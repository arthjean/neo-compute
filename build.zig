const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this string");

    const nupkg = fetchNupkg(b);
    const win32 = addBindings(b, target, optimize, nupkg);
    b.step("bindings", "Generate the Win32/COM bindings").dependOn(win32.step);

    const exe = addServer(b, target, optimize, false, win32.module);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run neo-compute").dependOn(&run.step);

    // Unit and integration tests of the portable core against the fake backend.
    const tests = b.addTest(.{
        .root_module = serverModule(b, target, optimize, true, null),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    tests.root_module.addAnonymousImport("toolset_fixture", .{ .root_source_file = b.path("tests/fixtures/toolset_20260801.json") });
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The registry must refuse oversized definitions at compile time.
    const registry_mod = b.createModule(.{ .root_source_file = b.path("src/core/registry.zig"), .target = target, .optimize = optimize });
    registry_mod.addOptions("build_options", buildOptions(b, true));
    for ([_][2][]const u8{
        .{ "tests/compile_errors/long_description.zig", "description is 301 characters, limit is 300" },
        .{ "tests/compile_errors/definition_budget.zig", "tokens, limit is 3000" },
    }) |case| {
        const bad = b.addObject(.{
            .name = std.fs.path.stem(case[0]),
            .root_module = b.createModule(.{
                .root_source_file = b.path(case[0]),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "registry", .module = registry_mod }},
            }),
        });
        bad.expect_errors = .{ .contains = case[1] };
        test_step.dependOn(&bad.step);
    }

    // The generated bindings compile and link in full.
    const bindings_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bindings_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "win32", .module = win32.module }},
        }),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(bindings_tests).step);

    // Struct layouts against the C compiler's sizeof/offsetof on mingw-w64.
    const layout_c = b.addExecutable(.{
        .name = "layout_c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    layout_c.root_module.addCSourceFile(.{ .file = b.path("tests/layout/layout.c"), .flags = &.{"-std=c11"} });
    const layout_ref = b.addRunArtifact(layout_c).captureStdOut(.{});
    const layout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/layout_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "win32", .module = win32.module }},
        }),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    layout_tests.root_module.addAnonymousImport("layout_c", .{ .root_source_file = layout_ref });
    test_step.dependOn(&b.addRunArtifact(layout_tests).step);

    // A name absent from the metadata fails generation and names the closest one.
    const missing = b.addRunArtifact(win32.generator);
    missing.addFileArg(b.path("tests/fixtures/missing_api.zon"));
    missing.addFileArg(nupkg);
    _ = missing.addOutputFileArg("unused.zig");
    missing.expectExitCode(1);
    missing.expectStdErrMatch("`CoInitializeExx` not found in Windows.Win32.winmd; closest existing name: `CoInitializeEx`");
    test_step.dependOn(&missing.step);

    // Lifecycle checks against the real binary (startup and EOF exit times).
    const test_options = b.addOptions();
    test_options.addOptionPath("server_exe", exe.getEmittedBin());
    const process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/process_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    process_tests.root_module.addOptions("test_options", test_options);
    const process_run = b.addRunArtifact(process_tests);
    process_run.has_side_effects = true;
    test_step.dependOn(&process_run.step);

    // The core must stay free of Windows dependencies: build it for Linux
    // with the fake backend.
    const cross = addServer(b, b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }), optimize, true, null);
    b.step("cross", "Compile the core with the fake backend for x86_64-linux-gnu").dependOn(&cross.step);

    // Bench on an optimized build: `zig build bench -- --check bench/baseline.json`.
    const bench_win32 = addBindings(b, target, .ReleaseFast, nupkg).module;
    const bench_exe = addServer(b, target, .ReleaseFast, false, bench_win32);
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.addArgs(&.{ "bench", "all" });
    bench_run.addPassthruArgs();
    bench_run.has_side_effects = true;
    b.step("bench", "Run the benchmark scenarios (ReleaseFast)").dependOn(&bench_run.step);

    // Developer-only: measures the bytes/token ratio through Claude Code
    // (`claude -p`, subscription auth). Never part of the server.
    const calibrate = b.addRunArtifact(b.addExecutable(.{
        .name = "calibrate_tokens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/calibrate_tokens.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    }));
    calibrate.setCwd(b.path("."));
    calibrate.addArg("bench/token_calibration.json");
    calibrate.addFileArg(b.path("tests/fixtures/toolset_20260801.json"));
    calibrate.has_side_effects = true;
    b.step("calibrate-tokens", "Calibrate text bytes/token through Claude Code (claude -p)").dependOn(&calibrate.step);

    addProbes(b, target, optimize, win32.module);
}

fn buildOptions(b: *std.Build, fake_backend: bool) *std.Build.Step.Options {
    const opts = b.addOptions();
    opts.addOption(bool, "fake_backend", fake_backend);
    opts.addOption(f64, "text_bytes_per_token", readTokenRatio(b));
    return opts;
}

/// Reads the calibrated bytes/token ratio from bench/token_calibration.json.
fn readTokenRatio(b: *std.Build) f64 {
    const path = "bench/token_calibration.json";
    b.dependOnFileContents(b.path(path));
    const bytes = b.root.root_dir.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(64 * 1024)) catch |err|
        std.debug.panic("cannot read {s}: {t}", .{ path, err });
    const Calibration = struct { text_bytes_per_token: f64 };
    const parsed = std.json.parseFromSliceLeaky(Calibration, b.allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err|
        std.debug.panic("invalid {s}: {t}", .{ path, err });
    return parsed.text_bytes_per_token;
}

/// `win32` is the generated bindings module, required by the Windows backend
/// and absent from fake-backend builds.
fn serverModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, fake_backend: bool, win32: ?*std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", buildOptions(b, fake_backend));
    if (win32) |m| mod.addImport("win32", m);
    return mod;
}

fn addServer(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, fake_backend: bool, win32: ?*std.Build.Module) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "neo-compute",
        .root_module = serverModule(b, target, optimize, fake_backend, win32),
    });
}

