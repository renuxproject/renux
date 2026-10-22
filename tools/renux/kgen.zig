// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
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
//   efi-pe ELF OUT EPOCH SECTION...
//                            elfcopy -j SECTION... --output-target=efi-app-x86_64
//   check-undefined ELF OUT  nm ELF | grep ' U ' finds nothing; OUT is ELF
//   stand-vers VERSION OUT NAME MACHINE
//                            stand/common/newvers.sh -r VERSION NAME MACHINE
//   in DIR PROG ARG...       run PROG in DIR (for generators that write to .)

const std: type = @import("std");
const mem: type = std.mem;
const fmt: type = std.fmt;
const ascii: type = std.ascii;
const fs: type = std.fs;
const debug: type = std.debug;
const process: type = std.process;
const Io: type = std.Io;

const Allocator: type = mem.Allocator;

var io: Io = undefined;
var gpa: Allocator = undefined;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    debug.print("kgen: " ++ format ++ "\n", args);
    process.exit(1);
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

const SHN_UNDEF: u16 = 0;
const SHN_COMMON: u16 = 0xfff2;
const SHF_ALLOC: u64 = 0x2;
const SHT_PROGBITS: u32 = 1;
const SHT_SYMTAB: u32 = 2;
const SHT_DYNAMIC: u32 = 6;
const SHT_DYNSYM: u32 = 11;
const STT_SECTION: u4 = 3;
const STT_FILE: u4 = 4;

