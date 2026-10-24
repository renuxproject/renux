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
//   zig build world        the userland: FreeBSD's buildworld and
//                          installworld, run by bmake with Zig as the
//                          compiler, installed without root in the cache
//   zig build image        a bootable disk: the world, the kernel and the
//                          loader, in zig-out/renux-<version>-<machine>.img
//   zig build iso          the installer ISO (bsdinstall), in
//                          zig-out/renux-<version>-<machine>-installer.iso
//   zig build run          the disk in QEMU, with UEFI firmware (QEMU is
//                          the one program besides Zig the build may use,
//                          and only for this step)
//
// Options:
//   -Dkernconf=NAME        kernel configuration, a file of
//                          sys/<machine>/conf/ (default: GENERIC)
//   -Dmachine=NAME         target machine: amd64, arm64 or riscv (default:
//                          amd64; tools/renux/machine.zig says which the Zig
//                          build supports)

const std: type = @import("std");
const builtin: type = @import("builtin");
const mem: type = std.mem;
const fmt: type = std.fmt;
const ascii: type = std.ascii;
const debug: type = std.debug;
const process: type = std.process;
const enums: type = std.enums;
const Build: type = std.Build;
const Io: type = std.Io;
const SemanticVersion: type = std.SemanticVersion;

const kconfig: type = @import("tools/renux/kconfig.zig");
const hosttools: type = @import("tools/renux/hosttools.zig");
const kernel: type = @import("tools/renux/kernel.zig");
const stand: type = @import("tools/renux/stand.zig");
const world: type = @import("tools/renux/world.zig");
const machine_mod: type = @import("tools/renux/machine.zig");
const Machine: type = machine_mod.Machine;

/// Each series of Renux is built by one series of Zig, and carries it:
/// Renux 0.1 by Zig 0.17.x (0.17.0, then its fixes), Renux 0.2 by Zig
/// 0.18.  A Zig of another series stops the build here, rather than in
/// the middle of it.
const renux_version: []const u8 = "0.1-CURRENT";
/// Each series of Renux has a codename too, in alphabetical order.
const renux_codename: []const u8 = "Aurora";
const zig_series: SemanticVersion = .{
    .major = 0,
    .minor = 17,
    .patch = 0,
};

comptime {
    const v: SemanticVersion = builtin.zig_version;
    if (v.major != zig_series.major or v.minor != zig_series.minor)
        @compileError(fmt.comptimePrint(
            "Renux {s} \"{s}\" is built by Zig {d}.{d}.x, and this is Zig {s}",
            .{ renux_version, renux_codename, zig_series.major, zig_series.minor, builtin.zig_version_string },
        ));
}

/// Reads files of the source tree for kconfig, and records each one as an
/// input of the configuration, so that `zig build` configures again when
/// one changes.
const TreeReader: type = struct {
    b: *Build,

    fn read(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *TreeReader = @ptrCast(@alignCast(ctx));
        const b: *Build = self.b;
        const full: Build.Cache.Path = b.root.join(b.allocator, path) catch @panic("OOM");
        const text: []u8 = full.root_dir.handle.readFileAlloc(b.graph.io, full.sub_path, b.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => debug.panic("reading {s}: {t}", .{ path, err }),
        };
        b.dependOnFileContents(b.path(path));
        return text;
    }
};

