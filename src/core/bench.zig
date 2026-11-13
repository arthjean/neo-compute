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
const uitree = @import("uitree.zig");

pub const Stats = struct {
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    allocations: u64,
};

pub const Outcome = union(enum) {
    ok: struct {
        iterations: usize,
        stages: [stage_count]?Stats,
        total: Stats,
        /// p95 of the C witness probe on the same window, for a
        /// provider-bound budget (decision 0004) or a provider-relative
        /// reference (decision 0010).
        witness_p95_ns: ?u64 = null,
    },
    unsupported: []const u8,
};

pub const Result = struct { name: []const u8, outcome: Outcome };

/// Absolute p95 budgets on a scenario's total (PRD Quality Gates). A
/// provider-bound budget also passes when the total stays within 110 % of the
/// C witness probe on the same window: the cost is then the provider's
/// (decision 0004). A budget `over` another scenario is that scenario's
/// total p95 in the same run (its absolute budget when it did not run) plus
/// `ms`, plus the scenario's witness when it has one: `marks` is budgeted
/// on what it adds to the ui_tree of the same window. A budget with a
/// `stage` is on that stage's p95 instead of the total: the settling of the
/// background mode, which the total leaves out.
pub const budgets = [_]struct { scenario: []const u8, ms: f64, provider_bound: bool = false, over: ?[]const u8 = null, stage: ?Stage = null }{
    .{ .scenario = "capture", .ms = 8 },
    // US-032: BitBlt of a 2560x1440 display into a DIB section.
    .{ .scenario = "capture-gdi", .ms = 40 },
    .{ .scenario = "screenshot", .ms = 30 },
    .{ .scenario = "snapshot", .ms = 50 },
    .{ .scenario = "window_list", .ms = 5 },
    .{ .scenario = "diff", .ms = 3 },
    .{ .scenario = "ui_tree", .ms = 50 },
    // US-011 and US-014, on the reference applications (bench <app>).
    .{ .scenario = "notepad", .ms = 50 },
    // US-023: Notepad with its context menu open, read as a second root.
    .{ .scenario = "notepad-menu", .ms = 50 },
    .{ .scenario = "explorer", .ms = 50, .provider_bound = true },
    .{ .scenario = "settings", .ms = 50 },
    .{ .scenario = "calculator", .ms = 50 },
    .{ .scenario = "chrome", .ms = 120 },
    // US-024: the reference page with its text (ui_tree text: true).
    .{ .scenario = "chrome-text", .ms = 120 },
    // US-025: the reference page in Firefox, through native UIA or MSAA.
    .{ .scenario = "firefox", .ms = 150 },
    // US-025: the same page with Firefox's native UIA off (MSAA proxy).
    .{ .scenario = "firefox-msaa", .ms = 150 },
    .{ .scenario = "vscode", .ms = 120 },
    // US-027: window_set without settling.
    .{ .scenario = "window_set", .ms = 20 },
    // US-028 (A13): a Start menu enumeration, and a match on the cached
    // catalog.
    .{ .scenario = "apps-catalog", .ms = 300 },
    .{ .scenario = "apps", .ms = 1 },
    // US-031: ui_tree marks on a test window costs less than 8 ms beyond
    // a screenshot of the same display.
    .{ .scenario = "marks", .ms = 8, .over = "screenshot" },
    // US-048: a background ui_act on the covered test window, settling
    // apart; and the settling of an action without effect while the window
    // over the target repaints itself.
    .{ .scenario = "bg-act", .ms = 20 },
    .{ .scenario = "bg-settle", .ms = 150, .stage = .settle },
    // US-061: screenshot of a covered 2560x1440 window, in background mode.
    .{ .scenario = "bg-capture", .ms = 60 },
};

