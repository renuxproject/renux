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
// The modules are compiled, not installed: the .ko files stay in the
// object directory (.zig-cache/modules/obj/.../sys/modules/<name>/).
// Wiring them into the image comes next.

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

/// The absolute path of the source tree.  `joinString` keeps the path the
/// build was given: it does not call realpath(2), which not every host (or
/// Linux compatibility layer) implements for a directory handle.
fn treeDir(b: *Build) []const u8 {
    if (b.root.root_dir.path) |p| return p;
    return b.root.joinString(b.allocator, "") catch @panic("OOM");
}

/// "zfs,if_bridge" -> "zfs if_bridge"; "all" -> "" (no override).
fn moduleList(b: *Build, selection: []const u8) []const u8 {
    if (mem.eql(u8, selection, "all")) return "";
    var parts: std.ArrayList([]const u8) = .empty;
    var it: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, selection, ',');
    while (it.next()) |part| {
        const name: []const u8 = mem.trim(u8, part, " \t");
        if (name.len > 0) parts.append(b.allocator, name) catch @panic("OOM");
    }
    return mem.join(b.allocator, " ", parts.items) catch @panic("OOM");
}

/// The `modules` step: bmake -C sys/modules all, with KERNBUILDDIR set
/// to the kernel's generated headers and MODULES_OVERRIDE to the
/// selected modules.
pub fn build(b: *Build, opts: Options) *Build.Step {
    const tree: []const u8 = treeDir(b);
    const obj: []const u8 = b.fmt("{s}/.zig-cache/modules/obj", .{tree});
    const zig_lib: []const u8 = b.fmt("{s}/lib", .{std.fs.path.dirname(b.graph.zig_exe) orelse "."});

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
    // GNU objcopy has no elf64-x86-64-freebsd target (the linux module's
    // 32-bit vDSO needs it), and it cannot write the FreeBSD OSABI.
    run.addArg("OBJCOPY=llvm-objcopy");
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
    const list: []const u8 = moduleList(b, opts.selection);
    if (list.len > 0) run.addArg(b.fmt("MODULES_OVERRIDE={s}", .{list}));
    run.addArg("all");
    // bmake keeps its own object directories: the Zig build always asks
    // it, as it does for the world.
    run.has_side_effects = true;
    return &run.step;
}