pub fn build(b: *Build) void {
    const machine: Machine = b.option(Machine, "machine", "Target machine (default: amd64)") orelse .amd64;
    const kernconf: []const u8 = b.option([]const u8, "kernconf", "Kernel configuration in sys/<machine>/conf (default: GENERIC)") orelse "GENERIC";
    if (machine.config() == null) {
        debug.print("error: the Zig build does not support {s} yet; it supports:\n", .{machine.name()});
        for (enums.values(Machine)) |m| if (m.config() != null) debug.print("  {s}\n", .{m.name()});
        process.exit(1);
    }
    checkKernconf(b, machine, kernconf);

    var tree: TreeReader = .{ .b = b };
    var diag: std.ArrayList(u8) = .empty;
    const cfg: kconfig.Config = kconfig.configure(b.allocator, .{ .ctx = &tree, .readFn = TreeReader.read }, machine.name(), kernconf, &diag) catch |err| switch (err) {
        error.ConfigError => debug.panic("{s}", .{diag.items}),
        error.OutOfMemory => @panic("OOM"),
    };

    const kconfig_step: *Build.Step = b.step("kconfig", "Write the kernel configuration to zig-out/kconfig/<KERNCONF>");
    const wf: *Build.Step.WriteFile = b.addWriteFiles();
    for (cfg.headers.items) |h| {
        var text: std.ArrayList(u8) = .empty;
        for (h.defines.items) |d| text.print(b.allocator, "#define {s} {s}\n", .{ d.name, d.value.? }) catch @panic("OOM");
        _ = wf.add(h.name, text.items);
    }
    _ = wf.add("files.txt", fileLists(b, &cfg));
    _ = wf.add("config.c", cfg.config_c);
    _ = wf.add("env.c", cfg.env_c);
    _ = wf.add("hints.c", cfg.hints_c);
    const install: *Build.Step.InstallDir = b.addInstallDirectory(.{
        .source_dir = wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = b.fmt("kconfig/{s}", .{kernconf}),
    });
    kconfig_step.dependOn(&install.step);

    const tools: hosttools.HostTools = hosttools.build(b);
    const tools_step: *Build.Step = b.step("hosttools", "Build the host tools (yacc, awk, rpcgen, vtfontcvt, bmake) into zig-out/hosttools");
    for ([_]*Build.Step.Compile{ tools.yacc, tools.awk, tools.rpcgen, tools.vtfontcvt, tools.bmake }) |exe| {
        const inst: *Build.Step.InstallArtifact = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "hosttools" } } });
        tools_step.dependOn(&inst.step);
    }
    const bmake_step: *Build.Step = b.step("bmake", "Build bmake, FreeBSD's make, into zig-out/hosttools");
    bmake_step.dependOn(&b.addInstallArtifact(tools.bmake, .{ .dest_dir = .{ .override = .{ .custom = "hosttools" } } }).step);

    // The kernel, installed where the system keeps it.
    const kgen: *Build.Step.Compile = b.addExecutable(.{
        .name = "kgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/renux/kgen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const newvers: []const u8 = TreeReader.read(&tree, "sys/conf/newvers.sh") orelse @panic("no sys/conf/newvers.sh");
    const k: kernel.Kernel = kernel.build(b, .{
        .cfg = &cfg,
        .machine = machine,
        .tools = tools,
        .kgen = kgen,
        .kernconf = kernconf,
        .revision = shellVar(newvers, "REVISION"),
    });
    const kernel_step: *Build.Step = b.step("kernel", "Build the kernel into zig-out/boot/kernel");
    kernel_step.dependOn(&b.addInstallFile(k.kernel, "boot/kernel/kernel").step);
    kernel_step.dependOn(&b.addInstallFile(k.debug, "usr/lib/debug/boot/kernel/kernel.debug").step);

    // The EFI loader and what it reads from /boot.
    const l: stand.Loader = stand.build(b, .{ .machine = machine, .tools = tools, .kgen = kgen, .revision = shellVar(newvers, "REVISION") });
    const loader_step: *Build.Step = b.step("loader", "Build the EFI loader into zig-out/boot");
    loader_step.dependOn(&b.addInstallFile(l.efi, "boot/loader.efi").step);
    loader_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("stand/lua"),
        .install_dir = .prefix,
        .install_subdir = "boot/lua",
        .include_extensions = &.{".lua"},
    }).step);
    loader_step.dependOn(&b.addInstallFile(b.path("stand/defaults/loader.conf"), "boot/defaults/loader.conf").step);
    loader_step.dependOn(&b.addInstallFile(b.path(b.fmt("sys/{s}/conf/GENERIC.hints", .{machine.name()})), "boot/device.hints").step);

    // The userland.
    const w: world.World = world.build(b, .{ .machine = machine, .bmake = tools.bmake, .kgen = kgen });
    const world_step: *Build.Step = b.step("world", "Build the userland and install it, without root, in the build's cache");
    world_step.dependOn(w.install);

    // The media: a bootable disk, and an installer ISO.
    const config: machine_mod.Config = machine.config().?;
    const image_exe: *Build.Step.Compile = b.addExecutable(.{
        .name = "image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/renux/image.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const image: Build.LazyPath = medium(b, image_exe, "disk", "renux.img", w, k, l, machine, config, .{ .string = w.mkimg }, null);
    const install_image: *Build.Step.InstallFile = b.addInstallFile(image, b.fmt("renux-{s}-{s}.img", .{ renux_version, machine.name() }));
    const image_step: *Build.Step = b.step("image", "Make a bootable disk in zig-out/renux-<version>-<machine>.img");
    image_step.dependOn(&install_image.step);
    const iso: Build.LazyPath = medium(b, image_exe, "iso", "renux.iso", w, k, l, machine, config, .{ .file = b.path("release/rc.local") }, b.path("tools/renux/installer"));
    const install_iso: *Build.Step.InstallFile = b.addInstallFile(iso, b.fmt("renux-{s}-{s}-installer.iso", .{ renux_version, machine.name() }));
    const iso_step: *Build.Step = b.step("iso", "Make the installer ISO in zig-out/renux-<version>-<machine>-installer.iso");
    iso_step.dependOn(&install_iso.step);

    // The disk in QEMU.  -snapshot: what Renux writes is thrown away, and
    // the firmware's variables too.
    const run_step: *Build.Step = b.step("run", "Run the disk in QEMU with UEFI firmware");
    if (findFirmware(b, config)) |firmware| {
        const qemu: *Build.Step.Run = b.addSystemCommand(&.{config.qemu});
        qemu.addArgs(config.qemu_args);
        qemu.addArgs(&.{ "-accel", "kvm", "-accel", "hvf", "-accel", "tcg", "-smp", "2", "-m", "2048", "-snapshot" });
        qemu.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{firmware[0]}) });
        qemu.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,file={s}", .{firmware[1]}) });
        qemu.addArg("-drive");
        qemu.addPrefixedFileArg("if=virtio,format=raw,file=", image);
        qemu.addArgs(&.{ "-nic", "user,model=virtio-net-pci", "-vga", "std" });
        qemu.has_side_effects = true;
        qemu.step.dependOn(&install_image.step);
        run_step.dependOn(&qemu.step);
    } else {
        run_step.dependOn(&b.addFail(b.fmt("no UEFI firmware for {s} found; install QEMU's (EDK II OVMF)", .{config.qemu})).step);
    }

    // `zig build`: the kernel and the loader.
    b.getInstallStep().dependOn(kernel_step);
    b.getInstallStep().dependOn(loader_step);
}

