const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this string");
    const fake_backend = b.option(bool, "fake-backend", "Build the server on the fake backend of the tests, for any target") orelse false;
    const os = target.result.os.tag;
    // A target without a backend fails here rather than building a server
    // that drives no desktop (US-068).
    if (!fake_backend and os != .windows and os != .linux)
        std.process.fatal("Aucun backend pour {t} : neo-compute se construit pour windows et linux, ou avec -Dfake-backend=true pour les tests.", .{os});
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    var win32: Win32 = .{ .b = b };
    b.step("bindings", "Generate the Win32/COM bindings").dependOn(win32.gen().step);

    const exe = addServer(b, &win32, target, optimize, fake_backend);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run neo-compute").dependOn(&run.step);

    // Unit and integration tests of the portable core against the fake
    // backend: the `core` module with the `fake` module, which imports it
    // back.
    const core_test = coreModule(b, target, optimize, buildOptions(b, true).createModule());
    core_test.addImport("fake", fakeModule(b, target, optimize, core_test, textsModules(b, target, optimize, core_test)));
    core_test.addAnonymousImport("toolset_fixture", .{ .root_source_file = b.path("tests/fixtures/toolset_20260801.json") });
    // `tools/list` of the a11y and vision modes as it was before the
    // background mode (US-041): neither may change.
    core_test.addAnonymousImport("tools_list_a11y", .{ .root_source_file = b.path("tests/fixtures/tools_list_a11y.json") });
    core_test.addAnonymousImport("tools_list_vision", .{ .root_source_file = b.path("tests/fixtures/tools_list_vision.json") });
    // initialize and tools/list of the Windows server before US-071.
    core_test.addAnonymousImport("windows_texts", .{ .root_source_file = b.path("tests/fixtures/windows_texts.json") });
    core_test.addAnonymousImport("baseline_windows", .{ .root_source_file = b.path("bench/baseline.json") });
    core_test.addAnonymousImport("baseline_linux", .{ .root_source_file = b.path("bench/baseline-linux.json") });
    const tests = b.addTest(.{ .root_module = core_test, .filters = filters });
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The registry must refuse oversized definitions at compile time.
    const registry_mod = b.createModule(.{ .root_source_file = b.path("src/core/registry.zig"), .target = target, .optimize = optimize });
    registry_mod.addOptions("build_options", buildOptions(b, true));
    for ([_][2][]const u8{
        .{ "tests/compile_errors/long_description.zig", "description is 301 characters, limit is 300" },
        .{ "tests/compile_errors/definition_budget.zig", "tokens, limit is 4500" },
        .{ "tests/compile_errors/always_load_budget.zig", "tokens with always-loaded tool `tool_9`, limit is 1500" },
        .{ "tests/compile_errors/background_intrusion.zig", "tool `click` is listed in the background mode but its intrusion class is `input`: only `none` tools may be listed" },
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

    // The module boundaries (US-069): src/core/ imports no file of
    // src/backend/, and neither OS backend imports the other.
    const imports_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/imports_test.zig"), .target = b.graph.host, .optimize = .Debug }),
        .filters = filters,
    });
    const imports_run = b.addRunArtifact(imports_tests);
    imports_run.setCwd(b.path("."));
    imports_run.has_side_effects = true;
    test_step.dependOn(&imports_run.step);

    // A name absent from the metadata fails generation and names the closest one.
    const missing = b.addRunArtifact(win32.gen().generator);
    missing.addFileArg(b.path("tests/fixtures/missing_api.zon"));
    missing.addFileArg(win32.gen().nupkg);
    _ = missing.addOutputFileArg("unused.zig");
    missing.expectExitCode(1);
    missing.expectStdErrMatch("`CoInitializeExx` not found in Windows.Win32.winmd; closest existing name: `CoInitializeEx`");
    test_step.dependOn(&missing.step);

    // Lifecycle checks against the real binary (startup and EOF exit times).
    const test_options = b.addOptions();
    test_options.addOptionPath("server_exe", exe.getEmittedBin());
    // The server on the fake backend, which logs its inputs on stderr
    // (US-072: release on a stop signal).
    test_options.addOptionPath("fake_server_exe", addServer(b, &win32, target, optimize, true).getEmittedBin());
    const process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/process_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = filters,
    });
    process_tests.root_module.addOptions("test_options", test_options);
    process_tests.root_module.addAnonymousImport("toolset_fixture", .{ .root_source_file = b.path("tests/fixtures/toolset_20260801.json") });
    const process_run = b.addRunArtifact(process_tests);
    process_run.has_side_effects = true;
    test_step.dependOn(&process_run.step);

    if (os == .linux and !fake_backend) {
        // The Linux backend's own tests (window handles, US-071).
        const linux_tests = b.addTest(.{ .root_module = serverModule(b, &win32, target, optimize, false).import_table.get("backend_linux").?, .filters = filters });
        test_step.dependOn(&b.addRunArtifact(linux_tests).step);
    }

    if (os == .windows) {
        // The generated bindings compile and link in full.
        const bindings_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/bindings_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "win32", .module = win32.module(target, optimize) }},
            }),
            .filters = filters,
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
                .imports = &.{.{ .name = "win32", .module = win32.module(target, optimize) }},
            }),
            .filters = filters,
        });
        layout_tests.root_module.addAnonymousImport("layout_c", .{ .root_source_file = layout_ref });
        test_step.dependOn(&b.addRunArtifact(layout_tests).step);

        // The import tables of the shipped PE image.
        const pe_tests = b.addTest(.{
            .root_module = b.createModule(.{ .root_source_file = b.path("tests/pe_test.zig"), .target = target, .optimize = optimize }),
            .filters = filters,
        });
        pe_tests.root_module.addOptions("test_options", test_options);
        const pe_run = b.addRunArtifact(pe_tests);
        pe_run.has_side_effects = true;
        test_step.dependOn(&pe_run.step);
    }

    // The server of the other OS compiles (US-069): from Linux the Windows
    // server and its probes, from Windows the Linux server for both
    // architectures at the glibc 2.28 floor (decision 0014, P7). Installed
    // under zig-out/cross/<triple>/.
    const cross = b.step("cross", "Compile the server of the other OS (Windows from Linux, Linux x86_64 and aarch64 from Windows)");
    const glibc: std.SemanticVersion = .{ .major = 2, .minor = 28, .patch = 0 };
    const cross_queries: []const std.Target.Query = if (os == .windows) &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = glibc },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu, .glibc_version = glibc },
    } else &.{
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    };
    for (cross_queries) |q| {
        const other = b.resolveTargetQuery(q);
        const dir: std.Build.InstallDir = .{ .custom = b.fmt("cross/{t}-{t}-{t}", .{ other.result.cpu.arch, other.result.os.tag, other.result.abi }) };
        var artifacts: [3]*std.Build.Step.Compile = undefined;
        var count: usize = 0;
        artifacts[count] = addServer(b, &win32, other, optimize, false);
        count += 1;
        if (q.os_tag == .windows) {
            const probes = addProbes(b, other, optimize, win32.module(other, optimize));
            artifacts[count] = probes[0];
            artifacts[count + 1] = probes[1];
            count += 2;
        }
        for (artifacts[0..count]) |art|
            cross.dependOn(&b.addInstallArtifact(art, .{ .dest_dir = .{ .override = dir } }).step);
    }

    // Bench on an optimized build: `zig build bench -- --check bench/baseline.json`.
    const bench_exe = addServer(b, &win32, target, .ReleaseFast, fake_backend);
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.addArgs(&.{ "bench", "all" });
    bench_run.addPassthruArgs();
    bench_run.has_side_effects = true;
    // The explorer scenario runs the C witness probe from zig-out/bin.
    if (os == .windows) bench_run.step.dependOn(b.getInstallStep());
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

    // The US-001 probes exist for a Windows target only.
    if (os == .windows) {
        const probes = addProbes(b, target, optimize, win32.module(target, optimize));
        const probe_run = b.addRunArtifact(probes[0]);
        probe_run.addPassthruArgs();
        b.step("probe", "Run the US-001 COM probe").dependOn(&probe_run.step);
        const probe_c_run = b.addRunArtifact(probes[1]);
        probe_c_run.addPassthruArgs();
        b.step("probe-c", "Run the US-001 C witness probe").dependOn(&probe_c_run.step);
        for (probes) |p| b.installArtifact(p);
    }
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

