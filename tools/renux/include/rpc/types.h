/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The Renux Project
 *
 * What usr.bin/rpcgen needs from <rpc/types.h> (sys/rpc/types.h), for
 * hosts whose C library has no Sun RPC, as current glibc.  The build puts
 * this directory on rpcgen's include path only.
 */

#ifndef RENUX_RPC_TYPES_H
#define	RENUX_RPC_TYPES_H

#include <stdint.h>
#include <sys/types.h>

typedef int32_t bool_t;
typedef int32_t enum_t;

#ifndef FALSE
#define	FALSE	(0)
#endif
#ifndef TRUE
#define	TRUE	(1)
#endif

#endif /* RENUX_RPC_TYPES_H */
