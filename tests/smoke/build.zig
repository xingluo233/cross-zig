const std = @import("std");
const cross = @import("cross");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk = cross.Options{
        .ohos = b.option(bool, "ohos", "Use the OpenHarmony NDK (OHOS_NDK_HOME) for a linux-musl target") orelse false,
        .android_sysroot = b.option([]const u8, "android-sysroot", "Android sysroot directory (overrides ANDROID_NDK_HOME)"),
        .ohos_sysroot = b.option([]const u8, "ohos-sysroot", "OpenHarmony sysroot directory (overrides OHOS_NDK_HOME)"),
        .emsdk_sysroot = b.option([]const u8, "emsdk-sysroot", "Emscripten sysroot directory (overrides EMSDK)"),
    };

    const config = cross.TargetConfig.init(b, target, sdk) catch |err| {
        std.log.err("cross.TargetConfig.init failed: {s}", .{@errorName(err)});
        @panic("see error above");
    };
    defer config.deinit(b.allocator);

    const is_emscripten = target.result.os.tag == .emscripten;

    const root = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = !is_emscripten,

        .sanitize_c = .off,
    });
    const step = if (is_emscripten)
        b.addObject(.{ .name = "smoke", .root_module = root })
    else
        b.addExecutable(.{ .name = "smoke", .root_module = root });
    step.root_module.addCSourceFile(.{ .file = b.path("src/main.c"), .flags = &.{} });
    config.configureCompile(step);

    const static_lib = b.addLibrary(.{
        .name = "smoke_static",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = !is_emscripten,
            .sanitize_c = .off,
        }),
    });
    static_lib.root_module.addCSourceFile(.{ .file = b.path("src/lib.c"), .flags = &.{} });
    config.configureCompile(static_lib);
    b.installArtifact(static_lib);

    const shared = b.addLibrary(.{
        .name = "smoke_shared",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = !is_emscripten,
            .sanitize_c = .off,
        }),
    });
    shared.root_module.addCSourceFile(.{ .file = b.path("src/lib.c"), .flags = &.{} });
    config.configureCompile(shared);
    b.installArtifact(shared);

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/headers.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_emscripten,
    });
    config.configureTranslateC(translate_c);
    step.step.dependOn(&translate_c.step);

    if (is_emscripten) {
        b.getInstallStep().dependOn(&step.step);
    } else {
        b.installArtifact(step);
    }

    if (!is_emscripten) {
        const run_cmd = b.addRunArtifact(step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step("run", "Run the smoke binary");
        run_step.dependOn(&run_cmd.step);
    }
}
