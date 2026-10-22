// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// stand.zig - the EFI boot loader (loader.efi, with Lua), as stand/ builds
// it: libsa, liblua and libefi, then the loader, linked as an ELF that the
// loader relocates itself, then turned into a PE image for the firmware.
//
// The sources and flags of every object are in stand_<machine>.zon, which
// mirrors the Makefiles of stand/ for the machine.  The flags name the
// directories the build makes:
//
//   @include   machine/ and x86/, the kernel's machine headers
//   @libsa     libsa's headers: the C library headers stand/ uses
//   @self      the object directory of the library being built

const std: type = @import("std");
const mem: type = std.mem;
const debug: type = std.debug;
const Build: type = std.Build;

const hosttools: type = @import("hosttools.zig");
const machine: type = @import("machine.zig");
const LazyPath: type = Build.LazyPath;
const Run: type = Build.Step.Run;

/// One object of a library: its source, and its set of flags.
const Source: type = struct {
    obj: []const u8,
    src: []const u8,
    flags: usize,
};

/// One library, or the loader itself.
const Library: type = struct {
    name: []const u8,
    files: []const Source,
};

const Data: type = struct {
    libs: []const Library,
    flags: []const []const []const u8,
};

/// A machine's table, and the header directories of its "include".
const Table: type = struct {
    data: Data,
    headers: []const [2][]const u8,
};

fn table(m: machine.Machine) ?Table {
    return switch (m) {
        .amd64 => .{
            .data = @import("stand_amd64.zon"),
            .headers = &.{ .{ "machine", "sys/amd64/include" }, .{ "x86", "sys/x86/include" } },
        },
        .arm64, .riscv => null,
    };
}

pub const Options: type = struct {
    machine: machine.Machine,
    tools: hosttools.HostTools,
    kgen: *Build.Step.Compile,
    /// The FreeBSD release of the tree (sys/conf/newvers.sh's REVISION).
    revision: []const u8,
};

/// What `zig build loader` installs into /boot.
pub const Loader: type = struct {
    efi: LazyPath,
};

/// The sections elfcopy keeps in loader.efi (stand/efi/loader/Makefile).
const pe_sections: [12][]const u8 = .{
    ".peheader", ".text",     ".sdata", ".data",     ".dynamic",         ".dynsym",
    ".rel.dyn",  ".rela.dyn", ".reloc", ".eh_frame", "set_Xcommand_set", "set_Xlua_compile_set",
};

/// The source tree is /usr/src in what the compiler records (__FILE__ and
/// the debug information), as with FreeBSD's -ffile-prefix-map.  The
/// build names sources ./dir/... and finds headers as dir/... through -I.
pub const file_prefix_map: [12][]const u8 = blk: {
    const dirs: [6][]const u8 = [_][]const u8{ "contrib", "include", "lib", "libexec", "stand", "sys" };
    var maps: [2 * dirs.len][]const u8 = undefined;
    for (dirs, 0..) |d, i| {
        maps[2 * i] = "-ffile-prefix-map=./" ++ d ++ "=/usr/src/" ++ d;
        maps[2 * i + 1] = "-ffile-prefix-map=" ++ d ++ "/=/usr/src/" ++ d ++ "/";
    }
    break :blk maps;
};

/// SOURCE_DATE_EPOCH of stand/: the PE timestamp, so the image is the
/// same on every build.
const source_date_epoch: []const u8 = "1704067200";

/// The headers libsa puts in its object directory (stand/libsa/Makefile).
fn libsaHeaders(b: *Build) LazyPath {
    const wf: *Build.Step.WriteFile = b.addWriteFiles();
    for ([_][]const u8{
        "a.out.h",  "assert.h",  "elf.h",    "limits.h",  "nlist.h", "setjmp.h",
        "stddef.h", "stdbool.h", "string.h", "strings.h", "time.h",  "uuid.h",
    }) |h| _ = wf.addCopyFile(b.path(b.fmt("include/{s}", .{h})), h);
    for ([_][]const u8{ "errno.h", "stdarg.h", "stdint.h" }) |h|
        _ = wf.addCopyFile(b.path(b.fmt("sys/sys/{s}", .{h})), h);
    for ([_][]const u8{ "arpa/inet.h", "arpa/tftp.h", "ssp/ssp.h" }) |h|
        _ = wf.addCopyFile(b.path(b.fmt("include/{s}", .{h})), h);
    for ([_][]const u8{ "_time.h", "_strings.h", "_string.h" }) |h|
        _ = wf.add(b.fmt("xlocale/{s}", .{h}), "");
    for ([_][]const u8{ "ctype.h", "fcntl.h", "signal.h", "stdio.h", "stdlib.h", "unistd.h" }) |h|
        _ = wf.addCopyFile(b.path("stand/libsa/stand.h"), h);
    return wf.getDirectory();
}

