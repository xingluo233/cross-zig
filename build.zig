const std = @import("std");

pub const TargetConfig = @import("src/target.zig").TargetConfig;
pub const Options = @import("src/target.zig").Options;

pub const android = @import("src/android.zig");
pub const ohos = @import("src/ohos.zig");
pub const emscripten = @import("src/emscripten.zig");
pub const platform = @import("src/platform.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
