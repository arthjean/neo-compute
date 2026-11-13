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

    // The taskbar scenarios are provider-relative (decision 0010): a
    // provider stage above 110 % of its reference passes within 110 % of the
    // witness probe, fails above it or without one, and the other stages
    // stay strict.
    const taskbar = "{\"reference_p95_us\":{\"snapshot\":{\"accessibility\":24000,\"total\":24000},\"ui_tree\":{\"diff\":2,\"dispatch\":30000,\"total\":30000}}}";
    var snap = fakeResult("snapshot", .accessibility, 32_000);
    try testing.expectEqual(@as(usize, 2), try bench.check(a, taskbar, &.{snap}, &sink.writer));
    snap.outcome.ok.witness_p95_ns = 30_000_000;
    try testing.expectEqual(@as(usize, 0), try bench.check(a, taskbar, &.{snap}, &sink.writer));
    snap.outcome.ok.witness_p95_ns = 28_000_000;
    try testing.expectEqual(@as(usize, 2), try bench.check(a, taskbar, &.{snap}, &sink.writer));
    var tree_diff = fakeResult("ui_tree", .diff, 5);
    tree_diff.outcome.ok.witness_p95_ns = 30_000_000;
    try testing.expectEqual(@as(usize, 1), try bench.check(a, taskbar, &.{tree_diff}, &sink.writer));
    // The absolute 50 ms budget stays absolute.
    var slow = fakeResult("snapshot", .accessibility, 52_000);
    slow.outcome.ok.witness_p95_ns = 60_000_000;
    try testing.expectEqual(@as(usize, 1), try bench.check(a, taskbar, &.{slow}, &sink.writer));
    // Other scenarios ignore a witness against their reference.
    var cap = fakeResult("capture", .capture, 1110);
    cap.outcome.ok.witness_p95_ns = 10_000_000;
    try testing.expectEqual(@as(usize, 2), try bench.check(a, baseline, &.{cap}, &sink.writer));

    // Unsupported scenarios are never checked.
    const skipped: bench.Result = .{ .name = "capture", .outcome = .{ .unsupported = "no output" } };
    try testing.expectEqual(@as(usize, 0), try bench.check(a, baseline, &.{skipped}, &sink.writer));
}

test "a baseline keeps the worst p95 and p50 of its runs, and the p95 of each" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const passes = [_][]const bench.Result{
        &.{fakeResult("capture", .capture, 1000)},
        &.{fakeResult("capture", .capture, 1300)},
        &.{fakeResult("capture", .capture, 1100)},
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try bench.writeBaseline(&passes, &out.writer);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
    const stage = struct {
        fn of(root: std.json.Value, section: []const u8, name: []const u8) std.json.Value {
            return root.object.get(section).?.object.get("capture").?.object.get(name).?;
        }
    }.of;
    try testing.expectEqual(@as(i64, 1300), stage(v, "reference_p95_us", "capture").integer);
    try testing.expectEqual(@as(i64, 1300), stage(v, "reference_p95_us", "total").integer);
    // fakeResult's p50 is 90 % of its p95.
    try testing.expectEqual(@as(i64, 1170), stage(v, "reference_p50_us", "capture").integer);
    const each = stage(v, "passes_p95_us", "total").array.items;
    try testing.expectEqual(@as(usize, 3), each.len);
    try testing.expectEqual(@as(i64, 1000), each[0].integer);
    try testing.expectEqual(@as(i64, 1100), each[2].integer);
}

test "a noisy tail is held to the limit of its own noise, the median to 110 %" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink: std.Io.Writer.Allocating = .init(a);

    // The upper fence: Q3 + 1.5 times the interquartile range.
    var five = [_]f64{ 2880, 2355, 2765, 2750, 2644 };
    try testing.expectEqual(@as(f64, 2765 + 1.5 * (2765 - 2644)), bench.fence(&five).?);
    var three = [_]f64{ 1, 2, 3 };
    try testing.expectEqual(@as(?f64, null), bench.fence(&three));

    // bg-act as measured (decision 0013): reference 2 549 us, passes that
    // spread over 22 %. 2 846 us is above 110 % of the reference and within
    // the noise limit (2 946.5 us); 3 000 us is above both.
    const noisy = "{\"reference_p95_us\":{\"bg-act\":{\"total\":2549}},\"passes_p95_us\":{\"bg-act\":{\"total\":[2880,2355,2765,2750,2644]}}}";
    var r = fakeResult("bg-act", .accessibility, 2846);
    try testing.expectEqual(@as(usize, 0), try bench.check(a, noisy, &.{r}, &sink.writer));
    try testing.expect(std.mem.indexOf(u8, sink.written(), "bg-act.total p95 2846.0 us exceeds 110 % of its 2549.0 us reference, within the 2946.5 us limit of its own noise") != null);
    r = fakeResult("bg-act", .accessibility, 3000);
    try testing.expectEqual(@as(usize, 1), try bench.check(a, noisy, &.{r}, &sink.writer));
    // Without its passes, or with too few, the 110 % rule alone decides.
    r = fakeResult("bg-act", .accessibility, 2846);
    try testing.expectEqual(@as(usize, 1), try bench.check(a, "{\"reference_p95_us\":{\"bg-act\":{\"total\":2549}}}", &.{r}, &sink.writer));
    try testing.expectEqual(@as(usize, 1), try bench.check(a, "{\"reference_p95_us\":{\"bg-act\":{\"total\":2549}},\"passes_p95_us\":{\"bg-act\":{\"total\":[2880,2355,2765]}}}", &.{r}, &sink.writer));

    // The median: 110 % of its reference, whatever the tail's noise.
    const median = "{\"reference_p50_us\":{\"bg-act\":{\"total\":1800}},\"passes_p95_us\":{\"bg-act\":{\"total\":[2880,2355,2765,2750,2644]}}}";
    r = fakeResult("bg-act", .accessibility, 2000); // p50 1 800
    try testing.expectEqual(@as(usize, 0), try bench.check(a, median, &.{r}, &sink.writer));
    r = fakeResult("bg-act", .accessibility, 2300); // p50 2 070: 115 %
    sink.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 1), try bench.check(a, median, &.{r}, &sink.writer));
    try testing.expect(std.mem.indexOf(u8, sink.written(), "bg-act.total p50 2070.0 us exceeds 110 % of its 1800.0 us median reference") != null);

    // A provider stage of a provider-relative scenario follows its witness
    // probe, never the passes of a slow day.
    const taskbar = "{\"reference_p95_us\":{\"snapshot\":{\"accessibility\":24000}},\"passes_p95_us\":{\"snapshot\":{\"accessibility\":[42000,41000,43000,42500,41500]}}}";
    var snap = fakeResult("snapshot", .accessibility, 40_000);
    try testing.expectEqual(@as(usize, 1), try bench.check(a, taskbar, &.{snap}, &sink.writer));
    snap.outcome.ok.witness_p95_ns = 39_000_000;
    try testing.expectEqual(@as(usize, 0), try bench.check(a, taskbar, &.{snap}, &sink.writer));
}