/// A source the build makes (@vers.c), and where it is.
const Generated: type = struct {
    name: []const u8,
    path: LazyPath,
};

/// A directory the flags name (@self, @libsa, @include), and where it is.
const IncludeDir: type = struct {
    name: []const u8,
    path: LazyPath,
};

const Builder: type = struct {
    b: *Build,
    opts: Options,
    triple: []const u8,
    data: Data,
    include: LazyPath,
    libsa: LazyPath,

    /// One object: `zig clang` with the flags of its set.
    fn compile(k: *Builder, obj: []const u8, src: LazyPath, flags: []const []const u8, self: LazyPath) LazyPath {
        const b: *Build = k.b;
        const run: *Build.Step.Run = Run.create(b, obj);
        run.setCwd(b.path("."));
        run.expectExitCode(0);
        run.addArgs(&.{ b.graph.zig_exe, "clang", "-target", k.triple });
        run.addPrefixedDirectoryArg("-resource-dir=", b.graph.path(.zig_lib, "."));
        run.addArgs(&file_prefix_map);
        for (flags) |f| {
            const dirs: [3]IncludeDir = .{ .{ .name = "@self", .path = self }, .{ .name = "@libsa", .path = k.libsa }, .{ .name = "@include", .path = k.include } };
            for (dirs) |d| {
                if (mem.startsWith(u8, f, "-I") and mem.eql(u8, f[2..], d.name)) {
                    run.addPrefixedDirectoryArg("-I", d.path);
                    break;
                }
            } else run.addArg(f);
        }
        run.addArg("-c");
        run.addFileArg(src);
        run.addArg("-o");
        const out: LazyPath = run.addOutputFileArg(obj);
        run.addArg("-MD");
        _ = run.addPrefixedDepFileOutputArg("-MF", b.fmt("{s}.d", .{obj}));
        return out;
    }

    /// `ar -crsD`, with the members in the Makefile's order.
    fn archive(k: *Builder, name: []const u8, objs: []const LazyPath) LazyPath {
        const b: *Build = k.b;
        const run: *Build.Step.Run = Run.create(b, name);
        run.expectExitCode(0);
        run.addArgs(&.{ b.graph.zig_exe, "ar", "-crsD" });
        const out: LazyPath = run.addOutputFileArg(name);
        for (objs) |o| run.addFileArg(o);
        return out;
    }

    fn kgen(k: *Builder, name: []const u8, cmd: []const u8, inputs: []const LazyPath, extra: []const []const u8) LazyPath {
        const run: *Build.Step.Run = k.b.addRunArtifact(k.opts.kgen);
        run.setName(name);
        run.setCwd(k.b.path("."));
        run.expectExitCode(0);
        run.addArg(cmd);
        for (inputs) |i| run.addFileArg(i);
        const out: LazyPath = run.addOutputFileArg(name);
        run.addArgs(extra);
        return out;
    }

    /// Every object of a library of the table; `generated` holds the
    /// sources the build makes (@name).
    fn objects(k: *Builder, lib: []const u8, self: LazyPath, generated: []const Generated) []LazyPath {
        const b: *Build = k.b;
        var list: std.ArrayList(LazyPath) = .empty;
        const l: Library = for (k.data.libs) |l| {
            if (mem.eql(u8, l.name, lib)) break l;
        } else debug.panic("stand: no library {s}", .{lib});
        for (l.files) |f| {
            const src: LazyPath = if (f.src[0] == '@') for (generated) |g| {
                if (mem.eql(u8, g.name, f.src[1..])) break g.path;
            } else debug.panic("stand: nothing makes {s}", .{f.src}) else b.path(f.src);
            list.append(b.allocator, k.compile(f.obj, src, k.data.flags[f.flags], self)) catch @panic("OOM");
        }
        return list.items;
    }

    fn build(k: *Builder) Loader {
        const b: *Build = k.b;
        const empty: LazyPath = b.addWriteFiles().getDirectory();

        const libsa: LazyPath = k.archive("libsa.a", k.objects("sa", k.libsa, &.{}));
        const liblua: LazyPath = k.archive("liblua.a", k.objects("lua", empty, &.{}));

        // libefi's object directory has teken_state.h.
        const teken: *Build.Step.Run = b.addRunArtifact(k.opts.tools.awk);
        teken.setCwd(b.path("."));
        teken.expectExitCode(0);
        teken.addArgs(&.{ "-f", "sys/teken/gensequences", "sys/teken/sequences" });
        const efi_dir: *Build.Step.WriteFile = b.addWriteFiles();
        _ = efi_dir.addCopyFile(teken.captureStdOut(.{ .basename = "teken_state.h" }), "teken_state.h");
        const libefi: LazyPath = k.archive("libefi.a", k.objects("efi", efi_dir.getDirectory(), &.{}));

        // The loader: vers.c (newvers.sh) and the console font (vtfontcvt).
        const vers: LazyPath = k.kgen("vers.c", "stand-vers", &.{b.path("stand/efi/loader/version")}, &.{ "EFI loader", k.opts.machine.name() });
        const font: *Build.Step.Run = b.addRunArtifact(k.opts.tools.vtfontcvt);
        font.expectExitCode(0);
        font.addArgs(&.{ "-f", "compressed-source", "-o" });
        const font_c: LazyPath = font.addOutputFileArg("8x16.c");
        font.addFileArg(b.path("contrib/terminus/ter-u16b.bdf"));
        const objs: []LazyPath = k.objects("loader", empty, &.{ .{ .name = "vers.c", .path = vers }, .{ .name = "8x16.c", .path = font_c } });

        // The link, as clang drives lld for stand/efi/loader.
        const link: *Build.Step.Run = Run.create(b, "loader_lua.sym");
        link.expectExitCode(0);
        link.addArgs(&.{
            b.graph.zig_exe,   "ld.lld",               "-pie",              "--eh-frame-hdr",
            "-dynamic-linker", "/libexec/ld-elf.so.1", "--hash-style=both", "--enable-new-dtags",
            "-znocombreloc",   "-Bsymbolic",           "-znotext",          "-zrelro",
        });
        const m: []const u8 = k.opts.machine.name();
        link.addPrefixedFileArg("-T", b.path(b.fmt("stand/efi/loader/arch/{s}/{s}.ldscript", .{ m, m })));
        link.addArg("-o");
        const sym: LazyPath = link.addOutputFileArg("loader_lua.sym");
        for (objs) |o| link.addFileArg(o);
        for ([_]LazyPath{ liblua, libefi, libsa }) |a| link.addFileArg(a);

        // No undefined symbols, then the PE image.
        const checked: LazyPath = k.kgen("loader_lua.sym.checked", "check-undefined", &.{sym}, &.{});
        var sections: std.ArrayList([]const u8) = .empty;
        sections.append(b.allocator, source_date_epoch) catch @panic("OOM");
        sections.appendSlice(b.allocator, &pe_sections) catch @panic("OOM");
        const efi: LazyPath = k.kgen("loader.efi", "efi-pe", &.{checked}, sections.items);
        return .{ .efi = efi };
    }
};

pub fn build(b: *Build, opts: Options) Loader {
    const config: machine.Config = opts.machine.config() orelse
        debug.panic("loader: the Zig build does not support {s} yet", .{opts.machine.name()});
    const t: Table = table(opts.machine) orelse
        debug.panic("loader: no stand/ table for {s} yet", .{opts.machine.name()});
    var k: Builder = .{
        .b = b,
        .opts = opts,
        .triple = config.triple(b, opts.revision),
        .data = t.data,
        .include = blk: {
            const wf: *Build.Step.WriteFile = b.addWriteFiles();
            for (t.headers) |h| _ = wf.addCopyDirectory(b.path(h[1]), h[0], .{});
            break :blk wf.getDirectory();
        },
        .libsa = libsaHeaders(b),
    };
    return k.build();
}
