// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// zigtools.zig - the toolchain FreeBSD's Makefiles call, made of Zig.  One
// program, installed under many names; the name it is called by says what
// it does:
//
//   cc, c++, cpp                the host's compiler: zig cc, zig c++
//   clang, clang++, clang-cpp   the target's compiler: zig clang
//   ld.lld                      the target's linker: zig ld.lld
//   hostname, time              the two commands the build links from the
//                               host and not every host has
//
// The path of Zig and of clang's resource directory (a copy of Zig's
// lib/include, see world.zig) are fixed when the build compiles this
// program (options.zig_exe, options.resource_dir).

const std: type = @import("std");
const mem: type = std.mem;
const fmt: type = std.fmt;
const fs: type = std.fs;
const debug: type = std.debug;
const posix: type = std.posix;
const process: type = std.process;
const options: type = @import("options");
const Io: type = std.Io;
const Allocator: type = mem.Allocator;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    debug.print("zigtools: " ++ format ++ "\n", args);
    process.exit(1);
}

/// A name of a compiler, and Zig's arguments that go before the caller's.
const Driver: type = struct {
    name: []const u8,
    args: []const []const u8,
};

/// Zig's arguments before the caller's, for each name of a compiler.
fn zigArgs(gpa: Allocator, name: []const u8) ?[]const []const u8 {
    const resource_dir: []const u8 = fmt.allocPrint(gpa, "-resource-dir={s}", .{options.resource_dir}) catch @panic("OOM");
    const table: []const Driver = &.{
        .{ .name = "cc", .args = &.{"cc"} },
        .{ .name = "c++", .args = &.{"c++"} },
        .{ .name = "cpp", .args = &.{ "clang", "--driver-mode=cpp" } },
        .{ .name = "clang", .args = &.{ "clang", resource_dir } },
        .{ .name = "clang++", .args = &.{ "clang", "--driver-mode=g++", resource_dir } },
        .{ .name = "clang-cpp", .args = &.{ "clang", "--driver-mode=cpp", resource_dir } },
        .{ .name = "ld.lld", .args = &.{"ld.lld"} },
    };
    for (table) |entry| {
        // The table is on the stack (resource_dir is known at run time):
        // what is returned must outlive it.
        if (mem.eql(u8, entry.name, name)) return gpa.dupe([]const u8, entry.args) catch @panic("OOM");
    }
    return null;
}

pub fn main(init: process.Init) void {
    const io: Io = init.io;
    const gpa: Allocator = init.arena.allocator();
    const args: []const [:0]const u8 = init.minimal.args.toSlice(gpa) catch @panic("OOM");
    const name: []const u8 = fs.path.basename(args[0]);

    if (mem.eql(u8, name, "hostname")) {
        var buf: [posix.HOST_NAME_MAX]u8 = undefined;
        const host: []const u8 = posix.gethostname(&buf) catch |err| fatal("hostname: {t}", .{err});
        const line: []const u8 = fmt.allocPrint(gpa, "{s}\n", .{host}) catch @panic("OOM");
        Io.File.stdout().writeStreamingAll(io, line) catch |err| fatal("hostname: {t}", .{err});
        return;
    }

    // time runs its command; the build reads no times from it.
    var argv: std.ArrayList([]const u8) = .empty;
    if (mem.eql(u8, name, "time")) {
        if (args.len < 2) fatal("usage: time command [args...]", .{});
        argv.appendSlice(gpa, args[1..]) catch @panic("OOM");
    } else if (zigArgs(gpa, name)) |zig_args| {
        argv.append(gpa, options.zig_exe) catch @panic("OOM");
        argv.appendSlice(gpa, zig_args) catch @panic("OOM");
        argv.appendSlice(gpa, args[1..]) catch @panic("OOM");
    } else fatal("unknown name {s}", .{name});

    if (mem.eql(u8, name, "time")) {
        const err: process.ReplaceError = process.replace(io, .{ .argv = argv.items, .environ_map = init.environ_map });
        fatal("{s}: {t}", .{ argv.items[0], err });
    }
    execve(gpa, argv.items, init.environ_map);
}

/// Become Zig, by execve(2): process.replace copies the arguments with the
/// Io's own allocator, and a compiler's command line can outgrow it.
fn execve(gpa: Allocator, argv: []const []const u8, environ: *const process.Environ.Map) noreturn {
    const argv_z: [:null]?[*:0]const u8 = gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch @panic("OOM");
    for (argv, 0..) |arg, i| argv_z[i] = (gpa.dupeSentinel(u8, arg, 0) catch @panic("OOM")).ptr;
    const envp: process.Environ.PosixBlock = environ.createPosixBlock(gpa, .{}) catch @panic("OOM");
    const rc: c_int = std.c.execve(argv_z[0].?, argv_z.ptr, envp.slice.ptr);
    fatal("{s}: {t}", .{ argv[0], std.c.errno(rc) });
}
