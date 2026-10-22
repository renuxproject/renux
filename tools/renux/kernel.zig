// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// kernel.zig - the kernel build: what sys/conf/kern.pre.mk, kern.post.mk
// and the Makefile config(8) writes do, as steps of the Zig build.
//
// Every command is a step, so Zig runs them in parallel and caches them;
// compilers report the headers they read (-MD), so a step runs again only
// when one of its inputs changes.  The tools are Zig's clang and lld and
// the host tools built from the tree (hosttools.zig, kgen.zig).
//
// The kernel is built in stages, each adding a directory of generated
// files to the include path that config(8)'s build directory ("-I.") is:
//
//   gen       option headers, config.c, env.c, hints.c, the machine
//             header links, and the awk and rpcgen products
//   offset    offset.inc (genoffset)
//   assym     assym.inc, ia32_assym.h (genassym)
//   late      what is made from assembled code: the ACPI wakeup code
//             and the vDSO headers
//
// then every object, then the link.

const std = @import("std");
const kconfig = @import("kconfig.zig");
const hosttools = @import("hosttools.zig");
const machine = @import("machine.zig");
const LazyPath = std.Build.LazyPath;
const Run = std.Build.Step.Run;

pub const Options = struct {
    cfg: *const kconfig.Config,
    machine: machine.Machine,
    tools: hosttools.HostTools,
    kgen: *std.Build.Step.Compile,
    kernconf: []const u8,
    /// sys/conf/newvers.sh's REVISION: the FreeBSD release of the tree.
    revision: []const u8,
};

pub const Kernel = struct {
    kernel: LazyPath,
    debug: LazyPath,
};

// --- Command arguments -----------------------------------------------------

/// One argument of a command: a string, or a path the build tracks.
const Arg = union(enum) {
    str: []const u8,
    /// A directory with a prefix: -I<dir>.
    dir: struct { prefix: []const u8, path: LazyPath },
    /// An input file.
    file: LazyPath,
    /// The output (${.TARGET}).
    out,

    /// The text make's :N and :M modifiers match.
    fn text(a: Arg) []const u8 {
        return switch (a) {
            .str => |s| s,
            .dir => |d| d.prefix,
            .file => "file",
            .out => "out",
        };
    }
};

/// make's glob: only '*' is used in the kernel's rules.
fn glob(pattern: []const u8, s: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, s);
    const head = pattern[0..star];
    const rest = pattern[star + 1 ..];
    if (!std.mem.startsWith(u8, s, head)) return false;
    if (rest.len == 0) return true;
    var i = head.len;
    while (i <= s.len) : (i += 1) if (glob(rest, s[i..])) return true;
    return false;
}

// --- The build -------------------------------------------------------------

