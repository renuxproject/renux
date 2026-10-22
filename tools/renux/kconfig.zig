// SPDX-License-Identifier: MPL-2.0
//
// Copyright (c) 2026 Renan Lucas Vieira Hilário
// Copyright (c) 2026 The Renux Project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// kconfig.zig - config(8) in Zig.
//
// Reads a kernel configuration (sys/<machine>/conf/<KERNCONF>, after the
// DEFAULTS next to it), the option tables (sys/conf/options*) and the file
// lists (sys/conf/files*), and works out what config(8) works out: the
// option headers (opt_*.h) and the list of files to build, with their
// rules.  The build turns that into steps; this file only reads.
//
// The rules follow usr.sbin/config: config.y and lang.l for the
// configuration, mkoptions.cc for the options, mkmakefile.cc for the
// files.  Where config(8) has a quirk, this file keeps it, so that both
// select the same files.
//
// Files are read through a callback, with paths relative to the top of the
// source tree, so the build can record them as configure inputs.

const std: type = @import("std");
const mem: type = std.mem;
const fmt: type = std.fmt;
const ascii: type = std.ascii;
const meta: type = std.meta;

const Allocator: type = mem.Allocator;

/// Reads a file of the source tree, or returns null if there is none.
pub const ReadFn: type = *const fn (ctx: *anyopaque, path: []const u8) ?[]const u8;

pub const Reader: type = struct {
    ctx: *anyopaque,
    readFn: ReadFn,

    fn read(r: Reader, path: []const u8) ?[]const u8 {
        return r.readFn(r.ctx, path);
    }
};

pub const Option: type = struct {
    name: []const u8,
    /// null for a plain `options NAME`.
    value: ?[]const u8,
};

pub const MakeOption: type = struct {
    name: []const u8,
    /// The values: one, or more after `+=`.
    values: std.ArrayList([]const u8),
};

/// A file of the build, as one entry of sys/conf/files*.
pub const File: type = struct {
    /// The path, relative to sys/ unless `local`.
    path: []const u8,
    /// "$S/" (the kernel source directory) or "" for `local` files.
    srcprefix: []const u8,
    objprefix: []const u8 = "",
    compile_with: ?[]const u8 = null,
    dependency: ?[]const u8 = null,
    clean: ?[]const u8 = null,
    warning: ?[]const u8 = null,
    no_obj: bool = false,
    no_implicit_rule: bool = false,
    no_ctfconvert: bool = false,
    before_depend: bool = false,
    nowerror: bool = false,
    no_depend: bool = false,

    /// The object file's name, as config(8) writes it in OBJS.
    pub fn object(f: File, gpa: Allocator) ![]const u8 {
        const t: []const u8 = tail(f.path);
        return fmt.allocPrint(gpa, "{s}{s}o", .{ f.objprefix, t[0 .. t.len - 1] });
    }

    /// The suffix: "c", "S", "m", "o", "h"...
    pub fn suffix(f: File) []const u8 {
        const dot: usize = mem.lastIndexOfScalar(u8, f.path, '.') orelse return "";
        return f.path[dot + 1 ..];
    }
};

/// An option header, opt_*.h, with its #define lines.
pub const Header: type = struct {
    name: []const u8,
    defines: std.ArrayList(Option),
};

pub const Config: type = struct {
    machine: []const u8 = "",
    machine_arch: []const u8 = "",
    ident: []const u8 = "",
    maxusers: i64 = 0,
    cpus: std.ArrayList([]const u8) = .empty,
    /// In the order config(8) keeps them.
    options: std.ArrayList(Option) = .empty,
    makeoptions: std.ArrayList(MakeOption) = .empty,
    devices: std.ArrayList([]const u8) = .empty,
    envs: std.ArrayList([]const u8) = .empty,
    hints: std.ArrayList([]const u8) = .empty,
    extra_files: std.ArrayList([]const u8) = .empty,
    extra_options: std.ArrayList([]const u8) = .empty,

    /// Results.
    files: std.ArrayList(File) = .empty,
    headers: std.ArrayList(Header) = .empty,
    /// config.c, env.c and hints.c, as config(8) writes them.
    config_c: []const u8 = "",
    env_c: []const u8 = "",
    hints_c: []const u8 = "",
};

/// usr.sbin/config/kernconf.tmpl, the template of config.c.
const kernconf_head: []const u8 =
    \\/*
    \\ * This file acts as a template for config.c that will be generated in the
    \\ * kernel build directory after config(8) has been successfully run.
    \\ */
    \\#include "opt_config.h"
    \\#ifdef INCLUDE_CONFIG_FILE
    \\
    \\/*
    \\ * For !INCLUDE_CONFIG_FILE case, you should look at kern_mib.c. This is
    \\ * where kernconfstring is defined then.
    \\ */
    \\const char kernconfstring[] __attribute__ ((section("kern_conf"))) =
    \\"
