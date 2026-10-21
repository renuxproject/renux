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
zig build hosttools    # yacc and awk, built from this tree
zig build kernel       # the kernel, in zig-out/boot/kernel
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

Renux follows FreeBSD `releng/15.1`.

- The upstream branch is mirrored untouched as `upstream/releng-15.1`.
- It is merged into `main`, so FreeBSD's security fixes reach Renux as they
  are published.
- Renux changes as few of FreeBSD's files as it can.

## Source Roadmap

### Renux

| Path | Description |
| ---- | ----------- |
| [`build.zig`](build.zig) | The build. |
| [`tools/renux`](tools/renux) | The build's parts: the kernel configuration, the host tools, the kernel. |

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

## Copyright

See [`COPYRIGHT`](COPYRIGHT). Third-party sources keep their own licenses in
their directories.
