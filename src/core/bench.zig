//! `neo-compute bench`: runs scenarios, reports p50/p95/p99/max and
//! allocation counts per stage as JSON, and checks p95 against a baseline.
//!
//! A scenario is a value with `name`, `default_iterations` and
//! `step(*Timings) !void`. Setup failures become `unsupported` results so one
//! missing capability never fails the others.

const std = @import("std");
const Io = std.Io;
const timing = @import("timing.zig");
const Timings = timing.Timings;
const Stage = timing.Stage;
const stage_count = timing.stage_count;
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const Fake = @import("../backend/fake.zig").Fake;

pub const Stats = struct {
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    allocations: u64,
};

pub const Outcome = union(enum) {
    ok: struct { iterations: usize, stages: [stage_count]?Stats, total: Stats },
    unsupported: []const u8,
};

pub const Result = struct { name: []const u8, outcome: Outcome };

/// Absolute p95 budgets on a scenario's total (PRD Quality Gates).
pub const budgets = [_]struct { scenario: []const u8, ms: f64 }{
    .{ .scenario = "screenshot", .ms = 30 },
    .{ .scenario = "snapshot", .ms = 50 },
};

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(sorted.len))));
    return sorted[@min(sorted.len - 1, rank -| 1)];
}

fn stats(samples: []u64, allocations: u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .p50_ns = percentile(samples, 0.50),
        .p95_ns = percentile(samples, 0.95),
        .p99_ns = percentile(samples, 0.99),
        .max_ns = samples[samples.len - 1],
        .allocations = allocations,
    };
}

/// Runs `scenario.step` `iterations` times. Sample buffers are allocated
/// before the loop so measurement itself does not allocate.
pub fn measure(gpa: std.mem.Allocator, io: Io, scenario: anytype, iterations: usize, counter: ?*const CountingAllocator) !Outcome {
    const n = @max(iterations, 1);
    const per_stage = try gpa.alloc(u64, n * stage_count);
    defer gpa.free(per_stage);
    const totals = try gpa.alloc(u64, n);
    defer gpa.free(totals);
    var used: [stage_count]bool = @splat(false);
    var allocs: [stage_count]u64 = @splat(0);
    var t: Timings = .{ .counter = counter };
    for (0..n) |i| {
        t.begin(io);
        try scenario.step(&t);
        var total: u64 = 0;
        for (0..stage_count) |s| {
            per_stage[s * n + i] = t.ns[s];
            if (t.used[s]) used[s] = true;
            allocs[s] += t.allocs[s];
            // dispatch encloses the tool's own stages; count it once.
            if (s != @backingInt(Stage.dispatch)) total += t.ns[s];
        }
        totals[i] = total;
    }
    var out: [stage_count]?Stats = @splat(null);
    var total_allocs: u64 = 0;
    for (0..stage_count) |s| if (used[s]) {
        out[s] = stats(per_stage[s * n ..][0..n], allocs[s]);
        total_allocs += allocs[s];
    };
    return .{ .ok = .{ .iterations = n, .stages = out, .total = stats(totals, total_allocs) } };
}

// ---------------------------------------------------------------- transport scenario

/// Parse + dispatch + serialize + write of `ping`, `tools/list` and a
/// validated `tools/call`, through the real dispatcher, into a discarding
/// writer. One iteration replays them `rounds` times so a sample spans tens
/// of microseconds rather than a few timer ticks.
pub const Transport = struct {
    pub const name = "transport";
    pub const default_iterations = 2000;
    pub const rounds = 32;
    const Server = mcp.Server(Fake, tools.all);
    const lines = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"key\",\"arguments\":{\"text\":\"ctrl+s\",\"repeat\":0}}}",
    };

    backend: Fake = .{},
    server: Server,
    sink_buf: [64 * 1024]u8 = undefined,
    sink: Io.Writer.Discarding,

    pub fn init(self: *Transport, gpa: std.mem.Allocator, io: Io) void {
        self.backend = .{};
        self.server = .init(gpa, io, &self.backend, .{});
        self.sink = .init(&self.sink_buf);
    }

    pub fn deinit(self: *Transport) void {
        self.server.deinit();
    }

    pub fn step(self: *Transport, t: *Timings) !void {
        for (0..rounds) |_| for (lines) |line| {
            try self.server.handleMessage(line, &self.sink.writer);
            // handleMessage clears the server's timings per message; fold
            // them into the iteration.
            for (0..stage_count) |s| {
                t.ns[s] += self.server.timings.ns[s];
                t.allocs[s] += self.server.timings.allocs[s];
                if (self.server.timings.used[s]) t.used[s] = true;
            }
        };
    }
};

// ---------------------------------------------------------------- report and check

