//! Comptime tool registry: each tool is a namespace type declaring `name`,
//! `description`, `Args` and `run`. JSON schemas, the `tools/list` payload and
//! argument validation are all derived from the `Args` struct at compile
//! time, so a schema can never drift from the code that parses it.
//!
//! Field metadata lives in the type: `pub const field_info = .{ .repeat =
//! .{ .description = "...", .minimum = 1, .maximum = 100 } };`.

const std = @import("std");
const build_options = @import("build_options");

pub const max_description_len = 300;
pub const max_definition_tokens = 3000;

pub const Annotations = struct {
    read_only: bool = false,
    idempotent: bool = false,
    always_load: bool = false,
};

// ---------------------------------------------------------------- comptime JSON

fn jsonString(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (s) |c| {
            out = out ++ switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0...8, 11, 12, 14...0x1f => std.fmt.comptimePrint("\\u{x:0>4}", .{c}),
                else => &[_]u8{c},
            };
        }
        return out ++ "\"";
    }
}

fn infoOf(comptime Args: type, comptime field: []const u8) ?FieldMeta {
    if (!@hasDecl(Args, "field_info")) return null;
    const all = Args.field_info;
    if (!@hasField(@TypeOf(all), field)) return null;
    const raw = @field(all, field);
    var meta: FieldMeta = .{};
    if (@hasField(@TypeOf(raw), "description")) meta.description = raw.description;
    if (@hasField(@TypeOf(raw), "minimum")) meta.minimum = raw.minimum;
    if (@hasField(@TypeOf(raw), "maximum")) meta.maximum = raw.maximum;
    return meta;
}

const FieldMeta = struct {
    description: ?[]const u8 = null,
    minimum: ?comptime_float = null,
    maximum: ?comptime_float = null,
};

fn numberText(comptime v: comptime_float) []const u8 {
    if (@floor(v) == v) return std.fmt.comptimePrint("{d}", .{@as(i64, @intFromFloat(v))});
    return std.fmt.comptimePrint("{d}", .{@as(f64, v)});
}

/// JSON schema of a value type, without the surrounding property metadata.
fn typeSchema(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "{\"type\":\"boolean\"}",
        .int => "{\"type\":\"integer\"}",
        .float => "{\"type\":\"number\"}",
        .@"enum" => |e| if (@hasDecl(T, "json_schema")) T.json_schema else blk: {
            var list: []const u8 = "";
            for (e.field_names, 0..) |n, i| list = list ++ (if (i == 0) "" else ",") ++ jsonString(n);
            break :blk "{\"type\":\"string\",\"enum\":[" ++ list ++ "]}";
        },
        .optional => |o| typeSchema(o.child),
        .array => |a| std.fmt.comptimePrint("{{\"type\":\"array\",\"items\":{s},\"minItems\":{d},\"maxItems\":{d}}}", .{ typeSchema(a.child), a.len, a.len }),
        .pointer => |p| if (p.size == .slice and p.child == u8)
            "{\"type\":\"string\"}"
        else if (p.size == .slice)
            "{\"type\":\"array\",\"items\":" ++ typeSchema(p.child) ++ "}"
        else
            @compileError("unsupported pointer type in tool arguments: " ++ @typeName(T)),
        else => @compileError("unsupported type in tool arguments: " ++ @typeName(T)),
    };
}

fn isRequired(comptime T: type, comptime attrs: std.lang.Type.Struct.FieldAttributes) bool {
    return @typeInfo(T) != .optional and attrs.default_value_ptr == null;
}

