# Renux Source

Renux is a BSD operating system built for **portability**, **performance** and
**ease of maintenance**. It is based on FreeBSD 15.1 and borrows NetBSD's
discipline: machine-dependent code lives in [`sys/arch/`](sys/arch), and the
whole system builds from any Unix host with nothing but a POSIX shell and a
C/C++ compiler.

> **Status:** 0.1-CURRENT. Experimental; amd64 only.

## Building

```sh
./renux build      # host tools, world and the GENERIC kernel
./renux distrib    # sets and install media
./renux run        # boot the install media in QEMU
```

The first build makes its own tools from this tree into `obj/tools/` — make,
Lua, the LLVM toolchain, `makefs`, `mkimg` — so the result does not depend on
the host. The build never needs root.

### Requirements

| Tool | Used for |
| ---- | -------- |
| a POSIX `sh` | running `./renux` |
| a C and C++ compiler | building the host tools in `obj/tools/` |
| QEMU | `./renux run` only |

Supported hosts: FreeBSD, NetBSD, OpenBSD, DragonFly, Linux and macOS.

## Relationship with FreeBSD

Renux follows FreeBSD `releng/15.1`.

- The upstream branch is mirrored untouched as `upstream/releng-15.1`.
- `./renux sync` merges it into `main`, so FreeBSD's security fixes reach
  Renux as they are published.
- Every file Renux changes is listed in
  [`docs/DIVERGENCE.md`](docs/DIVERGENCE.md).

## Source Roadmap

### Renux

| Directory | Description |
| --------- | ----------- |
| [`renux`](renux) | The build entry point. |
| [`tools/renux`](tools/renux) | The Renux build and maintenance tools. |
| [`distrib`](distrib) | Sets and install media. |
| [`docs`](docs) | Renux documentation. |

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
| `release` | FreeBSD's release Makefiles and scripts (Renux uses [`distrib`](distrib)). |
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

## Copyright

See [`COPYRIGHT`](COPYRIGHT). Third-party sources keep their own licenses in
their directories.
