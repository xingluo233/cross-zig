const std = @import("std");
const platform = @import("platform.zig");

pub const Error = platform.Error || error{
    UnsupportedTargetArchitecture,
};

pub const Paths = struct {
    include: []const u8,
    lib: []const u8,
    crt1: ?[]const u8 = null,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.include);
        allocator.free(self.lib);
        if (self.crt1) |p| allocator.free(p);
    }
};

pub fn macros() [1]platform.Macro {
    return .{.{ .name = "__EMSCRIPTEN__", .value = "1" }};
}

pub fn targetTriple(cpu_arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (cpu_arch) {
        .wasm32 => "wasm32-emscripten",
        .wasm64 => "wasm64-emscripten",
        else => null,
    };
}

pub fn resolvePaths(b: *std.Build, target: std.Build.ResolvedTarget, sysroot: ?[]const u8) Error!Paths {
    const triple = targetTriple(target.result.cpu.arch) orelse {
        std.log.err("Unsupported Emscripten target arch: {s}", .{@tagName(target.result.cpu.arch)});
        return Error.UnsupportedTargetArchitecture;
    };

    if (sysroot) |dir| return resolveExplicitSysroot(b, dir, triple);

    const emsdk_home = try platform.requireEnvDir(b, "EMSDK", "the Emscripten SDK root");

    const emscripten_root = try std.fs.path.join(b.allocator, &.{ emsdk_home, "upstream", "emscripten" });
    defer b.allocator.free(emscripten_root);

    const cache_sysroot = try std.fs.path.join(b.allocator, &.{ emscripten_root, "cache", "sysroot" });
    defer b.allocator.free(cache_sysroot);

    const cache_include = try std.fs.path.join(b.allocator, &.{ cache_sysroot, "include" });
    const cache_lib = try std.fs.path.join(b.allocator, &.{ cache_sysroot, "lib", triple });

    if (!platform.dirExists(b.graph.io, cache_include)) {
        std.log.err(
            "Emscripten sysroot cache not found at {s}. Run `emcc -v` once to generate it, or point Options.emsdk_sysroot at a complete sysroot.",
            .{cache_sysroot},
        );
        return Error.SysrootNotFound;
    }
    if (!platform.dirExists(b.graph.io, cache_lib)) {
        std.log.err(
            "Emscripten sysroot cache is incomplete: {s} is missing. Remove the cache and run `emcc -v` once to regenerate it, or point Options.emsdk_sysroot at a complete sysroot.",
            .{cache_lib},
        );
        return Error.SysrootNotFound;
    }

    const cache_crt1 = try std.fs.path.join(b.allocator, &.{ cache_lib, "crt1.o" });
    const has_crt1 = platform.pathExists(b.graph.io, cache_crt1);
    if (!has_crt1) b.allocator.free(cache_crt1);
    return .{
        .include = cache_include,
        .lib = cache_lib,
        .crt1 = if (has_crt1) cache_crt1 else null,
    };
}

fn resolveExplicitSysroot(b: *std.Build, sysroot: []const u8, triple: []const u8) Error!Paths {
    try platform.checkDir(b.graph.io, sysroot, "Emscripten sysroot (Options.emsdk_sysroot)");

    const include = try std.fs.path.join(b.allocator, &.{ sysroot, "include" });
    const lib_arch = try std.fs.path.join(b.allocator, &.{ sysroot, "lib", triple });

    if (!platform.dirExists(b.graph.io, lib_arch)) {
        std.log.err(
            "Emscripten sysroot is incomplete: {s} is missing (expected the Emscripten sysroot layout: include/ and lib/{s}/).",
            .{ lib_arch, triple },
        );
        return Error.SysrootNotFound;
    }
    try platform.checkDir(b.graph.io, include, "Emscripten sysroot include directory");

    const crt1 = try std.fs.path.join(b.allocator, &.{ lib_arch, "crt1.o" });
    const has_crt1 = platform.pathExists(b.graph.io, crt1);
    if (!has_crt1) b.allocator.free(crt1);
    return .{ .include = include, .lib = lib_arch, .crt1 = if (has_crt1) crt1 else null };
}

pub fn configureCompile(compile: *std.Build.Step.Compile, paths: Paths, libc_file: std.Build.LazyPath) void {
    platform.configureCompile(compile, .{
        .include = paths.include,
        .include_arch = paths.include,
        .lib = &.{paths.lib},
    }, libc_file);

    if (paths.crt1) |crt1| {
        if (compile.kind != .obj) {
            compile.root_module.addObjectFile(.{ .cwd_relative = crt1 });
        }
    }
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, paths: Paths) void {
    platform.configureTranslateC(translate_c, .{
        .include = paths.include,
        .include_arch = paths.include,
    });
}

test "Emscripten macros" {
    const m = macros();
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqualStrings("__EMSCRIPTEN__", m[0].name);
    try std.testing.expectEqualStrings("1", m[0].value.?);
}

test "Emscripten target triples" {
    try std.testing.expectEqualStrings("wasm32-emscripten", targetTriple(.wasm32).?);
    try std.testing.expectEqualStrings("wasm64-emscripten", targetTriple(.wasm64).?);
    try std.testing.expect(targetTriple(.x86_64) == null);
}