/// Enough of ELF (32 and 64 bits, little-endian) to list symbols and
/// sections, as nm and objcopy do.
const Elf: type = struct {
    data: []const u8,
    is64: bool,

    const Section: type = struct {
        name: []const u8,
        type: u32,
        flags: u64,
        addr: u64,
        offset: u64,
        size: u64,
        link: u32,
    };

    const Symbol: type = struct {
        name: []const u8,
        value: u64,
        size: u64,
        type: u4,
        shndx: u16,
    };

    fn open(path: []const u8) Elf {
        const data: []u8 = readFile(path);
        if (data.len < 64 or !mem.eql(u8, data[0..4], "\x7fELF") or data[5] != 1)
            fatal("{s}: not a little-endian ELF file", .{path});
        return .{ .data = data, .is64 = data[4] == 2 };
    }

    fn int(e: Elf, comptime T: type, off: u64) T {
        return mem.readInt(T, e.data[@intCast(off)..][0..@sizeOf(T)], .little);
    }

    /// A word that is 32 bits in ELF32 and 64 bits in ELF64.
    fn word(e: Elf, off: u64) u64 {
        return if (e.is64) e.int(u64, off) else e.int(u32, off);
    }

    fn sectionCount(e: Elf) u16 {
        return e.int(u16, if (e.is64) 0x3c else 0x30);
    }

    fn section(e: Elf, i: usize) Section {
        const shoff: u64 = e.word(if (e.is64) 0x28 else 0x20);
        const shentsize: u16 = e.int(u16, if (e.is64) 0x3a else 0x2e);
        const shstrndx: u16 = e.int(u16, if (e.is64) 0x3e else 0x32);
        const sh: u64 = shoff + i * shentsize;
        const strtab: u64 = e.sectionOffset(shoff + @as(u64, shstrndx) * shentsize);
        return .{
            .name = e.str(strtab, e.int(u32, sh)),
            .type = e.int(u32, sh + 4),
            .flags = e.word(sh + 8),
            .addr = e.word(if (e.is64) sh + 0x10 else sh + 0x0c),
            .offset = e.word(if (e.is64) sh + 0x18 else sh + 0x10),
            .size = e.word(if (e.is64) sh + 0x20 else sh + 0x14),
            .link = e.int(u32, if (e.is64) sh + 0x28 else sh + 0x18),
        };
    }

    /// The file offset of the section whose header is at sh.
    fn sectionOffset(e: Elf, sh: u64) u64 {
        return e.word(if (e.is64) sh + 0x18 else sh + 0x10);
    }

    fn str(e: Elf, table: u64, off: u32) []const u8 {
        const s: []const u8 = e.data[@intCast(table + off)..];
        return s[0 .. mem.indexOfScalar(u8, s, 0) orelse s.len];
    }

    fn contents(e: Elf, s: Section) []const u8 {
        return e.data[@intCast(s.offset)..][0..@intCast(s.size)];
    }

    /// The symbols of the first section of type `kind` (symtab or dynsym),
    /// without the null symbol.
    fn symbols(e: Elf, kind: u32) []Symbol {
        var list: std.ArrayList(Symbol) = .empty;
        for (0..e.sectionCount()) |i| {
            const s: Elf.Section = e.section(i);
            if (s.type != kind) continue;
            const strtab: Elf.Section = e.section(s.link);
            const entsize: u64 = if (e.is64) 24 else 16;
            var off: u64 = s.offset + entsize;
            while (off < s.offset + s.size) : (off += entsize) {
                const info: u8 = e.data[@intCast(if (e.is64) off + 4 else off + 12)];
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
    return mem.order(u8, a.name, b.name) == .lt;
}

/// nm(1) prints a common symbol's size where others have their address.
fn nmValue(s: Elf.Symbol) u64 {
    return if (s.shndx == SHN_COMMON) s.size else s.value;
}

// --- genassym and genoffset ------------------------------------------------

fn genassym(obj: []const u8, out_path: []const u8) void {
    const syms: []Elf.Symbol = nmSymbols(Elf.open(obj), SHT_SYMTAB);
    mem.sort(Elf.Symbol, syms, {}, byName);
    var out: std.ArrayList(u8) = .empty;
    // The awk program of genassym.sh: each value is spread over the low 16
    // bits of the sizes of five common symbols, name{sign,w0,w1,w2,w3}.
    var sign: []const u8 = "";
    var w: [4][]const u8 = .{ "", "", "", "" };
    for (syms) |s| {
        if (s.shndx != SHN_COMMON) continue;
        const hex: []u8 = fmt.allocPrint(gpa, "{x:0>16}", .{nmValue(s)}) catch @panic("OOM");
        const low: []u8 = hex[hex.len - 4 ..];
        if (mem.endsWith(u8, s.name, "sign")) {
            sign = if (mem.trimStart(u8, low, "0").len > 0) "-" else "";
        } else if (s.name.len >= 2 and s.name[s.name.len - 2] == 'w' and
            s.name[s.name.len - 1] >= '0' and s.name[s.name.len - 1] <= '3')
        {
            const n: u8 = s.name[s.name.len - 1] - '0';
            w[n] = low;
            if (n == 3) {
                const all: []u8 = mem.concat(gpa, u8, &.{ w[3], w[2], w[1], w[0] }) catch @panic("OOM");
                var v: []const u8 = mem.trimStart(u8, all, "0");
                if (v.len == 0) v = "0";
                const prefix: []const u8 = if (mem.eql(u8, v, "0")) "" else "0x";
                out.print(gpa, "#define\t{s}\t{s}{s}{s}\n", .{ s.name[0 .. s.name.len - 2], sign, prefix, v }) catch @panic("OOM");
            }
        }
    }
    writeFile(out_path, out.items);
}

/// Text at the end of out.
fn put(out: *std.ArrayList(u8), comptime format: []const u8, args: anytype) void {
    out.print(gpa, format, args) catch @panic("OOM");
}

fn genoffset(obj: []const u8, out_path: []const u8) void {
    const Entry: type = struct { line: []const u8, off: u64, struct_: []const u8, field: []const u8, type: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    for (nmSymbols(Elf.open(obj), SHT_SYMTAB)) |s| {
        if (mem.indexOf(u8, s.name, "__assym_offset__") == null) continue;
        // `nm -t d | sed -e 's/__/ /g'`, then read into
        // "off x1 x2 struct field type".
        const nmline: []u8 = fmt.allocPrint(gpa, "{d:0>16} C {s}", .{ nmValue(s), s.name }) catch @panic("OOM");
        const line: []u8 = mem.replaceOwned(u8, gpa, nmline, "__", " ") catch @panic("OOM");
        var it: mem.TokenIterator(u8, .any) = mem.tokenizeAny(u8, line, " \t");
        var f: [6][]const u8 = .{ "", "", "", "", "", "" };
        for (&f) |*x| x.* = it.next() orelse "";
        entries.append(gpa, .{ .line = line, .off = nmValue(s), .struct_ = f[3], .field = f[4], .type = f[5] }) catch @panic("OOM");
    }
    // sort -k 4 -k 1 -n: the struct names are not numbers, so this sorts
    // by offset, then by the whole line.
    mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.off != b.off) return a.off < b.off;
            return mem.order(u8, a.line, b.line) == .lt;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    var asserts: std.ArrayList(u8) = .empty;
    put(&out, "#ifndef _OFFSET_INC_\n#define _OFFSET_INC_\n", .{});
    put(&out, "#if !defined(GENOFFSET) && (!defined(KLD_MODULE) || defined(KLD_TIED))\n", .{});
    var last: []const u8 = "";
    var lastoff: u64 = 0;
    var lasttype: []const u8 = "";
    for (entries.items) |e| {
        if (!mem.eql(u8, last, e.struct_)) {
            if (last.len > 0) put(&out, "}};\n", .{});
            put(&out, "struct {s}_lite {{\n", .{e.struct_});
            last = e.struct_;
            put(&out, "\tu_char\tpad_{s}[{d}];\n", .{ e.field, e.off });
        } else {
            put(&out, "\tu_char\tpad_{s}[{d} - ({d} + sizeof({s}))];\n", .{ e.field, e.off, lastoff, lasttype });
        }
        put(&out, "\t{s}\t{s};\n", .{ e.type, e.field });
        lastoff = e.off;
        lasttype = e.type;
        put(&asserts, "_SA({s}, {s}, {d});\n", .{ e.struct_, e.field, e.off });
    }
    put(&out, "}};\n", .{});
    put(&out, "#define _SA(s,f,o) _Static_assert(__builtin_offsetof(struct s ## _lite, f) == o, \\\n", .{});
    put(&out, "\t\"struct \"#s\"_lite field \"#f\" not at offset \"#o)\n", .{});
    put(&out, "{s}#undef _SA\n#endif\n#endif\n", .{asserts.items});
    writeFile(out_path, out.items);
}

// --- nm, objcopy and file2c ------------------------------------------------

fn nmdefs(obj: []const u8, out_path: []const u8) void {
    const e: Elf = Elf.open(obj);
    var list: std.ArrayList(Elf.Symbol) = .empty;
    for (nmSymbols(e, SHT_SYMTAB)) |s| if (s.shndx != SHN_UNDEF) list.append(gpa, s) catch @panic("OOM");
    // nm -n: by address, then by name.
    mem.sort(Elf.Symbol, list.items, {}, struct {
        fn lt(_: void, a: Elf.Symbol, b: Elf.Symbol) bool {
            if (nmValue(a) != nmValue(b)) return nmValue(a) < nmValue(b);
            return mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (list.items) |s| {
        const v: u64 = nmValue(s);
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
    const e: Elf = Elf.open(obj);
    var found: ?Elf.Section = null;
    for (0..e.sectionCount()) |i| {
        const s: Elf.Section = e.section(i);
        if (s.type != SHT_PROGBITS or s.flags & SHF_ALLOC == 0 or s.size == 0) continue;
        if (found != null) fatal("{s}: more than one allocated section", .{obj});
        found = s;
    }
    const s: Elf.Section = found orelse fatal("{s}: no allocated section", .{obj});
    writeFile(out_path, e.contents(s));
}

/// usr.bin/file2c with -s -x.
fn file2c(in_path: []const u8, out_path: []const u8, prefix: []const u8, suffix: []const u8) void {
    const in: []u8 = readFile(in_path);
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
    var it: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, readFile(in_path), '\n');
    while (it.next()) |line| {
        if (it.peek() == null and line.len == 0) break;
        if (mem.indexOf(u8, line, pattern) != null) continue;
        out.print(gpa, "{s}\n", .{line}) catch @panic("OOM");
    }
    writeFile(out_path, out.items);
}

// --- The vDSO --------------------------------------------------------------

/// The checks of sys/tools/amd64_vdso.sh: at most 2 KB, and no runtime
/// relocations (DT_RELSZ, DT_RELASZ, DT_RELRSZ).
fn vdsoCheck(so: []const u8, out_path: []const u8) void {
    const e: Elf = Elf.open(so);
    if (e.data.len > 2048) fatal("{s} too large", .{so});
    for (0..e.sectionCount()) |i| {
        const s: Elf.Section = e.section(i);
        if (s.type != SHT_DYNAMIC) continue;
        const entsize: u64 = if (e.is64) 16 else 8;
        var off: u64 = s.offset;
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
    const e: Elf = Elf.open(so);
    const syms: []Elf.Symbol = nmSymbols(e, SHT_DYNSYM);
    mem.sort(Elf.Symbol, syms, {}, byName);
    var out: std.ArrayList(u8) = .empty;
    for (syms) |s| {
        for (rules) |rule| {
            const eq: usize = mem.indexOfScalar(u8, rule, '=') orelse fatal("bad rule {s}", .{rule});
            if (mem.indexOf(u8, s.name, rule[0..eq]) == null) continue;
            const v: u64 = nmValue(s);
            if (e.is64)
                out.print(gpa, "#define {s} 0x{x:0>16}\n", .{ rule[eq + 1 ..], v }) catch @panic("OOM")
            else
                out.print(gpa, "#define {s} 0x{x:0>8}\n", .{ rule[eq + 1 ..], v }) catch @panic("OOM");
        }
    }
    writeFile(out_path, out.items);
}

// --- ELF to PE, for EFI ----------------------------------------------------

const SHT_NOBITS: u32 = 8;
const SHF_WRITE: u64 = 0x1;
const SHF_EXECINSTR: u64 = 0x4;

/// v at the end of out, little-endian.
fn appendInt(out: *std.ArrayList(u8), comptime T: type, v: T) void {
    var buf: [@sizeOf(T)]u8 = undefined;
    mem.writeInt(T, &buf, v, .little);
    out.appendSlice(gpa, &buf) catch @panic("OOM");
}

/// Zeros at the end of out, up to the length `to`.
fn padTo(out: *std.ArrayList(u8), to: usize) void {
    out.appendNTimes(gpa, 0, to - out.items.len) catch @panic("OOM");
}

/// elfcopy -j SECTION... --output-target=efi-app-x86_64 IN OUT, as
/// contrib/elftoolchain/elfcopy/pe.c and libpe write it: each section kept
/// becomes a PE section at its address; the image is not relocated by the
/// firmware, the loader relocates itself.
fn efiPe(in_path: []const u8, out_path: []const u8, epoch: []const u8, keep: []const [:0]const u8) void {
    const e: Elf = Elf.open(in_path);
    if (!e.is64) fatal("{s}: not ELF64", .{in_path});
    const filealign: u32 = 0x200;
    const secalign: u32 = 0x1000;

    var sections: std.ArrayList(Elf.Section) = .empty;
    for (0..e.sectionCount()) |i| {
        const s: Elf.Section = e.section(i);
        for (keep) |k| if (mem.eql(u8, s.name, k)) {
            sections.append(gpa, s) catch @panic("OOM");
            break;
        };
    }

    // The optional header's sizes and the image's extent.
    var textbase: u32 = 0;
    var textsize: u32 = 0;
    var datasize: u32 = 0;
    var bsssize: u32 = 0;
    var rvamax: u64 = 0;
    var reloc: ?Elf.Section = null;
    for (sections.items) |s| {
        if (mem.eql(u8, s.name, ".text")) {
            textbase = @intCast(s.addr);
            textsize = @intCast(mem.alignForward(u64, s.size, filealign));
        } else if (s.type == SHT_NOBITS) {
            bsssize += @intCast(mem.alignForward(u64, s.size, filealign));
        } else if (s.flags & SHF_ALLOC != 0) {
            datasize += @intCast(mem.alignForward(u64, s.size, filealign));
        }
        if (mem.startsWith(u8, s.name, ".reloc")) reloc = s;
        rvamax = @max(rvamax, s.addr + s.size);
    }

    const nsec: u32 = @intCast(sections.items.len);
    const coff_at: u32 = 0x80 + 4;
    const optsize: u16 = 240;
    const headers: u32 = coff_at + 20 + optsize + nsec * 40;
    const hdrsize: u32 = mem.alignForward(u32, headers, filealign);

    var out: std.ArrayList(u8) = .empty;

    // MS-DOS header and stub (libpe's init_dos_header and msdos_stub).
    out.appendSlice(gpa, "MZ") catch @panic("OOM");
    for ([_]u16{ 144, 3, 0, 4, 0, 65535, 0, 184, 0, 0, 0, 0x40, 0 }) |v| appendInt(&out, u16, v);
    padTo(&out, 0x3c);
    appendInt(&out, u32, 0x80);
    out.appendSlice(gpa, "\x0e\x1f\xba\x0e\x00\xb4\x09\xcd\x21\xb8\x01\x4c\xcd\x21This program cannot be run in DOS mode.\r\r\n$") catch @panic("OOM");
    padTo(&out, 0x80);

    // PE signature and COFF header.
    out.appendSlice(gpa, "PE\x00\x00") catch @panic("OOM");
    appendInt(&out, u16, 0x8664); // IMAGE_FILE_MACHINE_AMD64
    appendInt(&out, u16, @intCast(nsec));
    appendInt(&out, u32, fmt.parseInt(u32, epoch, 10) catch fatal("bad epoch {s}", .{epoch}));
    appendInt(&out, u32, 0);
    appendInt(&out, u32, 0);
    appendInt(&out, u16, optsize);
    // EXECUTABLE_IMAGE | LINE_NUMS_STRIPPED | LOCAL_SYMS_STRIPPED |
    // LARGE_ADDRESS_AWARE, and RELOCS_STRIPPED without a .reloc.
    appendInt(&out, u16, 0x0002 | 0x0004 | 0x0008 | 0x0020 | @as(u16, if (reloc == null) 0x0001 else 0));

    // Optional header, PE32+.
    appendInt(&out, u16, 0x20b);
    out.appendSlice(gpa, &.{ 2, 22 }) catch @panic("OOM");
    appendInt(&out, u32, textsize);
    appendInt(&out, u32, datasize);
    appendInt(&out, u32, bsssize);
    appendInt(&out, u32, @intCast(e.word(0x18))); // e_entry
    appendInt(&out, u32, textbase);
    appendInt(&out, u64, 0); // ImageBase
    appendInt(&out, u32, secalign);
    appendInt(&out, u32, filealign);
    for (0..6) |_| appendInt(&out, u16, 0); // OS, image and subsystem versions
    appendInt(&out, u32, 0); // Win32VersionValue
    appendInt(&out, u32, mem.alignForward(u32, @intCast(rvamax), secalign));
    appendInt(&out, u32, hdrsize);
    appendInt(&out, u32, 0); // CheckSum
    appendInt(&out, u16, 10); // IMAGE_SUBSYSTEM_EFI_APPLICATION
    appendInt(&out, u16, 0);
    for (0..4) |_| appendInt(&out, u64, 0); // stack and heap
    appendInt(&out, u32, 0); // LoaderFlags
    appendInt(&out, u32, 16); // NumberOfRvaAndSizes
    for (0..16) |i| {
        if (i == 5 and reloc != null) { // IMAGE_DIRECTORY_ENTRY_BASERELOC
            appendInt(&out, u32, @intCast(reloc.?.addr));
            appendInt(&out, u32, @intCast(reloc.?.size));
        } else {
            appendInt(&out, u64, 0);
        }
    }

    // Section headers; the contents follow the headers in order.
    var rawptr: u32 = hdrsize;
    for (sections.items) |s| {
        var name: [8]u8 = @splat(0);
        @memcpy(name[0..@min(8, s.name.len)], s.name[0..@min(8, s.name.len)]);
        out.appendSlice(gpa, &name) catch @panic("OOM");
        appendInt(&out, u32, @intCast(s.size));
        appendInt(&out, u32, @intCast(s.addr));
        const nobits: bool = s.type == SHT_NOBITS;
        const rawsize: u32 = if (nobits) 0 else mem.alignForward(u32, @intCast(s.size), filealign);
        appendInt(&out, u32, rawsize);
        appendInt(&out, u32, if (rawsize == 0) 0 else rawptr);
        appendInt(&out, u32, 0);
        appendInt(&out, u32, 0);
        appendInt(&out, u16, 0);
        appendInt(&out, u16, 0);
        var ch: u32 = 0x40000000; // MEM_READ
        if (nobits) ch |= 0x80; // CNT_UNINITIALIZED_DATA
        if (s.flags & SHF_WRITE != 0) ch |= 0x80000000;
        if (s.flags & SHF_EXECINSTR != 0) ch |= 0x20000000 | 0x20;
        if (s.flags & SHF_ALLOC != 0 and ch & 0xf0 == 0) ch |= 0x40;
        if (mem.eql(u8, s.name, ".reloc")) ch |= 0x02000000;
        appendInt(&out, u32, ch);
        rawptr += rawsize;
    }
    padTo(&out, hdrsize);
    for (sections.items) |s| {
        if (s.type == SHT_NOBITS) continue;
        out.appendSlice(gpa, e.contents(s)) catch @panic("OOM");
        padTo(&out, mem.alignForward(usize, out.items.len, filealign));
    }
    writeFile(out_path, out.items);
}

/// `nm ELF | grep ' U '` must find nothing: the loader cannot resolve
/// symbols at run time.  OUT is ELF.
fn checkUndefined(elf: []const u8, out_path: []const u8) void {
    const e: Elf = Elf.open(elf);
    var bad: bool = false;
    for (nmSymbols(e, SHT_SYMTAB)) |s| if (s.shndx == SHN_UNDEF) {
        debug.print("{s}: undefined symbol {s}\n", .{ elf, s.name });
        bad = true;
    };
    if (bad) process.exit(1);
    writeFile(out_path, e.data);
}

// --- The loader's vers.c ---------------------------------------------------

/// stand/common/newvers.sh -r VERSION_FILE NAME MACHINE: the loader's
/// version, without build metadata.
fn standVers(out_path: []const u8, version_file: []const u8, name: []const u8, machine: []const u8) void {
    // The first "N.N:" line of the version file.
    var rev: []const u8 = "";
    var lines: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, readFile(version_file), '\n');
    while (lines.next()) |line| {
        const colon: usize = mem.indexOfScalar(u8, line, ':') orelse continue;
        const r: []const u8 = line[0..colon];
        const dot: usize = mem.indexOfScalar(u8, r, '.') orelse continue;
        if (dot != 1 or !ascii.isDigit(r[0]) or r.len < 3) continue;
        for (r[2..]) |c| if (!ascii.isDigit(c)) break;
        rev = r;
        break;
    }
    if (rev.len == 0) fatal("{s}: no revision", .{version_file});
    const dot: usize = mem.indexOfScalar(u8, rev, '.').?;
    writeFile(out_path, fmt.allocPrint(gpa,
        \\char bootprog_info[] = "FreeBSD/{s} {s}, Revision {s}\n";
        \\unsigned bootprog_rev = {s} * 1000 + {s};
        \\
    , .{ machine, name, rev, rev[0..dot], rev[dot + 1 ..] }) catch @panic("OOM"));
}

// --- vers.c ----------------------------------------------------------------

/// The value of NAME="..." in a shell script.
fn shellVar(text: []const u8, name: []const u8) []const u8 {
    var it: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!mem.startsWith(u8, line, name) or line.len < name.len + 2) continue;
        if (line[name.len] != '=' or line[name.len + 1] != '"') continue;
        const rest: []const u8 = line[name.len + 2 ..];
        return rest[0 .. mem.indexOfScalar(u8, rest, '"') orelse rest.len];
    }
    fatal("newvers.sh has no {s}", .{name});
}

/// sys/conf/newvers.sh -R in a tree without version control: no date, no
/// user and no host, so the same tree always makes the same vers.c.
fn vers(out_path: []const u8, srctop: []const u8, ident: []const u8, zig: []const u8) void {
    const newvers: []u8 = readFile(fs.path.join(gpa, &.{ srctop, "sys/conf/newvers.sh" }) catch @panic("OOM"));
    const typ: []const u8 = shellVar(newvers, "TYPE");
    const release: []u8 = mem.concat(gpa, u8, &.{ shellVar(newvers, "REVISION"), "-", shellVar(newvers, "BRANCH") }) catch @panic("OOM");

    const param: []u8 = readFile(fs.path.join(gpa, &.{ srctop, "sys/sys/param.h" }) catch @panic("OOM"));
    var reldate: []const u8 = "";
    var lines: mem.SplitIterator(u8, .scalar) = mem.splitScalar(u8, param, '\n');
    while (lines.next()) |line| {
        var it: mem.TokenIterator(u8, .any) = mem.tokenizeAny(u8, line, " \t");
        if (!mem.eql(u8, it.next() orelse "", "#define")) continue;
        if (!mem.eql(u8, it.next() orelse "", "__FreeBSD_version")) continue;
        reldate = it.next() orelse "";
        break;
    }

    // The year of "Copyright (c) 1992-YEAR The FreeBSD Project" in COPYRIGHT.
    const copyright: []u8 = readFile(fs.path.join(gpa, &.{ srctop, "COPYRIGHT" }) catch @panic("OOM"));
    var year: []const u8 = "";
    lines = mem.splitScalar(u8, copyright, '\n');
    while (lines.next()) |line| {
        if (!mem.startsWith(u8, line, "Copyright ") or mem.indexOf(u8, line, "The FreeBSD Project") == null) continue;
        const at: usize = mem.indexOf(u8, line, "1992-") orelse continue;
        const rest: []const u8 = line[at + 5 ..];
        year = rest[0 .. mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    }

    // `cc -v 2>&1 | grep -w version`: the compiler's version line.
    const cc: process.RunResult = process.run(gpa, io, .{ .argv = &.{ zig, "clang", "-v" } }) catch |err|
        fatal("{s} clang -v: {t}", .{ zig, err });
    var compiler: []const u8 = "";
    lines = mem.splitScalar(u8, cc.stderr, '\n');
    while (lines.next()) |line| {
        if (mem.indexOf(u8, line, " version ") != null) {
            compiler = line;
            break;
        }
    }

    const verinfo: []u8 = mem.concat(gpa, u8, &.{ typ, " ", release, " ", ident }) catch @panic("OOM");
    const out: []u8 = fmt.allocPrint(gpa,
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
    const here: [:0]u8 = process.currentPathAlloc(io, gpa) catch |err| fatal("getcwd: {t}", .{err});
    var args: std.ArrayList([]const u8) = .empty;
    for (argv) |a| {
        const is_file: bool = a.len > 0 and a[0] != '-' and a[0] != '/' and
            if (Io.Dir.cwd().access(io, a, .{})) |_| true else |_| false;
        const arg: []const u8 = if (is_file) fs.path.join(gpa, &.{ here, a }) catch @panic("OOM") else a;
        args.append(gpa, arg) catch @panic("OOM");
    }
    const r: process.RunResult = process.run(gpa, io, .{ .argv = args.items, .cwd = .{ .path = dir } }) catch |err|
        fatal("{s}: {t}", .{ argv[0], err });
    if (r.stderr.len > 0) debug.print("{s}", .{r.stderr});
    switch (r.term) {
        .exited => |code| if (code != 0) fatal("{s} exited with {d}", .{ argv[0], code }),
        else => fatal("{s} failed", .{argv[0]}),
    }
}

pub fn main(init: process.Init) void {
    io = init.io;
    gpa = init.arena.allocator();
    const args: []const [:0]const u8 = init.minimal.args.toSlice(gpa) catch @panic("OOM");
    if (args.len < 2) fatal("usage: kgen command args...", .{});
    const cmd: [:0]const u8 = args[1];
    const a: []const [:0]const u8 = args[2..];
    const eql: fn (comptime type, anytype, anytype) bool = mem.eql;
    if (eql(u8, cmd, "genassym") and a.len == 2) return genassym(a[0], a[1]);
    if (eql(u8, cmd, "genoffset") and a.len == 2) return genoffset(a[0], a[1]);
    if (eql(u8, cmd, "nmdefs") and a.len == 2) return nmdefs(a[0], a[1]);
    if (eql(u8, cmd, "binary") and a.len == 2) return binary(a[0], a[1]);
    if (eql(u8, cmd, "file2c") and a.len == 4) return file2c(a[0], a[1], a[2], a[3]);
    if (eql(u8, cmd, "grepv") and a.len == 3) return grepv(a[0], a[1], a[2]);
    if (eql(u8, cmd, "vdso-check") and a.len == 2) return vdsoCheck(a[0], a[1]);
    if (eql(u8, cmd, "vdso-offsets") and a.len >= 3) return vdsoOffsets(a[0], a[1], a[2..]);
    if (eql(u8, cmd, "vers") and a.len == 4) return vers(a[0], a[1], a[2], a[3]);
    if (eql(u8, cmd, "efi-pe") and a.len >= 4) return efiPe(a[0], a[1], a[2], a[3..]);
    if (eql(u8, cmd, "check-undefined") and a.len == 2) return checkUndefined(a[0], a[1]);
    if (eql(u8, cmd, "stand-vers") and a.len == 4) return standVers(a[1], a[0], a[2], a[3]);
    if (eql(u8, cmd, "in") and a.len >= 2) return runIn(a[0], a[1..]);
    fatal("unknown command or wrong arguments: {s}", .{cmd});
}
