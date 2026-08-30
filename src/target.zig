const std = @import("std");
const android = @import("android.zig");
const ohos = @import("ohos.zig");
const emscripten = @import("emscripten.zig");
const platform = @import("platform.zig");

fn PlatformConfig(comptime Paths: type) type {
    return struct {
        paths: Paths,
        libc_file: std.Build.LazyPath,
        api_level: ?[]const u8 = null,
    };
}

pub const Tag = enum {
    native,
    android,
    ohos,
    emscripten,
};

pub fn classify(target: std.Target, ohos_opt: bool) Tag {
    if (target.abi.isAndroid()) return .android;
    if (target.abi.isOpenHarmony() or (target.os.tag == .linux and target.abi.isMusl() and ohos_opt)) return .ohos;
    if (target.os.tag == .emscripten) return .emscripten;
    return .native;
}

pub const Options = struct {
    ohos: bool = false,
    android_sysroot: ?[]const u8 = null,
    ohos_sysroot: ?[]const u8 = null,
    emsdk_sysroot: ?[]const u8 = null,
};

pub const TargetConfig = union(enum) {
    native,
    android: PlatformConfig(android.Paths),
    ohos: PlatformConfig(ohos.Paths),
    emscripten: PlatformConfig(emscripten.Paths),

    pub fn init(b: *std.Build, target: std.Build.ResolvedTarget, options: Options) !TargetConfig {
        switch (classify(target.result, options.ohos)) {
            .android => {
                const paths = try android.resolvePaths(b, target, options.android_sysroot);
                const libc_file = try platform.createLibCConfig(
                    b,
                    paths.include,
                    paths.include_arch,
                    paths.static_lib_dir,
                    "android-libc.conf",
                );

                const api_level_str = b.fmt("{}", .{target.result.os.version_range.linux.android});
                return .{ .android = .{ .paths = paths, .libc_file = libc_file, .api_level = api_level_str } };
            },

            .ohos => {
                if (!target.result.abi.isOpenHarmony()) {
                    std.log.warn(
                        "Options.ohos=true: OHOS_NDK_HOME is used for target {s}-{s}; consider using the .ohos ABI once zig std supports it",
                        .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
                    );
                }
                const paths = try ohos.resolvePaths(b, target, options.ohos_sysroot);
                const libc_file = try platform.createLibCConfig(
                    b,
                    paths.include,
                    paths.include_arch,
                    paths.lib,
                    "ohos-libc.conf",
                );
                return .{ .ohos = .{ .paths = paths, .libc_file = libc_file } };
            },
            .emscripten => {
                const paths = try emscripten.resolvePaths(b, target, options.emsdk_sysroot);
                const libc_file = try platform.createLibCConfig(
                    b,
                    paths.include,
                    paths.include,
                    paths.lib,
                    "emscripten-libc.conf",
                );
                return .{ .emscripten = .{ .paths = paths, .libc_file = libc_file } };
            },
            .native => return .native,
        }
    }

    pub fn deinit(self: TargetConfig, allocator: std.mem.Allocator) void {
        switch (self) {
            .native => {},
            inline else => |config| config.paths.deinit(allocator),
        }
    }

    pub fn isNative(self: TargetConfig) bool {
        return self == .native;
    }

    pub fn configureTranslateC(self: TargetConfig, translate_c: *std.Build.Step.TranslateC) void {
        switch (self) {
            .native => {},
            .android => |config| {
                android.configureTranslateC(translate_c, config.paths);
                platform.applyTranslateCMacros(translate_c, &android.macros(config.api_level.?));
            },
            .ohos => |config| {
                ohos.configureTranslateC(translate_c, config.paths);
                platform.applyTranslateCMacros(translate_c, ohos.macros(translate_c.optimize));
            },
            .emscripten => |config| {
                emscripten.configureTranslateC(translate_c, config.paths);
                platform.applyTranslateCMacros(translate_c, &emscripten.macros());
            },
        }
    }

    pub fn configureCompile(self: TargetConfig, compile: *std.Build.Step.Compile) void {
        switch (self) {
            .native => {},
            .android => |config| {
                android.configureCompile(compile, config.paths, config.libc_file);
                platform.applyCompileMacros(compile, &android.macros(config.api_level.?));
            },
            .ohos => |config| {
                ohos.configureCompile(compile, config.paths, config.libc_file);
                platform.applyCompileMacros(compile, ohos.macros(compile.root_module.optimize orelse .Debug));
            },
            .emscripten => |config| {
                emscripten.configureCompile(compile, config.paths, config.libc_file);
                platform.applyCompileMacros(compile, &emscripten.macros());
            },
        }
    }
};

fn resolveTarget(str: []const u8) !std.Target {
    const query = try std.Target.Query.parse(.{ .arch_os_abi = str });
    return std.zig.system.resolveTargetQuery(std.testing.io, query);
}

test "classify: Android targets" {
    try std.testing.expectEqual(Tag.android, classify(try resolveTarget("aarch64-linux-android"), false));
    try std.testing.expectEqual(Tag.android, classify(try resolveTarget("arm-linux-androideabi"), false));
    try std.testing.expectEqual(Tag.android, classify(try resolveTarget("riscv64-linux-android"), true));
}

test "classify: OpenHarmony" {
    try std.testing.expectEqual(Tag.ohos, classify(try resolveTarget("aarch64-linux-ohos"), false));

    try std.testing.expectEqual(Tag.ohos, classify(try resolveTarget("aarch64-linux-musl"), true));
    try std.testing.expectEqual(Tag.native, classify(try resolveTarget("aarch64-linux-musl"), false));
}

test "classify: Emscripten" {
    try std.testing.expectEqual(Tag.emscripten, classify(try resolveTarget("wasm32-emscripten"), false));
    try std.testing.expectEqual(Tag.emscripten, classify(try resolveTarget("wasm32-emscripten"), true));
    try std.testing.expectEqual(Tag.emscripten, classify(try resolveTarget("wasm64-emscripten"), false));
}

test "classify: native" {
    try std.testing.expectEqual(Tag.native, classify(try resolveTarget("x86_64-linux-gnu"), false));
    try std.testing.expectEqual(Tag.native, classify(try resolveTarget("aarch64-macos"), true));
    try std.testing.expectEqual(Tag.native, classify(try resolveTarget("x86_64-windows-msvc"), true));
}

test "classify: the ohos option does not hijack non-musl targets" {
    try std.testing.expectEqual(Tag.native, classify(try resolveTarget("x86_64-linux-gnu"), true));
    try std.testing.expectEqual(Tag.emscripten, classify(try resolveTarget("wasm32-emscripten"), true));
}
