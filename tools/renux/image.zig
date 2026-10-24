// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// image.zig - Renux's media: a bootable disk, and an installer ISO.
//
//   image disk OUT STAGE MAKEFS DESTDIR KERNEL LOADER LUA DEFAULTS HINTS EFIBOOT MKIMG
//   image iso  OUT STAGE MAKEFS DESTDIR KERNEL LOADER LUA DEFAULTS HINTS EFIBOOT RCLOCAL INSTALLER
//
// disk: a GPT disk, an EFI system partition holding the loader and a UFS
// root holding the world, the kernel and what the loader reads from /boot
// (release/tools/vmimage.subr).
//
// iso: FreeBSD's disc1 (release/Makefile, release/amd64/mkisoimages.sh): a
// CD that boots by UEFI into the live system, which starts the installer
// (bsdinstall, named Renux by OSNAME, with Renux's welcome and languages,
// INSTALLER, in /usr/libexec/renux-installer); the installer configures the disk
// and the network and installs the distribution sets base.txz and
// kernel.txz from /usr/freebsd-dist.  The sets are made by bsdtar from
// the METALOG, as FreeBSD's packageworld does.
//
// DESTDIR is the world installed with -DNO_ROOT: its METALOG gives the
// owners and modes, since the build runs without root.  Each medium gets
// its own copy of the world in STAGE, made of hard links: files are only
// ever replaced there (writeFile removes first), so DESTDIR stays as
// installworld left it.  The files of the Zig build (the kernel, what the
// loader reads) and those a medium needs are added to the copy and to its
// list.

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

/// A line of the METALOG without its size=: makefs and bsdtar take that
/// many bytes of the file, and a file replaced after installworld (a
/// script of bsdinstall Renux changed) would be cut.
fn withoutSize(line: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it: mem.TokenIterator(u8, .scalar) = mem.tokenizeScalar(u8, line, ' ');
    while (it.next()) |word| {
        if (mem.startsWith(u8, word, "size=")) continue;
        if (out.items.len > 0) out.append(gpa, ' ') catch @panic("OOM");
        out.appendSlice(gpa, word) catch @panic("OOM");
    }
    return out.items;
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
        lines.append(gpa, withoutSize(line)) catch @panic("OOM");
    }
    mem.sort([]const u8, lines.items, {}, pathLess);
    for (lines.items) |line| spec.print(gpa, "{s}\n", .{line}) catch @panic("OOM");
}

/// A copy of the tree src in dst, made of hard links (and of the same
/// symbolic links).
fn linkTree(src: []const u8, dst: []const u8) void {
    Io.Dir.cwd().deleteTree(io, dst) catch |err| fatal("{s}: {t}", .{ dst, err });
    Io.Dir.cwd().createDirPath(io, dst) catch |err| fatal("{s}: {t}", .{ dst, err });
    var src_dir: Io.Dir = Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch |err| fatal("{s}: {t}", .{ src, err });
    defer src_dir.close(io);
    var dst_dir: Io.Dir = Io.Dir.cwd().openDir(io, dst, .{}) catch |err| fatal("{s}: {t}", .{ dst, err });
    defer dst_dir.close(io);
    var walker: Io.Dir.Walker = src_dir.walk(gpa) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| fatal("{s}: {t}", .{ src, err })) |e| {
        switch (e.kind) {
            .directory => dst_dir.createDirPath(io, e.path) catch |err| fatal("{s}: {t}", .{ e.path, err }),
            .sym_link => {
                var buf: [fs.max_path_bytes]u8 = undefined;
                const n: usize = src_dir.readLink(io, e.path, &buf) catch |err| fatal("{s}: {t}", .{ e.path, err });
                dst_dir.symLink(io, buf[0..n], e.path, .{}) catch |err| fatal("{s}: {t}", .{ e.path, err });
            },
            else => src_dir.hardLink(e.path, dst_dir, e.path, io, .{}) catch |err| fatal("{s}: {t}", .{ e.path, err }),
        }
    }
}