/// The portable core (src/core/, root `core.zig`) with the C libraries it
/// links. A module may import no file outside its own directory, so the
/// compiler itself keeps src/core/ out of src/backend/.
fn coreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, options: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("build_options", options);
    addJpeg(b, mod, target);
    addPixelHash(b, mod, target);
    return mod;
}

/// The texts of each OS (decision 0014, D7): `texts_windows`
/// (src/backend/windows/texts.zig) and `texts_linux`
/// (src/backend/linux/texts.zig), modules of their own so the fake backend
/// can read both while each file stays in one module.
const Texts = struct { windows: *std.Build.Module, linux: *std.Build.Module };

fn textsModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, core: *std.Build.Module) Texts {
    var out: Texts = undefined;
    inline for (.{ "windows", "linux" }) |os| @field(out, os) = b.createModule(.{
        .root_source_file = b.path("src/backend/" ++ os ++ "/texts.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });
    return out;
}

/// The fake backend (src/backend/fake.zig), the executable specification
/// of the backend contract, on `core`; it speaks with the Windows texts and
/// carries the Linux ones for their compile-time checks.
fn fakeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, core: *std.Build.Module, texts: Texts) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/backend/fake.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "texts_windows", .module = texts.windows },
            .{ .name = "texts_linux", .module = texts.linux },
        },
    });
}

