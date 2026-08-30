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

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.include);
        allocator.free(self.include_arch);
        allocator.free(self.lib);
        if (self.builtins_dir) |dir| allocator.free(dir);
    }
};

const macros_all = [_]platform.Macro{
    .{ .name = "__MUSL__", .value = "1" },
    .{ .name = "NDEBUG", .value = "1" },
};

pub fn macros(optimize: std.builtin.OptimizeMode) []const platform.Macro {
    return if (optimize == .Debug) macros_all[0..1] else macros_all[0..2];
}

pub fn targetArchName(cpu_arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (cpu_arch) {
        .aarch64 => "aarch64-linux-ohos",
        .x86_64 => "x86_64-linux-ohos",
        .arm, .thumb => "arm-linux-ohos",
        else => null,
    };
}

fn parseVersion(name: []const u8) ?[3]u32 {
    return platform.parseVersion(name);
}

fn versionNewer(a: [3]u32, b: [3]u32) bool {
    return platform.versionNewer(a, b);
}

pub fn resolveBuiltinsDir(b: *std.Build, sysroot: []const u8, triple: []const u8) Error!?[]const u8 {
    const sdk_root = std.fs.path.dirname(sysroot) orelse {
        std.log.warn(
            "Cannot infer the OpenHarmony SDK root from sysroot '{s}'; static linking against OHOS libc.a may fail with 'undefined symbol: __emutls_get_address'",
            .{sysroot},
        );
        return null;
    };
    const clang_root = try std.fs.path.join(b.allocator, &.{ sdk_root, "llvm", "lib", "clang" });
    defer b.allocator.free(clang_root);

    const io = b.graph.io;
    var clang_dir = std.Io.Dir.openDirAbsolute(io, clang_root, .{ .iterate = true }) catch |err| {
        std.log.warn(
            "OHOS clang toolchain not found at {s} ({s}); static linking against OHOS libc.a may fail with 'undefined symbol: __emutls_get_address'",
            .{ clang_root, @errorName(err) },
        );
        return null;
    };
    defer clang_dir.close(io);

    const Best = struct { version: [3]u32, path: []const u8 };
    var best: ?Best = null;
    var it = clang_dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch break;
        const entry = maybe_entry orelse break;
        if (entry.kind != .directory) continue;
        const version = platform.parseVersion(entry.name) orelse continue;
        const cand = try std.fs.path.join(b.allocator, &.{ clang_root, entry.name, "lib", triple });
        if (!platform.dirExists(io, cand)) {
            b.allocator.free(cand);
            continue;
        }
        if (best == null or platform.versionNewer(version, best.?.version)) {
            if (best) |old| b.allocator.free(old.path);
            best = .{ .version = version, .path = cand };
        } else {
            b.allocator.free(cand);
        }
    }

    if (best) |found| return found.path;

    std.log.warn(
        "OHOS clang toolchain found at {s} but no builtins archive for {s}; static linking against OHOS libc.a may fail with 'undefined symbol: __emutls_get_address'",
        .{ clang_root, triple },
    );
    return null;
}

pub fn resolvePaths(b: *std.Build, target: std.Build.ResolvedTarget, sysroot: ?[]const u8) Error!Paths {
    const cpu_arch = target.result.cpu.arch;

    const target_arch = targetArchName(cpu_arch) orelse {
        std.log.err("Unsupported target arch: {s}", .{@tagName(cpu_arch)});
        return Error.UnsupportedTargetArchitecture;
    };

    const sysroot_path = try resolveSysroot(b, sysroot);
    defer b.allocator.free(sysroot_path);

    const include = try std.fs.path.join(b.allocator, &.{ sysroot_path, "usr", "include" });
    const lib = try std.fs.path.join(b.allocator, &.{ sysroot_path, "usr", "lib", target_arch });
    const include_arch = try std.fs.path.join(b.allocator, &.{ sysroot_path, "usr", "include", target_arch });
    try platform.checkDir(b.graph.io, include, "OHOS include directory");
    try platform.checkDir(b.graph.io, lib, "OHOS library directory");
    try platform.checkDir(b.graph.io, include_arch, "OHOS architecture include directory");

    return .{
        .include = include,
        .include_arch = include_arch,
        .lib = lib,
        .builtins_dir = try resolveBuiltinsDir(b, sysroot_path, target_arch),
    };
}

fn resolveSysroot(b: *std.Build, explicit: ?[]const u8) Error![]const u8 {
    if (explicit) |path| {
        try platform.checkDir(b.graph.io, path, "OpenHarmony sysroot (Options.ohos_sysroot)");
        return try b.allocator.dupe(u8, path);
    }

    const ndk_home = try platform.requireEnvDir(b, "OHOS_NDK_HOME", "the OpenHarmony SDK native root");
    const sysroot = try std.fs.path.join(b.allocator, &.{ ndk_home, "sysroot" });
    try platform.checkDir(b.graph.io, sysroot, "OHOS sysroot");
    return sysroot;
}

pub fn configureCompile(compile: *std.Build.Step.Compile, paths: Paths, libc_file: std.Build.LazyPath) void {
    platform.configureCompile(compile, .{
        .include = paths.include,
        .include_arch = paths.include_arch,
        .lib = &.{paths.lib},
    }, libc_file);

    if (paths.builtins_dir) |dir| {
        compile.root_module.addLibraryPath(.{ .cwd_relative = dir });
        compile.root_module.linkSystemLibrary("clang_rt.builtins", .{
            .preferred_link_mode = .static,
        });
    }
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, paths: Paths) void {
    platform.configureTranslateC(translate_c, .{
        .include = paths.include,
        .include_arch = paths.include_arch,
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
    const debug = macros(.Debug);
    try std.testing.expectEqual(@as(usize, 1), debug.len);
    try std.testing.expectEqualStrings("__MUSL__", debug[0].name);

    const release = macros(.ReleaseFast);
    try std.testing.expectEqual(@as(usize, 2), release.len);
    try std.testing.expectEqualStrings("__MUSL__", release[0].name);
    try std.testing.expectEqualStrings("NDEBUG", release[1].name);
    try std.testing.expectEqualStrings("1", release[1].value.?);
}

test "clang version parsing" {
    try std.testing.expectEqual(@as(?[3]u32, .{ 17, 0, 0 }), parseVersion("17"));
    try std.testing.expectEqual(@as(?[3]u32, .{ 18, 1, 0 }), parseVersion("18.1.0"));
    try std.testing.expectEqual(@as(?[3]u32, .{ 18, 1, 4 }), parseVersion("18.1.4"));
    try std.testing.expect(parseVersion("") == null);
    try std.testing.expect(parseVersion("llvm") == null);
    try std.testing.expect(parseVersion("17a") == null);
    try std.testing.expect(parseVersion("1.2.3.4") == null);
}

test "clang version ordering" {
    try std.testing.expect(versionNewer(.{ 18, 0, 0 }, .{ 17, 9, 9 }));
    try std.testing.expect(versionNewer(.{ 18, 1, 0 }, .{ 18, 0, 9 }));
    try std.testing.expect(versionNewer(.{ 18, 1, 1 }, .{ 18, 1, 0 }));
    try std.testing.expect(!versionNewer(.{ 17, 9, 9 }, .{ 18, 0, 0 }));
    try std.testing.expect(!versionNewer(.{ 18, 1, 0 }, .{ 18, 1, 0 }));
}