/// `inputSchema` object for an `Args` struct.
pub fn inputSchema(comptime Args: type) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const info = @typeInfo(Args).@"struct";
        var props: []const u8 = "";
        var required: []const u8 = "";
        for (info.field_names, info.field_types, info.field_attrs, 0..) |fname, ftype, fattrs, i| {
            var schema = typeSchema(ftype);
            // Splice property metadata in before the closing brace.
            var extra: []const u8 = "";
            if (infoOf(Args, fname)) |meta| {
                if (meta.description) |d| extra = extra ++ ",\"description\":" ++ jsonString(d);
                if (meta.minimum) |v| extra = extra ++ ",\"minimum\":" ++ numberText(v);
                if (meta.maximum) |v| extra = extra ++ ",\"maximum\":" ++ numberText(v);
            }
            schema = schema[0 .. schema.len - 1] ++ extra ++ "}";
            props = props ++ (if (i == 0) "" else ",") ++ jsonString(fname) ++ ":" ++ schema;
            if (isRequired(ftype, fattrs)) required = required ++ (if (required.len == 0) "" else ",") ++ jsonString(fname);
        }
        var out: []const u8 = "{\"type\":\"object\",\"properties\":{" ++ props ++ "}";
        if (required.len > 0) out = out ++ ",\"required\":[" ++ required ++ "]";
        // No `additionalProperties: false`: parseArgs already rejects unknown
        // fields with an isError naming them, and the 22 repetitions cost
        // about 260 tokens of the definition budget.
        return out ++ "}";
    }
}

fn annotationsOf(comptime T: type) Annotations {
    var a: Annotations = .{};
    if (!@hasDecl(T, "annotations")) return a;
    const raw = T.annotations;
    inline for (@typeInfo(Annotations).@"struct".field_names) |n| {
        if (@hasField(@TypeOf(raw), n)) @field(a, n) = @field(raw, n);
    }
    return a;
}

/// One `Tool` object of `tools/list`.
pub fn toolDefinition(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        if (T.description.len > max_description_len)
            @compileError(std.fmt.comptimePrint("tool `{s}`: description is {d} characters, limit is {d}", .{ T.name, T.description.len, max_description_len }));
        const a = annotationsOf(T);
        var out: []const u8 = "{\"name\":" ++ jsonString(T.name) ++ ",\"description\":" ++ jsonString(T.description) ++ ",\"inputSchema\":" ++ inputSchema(T.Args);
        if (a.read_only or a.idempotent) {
            out = out ++ ",\"annotations\":{" ++ (if (a.read_only) "\"readOnlyHint\":true" else "\"readOnlyHint\":false") ++ (if (a.idempotent) ",\"idempotentHint\":true" else "") ++ "}";
        }
        if (a.always_load) out = out ++ ",\"_meta\":{\"anthropic/alwaysLoad\":true}";
        return out ++ "}";
    }
}

/// Estimated tokens of a definition payload, using the calibrated ratio.
pub fn estimateTokens(comptime bytes: usize) usize {
    const ratio: comptime_float = build_options.text_bytes_per_token;
    return @intFromFloat(@ceil(@as(comptime_float, bytes) / ratio));
}

/// Builds the registry for a tuple of tool namespaces.
pub fn Registry(comptime tools: anytype) type {
    return struct {
        pub const list_result: []const u8 = blk: {
            @setEvalBranchQuota(1_000_000);
            var defs: []const u8 = "";
            for (tools, 0..) |T, i| defs = defs ++ (if (i == 0) "" else ",") ++ toolDefinition(T);
            const tokens = estimateTokens(defs.len);
            if (tokens > max_definition_tokens)
                @compileError(std.fmt.comptimePrint("tool definitions estimate {d} tokens, limit is {d}", .{ tokens, max_definition_tokens }));
            break :blk "{\"tools\":[" ++ defs ++ "]}";
        };

        pub const definition_tokens = estimateTokens(list_result.len);

        pub const names = blk: {
            var out: [tools.len][]const u8 = undefined;
            for (tools, 0..) |T, i| out[i] = T.name;
            break :blk out;
        };

        pub fn has(name: []const u8) bool {
            inline for (tools) |T| if (std.mem.eql(u8, T.name, name)) return true;
            return false;
        }

        /// Whether the named tool acts on the desktop: every tool that is not
        /// read-only, except those declaring `inert` (`wait`). Actions are
        /// refused while paused and in a second instance.
        pub fn isAction(name: []const u8) bool {
            inline for (tools) |T| if (std.mem.eql(u8, T.name, name)) return !annotationsOf(T).read_only and !@hasDecl(T, "inert");
            return false;
        }

        /// Validates `args` against the named tool and runs it. `null` means
        /// the tool is unknown (a protocol error for the caller).
        pub fn call(ctx: anytype, name: []const u8, args: ?std.json.Value) ?@TypeOf(ctx.*).Result {
            inline for (tools) |T| {
                if (std.mem.eql(u8, T.name, name)) {
                    const parsed = parseArgs(T.Args, ctx.arena, args);
                    return switch (parsed) {
                        .invalid => |msg| @TypeOf(ctx.*).Result.err(msg),
                        .ok => |a| T.run(ctx, a),
                    };
                }
            }
            return null;
        }
    };
}