/// A symbolic link in the root, and in its list.
fn symlinkEntry(spec: *std.ArrayList(u8), path: []const u8, target: []const u8) void {
    const full: []const u8 = fs.path.join(gpa, &.{ root, path }) catch @panic("OOM");
    Io.Dir.cwd().deleteFile(io, full) catch |err| switch (err) {
        error.FileNotFound => {},
        else => fatal("{s}: {t}", .{ full, err }),
    };
    Io.Dir.cwd().symLink(io, target, full, .{}) catch |err| fatal("{s}: {t}", .{ full, err });
    spec.print(gpa, "./{s} type=link uname=root gname=wheel mode=0755 link={s}\n", .{ path, target }) catch @panic("OOM");
}

/// What the Zig build makes and a medium holds.
const Parts: type = struct {
    makefs: []const u8,
    destdir: []const u8,
    kernel: []const u8,
    loader: []const u8,
    lua: []const u8,
    defaults: []const u8,
    hints: []const u8,
    efi_boot: []const u8,
};

/// A list of the root: the world's METALOG, sorted.
fn worldSpec(p: Parts) std.ArrayList(u8) {
    const metalog_path: []const u8 = fmt.allocPrint(gpa, "{s}/METALOG", .{p.destdir}) catch @panic("OOM");
    var spec: std.ArrayList(u8) = .empty;
    appendMetalog(&spec, readFile(metalog_path));
    return spec;
}

/// /boot without the kernel: the loader, the Lua it runs, its defaults
/// and the device hints.
fn addBoot(spec: *std.ArrayList(u8), p: Parts) void {
    entry(spec, "boot", "0755", null);
    entry(spec, "boot/loader.efi", "0555", readFile(p.loader));
    entry(spec, "boot/defaults", "0755", null);
    entry(spec, "boot/defaults/loader.conf", "0444", readFile(p.defaults));
    entry(spec, "boot/device.hints", "0444", readFile(p.hints));
    // The images the boot menu draws on a framebuffer: stand/images,
    // beside stand/lua.
    const images: []const u8 = fs.path.join(gpa, &.{ fs.path.dirname(p.lua).?, "images" }) catch @panic("OOM");
    entry(spec, "boot/images", "0755", null);
    var images_dir: Io.Dir = Io.Dir.cwd().openDir(io, images, .{ .iterate = true }) catch |err| fatal("{s}: {t}", .{ images, err });
    defer images_dir.close(io);
    var images_it: Io.Dir.Iterator = images_dir.iterate();
    while (images_it.next(io) catch |err| fatal("{s}: {t}", .{ images, err })) |e| {
        if (e.kind != .file or !mem.endsWith(u8, e.name, ".png")) continue;
        const path: []const u8 = fmt.allocPrint(gpa, "boot/images/{s}", .{e.name}) catch @panic("OOM");
        const source: []const u8 = fs.path.join(gpa, &.{ images, e.name }) catch @panic("OOM");
        entry(spec, path, "0444", readFile(source));
    }
    entry(spec, "boot/lua", "0755", null);
    var lua_dir: Io.Dir = Io.Dir.cwd().openDir(io, p.lua, .{ .iterate = true }) catch |err| fatal("{s}: {t}", .{ p.lua, err });
    defer lua_dir.close(io);
    var it: Io.Dir.Iterator = lua_dir.iterate();
    while (it.next(io) catch |err| fatal("{s}: {t}", .{ p.lua, err })) |e| {
        if (e.kind != .file or !mem.endsWith(u8, e.name, ".lua")) continue;
        const path: []const u8 = fmt.allocPrint(gpa, "boot/lua/{s}", .{e.name}) catch @panic("OOM");
        const source: []const u8 = fs.path.join(gpa, &.{ p.lua, e.name }) catch @panic("OOM");
        entry(spec, path, "0444", readFile(source));
    }
}

fn addKernel(spec: *std.ArrayList(u8), p: Parts) void {
    entry(spec, "boot", "0755", null);
    entry(spec, "boot/kernel", "0755", null);
    entry(spec, "boot/kernel/kernel", "0555", readFile(p.kernel));
}

