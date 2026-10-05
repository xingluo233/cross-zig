const std = @import("std");
const platform = @import("platform.zig");

pub const Error = platform.Error || error{
    UnsupportedTargetArchitecture,
};

pub const Paths = struct {
    include: []const u8,
    lib: []const u8,
    crt1: ?[]const u8 = null,
};

pub fn macros() [1]platform.Macro {
    return .{.{ .name = "__EMSCRIPTEN__", .value = "1" }};
}

fn targetTriple(cpu_arch: std.Target.Cpu.Arch) ?[]const u8 {
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

    if (sysroot) |dir| {
        try platform.checkDir(b.graph.io, dir, "Emscripten sysroot (Options.emsdk_sysroot)");
        return sysrootPaths(b, dir, triple);
    }

    const emsdk_home = try platform.requireEnvDir(b, "EMSDK", "the Emscripten SDK root");
    return sysrootPaths(b, b.pathJoin(&.{ emsdk_home, "upstream", "emscripten", "cache", "sysroot" }), triple);
}

fn sysrootPaths(b: *std.Build, sysroot: []const u8, triple: []const u8) Error!Paths {
    const io = b.graph.io;
    const include = b.pathJoin(&.{ sysroot, "include" });
    const lib = b.pathJoin(&.{ sysroot, "lib", triple });
    if (!platform.dirExists(io, include) or !platform.dirExists(io, lib)) {
        std.log.err(
            "Emscripten sysroot at {s} is incomplete: expected include/ and lib/{s}/. Run `emcc -v` once to generate the cache sysroot, or point Options.emsdk_sysroot at a complete one.",
            .{ sysroot, triple },
        );
        return Error.SysrootNotFound;
    }

    const crt1 = b.pathJoin(&.{ lib, "crt1.o" });
    return .{
        .include = include,
        .lib = lib,
        .crt1 = if (platform.pathExists(io, crt1)) crt1 else null,
    };
}

pub fn configureCompile(compile: *std.Build.Step.Compile, paths: Paths, libc_file: std.Build.LazyPath) void {
    platform.configureCompile(compile, .{
        .include = paths.include,
        .include_arch = paths.include,
        .lib = &.{paths.lib},
    }, libc_file);

    if (paths.crt1) |crt1| {
        if (compile.kind != .obj) {
            compile.root_module.addObjectFile(compile.step.owner.graph.cwdRelativePath(crt1));
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
