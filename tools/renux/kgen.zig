// SPDX-License-Identifier: BSD-2-Clause
//
// Copyright (c) 2026 The Renux Project
//
// kgen.zig - the kernel build's small tools, so that the host needs
// nothing but Zig.  Each subcommand does what a FreeBSD shell pipeline of
// the kernel build does, with the same output:
//
//   genassym OBJ OUT         sys/kern/genassym.sh (nm + awk)
//   genoffset OBJ OUT        sys/kern/genoffset.sh (nm + sed + sort)
//   nmdefs OBJ OUT           nm -n --defined-only | "#define name 0xaddr"
//   binary OBJ OUT           objcopy -S -O binary, for relocatable objects
//   file2c IN OUT PRE POST   file2c -sx PRE POST < IN
//   grepv IN OUT PATTERN     grep -v PATTERN < IN
//   vdso-check SO OUT        the checks of sys/tools/amd64*_vdso.sh; OUT is SO
//   vdso-offsets SO OUT PAT=MACRO...
//                            nm -D SO | awk '/PAT/{printf "#define MACRO 0x%s\n",$1}'
//   vers OUT SRCTOP IDENT ZIG
//                            sys/conf/newvers.sh -R, without version control
//   in DIR PROG ARG...       run PROG in DIR (for generators that write to .)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

var io: Io = undefined;
var gpa: Allocator = undefined;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("kgen: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn readFile(path: []const u8) []u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err|
        fatal("{s}: {t}", .{ path, err });
}

fn writeFile(path: []const u8, data: []const u8) void {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |err|
        fatal("{s}: {t}", .{ path, err });
}

// --- ELF -------------------------------------------------------------------

const SHN_UNDEF = 0;
const SHN_COMMON = 0xfff2;
const SHF_ALLOC = 0x2;
const SHT_PROGBITS = 1;
const SHT_SYMTAB = 2;
const SHT_DYNAMIC = 6;
const SHT_DYNSYM = 11;
const STT_SECTION = 3;
const STT_FILE = 4;

/// Enough of ELF (32 and 64 bits, little-endian) to list symbols and
/// sections, as nm and objcopy do.
const Elf = struct {
    data: []const u8,
    is64: bool,

    const Section = struct {
        name: []const u8,
        type: u32,
        flags: u64,
        addr: u64,
        offset: u64,
        size: u64,
        link: u32,
    };

    const Symbol = struct {
        name: []const u8,
        value: u64,
        size: u64,
        type: u4,
        shndx: u16,
    };

    fn open(path: []const u8) Elf {
        const data = readFile(path);
        if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF") or data[5] != 1)
            fatal("{s}: not a little-endian ELF file", .{path});
        return .{ .data = data, .is64 = data[4] == 2 };
    }

    fn int(e: Elf, comptime T: type, off: u64) T {
        return std.mem.readInt(T, e.data[@intCast(off)..][0..@sizeOf(T)], .little);
    }

    /// A word that is 32 bits in ELF32 and 64 bits in ELF64.
    fn word(e: Elf, off: u64) u64 {
        return if (e.is64) e.int(u64, off) else e.int(u32, off);
    }

    fn sectionCount(e: Elf) u16 {
        return e.int(u16, if (e.is64) 0x3c else 0x30);
    }

    fn section(e: Elf, i: usize) Section {
        const shoff = e.word(if (e.is64) 0x28 else 0x20);
        const shentsize = e.int(u16, if (e.is64) 0x3a else 0x2e);
        const shstrndx = e.int(u16, if (e.is64) 0x3e else 0x32);
        const sh = shoff + i * shentsize;
        const strtab = e.rawSection(shoff + @as(u64, shstrndx) * shentsize);
        return .{
            .name = e.str(strtab.offset, e.int(u32, sh)),
            .type = e.int(u32, sh + 4),
            .flags = e.word(sh + 8),
            .addr = e.word(if (e.is64) sh + 0x10 else sh + 0x0c),
            .offset = e.word(if (e.is64) sh + 0x18 else sh + 0x10),
            .size = e.word(if (e.is64) sh + 0x20 else sh + 0x14),
            .link = e.int(u32, if (e.is64) sh + 0x28 else sh + 0x18),
        };
    }

    fn rawSection(e: Elf, sh: u64) struct { offset: u64 } {
        return .{ .offset = e.word(if (e.is64) sh + 0x18 else sh + 0x10) };
    }

    fn str(e: Elf, table: u64, off: u32) []const u8 {
        const s = e.data[@intCast(table + off)..];
        return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
    }

    fn contents(e: Elf, s: Section) []const u8 {
        return e.data[@intCast(s.offset)..][0..@intCast(s.size)];
    }

    /// The symbols of the first section of type `kind` (symtab or dynsym),
    /// without the null symbol.
    fn symbols(e: Elf, kind: u32) []Symbol {
        var list: std.ArrayList(Symbol) = .empty;
        for (0..e.sectionCount()) |i| {
            const s = e.section(i);
            if (s.type != kind) continue;
            const strtab = e.section(s.link);
            const entsize: u64 = if (e.is64) 24 else 16;
            var off = s.offset + entsize;
            while (off < s.offset + s.size) : (off += entsize) {
                const info = e.data[@intCast(if (e.is64) off + 4 else off + 12)];
                list.append(gpa, .{
                    .name = e.str(strtab.offset, e.int(u32, off)),
                    .value = e.word(if (e.is64) off + 8 else off + 4),
                    .size = e.word(if (e.is64) off + 16 else off + 8),
                    .type = @truncate(info & 0xf),
                    .shndx = e.int(u16, if (e.is64) off + 6 else off + 14),
                }) catch @panic("OOM");
            }
            break;
        }
        return list.items;
    }
};

