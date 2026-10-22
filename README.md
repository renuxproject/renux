# Renux Source

Renux is a BSD operating system built for **portability**, **performance** and
**ease of maintenance**. It is based on FreeBSD 15.1 and borrows NetBSD's
discipline: machine-dependent code is kept apart from the rest, and the system is
built by Zig alone.

> **Status:** 0.1-CURRENT. Experimental; amd64 only. The Zig build is being
> written.

## Building

```sh
zig build kconfig      # the kernel configuration, in zig-out/kconfig/GENERIC
zig build hosttools    # yacc, awk, rpcgen and vtfontcvt, built from this tree
zig build kernel       # the kernel, in zig-out/boot/kernel
zig build loader       # the EFI loader and its Lua scripts, in zig-out/boot
```

Zig is the whole toolchain. It compiles the C and assembly of the tree with
the clang and lld it carries, and builds from the tree every other program
the build runs, so the result does not depend on the host.

| Option | Effect |
| ------ | ------ |
| `-Dkernconf=NAME` | kernel configuration (default: `GENERIC`) |
| `-Dmachine=NAME` | target machine (default: `amd64`) |

### Requirements

| Tool | Used for |
| ---- | -------- |
| Zig 0.17 | everything |

## Relationship with FreeBSD

Renux is based on FreeBSD 15.1 and moves with FreeBSD's development:

| Branch | Contents |
| ------ | -------- |
| `main` | Renux. |
| `upstream` | FreeBSD's `main` (CURRENT), mirrored untouched once a day by [`.github/workflows/upstream.yml`](.github/workflows/upstream.yml). |

FreeBSD's changes are brought into `main` a little at a time, by merging
`upstream` up to a chosen commit, so that Renux keeps a current base when
a FreeBSD release reaches its end of life.  Renux changes as few of
FreeBSD's files as it can, so that these merges stay simple.

## Source Roadmap

### Renux

| Path | Description |
| ---- | ----------- |
| [`build.zig`](build.zig) | The build. |
| [`tools/renux`](tools/renux) | The build's parts: the kernel configuration, the host tools, the kernel, the loader. |

### Base system

| Directory | Description |
| --------- | ----------- |
| `bin` | System/user commands. |
| `cddl` | Source code for third-party software under the Common Development and Distribution License. |
| `contrib` | Source code for third-party software. |
| `crypto` | Source code for cryptographic libraries and commands (see [`crypto/README`](crypto/README)). |
| `etc` | Template files for `/etc`. |
| `gnu` | Source code for third-party software under the GNU General Public License (GPL) or Lesser General Public License (LGPL). See [`gnu/COPYING`](gnu/COPYING) and [`gnu/COPYING.LIB`](gnu/COPYING.LIB). |
| `include` | System include files. |
| `kerberos5` | Build system for Kerberos 5 (Heimdal). |
| `krb5` | Build system for Kerberos 5 (MIT). |
| `lib` | System libraries. |
| `libexec` | System commands intended to be executed by other commands or daemons. |
| `release` | FreeBSD's release Makefiles and scripts. |
| `rescue` | Build system for statically linked `/rescue` commands. |
| `sbin` | System commands. |
| `secure` | Build system for cryptographic libraries and commands (excluding Kerberos). |
| `share` | Shared resources. |
| `stand` | Boot loader sources. |
| `sys` | Kernel sources (see [`sys/README.md`](sys/README.md)). |
| `targets` | Support for experimental `DIRDEPS_BUILD`. |
| `tests` | Tests which can be run by Kyua (see [`tests/README`](tests/README)). |
| `tools` | Ancillary utilities and tests (not included in the build). |
| `usr.bin` | User commands. |
| `usr.sbin` | System administration commands. |

## Licenses

Renux's own work is under the
[Mozilla Public License 2.0](LICENSES/MPL-2.0.txt), so that it stays open
source: whoever changes a Renux file and distributes it must publish that
file's source.  The MPL applies file by file, so Renux's files may be
combined with code under other licenses.

- **Files Renux writes** (the build, `build.zig` and
  [`tools/renux`](tools/renux), and any new file) are under the MPL 2.0
  and say `SPDX-License-Identifier: MPL-2.0`.
- **Renux's code goes in new files** whenever it can, with no more than a
  hook in FreeBSD's files (an `#include`, a call): every file then has one
  license, and FreeBSD's changes merge with few conflicts.
- **Renux's changes to FreeBSD's files**, when there is no other way, are
  under the MPL 2.0 too.  The file keeps FreeBSD's license and notices for
  FreeBSD's code, and its header says both, with a line that names Renux's
  part:

  ```c
  /*-
   * SPDX-License-Identifier: BSD-2-Clause AND MPL-2.0
   *
   * ...FreeBSD's copyright and license, unchanged...
   *
   * Renux's changes to this file are under the Mozilla Public License,
   * v. 2.0: https://mozilla.org/MPL/2.0/.
   */
  ```

The rest of the tree keeps its license: FreeBSD's code is under the BSD
licenses of [`COPYRIGHT`](COPYRIGHT), and third-party sources under their
own, in their directories.  Some Renux files reproduce short pieces of
FreeBSD (the config.c template of config(8), the vers.c of newvers.sh,
libpe's MS-DOS stub); those pieces stay under their BSD licenses.
