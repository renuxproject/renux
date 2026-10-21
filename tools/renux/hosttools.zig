// SPDX-License-Identifier: BSD-2-Clause
//
// Copyright (c) 2026 The Renux Project
//
// hosttools.zig - the programs the build runs on the host, built by Zig
// from this tree as usr.bin/ builds them: yacc (contrib/byacc), awk
// (contrib/one-true-awk), rpcgen and vtfontcvt.  With them the build's
// generators (awk scripts, rpcgen, the console font) need nothing on the
// host but Zig.
//
// tools/renux/include holds the few BSD definitions these tools need and
// not every host C library has.

const std = @import("std");

pub const HostTools = struct {
    yacc: *std.Build.Step.Compile,
    awk: *std.Build.Step.Compile,
    rpcgen: *std.Build.Step.Compile,
    vtfontcvt: *std.Build.Step.Compile,
};

/// A C program for the host, without Zig's safety checks: the tools are
/// FreeBSD's, tested as FreeBSD builds them.
fn hostProgram(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
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

pub fn build(b: *std.Build) HostTools {
    // yacc, as usr.bin/yacc builds it.
    const yacc = hostProgram(b, "yacc");
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
    const gram = b.addRunArtifact(yacc);
    // awk's grammar has conflicts, which yacc reports on stderr, as it
    // does in FreeBSD's build.  They are expected: keep the report out of
    // the build's output, which would show it as a warning.
    gram.expectExitCode(0);
    _ = gram.captureStdErr(.{ .basename = "awkgram.conflicts" });
    gram.addArg("-d");
    gram.addArg("-H");
    const gram_h = gram.addOutputFileArg("awkgram.tab.h");
    gram.addArg("-o");
    const gram_c = gram.addOutputFileArg("awkgram.c");
    gram.addFileArg(b.path("contrib/one-true-awk/awkgram.y"));

    const maketab = hostProgram(b, "maketab");
    maketab.root_module.addIncludePath(gram_h.dirname());
    maketab.root_module.addIncludePath(b.path("contrib/one-true-awk"));
    maketab.root_module.addCSourceFile(.{ .file = b.path("contrib/one-true-awk/maketab.c") });

    const tab = b.addRunArtifact(maketab);
    tab.addFileArg(gram_h);
    const proctab = tab.captureStdOut(.{ .basename = "proctab.c" });

    const awk = hostProgram(b, "awk");
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
    const rpcgen = hostProgram(b, "rpcgen");
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
    const vt_inc = b.addWriteFiles();
    for ([_][]const u8{ "fnv_hash.h", "font.h", "queue.h" }) |h|
        _ = vt_inc.addCopyFile(b.path(b.fmt("sys/sys/{s}", .{h})), b.fmt("sys/{s}", .{h}));
    switch (b.graph.host.result.os.tag) {
        .linux => _ = vt_inc.addCopyFile(b.path("tools/build/cross-build/include/linux/sys/endian.h"), "sys/endian.h"),
        .macos => _ = vt_inc.addCopyFile(b.path("tools/build/cross-build/include/mac/sys/endian.h"), "sys/endian.h"),
        else => {},
    }
    const vtfontcvt = hostProgram(b, "vtfontcvt");
    vtfontcvt.root_module.addIncludePath(vt_inc.getDirectory());
    vtfontcvt.root_module.addIncludePath(b.path("sys/cddl/contrib/opensolaris/common/lz4"));
    const vt_flags: []const []const u8 = &.{ "-include", "tools/renux/include/bsdcompat.h" };
    vtfontcvt.root_module.addCSourceFile(.{ .file = b.path("usr.bin/vtfontcvt/vtfontcvt.c"), .flags = vt_flags });
    vtfontcvt.root_module.addCSourceFile(.{ .file = b.path("sys/cddl/contrib/opensolaris/common/lz4/lz4.c"), .flags = vt_flags });

    return .{ .yacc = yacc, .awk = awk, .rpcgen = rpcgen, .vtfontcvt = vtfontcvt };
}

/// contrib/byacc/VERSION, which usr.bin/yacc passes as YYPATCH.
fn byaccVersion(b: *std.Build) []const u8 {
    const path = b.root.join(b.allocator, "contrib/byacc/VERSION") catch @panic("OOM");
    const text = path.root_dir.handle.readFileAlloc(b.graph.io, path.sub_path, b.allocator, .unlimited) catch
        @panic("cannot read contrib/byacc/VERSION");
    b.dependOnFileContents(b.path("contrib/byacc/VERSION"));
    return std.mem.trim(u8, text, " \t\n");
}
