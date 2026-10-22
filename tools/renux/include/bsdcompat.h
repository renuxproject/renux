/*
 * SPDX-License-Identifier: MPL-2.0
 *
 * Copyright (c) 2026 Renan Lucas Vieira Hilário
 * Copyright (c) 2026 The Renux Project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * The <sys/cdefs.h> and <sys/param.h> macros that the host tools of the
 * build use and that not every host defines.  The build passes this file
 * with -include when it compiles a FreeBSD tool for the host.
 */

#ifndef RENUX_BSDCOMPAT_H
#define	RENUX_BSDCOMPAT_H

#include <sys/types.h>
#include <stdint.h>
#include <stdio.h>

#ifndef __dead2
#define	__dead2		__attribute__((__noreturn__))
#endif
#ifndef __unused
#define	__unused	__attribute__((__unused__))
#endif
#ifndef __packed
#define	__packed	__attribute__((__packed__))
#endif
#ifndef __nonstring
#define	__nonstring
#endif
#ifndef __DECONST
#define	__DECONST(type, var)	((type)(unsigned long)(const void *)(var))
#endif
#ifndef nitems
#define	nitems(x)	(sizeof((x)) / sizeof((x)[0]))
#endif

#if !defined(__FreeBSD__) && !defined(__NetBSD__) && !defined(__OpenBSD__) && \
    !defined(__DragonFly__) && !defined(__APPLE__)
typedef unsigned long	u_register_t;

/*
 * fgetln(3), which glibc and musl lack: the next line of fp, newline
 * included, valid until the next call.
 */
static inline char *
renux_fgetln(FILE *fp, size_t *len)
{
	static char *line;
	static size_t size;
	ssize_t n;

	if ((n = getline(&line, &size, fp)) < 0)
		return (NULL);
	*len = (size_t)n;
	return (line);
}
#define	fgetln	renux_fgetln
#endif

#endif /* RENUX_BSDCOMPAT_H */
