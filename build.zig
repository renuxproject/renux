// SPDX-License-Identifier: BSD-2-Clause
//
// Copyright (c) 2026 The Renux Project
//
// The Renux build.
//
// Zig is the whole toolchain: the host needs nothing but this Zig, which
// compiles the C and assembly of the tree with the clang and lld it carries.
//
// Steps:
//   zig build kernel       the kernel, in zig-out/boot/kernel/kernel, and its
//                          debug file in zig-out/usr/lib/debug/boot/kernel/
//   zig build kconfig      the kernel configuration: the option headers and
//                          the list of files config(8) would select, in
//                          zig-out/kconfig/<KERNCONF>/
//   zig build hosttools    the host tools the build makes from the tree
//                          (yacc, awk, rpcgen), in zig-out/hosttools/
//
// Options:
//   -Dkernconf=NAME        kernel configuration (default: GENERIC)
//   -Dmachine=NAME         target machine (default: amd64)

const std = @import("std");
const kconfig = @import("tools/renux/kconfig.zig");
const hosttools = @import("tools/renux/hosttools.zig");
const kernel = @import("tools/renux/kernel.zig");

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
    const kernconf = b.option([]const u8, "kernconf", "Kernel configuration (default: GENERIC)") orelse "GENERIC";
    const machine = b.option([]const u8, "machine", "Target machine (default: amd64)") orelse "amd64";

    var tree: TreeReader = .{ .b = b };
    var diag: std.ArrayList(u8) = .empty;
    const cfg = kconfig.configure(b.allocator, .{ .ctx = &tree, .readFn = TreeReader.read }, machine, kernconf, &diag) catch |err| switch (err) {
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
    const tools_step = b.step("hosttools", "Build the host tools (yacc, awk, rpcgen) into zig-out/hosttools");
    for ([_]*std.Build.Step.Compile{ tools.yacc, tools.awk, tools.rpcgen }) |exe| {
        const inst = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "hosttools" } } });
        tools_step.dependOn(&inst.step);
    }

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
        .tools = tools,
        .kgen = kgen,
        .kernconf = kernconf,
        .revision = shellVar(newvers, "REVISION"),
    });
    const kernel_step = b.step("kernel", "Build the kernel into zig-out/boot/kernel");
    kernel_step.dependOn(&b.addInstallFile(k.kernel, "boot/kernel/kernel").step);
    kernel_step.dependOn(&b.addInstallFile(k.debug, "usr/lib/debug/boot/kernel/kernel.debug").step);
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