/// An EFI system partition of size bytes, with the loader as the default
/// boot program; returns its path.
fn makeEsp(stage: []const u8, p: Parts, size: []const u8, fat: []const u8) []const u8 {
    const esp_dir: []const u8 = fmt.allocPrint(gpa, "{s}/esp", .{stage}) catch @panic("OOM");
    const boot_efi: []const u8 = fmt.allocPrint(gpa, "{s}/EFI/BOOT/{s}", .{ esp_dir, p.efi_boot }) catch @panic("OOM");
    writeFile(boot_efi, readFile(p.loader));
    const esp_img: []const u8 = fmt.allocPrint(gpa, "{s}/esp.img", .{stage}) catch @panic("OOM");
    const fat_opts: []const u8 = fmt.allocPrint(gpa, "fat_type={s},volume_label=EFISYS", .{fat}) catch @panic("OOM");
    run(&.{ p.makefs, "-t", "msdos", "-s", size, "-o", fat_opts, esp_img, esp_dir });
    return esp_img;
}

fn writeSpec(stage: []const u8, name: []const u8, spec: std.ArrayList(u8)) []const u8 {
    const path: []const u8 = fmt.allocPrint(gpa, "{s}/{s}", .{ stage, name }) catch @panic("OOM");
    writeFile(path, spec.items);
    return absolute(path);
}

/// The bootable disk.
fn disk(out: []const u8, stage: []const u8, p: Parts, mkimg: []const u8) void {
    root = fmt.allocPrint(gpa, "{s}/root", .{stage}) catch @panic("OOM");
    linkTree(p.destdir, root);
    var spec: std.ArrayList(u8) = worldSpec(p);
    addBoot(&spec, p);
    addKernel(&spec, p);
    // What a disk needs and the world has not.
    entry(&spec, "etc/fstab", "0644", "# Device\tMountpoint\tFStype\tOptions\tDump\tPass#\n/dev/gpt/rootfs\t/\tufs\trw\t1\t1\n");
    entry(&spec, "etc/rc.conf", "0644", "hostname=\"renux\"\n");
    const spec_path: []const u8 = writeSpec(stage, "root.mtree", spec);

    const root_img: []const u8 = fmt.allocPrint(gpa, "{s}/root.img", .{stage}) catch @panic("OOM");
    const etc: []const u8 = fmt.allocPrint(gpa, "{s}/etc", .{root}) catch @panic("OOM");
    run(&.{ p.makefs, "-D", "-N", etc, "-B", "little", "-t", "ffs", "-o", "version=2,label=rootfs,softupdates=1", "-b", "30%", "-f", "30%", "-F", spec_path, root_img, root });

    const esp_img: []const u8 = makeEsp(stage, p, "64m", "16");
    const esp_part: []const u8 = fmt.allocPrint(gpa, "efi/efiesp:={s}", .{esp_img}) catch @panic("OOM");
    const root_part: []const u8 = fmt.allocPrint(gpa, "freebsd-ufs/rootfs:={s}", .{root_img}) catch @panic("OOM");
    run(&.{ mkimg, "-s", "gpt", "-p", esp_part, "-p", root_part, "-o", out });
}

/// The number of entries of a list (the files of a set, for MANIFEST).
fn entries(spec: std.ArrayList(u8)) usize {
    var n: usize = 0;
    var it: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, spec.items, '\n');
    while (it.next()) |line| {
        if (line.len > 0 and line[0] != '#') n += 1;
    }
    return n;
}

/// A distribution set, NAME.txz in dist, of the tree dir as spec lists it;
/// returns its line of MANIFEST (release/scripts/make-manifest.sh).
fn distSet(stage: []const u8, dist: []const u8, name: []const u8, dir: []const u8, spec: std.ArrayList(u8), desc: []const u8) []const u8 {
    const spec_path: []const u8 = writeSpec(stage, fmt.allocPrint(gpa, "{s}.mtree", .{name}) catch @panic("OOM"), spec);
    const txz: []const u8 = fmt.allocPrint(gpa, "{s}/{s}.txz", .{ dist, name }) catch @panic("OOM");
    const at_spec: []const u8 = fmt.allocPrint(gpa, "@{s}", .{spec_path}) catch @panic("OOM");
    run(&.{ "bsdtar", "-c", "--xz", "--options", "xz:threads=0", "-f", txz, "-C", dir, at_spec });
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(readFile(txz), &digest, .{});
    return fmt.allocPrint(gpa, "{s}.txz\t{x}\t{d}\t{s}\t\"{s}\"\ton\n", .{ name, digest, entries(spec), name, desc }) catch @panic("OOM");
}

