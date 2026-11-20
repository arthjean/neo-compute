//! A small XML reader for protocol descriptions (Wayland, EI, D-Bus
//! introspection). std has none. It builds an element tree and keeps no
//! text: the generator reads attributes only.
//!
//! It refuses what a protocol description never needs and a hostile file
//! could abuse: an internal DTD subset (`<!DOCTYPE x [ ... ]>`), any
//! `<!ENTITY>` declaration, and every entity reference other than the five
//! predefined ones and numeric character references. A DOCTYPE without an
//! internal subset, as every D-Bus introspection file carries, names an
//! external DTD that is never read.

const std = @import("std");

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Element = struct {
    name: []const u8,
    attrs: []const Attr,
    children: []const Element,
    /// 1-based line of the start tag.
    line: u32,

    pub fn attr(e: Element, name: []const u8) ?[]const u8 {
        for (e.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    /// The children named `name`, in document order.
    pub fn each(e: Element, name: []const u8) Iterator {
        return .{ .children = e.children, .name = name };
    }

    pub const Iterator = struct {
        children: []const Element,
        name: []const u8,
        i: usize = 0,

        pub fn next(it: *Iterator) ?Element {
            while (it.i < it.children.len) {
                const c = it.children[it.i];
                it.i += 1;
                if (std.mem.eql(u8, c.name, it.name)) return c;
            }
            return null;
        }
    };
};

pub const Error = error{
    OutOfMemory,
    /// Malformed markup; `Diagnostic` holds the line and the reason.
    Syntax,
    /// An internal DTD subset or an `<!ENTITY>` declaration.
    DtdRefused,
    /// An entity reference other than the predefined ones.
    EntityRefused,
};

pub const Diagnostic = struct {
    line: u32 = 0,
    reason: []const u8 = "",
};

const max_depth = 64;

/// Parses `src` into the root element, allocating from `arena`.
pub fn parse(arena: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error!Element {
    var p: Parser = .{ .arena = arena, .src = src, .diag = diag };
    return p.document();
}

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    diag: *Diagnostic,

    fn fail(p: *Parser, err: Error, reason: []const u8) Error {
        p.diag.* = .{ .line = p.line, .reason = reason };
        return err;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], s);
    }

    fn advance(p: *Parser, n: usize) void {
        for (p.src[p.pos..][0..n]) |c| {
            if (c == '\n') p.line += 1;
        }
        p.pos += n;
    }

    fn skipSpace(p: *Parser) void {
        while (p.peek()) |c| switch (c) {
            ' ', '\t', '\r', '\n' => p.advance(1),
            else => return,
        };
    }

    /// Skips to just past `end`, or fails.
    fn skipPast(p: *Parser, end: []const u8, what: []const u8) Error!void {
        const i = std.mem.indexOfPos(u8, p.src, p.pos, end) orelse return p.fail(error.Syntax, what);
        p.advance(i + end.len - p.pos);
    }

    fn document(p: *Parser) Error!Element {
        if (p.startsWith("\xEF\xBB\xBF")) p.advance(3);
        var root: ?Element = null;
        while (true) {
            p.skipSpace();
            if (p.pos >= p.src.len) break;
            if (p.startsWith("<?")) {
                try p.skipPast("?>", "unterminated processing instruction");
            } else if (p.startsWith("<!--")) {
                try p.skipPast("-->", "unterminated comment");
            } else if (p.startsWith("<!DOCTYPE")) {
                if (root != null) return p.fail(error.Syntax, "DOCTYPE after the root element");
                try p.doctype();
            } else if (p.startsWith("<!")) {
                return p.fail(error.DtdRefused, "markup declaration outside a DTD");
            } else if (p.startsWith("<")) {
                if (root != null) return p.fail(error.Syntax, "second root element");
                root = try p.element(0);
            } else {
                return p.fail(error.Syntax, "text outside the root element");
            }
        }
        return root orelse p.fail(error.Syntax, "no root element");
    }

    /// `<!DOCTYPE name PUBLIC "..." "...">` or `SYSTEM "..."`, never an
    /// internal subset.
    fn doctype(p: *Parser) Error!void {
        p.advance("<!DOCTYPE".len);
        while (p.peek()) |c| switch (c) {
            '[' => return p.fail(error.DtdRefused, "internal DTD subset"),
            '"', '\'' => {
                p.advance(1);
                const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, c) orelse return p.fail(error.Syntax, "unterminated DOCTYPE literal");
                p.advance(end + 1 - p.pos);
            },
            '>' => {
                p.advance(1);
                return;
            },
            else => p.advance(1),
        };
        return p.fail(error.Syntax, "unterminated DOCTYPE");
    }

    fn isNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':' or c >= 0x80;
    }

    fn name(p: *Parser) Error![]const u8 {
        const start = p.pos;
        while (p.peek()) |c| {
            if (!isNameChar(c)) break;
            p.advance(1);
        }
        if (p.pos == start) return p.fail(error.Syntax, "expected a name");
        return p.src[start..p.pos];
    }

    fn element(p: *Parser, depth: usize) Error!Element {
        if (depth >= max_depth) return p.fail(error.Syntax, "elements nested too deep");
        const line = p.line;
        p.advance(1); // <
        const tag = try p.name();
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            p.skipSpace();
            const c = p.peek() orelse return p.fail(error.Syntax, "unterminated start tag");
            if (c == '/') {
                if (!p.startsWith("/>")) return p.fail(error.Syntax, "expected />");
                p.advance(2);
                return .{ .name = tag, .attrs = try attrs.toOwnedSlice(p.arena), .children = &.{}, .line = line };
            }
            if (c == '>') {
                p.advance(1);
                break;
            }
            const an = try p.name();
            p.skipSpace();
            if (p.peek() != '=') return p.fail(error.Syntax, "expected = after an attribute name");
            p.advance(1);
            p.skipSpace();
            const q = p.peek() orelse return p.fail(error.Syntax, "unterminated attribute");
            if (q != '"' and q != '\'') return p.fail(error.Syntax, "attribute value without quotes");
            p.advance(1);
            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, q) orelse return p.fail(error.Syntax, "unterminated attribute value");
            const raw = p.src[p.pos..end];
            if (std.mem.indexOfScalar(u8, raw, '<') != null) return p.fail(error.Syntax, "< in an attribute value");
            const value = try p.decode(raw);
            p.advance(end + 1 - p.pos);
            for (attrs.items) |a| if (std.mem.eql(u8, a.name, an)) return p.fail(error.Syntax, "duplicate attribute");
            try attrs.append(p.arena, .{ .name = an, .value = value });
        }

        var children: std.ArrayList(Element) = .empty;
        while (true) {
            const lt = std.mem.indexOfScalarPos(u8, p.src, p.pos, '<') orelse return p.fail(error.Syntax, "unterminated element");
            _ = try p.decode(p.src[p.pos..lt]); // text: checked, not kept
            p.advance(lt - p.pos);
            if (p.startsWith("</")) {
                p.advance(2);
                const close = try p.name();
                if (!std.mem.eql(u8, close, tag)) return p.fail(error.Syntax, "end tag does not match its start tag");
                p.skipSpace();
                if (p.peek() != '>') return p.fail(error.Syntax, "expected > after an end tag");
                p.advance(1);
                return .{ .name = tag, .attrs = try attrs.toOwnedSlice(p.arena), .children = try children.toOwnedSlice(p.arena), .line = line };
            } else if (p.startsWith("<!--")) {
                try p.skipPast("-->", "unterminated comment");
            } else if (p.startsWith("<![CDATA[")) {
                try p.skipPast("]]>", "unterminated CDATA section");
            } else if (p.startsWith("<!")) {
                return p.fail(error.DtdRefused, "markup declaration inside an element");
            } else if (p.startsWith("<?")) {
                try p.skipPast("?>", "unterminated processing instruction");
            } else {
                try children.append(p.arena, try p.element(depth + 1));
            }
        }
    }

    /// Replaces the references of `raw` (attribute value or text); refuses
    /// any entity other than the predefined five.
    fn decode(p: *Parser, raw: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '&') {
                try out.append(p.arena, raw[i]);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return p.fail(error.EntityRefused, "& without a reference");
            const ref = raw[i + 1 .. semi];
            i = semi + 1;
            const predefined = [_]struct { []const u8, u8 }{ .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' } };
            const known: ?u8 = for (predefined) |e| {
                if (std.mem.eql(u8, ref, e[0])) break e[1];
            } else null;
            if (known) |c| {
                try out.append(p.arena, c);
                continue;
            }
            if (ref.len < 2 or ref[0] != '#') return p.fail(error.EntityRefused, "entity reference other than lt, gt, amp, quot and apos");
            const code = (if (ref[1] == 'x')
                std.fmt.parseInt(u21, ref[2..], 16)
            else
                std.fmt.parseInt(u21, ref[1..], 10)) catch return p.fail(error.Syntax, "invalid character reference");
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(code, &buf) catch return p.fail(error.Syntax, "invalid character reference");
            try out.appendSlice(p.arena, buf[0..n]);
        }
        return out.items;
    }
};

