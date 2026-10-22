// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// The Renux build.
//
// Zig is the whole toolchain: the host needs nothing but this Zig, which
// compiles the C and assembly of the tree with the clang and lld it carries.
//
// Steps:
//   zig build              the kernel and the loader (the default)
//   zig build kernel       the kernel, in zig-out/boot/kernel/kernel, and its
//                          debug file in zig-out/usr/lib/debug/boot/kernel/
//   zig build loader       the EFI loader, in zig-out/boot/loader.efi, with the
//                          Lua scripts and files it reads from /boot
//   zig build kconfig      the kernel configuration: the option headers and
//                          the list of files config(8) would select, in
//                          zig-out/kconfig/<KERNCONF>/
//   zig build hosttools    the host tools the build makes from the tree
//                          (yacc, awk, rpcgen, vtfontcvt, bmake), in
//                          zig-out/hosttools/
//   zig build bmake        bmake alone, in zig-out/hosttools/
//
// Options:
//   -Dkernconf=NAME        kernel configuration, a file of
//                          sys/<machine>/conf/ (default: GENERIC)
//   -Dmachine=NAME         target machine: amd64, arm64 or riscv (default:
//                          amd64; tools/renux/machine.zig says which the Zig
//                          build supports)

const std = @import("std");
const kconfig = @import("tools/renux/kconfig.zig");
const hosttools = @import("tools/renux/hosttools.zig");
const kernel = @import("tools/renux/kernel.zig");
const stand = @import("tools/renux/stand.zig");
const Machine = @import("tools/renux/machine.zig").Machine;

/// Reads files of the source tree for kconfig, and records each one as an
/// input of the configuration, so that `zig build` configures again when
/// one changes.
const TreeReader = struct {
    b: *std.Build,

    fn read(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *TreeReader = @ptrCast(@alignCast(ctx));
        const b = self.b;
        const full = b.root.join(b.allocator, path) catch @panic("OOM");
        const text = full.root_dir.handle.readFileAlloc(b.graph.io, full.sub_path, b.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => std.debug.panic("reading {s}: {t}", .{ path, err }),
        };
        b.dependOnFileContents(b.path(path));
        return text;
    }
};

pub fn build(b: *std.Build) void {
    const machine = b.option(Machine, "machine", "Target machine (default: amd64)") orelse .amd64;
    const kernconf = b.option([]const u8, "kernconf", "Kernel configuration in sys/<machine>/conf (default: GENERIC)") orelse "GENERIC";
    if (machine.config() == null) {
        std.debug.print("error: the Zig build does not support {s} yet; it supports:\n", .{machine.name()});
        for (std.enums.values(Machine)) |m| if (m.config() != null) std.debug.print("  {s}\n", .{m.name()});
        std.process.exit(1);
    }
    checkKernconf(b, machine, kernconf);

    var tree: TreeReader = .{ .b = b };
    var diag: std.ArrayList(u8) = .empty;
    const cfg = kconfig.configure(b.allocator, .{ .ctx = &tree, .readFn = TreeReader.read }, machine.name(), kernconf, &diag) catch |err| switch (err) {
        error.ConfigError => std.debug.panic("{s}", .{diag.items}),
        error.OutOfMemory => @panic("OOM"),
    };

    const kconfig_step = b.step("kconfig", "Write the kernel configuration to zig-out/kconfig/<KERNCONF>");
    const wf = b.addWriteFiles();
    for (cfg.headers.items) |h| {
        var text: std.ArrayList(u8) = .empty;
        for (h.defines.items) |d| text.print(b.allocator, "#define {s} {s}\n", .{ d.name, d.value.? }) catch @panic("OOM");
        _ = wf.add(h.name, text.items);
    }
    _ = wf.add("files.txt", fileLists(b, &cfg));
    _ = wf.add("config.c", cfg.config_c);
    _ = wf.add("env.c", cfg.env_c);
    _ = wf.add("hints.c", cfg.hints_c);
    const install = b.addInstallDirectory(.{
        .source_dir = wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = b.fmt("kconfig/{s}", .{kernconf}),
    });
    kconfig_step.dependOn(&install.step);

    const tools = hosttools.build(b);
    const tools_step = b.step("hosttools", "Build the host tools (yacc, awk, rpcgen, vtfontcvt, bmake) into zig-out/hosttools");
    for ([_]*std.Build.Step.Compile{ tools.yacc, tools.awk, tools.rpcgen, tools.vtfontcvt, tools.bmake }) |exe| {
        const inst = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "hosttools" } } });
        tools_step.dependOn(&inst.step);
    }
    const bmake_step = b.step("bmake", "Build bmake, FreeBSD's make, into zig-out/hosttools");
    bmake_step.dependOn(&b.addInstallArtifact(tools.bmake, .{ .dest_dir = .{ .override = .{ .custom = "hosttools" } } }).step);

    // The kernel, installed where the system keeps it.
    const kgen = b.addExecutable(.{
        .name = "kgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/renux/kgen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const newvers = TreeReader.read(&tree, "sys/conf/newvers.sh") orelse @panic("no sys/conf/newvers.sh");
    const k = kernel.build(b, .{
        .cfg = &cfg,
        .machine = machine,
        .tools = tools,
        .kgen = kgen,
        .kernconf = kernconf,
        .revision = shellVar(newvers, "REVISION"),
    });
    const kernel_step = b.step("kernel", "Build the kernel into zig-out/boot/kernel");
    kernel_step.dependOn(&b.addInstallFile(k.kernel, "boot/kernel/kernel").step);
    kernel_step.dependOn(&b.addInstallFile(k.debug, "usr/lib/debug/boot/kernel/kernel.debug").step);

    // The EFI loader and what it reads from /boot.
    const l = stand.build(b, .{ .machine = machine, .tools = tools, .kgen = kgen, .revision = shellVar(newvers, "REVISION") });
    const loader_step = b.step("loader", "Build the EFI loader into zig-out/boot");
    loader_step.dependOn(&b.addInstallFile(l.efi, "boot/loader.efi").step);
    loader_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("stand/lua"),
        .install_dir = .prefix,
        .install_subdir = "boot/lua",
        .include_extensions = &.{".lua"},
    }).step);
    loader_step.dependOn(&b.addInstallFile(b.path("stand/defaults/loader.conf"), "boot/defaults/loader.conf").step);
    loader_step.dependOn(&b.addInstallFile(b.path(b.fmt("sys/{s}/conf/GENERIC.hints", .{machine.name()})), "boot/device.hints").step);

    // `zig build`: the kernel and the loader.
    b.getInstallStep().dependOn(kernel_step);
    b.getInstallStep().dependOn(loader_step);
}

