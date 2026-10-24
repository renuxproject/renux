// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// image.zig - a bootable disk of Renux: a GPT disk with an EFI system
// partition, holding the loader, and a UFS root, holding the world, the
// kernel and what the loader reads from /boot.
//
//   image OUT STAGE MAKEFS MKIMG DESTDIR KERNEL LOADER LUA DEFAULTS HINTS EFIBOOT
//
// DESTDIR is the world installed with -DNO_ROOT: its METALOG gives the
// owners and modes, since the build runs without root.  The files of the
// Zig build (the kernel, what the loader reads) and the few a disk needs
// and a world has not (/etc/fstab, /etc/rc.conf) are put in DESTDIR, as
// installkernel would, and added to that list.  STAGE holds the list and
// the partitions.

const std: type = @import("std");
const mem: type = std.mem;
const fmt: type = std.fmt;
const fs: type = std.fs;
const debug: type = std.debug;
const process: type = std.process;
const Io: type = std.Io;
const Allocator: type = mem.Allocator;

var io: Io = undefined;
var gpa: Allocator = undefined;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    debug.print("image: " ++ format ++ "\n", args);
    process.exit(1);
}

fn absolute(path: []const u8) []const u8 {
    return Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| fatal("{s}: {t}", .{ path, err });
}

fn writeFile(path: []const u8, data: []const u8) void {
    if (fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch |err| fatal("{s}: {t}", .{ dir, err });
    // A file installworld made read-only is replaced, as install(1) does.
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => fatal("{s}: {t}", .{ path, err }),
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |err| fatal("{s}: {t}", .{ path, err });
}

fn run(argv: []const []const u8) void {
    const r: process.RunResult = process.run(gpa, io, .{ .argv = argv }) catch |err| fatal("{s}: {t}", .{ argv[0], err });
    switch (r.term) {
        .exited => |code| if (code != 0) {
            debug.print("{s}{s}", .{ r.stdout, r.stderr });
            fatal("{s} exited with {d}", .{ argv[0], code });
        },
        else => fatal("{s} failed", .{argv[0]}),
    }
}

/// The root's DESTDIR, for entry().
var root: []const u8 = undefined;

/// Put a file (or, with no data, a directory) in the root, and in its list.
fn entry(spec: *std.ArrayList(u8), path: []const u8, mode: []const u8, data: ?[]const u8) void {
    const full: []const u8 = fs.path.join(gpa, &.{ root, path }) catch @panic("OOM");
    if (data) |d| {
        writeFile(full, d);
        spec.print(gpa, "./{s} type=file uname=root gname=wheel mode={s}\n", .{ path, mode }) catch @panic("OOM");
    } else {
        Io.Dir.cwd().createDirPath(io, full) catch |err| fatal("{s}: {t}", .{ full, err });
        spec.print(gpa, "./{s} type=dir uname=root gname=wheel mode={s}\n", .{ path, mode }) catch @panic("OOM");
    }
}

fn readFile(path: []const u8) []u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| fatal("{s}: {t}", .{ path, err });
}

/// Whether line a comes before line b: by path, so that a directory comes
/// before what it holds ("./a" is a prefix of "./a/b").
fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    const a_path: []const u8 = a[0 .. mem.indexOfScalar(u8, a, ' ') orelse a.len];
    const b_path: []const u8 = b[0 .. mem.indexOfScalar(u8, b, ' ') orelse b.len];
    return mem.order(u8, a_path, b_path) == .lt;
}

/// The METALOG's entries, in an order makefs takes: installworld writes
/// them as it installs, and a file may come before its directory.  The
/// debug files (/usr/lib/debug) stay out of the disk, as in FreeBSD's
/// releases, which ship them apart.
fn appendMetalog(spec: *std.ArrayList(u8), metalog: []const u8) void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, metalog, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') {
            spec.print(gpa, "{s}\n", .{line}) catch @panic("OOM");
            continue;
        }
        if (mem.startsWith(u8, line, "./usr/lib/debug/")) continue;
        lines.append(gpa, line) catch @panic("OOM");
    }
    mem.sort([]const u8, lines.items, {}, pathLess);
    for (lines.items) |line| spec.print(gpa, "{s}\n", .{line}) catch @panic("OOM");
}

