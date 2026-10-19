const std = @import("std");
const platform = @import("platform.zig");

pub const Error = platform.Error || error{
    UnsupportedTargetArchitecture,
};

pub const Paths = struct {
    include: []const u8,
    lib: []const u8,
};

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
        try platform.checkDirTracked(b, dir, "Emscripten sysroot (Options.emsdk_sysroot)");
        return sysrootPaths(b, dir, triple);
    }

    const emsdk_home = try platform.requireEnvDir(b, "EMSDK", "the Emscripten SDK root");
    return sysrootPaths(b, b.pathJoin(&.{ emsdk_home, "upstream", "emscripten", "cache", "sysroot" }), triple);
}

fn sysrootPaths(b: *std.Build, sysroot: []const u8, triple: []const u8) Error!Paths {
    const io = b.graph.io;
    const include = b.pathJoin(&.{ sysroot, "include" });
    const lib = b.pathJoin(&.{ sysroot, "lib", triple });
    platform.trackDir(b, include);
    platform.trackDir(b, lib);
    if (!platform.dirExists(io, include) or !platform.dirExists(io, lib)) {
        std.log.err(
            "Emscripten sysroot at {s} is incomplete: expected include/ and lib/{s}/. Run `emcc -v` once to generate the cache sysroot, or point Options.emsdk_sysroot at a complete one.",
            .{ sysroot, triple },
        );
        return Error.SysrootNotFound;
    }

    return .{
        .include = include,
        .lib = lib,
    };
}

pub fn configureCompile(compile: *std.Build.Step.Compile, paths: Paths, libc_file: std.Build.LazyPath) void {
    const graph = compile.step.owner.graph;
    platform.configureCompile(compile, .{
        .include = graph.cwdRelativePath(paths.include),
        .lib = &.{graph.cwdRelativePath(paths.lib)},
    }, libc_file);

    switch (compile.kind) {
        .exe, .@"test" => {
            std.log.err(
                "Emscripten executable targets are not supported; build an object (see tests/smoke) and link it with emcc",
                .{},
            );
            @panic("Emscripten executable target");
        },
        .lib, .obj, .test_obj => {},
    }
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, paths: Paths) void {
    const graph = translate_c.step.owner.graph;
    platform.configureTranslateC(translate_c, .{
        .include = graph.cwdRelativePath(paths.include),
    });
}

test "Emscripten target triples" {
    try std.testing.expectEqualStrings("wasm32-emscripten", targetTriple(.wasm32).?);
    try std.testing.expectEqualStrings("wasm64-emscripten", targetTriple(.wasm64).?);
    try std.testing.expect(targetTriple(.x86_64) == null);
}