const testing = std.testing;

test "a minimal protocol is read with its attributes and children" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const root = try parse(arena.allocator(),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- a comment -->
        \\<protocol name="p">
        \\  <copyright>a &lt;b&gt; &amp; &#233;<![CDATA[ <x> ]]></copyright>
        \\  <interface name="i" version='3'>
        \\    <request name="r"><arg name="a" type="uint" summary="&quot;q&quot;"/></request>
        \\  </interface>
        \\</protocol>
    , &diag);
    try testing.expectEqualStrings("protocol", root.name);
    try testing.expectEqualStrings("p", root.attr("name").?);
    var it = root.each("interface");
    const iface = it.next().?;
    try testing.expectEqualStrings("3", iface.attr("version").?);
    try testing.expectEqual(@as(u32, 5), iface.line);
    try testing.expect(it.next() == null);
    const arg = iface.children[0].children[0];
    try testing.expectEqualStrings("\"q\"", arg.attr("summary").?);
}

test "a D-Bus DOCTYPE without an internal subset is accepted, its DTD never read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const root = try parse(arena.allocator(),
        \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
        \\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        \\<node><interface name="a.b"/></node>
    , &diag);
    try testing.expectEqualStrings("node", root.name);
}

test "an internal DTD subset, an entity declaration and an unknown entity are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.DtdRefused, parse(arena.allocator(),
        \\<!DOCTYPE node [ <!ENTITY big "x"> ]>
        \\<node/>
    , &diag));
    try testing.expectError(error.DtdRefused, parse(arena.allocator(), "<!ENTITY x \"y\"><node/>", &diag));
    try testing.expectError(error.DtdRefused, parse(arena.allocator(), "<node><!ENTITY x \"y\"></node>", &diag));
    try testing.expectError(error.EntityRefused, parse(arena.allocator(), "<node name=\"&big;\"/>", &diag));
    try testing.expectError(error.EntityRefused, parse(arena.allocator(), "<node>&xxe;</node>", &diag));
    try testing.expectEqual(@as(u32, 1), diag.line);
}

test "malformed markup fails with a reason" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    for ([_][]const u8{ "<a><b></a>", "<a x=1/>", "<a x=\"1\" x=\"2\"/>", "<a>", "", "<a/><b/>", "text", "<a x=\"<\"/>" }) |src| {
        try testing.expectError(error.Syntax, parse(arena.allocator(), src, &diag));
        try testing.expect(diag.reason.len > 0);
    }
}