/// The files of a directory of the tree in the root, under path, with mode
/// for files: the Renux installer's welcome, catalogs and notes.
fn addDir(spec: *std.ArrayList(u8), source: []const u8, path: []const u8, file_mode: []const u8) void {
    entry(spec, path, "0755", null);
    var dir: Io.Dir = Io.Dir.cwd().openDir(io, source, .{ .iterate = true }) catch |err| fatal("{s}: {t}", .{ source, err });
    defer dir.close(io);
    var it: Io.Dir.Iterator = dir.iterate();
    while (it.next(io) catch |err| fatal("{s}: {t}", .{ source, err })) |e| {
        if (e.kind != .file) continue;
        const sub: []const u8 = fmt.allocPrint(gpa, "{s}/{s}", .{ path, e.name }) catch @panic("OOM");
        const from: []const u8 = fs.path.join(gpa, &.{ source, e.name }) catch @panic("OOM");
        entry(spec, sub, file_mode, readFile(from));
    }
}

/// The installer ISO.
fn iso(out: []const u8, stage: []const u8, p: Parts, rc_local: []const u8, installer: []const u8) void {
    const label: []const u8 = "RENUX_INSTALL";
    const dist: []const u8 = fmt.allocPrint(gpa, "{s}/dist", .{stage}) catch @panic("OOM");
    Io.Dir.cwd().createDirPath(io, dist) catch |err| fatal("{s}: {t}", .{ dist, err });

    // base.txz: the world and /boot without the kernel.
    root = fmt.allocPrint(gpa, "{s}/base", .{stage}) catch @panic("OOM");
    linkTree(p.destdir, root);
    var base: std.ArrayList(u8) = worldSpec(p);
    addBoot(&base, p);
    const base_line: []const u8 = distSet(stage, dist, "base", root, base, "Base system (MANDATORY)");

    // kernel.txz: the kernel.
    root = fmt.allocPrint(gpa, "{s}/kernel", .{stage}) catch @panic("OOM");
    linkTree(p.destdir, root);
    var kernel: std.ArrayList(u8) = .empty;
    kernel.appendSlice(gpa, "#mtree\n") catch @panic("OOM");
    addKernel(&kernel, p);
    const kernel_line: []const u8 = distSet(stage, dist, "kernel", root, kernel, "Kernel (MANDATORY)");

    // The live system: the world, /boot with the kernel, and the sets.
    root = fmt.allocPrint(gpa, "{s}/iso", .{stage}) catch @panic("OOM");
    linkTree(p.destdir, root);
    var spec: std.ArrayList(u8) = worldSpec(p);
    addBoot(&spec, p);
    addKernel(&spec, p);
    entry(&spec, "usr/freebsd-dist", "0755", null);
    entry(&spec, "usr/freebsd-dist/MANIFEST", "0644", mem.concat(gpa, u8, &.{ base_line, kernel_line }) catch @panic("OOM"));
    for ([_][]const u8{ "base.txz", "kernel.txz" }) |set| {
        const path: []const u8 = fmt.allocPrint(gpa, "usr/freebsd-dist/{s}", .{set}) catch @panic("OOM");
        const source: []const u8 = fmt.allocPrint(gpa, "{s}/{s}", .{ dist, set }) catch @panic("OOM");
        entry(&spec, path, "0644", readFile(source));
    }
    // The CD is the root, read-only (release/Makefile, disc1).
    entry(&spec, "etc/fstab", "0644", fmt.allocPrint(gpa, "/dev/iso9660/{s} / cd9660 ro 0 0\n", .{label}) catch @panic("OOM"));
    entry(&spec, "etc/rc.conf", "0644", "hostname=\"renux\"\nhostid_enable=\"NO\"\n");
    entry(&spec, "boot/loader.conf", "0644", fmt.allocPrint(gpa,
        \\vfs.root.mountfrom="cd9660:/dev/iso9660/{s}"
        \\vfs.mountroot.timeout="10"
        \\kernels_autodetect="NO"
        \\loader_menu_multi_user_prompt="Installer"
        \\loader_menu_title="Renux Installer"
        \\
    , .{label}) catch @panic("OOM"));
    // The network configuration of the installer goes to /tmp.
    symlinkEntry(&spec, "etc/resolv.conf", "/tmp/bsdinstall_etc/resolv.conf");
    // Start the installer, named Renux.
    const rc: []u8 = readFile(rc_local);
    const first: usize = if (mem.startsWith(u8, rc, "#!")) (mem.indexOfScalar(u8, rc, '\n') orelse rc.len - 1) + 1 else 0;
    entry(&spec, "etc/rc.local", "0644", mem.concat(gpa, u8, &.{ rc[0..first], "OSNAME=Renux; export OSNAME\n", rc[first..] }) catch @panic("OOM"));
    // The Renux installer's welcome, languages and release notes, which
    // bsdinstall's startbsdinstall runs.
    const libexec: []const u8 = "usr/libexec/renux-installer";
    entry(&spec, libexec, "0755", null);
    entry(&spec, libexec ++ "/welcome.subr", "0444", readFile(fs.path.join(gpa, &.{ installer, "welcome.subr" }) catch @panic("OOM")));
    entry(&spec, libexec ++ "/renux.theme", "0444", readFile(fs.path.join(gpa, &.{ installer, "renux.theme" }) catch @panic("OOM")));
    addDir(&spec, fs.path.join(gpa, &.{ installer, "bin" }) catch @panic("OOM"), libexec ++ "/bin", "0555");
    addDir(&spec, fs.path.join(gpa, &.{ installer, "lang" }) catch @panic("OOM"), libexec ++ "/lang", "0444");
    addDir(&spec, fs.path.join(gpa, &.{ installer, "notes" }) catch @panic("OOM"), libexec ++ "/notes", "0444");
    const spec_path: []const u8 = writeSpec(stage, "iso.mtree", spec);

    // UEFI boot by El Torito (release/amd64/mkisoimages.sh).
    const esp_img: []const u8 = makeEsp(stage, p, "4m", "12");
    const boot: []const u8 = fmt.allocPrint(gpa, "bootimage=i386;{s}", .{esp_img}) catch @panic("OOM");
    const label_opt: []const u8 = fmt.allocPrint(gpa, "label={s}", .{label}) catch @panic("OOM");
    const etc: []const u8 = fmt.allocPrint(gpa, "{s}/etc", .{root}) catch @panic("OOM");
    run(&.{ p.makefs, "-D", "-N", etc, "-t", "cd9660", "-o", boot, "-o", "no-emul-boot", "-o", "platformid=efi", "-o", "rockridge", "-o", label_opt, "-o", "publisher=The Renux Project", "-F", spec_path, out, root });
}

pub fn main(init: process.Init) void {
    io = init.io;
    gpa = init.arena.allocator();
    const args: []const [:0]const u8 = init.minimal.args.toSlice(gpa) catch @panic("OOM");
    if (args.len < 13) fatal("usage: image disk|iso OUT STAGE MAKEFS DESTDIR KERNEL LOADER LUA DEFAULTS HINTS EFIBOOT MKIMG|RCLOCAL INSTALLER", .{});
    const p: Parts = .{
        .makefs = args[4],
        .destdir = args[5],
        .kernel = absolute(args[6]),
        .loader = absolute(args[7]),
        .lua = absolute(args[8]),
        .defaults = absolute(args[9]),
        .hints = absolute(args[10]),
        .efi_boot = args[11],
    };
    const out: []const u8 = args[2];
    const stage: []const u8 = args[3];
    if (mem.eql(u8, args[1], "disk")) return disk(out, stage, p, args[12]);
    if (mem.eql(u8, args[1], "iso") and args.len == 14) return iso(out, stage, p, absolute(args[12]), absolute(args[13]));
    fatal("unknown medium {s}", .{args[1]});
}
