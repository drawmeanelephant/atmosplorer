const std = @import("std");

const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});

    // [our overlay] The C ABI static library produced here is linked into the
    // SwiftUI app, which sets a 13.0 macOS deployment target. If we leave the
    // host's OS version in place (e.g. 27.0 from a freshly installed SDK),
    // Apple's ld warns that the object files were "built for newer macOS"
    // than the app links against. Pin the minimum to match the Swift side so
    // the archive is tagged 13.0 while CPU/ABI stay native. This only matters
    // when we build for a Darwin target, which is the only case that feeds
    // the app.
    if (target.result.os.tag.isDarwin()) {
        var query = target.query;
        query.os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
        target = b.resolveTargetQuery(query);
    }

    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    // Sentinel-terminated so the C ABI can return it as a C string directly.
    build_options.addOption([:0]const u8, "version", version);
    // Create the module once and share it — calling createModule() twice on
    // the same Options makes Zig reject the duplicate file root.
    const build_options_mod = build_options.createModule();

    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("zat", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "websocket", .module = websocket.module("websocket") },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // [our overlay] C ABI static library + header for Swift consumption
    // (ownership contract documented in include/zat.h).
    const zat_c_mod = b.createModule(.{
        .root_source_file = b.path("src/c_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zat", .module = mod },
            // lets zat_version() report the version from build.zig.zon
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const zat_c_lib = b.addLibrary(.{ .name = "zat_c", .root_module = zat_c_mod, .linkage = .static });
    // bundle Zig's compiler-rt so host linkers (e.g. Swift's) find the f128
    // helpers the archive references instead of failing with missing symbols
    zat_c_lib.bundle_compiler_rt = true;
    b.installArtifact(zat_c_lib);

    const install_zat_h = b.addInstallHeaderFile(b.path("include/zat.h"), "zat.h");
    b.getInstallStep().dependOn(&install_zat_h.step);

    // Tests (upstream wiring, kept verbatim). NOTE: upstream's
    // smoke/example/bench/publish steps are intentionally NOT wired here —
    // the zig package ships only build.zig + build.zig.zon + src/ (its
    // `.paths`), so those dev tools aren't present in the fetched tarball and
    // their steps would fail with FileNotFound. The test step only needs
    // src/ and the lazily-fetched interop fixtures, so it works from the
    // package.
    const tests = b.addTest(.{ .root_module = mod });

    // add interop test fixtures (lazy — only fetched when running tests)
    if (b.lazyDependency("atproto-interop-tests", .{})) |interop| {
        const interop_files = .{
            // syntax fixtures
            .{ "tid_syntax_valid", "syntax/tid_syntax_valid.txt" },
            .{ "tid_syntax_invalid", "syntax/tid_syntax_invalid.txt" },
            .{ "did_syntax_valid", "syntax/did_syntax_valid.txt" },
            .{ "did_syntax_invalid", "syntax/did_syntax_invalid.txt" },
            .{ "handle_syntax_valid", "syntax/handle_syntax_valid.txt" },
            .{ "handle_syntax_invalid", "syntax/handle_syntax_invalid.txt" },
            .{ "nsid_syntax_valid", "syntax/nsid_syntax_valid.txt" },
            .{ "nsid_syntax_invalid", "syntax/nsid_syntax_invalid.txt" },
            .{ "recordkey_syntax_valid", "syntax/recordkey_syntax_valid.txt" },
            .{ "recordkey_syntax_invalid", "syntax/recordkey_syntax_invalid.txt" },
            .{ "aturi_syntax_valid", "syntax/aturi_syntax_valid.txt" },
            .{ "aturi_syntax_invalid", "syntax/aturi_syntax_invalid.txt" },
            .{ "atidentifier_syntax_valid", "syntax/atidentifier_syntax_valid.txt" },
            .{ "atidentifier_syntax_invalid", "syntax/atidentifier_syntax_invalid.txt" },
            .{ "cid_syntax_valid", "syntax/cid_syntax_valid.txt" },
            .{ "cid_syntax_invalid", "syntax/cid_syntax_invalid.txt" },
            .{ "uri_syntax_valid", "syntax/uri_syntax_valid.txt" },
            .{ "uri_syntax_invalid", "syntax/uri_syntax_invalid.txt" },
            .{ "language_syntax_valid", "syntax/language_syntax_valid.txt" },
            .{ "language_syntax_invalid", "syntax/language_syntax_invalid.txt" },
            .{ "datetime_syntax_valid", "syntax/datetime_syntax_valid.txt" },
            .{ "datetime_syntax_invalid", "syntax/datetime_syntax_invalid.txt" },
            .{ "datetime_parse_invalid", "syntax/datetime_parse_invalid.txt" },
            // crypto fixtures
            .{ "signature_fixtures", "crypto/signature-fixtures.json" },
            .{ "w3c_didkey_K256", "crypto/w3c_didkey_K256.json" },
            .{ "w3c_didkey_P256", "crypto/w3c_didkey_P256.json" },
            // data model fixtures
            .{ "data_model_fixtures", "data-model/data-model-fixtures.json" },
            // mst fixtures
            .{ "mst_key_heights", "mst/key_heights.json" },
            .{ "common_prefix", "mst/common_prefix.json" },
            .{ "commit_proofs", "firehose/commit-proof-fixtures.json" },
        };
        inline for (interop_files) |entry| {
            tests.root_module.addAnonymousImport(entry[0], .{
                .root_source_file = interop.path(entry[1]),
            });
        }
    }

    const run_tests = b.addRunArtifact(tests);
    run_tests.skip_foreign_checks = true;

    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);
    if (unreachedTestFiles(b)) |missing| {
        test_step.dependOn(&b.addFail(missing).step);
    }
}

/// Zig only runs tests in files the test root actually resolves, so every file
/// carrying a `test` block has to be listed in root.zig's `is_test` import
/// block. That list is hand-written and silently rotted once already: five
/// subsystems drifted out of it, taking 66 tests and two compile errors with
/// them. Returns an error message naming any file the list has missed.
fn unreachedTestFiles(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const gpa = b.allocator;
    const limit: std.Io.Limit = .limited(4 << 20);

    const root_dir = b.build_root.handle;
    const root = root_dir.readFileAlloc(io, "src/root.zig", gpa, limit) catch return null;

    var src = root_dir.openDir(io, "src", .{ .iterate = true }) catch return null;
    defer src.close(io);
    var walker = src.walk(gpa) catch return null;
    defer walker.deinit();

    var missing: std.ArrayList(u8) = .empty;
    while (walker.next(io) catch return null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "root.zig")) continue;

        const path = b.pathJoin(&.{ "src", entry.path });
        const source = root_dir.readFileAlloc(io, path, gpa, limit) catch continue;
        if (!declaresTest(source)) continue;

        const posix = std.mem.replaceOwned(u8, gpa, entry.path, "\\", "/") catch return null;
        const needle = b.fmt("@import(\"{s}\")", .{posix});
        if (std.mem.indexOf(u8, root, needle) == null) {
            missing.print(gpa, "\n  _ = @import(\"{s}\");", .{posix}) catch return null;
        }
    }

    if (missing.items.len == 0) return null;
    return b.fmt(
        "these files declare tests that will never run -- add them to the `is_test` block in src/root.zig:{s}",
        .{missing.items},
    );
}

fn declaresTest(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "test \"") or std.mem.startsWith(u8, line, "test {")) return true;
    }
    return false;
}
