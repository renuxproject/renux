// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// machine.zig - what the build needs to know of each port, and the only
// place it is written.  The lists of files stay where FreeBSD keeps them
// (sys/conf/files.<machine>, the Makefiles of stand/); this file has only
// what the build itself decides for a machine.
//
// The machine is a build option (-Dmachine), not the host: the build makes
// a kernel for any machine on any host.

const std = @import("std");

/// The ports of the tree, by the names FreeBSD gives them.
pub const Machine = enum {
    amd64,
    arm64,
    riscv,

    /// The port's build settings, or null for a port the Zig build does
    /// not support yet.
    pub fn config(m: Machine) ?Config {
        return switch (m) {
            .amd64 => .{
                .arch = .x86_64,
                .emulation = "elf_x86_64_fbsd",
                .headers = &.{
                    .{ "machine", "sys/amd64/include" },
                    .{ "x86", "sys/x86/include" },
                    .{ "i386", "sys/i386/include" },
                },
                // kern.mk, for amd64 and clang.
                .kernel_cflags = "-mcmodel=kernel -mno-red-zone -mno-mmx -mno-sse -msoft-float " ++
                    "-fno-asynchronous-unwind-tables",
                .kernel_cflags_late = "-mno-aes -mno-avx",
            },
            .arm64, .riscv => null,
        };
    }

    /// The port's name in paths: sys/<name>/conf, ldscript.<name>...
    pub fn name(m: Machine) []const u8 {
        return @tagName(m);
    }
};

pub const Config = struct {
    /// The CPU of the target triple.
    arch: std.Target.Cpu.Arch,
    /// lld's -m for the kernel.
    emulation: []const u8,
    /// The header directories config(8)'s build directory links, as
    /// { name, directory }: <machine/...> and the ones it includes.
    headers: []const [2][]const u8,
    /// The machine's kernel CFLAGS, where kern.mk puts them: after the
    /// common ones, and the last ones before -std.
    kernel_cflags: []const u8,
    kernel_cflags_late: []const u8,

    /// The target triple, for the FreeBSD release `revision`.
    pub fn triple(c: Config, b: *std.Build, revision: []const u8) []const u8 {
        return b.fmt("{s}-unknown-freebsd{s}", .{ @tagName(c.arch), revision });
    }
};