/// The symbols nm(1) lists: no section or file symbols, no empty names.
fn nmSymbols(e: Elf, kind: u32) []Elf.Symbol {
    var list: std.ArrayList(Elf.Symbol) = .empty;
    for (e.symbols(kind)) |s| {
        if (s.name.len == 0 or s.type == STT_SECTION or s.type == STT_FILE) continue;
        list.append(gpa, s) catch @panic("OOM");
    }
    return list.items;
}

fn byName(_: void, a: Elf.Symbol, b: Elf.Symbol) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// nm(1) prints a common symbol's size where others have their address.
fn nmValue(s: Elf.Symbol) u64 {
    return if (s.shndx == SHN_COMMON) s.size else s.value;
}

// --- genassym and genoffset ------------------------------------------------

fn genassym(obj: []const u8, out_path: []const u8) void {
    const syms = nmSymbols(Elf.open(obj), SHT_SYMTAB);
    std.mem.sort(Elf.Symbol, syms, {}, byName);
    var out: std.ArrayList(u8) = .empty;
    // The awk program of genassym.sh: each value is spread over the low 16
    // bits of the sizes of five common symbols, name{sign,w0,w1,w2,w3}.
    var sign: []const u8 = "";
    var w: [4][]const u8 = .{ "", "", "", "" };
    for (syms) |s| {
        if (s.shndx != SHN_COMMON) continue;
        const hex = std.fmt.allocPrint(gpa, "{x:0>16}", .{nmValue(s)}) catch @panic("OOM");
        const low = hex[hex.len - 4 ..];
        if (std.mem.endsWith(u8, s.name, "sign")) {
            sign = if (std.mem.trimStart(u8, low, "0").len > 0) "-" else "";
        } else if (s.name.len >= 2 and s.name[s.name.len - 2] == 'w' and
            s.name[s.name.len - 1] >= '0' and s.name[s.name.len - 1] <= '3')
        {
            const n = s.name[s.name.len - 1] - '0';
            w[n] = low;
            if (n == 3) {
                const all = std.mem.concat(gpa, u8, &.{ w[3], w[2], w[1], w[0] }) catch @panic("OOM");
                var v = std.mem.trimStart(u8, all, "0");
                if (v.len == 0) v = "0";
                const prefix = if (std.mem.eql(u8, v, "0")) "" else "0x";
                out.print(gpa, "#define\t{s}\t{s}{s}{s}\n", .{ s.name[0 .. s.name.len - 2], sign, prefix, v }) catch @panic("OOM");
            }
        }
    }
    writeFile(out_path, out.items);
}