/// The server: src/main.zig on `core`, `fake` (the transport bench and
/// `-Dfake-backend`) and the backend module of the target's OS,
/// `backend_windows` (src/backend/windows.zig and windows/, with the
/// generated bindings) or `backend_linux` (src/backend/linux.zig and
/// linux/).
fn serverModule(b: *std.Build, win32: *Win32, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, fake_backend: bool) *std.Build.Module {
    // One module for both: a file belongs to one module only.
    const options = buildOptions(b, fake_backend).createModule();
    const core = coreModule(b, target, optimize, options);
    const texts = textsModules(b, target, optimize, core);
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "fake", .module = fakeModule(b, target, optimize, core, texts) },
        },
    });
    mod.addImport("build_options", options);
    if (!fake_backend) switch (target.result.os.tag) {
        .windows => mod.addImport("backend_windows", b.createModule(.{
            .root_source_file = b.path("src/backend/windows.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "texts_windows", .module = texts.windows },
                .{ .name = "win32", .module = win32.module(target, optimize) },
            },
        })),
        .linux => mod.addImport("backend_linux", b.createModule(.{
            .root_source_file = b.path("src/backend/linux.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "texts_linux", .module = texts.linux },
            },
        })),
        else => unreachable,
    };
    return mod;
}

/// The fingerprint hash of src/core/pixel_hash.zig as a static library,
/// always optimized like libjpeg: in a Debug server a maximized window's
/// fingerprint cost 11.5 ms per GDI look (US-032). A separate artifact,
/// because a module's own `optimize` does not change how the Zig code of
/// one compilation is optimized.
fn addPixelHash(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const lib = b.addLibrary(.{
        .name = "neo_pixel_hash",
        .linkage = .static,
        .root_module = b.createModule(.{ .root_source_file = b.path("src/core/pixel_hash.zig"), .target = target, .optimize = .ReleaseFast }),
    });
    mod.linkLibrary(lib);
}