/// The last argument of a medium: a path outside the build (mkimg), or a
/// file of the tree (the ISO's rc.local).
const LastArg: type = union(enum) {
    string: []const u8,
    file: Build.LazyPath,
};

/// A medium of image.zig (disk or iso), made from the world, the kernel and
/// the loader; last is the medium's last argument (mkimg, or the ISO's
/// rc.local).
fn medium(
    b: *Build,
    image_exe: *Build.Step.Compile,
    kind: []const u8,
    name: []const u8,
    w: world.World,
    k: kernel.Kernel,
    l: stand.Loader,
    machine: Machine,
    config: machine_mod.Config,
    last: LastArg,
    /// The ISO's: the Renux installer's welcome, languages and notes.
    installer: ?Build.LazyPath,
) Build.LazyPath {
    const run: *Build.Step.Run = b.addRunArtifact(image_exe);
    run.addArg(kind);
    const out: Build.LazyPath = run.addOutputFileArg(name);
    _ = run.addOutputDirectoryArg("stage");
    run.addArgs(&.{ w.makefs, w.destdir });
    run.addFileArg(k.kernel);
    run.addFileArg(l.efi);
    run.addDirectoryArg(b.path("stand/lua"));
    run.addFileArg(b.path("stand/defaults/loader.conf"));
    run.addFileArg(b.path(b.fmt("sys/{s}/conf/GENERIC.hints", .{machine.name()})));
    run.addArg(config.efi_boot);
    switch (last) {
        .string => |str| run.addArg(str),
        .file => |file| run.addFileArg(file),
    }
    if (installer) |dir| run.addDirectoryArg(dir);
    // The world is outside the Zig build's view: make the medium again
    // whenever it is asked for.
    run.has_side_effects = true;
    run.step.dependOn(w.install);
    return out;
}