fn genoffset(obj: []const u8, out_path: []const u8) void {
    const Entry = struct { line: []const u8, off: u64, struct_: []const u8, field: []const u8, type: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    for (nmSymbols(Elf.open(obj), SHT_SYMTAB)) |s| {
        if (std.mem.indexOf(u8, s.name, "__assym_offset__") == null) continue;
        // `nm -t d | sed -e 's/__/ /g'`, then read into
        // "off x1 x2 struct field type".
        const nmline = std.fmt.allocPrint(gpa, "{d:0>16} C {s}", .{ nmValue(s), s.name }) catch @panic("OOM");
        const line = std.mem.replaceOwned(u8, gpa, nmline, "__", " ") catch @panic("OOM");
        var it = std.mem.tokenizeAny(u8, line, " \t");
        var f: [6][]const u8 = .{ "", "", "", "", "", "" };
        for (&f) |*x| x.* = it.next() orelse "";
        entries.append(gpa, .{ .line = line, .off = nmValue(s), .struct_ = f[3], .field = f[4], .type = f[5] }) catch @panic("OOM");
    }
    // sort -k 4 -k 1 -n: the struct names are not numbers, so this sorts
    // by offset, then by the whole line.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.off != b.off) return a.off < b.off;
            return std.mem.order(u8, a.line, b.line) == .lt;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    var asserts: std.ArrayList(u8) = .empty;
    const p = struct {
        fn f(o: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
            o.print(gpa, fmt, args) catch @panic("OOM");
        }
    }.f;
    p(&out, "#ifndef _OFFSET_INC_\n#define _OFFSET_INC_\n", .{});
    p(&out, "#if !defined(GENOFFSET) && (!defined(KLD_MODULE) || defined(KLD_TIED))\n", .{});
    var last: []const u8 = "";
    var lastoff: u64 = 0;
    var lasttype: []const u8 = "";
    for (entries.items) |e| {
        if (!std.mem.eql(u8, last, e.struct_)) {
            if (last.len > 0) p(&out, "}};\n", .{});
            p(&out, "struct {s}_lite {{\n", .{e.struct_});
            last = e.struct_;
            p(&out, "\tu_char\tpad_{s}[{d}];\n", .{ e.field, e.off });
        } else {
            p(&out, "\tu_char\tpad_{s}[{d} - ({d} + sizeof({s}))];\n", .{ e.field, e.off, lastoff, lasttype });
        }
        p(&out, "\t{s}\t{s};\n", .{ e.type, e.field });
        lastoff = e.off;
        lasttype = e.type;
        p(&asserts, "_SA({s}, {s}, {d});\n", .{ e.struct_, e.field, e.off });
    }
    p(&out, "}};\n", .{});
    p(&out, "#define _SA(s,f,o) _Static_assert(__builtin_offsetof(struct s ## _lite, f) == o, \\\n", .{});
    p(&out, "\t\"struct \"#s\"_lite field \"#f\" not at offset \"#o)\n", .{});
    p(&out, "{s}#undef _SA\n#endif\n#endif\n", .{asserts.items});
    writeFile(out_path, out.items);
}

// --- nm, objcopy and file2c ------------------------------------------------

fn nmdefs(obj: []const u8, out_path: []const u8) void {
    const e = Elf.open(obj);
    var list: std.ArrayList(Elf.Symbol) = .empty;
    for (nmSymbols(e, SHT_SYMTAB)) |s| if (s.shndx != SHN_UNDEF) list.append(gpa, s) catch @panic("OOM");
    // nm -n: by address, then by name.
    std.mem.sort(Elf.Symbol, list.items, {}, struct {
        fn lt(_: void, a: Elf.Symbol, b: Elf.Symbol) bool {
            if (nmValue(a) != nmValue(b)) return nmValue(a) < nmValue(b);
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (list.items) |s| {
        const v = nmValue(s);
        if (e.is64)
            out.print(gpa, "#define\t{s}\t0x{x:0>16}\n", .{ s.name, v }) catch @panic("OOM")
        else
            out.print(gpa, "#define\t{s}\t0x{x:0>8}\n", .{ s.name, v }) catch @panic("OOM");
    }
    writeFile(out_path, out.items);
}

/// objcopy -O binary of a relocatable object: the contents of its
/// allocated sections.  Every section starts at 0 in a relocatable
/// object, so there may be only one that is not empty.
fn binary(obj: []const u8, out_path: []const u8) void {
    const e = Elf.open(obj);
    var found: ?Elf.Section = null;
    for (0..e.sectionCount()) |i| {
        const s = e.section(i);
        if (s.type != SHT_PROGBITS or s.flags & SHF_ALLOC == 0 or s.size == 0) continue;
        if (found != null) fatal("{s}: more than one allocated section", .{obj});
        found = s;
    }
    const s = found orelse fatal("{s}: no allocated section", .{obj});
    writeFile(out_path, e.contents(s));
}

/// usr.bin/file2c with -s -x.
fn file2c(in_path: []const u8, out_path: []const u8, prefix: []const u8, suffix: []const u8) void {
    const in = readFile(in_path);
    var out: std.ArrayList(u8) = .empty;
    out.print(gpa, "{s}\n", .{prefix}) catch @panic("OOM");
    var count: usize = 0;
    var linepos: usize = 0;
    for (in) |c| {
        if (count > 0) {
            out.append(gpa, ',') catch @panic("OOM");
            linepos += 1;
        }
        if (linepos > 70) {
            out.append(gpa, '\n') catch @panic("OOM");
            count = 0;
            linepos = 0;
        }
        if (count > 0) {
            out.append(gpa, ' ') catch @panic("OOM");
            linepos += 1;
        } else {
            out.append(gpa, '\t') catch @panic("OOM");
            linepos += 8;
        }
        out.print(gpa, "0x{x:0>2}", .{c}) catch @panic("OOM");
        linepos += 4;
        count += 1;
    }
    out.print(gpa, "\n{s}\n", .{suffix}) catch @panic("OOM");
    writeFile(out_path, out.items);
}

fn grepv(in_path: []const u8, out_path: []const u8, pattern: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, readFile(in_path), '\n');
    while (it.next()) |line| {
        if (it.peek() == null and line.len == 0) break;
        if (std.mem.indexOf(u8, line, pattern) != null) continue;
        out.print(gpa, "{s}\n", .{line}) catch @panic("OOM");
    }
    writeFile(out_path, out.items);
}

// --- The vDSO --------------------------------------------------------------

/// The checks of sys/tools/amd64_vdso.sh: at most 2 KB, and no runtime
/// relocations (DT_RELSZ, DT_RELASZ, DT_RELRSZ).
fn vdsoCheck(so: []const u8, out_path: []const u8) void {
    const e = Elf.open(so);
    if (e.data.len > 2048) fatal("{s} too large", .{so});
    for (0..e.sectionCount()) |i| {
        const s = e.section(i);
        if (s.type != SHT_DYNAMIC) continue;
        const entsize: u64 = if (e.is64) 16 else 8;
        var off = s.offset;
        while (off < s.offset + s.size) : (off += entsize) {
            switch (e.word(off)) {
                8, 18, 35 => fatal("{s} contains runtime relocations", .{so}),
                else => {},
            }
        }
    }
    writeFile(out_path, e.data);
}

fn vdsoOffsets(so: []const u8, out_path: []const u8, rules: []const [:0]const u8) void {
    const e = Elf.open(so);
    const syms = nmSymbols(e, SHT_DYNSYM);
    std.mem.sort(Elf.Symbol, syms, {}, byName);
    var out: std.ArrayList(u8) = .empty;
    for (syms) |s| {
        for (rules) |rule| {
            const eq = std.mem.indexOfScalar(u8, rule, '=') orelse fatal("bad rule {s}", .{rule});
            if (std.mem.indexOf(u8, s.name, rule[0..eq]) == null) continue;
            const v = nmValue(s);
            if (e.is64)
                out.print(gpa, "#define {s} 0x{x:0>16}\n", .{ rule[eq + 1 ..], v }) catch @panic("OOM")
            else
                out.print(gpa, "#define {s} 0x{x:0>8}\n", .{ rule[eq + 1 ..], v }) catch @panic("OOM");
        }
    }
    writeFile(out_path, out.items);
}

// --- vers.c ----------------------------------------------------------------

/// The value of NAME="..." in a shell script.
fn shellVar(text: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, name) or line.len < name.len + 2) continue;
        if (line[name.len] != '=' or line[name.len + 1] != '"') continue;
        const rest = line[name.len + 2 ..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse rest.len];
    }
    fatal("newvers.sh has no {s}", .{name});
}

