/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The Renux Project
 *
 * The <sys/cdefs.h> and <sys/param.h> macros that the host tools of the
 * build use and that not every host defines.  The build passes this file
 * with -include when it compiles a FreeBSD tool for the host.
 */

#ifndef RENUX_BSDCOMPAT_H
#define	RENUX_BSDCOMPAT_H

#ifndef __dead2
#define	__dead2		__attribute__((__noreturn__))
#endif
#ifndef __unused
#define	__unused	__attribute__((__unused__))
#endif
#ifndef nitems
#define	nitems(x)	(sizeof((x)) / sizeof((x)[0]))
#endif

#endif /* RENUX_BSDCOMPAT_H */
