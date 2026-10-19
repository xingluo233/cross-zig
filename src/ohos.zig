const std = @import("std");
const platform = @import("platform.zig");

pub const Error = platform.Error || error{
    UnsupportedTargetArchitecture,
};

pub const Paths = struct {
    include: []const u8,
    include_arch: []const u8,
    lib: []const u8,
    builtins_dir: ?[]const u8 = null,
    crt_shim_dir: ?std.Build.LazyPath = null,
};

const macros_all = [_]platform.Macro{
    .{ .name = "__MUSL__", .value = "1" },
    .{ .name = "NDEBUG", .value = "1" },
};

pub fn macros(optimize: std.builtin.Optimize) []const platform.Macro {
    return if (optimize == .debug) macros_all[0..1] else macros_all[0..2];
}

fn targetArchName(cpu_arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (cpu_arch) {
        .aarch64 => "aarch64-linux-ohos",
        .x86_64 => "x86_64-linux-ohos",
        .arm, .thumb => "arm-linux-ohos",
        else => null,
    };
}

fn resolveBuiltinsDir(b: *std.Build, sysroot: []const u8, triple: []const u8) ?[]const u8 {
    const sdk_root = std.Io.Dir.path.dirname(sysroot) orelse {
        std.log.warn(
            "Cannot infer the OpenHarmony SDK root from sysroot '{s}'; static linking against OHOS libc.a may fail with 'undefined symbol: __emutls_get_address'",
            .{sysroot},
        );
        return null;
    };
    const clang_root = b.pathJoin(&.{ sdk_root, "llvm", "lib", "clang" });

    platform.trackDir(b, clang_root);
    const found = platform.findNewestVersionedSubdir(b.allocator, b.graph.io, clang_root, &.{ "lib", triple });
    if (found == null) {
        std.log.warn(
            "OHOS clang builtins for {s} not found under {s}; static linking against OHOS libc.a may fail with 'undefined symbol: __emutls_get_address'",
            .{ triple, clang_root },
        );
    }
    return found;
}

pub fn resolvePaths(b: *std.Build, target: std.Build.ResolvedTarget, sysroot: ?[]const u8) Error!Paths {
    const cpu_arch = target.result.cpu.arch;

    const target_arch = targetArchName(cpu_arch) orelse {
        std.log.err("Unsupported target arch: {s}", .{@tagName(cpu_arch)});
        return Error.UnsupportedTargetArchitecture;
    };

    const sysroot_path = try resolveSysroot(b, sysroot);

    const include = b.pathJoin(&.{ sysroot_path, "usr", "include" });
    const lib = b.pathJoin(&.{ sysroot_path, "usr", "lib", target_arch });
    const include_arch = b.pathJoin(&.{ sysroot_path, "usr", "include", target_arch });
    try platform.checkDirTracked(b, include, "OHOS include directory");
    try platform.checkDirTracked(b, lib, "OHOS library directory");
    try platform.checkDirTracked(b, include_arch, "OHOS architecture include directory");

    const builtins_dir = resolveBuiltinsDir(b, sysroot_path, target_arch);

    const crt_shim_dir = if (builtins_dir) |dir| platform.crtShimDir(
        b,
        dir,
        &.{
            .{ .src = "clang_rt.crtbegin.o", .dst = "crtbegin.o" },
            .{ .src = "clang_rt.crtend.o", .dst = "crtend.o" },
            .{ .src = "clang_rt.crtbegin.o", .dst = "crtbeginS.o" },
            .{ .src = "clang_rt.crtend.o", .dst = "crtendS.o" },
        },
    ) else null;

    return .{
        .include = include,
        .include_arch = include_arch,
        .lib = lib,
        .builtins_dir = builtins_dir,
        .crt_shim_dir = crt_shim_dir,
    };
}

fn resolveSysroot(b: *std.Build, explicit: ?[]const u8) Error![]const u8 {
    if (explicit) |path| {
        try platform.checkDirTracked(b, path, "OpenHarmony sysroot (Options.ohos_sysroot)");
        return path;
    }

    const ndk_home = try platform.requireEnvDir(b, "OHOS_NDK_HOME", "the OpenHarmony SDK native root");
    const sysroot = b.pathJoin(&.{ ndk_home, "sysroot" });
    try platform.checkDirTracked(b, sysroot, "OHOS sysroot");
    return sysroot;
}

pub fn configureCompile(compile: *std.Build.Step.Compile, paths: Paths, libc_file: std.Build.LazyPath) void {
    const graph = compile.step.owner.graph;
    platform.configureCompile(compile, .{
        .include = graph.cwdRelativePath(paths.include),
        .include_arch = graph.cwdRelativePath(paths.include_arch),
        .lib = &.{graph.cwdRelativePath(paths.lib)},
    }, libc_file);

    if (paths.builtins_dir) |dir| {
        compile.root_module.addLibraryPath(graph.cwdRelativePath(dir));

        compile.root_module.linkSystemLibrary("clang_rt.builtins", .{
            .preferred_link_mode = .static,
            .use_pkg_config = .no,
        });
    }
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, paths: Paths) void {
    const graph = translate_c.step.owner.graph;
    platform.configureTranslateC(translate_c, .{
        .include = graph.cwdRelativePath(paths.include),
        .include_arch = graph.cwdRelativePath(paths.include_arch),
    });
}

test "OHOS target arch names" {
    try std.testing.expectEqualStrings("aarch64-linux-ohos", targetArchName(.aarch64).?);
    try std.testing.expectEqualStrings("x86_64-linux-ohos", targetArchName(.x86_64).?);
    try std.testing.expectEqualStrings("arm-linux-ohos", targetArchName(.arm).?);
    try std.testing.expectEqualStrings("arm-linux-ohos", targetArchName(.thumb).?);
    try std.testing.expect(targetArchName(.riscv64) == null);
}

test "OHOS macros" {
    const debug = macros(.debug);
    try std.testing.expectEqual(@as(usize, 1), debug.len);
    try std.testing.expectEqualStrings("__MUSL__", debug[0].name);

    const release = macros(.fast);
    try std.testing.expectEqual(@as(usize, 2), release.len);
    try std.testing.expectEqualStrings("__MUSL__", release[0].name);
    try std.testing.expectEqualStrings("NDEBUG", release[1].name);
    try std.testing.expectEqualStrings("1", release[1].value.?);
}