// ---------------------------------------------------------------- argument parsing

pub fn Parsed(comptime Args: type) type {
    return union(enum) { ok: Args, invalid: []const u8 };
}

fn typeLabel(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .bool => "booléen",
        .int => "entier",
        .float => "nombre",
        .@"enum" => |e| blk: {
            var s: []const u8 = "une valeur parmi ";
            for (e.field_names, 0..) |n, i| s = s ++ (if (i == 0) "" else ", ") ++ n;
            break :blk s;
        },
        .optional => |o| typeLabel(o.child),
        .array => |a| std.fmt.comptimePrint("tableau de {d} {s}s", .{ a.len, typeLabel(a.child) }),
        .pointer => |p| if (p.child == u8) "chaîne" else "tableau",
        else => @typeName(T),
    };
}

fn asFloat(v: anytype) f64 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int => @floatFromInt(v),
        .float => @floatCast(v),
        else => unreachable,
    };
}

/// Parses tool arguments with `std.json.parseFromValueLeaky` into `arena`,
/// field by field so an error can name the field and the violated
/// constraint. Nothing is allocated outside `arena`.
pub fn parseArgs(comptime Args: type, arena: std.mem.Allocator, value: ?std.json.Value) Parsed(Args) {
    const info = @typeInfo(Args).@"struct";
    const empty: std.json.ObjectMap = .empty;
    const obj = if (value) |v| switch (v) {
        .object => |o| o,
        .null => empty,
        else => return .{ .invalid = "Arguments invalides : un objet JSON est attendu" },
    } else empty;

    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const known = inline for (info.field_names) |n| {
            if (std.mem.eql(u8, n, key)) break true;
        } else false;
        if (!known) return .{ .invalid = fmt(arena, "Argument inconnu `{s}`", .{key}) };
    }

    var out: Args = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs) |fname, ftype, fattrs| {
        if (obj.get(fname)) |raw| {
            const is_null = raw == .null;
            if (is_null and @typeInfo(ftype) == .optional) {
                @field(out, fname) = null;
            } else {
                @field(out, fname) = std.json.parseFromValueLeaky(ftype, arena, raw, .{}) catch
                    return .{ .invalid = fmt(arena, "Champ `{s}` : {s} attendu", .{ fname, typeLabel(ftype) }) };
                if (comptime infoOf(Args, fname)) |meta| {
                    const present = if (@typeInfo(ftype) == .optional) @field(out, fname).? else @field(out, fname);
                    switch (@typeInfo(@TypeOf(present))) {
                        .int, .float => {
                            const x = asFloat(present);
                            const lo: ?f64 = if (meta.minimum) |m| @as(f64, m) else null;
                            const hi: ?f64 = if (meta.maximum) |m| @as(f64, m) else null;
                            if ((lo != null and x < lo.?) or (hi != null and x > hi.?)) {
                                return .{ .invalid = fmt(arena, "Champ `{s}` : doit être entre {?d} et {?d} (reçu {d})", .{ fname, lo, hi, x }) };
                            }
                        },
                        else => {},
                    }
                }
            }
        } else if (comptime fattrs.defaultValue(ftype)) |dv| {
            @field(out, fname) = dv;
        } else if (@typeInfo(ftype) == .optional) {
            @field(out, fname) = null;
        } else {
            return .{ .invalid = fmt(arena, "Champ `{s}` requis ({s})", .{ fname, typeLabel(ftype) }) };
        }
    }
    return .{ .ok = out };
}

fn fmt(arena: std.mem.Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, f, args) catch "Arguments invalides";
}
