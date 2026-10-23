/*-
 * SPDX-License-Identifier: MPL-2.0
 *
 * Copyright (c) 2026 Renan Lucas Vieira Hilário
 * Copyright (c) 2026 The Renux Project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * The shape of vt(4)'s text cursor.
 *
 * FreeBSD draws the cursor as a block: the cell under it in reverse
 * colors.  Renux draws it as an underline, a bar at the bottom of the
 * cell in the color of the text, as the PC's text mode did.  The block
 * is a tunable away, in loader.conf(5):
 *
 *	kern.vt.cursor_shape=1
 *
 * The drivers that draw text with a font (vt_fb, and vt_core's buffer)
 * ask vt_cursor_invert() whether a cell is drawn in reverse, and call
 * vt_cursor_draw() after the text.  The others (vt_vga) keep the block.
 */

#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/systm.h>

#include <dev/vt/vt.h>

#define	VT_CURSOR_UNDERLINE	0
#define	VT_CURSOR_BLOCK		1

static int vt_cursor_shape = VT_CURSOR_UNDERLINE;
TUNABLE_INT("kern.vt.cursor_shape", &vt_cursor_shape);

/* The bar, in rows of one bit per pixel: wide enough for any font. */
static const uint8_t vt_cursor_bar[256] = { [0 ... 255] = 0xff };

/* A color no cell is drawn in: the cache of a cell that must be redrawn. */
#define	VT_CURSOR_STALE		((term_color_t)0xff)

static int
vt_cursor_at(const struct vt_buf *vb, int row, int col)
{

	return ((vb->vb_flags & (VBF_CURSOR | VBF_SCROLL)) == VBF_CURSOR &&
	    vb->vb_cursor.tp_row == row && vb->vb_cursor.tp_col == col);
}

/*
 * Whether the cell is drawn in reverse colors: the cut/paste selection
 * always, the cursor only when it is a block.
 */
int
vt_cursor_invert(const struct vt_buf *vb, int row, int col)
{

	if (vt_cursor_shape == VT_CURSOR_UNDERLINE &&
	    vt_cursor_at(vb, row, col))
		return (0);
	return (vtbuf_iscursor(vb, row, col));
}

/*
 * Draw the underline cursor, when it is in the area the driver has just
 * drawn.
 */
void
vt_cursor_draw(struct vt_device *vd, const struct vt_window *vw,
    const term_rect_t *area)
{
	const struct vt_buf *vb;
	const struct vt_font *vf;
	term_pos_t p;
	term_char_t c;
	term_color_t fg, bg;
	unsigned int height, x, y;
	size_t z;

	vb = &vw->vw_buf;
	vf = vw->vw_font;
	p = vb->vb_cursor;

	if (vt_cursor_shape != VT_CURSOR_UNDERLINE || vf == NULL ||
	    vd->vd_driver->vd_bitblt_bmp == NULL)
		return;
	if (!vt_cursor_at(vb, p.tp_row, p.tp_col))
		return;
	if (p.tp_row < area->tr_begin.tp_row ||
	    p.tp_row >= area->tr_end.tp_row ||
	    p.tp_col < area->tr_begin.tp_col ||
	    p.tp_col >= area->tr_end.tp_col)
		return;

	/* An eighth of the cell: 2 pixels of a 16-pixel font. */
	height = MAX(vf->vf_height / 8, 1);
	if (howmany(vf->vf_width, 8) * height > sizeof(vt_cursor_bar))
		return;

	c = VTBUF_GET_FIELD(vb, p.tp_row, p.tp_col);
	vt_determine_colors(c, 0, &fg, &bg);
	x = p.tp_col * vf->vf_width + vw->vw_draw_area.tr_begin.tp_col;
	y = (p.tp_row + 1) * vf->vf_height - height +
	    vw->vw_draw_area.tr_begin.tp_row;
	vd->vd_driver->vd_bitblt_bmp(vd, vw, vt_cursor_bar, NULL,
	    vf->vf_width, height, x, y, fg, bg);

	/*
	 * The cell now has a bar its cached colors do not know of: when
	 * the cursor leaves, the driver must draw the cell again.
	 */
	z = p.tp_row * PIXEL_WIDTH(VT_FB_MAX_WIDTH) + p.tp_col;
	if (vd->vd_drawnfg != NULL &&
	    z < PIXEL_HEIGHT(VT_FB_MAX_HEIGHT) * PIXEL_WIDTH(VT_FB_MAX_WIDTH))
		vd->vd_drawnfg[z] = VT_CURSOR_STALE;
}