/// Total p95 in ms of scenario `name` in `results`, else its absolute
/// budget.
fn reference(results: []const Result, name: []const u8) ?f64 {
    for (results) |r| if (std.mem.eql(u8, r.name, name)) switch (r.outcome) {
        .ok => |ok| return us(ok.total.p95_ns) / 1000.0,
        .unsupported => {},
    };
    for (budgets) |b| if (std.mem.eql(u8, b.scenario, name) and b.over == null) return b.ms;
    return null;
}

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
            // settle waits on the application, not on neo-compute (US-015).
            if (s != @backingInt(Stage.dispatch) and s != @backingInt(Stage.settle)) total += t.ns[s];
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
/// validated `tools/call` without observation (the `diff` and `ui_tree`
/// scenarios time observations), through the real dispatcher, into a
/// discarding writer. One iteration replays them `rounds` times so a sample spans tens
/// of microseconds rather than a few timer ticks.
pub const Transport = struct {
    pub const name = "transport";
    pub const default_iterations = 2000;
    pub const rounds = 32;
    const Server = mcp.Server(Fake, tools.all);
    const lines = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"key\",\"arguments\":{\"text\":\"ctrl+s\",\"repeat\":0,\"observe\":\"none\"}}}",
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

// ---------------------------------------------------------------- diff scenario

/// Diff of two 1,500-element trees with a few additions, removals and
/// changes per iteration (US-012: p95 < 3 ms).
pub const Diff = struct {
    pub const name = "diff";
    pub const default_iterations = 1000;
    const n = 1500;

    old: [n]uitree.Shown = undefined,
    new: [n]uitree.Shown = undefined,
    arena: std.heap.ArenaAllocator,
    io: Io,
    round: u32 = 0,

    pub fn init(self: *Diff, gpa: std.mem.Allocator, io: Io) void {
        self.* = .{ .arena = .init(gpa), .io = io };
        for (&self.old, 0..) |*s, i| s.* = .{ .id = @intCast(i + 1), .role = .button, .states = .{}, .name_hash = i *% 0x9e3779b97f4a7c15, .value_hash = 0, .rect = .{ .x = @intCast(i % 40 * 30), .y = @intCast(i / 40 * 20), .w = 28, .h = 18 } };
    }

    pub fn step(self: *Diff, t: *Timings) !void {
        _ = self.arena.reset(.retain_capacity);
        self.new = self.old;
        self.round +%= 1;
        // 5 renamed, 5 moved, 5 replaced by new elements.
        for (0..5) |k| {
            const i = (self.round * 97 + k * 301) % n;
            self.new[i].name_hash +%= 1;
            self.new[(i + 1) % n].rect.x += 9;
            self.new[(i + 2) % n].id = @intCast(n + 1 + self.round * 5 + k);
        }
        t.start(self.io, .diff);
        defer t.stop(self.io, .diff);
        _ = try uitree.diff(self.arena.allocator(), &self.old, &self.new);
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
                if (ok.witness_p95_ns) |wp| {
                    try s.objectField("witness_p95_us");
                    try s.write(us(wp));
                }
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

/// Scenarios whose provider stages are checked against the provider as well
/// as their reference (decision 0010): the taskbar's UIA provider drifts
/// with the machine's state, so such a stage above 110 % of its reference
/// still passes within 110 % of the witness probe reading the same tree the
/// same way (`probe_c ... full`), measured before and after the series.
/// Their other stages and their absolute budgets stay as they are.
pub const provider_relative = [_][]const u8{ "snapshot", "ui_tree" };

/// Stages that wait on the provider: the UIA round trips and the stages
/// that contain them.
fn providerStage(stage: []const u8) bool {
    for ([_][]const u8{ "accessibility", "dispatch", "total" }) |s| if (std.mem.eql(u8, s, stage)) return true;
    return false;
}

fn providerRelative(scenario: []const u8) bool {
    for (provider_relative) |s| if (std.mem.eql(u8, s, scenario)) return true;
    return false;
}

/// Baseline file: `{"reference_p95_us": {"<scenario>": {"<stage>": us}},
/// "reference_p50_us": the same shape, "passes_p95_us": {"<scenario>":
/// {"<stage>": [us of each baseline pass]}}}`; the last two are optional.
/// Fails when a p95 exceeds 110 % of its reference by at least
/// `min_regression_us` and the limit its own noise sets (`fence` of its
/// baseline passes; for a provider stage of a provider-relative scenario,
/// 110 % of the witness probe instead), when a p50 exceeds 110 % of its
/// reference, or when a scenario total exceeds its absolute budget. The
/// p95 of a few hundred iterations is set by its slowest ten: it moved by
/// 22 % from one series to the next where the median moved by 2 to 7 %
/// (`bg-act`, decision 0013), so the median carries the tight rule and the
/// tail a limit as wide as it was measured to vary. Returns the number of
/// violations.
pub fn check(arena: std.mem.Allocator, baseline_json: []const u8, results: []const Result, log: *Io.Writer) !usize {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, baseline_json, .{});
    const refs = section(v, "reference_p95_us");
    const medians = section(v, "reference_p50_us");
    const noise = section(v, "passes_p95_us");
    var violations: usize = 0;
    for (results) |r| {
        const ok = switch (r.outcome) {
            .ok => |ok| ok,
            .unsupported => continue,
        };
        for (budgets) |b| if (std.mem.eql(u8, b.scenario, r.name)) {
            if (b.stage) |stage| {
                const st = ok.stages[@backingInt(stage)] orelse {
                    violations += 1;
                    try log.print("bench: {s} has no {t} stage to hold against its {d} ms budget\n", .{ r.name, stage, b.ms });
                    continue;
                };
                const stage_ms = us(st.p95_ns) / 1000.0;
                if (stage_ms <= b.ms) continue;
                violations += 1;
                try log.print("bench: {s} {t} p95 {d:.2} ms exceeds the {d} ms budget\n", .{ r.name, stage, stage_ms, b.ms });
                continue;
            }
            const p95_ms = us(ok.total.p95_ns) / 1000.0;
            if (b.over) |other| {
                const witness_ms = if (ok.witness_p95_ns) |wn| us(wn) / 1000.0 else 0;
                const base = (reference(results, other) orelse continue) + witness_ms;
                if (p95_ms <= base + b.ms) continue;
                violations += 1;
                try log.print("bench: {s} total p95 {d:.2} ms exceeds {s} p95 (with its witness) {d:.2} ms + {d} ms\n", .{ r.name, p95_ms, other, base, b.ms });
                continue;
            }
            if (p95_ms <= b.ms) continue;
            if (b.provider_bound) {
                const witness = ok.witness_p95_ns orelse {
                    violations += 1;
                    try log.print("bench: {s} total p95 {d:.2} ms exceeds the {d} ms budget and no witness probe ran (build zig-out/bin/probe_c.exe)\n", .{ r.name, p95_ms, b.ms });
                    continue;
                };
                const witness_ms = us(witness) / 1000.0;
                if (p95_ms <= witness_ms * 1.10) continue;
                violations += 1;
                try log.print("bench: {s} total p95 {d:.2} ms exceeds the {d} ms budget and 110 % of the {d:.2} ms witness probe\n", .{ r.name, p95_ms, b.ms, witness_ms });
            } else {
                violations += 1;
                try log.print("bench: {s} total p95 {d:.2} ms exceeds the {d} ms budget\n", .{ r.name, p95_ms, b.ms });
            }
        };
        const base: Base = .{
            .p95 = refs.get(r.name),
            .p50 = medians.get(r.name),
            .passes = noise.get(r.name),
            .relative = providerRelative(r.name),
            .witness_ns = if (providerRelative(r.name)) ok.witness_p95_ns else null,
        };
        if (base.p95 == null and base.p50 == null) continue;
        for (ok.stages, 0..) |maybe, i| {
            const st = maybe orelse continue;
            // Settling time depends on the application on screen: reported,
            // never checked.
            if (i == @backingInt(Stage.settle)) continue;
            violations += try compare(log, r.name, @tagName(@as(Stage, @fromBackingInt(@intCast(i)))), st, base);
        }
        violations += try compare(log, r.name, "total", ok.total, base);
    }
    return violations;
}

fn section(v: std.json.Value, name: []const u8) std.json.ObjectMap {
    if (v != .object) return .empty;
    const s = v.object.get(name) orelse return .empty;
    return if (s == .object) s.object else .empty;
}

/// What a scenario is held against: its references, the p95 of each
/// baseline pass, and for a provider-relative scenario its witness probe.
const Base = struct {
    p95: ?std.json.Value,
    p50: ?std.json.Value,
    passes: ?std.json.Value,
    relative: bool,
    witness_ns: ?u64,
};

fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn referenceOf(refs: ?std.json.Value, stage: []const u8) ?f64 {
    const o = refs orelse return null;
    if (o != .object) return null;
    return number(o.object.get(stage) orelse return null);
}

/// Fewest baseline passes a noise limit is drawn from, and the most read.
pub const min_passes = 4;
const max_passes = 32;

/// Upper fence of `values` (Tukey: the third quartile plus 1.5 times the
/// interquartile range), sorted in place: the limit a new measure of the
/// same code stays under, drawn from how far its own measures spread.
/// rustc-perf judges a change against the same kind of bound. Null below
/// `min_passes` values.
pub fn fence(values: []f64) ?f64 {
    if (values.len < min_passes) return null;
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const q1 = quantile(values, 0.25);
    const q3 = quantile(values, 0.75);
    return q3 + 1.5 * (q3 - q1);
}

fn quantile(sorted: []const f64, q: f64) f64 {
    const pos = q * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi = @min(lo + 1, sorted.len - 1);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - @as(f64, @floatFromInt(lo)));
}

fn noiseLimit(passes: ?std.json.Value, stage: []const u8) ?f64 {
    const o = passes orelse return null;
    if (o != .object) return null;
    const list = o.object.get(stage) orelse return null;
    if (list != .array) return null;
    var buf: [max_passes]f64 = undefined;
    var n: usize = 0;
    for (list.array.items) |item| {
        if (n == buf.len) break;
        buf[n] = number(item) orelse continue;
        n += 1;
    }
    return fence(buf[0..n]);
}

fn compare(log: *Io.Writer, scenario: []const u8, stage: []const u8, st: Stats, base: Base) !usize {
    var violations: usize = 0;
    // A provider stage of a provider-relative scenario follows the witness
    // probe (decision 0010), never a noise limit: the passes of a day the
    // provider was slow would clear the regressions of the next.
    const provider = base.relative and providerStage(stage);
    if (referenceOf(base.p95, stage)) |ref| check: {
        const p95 = us(st.p95_ns);
        // Below 1 us of difference the timer resolution dominates: 0.3 to
        // 0.4 us is one tick, not a regression.
        if (p95 <= ref * 1.10 or p95 - ref < min_regression_us) break :check;
        if (provider) if (base.witness_ns) |wn| {
            const witness = us(wn);
            if (p95 <= witness * 1.10) {
                try log.print("bench: {s}.{s} p95 {d:.1} us exceeds 110 % of its {d:.1} us reference, within 110 % of the {d:.1} us witness probe (provider-relative)\n", .{ scenario, stage, p95, ref, witness });
                break :check;
            }
            try log.print("bench: {s}.{s} p95 {d:.1} us exceeds 110 % of its {d:.1} us reference and of the {d:.1} us witness probe\n", .{ scenario, stage, p95, ref, witness });
            violations += 1;
            break :check;
        };
        if (!provider) if (noiseLimit(base.passes, stage)) |limit| {
            if (p95 <= limit) {
                try log.print("bench: {s}.{s} p95 {d:.1} us exceeds 110 % of its {d:.1} us reference, within the {d:.1} us limit of its own noise\n", .{ scenario, stage, p95, ref, limit });
                break :check;
            }
            try log.print("bench: {s}.{s} p95 {d:.1} us exceeds 110 % of its {d:.1} us reference and the {d:.1} us limit of its own noise\n", .{ scenario, stage, p95, ref, limit });
            violations += 1;
            break :check;
        };
        try log.print("bench: {s}.{s} p95 {d:.1} us exceeds 110 % of its {d:.1} us reference\n", .{ scenario, stage, p95, ref });
        violations += 1;
    }
    if (referenceOf(base.p50, stage)) |ref| check: {
        const p50 = us(st.p50_ns);
        if (p50 <= ref * 1.10 or p50 - ref < min_regression_us) break :check;
        if (provider) if (base.witness_ns) |wn| if (p50 <= us(wn) * 1.10) break :check;
        try log.print("bench: {s}.{s} p50 {d:.1} us exceeds 110 % of its {d:.1} us median reference\n", .{ scenario, stage, p50, ref });
        violations += 1;
    }
    return violations;
}

/// Smallest p95 increase over a reference that counts as a regression.
pub const min_regression_us = 1.0;

/// Number of runs a baseline is recorded over (`--write-baseline`).
pub const baseline_runs = 5;

/// Stage `i` of a result, the total at `stage_count`.
fn statOf(r: Result, i: usize) ?Stats {
    return switch (r.outcome) {
        .unsupported => null,
        .ok => |ok| if (i == stage_count) ok.total else ok.stages[i],
    };
}

/// Writes a baseline from `passes` runs of the same scenarios in the same
/// order: per stage the worst p95 and the worst p50 (so the 110 % rule
/// flags regressions rather than jitter), and the p95 of every pass, from
/// which `check` draws the limit of the stage's own noise.
pub fn writeBaseline(passes: []const []const Result, w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    const Kind = enum { reference_p95_us, reference_p50_us, passes_p95_us };
    inline for (@typeInfo(Kind).@"enum".field_names) |name| {
        const kind = @field(Kind, name);
        try s.objectField(name);
        try s.beginObject();
        for (passes[0], 0..) |first, index| {
            if (first.outcome != .ok) continue;
            try s.objectField(first.name);
            try s.beginObject();
            for (0..stage_count + 1) |i| {
                if (statOf(first, i) == null) continue;
                try s.objectField(if (i == stage_count) "total" else @tagName(@as(Stage, @fromBackingInt(@intCast(i)))));
                if (kind == .passes_p95_us) try s.beginArray();
                var worst: u64 = 0;
                for (passes) |pass| {
                    const st = statOf(pass[index], i) orelse continue;
                    switch (kind) {
                        .reference_p95_us => worst = @max(worst, st.p95_ns),
                        .reference_p50_us => worst = @max(worst, st.p50_ns),
                        .passes_p95_us => try s.write(us(st.p95_ns)),
                    }
                }
                if (kind == .passes_p95_us) try s.endArray() else try s.write(us(worst));
            }
            try s.endObject();
        }
        try s.endObject();
    }
    try s.endObject();
    try w.writeByte('\n');
}

/// `settle` reports the settling time of an action apart (US-015): it has
/// no budget and no reference, its other stages are the post-action delta.
/// `bg-act` and `bg-settle` run the background mode behind a decoy window
/// (US-048), `bg-capture` captures a covered window of 2560x1440 (US-061);
/// they come last, after the scenarios that own the foreground.
pub const scenario_names = [_][]const u8{ "transport", "diff", "capture", "capture-gdi", "snapshot", "screenshot", "window_list", "ui_tree", "settle", "window_set", "apps-catalog", "apps", "marks", "bg-act", "bg-settle", "bg-capture" };

/// Scenarios that open applications on the desktop: run on request only
/// (`neo-compute bench chrome`), never by `all`.
pub const app_scenarios = [_][]const u8{ "notepad", "notepad-menu", "explorer", "settings", "calculator", "chrome", "chrome-text", "firefox", "firefox-msaa", "vscode", "app_launch" };

/// Runs `which` ("all" or one scenario name). Platform scenarios come from
/// `Backend.benchScenario`; a backend without them reports them unsupported.
pub fn run(comptime Backend: type, gpa: std.mem.Allocator, io: Io, which: []const u8, iterations: ?usize) ![]Result {
    var results: std.ArrayList(Result) = .empty;
    var known = std.mem.eql(u8, which, "all");
    for (scenario_names ++ app_scenarios, 0..) |name, index| {
        const explicit = std.mem.eql(u8, which, name);
        if (!explicit and (index >= scenario_names.len or !std.mem.eql(u8, which, "all"))) continue;
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
        } else if (std.mem.eql(u8, name, "diff")) blk: {
            const d = try gpa.create(Diff);
            defer gpa.destroy(d);
            d.init(counter.allocator(), io);
            defer d.arena.deinit();
            for (0..100) |_| {
                var scratch: Timings = .{};
                try d.step(&scratch);
            }
            break :blk try measure(gpa, io, d, iterations orelse Diff.default_iterations, &counter);
        } else if (@hasDecl(Backend, "benchScenario"))
            try Backend.benchScenario(gpa, io, &counter, name, iterations)
        else
            .{ .unsupported = "not available on this backend" };
        try results.append(gpa, .{ .name = name, .outcome = outcome });
    }
    if (!known) return error.UnknownScenario;
    return results.toOwnedSlice(gpa);
}
