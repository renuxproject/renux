// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// modules.zig - the kernel modules, built by FreeBSD's sys/modules
// Makefiles with the bmake Zig builds from the tree, and with the same
// Zig toolchain the world uses.  The kernel build writes the option
// headers, vnode_if.h and the machine headers into one directory; that
// directory is the KERNBUILDDIR the Makefiles read, so the modules are
// built against exactly the kernel configuration of this build.
//
// `-Dmodules=all` builds every module in sys/modules.  The default, and
// any comma-separated list, passes MODULES_OVERRIDE, which is how FreeBSD
// itself builds a subset.
//
// The build collects the selected .ko files in a generated directory,
// installs them in zig-out/boot/modules, and hands that directory to the
// image: the disk, the installer's kernel.txz and the live ISO all carry
// /boot/modules.

const std: type = @import("std");
const mem: type = std.mem;
const Thread: type = std.Thread;
const Build: type = std.Build;
const LazyPath: type = Build.LazyPath;

const Machine: type = @import("machine.zig").Machine;
const HostTools: type = @import("hosttools.zig").HostTools;

pub const Options: type = struct {
    machine: Machine,
    /// The target triple, as kernel.zig passes it to Zig.
    triple: []const u8,
    /// The directory of zigtools wrappers (cc, c++, cpp, ld.lld, ...).
    tools: LazyPath,
    hosttools: HostTools,
    kgen: *Build.Step.Compile,
    /// The kernel's generated headers: opt_*.h, vnode_if.h, machine/...
    include: LazyPath,
    /// "all", or a comma-separated MODULES_OVERRIDE list.
    selection: []const u8,
};

pub const Modules: type = struct {
    /// bmake -C sys/modules all.
    compile: *Build.Step,
    /// The same modules installed in zig-out/boot/modules.
    install: *Build.Step,
    /// The flat directory of .ko files the image reads.
    dir: LazyPath,
};

/// The absolute path of the source tree.  `joinString` keeps the path the
/// build was given: it does not call realpath(2), which not every host (or
/// Linux compatibility layer) implements for a directory handle.
fn treeDir(b: *Build) []const u8 {
    if (b.root.root_dir.path) |p| return p;
    return b.root.joinString(b.allocator, "") catch @panic("OOM");
}

const Selection: type = struct {
    /// MODULES_OVERRIDE, or "" for all.
    override: []const u8,
    /// The module directory names of the selection; empty for all.
    names: []const []const u8,
};

/// "zfs,if_bridge" -> { "zfs if_bridge", { "zfs", "if_bridge" } };
/// "all" -> { "", {} } (no override, every module).
fn selection(b: *Build, choice: []const u8) Selection {
    if (mem.eql(u8, choice, "all")) return .{ .override = "", .names = &.{} };
    var names: std.ArrayList([]const u8) = .empty;
    var it: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, choice, ',');
    while (it.next()) |part| {
        const name: []const u8 = mem.trim(u8, part, " \t");
        if (name.len > 0) names.append(b.allocator, name) catch @panic("OOM");
    }
    const items: []const []const u8 = names.items;
    return .{ .override = mem.join(b.allocator, " ", items) catch @panic("OOM"), .names = items };
}

