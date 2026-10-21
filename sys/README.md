# Renux Kernel Source

This directory contains the source files and build glue that make up the Renux
kernel and its modules, including both original and contributed software.

## MD/MI separation

The kernel is split in two:

- **Machine-dependent (MD) code** lives in one directory per port (`amd64/`,
  `arm64/`, ...), and `x86/` holds what amd64 and i386 share. A new port
  touches its own directory and nothing else.
- **Machine-independent (MI) code** is everything else. It must not include
  `<machine/...>` headers it does not need, nor test `__amd64__` and friends.

The ports are to move under `arch/`, as in NetBSD.

## Configuration

Each port keeps its kernel configurations in `<port>/conf/`:

| File | Purpose |
| ---- | ------- |
| `GENERIC` | The configuration used in release builds. |
| `NOTES` | Documents every possible entry. |
| `LINT` | A compile-only configuration that maximizes build coverage. |

## Documentation

Source code documentation is maintained in the section 9 manual pages, under
[`share/man/man9`](../share/man/man9). Start with
[`intro(9)`](https://man.freebsd.org/intro/9). The
[FreeBSD Architecture Handbook](https://docs.freebsd.org/en/books/arch-handbook/)
covers the kernel's design at a higher level.

## Source Roadmap

### Machine-dependent

| Directory | Description |
| --------- | ----------- |
| `amd64` | AMD64 (64-bit x86) |
| `arm` | 32-bit ARM |
| `arm64` | 64-bit ARM (AArch64) |
| `i386` | i386 (32-bit x86) |
| `powerpc` | PowerPC/POWER (32 and 64-bit) |
| `riscv` | 64-bit RISC-V |
| `x86` | Code shared by amd64 and i386 |

### Machine-independent

| Directory | Description |
| --------- | ----------- |
| `bsm` | BSM audit record definitions |
| `cam` | Common Access Method storage subsystem: `cam(4)` and `ctl(4)` |
| `cddl` | CDDL-licensed optional sources such as DTrace |
| `compat` | Linux compatibility layer, 32-bit compatibility |
| `conf` | Kernel build glue |
| `contrib` | Third-party imported software such as OpenZFS |
| `crypto` | Crypto drivers |
| `ddb` | Interactive kernel debugger: `ddb(4)` |
| `dev` | Device drivers and other architecture-independent code |
| `fs` | Most filesystems, excluding UFS, NFS and ZFS |
| `gdb` | Kernel remote GDB stub: `gdb(4)` |
| `geom` | GEOM framework: `geom(4)` |
| `kern` | Main part of the kernel |
| `libkern` | libc-like and other support functions for kernel use |
| `modules` | Kernel module infrastructure |
| `net` | Core networking code |
| `net80211` | Wireless networking (IEEE 802.11): `net80211(4)` |
| `netgraph` | Graph-based networking subsystem: `netgraph(4)` |
| `netinet` | IPv4 protocol implementation: `inet(4)` |
| `netinet6` | IPv6 protocol implementation: `inet6(4)` |
| `netipsec` | IPsec protocol implementation: `ipsec(4)` |
| `netpfil` | Packet filters: `ipfw(4)`, `pf(4)` and `ipfilter(4)` |
| `opencrypto` | OpenCrypto framework: `crypto(7)` |
| `security` | Security facilities: `audit(4)` and `mac(4)` |
| `sys` | Kernel headers |
| `tests` | Kernel unit tests |
| `ufs` | Unix File System: `ffs(4)` |
| `vm` | Virtual memory system |