/// -Dkernconf must name a kernel configuration of sys/<machine>/conf; say
/// which there are when it does not.
fn checkKernconf(b: *std.Build, machine: Machine, kernconf: []const u8) void {
    const conf = b.fmt("sys/{s}/conf", .{machine.name()});
    const path = b.root.join(b.allocator, conf) catch @panic("OOM");
    var dir = path.root_dir.handle.openDir(b.graph.io, path.sub_path, .{ .iterate = true }) catch |err|
        std.debug.panic("{s}: {t}", .{ conf, err });
    defer dir.close(b.graph.io);
    b.dependOnDirectoryContents(b.path(conf));

    // Configurations are the files of conf/ but DEFAULTS, NOTES (the
    // documentation of every option) and hints files.
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(b.graph.io) catch |err| std.debug.panic("{s}: {t}", .{ conf, err })) |e| {
        if (e.kind != .file) continue;
        if (std.mem.eql(u8, e.name, "DEFAULTS") or std.mem.eql(u8, e.name, "NOTES")) continue;
        if (std.mem.indexOfScalar(u8, e.name, '.') != null) continue;
        if (std.mem.eql(u8, e.name, kernconf)) return;
        names.append(b.allocator, b.dupe(e.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.order(u8, a, c) == .lt;
        }
    }.lt);
    std.debug.print("error: no kernel configuration {s} in {s}; there are:\n", .{ kernconf, conf });
    for (names.items) |n| std.debug.print("  {s}\n", .{n});
    std.process.exit(1);
}

/// The value of NAME="..." in a shell script.
fn shellVar(text: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, name) or line.len < name.len + 2) continue;
        if (line[name.len] != '=' or line[name.len + 1] != '"') continue;
        const rest = line[name.len + 2 ..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse rest.len];
    }
    std.debug.panic("no {s}= in sys/conf/newvers.sh", .{name});
}

/// The lists config(8) writes into the kernel's Makefile, one name per
/// line under a "[NAME]" heading.
fn fileLists(b: *std.Build, cfg: *const kconfig.Config) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const gpa = b.allocator;
    const p = struct {
        fn line(o: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
            o.print(a, fmt ++ "\n", args) catch @panic("OOM");
        }
    }.line;

    p(&out, gpa, "[BEFORE_DEPEND]", .{});
    for (cfg.files.items) |f| if (f.before_depend) {
        if (f.no_implicit_rule) p(&out, gpa, "{s}", .{f.path}) else p(&out, gpa, "{s}{s}", .{ f.srcprefix, f.path });
    };
    p(&out, gpa, "[OBJS]", .{});
    for (cfg.files.items) |f| if (!f.no_obj) p(&out, gpa, "{s}", .{f.object(gpa) catch @panic("OOM")});
    for ([_][]const u8{ "c", "s", "m" }) |suffix| {
        p(&out, gpa, "[{s}FILES]", .{if (suffix[0] == 'c') "C" else if (suffix[0] == 's') "S" else "M"});
        for (cfg.files.items) |f| {
            if (f.no_depend or !std.ascii.eqlIgnoreCase(f.suffix(), suffix)) continue;
            p(&out, gpa, "{s}{s}", .{ f.srcprefix, f.path });
        }
    }
    return out.items;
}