/// The `modules` step: bmake -C sys/modules all, with KERNBUILDDIR set
/// to the kernel's generated headers and MODULES_OVERRIDE to the
/// selected modules, then the .ko files collected and installed.
pub fn build(b: *Build, opts: Options) Modules {
    const tree: []const u8 = treeDir(b);
    const obj: []const u8 = b.fmt("{s}/.zig-cache/modules/obj", .{tree});
    const zig_lib: []const u8 = b.fmt("{s}/lib", .{std.fs.path.dirname(b.graph.zig_exe) orelse "."});
    const sel: Selection = selection(b, opts.selection);

    const run: *Build.Step.Run = b.addRunArtifact(opts.kgen);
    run.addArg("env");
    // The toolchain wrappers, then the environment the Makefiles read.
    run.addPrefixedDirectoryArg("PATH+=", opts.tools);
    run.addArg(b.fmt("MAKEOBJDIRPREFIX={s}", .{obj}));
    run.addArg(b.fmt("SRCTOP={s}", .{tree}));
    run.addArg(b.fmt("SYSDIR={s}/sys", .{tree}));
    run.addArg(b.fmt("MACHINE={s}", .{opts.machine.name()}));
    run.addArg(b.fmt("MACHINE_ARCH={s}", .{opts.machine.name()}));
    run.addArg(b.fmt("MACHINE_CPUARCH={s}", .{opts.machine.name()}));
    run.addArg(b.fmt("TARGET={s}", .{opts.machine.name()}));
    run.addArg(b.fmt("TARGET_ARCH={s}", .{opts.machine.name()}));
    // Zig's clang is newer than the tree's LLVM: its new warnings must
    // not stop the build.  The host has no ctfmerge; skip CTF.
    run.addArg("WERROR=");
    run.addArg("MK_CTF=no");
    run.addArg("NO_XREF=yes");
    // BSD xargs -J and GNU xargs differ; -I is the portable spelling.
    run.addArg("XARGS_J=-I");
    // The host's objcopy and uudecode, wrapped for FreeBSD ELF output and
    // for uudecode -p (see kgen), and the tree's rpcgen, yacc and awk:
    // some module Makefiles call "rpcgen" (not ${RPCGEN}), and the host's
    // rpcgen may generate code for another RPC implementation.
    const wrappers: *Build.Step.WriteFile = b.addWriteFiles();
    _ = wrappers.addCopyFile(opts.kgen.getEmittedBin(), "objcopy");
    _ = wrappers.addCopyFile(opts.kgen.getEmittedBin(), "uudecode");
    _ = wrappers.addCopyFile(opts.hosttools.rpcgen.getEmittedBin(), "rpcgen");
    _ = wrappers.addCopyFile(opts.hosttools.yacc.getEmittedBin(), "yacc");
    _ = wrappers.addCopyFile(opts.hosttools.awk.getEmittedBin(), "awk");
    run.addPrefixedDirectoryArg("PATH+=", wrappers.getDirectory());
    run.addArg("OBJCOPY=objcopy");
    // The target compiler and linker.  `zig clang` needs the target here:
    // the host is not the machine the modules run on.
    run.addArg(b.fmt("CC={s} clang -target {s} -resource-dir={s}", .{ b.graph.zig_exe, opts.triple, zig_lib }));
    run.addArg(b.fmt("CXX={s} clang --driver-mode=g++ -target {s} -resource-dir={s}", .{ b.graph.zig_exe, opts.triple, zig_lib }));
    run.addArg(b.fmt("CPP={s} clang --driver-mode=cpp -target {s} -resource-dir={s}", .{ b.graph.zig_exe, opts.triple, zig_lib }));
    run.addArg("COMPILER_TYPE=clang");
    run.addArg(b.fmt("LD={s} ld.lld", .{b.graph.zig_exe}));
    // The generators the Makefiles call, built from the tree.
    run.addPrefixedFileArg("AWK=", opts.hosttools.awk.getEmittedBin());
    run.addPrefixedFileArg("YACC=", opts.hosttools.yacc.getEmittedBin());
    run.addPrefixedFileArg("RPCGEN=", opts.hosttools.rpcgen.getEmittedBin());
    run.addPrefixedDirectoryArg("KERNBUILDDIR=", opts.include);
    run.addArg("--");
    run.addArtifactArg(opts.hosttools.bmake);
    run.addArg("-C");
    run.addArg(b.fmt("{s}/sys/modules", .{tree}));
    const jobs: usize = Thread.getCpuCount() catch 1;
    run.addArgs(&.{ "-j", b.fmt("{d}", .{jobs}) });
    if (sel.override.len > 0) run.addArg(b.fmt("MODULES_OVERRIDE={s}", .{sel.override}));
    run.addArg("all");
    // bmake keeps its own object directories: the Zig build always asks
    // it, as it does for the world.
    run.has_side_effects = true;

    // The flat set of .ko files: the image reads it, and the install step
    // copies it to zig-out/boot/modules.
    const copy: *Build.Step.Run = b.addRunArtifact(opts.kgen);
    copy.addArg("copy-modules");
    copy.addArg(obj);
    const dir: LazyPath = copy.addOutputDirectoryArg("modules");
    for (sel.names) |name| copy.addArg(name);
    copy.step.dependOn(&run.step);
    const install: *Build.Step.InstallDir = b.addInstallDirectory(.{
        .source_dir = dir,
        .install_dir = .prefix,
        .install_subdir = "boot/modules",
    });
    return .{ .compile = &run.step, .install = &install.step, .dir = dir };
}
