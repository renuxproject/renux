// SPDX-License-Identifier: BSD-2-Clause
//
// Copyright (c) 2026 The Renux Project
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

const std = @import("std");
const hosttools = @import("hosttools.zig");
const machine = @import("machine.zig");
const LazyPath = std.Build.LazyPath;
const Run = std.Build.Step.Run;

const Data = struct {
    libs: []const struct {
        name: []const u8,
        files: []const struct { obj: []const u8, src: []const u8, flags: usize },
    },
    flags: []const []const []const u8,
};

/// A machine's table, and the header directories of its "include".
const Table = struct {
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

pub const Options = struct {
    machine: machine.Machine,
    tools: hosttools.HostTools,
    kgen: *std.Build.Step.Compile,
    /// The FreeBSD release of the tree (sys/conf/newvers.sh's REVISION).
    revision: []const u8,
};

/// What `zig build loader` installs into /boot.
pub const Loader = struct {
    efi: LazyPath,
};

/// The sections elfcopy keeps in loader.efi (stand/efi/loader/Makefile).
const pe_sections = [_][]const u8{
    ".peheader", ".text",     ".sdata", ".data",     ".dynamic",         ".dynsym",
    ".rel.dyn",  ".rela.dyn", ".reloc", ".eh_frame", "set_Xcommand_set", "set_Xlua_compile_set",
};

/// The source tree is /usr/src in what the compiler records (__FILE__ and
/// the debug information), as with FreeBSD's -ffile-prefix-map.  The
/// build names sources ./dir/... and finds headers as dir/... through -I.
pub const file_prefix_map = blk: {
    const dirs = [_][]const u8{ "contrib", "include", "lib", "libexec", "stand", "sys" };
    var maps: [2 * dirs.len][]const u8 = undefined;
    for (dirs, 0..) |d, i| {
        maps[2 * i] = "-ffile-prefix-map=./" ++ d ++ "=/usr/src/" ++ d;
        maps[2 * i + 1] = "-ffile-prefix-map=" ++ d ++ "/=/usr/src/" ++ d ++ "/";
    }
    break :blk maps;
};

/// SOURCE_DATE_EPOCH of stand/: the PE timestamp, so the image is the
/// same on every build.
const source_date_epoch = "1704067200";

/// The headers libsa puts in its object directory (stand/libsa/Makefile).
fn libsaHeaders(b: *std.Build) LazyPath {
    const wf = b.addWriteFiles();
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

const Builder = struct {
    b: *std.Build,
    opts: Options,
    triple: []const u8,
    data: Data,
    include: LazyPath,
    libsa: LazyPath,

    /// One object: `zig clang` with the flags of its set.
    fn compile(k: *Builder, obj: []const u8, src: LazyPath, flags: []const []const u8, self: LazyPath) LazyPath {
        const b = k.b;
        const run = Run.create(b, obj);
        run.setCwd(b.path("."));
        run.expectExitCode(0);
        run.addArgs(&.{ b.graph.zig_exe, "clang", "-target", k.triple });
        run.addPrefixedDirectoryArg("-resource-dir=", b.graph.path(.zig_lib, "."));
        run.addArgs(&file_prefix_map);
        for (flags) |f| {
            const dirs = [_]struct { []const u8, LazyPath }{ .{ "@self", self }, .{ "@libsa", k.libsa }, .{ "@include", k.include } };
            for (dirs) |d| {
                if (std.mem.startsWith(u8, f, "-I") and std.mem.eql(u8, f[2..], d[0])) {
                    run.addPrefixedDirectoryArg("-I", d[1]);
                    break;
                }
            } else run.addArg(f);
        }
        run.addArg("-c");
        run.addFileArg(src);
        run.addArg("-o");
        const out = run.addOutputFileArg(obj);
        run.addArg("-MD");
        _ = run.addPrefixedDepFileOutputArg("-MF", b.fmt("{s}.d", .{obj}));
        return out;
    }

    /// `ar -crsD`, with the members in the Makefile's order.
    fn archive(k: *Builder, name: []const u8, objs: []const LazyPath) LazyPath {
        const b = k.b;
        const run = Run.create(b, name);
        run.expectExitCode(0);
        run.addArgs(&.{ b.graph.zig_exe, "ar", "-crsD" });
        const out = run.addOutputFileArg(name);
        for (objs) |o| run.addFileArg(o);
        return out;
    }

    fn kgen(k: *Builder, name: []const u8, cmd: []const u8, inputs: []const LazyPath, extra: []const []const u8) LazyPath {
        const run = k.b.addRunArtifact(k.opts.kgen);
        run.setName(name);
        run.setCwd(k.b.path("."));
        run.expectExitCode(0);
        run.addArg(cmd);
        for (inputs) |i| run.addFileArg(i);
        const out = run.addOutputFileArg(name);
        run.addArgs(extra);
        return out;
    }

    /// Every object of a library of the table; `generated` holds the
    /// sources the build makes (@name).
    fn objects(k: *Builder, lib: []const u8, self: LazyPath, generated: []const struct { []const u8, LazyPath }) []LazyPath {
        const b = k.b;
        var list: std.ArrayList(LazyPath) = .empty;
        const l = for (k.data.libs) |l| {
            if (std.mem.eql(u8, l.name, lib)) break l;
        } else std.debug.panic("stand: no library {s}", .{lib});
        for (l.files) |f| {
            const src = if (f.src[0] == '@') for (generated) |g| {
                if (std.mem.eql(u8, g[0], f.src[1..])) break g[1];
            } else std.debug.panic("stand: nothing makes {s}", .{f.src}) else b.path(f.src);
            list.append(b.allocator, k.compile(f.obj, src, k.data.flags[f.flags], self)) catch @panic("OOM");
        }
        return list.items;
    }

    fn build(k: *Builder) Loader {
        const b = k.b;
        const empty = b.addWriteFiles().getDirectory();

        const libsa = k.archive("libsa.a", k.objects("sa", k.libsa, &.{}));
        const liblua = k.archive("liblua.a", k.objects("lua", empty, &.{}));

        // libefi's object directory has teken_state.h.
        const teken = b.addRunArtifact(k.opts.tools.awk);
        teken.setCwd(b.path("."));
        teken.expectExitCode(0);
        teken.addArgs(&.{ "-f", "sys/teken/gensequences", "sys/teken/sequences" });
        const efi_dir = b.addWriteFiles();
        _ = efi_dir.addCopyFile(teken.captureStdOut(.{ .basename = "teken_state.h" }), "teken_state.h");
        const libefi = k.archive("libefi.a", k.objects("efi", efi_dir.getDirectory(), &.{}));

        // The loader: vers.c (newvers.sh) and the console font (vtfontcvt).
        const vers = k.kgen("vers.c", "stand-vers", &.{b.path("stand/efi/loader/version")}, &.{ "EFI loader", k.opts.machine.name() });
        const font = b.addRunArtifact(k.opts.tools.vtfontcvt);
        font.expectExitCode(0);
        font.addArgs(&.{ "-f", "compressed-source", "-o" });
        const font_c = font.addOutputFileArg("8x16.c");
        font.addFileArg(b.path("contrib/terminus/ter-u16b.bdf"));
        const objs = k.objects("loader", empty, &.{ .{ "vers.c", vers }, .{ "8x16.c", font_c } });

        // The link, as clang drives lld for stand/efi/loader.
        const link = Run.create(b, "loader_lua.sym");
        link.expectExitCode(0);
        link.addArgs(&.{
            b.graph.zig_exe,   "ld.lld",               "-pie",              "--eh-frame-hdr",
            "-dynamic-linker", "/libexec/ld-elf.so.1", "--hash-style=both", "--enable-new-dtags",
            "-znocombreloc",   "-Bsymbolic",           "-znotext",          "-zrelro",
        });
        const m = k.opts.machine.name();
        link.addPrefixedFileArg("-T", b.path(b.fmt("stand/efi/loader/arch/{s}/{s}.ldscript", .{ m, m })));
        link.addArg("-o");
        const sym = link.addOutputFileArg("loader_lua.sym");
        for (objs) |o| link.addFileArg(o);
        for ([_]LazyPath{ liblua, libefi, libsa }) |a| link.addFileArg(a);

        // No undefined symbols, then the PE image.
        const checked = k.kgen("loader_lua.sym.checked", "check-undefined", &.{sym}, &.{});
        var sections: std.ArrayList([]const u8) = .empty;
        sections.append(b.allocator, source_date_epoch) catch @panic("OOM");
        sections.appendSlice(b.allocator, &pe_sections) catch @panic("OOM");
        const efi = k.kgen("loader.efi", "efi-pe", &.{checked}, sections.items);
        return .{ .efi = efi };
    }
};

pub fn build(b: *std.Build, opts: Options) Loader {
    const config = opts.machine.config() orelse
        std.debug.panic("loader: the Zig build does not support {s} yet", .{opts.machine.name()});
    const t = table(opts.machine) orelse
        std.debug.panic("loader: no stand/ table for {s} yet", .{opts.machine.name()});
    var k: Builder = .{
        .b = b,
        .opts = opts,
        .triple = config.triple(b, opts.revision),
        .data = t.data,
        .include = blk: {
            const wf = b.addWriteFiles();
            for (t.headers) |h| _ = wf.addCopyDirectory(b.path(h[1]), h[0], .{});
            break :blk wf.getDirectory();
        },
        .libsa = libsaHeaders(b),
    };
    return k.build();
}
