// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// hosttools.zig - the programs the build runs on the host, built by Zig
// from this tree as usr.bin/ builds them: yacc (contrib/byacc), awk
// (contrib/one-true-awk), rpcgen, vtfontcvt and bmake (contrib/bmake).
// With them the build's generators (awk scripts, rpcgen, the console font)
// and FreeBSD's own Makefiles need nothing on the host but Zig.
//
// tools/renux/include holds the few BSD definitions these tools need and
// not every host C library has.

const std: type = @import("std");
const mem: type = std.mem;
const debug: type = std.debug;
const Build: type = std.Build;
const Target: type = std.Target;

pub const HostTools: type = struct {
    yacc: *Build.Step.Compile,
    awk: *Build.Step.Compile,
    rpcgen: *Build.Step.Compile,
    vtfontcvt: *Build.Step.Compile,
    bmake: *Build.Step.Compile,
};

/// A C program for the host, without Zig's safety checks: the tools are
/// FreeBSD's, tested as FreeBSD builds them.
fn hostProgram(b: *Build, name: []const u8) *Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
}

pub fn build(b: *Build) HostTools {
    // yacc, as usr.bin/yacc builds it.
    const yacc: *Build.Step.Compile = hostProgram(b, "yacc");
    yacc.root_module.addIncludePath(b.path("usr.bin/yacc"));
    yacc.root_module.addCMacro("HAVE_CONFIG_H", "1");
    yacc.root_module.addCMacro("MAXTABLE", "INT_MAX");
    yacc.root_module.addCMacro("YYPATCH", byaccVersion(b));
    yacc.root_module.addCSourceFiles(.{
        .root = b.path("contrib/byacc"),
        .files = &.{
            "closure.c", "error.c",  "graph.c",   "lalr.c",     "lr0.c",
            "main.c",    "mkpar.c",  "mstring.c", "output.c",   "reader.c",
            "yaccpar.c", "symtab.c", "verbose.c", "warshall.c",
        },
    });

    // awk's grammar, its token table (maketab), then awk.
    const gram: *Build.Step.Run = b.addRunArtifact(yacc);
    // awk's grammar has conflicts, which yacc reports on stderr, as it
    // does in FreeBSD's build.  They are expected: keep the report out of
    // the build's output, which would show it as a warning.
    gram.expectExitCode(0);
    _ = gram.captureStdErr(.{ .basename = "awkgram.conflicts" });
    gram.addArg("-d");
    gram.addArg("-H");
    const gram_h: Build.LazyPath = gram.addOutputFileArg("awkgram.tab.h");
    gram.addArg("-o");
    const gram_c: Build.LazyPath = gram.addOutputFileArg("awkgram.c");
    gram.addFileArg(b.path("contrib/one-true-awk/awkgram.y"));

    const maketab: *Build.Step.Compile = hostProgram(b, "maketab");
    maketab.root_module.addIncludePath(gram_h.dirname());
    maketab.root_module.addIncludePath(b.path("contrib/one-true-awk"));
    maketab.root_module.addCSourceFile(.{ .file = b.path("contrib/one-true-awk/maketab.c") });

    const tab: *Build.Step.Run = b.addRunArtifact(maketab);
    tab.addFileArg(gram_h);
    const proctab: Build.LazyPath = tab.captureStdOut(.{ .basename = "proctab.c" });

    const awk: *Build.Step.Compile = hostProgram(b, "awk");
    awk.root_module.addIncludePath(gram_h.dirname());
    awk.root_module.addIncludePath(b.path("contrib/one-true-awk"));
    awk.root_module.addCMacro("HAS_ISBLANK", "1");
    const awk_flags: []const []const u8 = &.{ "-DFOPEN_MAX=64", "-Wno-macro-redefined" };
    awk.root_module.addCSourceFiles(.{
        .root = b.path("contrib/one-true-awk"),
        .files = &.{ "b.c", "lex.c", "lib.c", "main.c", "parse.c", "run.c", "tran.c" },
        .flags = awk_flags,
    });
    awk.root_module.addCSourceFile(.{ .file = gram_c, .flags = awk_flags });
    awk.root_module.addCSourceFile(.{ .file = proctab, .flags = awk_flags });
    awk.root_module.linkSystemLibrary("m", .{});

    // rpcgen, with <rpc/types.h> from tools/renux/include: glibc has no
    // Sun RPC any more.
    const rpcgen: *Build.Step.Compile = hostProgram(b, "rpcgen");
    rpcgen.root_module.addIncludePath(b.path("tools/renux/include"));
    rpcgen.root_module.addCSourceFiles(.{
        .root = b.path("usr.bin/rpcgen"),
        .files = &.{
            "rpc_main.c",   "rpc_clntout.c", "rpc_cout.c",   "rpc_hout.c",   "rpc_parse.c",
            "rpc_sample.c", "rpc_scan.c",    "rpc_svcout.c", "rpc_tblout.c", "rpc_util.c",
        },
        .flags = &.{ "-include", "tools/renux/include/bsdcompat.h" },
    });

    // vtfontcvt, which makes the loader's console font.  It uses kernel
    // headers (sys/font.h and the rest), copied for it, and on hosts that
    // are not BSDs the <sys/endian.h> of tools/build/cross-build.
    const vt_inc: *Build.Step.WriteFile = b.addWriteFiles();
    for ([_][]const u8{ "fnv_hash.h", "font.h", "queue.h" }) |h|
        _ = vt_inc.addCopyFile(b.path(b.fmt("sys/sys/{s}", .{h})), b.fmt("sys/{s}", .{h}));
    switch (b.graph.host.result.os.tag) {
        .linux => _ = vt_inc.addCopyFile(b.path("tools/build/cross-build/include/linux/sys/endian.h"), "sys/endian.h"),
        .macos => _ = vt_inc.addCopyFile(b.path("tools/build/cross-build/include/mac/sys/endian.h"), "sys/endian.h"),
        else => {},
    }
    const vtfontcvt: *Build.Step.Compile = hostProgram(b, "vtfontcvt");
    vtfontcvt.root_module.addIncludePath(vt_inc.getDirectory());
    vtfontcvt.root_module.addIncludePath(b.path("sys/cddl/contrib/opensolaris/common/lz4"));
    const vt_flags: []const []const u8 = &.{ "-include", "tools/renux/include/bsdcompat.h" };
    vtfontcvt.root_module.addCSourceFile(.{ .file = b.path("usr.bin/vtfontcvt/vtfontcvt.c"), .flags = vt_flags });
    vtfontcvt.root_module.addCSourceFile(.{ .file = b.path("sys/cddl/contrib/opensolaris/common/lz4/lz4.c"), .flags = vt_flags });

    return .{ .yacc = yacc, .awk = awk, .rpcgen = rpcgen, .vtfontcvt = vtfontcvt, .bmake = buildBmake(b) };
}