/// sys/conf/newvers.sh -R in a tree without version control: no date, no
/// user and no host, so the same tree always makes the same vers.c.
fn vers(out_path: []const u8, srctop: []const u8, ident: []const u8, zig: []const u8) void {
    const newvers = readFile(std.fs.path.join(gpa, &.{ srctop, "sys/conf/newvers.sh" }) catch @panic("OOM"));
    const typ = shellVar(newvers, "TYPE");
    const release = std.mem.concat(gpa, u8, &.{ shellVar(newvers, "REVISION"), "-", shellVar(newvers, "BRANCH") }) catch @panic("OOM");

    const param = readFile(std.fs.path.join(gpa, &.{ srctop, "sys/sys/param.h" }) catch @panic("OOM"));
    var reldate: []const u8 = "";
    var lines = std.mem.splitScalar(u8, param, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, it.next() orelse "", "#define")) continue;
        if (!std.mem.eql(u8, it.next() orelse "", "__FreeBSD_version")) continue;
        reldate = it.next() orelse "";
        break;
    }

    // The year of "Copyright (c) 1992-YEAR The FreeBSD Project" in COPYRIGHT.
    const copyright = readFile(std.fs.path.join(gpa, &.{ srctop, "COPYRIGHT" }) catch @panic("OOM"));
    var year: []const u8 = "";
    lines = std.mem.splitScalar(u8, copyright, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Copyright ") or std.mem.indexOf(u8, line, "The FreeBSD Project") == null) continue;
        const at = std.mem.indexOf(u8, line, "1992-") orelse continue;
        const rest = line[at + 5 ..];
        year = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    }

    // `cc -v 2>&1 | grep -w version`: the compiler's version line.
    const cc = std.process.run(gpa, io, .{ .argv = &.{ zig, "clang", "-v" } }) catch |err|
        fatal("{s} clang -v: {t}", .{ zig, err });
    var compiler: []const u8 = "";
    lines = std.mem.splitScalar(u8, cc.stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " version ") != null) {
            compiler = line;
            break;
        }
    }

    const verinfo = std.mem.concat(gpa, u8, &.{ typ, " ", release, " ", ident }) catch @panic("OOM");
    const out = std.fmt.allocPrint(gpa,
        \\/*-
        \\ * Copyright (c) 1992-{s} The FreeBSD Project.
        \\ *
        \\ */
        \\
        \\/*
        \\ * The SCCS stuff is a marker that by convention identifies the kernel.  While
        \\ * the convention originated with SCCS, the current use is more generic and is
        \\ * used by different organizations to identify the kernel, the crash dump,
        \\ * etc. The what(1) utility prints these markers. Better methods exist, so this
        \\ * method is deprecated and will be removed in a future version of FreeBSD. Orgs
        \\ * that use it are encouraged to migrate before then.
        \\ */
        \\#define SCCSSTR "@(#){s}"
        \\#define VERSTR "{s}\n"
        \\#define RELSTR "{s}"
        \\
        \\const char sccs[sizeof(SCCSSTR) > 128 ? sizeof(SCCSSTR) : 128] = SCCSSTR;
        \\const char version[sizeof(VERSTR) > 256 ? sizeof(VERSTR) : 256] = VERSTR;
        \\const char compiler_version[] = "{s}";
        \\const char ostype[] = "{s}";
        \\const char osrelease[sizeof(RELSTR) > 32 ? sizeof(RELSTR) : 32] = RELSTR;
        \\const int osreldate = {s};
        \\const char kern_ident[] = "{s}";
        \\
    , .{ year, verinfo, verinfo, release, compiler, typ, reldate, ident }) catch @panic("OOM");
    writeFile(out_path, out);
}

