//! Tests of the bench harness: per-stage timings and allocation counts,
//! the JSON report, the baseline check and unsupported scenarios.

const std = @import("std");
const testing = std.testing;
const bench = @import("bench.zig");
const timing = @import("timing.zig");
const Fake = @import("../backend/fake.zig").Fake;

test "transport scenario records parse/dispatch/serialize/write timings and no steady-state allocation" {
    const results = try bench.run(Fake, testing.allocator, testing.io, "transport", 500);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    const ok = results[0].outcome.ok;
    try testing.expectEqual(@as(usize, 500), ok.iterations);
    for ([_]timing.Stage{ .parse, .dispatch, .serialize, .write }) |s| {
        const st = ok.stages[@backingInt(s)].?;
        try testing.expect(st.p50_ns > 0);
        try testing.expect(st.p50_ns <= st.p95_ns and st.p95_ns <= st.p99_ns and st.p99_ns <= st.max_ns);
        try testing.expectEqual(@as(u64, 0), st.allocations);
    }
    // Transport overhead NFR: parse + dispatch + serialization p95 < 1 ms
    // per message (one iteration carries rounds * 3 messages).
    try testing.expect(ok.total.p95_ns < bench.Transport.rounds * 3 * std.time.ns_per_ms);
}

test "a backend without platform scenarios reports them unsupported without failing the run" {
    const results = try bench.run(Fake, testing.allocator, testing.io, "all", 50);
    defer testing.allocator.free(results);
    try testing.expectEqual(bench.scenario_names.len, results.len);
    // transport and diff are portable; the others need a platform backend.
    try testing.expect(results[0].outcome == .ok);
    try testing.expect(results[1].outcome == .ok);
    for (results[2..]) |r| try testing.expect(r.outcome == .unsupported);
}

test "diff scenario times 1,500-element diffs without steady-state allocation" {
    const results = try bench.run(Fake, testing.allocator, testing.io, "diff", 200);
    defer testing.allocator.free(results);
    const ok = results[0].outcome.ok;
    const st = ok.stages[@backingInt(timing.Stage.diff)].?;
    try testing.expect(st.p50_ns > 0);
    try testing.expectEqual(@as(u64, 0), st.allocations);
}

test "settling time is reported as its own stage and kept out of the total" {
    const Scenario = struct {
        pub fn step(_: *@This(), t: *timing.Timings) !void {
            t.ns[@backingInt(timing.Stage.settle)] = 40 * std.time.ns_per_ms;
            t.used[@backingInt(timing.Stage.settle)] = true;
            t.ns[@backingInt(timing.Stage.accessibility)] = std.time.ns_per_ms;
            t.used[@backingInt(timing.Stage.accessibility)] = true;
        }
    };
    var s: Scenario = .{};
    const ok = (try bench.measure(testing.allocator, testing.io, &s, 10, null)).ok;
    try testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), ok.stages[@backingInt(timing.Stage.settle)].?.p95_ns);
    try testing.expectEqual(@as(u64, std.time.ns_per_ms), ok.total.p95_ns);
}

test "application scenarios run only on request" {
    const results = try bench.run(Fake, testing.allocator, testing.io, "chrome", 1);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expect(results[0].outcome == .unsupported);
    for (bench.scenario_names) |n| for (bench.app_scenarios) |app| try testing.expect(!std.mem.eql(u8, n, app));
}

test "report lists p50, p95, p99, max and allocations per stage" {
    const results = try bench.run(Fake, testing.allocator, testing.io, "all", 20);
    defer testing.allocator.free(results);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try bench.writeReport(results, &out.writer);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), out.written(), .{});
    const scenarios = v.object.get("scenarios").?.array.items;
    const transport = scenarios[0].object;
    try testing.expectEqualStrings("ok", transport.get("status").?.string);
    const parse = transport.get("stages").?.object.get("parse").?.object;
    for ([_][]const u8{ "p50_us", "p95_us", "p99_us", "max_us", "allocations" }) |k| try testing.expect(parse.get(k) != null);
    try testing.expectEqualStrings("unsupported", scenarios[2].object.get("status").?.string);
    try testing.expect(scenarios[2].object.get("reason").?.string.len > 0);
}