;
const kernconf_tail: []const u8 =
    \\";
    \\
    \\#endif /* INCLUDE_CONFIG_FILE */
    \\
;

/// configfile_dynamic() of config(8): the configuration, rebuilt from what
/// was read, as a C string.
fn configC(gpa: Allocator, cfg: *const Config) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const lend: []const u8 = "\\n\\\n";
    try out.appendSlice(gpa, kernconf_head);
    try out.print(gpa, "options\tCONFIG_AUTOGENERATED{s}", .{lend});
    try out.print(gpa, "ident\t{s}{s}", .{ cfg.ident, lend });
    try out.print(gpa, "machine\t{s}{s}", .{ cfg.machine, lend });
    for (cfg.cpus.items) |c| try out.print(gpa, "cpu\t{s}{s}", .{ c, lend });
    for (cfg.makeoptions.items) |m|
        try out.print(gpa, "makeoptions\t{s}={s}{s}", .{ m.name, m.values.items[0], lend });
    for (cfg.options.items) |o| {
        if (mem.startsWith(u8, o.name, "DEV_")) continue;
        try out.print(gpa, "options\t{s}", .{o.name});
        if (o.value) |v| {
            try out.append(gpa, '=');
            for (v) |ch| {
                if (ch == '"') try out.append(gpa, '\\');
                try out.append(gpa, ch);
            }
        }
        try out.appendSlice(gpa, lend);
    }
    for (cfg.devices.items) |d| try out.print(gpa, "device\t{s}{s}", .{ d, lend });
    try out.appendSlice(gpa, kernconf_tail);
    return out.items;
}

/// makeenv() and makehints() of config(8), for configurations without
/// env or hints, the only ones supported yet.
fn staticStrings(gpa: Allocator, name: []const u8) ![]const u8 {
    return fmt.allocPrint(gpa,
        \\#include <sys/types.h>
        \\#include <sys/systm.h>
        \\
        \\char {s}[] = {{
        \\"\0"
        \\}};
        \\
    , .{name});
}

pub const Error: type = error{ConfigError} || Allocator.Error;

// --- Paths -----------------------------------------------------------------