fn addProbes(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, win32: *std.Build.Module) void {
    const probe = b.addExecutable(.{
        .name = "probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("probe/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "win", .module = win32 }},
        }),
    });
    const probe_run = b.addRunArtifact(probe);
    probe_run.addPassthruArgs();
    b.step("probe", "Run the US-001 COM probe").dependOn(&probe_run.step);
    b.installArtifact(probe);

    const probe_c = b.addExecutable(.{
        .name = "probe_c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    probe_c.root_module.addCSourceFile(.{ .file = b.path("probe/probe_c.c"), .flags = &.{"-std=c11"} });
    for ([_][]const u8{ "ole32", "oleaut32", "user32" }) |lib|
        probe_c.root_module.linkSystemLibrary(lib, .{});
    const probe_c_run = b.addRunArtifact(probe_c);
    probe_c_run.addPassthruArgs();
    b.step("probe-c", "Run the US-001 C witness probe").dependOn(&probe_c_run.step);
    b.installArtifact(probe_c);
}

/// The pinned win32metadata package, downloaded once into the build cache
/// (the step is cached on its arguments). It ships under the Windows SDK
/// license, so it is not redistributed with the sources; winmdgen checks its
/// SHA-256 against bindings/windows.zon before reading it. `zig fetch` cannot
/// be used: NuGet serves it as application/octet-stream with a `.nupkg` name.
const nupkg_url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.win32metadata/71.0.37-preview/microsoft.windows.sdk.win32metadata.71.0.37-preview.nupkg";

fn fetchNupkg(b: *std.Build) std.Build.LazyPath {
    const curl = b.addSystemCommand(&.{ "curl", "--fail", "--silent", "--show-error", "--location", "--output" });
    const out = curl.addOutputFileArg("win32metadata.nupkg");
    curl.addArg(nupkg_url);
    return out;
}

/// Generates win32.zig from bindings/windows.zon and the pinned
/// win32metadata package. The run step is cached on its inputs.
fn addBindings(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, nupkg: std.Build.LazyPath) struct { module: *std.Build.Module, step: *std.Build.Step, generator: *std.Build.Step.Compile } {
    const gen = b.addExecutable(.{
        .name = "winmdgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/winmdgen/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    const run = b.addRunArtifact(gen);
    run.addFileArg(b.path("bindings/windows.zon"));
    run.addFileArg(nupkg);
    const out = run.addOutputFileArg("win32.zig");
    const module = b.createModule(.{ .root_source_file = out, .target = target, .optimize = optimize });
    return .{ .module = module, .step = &run.step, .generator = gen };
}
