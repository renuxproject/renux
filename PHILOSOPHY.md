<!--
SPDX-License-Identifier: MPL-2.0

Copyright (c) 2026 Renan Lucas Vieira Hilário
Copyright (c) 2026 The Renux Project

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
-->

# The Renux Philosophy

> **Install Zig. Build the whole system.**

Renux is a general-purpose operating system that is easy to maintain,
portable, and built with Zig alone.  This document says what Renux values
and how those values decide what goes into it.  When a change is in doubt,
it is judged against this document.

## Why Renux exists

Renux is **Ren**an + **U**ni**x**.  Its creator, Renan Lucas Vieira Hilário,
uses Linux and the BSDs, and saw how many toolchains and dependencies it
takes to build them: a compiler, a linker, a make, a shell, an awk, a yacc,
each with its own version, and each a little different on every host.

Zig compiles C, C++ and Zig for any machine, and it is a single binary.  So
the question was: what if an operating system could be built on any system
at the cost of Zig alone?  Renux is the answer to that question, and it is
meant to be a technology anyone can take up, not one person's project.

## Principles

### 1. Zig is the only dependency

To build Renux you install Zig.  Nothing else is needed from the host: no
system compiler, no make, no shell scripts, no Python, no Perl.

- Zig is the toolchain.  It compiles the C and assembly of the tree with
  the clang and lld it carries.
- Every other program the build runs (yacc, awk, rpcgen, vtfontcvt, bmake,
  config) is either built from the tree by Zig or rewritten in Zig.
- The build is `build.zig`.  A step that needs a host tool is a bug.

### 2. Any host builds Renux

Renux must build on any system Zig runs on, Unix or not, and the result
must not depend on which one it was.

- The build reads only the tree and writes only its cache and `zig-out`.
- The same tree and the same Zig give the same bytes.  Reproducibility is
  checked, not hoped for: a kernel built in two different caches must be
  identical.
- Paths of the host never end up in what the build makes.

### 3. Renux carries its own compiler

Zig is Renux's system compiler, in the base system.  A running Renux
builds Renux with the Zig it ships, so the system can maintain itself.

- `cc`, `c++` and `ld` are `zig cc`, `zig c++` and `zig ld.lld`.
- For now the Zig the system carries is ziglang.org's build for the
  machine, fetched and checked by Zig's package manager (build.zig.zon);
  building it from the tree comes later, with the LLVM it needs.
- Each series of Renux is built by one series of Zig, and `zig build`
  refuses another:

  | Renux | Zig |
  | ----- | --- |
  | 0.1-CURRENT | 0.17.x |
  | 0.2-CURRENT | 0.18.0 |

### 4. Easy to maintain

A system that one person can understand is a system many people can keep.

- One build, in one language.  What the build knows of a machine is
  written in one place (`tools/renux/machine.zig`).
- Lists of files stay where FreeBSD keeps them; the build reads them
  instead of copying them.
- Code is explicit: types are written, names are spelled out, nothing is
  left for the reader to guess.

### 5. FreeBSD's base, Renux's way

Renux starts from FreeBSD 15.1 and grows into a hard fork that still
follows FreeBSD's development.

- The `upstream` branch mirrors FreeBSD's `main` every day; Renux merges
  it a little at a time, so it keeps a current base when a FreeBSD release
  reaches its end of life.
- Renux's code goes in new files, with no more than a hook in FreeBSD's
  files, so that merges stay simple.
- What FreeBSD does well is kept.  What Renux changes, it changes for a
  reason this document gives.

### 6. Portable

Renux is not tied to one machine.  amd64 comes first; arm64 and riscv
follow.  A new port should cost an entry in `machine.zig` and the port's
own code, not a new build.

### 7. Open source, always

Renux's work is under the [Mozilla Public License 2.0](LICENSES/MPL-2.0.txt).
Whoever changes a Renux file and distributes it publishes that file's
source.  The MPL applies file by file, so Renux lives beside FreeBSD's BSD
code and third-party code without changing their licenses.

### 8. Decentralized

No one owns Renux.  Anyone may mirror it, host it, fork it and build their
own.  Since the build needs only Zig, building your own Renux is never a
privilege of whoever holds the infrastructure.

### 9. Your device, your rules

Renux collects no personal data.  It does no age verification, and it
never will.  The system answers to the person who runs it.

## What "the whole system" is

For now, the whole system is the base system: the kernel, the loader and
the userland of this tree.  Packages are outside it.

## How this document grows

The principles above are the core, and they change rarely.  The rest of
the philosophy is written as Renux meets the questions, each answered
when a real decision needs it, not guessed in advance.  These are open:

- **The language of new Renux code:** Zig, C, or Zig wherever it can be.
- **Performance:** what Renux promises, and how it is measured.