test "the marks budget is 8 ms over the screenshot of the same run, else over its absolute budget" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink: std.Io.Writer.Allocating = .init(a);
    const empty = "{\"reference_p95_us\":{}}";
    // Screenshot at 20 ms in the run: marks passes at 27.9 ms, fails at 28.1.
    try testing.expectEqual(@as(usize, 0), try bench.check(a, empty, &.{ fakeResult("screenshot", .encode, 20_000), fakeResult("marks", .encode, 27_900) }, &sink.writer));
    try testing.expectEqual(@as(usize, 1), try bench.check(a, empty, &.{ fakeResult("screenshot", .encode, 20_000), fakeResult("marks", .encode, 28_100) }, &sink.writer));
    try testing.expect(std.mem.indexOf(u8, sink.written(), "marks total p95 28.10 ms exceeds screenshot p95 (with its witness) 20.00 ms + 8 ms") != null);
    // marks alone: the screenshot's 30 ms budget plus 8.
    try testing.expectEqual(@as(usize, 0), try bench.check(a, empty, &.{fakeResult("marks", .encode, 37_000)}, &sink.writer));
    try testing.expectEqual(@as(usize, 1), try bench.check(a, empty, &.{fakeResult("marks", .encode, 39_000)}, &sink.writer));
    // With its witness (ui_tree without marks on the same window, 10 ms),
    // marks is budgeted on what it adds: 20 + 10 + 8 ms.
    var with_tree = fakeResult("marks", .encode, 37_900);
    with_tree.outcome.ok.witness_p95_ns = 10 * std.time.ns_per_ms;
    try testing.expectEqual(@as(usize, 0), try bench.check(a, empty, &.{ fakeResult("screenshot", .encode, 20_000), with_tree }, &sink.writer));
    with_tree.outcome.ok.total.p95_ns = 38_100 * std.time.ns_per_us;
    try testing.expectEqual(@as(usize, 1), try bench.check(a, empty, &.{ fakeResult("screenshot", .encode, 20_000), with_tree }, &sink.writer));
}

test "the background scenarios are budgeted: bg-act on its total, bg-settle on its settle stage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try bench.check(a, "{}", &.{fakeResult("bg-act", .accessibility, 19_000)}, &sink.writer));
    try testing.expectEqual(@as(usize, 1), try bench.check(a, "{}", &.{fakeResult("bg-act", .accessibility, 21_000)}, &sink.writer));
    // The one scenario whose settling is held to a budget (US-048).
    try testing.expectEqual(@as(usize, 0), try bench.check(a, "{}", &.{fakeResult("bg-settle", .settle, 149_000)}, &sink.writer));
    try testing.expectEqual(@as(usize, 1), try bench.check(a, "{}", &.{fakeResult("bg-settle", .settle, 151_000)}, &sink.writer));
    // A series that never settled has nothing to hold against the budget.
    try testing.expectEqual(@as(usize, 1), try bench.check(a, "{}", &.{fakeResult("bg-settle", .accessibility, 30_000)}, &sink.writer));
    // Its reference still never checks the settle stage, as for the others.
    // bg-capture: the window capture's total (US-061).
    try testing.expectEqual(@as(usize, 0), try bench.check(a, "{}", &.{fakeResult("bg-capture", .capture, 59_000)}, &sink.writer));
    try testing.expectEqual(@as(usize, 1), try bench.check(a, "{}", &.{fakeResult("bg-capture", .capture, 61_000)}, &sink.writer));
    const ref = "{\"reference_p95_us\":{\"bg-settle\":{\"settle\":1}}}";
    try testing.expectEqual(@as(usize, 0), try bench.check(a, ref, &.{fakeResult("bg-settle", .settle, 100_000)}, &sink.writer));
}