/// libjpeg-turbo (pinned in build.zig.zon) plus the C shim of
/// src/core/jpeg, as a static library, and the shim's header through
/// translate-c. The C code is always optimized: a Debug libjpeg is ten
/// times slower and trips UBSan on its documented shifts.
fn addJpeg(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const upstream = b.dependency("libjpeg_turbo", .{});
    const version = "3.1.4.1";
    // The fetch strips the archive's single top-level directory, so the
    // package root is the source tree itself on every host.
    const src = upstream.path("src");
    const jconfig = b.addConfigHeader(.{ .style = .{ .cmake = src.path(b, "jconfig.h.in") }, .include_path = "jconfig.h" }, .{
        .JPEG_LIB_VERSION = 62,
        .VERSION = version,
        .LIBJPEG_TURBO_VERSION_NUMBER = 3001004,
        .C_ARITH_CODING_SUPPORTED = null,
        .D_ARITH_CODING_SUPPORTED = null,
        .WITH_SIMD = null,
        .RIGHT_SHIFT_IS_UNSIGNED = null,
    });
    const jconfigint = b.addConfigHeader(.{ .style = .{ .cmake = src.path(b, "jconfigint.h.in") }, .include_path = "jconfigint.h" }, .{
        .BUILD = "neo-compute",
        .CMAKE_PROJECT_NAME = "libjpeg-turbo",
        .VERSION = version,
        .SIZE_T = @as(i64, @intCast(target.result.ptrBitWidth() / 8)),
        .HAVE_BUILTIN_CTZL = true,
        .HAVE_INTRIN_H = null,
        .C_ARITH_CODING_SUPPORTED = null,
        .D_ARITH_CODING_SUPPORTED = null,
        .WITH_SIMD = null,
    });
    jconfigint.addIdent("HIDDEN", "__attribute__((visibility(\"hidden\")))");
    jconfigint.addIdent("INLINE", "__inline__ __attribute__((always_inline))");
    jconfigint.addIdent("THREAD_LOCAL", "_Thread_local");
    const jversion = b.addConfigHeader(.{ .style = .{ .cmake = src.path(b, "jversion.h.in") }, .include_path = "jversion.h" }, .{
        .COPYRIGHT_YEAR = "1991-2026",
    });

    const lib = b.addLibrary(.{
        .name = "jpeg",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
    });
    lib.root_module.addConfigHeader(jconfig);
    lib.root_module.addConfigHeader(jconfigint);
    lib.root_module.addConfigHeader(jversion);
    lib.root_module.addIncludePath(src);
    lib.root_module.addCSourceFiles(.{ .root = src, .files = jpeg_sources, .flags = &.{"-std=gnu11"} });
    lib.root_module.addCSourceFile(.{ .file = b.path("src/core/jpeg/neo_jpeg.c"), .flags = &.{"-std=gnu11"} });
    mod.linkLibrary(lib);

    const header = b.addTranslateC(.{ .root_source_file = b.path("src/core/jpeg/neo_jpeg.h"), .target = target, .optimize = .ReleaseFast });
    mod.addImport("neo_jpeg", header.createModule());
}

