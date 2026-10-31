/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2020 Vladimir Kondratyev <wulf@FreeBSD.org>
 * Copyright (c) 2020 Val Packett <val@packett.cool>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <sys/cdefs.h>
/*
 * XBox 360 gamepad driver thanks to the custom descriptor in usbhid.
 *
 * Tested on: SVEN GC-5070 in both XInput (XBox 360) and DirectInput modes
 */

#include <sys/param.h>
#include <sys/bus.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/sysctl.h>
#include <sys/taskqueue.h>

#include <machine/atomic.h>

#include <dev/evdev/input.h>
#include <dev/evdev/evdev.h>

#include <dev/hid/hgame.h>
#include <dev/hid/hid.h>
#include <dev/hid/hidbus.h>
#include <dev/hid/hidmap.h>
#include <dev/hid/hidquirk.h>
#include <dev/hid/hidrdesc.h>

#include <dev/usb/usb.h>
#include <dev/usb/usbdi.h>

static const uint8_t	xb360gp_rdesc[] = {HID_XB360GP_REPORT_DESCR()};

struct xb360gp_softc {
	struct hgame_softc	hgame;	/* first: hgame callbacks use it */
	struct task		rumble_task;
	u_int			rumble;	/* strong << 8 | weak */
};

static hidmap_cb_t	xb360gp_final_cb;

#define XB360GP_MAP_BUT(number, code)	\
	{ HIDMAP_KEY(HUP_BUTTON, number, code) }