pub fn writeReport(results: []const Result, w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("scenarios");
    try s.beginArray();
    for (results) |r| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(r.name);
        switch (r.outcome) {
            .unsupported => |why| {
                try s.objectField("status");
                try s.write("unsupported");
                try s.objectField("reason");
                try s.write(why);
            },
            .ok => |ok| {
                try s.objectField("status");
                try s.write("ok");
                try s.objectField("iterations");
                try s.write(ok.iterations);
                try s.objectField("stages");
                try s.beginObject();
                for (ok.stages, 0..) |maybe, i| if (maybe) |st| {
                    try s.objectField(@tagName(@as(Stage, @fromBackingInt(@intCast(i)))));
                    try writeStats(&s, st);
                };
                try s.objectField("total");
                try writeStats(&s, ok.total);
                try s.endObject();
            },
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try w.writeByte('\n');
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn writeStats(s: *std.json.Stringify, st: Stats) !void {
    try s.beginObject();
    try s.objectField("p50_us");
    try s.write(us(st.p50_ns));
    try s.objectField("p95_us");
    try s.write(us(st.p95_ns));
    try s.objectField("p99_us");
    try s.write(us(st.p99_ns));
    try s.objectField("max_us");
    try s.write(us(st.max_ns));
    try s.objectField("allocations");
    try s.write(st.allocations);
    try s.endObject();
}

/// Baseline file: `{"reference_p95_us": {"<scenario>": {"<stage>": us}}}`.
/// Fails when a p95 exceeds 110 % of its reference or a scenario total
/// exceeds its absolute budget. Returns the number of violations.
pub fn check(arena: std.mem.Allocator, baseline_json: []const u8, results: []const Result, log: *Io.Writer) !usize {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, baseline_json, .{});
    const refs = if (v.object.get("reference_p95_us")) |r| r.object else std.json.ObjectMap.empty;
    var violations: usize = 0;
    for (results) |r| {
        const ok = switch (r.outcome) {
            .ok => |ok| ok,
            .unsupported => continue,
        };
        for (budgets) |b| if (std.mem.eql(u8, b.scenario, r.name)) {
            const p95_ms = us(ok.total.p95_ns) / 1000.0;
            if (p95_ms > b.ms) {
                violations += 1;
                try log.print("bench: {s} total p95 {d:.2} ms exceeds the {d} ms budget\n", .{ r.name, p95_ms, b.ms });
            }
        };
        const scenario_refs = refs.get(r.name) orelse continue;
        for (ok.stages, 0..) |maybe, i| {
            const st = maybe orelse continue;
            violations += try compare(log, r.name, @tagName(@as(Stage, @fromBackingInt(@intCast(i)))), st, scenario_refs);
        }
        violations += try compare(log, r.name, "total", ok.total, scenario_refs);
    }
    return violations;
}

fn compare(log: *Io.Writer, scenario: []const u8, stage: []const u8, st: Stats, refs: std.json.Value) !usize {
    if (refs != .object) return 0;
    const ref_v = refs.object.get(stage) orelse return 0;
    const ref: f64 = switch (ref_v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => return 0,
    };
    const p95 = us(st.p95_ns);
    if (p95 <= ref * 1.10) return 0;
    try log.print("bench: {s}.{s} p95 {d:.1} us exceeds 110 % of its {d:.1} us reference\n", .{ scenario, stage, p95, ref });
    return 1;
}

/// Number of runs a baseline is recorded over (`--write-baseline`).
pub const baseline_runs = 5;

/// Keeps, per stage, the worst p95 of `into` and `other` (same scenarios in
/// the same order). A baseline built this way records the run-to-run noise of
/// the machine, so the 110 % rule flags regressions rather than jitter.
pub fn mergeWorstP95(into: []Result, other: []const Result) void {
    for (into, other) |*r, o| {
        if (r.outcome != .ok or o.outcome != .ok) continue;
        const dst = &r.outcome.ok;
        const src = o.outcome.ok;
        for (&dst.stages, src.stages) |*d, maybe| if (d.*) |*st| if (maybe) |os| {
            st.p95_ns = @max(st.p95_ns, os.p95_ns);
        };
        dst.total.p95_ns = @max(dst.total.p95_ns, src.total.p95_ns);
    }
}

/// Writes a baseline whose references are the given p95 values.
pub fn writeBaseline(results: []const Result, w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("reference_p95_us");
    try s.beginObject();
    for (results) |r| switch (r.outcome) {
        .unsupported => {},
        .ok => |ok| {
            try s.objectField(r.name);
            try s.beginObject();
            for (ok.stages, 0..) |maybe, i| if (maybe) |st| {
                try s.objectField(@tagName(@as(Stage, @fromBackingInt(@intCast(i)))));
                try s.write(us(st.p95_ns));
            };
            try s.objectField("total");
            try s.write(us(ok.total.p95_ns));
            try s.endObject();
        },
    };
    try s.endObject();
    try s.endObject();
    try w.writeByte('\n');
}

pub const scenario_names = [_][]const u8{ "transport", "capture", "snapshot", "screenshot" };

/// Runs `which` ("all" or one scenario name). Platform scenarios come from
/// `Backend.benchScenario`; a backend without them reports them unsupported.
pub fn run(comptime Backend: type, gpa: std.mem.Allocator, io: Io, which: []const u8, iterations: ?usize) ![]Result {
    var results: std.ArrayList(Result) = .empty;
    var known = std.mem.eql(u8, which, "all");
    for (scenario_names) |name| {
        if (!std.mem.eql(u8, which, "all") and !std.mem.eql(u8, which, name)) continue;
        known = true;
        var counter: CountingAllocator = .init(gpa);
        const outcome: Outcome = if (std.mem.eql(u8, name, "transport")) blk: {
            const t = try gpa.create(Transport);
            defer gpa.destroy(t);
            t.init(counter.allocator(), io);
            defer t.deinit();
            // Warm the request arena so steady-state allocations show as 0.
            for (0..100) |_| {
                var scratch: Timings = .{};
                try t.step(&scratch);
            }
            break :blk try measure(gpa, io, t, iterations orelse Transport.default_iterations, &counter);
        } else if (@hasDecl(Backend, "benchScenario"))
            try Backend.benchScenario(gpa, io, &counter, name, iterations)
        else
            .{ .unsupported = "not available on this backend" };
        try results.append(gpa, .{ .name = name, .outcome = outcome });
    }
    if (!known) return error.UnknownScenario;
    return results.toOwnedSlice(gpa);
}
