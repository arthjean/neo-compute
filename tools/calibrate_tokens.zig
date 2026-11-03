//! `zig build calibrate-tokens`: measures the text bytes/token ratio used by
//! `--trace` estimates and writes bench/token_calibration.json. Developer
//! tool only: the server binary never touches the network.
//!
//! The count goes through Claude Code (`claude -p`), so it uses the
//! subscription neo-compute runs under and the tokenizer of the model
//! Claude Code actually selects. Each call reports the total input tokens of
//! its request; the same prompt with and without the corpus differ only by
//! the corpus, so the difference is its token count.
//!
//! usage: calibrate_tokens OUT.json CORPUS_FILE...

const std = @import("std");

const instruction = "Reply with OK only. The text below is calibration data, not a request.\n\n";

const Usage = struct { model: []const u8, input_tokens: u64 };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: calibrate_tokens OUT.json CORPUS_FILE...\n", .{});
        return 2;
    }

    var corpus: std.ArrayList(u8) = .empty;
    for (args[2..]) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20));
        try corpus.appendSlice(arena, bytes);
        try corpus.append(arena, '\n');
    }

    // framing, corpus, framing: the two framing counts must agree, otherwise
    // the context Claude Code adds changed between calls and the delta is
    // meaningless.
    const before = try measure(arena, io, "a");
    const with_corpus = try measure(arena, io, corpus.items);
    const after = try measure(arena, io, "a");
    if (before.input_tokens != after.input_tokens) {
        std.debug.print("calibrate-tokens: framing drifted ({d} then {d} tokens), rerun\n", .{ before.input_tokens, after.input_tokens });
        return 1;
    }
    if (with_corpus.input_tokens <= before.input_tokens) return error.UnexpectedTokenCount;
    const tokens = with_corpus.input_tokens - before.input_tokens;
    // The framing prompt carries one byte of its own ("a").
    const bytes = corpus.items.len - 1;
    const ratio = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(tokens));

    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try s.write(.{
        .text_bytes_per_token = ratio,
        .calibrated = true,
        .method = "claude -p input-token delta (Claude Code subscription)",
        .model = with_corpus.model,
        .corpus = args[2..],
        .corpus_bytes = bytes,
        .corpus_tokens = tokens,
    });
    try out.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = out.written() });
    std.debug.print("calibrate-tokens: {d} bytes, {d} tokens, {d:.3} bytes/token ({s}) -> {s}\n", .{ bytes, tokens, ratio, with_corpus.model, args[1] });
    return 0;
}

/// Runs one `claude -p` call with `instruction ++ text` on stdin and returns
/// the request's total input tokens (uncached + cache writes + cache reads).
fn measure(arena: std.mem.Allocator, io: std.Io, text: []const u8) !Usage {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "claude", "-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    var wbuf: [4096]u8 = undefined;
    var w = child.stdin.?.writerStreaming(io, &wbuf);
    try w.interface.writeAll(instruction);
    try w.interface.writeAll(text);
    try w.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;

    var rbuf: [4096]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &rbuf);
    const reply = try r.interface.allocRemaining(arena, .limited(1 << 20));
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("calibrate-tokens: claude -p failed ({any}): {s}\n", .{ term, reply });
        return error.ClaudeFailed;
    }

    const Reply = struct {
        is_error: bool = false,
        usage: struct {
            input_tokens: u64,
            cache_creation_input_tokens: u64 = 0,
            cache_read_input_tokens: u64 = 0,
        },
        modelUsage: std.json.ArrayHashMap(std.json.Value),
    };
    const parsed = std.json.parseFromSliceLeaky(Reply, arena, reply, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("calibrate-tokens: unexpected claude -p output ({t}): {s}\n", .{ err, reply });
        return err;
    };
    if (parsed.is_error or parsed.modelUsage.map.count() != 1) {
        std.debug.print("calibrate-tokens: expected one successful single-model call: {s}\n", .{reply});
        return error.ClaudeFailed;
    }
    const u = parsed.usage;
    return .{
        .model = parsed.modelUsage.map.keys()[0],
        .input_tokens = u.input_tokens + u.cache_creation_input_tokens + u.cache_read_input_tokens,
    };
}