fn tail(path: []const u8) []const u8 {
    const slash: usize = mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// dir/rel, with "." and ".." resolved.  Both are relative to the top of
/// the source tree.
fn join(gpa: Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it: mem.TokenIterator(u8, .scalar) = mem.tokenizeScalar(u8, dir, '/');
    while (it.next()) |p| try parts.append(gpa, p);
    it = mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |p| {
        if (mem.eql(u8, p, ".")) continue;
        if (mem.eql(u8, p, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(gpa, p);
    }
    return mem.join(gpa, "/", parts.items);
}

// --- The word reader of mkmakefile.cc and mkoptions.cc ---------------------

/// get_word() and get_quoted_word() of usr.sbin/config/main.cc.
const Words: type = struct {
    buf: []const u8,
    pos: usize = 0,

    const Word: type = union(enum) { word: []const u8, eol, eof };

    fn getc(w: *Words) ?u8 {
        if (w.pos >= w.buf.len) return null;
        defer w.pos += 1;
        return w.buf[w.pos];
    }

    fn ungetc(w: *Words) void {
        w.pos -= 1;
    }

    /// Skips blanks and escaped newlines; returns the first other
    /// character, or eol/eof.
    fn start(w: *Words) union(enum) { ch: u8, eol, eof } {
        var escaped_nl: bool = false;
        while (true) {
            var ch: u8 = undefined;
            while (true) {
                ch = w.getc() orelse return .eof;
                if (ch != ' ' and ch != '\t') break;
            }
            if (ch == '\\') {
                escaped_nl = true;
                continue;
            }
            if (ch == '\n') {
                if (escaped_nl) {
                    escaped_nl = false;
                    continue;
                }
                return .eol;
            }
            return .{ .ch = ch };
        }
    }

    fn get(w: *Words) Word {
        const first: u8 = switch (w.start()) {
            .ch => |c| c,
            .eol => return .eol,
            .eof => return .eof,
        };
        const begin: usize = w.pos - 1;
        // The negation operator is a word by itself.
        if (first == '!') return .{ .word = w.buf[begin..w.pos] };
        while (w.getc()) |ch| {
            if (ascii.isWhitespace(ch)) {
                w.ungetc();
                return .{ .word = w.buf[begin..w.pos] };
            }
        }
        // As in config(8), a word that ends the file is lost.
        return .eof;
    }

    fn getQuoted(w: *Words, gpa: Allocator) Error!Word {
        const first: u8 = switch (w.start()) {
            .ch => |c| c,
            .eol => return .eol,
            .eof => return .eof,
        };
        if (first != '"' and first != '\'') {
            w.ungetc();
            return w.get();
        }
        var out: std.ArrayList(u8) = .empty;
        var escaped_nl: bool = false;
        while (w.getc()) |ch| {
            if (ch == first and !escaped_nl) return .{ .word = out.items };
            if (ch == '\n' and !escaped_nl) return error.ConfigError;
            if (ch == '\\' and !escaped_nl) {
                escaped_nl = true;
                continue;
            }
            if (ch != first and escaped_nl) try out.append(gpa, '\\');
            try out.append(gpa, ch);
            escaped_nl = false;
        }
        return .eof;
    }

    fn skipLine(w: *Words) void {
        while (true) switch (w.get()) {
            .word => {},
            .eol, .eof => return,
        };
    }
};

// --- The configuration file: lang.l and config.y ---------------------------

const Token: type = union(enum) {
    id: []const u8,
    path: []const u8,
    number: i64,
    semicolon,
    comma,
    equals,
    plusequals,
    envline: []const u8,
    other: u8,
    eof,
};

const Keyword: type = enum {
    cpu,
    nocpu,
    device,
    nodevice,
    env,
    envvar,
    hints,
    ident,
    machine,
    makeoptions,
    nomakeoptions,
    maxusers,
    options,
    nooptions,
    include,
    includeoptions,
    files,
};

const keywords: std.StaticStringMap(Keyword) = .initComptime(.{
    .{ "cpu", .cpu },                     .{ "nocpu", .nocpu },
    .{ "device", .device },               .{ "devices", .device },
    .{ "nodevice", .nodevice },           .{ "nodevices", .nodevice },
    .{ "env", .env },                     .{ "envvar", .envvar },
    .{ "hints", .hints },                 .{ "ident", .ident },
    .{ "machine", .machine },             .{ "makeoption", .makeoptions },
    .{ "makeoptions", .makeoptions },     .{ "nomakeoption", .nomakeoptions },
    .{ "nomakeoptions", .nomakeoptions }, .{ "maxusers", .maxusers },
    .{ "option", .options },              .{ "options", .options },
    .{ "nooption", .nooptions },          .{ "nooptions", .nooptions },
    .{ "include", .include },             .{ "includeoptions", .includeoptions },
    .{ "files", .files },
});

const Lexer: type = struct {
    buf: []const u8,
    pos: usize = 0,
    line: usize = 1,
    /// After `=` or `+=`: the next word runs to a blank or a comment.
    toeol: bool = false,
    /// After `envvar`: the rest of the line.
    envc: bool = false,

    fn peek(l: *Lexer, off: usize) ?u8 {
        return if (l.pos + off < l.buf.len) l.buf[l.pos + off] else null;
    }

    fn isIdStart(c: u8) bool {
        return ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdChar(c: u8) bool {
        return ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    fn isPathChar(c: u8) bool {
        return ascii.isAlphanumeric(c) or mem.indexOfScalar(u8, "-/.%^_", c) != null;
    }

    fn next(l: *Lexer) Token {
        if (l.envc) {
            l.envc = false;
            const b: usize = l.pos;
            while (l.peek(0)) |c| : (l.pos += 1) if (c == '#' or c == '\n') break;
            return .{ .envline = l.buf[b..l.pos] };
        }
        while (true) {
            const c: u8 = l.peek(0) orelse return .eof;
            switch (c) {
                ' ', '\t', 0x0c => l.pos += 1,
                '#' => while (l.peek(0)) |d| {
                    if (d == '\n') break;
                    l.pos += 1;
                },
                '\n' => {
                    l.pos += 1;
                    l.line += 1;
                    // A line that starts with a blank continues the last.
                    const n: ?u8 = l.peek(0);
                    if (n != null and (n.? == ' ' or n.? == '\t')) continue;
                    l.toeol = false;
                    return .semicolon;
                },
                else => break,
            }
        }
        const c: u8 = l.peek(0).?;
        const b: usize = l.pos;
        if (l.toeol) {
            l.toeol = false;
            if (c != '"') {
                while (l.peek(0)) |d| : (l.pos += 1)
                    if (d == '#' or d == ' ' or d == '\t' or d == '\n') break;
                return .{ .id = l.buf[b..l.pos] };
            }
        }
        if (c == '"') {
            const end: usize = mem.indexOfScalarPos(u8, l.buf, b + 1, '"') orelse
                return .{ .other = c };
            if (end > b + 1) {
                l.pos = end + 1;
                return .{ .id = l.buf[b + 1 .. end] };
            }
        }
        if (c == '\\' and l.peek(1) == '"') {
            // \"text\" keeps its quotes.
            if (mem.indexOfPos(u8, l.buf, b + 2, "\\\"")) |end| {
                l.pos = end + 2;
                return .{ .id = l.buf[b + 1 .. end + 2] };
            }
        }
        if (isIdStart(c)) {
            while (l.peek(0)) |d| : (l.pos += 1) if (!isIdChar(d)) break;
            const word: []const u8 = l.buf[b..l.pos];
            if (keywords.get(word)) |kw| {
                if (kw == .envvar) l.envc = true;
            }
            return .{ .id = word };
        }
        if (c == '?') {
            l.pos += 1;
            return .{ .number = -1 };
        }
        if (ascii.isDigit(c) or (c == '-' and l.peek(1) != null and ascii.isDigit(l.peek(1).?))) {
            while (l.peek(0)) |d| : (l.pos += 1)
                if (!ascii.isAlphanumeric(d) and d != '-') break;
            const text: []const u8 = l.buf[b..l.pos];
            const n: fmt.ParseIntError!i64 = if (mem.startsWith(u8, text, "0x"))
                fmt.parseInt(i64, text[2..], 16)
            else if (text.len > 1 and text[0] == '0')
                fmt.parseInt(i64, text[1..], 8)
            else
                fmt.parseInt(i64, text, 10);
            return .{ .number = n catch 0 };
        }
        if (c == '.' or c == '/') {
            l.pos += 1;
            while (l.peek(0)) |d| : (l.pos += 1) if (!isPathChar(d)) break;
            if (l.pos > b + 1) return .{ .path = l.buf[b..l.pos] };
        }
        l.pos = b + 1;
        switch (c) {
            ';' => return .semicolon,
            ',' => return .comma,
            '=' => {
                l.toeol = true;
                return .equals;
            },
            '+' => if (l.peek(0) == '=') {
                l.pos += 1;
                l.toeol = true;
                return .plusequals;
            },
            else => {},
        }
        return .{ .other = c };
    }
};

/// An included configuration file: where it is, and what it says.
const Include: type = struct {
    path: []const u8,
    text: []const u8,
};

const Parser: type = struct {
    gpa: Allocator,
    reader: Reader,
    cfg: *Config,
    /// The directory config(8) runs in: sys/<machine>/conf.
    confdir: []const u8,
    /// `options CONFIG_AUTOGENERATED` turns off the includes.
    incignore: bool = false,
    diag: *std.ArrayList(u8),

    fn fail(p: *Parser, file: []const u8, line: usize, comptime format: []const u8, args: anytype) Error {
        p.diag.print(p.gpa, "{s}:{d}: " ++ format ++ "\n", .{ file, line } ++ args) catch {};
        return error.ConfigError;
    }

    fn findOption(p: *Parser, name: []const u8) ?usize {
        for (p.cfg.options.items, 0..) |o, i|
            if (mem.eql(u8, o.name, name)) return i;
        return null;
    }

    /// newopt(&opt, ...): the first definition wins, except that options
    /// may be repeated (dupe) with another value.  As in config(8), a new
    /// option goes first in the list and a repeated one last; config.c
    /// lists them in that order.
    fn newOption(p: *Parser, name: []const u8, value: ?[]const u8, dupe: bool) !void {
        if (mem.eql(u8, name, "CONFIG_AUTOGENERATED")) {
            p.incignore = true;
            return;
        }
        const opt: Option = .{ .name = name, .value = value };
        if (p.findOption(name) == null)
            try p.cfg.options.insert(p.gpa, 0, opt)
        else if (dupe)
            try p.cfg.options.append(p.gpa, opt);
    }

    fn removeOption(p: *Parser, name: []const u8) void {
        while (p.findOption(name)) |i| _ = p.cfg.options.orderedRemove(i);
    }

    fn devopt(p: *Parser, dev: []const u8) ![]const u8 {
        const up: []u8 = try ascii.allocUpperString(p.gpa, dev);
        return fmt.allocPrint(p.gpa, "DEV_{s}", .{up});
    }

    fn newMakeOption(p: *Parser, name: []const u8, value: []const u8, append: bool) !void {
        for (p.cfg.makeoptions.items) |*m| {
            if (!mem.eql(u8, m.name, name)) continue;
            if (append) try m.values.append(p.gpa, value);
            return;
        }
        var values: std.ArrayList([]const u8) = .empty;
        try values.append(p.gpa, value);
        try p.cfg.makeoptions.insert(p.gpa, 0, .{ .name = name, .values = values });
    }

    /// The include rules of lang.l: the name as given (relative to the
    /// configuration directory), then sys/conf/.
    fn resolveInclude(p: *Parser, name: []const u8) !?Include {
        const direct: []const u8 = try join(p.gpa, p.confdir, name);
        if (p.reader.read(direct)) |text| return .{ .path = direct, .text = text };
        if (name[0] != '.' and name[0] != '/') {
            const conf: []const u8 = try join(p.gpa, p.confdir, try fmt.allocPrint(p.gpa, "../../conf/{s}", .{name}));
            if (p.reader.read(conf)) |text| return .{ .path = conf, .text = text };
        }
        return null;
    }

    fn parseFile(p: *Parser, path: []const u8, text: []const u8) Error!void {
        var lex: Lexer = .{ .buf = text };
        while (true) {
            const tok: Token = lex.next();
            switch (tok) {
                .eof => return,
                .semicolon => continue,
                .id => |word| {
                    const kw: Keyword = keywords.get(word) orelse
                        return p.fail(path, lex.line, "syntax error at {s}", .{word});
                    try p.statement(path, &lex, kw);
                },
                else => return p.fail(path, lex.line, "syntax error", .{}),
            }
        }
    }

    fn expectWord(p: *Parser, path: []const u8, lex: *Lexer) Error![]const u8 {
        return switch (lex.next()) {
            .id => |w| w,
            .path => |w| w,
            else => p.fail(path, lex.line, "a name is missing", .{}),
        };
    }

    fn endOfStatement(p: *Parser, path: []const u8, lex: *Lexer) Error!void {
        switch (lex.next()) {
            .semicolon, .eof => {},
            else => return p.fail(path, lex.line, "extra words", .{}),
        }
    }

    fn statement(p: *Parser, path: []const u8, lex: *Lexer, kw: Keyword) Error!void {
        const cfg: *Config = p.cfg;
        switch (kw) {
            .include, .includeoptions, .files => {
                const name: []const u8 = try p.expectWord(path, lex);
                try p.endOfStatement(path, lex);
                switch (kw) {
                    .include => if (!p.incignore) {
                        const inc: Include = try p.resolveInclude(name) orelse
                            return p.fail(path, lex.line, "cannot open included file {s}", .{name});
                        try p.parseFile(inc.path, inc.text);
                    },
                    .includeoptions => try cfg.extra_options.append(p.gpa, name),
                    else => try cfg.extra_files.append(p.gpa, name),
                }
            },
            .machine => {
                const name: []const u8 = try p.expectWord(path, lex);
                var arch: []const u8 = name;
                switch (lex.next()) {
                    .id => |a| {
                        arch = a;
                        try p.endOfStatement(path, lex);
                    },
                    .semicolon, .eof => {},
                    else => return p.fail(path, lex.line, "syntax error", .{}),
                }
                if (cfg.machine.len > 0 and !mem.eql(u8, cfg.machine, name))
                    return p.fail(path, lex.line, "only one machine directive is allowed", .{});
                cfg.machine = name;
                cfg.machine_arch = arch;
            },
            .cpu => {
                try cfg.cpus.insert(p.gpa, 0, try p.expectWord(path, lex));
                try p.endOfStatement(path, lex);
            },
            .nocpu => {
                const name: []const u8 = try p.expectWord(path, lex);
                var i: usize = 0;
                while (i < cfg.cpus.items.len) {
                    if (mem.eql(u8, cfg.cpus.items[i], name))
                        _ = cfg.cpus.orderedRemove(i)
                    else
                        i += 1;
                }
                try p.endOfStatement(path, lex);
            },
            .ident => {
                cfg.ident = try p.expectWord(path, lex);
                try p.endOfStatement(path, lex);
            },
            .maxusers => {
                switch (lex.next()) {
                    .number => |n| cfg.maxusers = n,
                    else => return p.fail(path, lex.line, "maxusers needs a number", .{}),
                }
                try p.endOfStatement(path, lex);
            },
            .env, .hints => {
                const name: []const u8 = try p.expectWord(path, lex);
                try (if (kw == .env) &cfg.envs else &cfg.hints).append(p.gpa, name);
                try p.endOfStatement(path, lex);
            },
            .envvar => {
                switch (lex.next()) {
                    .envline => |line| try cfg.envs.append(p.gpa, line),
                    else => return p.fail(path, lex.line, "envvar needs a value", .{}),
                }
                try p.endOfStatement(path, lex);
            },
            .nomakeoptions => {
                const name: []const u8 = try p.expectWord(path, lex);
                var i: usize = 0;
                while (i < cfg.makeoptions.items.len) {
                    if (mem.eql(u8, cfg.makeoptions.items[i].name, name))
                        _ = cfg.makeoptions.orderedRemove(i)
                    else
                        i += 1;
                }
                try p.endOfStatement(path, lex);
            },
            .options, .nooptions, .makeoptions, .device, .nodevice => {
                while (true) {
                    const name: []const u8 = try p.expectWord(path, lex);
                    var after: Token = lex.next();
                    switch (kw) {
                        .options => {
                            var value: ?[]const u8 = null;
                            if (after == .equals) {
                                value = switch (lex.next()) {
                                    .id => |v| v,
                                    .number => |n| try fmt.allocPrint(p.gpa, "{d}", .{n}),
                                    else => return p.fail(path, lex.line, "{s}= needs a value", .{name}),
                                };
                                after = lex.next();
                            }
                            try p.newOption(name, value, true);
                        },
                        .makeoptions => {
                            var value: []const u8 = "";
                            var append: bool = false;
                            if (after == .equals or after == .plusequals) {
                                append = after == .plusequals;
                                switch (lex.next()) {
                                    .id => |v| {
                                        value = v;
                                        after = lex.next();
                                    },
                                    .number => |n| {
                                        value = try fmt.allocPrint(p.gpa, "{d}", .{n});
                                        after = lex.next();
                                    },
                                    else => |t| after = t,
                                }
                            }
                            try p.newMakeOption(name, value, append);
                        },
                        .nooptions => p.removeOption(name),
                        .device => {
                            try p.newOption(try p.devopt(name), "1", false);
                            for (cfg.devices.items) |d| {
                                if (mem.eql(u8, d, name)) break;
                            } else try cfg.devices.append(p.gpa, name);
                        },
                        .nodevice => {
                            p.removeOption(try p.devopt(name));
                            for (cfg.devices.items, 0..) |d, i| {
                                if (mem.eql(u8, d, name)) {
                                    _ = cfg.devices.orderedRemove(i);
                                    break;
                                }
                            }
                        },
                        else => unreachable,
                    }
                    switch (after) {
                        .comma => continue,
                        .semicolon, .eof => break,
                        else => return p.fail(path, lex.line, "syntax error after {s}", .{name}),
                    }
                }
            },
        }
    }
};

// --- Options: mkoptions.cc -------------------------------------------------

/// The option table: option name -> header, in the order config(8)
/// walks it (each options file in turn, last line first).
const OptionTable: type = struct {
    names: std.ArrayList([]const u8) = .empty,
    headers: std.ArrayList([]const u8) = .empty,

    fn find(t: OptionTable, name: []const u8) ?usize {
        for (t.names.items, 0..) |n, i| if (mem.eql(u8, n, name)) return i;
        return null;
    }
};

fn readOptionFile(gpa: Allocator, reader: Reader, path: []const u8, table: *OptionTable, diag: *std.ArrayList(u8)) Error!bool {
    const text: []const u8 = reader.read(path) orelse return false;
    var words: Words = .{ .buf = text };
    while (true) {
        const name: []const u8 = switch (words.get()) {
            .eof => break,
            .eol => continue,
            .word => |w| w,
        };
        if (name[0] == '#') {
            words.skipLine();
            continue;
        }
        // A name alone goes to opt_<name>.h.
        const header: []const u8 = switch (words.get()) {
            .eof => break,
            .eol => try fmt.allocPrint(gpa, "opt_{s}.h", .{try ascii.allocLowerString(gpa, name)}),
            .word => |w| w,
        };
        if (table.find(name) != null) {
            diag.print(gpa, "{s}: Duplicate option {s}.\n", .{ path, name }) catch {};
            return error.ConfigError;
        }
        try table.names.append(gpa, name);
        try table.headers.append(gpa, header);
    }
    return true;
}

fn makeOptions(gpa: Allocator, reader: Reader, cfg: *Config, confdir: []const u8, diag: *std.ArrayList(u8)) Error!void {
    var table: OptionTable = .{};
    _ = try readOptionFile(gpa, reader, "sys/conf/options", &table, diag);
    const mopts: []u8 = try fmt.allocPrint(gpa, "sys/conf/options.{s}", .{cfg.machine});
    if (!try readOptionFile(gpa, reader, mopts, &table, diag)) {
        const local: []const u8 = try join(gpa, confdir, try fmt.allocPrint(gpa, "options.{s}", .{cfg.machine}));
        _ = try readOptionFile(gpa, reader, local, &table, diag);
    }
    for (cfg.extra_options.items) |f|
        _ = try readOptionFile(gpa, reader, try join(gpa, confdir, f), &table, diag);

    // The cpu types, MAXUSERS and the machine architecture are options too.
    for (cfg.cpus.items) |c| try cfg.options.append(gpa, .{ .name = c, .value = null });
    try cfg.options.append(gpa, .{
        .name = "MAXUSERS",
        .value = try fmt.allocPrint(gpa, "{d}", .{cfg.maxusers}),
    });
    for (table.names.items) |n| {
        if (ascii.eqlIgnoreCase(n, cfg.machine_arch)) {
            try cfg.options.append(gpa, .{ .name = n, .value = null });
            break;
        }
    }

    // Every option must have a header, but the DEV_ ones of devices.
    for (cfg.options.items) |o| {
        if (table.find(o.name) == null and !mem.startsWith(u8, o.name, "DEV_")) {
            diag.print(gpa, "config: unknown option \"{s}\"\n", .{o.name}) catch {};
            return error.ConfigError;
        }
    }

    // One header per table entry's file, each with the options set.
    for (table.names.items, table.headers.items) |name, hname| {
        var value: ?[]const u8 = null;
        for (cfg.options.items) |o| {
            if (mem.eql(u8, o.name, name)) value = o.value orelse "1";
        }
        const h: *Header = for (cfg.headers.items) |*h| {
            if (mem.eql(u8, h.name, hname)) break h;
        } else blk: {
            try cfg.headers.append(gpa, .{ .name = hname, .defines = .empty });
            break :blk &cfg.headers.items[cfg.headers.items.len - 1];
        };
        if (value) |v| try h.defines.append(gpa, .{ .name = name, .value = v });
    }
}

// --- Files: mkmakefile.cc --------------------------------------------------

fn haveDevice(cfg: *const Config, name: []const u8) bool {
    for (cfg.devices.items) |d| if (mem.eql(u8, d, name)) return true;
    return false;
}

/// Options count in file lists only when they have no value.
fn haveOption(cfg: *const Config, name: []const u8) bool {
    for (cfg.options.items) |o|
        if (o.value == null and ascii.eqlIgnoreCase(o.name, name)) return true;
    return false;
}

fn haveFile(cfg: *const Config, path: []const u8) bool {
    for (cfg.files.items) |f| if (mem.eql(u8, f.path, path)) return true;
    return false;
}

fn readFiles(gpa: Allocator, reader: Reader, cfg: *Config, path: []const u8, diag: *std.ArrayList(u8)) Error!void {
    const text: []const u8 = reader.read(path) orelse {
        diag.print(gpa, "config: cannot open {s}\n", .{path}) catch {};
        return error.ConfigError;
    };
    var words: Words = .{ .buf = text };
    while (true) {
        const first: []const u8 = switch (words.get()) {
            .eof => return,
            .eol => continue,
            .word => |w| w,
        };
        if (first[0] == '#') {
            words.skipLine();
            continue;
        }
        if (mem.eql(u8, first, "include")) {
            const name: []const u8 = switch (try words.getQuoted(gpa)) {
                .word => |w| w,
                else => {
                    diag.print(gpa, "{s}: missing include filename\n", .{path}) catch {};
                    return error.ConfigError;
                },
            };
            try readFiles(gpa, reader, cfg, try join(gpa, "sys", name), diag);
            words.skipLine();
            continue;
        }

        var f: File = .{ .path = first, .srcprefix = "$S/" };
        const kind: []const u8 = switch (words.get()) {
            .word => |w| w,
            .eof => return,
            .eol => {
                diag.print(gpa, "{s}: No type for {s}.\n", .{ path, first }) catch {};
                return error.ConfigError;
            },
        };
        const standard: bool = mem.eql(u8, kind, "standard");
        if (!standard and !mem.eql(u8, kind, "optional")) {
            diag.print(gpa, "{s}: \"{s}\" {s} must be optional or standard\n", .{ path, kind, first }) catch {};
            return error.ConfigError;
        }

        var compile: u32 = 0;
        var match: bool = true;
        var nreqs: u32 = 0;
        var negate: bool = false;
        var local: bool = false;
        while (true) {
            const w: []const u8 = switch (words.get()) {
                .word => |w| w,
                .eol => break,
                .eof => return,
            };
            const Quoted: type = enum { dependency, clean, @"compile-with", warning, @"obj-prefix" };
            if (meta.stringToEnum(Quoted, w)) |q| {
                const s: []const u8 = switch (try words.getQuoted(gpa)) {
                    .word => |s| s,
                    else => {
                        diag.print(gpa, "{s}: {s} missing {s} string\n", .{ path, first, w }) catch {};
                        return error.ConfigError;
                    },
                };
                switch (q) {
                    .dependency => f.dependency = s,
                    .clean => f.clean = s,
                    .@"compile-with" => f.compile_with = s,
                    .warning => f.warning = s,
                    .@"obj-prefix" => f.objprefix = s,
                }
                continue;
            }
            if (mem.eql(u8, w, "!")) {
                negate = true;
                continue;
            }
            if (mem.eql(u8, w, "|")) {
                if (nreqs == 0) {
                    diag.print(gpa, "{s}: syntax error describing {s}\n", .{ path, first }) catch {};
                    return error.ConfigError;
                }
                compile += @intFromBool(match);
                match = true;
                nreqs = 0;
                continue;
            }
            const Flag: type = enum { @"no-ctfconvert", @"no-obj", @"no-implicit-rule", @"before-depend", nowerror, local, @"no-depend" };
            if (meta.stringToEnum(Flag, w)) |fl| {
                switch (fl) {
                    .@"no-ctfconvert" => f.no_ctfconvert = true,
                    .@"no-obj" => f.no_obj = true,
                    .@"no-implicit-rule" => {
                        if (f.compile_with == null) {
                            diag.print(gpa, "{s}: no-implicit-rule needs compile-with for {s}\n", .{ path, first }) catch {};
                            return error.ConfigError;
                        }
                        f.no_implicit_rule = true;
                    },
                    .@"before-depend" => f.before_depend = true,
                    .nowerror => f.nowerror = true,
                    .local => local = true,
                    .@"no-depend" => f.no_depend = true,
                }
                continue;
            }
            nreqs += 1;
            if (standard) {
                diag.print(gpa, "standard entry {s} has optional inclusion specifier {s}!\n", .{ first, w }) catch {};
                return error.ConfigError;
            }
            if (haveDevice(cfg, w) or haveOption(cfg, w)) {
                if (negate) match = false;
            } else {
                match = match and negate;
            }
            negate = false;
        }
        compile += @intFromBool(match);
        if (compile == 0 or haveFile(cfg, first)) continue;
        if (!standard and nreqs == 0) {
            diag.print(gpa, "{s}: what is {s} optional on?\n", .{ path, first }) catch {};
            return error.ConfigError;
        }
        if (local) f.srcprefix = "";
        if (f.no_obj) f.no_ctfconvert = true;
        try cfg.files.append(gpa, f);
    }
}

// --- The whole of config(8) ------------------------------------------------

/// Read sys/<machine>/conf/<kernconf> and everything it needs.  On error,
/// diag holds the message.
pub fn configure(
    gpa: Allocator,
    reader: Reader,
    machine: []const u8,
    kernconf: []const u8,
    diag: *std.ArrayList(u8),
) Error!Config {
    const confdir: []u8 = try fmt.allocPrint(gpa, "sys/{s}/conf", .{machine});
    var cfg: Config = .{};
    var p: Parser = .{
        .gpa = gpa,
        .reader = reader,
        .cfg = &cfg,
        .confdir = confdir,
        .diag = diag,
    };

    const defaults: []const u8 = try join(gpa, confdir, "DEFAULTS");
    if (reader.read(defaults)) |text| try p.parseFile(defaults, text);
    const path: []const u8 = try join(gpa, confdir, kernconf);
    const text: []const u8 = reader.read(path) orelse {
        diag.print(gpa, "config: cannot open {s}\n", .{path}) catch {};
        return error.ConfigError;
    };
    try p.parseFile(path, text);

    if (cfg.machine.len == 0 or cfg.cpus.items.len == 0 or cfg.ident.len == 0) {
        diag.print(gpa, "config: {s} needs machine, cpu and ident\n", .{path}) catch {};
        return error.ConfigError;
    }
    if (cfg.maxusers != 0 and cfg.maxusers < 2) cfg.maxusers = 2;

    // config.c is written before the options, from the lists as read.
    cfg.config_c = try configC(gpa, &cfg);
    if (cfg.envs.items.len > 0 or cfg.hints.items.len > 0) {
        diag.print(gpa, "config: {s}: env and hints are not supported yet\n", .{path}) catch {};
        return error.ConfigError;
    }
    cfg.env_c = try staticStrings(gpa, "static_env");
    cfg.hints_c = try staticStrings(gpa, "static_hints");

    try makeOptions(gpa, reader, &cfg, confdir, diag);

    try readFiles(gpa, reader, &cfg, "sys/conf/files", diag);
    try readFiles(gpa, reader, &cfg, try fmt.allocPrint(gpa, "sys/conf/files.{s}", .{cfg.machine}), diag);
    for (cfg.extra_files.items) |f| try readFiles(gpa, reader, &cfg, try join(gpa, confdir, f), diag);
    return cfg;
}