// --- Running a generator in a directory ------------------------------------

/// Run argv in dir.  The arguments that name files here (the program, its
/// scripts and inputs) are made absolute first, so they still name them
/// from dir.
fn runIn(dir: []const u8, argv: []const [:0]const u8) void {
    Io.Dir.cwd().createDirPath(io, dir) catch |err| fatal("{s}: {t}", .{ dir, err });
    const here = std.process.currentPathAlloc(io, gpa) catch |err| fatal("getcwd: {t}", .{err});
    var args: std.ArrayList([]const u8) = .empty;
    for (argv) |a| {
        const is_file = a.len > 0 and a[0] != '-' and a[0] != '/' and
            if (Io.Dir.cwd().access(io, a, .{})) |_| true else |_| false;
        const arg = if (is_file) std.fs.path.join(gpa, &.{ here, a }) catch @panic("OOM") else a;
        args.append(gpa, arg) catch @panic("OOM");
    }
    const r = std.process.run(gpa, io, .{ .argv = args.items, .cwd = .{ .path = dir } }) catch |err|
        fatal("{s}: {t}", .{ argv[0], err });
    if (r.stderr.len > 0) std.debug.print("{s}", .{r.stderr});
    switch (r.term) {
        .exited => |code| if (code != 0) fatal("{s} exited with {d}", .{ argv[0], code }),
        else => fatal("{s} failed", .{argv[0]}),
    }
}

