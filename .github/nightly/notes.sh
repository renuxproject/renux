#!/bin/sh
#
# SPDX-License-Identifier: MPL-2.0
#
# Copyright (c) 2026 Renan Lucas Vieira Hilário
# Copyright (c) 2026 The Renux Project
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# The notes of a Renux Nightly build's release, in Markdown, on standard
# output: the banner, what the build is, its last 10 commits (on Renux's
# own line: a merge of FreeBSD is one of them), its files and how to check
# them.  The snapshot workflow runs it in a checkout of the build's commit
# with at least 10 commits of history:
#
#   notes.sh NAME
#
# NAME is the snapshot's, renux-nightly-MACHINE-YYYYMMDD-COMMIT: a nightly
# build is Renux in development, and has no version.  The repository is
# GITHUB_REPOSITORY (renuxproject/renux when unset).

set -eu

name=$1
repo=${GITHUB_REPOSITORY:-renuxproject/renux}
url=https://github.com/$repo
commit=$(git rev-parse HEAD)
short=$(git rev-parse --short=10 HEAD)
# renux-nightly-amd64-20261025-0123456789: the machine and the day are
# the fields before the commit.
rest=${name#renux-nightly-}
rest=${rest%-*}
day=${rest##*-}
machine=${rest%-*}
date=$(printf '%s-%s-%s' "$(echo "$day" | cut -c1-4)" "$(echo "$day" | cut -c5-6)" "$(echo "$day" | cut -c7-8)")

cat <<NOTES
![Renux Nightly builds](https://raw.githubusercontent.com/$repo/$commit/.github/nightly/banner.png)

**Renux in development** for $machine, built on $date from [\`$short\`]($url/commit/$commit) by \`zig build image iso\`.

> [!WARNING]
> A nightly build is for testing: things change, and can break, from one build to the next. UEFI only. In the installer, choose UFS: ZFS is not built yet.

### The last 10 commits

NOTES

git log -10 --first-parent --format="- [\`%h\`]($url/commit/%H) %s" HEAD

cat <<NOTES

[All the changes]($url/commits/$commit)

### Files

| File | What it is |
| ---- | ---------- |
| \`$name-installer.iso.xz\` | The installer: it boots into the Renux installer, which sets up the disk and the network and installs the system. |
| \`$name.img.xz\` | A disk with the system ready, for a virtual machine or to write to a disk. |
| \`SHA256\` | The sha256 of both. |

### Check and unpack

\`\`\`sh
sha256sum -c SHA256
unxz $name-installer.iso.xz
\`\`\`
NOTES