/// A file of the tree, read while the build is configured, and recorded
/// as an input of the configuration.
fn readTree(b: *Build, sub_path: []const u8) []const u8 {
    const path: Build.Cache.Path = b.root.join(b.allocator, sub_path) catch @panic("OOM");
    const text: []u8 = path.root_dir.handle.readFileAlloc(b.graph.io, path.sub_path, b.allocator, .unlimited) catch |err|
        debug.panic("cannot read {s}: {t}", .{ sub_path, err });
    b.dependOnFileContents(b.path(sub_path));
    return text;
}

/// contrib/byacc/VERSION, which usr.bin/yacc passes as YYPATCH.
fn byaccVersion(b: *Build) []const u8 {
    return mem.trim(u8, readTree(b, "contrib/byacc/VERSION"), " \t\n");
}

/// bmake, as contrib/bmake's boot-strap builds it with tools/build/make.py's
/// options (no filemon), but without its configure script: config.h is
/// usr.bin/bmake's, written by configure on FreeBSD, with what configure
/// finds otherwise on the hosts that are not BSDs.
fn buildBmake(b: *Build) *Build.Step.Compile {
    const host: Target = b.graph.host.result;
    var config: []const u8 = readTree(b, "usr.bin/bmake/config.h");
    switch (host.os.tag) {
        .freebsd, .netbsd, .openbsd, .dragonfly, .macos => {},
        else => {
            // glibc and musl have no sysctl(3), sigvec(2) or <ranlib.h>,
            // and glibc no longer declares sys_siglist.
            for ([_][]const u8{ "HAVE_SYS_SYSCTL_H", "HAVE_SYSCTL", "HAVE_SIGVEC", "HAVE_RANLIB_H" }) |name|
                config = undefine(b, config, name);
            config = mem.replaceOwned(u8, b.allocator, config, "#define HAVE_DECL_SYS_SIGLIST 1", "#define HAVE_DECL_SYS_SIGLIST 0") catch @panic("OOM");
        },
    }
    const wf: *Build.Step.WriteFile = b.addWriteFiles();
    _ = wf.add("config.h", config);

    // The MACHINE and MACHINE_ARCH bmake reports, by FreeBSD's names.
    const machine: []const u8 = switch (host.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .riscv64 => "riscv",
        .powerpc64, .powerpc64le => "powerpc",
        else => @tagName(host.cpu.arch),
    };
    const version: []const u8 = bmakeVersion(b);

    const bmake: *Build.Step.Compile = hostProgram(b, "bmake");
    bmake.root_module.addIncludePath(wf.getDirectory());
    bmake.root_module.addIncludePath(b.path("contrib/bmake"));
    const flags: []const []const u8 = &.{ "-DHAVE_CONFIG_H", "-DMAKE_NATIVE", "-DUSE_META", "-DBMAKE_PATH_MAX=1024" };
    bmake.root_module.addCSourceFiles(.{
        .root = b.path("contrib/bmake"),
        .files = &.{
            "arch.c",      "buf.c", "compat.c",  "cond.c",        "dir.c",  "for.c",      "hash.c",
            "job.c",       "lst.c", "make.c",    "make_malloc.c", "meta.c", "metachar.c", "parse.c",
            "sigcompat.c", "str.c", "stresep.c", "suff.c",        "targ.c", "trace.c",    "util.c",
            "var.c",
        },
        .flags = flags,
    });
    bmake.root_module.addCSourceFile(.{
        .file = b.path("contrib/bmake/main.c"),
        .flags = mem.concat(b.allocator, []const u8, &.{ flags, &.{
            b.fmt("-DMAKE_VERSION=\"{s}\"", .{version}),
            b.fmt("-DMACHINE=\"{s}\"", .{machine}),
            b.fmt("-DMACHINE_ARCH=\"{s}\"", .{@tagName(host.cpu.arch)}),
            "-DMAKE_OS=\"\"",
            "-D_PATH_DEFSYSPATH=\".../share/mk\"",
        } }) catch @panic("OOM"),
    });
    return bmake;
}

/// _MAKE_VERSION of contrib/bmake/VERSION.
fn bmakeVersion(b: *Build) []const u8 {
    var it: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, readTree(b, "contrib/bmake/VERSION"), '\n');
    while (it.next()) |line| {
        if (mem.startsWith(u8, line, "_MAKE_VERSION="))
            return mem.trim(u8, line["_MAKE_VERSION=".len..], " \t");
    }
    @panic("no _MAKE_VERSION in contrib/bmake/VERSION");
}

/// config.h without "#define NAME 1".
fn undefine(b: *Build, config: []const u8, name: []const u8) []const u8 {
    return mem.replaceOwned(u8, b.allocator, config, b.fmt("#define {s} 1\n", .{name}), b.fmt("/* #undef {s} */\n", .{name})) catch @panic("OOM");
}