#define XB360GP_MAP_ABS(usage, code)	\
	{ HIDMAP_ABS(HUP_GENERIC_DESKTOP, HUG_##usage, code) }
#define XB360GP_MAP_ABS_FLT(usage, code)	\
	{ HIDMAP_ABS(HUP_GENERIC_DESKTOP, HUG_##usage, code),	\
	    .fuzz = 16, .flat = 128 }
#define XB360GP_MAP_ABS_INV(usage, code)	\
	{ HIDMAP_ABS(HUP_GENERIC_DESKTOP, HUG_##usage, code),	\
	    .fuzz = 16, .flat = 128, .invert_value = true }
#define XB360GP_MAP_CRG(usage_from, usage_to, callback)	\
	{ HIDMAP_ANY_CB_RANGE(HUP_GENERIC_DESKTOP,	\
	    HUG_##usage_from, HUG_##usage_to, callback) }
#define XB360GP_FINALCB(cb)		\
	{ HIDMAP_FINAL_CB(&cb) }

/* Customized to match usbhid's XBox 360 descriptor */
static const struct hidmap_item xb360gp_map[] = {
	XB360GP_MAP_BUT(1,		BTN_SOUTH),
	XB360GP_MAP_BUT(2,		BTN_EAST),
	XB360GP_MAP_BUT(3,		BTN_WEST),
	XB360GP_MAP_BUT(4,		BTN_NORTH),
	XB360GP_MAP_BUT(5,		BTN_TL),
	XB360GP_MAP_BUT(6,		BTN_TR),
	XB360GP_MAP_BUT(7,		BTN_SELECT),
	XB360GP_MAP_BUT(8,		BTN_START),
	XB360GP_MAP_BUT(9,		BTN_THUMBL),
	XB360GP_MAP_BUT(10,		BTN_THUMBR),
	XB360GP_MAP_BUT(11,		BTN_MODE),
	XB360GP_MAP_CRG(D_PAD_UP, D_PAD_LEFT, hgame_dpad_cb),
	XB360GP_MAP_ABS_FLT(X,		ABS_X),
	XB360GP_MAP_ABS_INV(Y,		ABS_Y),
	XB360GP_MAP_ABS(Z,		ABS_Z),
	XB360GP_MAP_ABS_FLT(RX,		ABS_RX),
	XB360GP_MAP_ABS_INV(RY,		ABS_RY),
	XB360GP_MAP_ABS(RZ,		ABS_RZ),
	XB360GP_FINALCB(		xb360gp_final_cb),
};

static const STRUCT_USB_HOST_ID xb360gp_devs[] = {
	/* the Xbox 360 gamepad doesn't use the HID class */
	{USB_IFACE_CLASS(UICLASS_VENDOR),
	 USB_IFACE_SUBCLASS(UISUBCLASS_XBOX360_CONTROLLER),
	 USB_IFACE_PROTOCOL(UIPROTO_XBOX360_GAMEPAD),},
};

static void
xb360gp_identify(driver_t *driver, device_t parent)
{
	const struct hid_device_info *hw = hid_get_device_info(parent);

	/* the Xbox 360 gamepad has no report descriptor */
	if (hid_test_quirk(hw, HQ_IS_XBOX360GP))
		hid_set_report_descr(parent, xb360gp_rdesc,
		    sizeof(xb360gp_rdesc));
}

static int
xb360gp_probe(device_t dev)
{
	struct hgame_softc *sc = device_get_softc(dev);
	const struct hid_device_info *hw = hid_get_device_info(dev);
	int error;

	if (!hid_test_quirk(hw, HQ_IS_XBOX360GP))
		return (ENXIO);

	hidmap_set_dev(&sc->hm, dev);

	error = HIDMAP_ADD_MAP(&sc->hm, xb360gp_map, NULL);
	if (error != 0)
		return (error);

	device_set_desc(dev, "XBox 360 Gamepad");

	return (BUS_PROBE_DEFAULT);
}

/* Called by evdev with its lock held, so the USB write is deferred. */
static void
xb360gp_ff_rumble(struct evdev_dev *evdev, uint16_t strong, uint16_t weak)
{
	struct xb360gp_softc *sc = device_get_softc(evdev_get_softc(evdev));

	atomic_store_int(&sc->rumble, (strong >> 8) << 8 | weak >> 8);
	taskqueue_enqueue(taskqueue_thread, &sc->rumble_task);
}

static void
xb360gp_rumble_task(void *context, int pending __unused)
{
	struct xb360gp_softc *sc = context;
	u_int rumble = atomic_load_int(&sc->rumble);
	/* Same packet as Linux xpad sends to XTYPE_XBOX360 pads */
	uint8_t buf[8] = { 0x00, 0x08, 0x00, rumble >> 8, rumble & 0xff };

	(void)hid_write(sc->hgame.hm.dev, buf, sizeof(buf));
}

static int
xb360gp_final_cb(HIDMAP_CB_ARGS)
{
	struct evdev_dev *evdev = HIDMAP_CB_GET_EVDEV();

	if (HIDMAP_CB_GET_STATE() == HIDMAP_CB_IS_ATTACHING)
		evdev_support_ff_rumble(evdev, xb360gp_ff_rumble);

	return (hgame_final_cb(hm, hi, ctx));
}

static int
xb360gp_attach(device_t dev)
{
	struct xb360gp_softc *sc = device_get_softc(dev);
	uint8_t reportbuf[3];
	int error;

	/*
	 * The four LEDs on the gamepad blink until the host assigns a
	 * player number.  Like Linux xpad, flash and then light the LED
	 * for player 1-4 (commands 0x02-0x05), taken from the unit number.
	 */
	reportbuf[0] = 1;
	reportbuf[1] = 3;
	reportbuf[2] = 0x02 + device_get_unit(dev) % 4;
	/* Linux xpad uses the interrupt OUT pipe, some clones need it */
	error = hid_write(dev, reportbuf, sizeof(reportbuf));
	if (error)
		error = hid_set_report(dev, reportbuf, sizeof(reportbuf),
		    HID_OUTPUT_REPORT, 0);
	if (error)
		device_printf(dev, "set output report failed, error=%d "
		    "(ignored)\n", error);

	TASK_INIT(&sc->rumble_task, 0, xb360gp_rumble_task, sc);

	return (hidmap_attach(&sc->hgame.hm));
}

static int
xb360gp_detach(device_t dev)
{
	struct xb360gp_softc *sc = device_get_softc(dev);
	int error;

	/* evdev is gone after this, so no new rumble requests */
	error = hidmap_detach(&sc->hgame.hm);
	if (error == 0)
		taskqueue_drain(taskqueue_thread, &sc->rumble_task);

	return (error);
}

static device_method_t xb360gp_methods[] = {
	DEVMETHOD(device_identify,	xb360gp_identify),
	DEVMETHOD(device_probe,		xb360gp_probe),
	DEVMETHOD(device_attach,	xb360gp_attach),
	DEVMETHOD(device_detach,	xb360gp_detach),
	DEVMETHOD_END
};

DEFINE_CLASS_0(xb360gp, xb360gp_driver, xb360gp_methods,
    sizeof(struct xb360gp_softc));
DRIVER_MODULE(xb360gp, hidbus, xb360gp_driver, NULL, NULL);
MODULE_DEPEND(xb360gp, hid, 1, 1, 1);
MODULE_DEPEND(xb360gp, hidbus, 1, 1, 1);
MODULE_DEPEND(xb360gp, hidmap, 1, 1, 1);
MODULE_DEPEND(xb360gp, hgame, 1, 1, 1);
MODULE_DEPEND(xb360gp, evdev, 1, 1, 1);
MODULE_VERSION(xb360gp, 1);
USB_PNP_HOST_INFO(xb360gp_devs);