pub fn main(init: process.Init) void {
    io = init.io;
    gpa = init.arena.allocator();
    const args: []const [:0]const u8 = init.minimal.args.toSlice(gpa) catch @panic("OOM");
    if (args.len != 12) fatal("usage: image OUT STAGE MAKEFS MKIMG DESTDIR KERNEL LOADER LUA DEFAULTS HINTS EFIBOOT", .{});
    const out: []const u8 = args[1];
    const stage: []const u8 = args[2];
    const makefs: []const u8 = args[3];
    const mkimg: []const u8 = args[4];
    const destdir: []const u8 = args[5];
    const kernel: []const u8 = absolute(args[6]);
    const loader: []const u8 = absolute(args[7]);
    const lua: []const u8 = absolute(args[8]);
    const defaults: []const u8 = absolute(args[9]);
    const hints: []const u8 = absolute(args[10]);
    const efi_boot: []const u8 = args[11];

    root = destdir;

    // The root's file list: the world's METALOG, then the Zig build's.
    const metalog_path: []const u8 = fmt.allocPrint(gpa, "{s}/METALOG", .{destdir}) catch @panic("OOM");
    const metalog: []u8 = Io.Dir.cwd().readFileAlloc(io, metalog_path, gpa, .unlimited) catch |err| fatal("{s}: {t}", .{ metalog_path, err });
    var spec: std.ArrayList(u8) = .empty;
    appendMetalog(&spec, metalog);
    entry(&spec, "boot/kernel", "0755", null);
    entry(&spec, "boot/kernel/kernel", "0555", readFile(kernel));
    entry(&spec, "boot/defaults", "0755", null);
    entry(&spec, "boot/defaults/loader.conf", "0444", readFile(defaults));
    entry(&spec, "boot/device.hints", "0444", readFile(hints));
    entry(&spec, "boot/lua", "0755", null);
    var lua_dir: Io.Dir = Io.Dir.cwd().openDir(io, lua, .{ .iterate = true }) catch |err| fatal("{s}: {t}", .{ lua, err });
    defer lua_dir.close(io);
    var it: Io.Dir.Iterator = lua_dir.iterate();
    while (it.next(io) catch |err| fatal("{s}: {t}", .{ lua, err })) |e| {
        if (e.kind != .file or !mem.endsWith(u8, e.name, ".lua")) continue;
        const path: []const u8 = fmt.allocPrint(gpa, "boot/lua/{s}", .{e.name}) catch @panic("OOM");
        const source: []const u8 = fs.path.join(gpa, &.{ lua, e.name }) catch @panic("OOM");
        entry(&spec, path, "0444", readFile(source));
    }
    // What a disk needs and the world has not.
    entry(&spec, "etc/fstab", "0644", "# Device\tMountpoint\tFStype\tOptions\tDump\tPass#\n/dev/gpt/rootfs\t/\tufs\trw\t1\t1\n");
    entry(&spec, "etc/rc.conf", "0644", "hostname=\"renux\"\n");
    const spec_path: []const u8 = fmt.allocPrint(gpa, "{s}/root.mtree", .{stage}) catch @panic("OOM");
    writeFile(spec_path, spec.items);

    // The root, as FreeBSD's release makes it (release/tools/vmimage.subr).
    const root_img: []const u8 = fmt.allocPrint(gpa, "{s}/root.img", .{stage}) catch @panic("OOM");
    const etc: []const u8 = fmt.allocPrint(gpa, "{s}/etc", .{destdir}) catch @panic("OOM");
    run(&.{ makefs, "-D", "-N", etc, "-B", "little", "-t", "ffs", "-o", "version=2,label=rootfs,softupdates=1", "-b", "30%", "-f", "30%", "-F", spec_path, root_img, destdir });

    // The EFI system partition: the loader as the default boot program.
    const esp_dir: []const u8 = fmt.allocPrint(gpa, "{s}/esp", .{stage}) catch @panic("OOM");
    const boot_efi: []const u8 = fmt.allocPrint(gpa, "{s}/EFI/BOOT/{s}", .{ esp_dir, efi_boot }) catch @panic("OOM");
    writeFile(boot_efi, readFile(loader));
    const esp_img: []const u8 = fmt.allocPrint(gpa, "{s}/esp.img", .{stage}) catch @panic("OOM");
    run(&.{ makefs, "-t", "msdos", "-s", "64m", "-o", "fat_type=16,volume_label=EFISYS", esp_img, esp_dir });

    const esp_part: []const u8 = fmt.allocPrint(gpa, "efi/efiesp:={s}", .{esp_img}) catch @panic("OOM");
    const root_part: []const u8 = fmt.allocPrint(gpa, "freebsd-ufs/rootfs:={s}", .{root_img}) catch @panic("OOM");
    run(&.{ mkimg, "-s", "gpt", "-p", esp_part, "-p", root_part, "-o", out });
}