/// JPEG_SOURCES of libjpeg-turbo's CMakeLists.txt, without arithmetic coding.
const jpeg_sources: []const []const u8 = &.{
    "jcapimin.c",            "wrapper/jcapistd-8.c",  "wrapper/jcapistd-12.c", "wrapper/jcapistd-16.c",
    "wrapper/jccoefct-8.c",  "wrapper/jccoefct-12.c", "wrapper/jccolor-8.c",   "wrapper/jccolor-12.c",
    "wrapper/jccolor-16.c",  "wrapper/jcdctmgr-8.c",  "wrapper/jcdctmgr-12.c", "wrapper/jcdiffct-8.c",
    "wrapper/jcdiffct-12.c", "wrapper/jcdiffct-16.c", "jchuff.c",              "jcicc.c",
    "jcinit.c",              "jclhuff.c",             "wrapper/jclossls-8.c",  "wrapper/jclossls-12.c",
    "wrapper/jclossls-16.c", "wrapper/jcmainct-8.c",  "wrapper/jcmainct-12.c", "wrapper/jcmainct-16.c",
    "jcmarker.c",            "jcmaster.c",            "jcomapi.c",             "jcparam.c",
    "jcphuff.c",             "wrapper/jcprepct-8.c",  "wrapper/jcprepct-12.c", "wrapper/jcprepct-16.c",
    "wrapper/jcsample-8.c",  "wrapper/jcsample-12.c", "wrapper/jcsample-16.c", "jctrans.c",
    "jdapimin.c",            "wrapper/jdapistd-8.c",  "wrapper/jdapistd-12.c", "wrapper/jdapistd-16.c",
    "jdatadst.c",            "jdatasrc.c",            "wrapper/jdcoefct-8.c",  "wrapper/jdcoefct-12.c",
    "wrapper/jdcolor-8.c",   "wrapper/jdcolor-12.c",  "wrapper/jdcolor-16.c",  "wrapper/jddctmgr-8.c",
    "wrapper/jddctmgr-12.c", "wrapper/jddiffct-8.c",  "wrapper/jddiffct-12.c", "wrapper/jddiffct-16.c",
    "jdhuff.c",              "jdicc.c",               "jdinput.c",             "jdlhuff.c",
    "wrapper/jdlossls-8.c",  "wrapper/jdlossls-12.c", "wrapper/jdlossls-16.c", "wrapper/jdmainct-8.c",
    "wrapper/jdmainct-12.c", "wrapper/jdmainct-16.c", "jdmarker.c",            "jdmaster.c",
    "wrapper/jdmerge-8.c",   "wrapper/jdmerge-12.c",  "jdphuff.c",             "wrapper/jdpostct-8.c",
    "wrapper/jdpostct-12.c", "wrapper/jdpostct-16.c", "wrapper/jdsample-8.c",  "wrapper/jdsample-12.c",
    "wrapper/jdsample-16.c", "jdtrans.c",             "jerror.c",              "jfdctflt.c",
    "wrapper/jfdctfst-8.c",  "wrapper/jfdctfst-12.c", "wrapper/jfdctint-8.c",  "wrapper/jfdctint-12.c",
    "wrapper/jidctflt-8.c",  "wrapper/jidctflt-12.c", "wrapper/jidctfst-8.c",  "wrapper/jidctfst-12.c",
    "wrapper/jidctint-8.c",  "wrapper/jidctint-12.c", "wrapper/jidctred-8.c",  "wrapper/jidctred-12.c",
    "jmemmgr.c",             "jmemnobs.c",            "jpeg_nbits.c",          "wrapper/jquant1-8.c",
    "wrapper/jquant1-12.c",  "wrapper/jquant2-8.c",   "wrapper/jquant2-12.c",  "wrapper/jutils-8.c",
    "wrapper/jutils-12.c",   "wrapper/jutils-16.c",
};

fn addServer(b: *std.Build, win32: *Win32, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, fake_backend: bool) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "neo-compute",
        .root_module = serverModule(b, win32, target, optimize, fake_backend),
    });
}

/// The US-001 probes, `probe` (generated bindings) and `probe_c` (the C
/// witness), for a Windows target.
fn addProbes(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, win32: *std.Build.Module) [2]*std.Build.Step.Compile {
    const probe = b.addExecutable(.{
        .name = "probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("probe/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "win", .module = win32 }},
        }),
    });
    const probe_c = b.addExecutable(.{
        .name = "probe_c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    probe_c.root_module.addCSourceFile(.{ .file = b.path("probe/probe_c.c"), .flags = &.{"-std=c11"} });
    for ([_][]const u8{ "ole32", "oleaut32", "user32" }) |lib|
        probe_c.root_module.linkSystemLibrary(lib, .{});
    return .{ probe, probe_c };
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

/// win32.zig, generated from bindings/windows.zon and the pinned
/// win32metadata package on first use: a build that needs no Windows code
/// downloads nothing. The run step is cached on its inputs, and each
/// target and mode gets its own module of the one generated file.
const Win32 = struct {
    b: *std.Build,
    generated: ?Generated = null,

    const Generated = struct {
        out: std.Build.LazyPath,
        step: *std.Build.Step,
        generator: *std.Build.Step.Compile,
        nupkg: std.Build.LazyPath,
    };

    fn gen(self: *Win32) Generated {
        if (self.generated) |g| return g;
        const b = self.b;
        const generator = b.addExecutable(.{
            .name = "winmdgen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/winmdgen/main.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
            }),
        });
        const nupkg = fetchNupkg(b);
        const run = b.addRunArtifact(generator);
        run.addFileArg(b.path("bindings/windows.zon"));
        run.addFileArg(nupkg);
        const out = run.addOutputFileArg("win32.zig");
        self.generated = .{ .out = out, .step = &run.step, .generator = generator, .nupkg = nupkg };
        return self.generated.?;
    }

    fn module(self: *Win32, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
        return self.b.createModule(.{ .root_source_file = self.gen().out, .target = target, .optimize = optimize });
    }
};