const Builder = struct {
    b: *std.Build,
    opts: Options,
    machine: machine.Config,
    triple: []const u8,
    /// make variables, as in kern.pre.mk for this machine and compiler.
    vars: std.array_hash_map.String([]const u8) = .empty,
    /// The directories that stand for config(8)'s build directory.
    incdirs: std.ArrayList(LazyPath) = .empty,
    /// The build products, by the names the rules use.
    products: std.array_hash_map.String(LazyPath) = .empty,
    /// The objects to link, by name, in OBJS order.
    objects: std.array_hash_map.String(LazyPath) = .empty,

    fn fail(_: *Builder, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.panic("kernel: " ++ fmt, args);
    }

    fn set(k: *Builder, name: []const u8, value: []const u8) void {
        k.vars.put(k.b.allocator, name, value) catch @panic("OOM");
    }

    fn hasDefine(k: *Builder, header: []const u8, name: []const u8) bool {
        for (k.opts.cfg.headers.items) |h| {
            if (!std.mem.eql(u8, h.name, header)) continue;
            for (h.defines.items) |d| if (std.mem.eql(u8, d.name, name)) return true;
        }
        return false;
    }

    fn makeoption(k: *Builder, name: []const u8) []const u8 {
        for (k.opts.cfg.makeoptions.items) |m|
            if (std.mem.eql(u8, m.name, name)) return std.mem.join(k.b.allocator, " ", m.values.items) catch @panic("OOM");
        return "";
    }

    /// The make variables of kern.pre.mk and kern.mk, for clang.
    fn defineVars(k: *Builder) void {
        // As kern.pre.mk and Makefile.<machine> build them; "-I." is the
        // build directory, replaced by the generated directories.
        const frame = if (k.hasDefine("opt_ddb.h", "DDB") or k.hasDefine("opt_kdtrace.h", "KDTRACE_FRAME") or
            k.hasDefine("opt_hwpmc_hooks.h", "HWPMC_HOOKS"))
            "-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"
        else
            "";
        k.set("DEBUG", k.makeoption("DEBUG"));
        k.set("CFLAGS", k.b.fmt(
            "-O2 -pipe -fno-strict-aliasing ${{DEBUG}} -nostdinc -I. -I$S -I$S/contrib/ck/include " ++
                "-I$S/contrib/libfdt -D_KERNEL -DHAVE_KERNEL_OPTION_HEADERS -include opt_global.h " ++
                "-fno-common {s} -ffile-prefix-map=$S=/usr/src/sys {s} " ++
                "-ffreestanding -fwrapv -fstack-protector -gdwarf-4 " ++
                "-Wall -Wstrict-prototypes -Wmissing-prototypes -Wpointer-arith -Wcast-qual -Wundef " ++
                "-Wno-pointer-sign -D__printf__=__freebsd_kprintf__ -Wmissing-include-dirs " ++
                "-fdiagnostics-show-option -Wno-unknown-pragmas -Wswitch " ++
                "-Wno-error=tautological-compare -Wno-error=empty-body -Wno-error=parentheses-equality " ++
                "-Wno-error=unused-function -Wno-error=pointer-sign -Wno-error=shift-negative-value " ++
                "-Wno-address-of-packed-member -Wno-format-zero-length {s} -std=gnu17",
            .{ frame, k.machine.kernel_cflags, k.machine.kernel_cflags_late },
        ));
        // Zig's clang is newer than the tree's LLVM: its new warnings must
        // not stop the build.
        k.set("WERROR", "");
        k.set("ASM_CFLAGS", "-x assembler-with-cpp -DLOCORE ${CFLAGS}");
        k.set("NORMAL_C", "${CC} -c ${CFLAGS} ${WERROR} ${.IMPSRC}");
        k.set("NORMAL_C_NOWERROR", "${CC} -c ${CFLAGS} ${.IMPSRC}");
        k.set("NORMAL_S", "${CC} -c ${ASM_CFLAGS} ${WERROR} ${.IMPSRC}");
        k.set("NOSAN_C", "${NORMAL_C:N-fsanitize*:N-fno-sanitize*:N-fasan-shadow-offset*}");
        k.set("ZSTD_C", "${CC} -c -DZSTD_HEAPMODE=1 -I$S/contrib/zstd/lib/freebsd ${CFLAGS} " ++
            "-I$S/contrib/zstd/lib -I$S/contrib/zstd/lib/common ${WERROR} " ++
            "-Wno-missing-prototypes -U__BMI__ -DZSTD_NO_INTRINSICS ${.IMPSRC}");
        k.set("ZSTD_DECOMPRESS_BLOCK_FLAGS", "");
        k.set("ATH_CFLAGS", "-I${SRCTOP}/sys/dev/ath ${NO_WUNUSED_BUT_SET_VARIABLE}");
        k.set("ATH_C", "${CC} -c ${CFLAGS} ${WERROR} ${ATH_CFLAGS} ${.IMPSRC}");
        k.set("ZLIB_CFLAGS", "-Wno-cast-qual ${NO_WDEPRECATED_NON_PROTOTYPE} ${NO_WSTRICT_PROTOTYPES}");
        k.set("ZLIB_C", "${CC} -c ${CFLAGS} ${WERROR} ${ZLIB_CFLAGS} ${.IMPSRC}");
        k.set("LINUXKPI_INCLUDES", "-I$S/compat/linuxkpi/common/include -I$S/compat/linuxkpi/dummy/include " ++
            "-include $S/compat/linuxkpi/common/include/linux/kconfig.h");
        k.set("LINUXKPI_C", "${NORMAL_C} ${LINUXKPI_INCLUDES}");
        k.set("OFEDINCLUDES", "-I$S/ofed/include -I$S/ofed/include/uapi ${LINUXKPI_INCLUDES}");
        k.set("OFEDNOERR", "-Wno-cast-qual -Wno-pointer-arith");
        k.set("OFEDCFLAGS", "${CFLAGS:N-I*} -DCONFIG_INFINIBAND_USER_MEM ${OFEDINCLUDES} ${CFLAGS:M-I*} ${OFEDNOERR}");
        k.set("OFED_C_NOIMP", "${CC} -c -o ${.TARGET} ${OFEDCFLAGS} ${WERROR}");
        k.set("OFED_C", "${OFED_C_NOIMP} ${.IMPSRC}");
        k.set("MLXFW_C", "${OFED_C_NOIMP} -I${SRCTOP}/sys/contrib/xz-embedded/freebsd " ++
            "-I${SRCTOP}/sys/contrib/xz-embedded/linux/lib/xz ${.IMPSRC}");
        // bsd.sys.mk's warning flags, for clang.
        k.set("NO_WUNUSED_BUT_SET_VARIABLE", "-Wno-unused-but-set-variable");
        k.set("NO_WDEPRECATED_NON_PROTOTYPE", "-Wno-deprecated-non-prototype");
        k.set("NO_WSTRICT_PROTOTYPES", "-Wno-strict-prototypes");
        k.set("NO_WSOMETIMES_UNINITIALIZED", "-Wno-error=sometimes-uninitialized");
        k.set("NO_WCONSTANT_CONVERSION", "-Wno-error=constant-conversion");
        k.set("NO_WCAST_QUAL", "-Wno-error=cast-qual");
        k.set("NO_WUNNEEDED_INTERNAL_DECL", "-Wno-error=unneeded-internal-declaration");
        k.set("NO_WSHIFT_COUNT_OVERFLOW", "-Wno-shift-count-overflow");
        k.set("NO_WSHIFT_COUNT_NEGATIVE", "-Wno-shift-count-negative");
        k.set("NO_WBITWISE_INSTEAD_OF_LOGICAL", "-Wno-bitwise-instead-of-logical");
        k.set("FEEDER_EQ_PRESETS", k.makeoption("FEEDER_EQ_PRESETS"));
        k.set("FEEDER_RATE_PRESETS", k.makeoption("FEEDER_RATE_PRESETS"));
    }

    /// $S, ${SRCTOP}, ${MACHINE} and single-word variables inside a word.
    fn substitute(k: *Builder, word: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        const gpa = k.b.allocator;
        var i: usize = 0;
        while (i < word.len) {
            if (std.mem.startsWith(u8, word[i..], "$S")) {
                out.appendSlice(gpa, "sys") catch @panic("OOM");
                i += 2;
            } else if (std.mem.startsWith(u8, word[i..], "${")) {
                const end = std.mem.indexOfScalarPos(u8, word, i, '}') orelse k.fail("unterminated variable in {s}", .{word});
                const name = word[i + 2 .. end];
                const value = if (std.mem.eql(u8, name, "SRCTOP"))
                    "."
                else if (std.mem.eql(u8, name, "S"))
                    "sys"
                else if (std.mem.eql(u8, name, "MACHINE"))
                    k.opts.machine.name()
                else
                    k.vars.get(name) orelse k.fail("unknown variable {s}", .{name});
                out.appendSlice(gpa, value) catch @panic("OOM");
                i = end + 1;
            } else {
                out.append(gpa, word[i]) catch @panic("OOM");
                i += 1;
            }
        }
        return out.items;
    }

    /// Expand a rule into arguments.  `impsrc` is ${.IMPSRC}.
    fn expand(k: *Builder, text: []const u8, impsrc: ?Arg, args: *std.ArrayList(Arg)) void {
        const gpa = k.b.allocator;
        var it = std.mem.tokenizeAny(u8, text, " \t\n");
        while (it.next()) |word| {
            if (std.mem.startsWith(u8, word, "${") and std.mem.endsWith(u8, word, "}") and
                std.mem.indexOfScalar(u8, word, '}') == word.len - 1)
            {
                const ref = word[2 .. word.len - 1];
                var parts = std.mem.splitScalar(u8, ref, ':');
                const name = parts.next().?;
                var list: std.ArrayList(Arg) = .empty;
                if (std.mem.eql(u8, name, "CC")) {
                    list.appendSlice(gpa, &.{
                        .{ .str = k.b.graph.zig_exe },                                                      .{ .str = "clang" },
                        .{ .str = "-target" },                                                              .{ .str = k.triple },
                        .{ .dir = .{ .prefix = "-resource-dir=", .path = k.b.graph.path(.zig_lib, ".") } },
                    }) catch @panic("OOM");
                } else if (std.mem.eql(u8, name, ".IMPSRC")) {
                    list.append(gpa, impsrc orelse k.fail("no source for {s}", .{text})) catch @panic("OOM");
                } else if (std.mem.eql(u8, name, ".TARGET")) {
                    list.append(gpa, .out) catch @panic("OOM");
                } else {
                    const value = k.vars.get(name) orelse k.fail("unknown variable {s}", .{name});
                    k.expand(value, impsrc, &list);
                }
                // Modifiers: :Nglob, :Mglob, :C/^old$/new/.
                while (parts.next()) |mod| {
                    var kept: std.ArrayList(Arg) = .empty;
                    for (list.items) |a| {
                        switch (mod[0]) {
                            'N' => if (!glob(mod[1..], a.text())) kept.append(gpa, a) catch @panic("OOM"),
                            'M' => if (glob(mod[1..], a.text())) kept.append(gpa, a) catch @panic("OOM"),
                            'C' => {
                                var re = std.mem.splitScalar(u8, mod[2..], mod[1]);
                                const pat = re.next().?;
                                const rep = re.next().?;
                                if (pat.len < 2 or pat[0] != '^' or pat[pat.len - 1] != '$')
                                    k.fail("unsupported :C modifier {s}", .{mod});
                                if (a == .str and std.mem.eql(u8, a.str, pat[1 .. pat.len - 1]))
                                    kept.append(gpa, .{ .str = rep }) catch @panic("OOM")
                                else
                                    kept.append(gpa, a) catch @panic("OOM");
                            },
                            else => k.fail("unsupported modifier :{s}", .{mod}),
                        }
                    }
                    list = kept;
                }
                args.appendSlice(gpa, list.items) catch @panic("OOM");
            } else if (std.mem.eql(u8, word, "-I.")) {
                for (k.incdirs.items) |d| args.append(gpa, .{ .dir = .{ .prefix = "-I", .path = d } }) catch @panic("OOM");
            } else {
                const s = k.substitute(word);
                if (s.len > 0) args.append(gpa, .{ .str = s }) catch @panic("OOM");
            }
        }
    }

    /// A step that runs argv; `out` names its output.
    fn command(k: *Builder, name: []const u8, argv: []const Arg) struct { run: *Run, out: LazyPath } {
        const b = k.b;
        const run = Run.create(b, name);
        run.setCwd(b.path("."));
        var out: ?LazyPath = null;
        var skip_o = false;
        for (argv, 0..) |a, i| {
            if (skip_o) {
                skip_o = false;
                continue;
            }
            switch (a) {
                .str => |s| {
                    // "-o ${.TARGET}" is added once, below.
                    if (std.mem.eql(u8, s, "-o") and i + 1 < argv.len and argv[i + 1] == .out) {
                        skip_o = true;
                        continue;
                    }
                    run.addArg(s);
                },
                .dir => |d| run.addPrefixedDirectoryArg(d.prefix, d.path),
                .file => |f| run.addFileArg(f),
                .out => {},
            }
        }
        run.addArg("-o");
        out = run.addOutputFileArg(std.fs.path.basename(name));
        // Warnings go to stderr; only the exit status counts.
        run.expectExitCode(0);
        return .{ .run = run, .out = out.? };
    }

    /// Compile with a rule, with -MD so the step knows its headers.
    fn compile(k: *Builder, obj: []const u8, rule: []const u8, impsrc: ?Arg, extra: []const u8) LazyPath {
        var argv: std.ArrayList(Arg) = .empty;
        k.expand(rule, impsrc, &argv);
        k.expand(extra, impsrc, &argv);
        const c = k.command(obj, argv.items);
        c.run.addArg("-MD");
        _ = c.run.addPrefixedDepFileOutputArg("-MF", k.b.fmt("{s}.d", .{obj}));
        return c.out;
    }

    fn source(k: *Builder, f: kconfig.File) Arg {
        // An entry named after its object (acpi_wakecode.o) is made from
        // the first file of its dependency list.
        if (std.mem.endsWith(u8, f.path, ".o")) {
            const dep = f.dependency orelse k.fail("{s} has no dependency", .{f.path});
            var it = std.mem.tokenizeAny(u8, dep, " \t");
            return .{ .file = k.b.path(k.substitute(it.next().?)) };
        }
        if (f.srcprefix.len == 0) {
            const p = k.products.get(f.path) orelse k.fail("no rule makes {s}", .{f.path});
            return .{ .file = p };
        }
        return .{ .file = k.b.path(k.b.fmt("sys/{s}", .{f.path})) };
    }

    fn kgen(k: *Builder, name: []const u8, cmd: []const u8, inputs: []const LazyPath, extra: []const []const u8) LazyPath {
        const run = k.b.addRunArtifact(k.opts.kgen);
        run.setName(name);
        run.expectExitCode(0);
        run.addArg(cmd);
        for (inputs) |i| run.addFileArg(i);
        const out = run.addOutputFileArg(name);
        run.addArgs(extra);
        return out;
    }

    fn product(k: *Builder, name: []const u8) LazyPath {
        return k.products.get(name) orelse k.fail("{s} is not made yet", .{name});
    }

    fn addProduct(k: *Builder, name: []const u8, p: LazyPath) void {
        k.products.put(k.b.allocator, name, p) catch @panic("OOM");
    }

    /// A directory of generated files, added to the include path.
    fn includeDir(k: *Builder, names: []const []const u8) void {
        const wf = k.b.addWriteFiles();
        for (names) |n| _ = wf.addCopyFile(k.product(n), n);
        k.incdirs.append(k.b.allocator, wf.getDirectory()) catch @panic("OOM");
    }

    // --- Generators -------------------------------------------------------

    /// An awk generator: "${AWK} -f script args [> out]".  Those without a
    /// redirection write `name` into the current directory.
    fn awk(k: *Builder, name: []const u8, rule: []const u8) LazyPath {
        const b = k.b;
        var words: std.ArrayList([]const u8) = .empty;
        var redirect: ?[]const u8 = null;
        var it = std.mem.tokenizeAny(u8, rule, " \t");
        _ = it.next(); // ${AWK}
        while (it.next()) |w| {
            if (std.mem.eql(u8, w, ">")) {
                redirect = it.next();
                continue;
            }
            const s = k.substitute(w);
            if (s.len > 0) words.append(b.allocator, s) catch @panic("OOM");
        }
        if (redirect) |_| {
            const run = b.addRunArtifact(k.opts.tools.awk);
            run.setName(name);
            run.setCwd(b.path("."));
            run.expectExitCode(0);
            run.addArgs(words.items);
            return run.captureStdOut(.{ .basename = name });
        }
        const run = b.addRunArtifact(k.opts.kgen);
        run.setName(name);
        run.setCwd(b.path("."));
        run.expectExitCode(0);
        run.addArg("in");
        const dir = run.addOutputDirectoryArg("gen");
        run.addArtifactArg(k.opts.tools.awk);
        run.addArgs(words.items);
        return dir.path(b, name);
    }

    /// makeobjops.awk or vnode_if.awk: `flag` (-c, -h...) writes `name`.
    fn awkInDir(k: *Builder, name: []const u8, script: []const u8, input: []const u8, flag: []const u8) LazyPath {
        return k.awk(name, k.b.fmt("${{AWK}} -f {s} {s} {s}", .{ script, input, flag }));
    }

    /// rpcgen, with Zig's clang as its preprocessor and grep -v in kgen.
    fn rpcgen(k: *Builder, name: []const u8, rule: []const u8) LazyPath {
        const b = k.b;
        const run = b.addRunArtifact(k.opts.tools.rpcgen);
        run.setName(name);
        run.setCwd(b.path("."));
        run.expectExitCode(0);
        run.setEnvironmentVariable("RPCGEN_CPP", b.fmt("{s} clang --driver-mode=cpp -target {s}", .{ b.graph.zig_exe, k.triple }));
        var it = std.mem.tokenizeAny(u8, rule, " \t");
        _ = it.next(); // RPCGEN_CPP=...
        _ = it.next(); // rpcgen
        var grep: ?[]const u8 = null;
        var to_stdout = true;
        while (it.next()) |w| {
            if (std.mem.eql(u8, w, "|")) {
                _ = it.next(); // grep
                _ = it.next(); // -v
                grep = it.next();
                break;
            }
            if (std.mem.eql(u8, w, "-o")) {
                _ = it.next();
                run.addArg("-o");
                to_stdout = false;
                return run.addOutputFileArg(name);
            }
            run.addArg(k.substitute(w));
        }
        const raw = run.captureStdOut(.{ .basename = b.fmt("{s}.raw", .{name}) });
        const pattern = grep orelse return raw;
        return k.kgen(name, "grepv", &.{raw}, &.{pattern});
    }

    /// sys/tools/amd64_vdso.sh and amd64_ia32_vdso.sh.
    fn vdso(k: *Builder, f: kconfig.File) void {
        const b = k.b;
        const ia32 = std.mem.indexOf(u8, f.compile_with.?, "ia32") != null;
        const so = if (ia32) "elf-vdso32.so.1" else "elf-vdso.so.1";
        const asm_src = if (ia32) "sys/amd64/ia32/ia32_sigtramp.S" else "sys/amd64/amd64/sigtramp.S";
        const ldscript = if (ia32) "sys/conf/vdso_amd64_ia32.ldscript" else "sys/conf/vdso_amd64.ldscript";
        const sym = if (ia32) "elf_vdso32_so_1" else "elf_vdso_so_1";
        const cflags = "${CC} -x assembler-with-cpp -DLOCORE -fPIC -nostdinc -c -I. -I$S -include opt_global.h";

        const pico = k.compile(
            if (ia32) "ia32_sigtramp.pico" else "sigtramp.pico",
            if (ia32) cflags ++ " -m32 ${.IMPSRC}" else cflags ++ " ${.IMPSRC}",
            .{ .file = b.path(asm_src) },
            "",
        );

        const ld = Run.create(b, so);
        ld.expectExitCode(0);
        ld.addArgs(&.{ b.graph.zig_exe, "ld.lld", "--shared", "-Bsymbolic", b.fmt("-soname={s}", .{so}), "-T" });
        ld.addFileArg(b.path(ldscript));
        ld.addArgs(&.{ "--eh-frame-hdr", "--no-undefined", "-z", "rodynamic", "-z", "norelro", "-nmagic", "--hash-style=sysv", "--fatal-warnings", "--strip-all", "-o" });
        const raw = ld.addOutputFileArg(b.fmt("{s}.raw", .{so}));
        ld.addFileArg(pico);
        const checked = k.kgen(so, "vdso-check", &.{raw}, &.{});

        // The object that carries the vDSO, found through -I with .incbin.
        var argv: std.ArrayList(Arg) = .empty;
        k.expand(cflags, null, &argv);
        argv.append(b.allocator, .{ .str = b.fmt("-DVDSO_NAME={s}", .{sym}) }) catch @panic("OOM");
        argv.append(b.allocator, .{ .str = b.fmt("-DVDSO_FILE=\"{s}\"", .{so}) }) catch @panic("OOM");
        argv.append(b.allocator, .{ .dir = .{ .prefix = "-I", .path = checked.dirname() } }) catch @panic("OOM");
        argv.append(b.allocator, .{ .file = b.path("sys/tools/vdso_wrap.S") }) catch @panic("OOM");
        k.objects.put(b.allocator, f.path, k.command(f.path, argv.items).out) catch @panic("OOM");

        const header = if (ia32) "vdso_ia32_offsets.h" else "vdso_offsets.h";
        const rules: []const []const u8 = if (ia32) &.{
            "__vdso_ia32_sigcode=VDSO_IA32_SIGCODE_OFFSET",
            "__vdso_freebsd4_ia32_sigcode=VDSO_FREEBSD4_IA32_SIGCODE_OFFSET",
            "__vdso_ia32_osigcode=VDSO_IA32_OSIGCODE_OFFSET",
            "__vdso_lcall_tramp=VDSO_LCALL_TRAMP_OFFSET",
        } else &.{"__vdso_sigcode=VDSO_SIGCODE_OFFSET"};
        k.addProduct(header, k.kgen(header, "vdso-offsets", &.{checked}, rules));
    }

    // --- The stages -------------------------------------------------------

    /// The object a generator rule reads: its word that ends in ".o".
    fn objectIn(rule: []const u8) []const u8 {
        var it = std.mem.tokenizeAny(u8, rule, " \t");
        while (it.next()) |w| if (std.mem.endsWith(u8, w, ".o")) return w;
        std.debug.panic("kernel: no object in rule {s}", .{rule});
    }

    fn kind(rule: []const u8) enum { awk, rpcgen, genassym, binary, file2c, nmdefs, vdso, compile } {
        if (std.mem.startsWith(u8, rule, "${AWK}")) return .awk;
        if (std.mem.indexOf(u8, rule, "rpcgen") != null) return .rpcgen;
        if (std.mem.indexOf(u8, rule, "genassym.sh") != null) return .genassym;
        if (std.mem.startsWith(u8, rule, "${OBJCOPY}")) return .binary;
        if (std.mem.startsWith(u8, rule, "file2c")) return .file2c;
        if (std.mem.startsWith(u8, rule, "${NM}")) return .nmdefs;
        if (std.mem.indexOf(u8, rule, "vdso.sh") != null) return .vdso;
        return .compile;
    }

    /// The object of one entry of the file lists.
    fn object(k: *Builder, f: kconfig.File) void {
        const b = k.b;
        const obj = f.object(b.allocator) catch @panic("OOM");
        const suffix = f.suffix();
        var p: LazyPath = undefined;
        if (std.mem.eql(u8, suffix, "m")) {
            // NORMAL_M: makeobjops.awk -c, then the C file.
            const base = std.fs.path.stem(f.path);
            const c = k.product(b.fmt("{s}.c", .{base}));
            const rule = f.compile_with orelse "${NORMAL_M}";
            p = k.compile(obj, "${NORMAL_C}", .{ .file = c }, rule["${NORMAL_M}".len..]);
        } else if (f.compile_with) |rule| {
            if (kind(rule) == .compile) {
                p = k.compile(obj, rule, k.source(f), "");
            } else {
                // A generated C file (rpcgen), compiled as any other.
                p = k.compile(obj, "${NORMAL_C}", .{ .file = k.product(f.path) }, "");
            }
        } else if (std.mem.eql(u8, suffix, "c")) {
            p = k.compile(obj, if (f.nowerror) "${NORMAL_C_NOWERROR}" else "${NORMAL_C}", k.source(f), "");
        } else if (std.mem.eql(u8, suffix, "S")) {
            p = k.compile(obj, "${NORMAL_S}", k.source(f), "");
        } else {
            k.fail("no rule for {s}", .{f.path});
        }
        if (!f.no_obj) k.objects.put(b.allocator, obj, p) catch @panic("OOM");
        k.addProduct(obj, p);
    }

    fn build(k: *Builder) Kernel {
        const b = k.b;
        const cfg = k.opts.cfg;
        const gpa = b.allocator;
        k.defineVars();

        // gen: the option headers, config.c and the rest, the machine
        // headers, and everything awk and rpcgen make.
        const gen = b.addWriteFiles();
        for (cfg.headers.items) |h| {
            var text: std.ArrayList(u8) = .empty;
            for (h.defines.items) |d| text.print(gpa, "#define {s} {s}\n", .{ d.name, d.value.? }) catch @panic("OOM");
            _ = gen.add(h.name, text.items);
        }
        k.addProduct("config.c", gen.add("config.c", cfg.config_c));
        k.addProduct("env.c", gen.add("env.c", cfg.env_c));
        k.addProduct("hints.c", gen.add("hints.c", cfg.hints_c));
        k.addProduct("force-dynamic-hack.c", gen.add("force-dynamic-hack.c", ""));
        for (k.machine.headers) |h| _ = gen.addCopyDirectory(b.path(h[1]), h[0], .{});

        const vnode = [_][2][]const u8{ .{ "vnode_if.c", "-c" }, .{ "vnode_if.h", "-h" }, .{ "vnode_if_newproto.h", "-p" }, .{ "vnode_if_typedef.h", "-q" } };
        for (vnode) |v| {
            const p = k.awkInDir(v[0], "$S/tools/vnode_if.awk", "$S/kern/vnode_if.src", v[1]);
            k.addProduct(v[0], p);
            _ = gen.addCopyFile(p, v[0]);
        }
        for (cfg.files.items) |f| {
            if (!std.mem.eql(u8, f.suffix(), "m")) continue;
            const base = std.fs.path.stem(f.path);
            for ([_][2][]const u8{ .{ "c", "-c" }, .{ "h", "-h" } }) |x| {
                const name = b.fmt("{s}.{s}", .{ base, x[0] });
                const p = k.awkInDir(name, "$S/tools/makeobjops.awk", b.fmt("$S/{s}", .{f.path}), x[1]);
                k.addProduct(name, p);
                if (x[0][0] == 'h') _ = gen.addCopyFile(p, name);
            }
        }
        for (cfg.files.items) |f| {
            const rule = f.compile_with orelse continue;
            const p = switch (kind(rule)) {
                .awk => k.awk(f.path, rule),
                .rpcgen => k.rpcgen(f.path, rule),
                else => continue,
            };
            k.addProduct(f.path, p);
            if (std.mem.endsWith(u8, f.path, ".h")) _ = gen.addCopyFile(p, f.path);
        }
        k.incdirs.append(gpa, gen.getDirectory()) catch @panic("OOM");

        // offset: genoffset.  genoffset_test.o checks offset.inc.
        const genrule = "${CC} -c ${CFLAGS:N-flto*:N-fno-common:N-fsanitize*:N-fno-sanitize*:N-fasan-shadow-offset*} -fcommon ${.IMPSRC}";
        const genoffset = k.compile("genoffset.o", genrule, .{ .file = b.path("sys/kern/genoffset.c") }, "");
        k.addProduct("offset.inc", k.kgen("offset.inc", "genoffset", &.{genoffset}, &.{}));
        k.includeDir(&.{"offset.inc"});
        const offset_test = k.compile("genoffset_test.o", genrule, .{ .file = b.path("sys/kern/genoffset.c") }, "-DOFFSET_TEST");

        // assym: genassym, and the other genassym objects of the file lists.
        const genassym = k.compile("genassym.o", genrule, .{ .file = b.path(b.fmt("sys/{s}/{s}/genassym.c", .{ k.opts.cfg.machine, k.opts.cfg.machine })) }, "");
        k.addProduct("assym.inc", k.kgen("assym.inc", "genassym", &.{genassym}, &.{}));
        var assym_names: std.ArrayList([]const u8) = .empty;
        assym_names.append(gpa, "assym.inc") catch @panic("OOM");
        for (cfg.files.items) |f| {
            const rule = f.compile_with orelse continue;
            if (kind(rule) != .genassym) continue;
            const input = objectIn(rule);
            const src = for (cfg.files.items) |g| {
                if (std.mem.eql(u8, g.path, input)) break g;
            } else k.fail("no rule makes {s}", .{input});
            const obj = k.compile(input, src.compile_with.?, k.source(src), "");
            k.addProduct(f.path, k.kgen(f.path, "genassym", &.{obj}, &.{}));
            assym_names.append(gpa, f.path) catch @panic("OOM");
        }
        k.includeDir(assym_names.items);

        // late: what is made from assembled code.
        var late: std.ArrayList([]const u8) = .empty;
        for (cfg.files.items) |f| {
            const rule = f.compile_with orelse continue;
            switch (kind(rule)) {
                .binary => k.addProduct(f.path, k.kgen(f.path, "binary", &.{k.product(objectIn(rule))}, &.{})),
                .file2c => {
                    // file2c -sx 'PREFIX' 'SUFFIX' < IN > ${.TARGET}
                    const q1 = std.mem.indexOfScalar(u8, rule, '\'').?;
                    const q2 = std.mem.indexOfScalarPos(u8, rule, q1 + 1, '\'').?;
                    const q3 = std.mem.indexOfScalarPos(u8, rule, q2 + 1, '\'').?;
                    const q4 = std.mem.indexOfScalarPos(u8, rule, q3 + 1, '\'').?;
                    var it = std.mem.tokenizeAny(u8, rule[std.mem.indexOfScalar(u8, rule, '<').? + 1 ..], " \t");
                    const in = it.next().?;
                    k.addProduct(f.path, k.kgen(f.path, "file2c", &.{k.product(in)}, &.{ rule[q1 + 1 .. q2], rule[q3 + 1 .. q4] }));
                    late.append(gpa, f.path) catch @panic("OOM");
                },
                .nmdefs => {
                    k.addProduct(f.path, k.kgen(f.path, "nmdefs", &.{k.product(objectIn(rule))}, &.{}));
                    late.append(gpa, f.path) catch @panic("OOM");
                },
                .vdso => {
                    k.vdso(f);
                    late.append(gpa, if (std.mem.indexOf(u8, rule, "ia32") != null) "vdso_ia32_offsets.h" else "vdso_offsets.h") catch @panic("OOM");
                },
                .compile => if (f.before_depend) k.object(f),
                else => {},
            }
        }
        k.includeDir(late.items);

        // Every object.  The no-obj entries are not in OBJS, but locore.S
        // is, as locore.o, first in the link; the rpcgen C files are made
        // before depend and compiled as any other.
        for (cfg.files.items) |f| {
            if (f.compile_with) |rule| switch (kind(rule)) {
                .compile => if (f.before_depend or f.no_obj) continue,
                .rpcgen => if (f.no_obj) continue,
                else => continue,
            } else if (f.no_obj and !std.mem.endsWith(u8, f.path, "locore.S")) continue;
            k.object(f);
        }
        const system = [_][]const u8{ "config.c", "env.c", "hints.c", "vnode_if.c" };
        for (system) |c| {
            const obj = b.fmt("{s}.o", .{c[0 .. c.len - 2]});
            k.objects.put(gpa, obj, k.compile(obj, "${NORMAL_C}", .{ .file = k.product(c) }, "")) catch @panic("OOM");
        }

        // force-dynamic-hack.pico: an empty shared object, so that the
        // kernel is a dynamic executable.  The kernel records it as
        // needed, by its soname: its name alone, as in FreeBSD's build,
        // and not the path of the cache, so the kernel does not change
        // with the cache.
        const hack_o = k.compile("force-dynamic-hack.o", "${NORMAL_C}", .{ .file = k.product("force-dynamic-hack.c") }, "");
        const hack = Run.create(b, "force-dynamic-hack.pico");
        hack.expectExitCode(0);
        hack.addArgs(&.{ b.graph.zig_exe, "ld.lld", "-m", k.machine.emulation, "-shared", "-soname=force-dynamic-hack.pico", "-o" });
        const hack_pico = hack.addOutputFileArg("force-dynamic-hack.pico");
        hack.addFileArg(hack_o);

        // vers.c, then the link (SYSTEM_LD of kern.pre.mk).
        const vers_c = b.addRunArtifact(k.opts.kgen);
        vers_c.expectExitCode(0);
        vers_c.addArg("vers");
        const vers_src = vers_c.addOutputFileArg("vers.c");
        vers_c.addArgs(&.{ ".", k.opts.kernconf, b.graph.zig_exe });
        vers_c.setCwd(b.path("."));
        vers_c.addFileInput(b.path("sys/conf/newvers.sh"));
        vers_c.addFileInput(b.path("sys/sys/param.h"));
        vers_c.addFileInput(b.path("COPYRIGHT"));
        const vers_o = k.compile("vers.o", "${NORMAL_C}", .{ .file = vers_src }, "");

        // kern.post.mk links kernel.full, then splits it with objcopy into
        // kernel and kernel.debug.  Zig's objcopy cannot strip a kernel
        // yet, so the linker makes both: kernel.full, which serves as
        // kernel.debug, and the kernel without its debug sections.
        // TODO: .gnu_debuglink in the kernel, and a kernel.debug with the
        // debug sections only.
        const full = k.link("kernel.full", false, hack_pico, vers_o, offset_test);
        const kernel = k.link("kernel", true, hack_pico, vers_o, offset_test);
        return .{ .kernel = kernel, .debug = full };
    }

    /// SYSTEM_LD of kern.pre.mk: locore.o, OBJS in config(8)'s order, the
    /// files config(8) writes, the hack, then vers.o.
    /// `check` (genoffset_test.o, which checks offset.inc) must build first.
    fn link(k: *Builder, name: []const u8, strip: bool, hack: LazyPath, vers: LazyPath, check: LazyPath) LazyPath {
        const b = k.b;
        const cfg = k.opts.cfg;
        const run = Run.create(b, name);
        check.addStepDependencies(&run.step);
        run.setCwd(b.path("."));
        run.expectExitCode(0);
        run.addArgs(&.{ b.graph.zig_exe, "ld.lld", "-m", k.machine.emulation, "-Bdynamic", "-L", "sys/conf", "-T" });
        run.addFileArg(b.path(b.fmt("sys/conf/ldscript.{s}", .{cfg.machine})));
        run.addArgs(&.{
            "--build-id=sha1",  "-z",           "max-page-size=2097152", "-z",            "notext",
            "-z",               "ifunc-noplt",  "--no-warn-mismatch",    "--warn-common", "--export-dynamic",
            "--dynamic-linker", "/red/herring", "-X",
        });
        if (strip) run.addArg("--strip-debug");
        run.addArg("-o");
        const out = run.addOutputFileArg(name);
        run.addFileArg(k.product("locore.o"));
        for (cfg.files.items) |f| {
            if (f.no_obj) continue;
            const obj = f.object(b.allocator) catch @panic("OOM");
            run.addFileArg(k.objects.get(obj) orelse k.fail("no rule makes {s}", .{obj}));
        }
        for ([_][]const u8{ "config.o", "env.o", "hints.o", "vnode_if.o" }) |o| run.addFileArg(k.objects.get(o).?);
        run.addFileArg(hack);
        run.addFileArg(vers);
        return out;
    }
};

pub fn build(b: *std.Build, opts: Options) Kernel {
    const config = opts.machine.config() orelse
        std.debug.panic("kernel: the Zig build does not support {s} yet", .{opts.machine.name()});
    var k: Builder = .{
        .b = b,
        .opts = opts,
        .machine = config,
        .triple = config.triple(b, opts.revision),
    };
    return k.build();
}