/// QEMU's UEFI firmware for the machine, where the host has it.
fn findFirmware(b: *Build, config: machine_mod.Config) ?[2][]const u8 {
    for (config.firmware) |f| {
        const code_ok: bool = if (Io.Dir.cwd().access(b.graph.io, f[0], .{})) |_| true else |_| false;
        const vars_ok: bool = if (Io.Dir.cwd().access(b.graph.io, f[1], .{})) |_| true else |_| false;
        if (code_ok and vars_ok) return f;
    }
    return null;
}

/// -Dkernconf must name a kernel configuration of sys/<machine>/conf; say
/// which there are when it does not.
fn checkKernconf(b: *Build, machine: Machine, kernconf: []const u8) void {
    const conf: []u8 = b.fmt("sys/{s}/conf", .{machine.name()});
    const path: Build.Cache.Path = b.root.join(b.allocator, conf) catch @panic("OOM");
    var dir: Io.Dir = path.root_dir.handle.openDir(b.graph.io, path.sub_path, .{ .iterate = true }) catch |err|
        debug.panic("{s}: {t}", .{ conf, err });
    defer dir.close(b.graph.io);
    b.dependOnDirectoryContents(b.path(conf));

    // Configurations are the files of conf/ but DEFAULTS, NOTES (the
    // documentation of every option) and hints files.
    var names: std.ArrayList([]const u8) = .empty;
    var it: Io.Dir.Iterator = dir.iterate();
    while (it.next(b.graph.io) catch |err| debug.panic("{s}: {t}", .{ conf, err })) |e| {
        if (e.kind != .file) continue;
        if (mem.eql(u8, e.name, "DEFAULTS") or mem.eql(u8, e.name, "NOTES")) continue;
        if (mem.indexOfScalar(u8, e.name, '.') != null) continue;
        if (mem.eql(u8, e.name, kernconf)) return;
        names.append(b.allocator, b.dupe(e.name)) catch @panic("OOM");
    }
    mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return mem.order(u8, a, c) == .lt;
        }
    }.lt);
    debug.print("error: no kernel configuration {s} in {s}; there are:\n", .{ kernconf, conf });
    for (names.items) |n| debug.print("  {s}\n", .{n});
    process.exit(1);
}

/// The value of NAME="..." in a shell script.
fn shellVar(text: []const u8, name: []const u8) []const u8 {
    var it: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!mem.startsWith(u8, line, name) or line.len < name.len + 2) continue;
        if (line[name.len] != '=' or line[name.len + 1] != '"') continue;
        const rest: []const u8 = line[name.len + 2 ..];
        return rest[0 .. mem.indexOfScalar(u8, rest, '"') orelse rest.len];
    }
    debug.panic("no {s}= in sys/conf/newvers.sh", .{name});
}

/// One line of text at the end of out.
fn putLine(out: *std.ArrayList(u8), gpa: mem.Allocator, comptime format: []const u8, args: anytype) void {
    out.print(gpa, format ++ "\n", args) catch @panic("OOM");
}

/// The lists config(8) writes into the kernel's Makefile, one name per
/// line under a "[NAME]" heading.
fn fileLists(b: *Build, cfg: *const kconfig.Config) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const gpa: mem.Allocator = b.allocator;

    putLine(&out, gpa, "[BEFORE_DEPEND]", .{});
    for (cfg.files.items) |f| if (f.before_depend) {
        if (f.no_implicit_rule) putLine(&out, gpa, "{s}", .{f.path}) else putLine(&out, gpa, "{s}{s}", .{ f.srcprefix, f.path });
    };
    putLine(&out, gpa, "[OBJS]", .{});
    for (cfg.files.items) |f| if (!f.no_obj) putLine(&out, gpa, "{s}", .{f.object(gpa) catch @panic("OOM")});
    for ([_][]const u8{ "c", "s", "m" }) |suffix| {
        putLine(&out, gpa, "[{s}FILES]", .{if (suffix[0] == 'c') "C" else if (suffix[0] == 's') "S" else "M"});
        for (cfg.files.items) |f| {
            if (f.no_depend or !ascii.eqlIgnoreCase(f.suffix(), suffix)) continue;
            putLine(&out, gpa, "{s}{s}", .{ f.srcprefix, f.path });
        }
    }
    return out.items;
}
