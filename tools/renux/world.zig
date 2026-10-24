// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// world.zig - the userland: FreeBSD's buildworld and installworld, run by
// the bmake Zig builds from the tree, with Zig as every compiler.
//
// The world is FreeBSD's Makefiles, and bmake runs them: the Zig build
// does not reimplement them, as it does the kernel's and the loader's.
// What the Makefiles call:
//
//   CC, CXX, CPP           the host's compiler (bootstrap tools): zig cc
//   XCC, XCXX, XCPP, XLD   the target's compiler and linker: zig clang,
//                          zig ld.lld
//   hostname, time         two commands the build links from the host
//
// are one program, zigtools.zig, under each name.  The other commands the
// Makefiles use (sh, cp, find, gzip, xz, ...) are the host's, as FreeBSD's
// tools/build lists them.
//
// The world is built without the toolchain (Zig is the compiler, and will
// be the system's), the tests and lib32, and without the loader, which the
// Zig build makes (stand.zig).  It is installed without root (-DNO_ROOT):
// owners and modes go to a METALOG, from which makefs makes the image.

const std: type = @import("std");
const mem: type = std.mem;
const fmt: type = std.fmt;
const debug: type = std.debug;
const Thread: type = std.Thread;
const Build: type = std.Build;
const LazyPath: type = Build.LazyPath;

const Machine: type = @import("machine.zig").Machine;

pub const Options: type = struct {
    machine: Machine,
    bmake: *Build.Step.Compile,
    kgen: *Build.Step.Compile,
};

pub const World: type = struct {
    /// buildworld.
    build: *Build.Step,
    /// installworld and distribution into destdir.
    install: *Build.Step,
    /// The installed world, with its METALOG.
    destdir: []const u8,
    /// makefs and mkimg, which buildworld makes for the host.
    makefs: []const u8,
    mkimg: []const u8,
};

/// The names zigtools answers to (zigtools.zig).
const tool_names: [9][]const u8 = .{ "cc", "c++", "cpp", "clang", "clang++", "clang-cpp", "ld.lld", "hostname", "time" };

/// The options of every make of the world.  DISK_IMAGE_TOOLS_BOOTSTRAP:
/// makefs and mkimg for the host, for the image.
const make_options: [8][]const u8 = .{
    "-DWITH_AUTO_OBJ",
    "-DWITH_DISK_IMAGE_TOOLS_BOOTSTRAP",
    "-DWITHOUT_CLEAN",
    "-DNO_ROOT",
    "-DWITHOUT_TOOLCHAIN",
    "-DWITHOUT_TESTS",
    "-DWITHOUT_LIB32",
    "-DWITHOUT_BOOT",
};

/// The absolute path of the source tree.
fn treeDir(b: *Build) []const u8 {
    return b.root.root_dir.handle.realPathFileAlloc(b.graph.io, b.root.subPathOrDot(), b.allocator) catch |err|
        debug.panic("source tree: {t}", .{err});
}

/// A make of the world: kgen env sets the toolchain, then bmake runs
/// targets in the tree.
fn make(b: *Build, opts: Options, tools: LazyPath, obj: []const u8, targets: []const []const u8) *Build.Step.Run {
    const run: *Build.Step.Run = b.addRunArtifact(opts.kgen);
    run.addArg("env");
    run.addPrefixedDirectoryArg("PATH+=", tools);
    run.addArg(b.fmt("MAKEOBJDIRPREFIX={s}", .{obj}));
    const vars: [7][2][]const u8 = .{
        .{ "CC", "cc" },      .{ "CXX", "c++" },      .{ "CPP", "cpp" },
        .{ "XCC", "clang" },  .{ "XCXX", "clang++" }, .{ "XCPP", "clang-cpp" },
        .{ "XLD", "ld.lld" },
    };
    for (vars) |v| run.addPrefixedFileArg(b.fmt("{s}=", .{v[0]}), tools.path(b, v[1]));
    run.addArg("--");
    run.addArtifactArg(opts.bmake);
    const jobs: usize = Thread.getCpuCount() catch 1;
    run.addArgs(&.{ "-C", treeDir(b), "-j", b.fmt("{d}", .{jobs}) });
    run.addArgs(targets);
    run.addArgs(&.{ b.fmt("TARGET={s}", .{opts.machine.name()}), b.fmt("TARGET_ARCH={s}", .{opts.machine.name()}) });
    run.addArgs(&make_options);
    // bmake knows what is up to date; the Zig build always asks it.
    run.has_side_effects = true;
    return run;
}

pub fn build(b: *Build, opts: Options) World {
    // zigtools, under each of its names.
    const options: *Build.Step.Options = b.addOptions();
    options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    // clang's resource directory: its own headers, and nothing else.  Zig's
    // lib directory is no resource directory: clang also looks there for
    // crt1.o and the like before the sysroot, and where Zig's lib is
    // /usr/lib (a host's package), it finds the host's.
    const resource: *Build.Step.WriteFile = b.addWriteFiles();
    _ = resource.addCopyDirectory(b.graph.path(.zig_lib, "include"), "include", .{});
    options.addOptionPathUntracked("resource_dir", resource.getDirectory());
    // The paths of options are relative to the tree, and the compilers run
    // in the world's object directories.
    options.addOption([]const u8, "tree", treeDir(b));
    const zigtools: *Build.Step.Compile = b.addExecutable(.{
        .name = "zigtools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/renux/zigtools.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            // execve(2)
            .link_libc = true,
        }),
    });
    zigtools.root_module.addOptions("options", options);
    const wf: *Build.Step.WriteFile = b.addWriteFiles();
    for (tool_names) |name| _ = wf.addCopyFile(zigtools.getEmittedBin(), name);
    const tools: LazyPath = wf.getDirectory();

    // bmake's object directories and the installed world, which bmake
    // keeps up to date itself, outside the Zig build's cache.
    const obj: []const u8 = b.fmt("{s}/.zig-cache/world/obj", .{treeDir(b)});
    const destdir: []const u8 = b.fmt("{s}/.zig-cache/world/root", .{treeDir(b)});
    const machine: []const u8 = opts.machine.name();
    const legacy: []const u8 = b.fmt("{s}{s}/{s}.{s}/tmp/legacy", .{ obj, treeDir(b), machine, machine });

    const mkdir: *Build.Step.Run = b.addRunArtifact(opts.kgen);
    mkdir.addArgs(&.{ "mkdir", obj });
    mkdir.has_side_effects = true;
    const buildworld: *Build.Step.Run = make(b, opts, tools, obj, &.{"buildworld"});
    buildworld.step.dependOn(&mkdir.step);

    // A fresh DESTDIR: the METALOG of NO_ROOT grows at every install.
    const fresh: *Build.Step.Run = b.addRunArtifact(opts.kgen);
    fresh.addArgs(&.{ "fresh", destdir });
    fresh.has_side_effects = true;
    fresh.step.dependOn(&buildworld.step);
    const install: *Build.Step.Run = make(b, opts, tools, obj, &.{ "installworld", "distribution" });
    install.addArgs(&.{ b.fmt("DESTDIR={s}", .{destdir}), "-DDB_FROM_SRC" });
    install.step.dependOn(&fresh.step);

    return .{
        .build = &buildworld.step,
        .install = &install.step,
        .destdir = destdir,
        .makefs = b.fmt("{s}/usr/sbin/makefs", .{legacy}),
        .mkimg = b.fmt("{s}/usr/bin/mkimg", .{legacy}),
    };
}