fn fakeResult(name: []const u8, stage: timing.Stage, p95_us: u64) bench.Result {
    var stages: [timing.stage_count]?bench.Stats = @splat(null);
    const st: bench.Stats = .{ .p50_ns = p95_us * 900, .p95_ns = p95_us * 1000, .p99_ns = p95_us * 1000, .max_ns = p95_us * 1000, .allocations = 0 };
    stages[@backingInt(stage)] = st;
    return .{ .name = name, .outcome = .{ .ok = .{ .iterations = 10, .stages = stages, .total = st } } };
}

test "check fails above 110 % of the reference or above the absolute budget" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const baseline = "{\"reference_p95_us\":{\"capture\":{\"capture\":1000,\"total\":1000}}}";

    // 109 % passes, 111 % fails (stage and total).
    try testing.expectEqual(@as(usize, 0), try bench.check(a, baseline, &.{fakeResult("capture", .capture, 1090)}, &sink.writer));
    try testing.expectEqual(@as(usize, 2), try bench.check(a, baseline, &.{fakeResult("capture", .capture, 1110)}, &sink.writer));

    // Sub-microsecond stages: one timer tick above 110 % is not a regression.
    const tiny = "{\"reference_p95_us\":{\"capture\":{\"capture\":0.5,\"total\":0.5}}}";
    try testing.expectEqual(@as(usize, 0), try bench.check(a, tiny, &.{fakeResult("capture", .capture, 1)}, &sink.writer));
    try testing.expectEqual(@as(usize, 2), try bench.check(a, tiny, &.{fakeResult("capture", .capture, 2)}, &sink.writer));

    // snapshot budget 50 ms, screenshot 30 ms, with no reference at all.
    const empty = "{}";
    try testing.expectEqual(@as(usize, 0), try bench.check(a, empty, &.{fakeResult("snapshot", .accessibility, 49_000)}, &sink.writer));
    try testing.expectEqual(@as(usize, 1), try bench.check(a, empty, &.{fakeResult("snapshot", .accessibility, 51_000)}, &sink.writer));
    try testing.expectEqual(@as(usize, 1), try bench.check(a, empty, &.{fakeResult("screenshot", .encode, 31_000)}, &sink.writer));

    // Settling time is reported but never checked, and stays out of totals.
    const settle_ref = "{\"reference_p95_us\":{\"ui_tree\":{\"settle\":1}}}";
    try testing.expectEqual(@as(usize, 0), try bench.check(a, settle_ref, &.{fakeResult("ui_tree", .settle, 40_000)}, &sink.writer));

    // Explorer's budget is provider-bound: above 50 ms it passes within 110 %
    // of the witness probe, and fails without one.
    var explorer = fakeResult("explorer", .accessibility, 84_000);
    try testing.expectEqual(@as(usize, 1), try bench.check(a, empty, &.{explorer}, &sink.writer));
    explorer.outcome.ok.witness_p95_ns = 80_000_000;
    try testing.expectEqual(@as(usize, 0), try bench.check(a, empty, &.{explorer}, &sink.writer));
    explorer.outcome.ok.witness_p95_ns = 70_000_000;
    try testing.expectEqual(@as(usize, 1), try bench.check(a, empty, &.{explorer}, &sink.writer));
    // Absolute budgets stay absolute whatever the witness.
    var notepad = fakeResult("notepad", .accessibility, 60_000);
    notepad.outcome.ok.witness_p95_ns = 90_000_000;
    try testing.expectEqual(@as(usize, 1), try bench.check(a, empty, &.{notepad}, &sink.writer));

    // Unsupported scenarios are never checked.
    const skipped: bench.Result = .{ .name = "capture", .outcome = .{ .unsupported = "no output" } };
    try testing.expectEqual(@as(usize, 0), try bench.check(a, baseline, &.{skipped}, &sink.writer));
}

test "a baseline keeps the worst p95 of its runs" {
    var a = [_]bench.Result{fakeResult("capture", .capture, 1000)};
    bench.mergeWorstP95(&a, &.{fakeResult("capture", .capture, 1300)});
    bench.mergeWorstP95(&a, &.{fakeResult("capture", .capture, 1100)});
    try testing.expectEqual(@as(u64, 1_300_000), a[0].outcome.ok.stages[@backingInt(timing.Stage.capture)].?.p95_ns);
    try testing.expectEqual(@as(u64, 1_300_000), a[0].outcome.ok.total.p95_ns);
}