pub fn main(init: std.process.Init) void {
    io = init.io;
    gpa = init.arena.allocator();
    const args = init.minimal.args.toSlice(gpa) catch @panic("OOM");
    if (args.len < 2) fatal("usage: kgen command args...", .{});
    const cmd = args[1];
    const a = args[2..];
    const eql = std.mem.eql;
    if (eql(u8, cmd, "genassym") and a.len == 2) return genassym(a[0], a[1]);
    if (eql(u8, cmd, "genoffset") and a.len == 2) return genoffset(a[0], a[1]);
    if (eql(u8, cmd, "nmdefs") and a.len == 2) return nmdefs(a[0], a[1]);
    if (eql(u8, cmd, "binary") and a.len == 2) return binary(a[0], a[1]);
    if (eql(u8, cmd, "file2c") and a.len == 4) return file2c(a[0], a[1], a[2], a[3]);
    if (eql(u8, cmd, "grepv") and a.len == 3) return grepv(a[0], a[1], a[2]);
    if (eql(u8, cmd, "vdso-check") and a.len == 2) return vdsoCheck(a[0], a[1]);
    if (eql(u8, cmd, "vdso-offsets") and a.len >= 3) return vdsoOffsets(a[0], a[1], a[2..]);
    if (eql(u8, cmd, "vers") and a.len == 4) return vers(a[0], a[1], a[2], a[3]);
    if (eql(u8, cmd, "in") and a.len >= 2) return runIn(a[0], a[1..]);
    fatal("unknown command or wrong arguments: {s}", .{cmd});
}
