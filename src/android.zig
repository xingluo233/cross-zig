const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

pub const Error = platform.Error || error{
    UnsupportedHostOperatingSystem,
    UnsupportedHostArchitecture,
    UnsupportedTargetArchitecture,
    StaticLibDirUnavailable,
};

pub const ArchNames = struct {
    triple: []const u8,
    builtins: []const u8,
    unwind: []const u8,
};

pub fn archNames(cpu_arch: std.Target.Cpu.Arch) ?ArchNames {
    return switch (cpu_arch) {
        .aarch64 => .{ .triple = "aarch64-linux-android", .builtins = "aarch64", .unwind = "aarch64" },
        .x86_64 => .{ .triple = "x86_64-linux-android", .builtins = "x86_64", .unwind = "x86_64" },
        .x86 => .{ .triple = "i686-linux-android", .builtins = "i686", .unwind = "i386" },
        .arm, .thumb => .{ .triple = "arm-linux-androideabi", .builtins = "arm", .unwind = "arm" },
        .riscv64 => .{ .triple = "riscv64-linux-android", .builtins = "riscv64", .unwind = "riscv64" },
        else => null,
    };
}

pub const Paths = struct {
    include: []const u8,
    include_arch: []const u8,
    lib_arch: []const u8,
    lib_api: []const u8,
    static_lib_dir: std.Build.LazyPath,

    api_level: []const u8,
    has_atomic: bool = false,
};

pub fn macros(api_level: []const u8) [3]platform.Macro {
    return .{
        .{ .name = "_FORTIFY_SOURCE", .value = "0" },
        .{ .name = "__ANDROID_API__", .value = api_level },
        .{ .name = "__ANDROID_MIN_SDK_VERSION__", .value = api_level },
    };
}

fn hostOsName(host_os: std.Target.Os.Tag) ?[]const u8 {
    return switch (host_os) {
        .windows => "windows",
        .linux => "linux",
        .macos => "darwin",
        else => null,
    };
}

fn hostArchName(host_arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (host_arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => null,
    };
}

pub fn resolvePaths(b: *std.Build, target: std.Build.ResolvedTarget, sysroot: ?[]const u8) Error!Paths {
    const api_level = target.result.os.version_range.linux.android;
    const cpu_arch = target.result.cpu.arch;

    const arch = archNames(cpu_arch) orelse {
        std.log.err("Unsupported target arch: {s}", .{@tagName(cpu_arch)});
        return Error.UnsupportedTargetArchitecture;
    };

    const sysroot_path = try resolveSysroot(b, sysroot);

    const include = b.pathJoin(&.{ sysroot_path, "usr", "include" });
    const include_arch = b.pathJoin(&.{ sysroot_path, "usr", "include", arch.triple });
    const lib_arch = b.pathJoin(&.{ sysroot_path, "usr", "lib", arch.triple });
    const api_level_str = b.fmt("{d}", .{api_level});
    const lib_api = b.pathJoin(&.{ lib_arch, api_level_str });

    try platform.checkDirTracked(b, include, "Android include directory");
    try platform.checkDirTracked(b, include_arch, "Android architecture include directory");
    try platform.checkDirTracked(b, lib_arch, "Android architecture library");
    platform.trackDir(b, lib_api);
    if (!platform.dirExists(b.graph.io, lib_api)) {
        std.log.err("Android API library directory not found: {s}", .{lib_api});
        logAvailableApiDirs(b, lib_arch);
        return Error.SysrootNotFound;
    }

    const layout = try createMergedStaticLibDir(b, arch, api_level, sysroot_path, lib_arch, lib_api);
    return .{
        .include = include,
        .include_arch = include_arch,
        .lib_arch = lib_arch,
        .lib_api = lib_api,
        .static_lib_dir = layout.dir,
        .api_level = api_level_str,
        .has_atomic = layout.has_atomic,
    };
}

const Layout = struct {
    dir: std.Build.LazyPath,
    has_atomic: bool,
};

fn logAvailableApiDirs(b: *std.Build, lib_arch: []const u8) void {
    const io = b.graph.io;
    var dir = std.Io.Dir.openDirAbsolute(io, lib_arch, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        names.append(b.allocator, b.graph.dupeString(entry.name)) catch return;
    }
    if (names.items.len == 0) return;

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    const levels = std.mem.join(b.allocator, ", ", names.items) catch return;
    std.log.err("  actual API levels in {s}: {s}", .{ lib_arch, levels });
    if (names.items.len == 1) {
        std.log.err("  hint: this architecture ships a single API level ({s}); use -Dtarget={s}.{s}", .{
            names.items[0], std.Io.Dir.path.basename(lib_arch), names.items[0],
        });
    }
}

fn clangLinuxLibDir(b: *std.Build, sysroot_path: []const u8) ?[]const u8 {
    const toolchain_root = std.Io.Dir.path.dirname(sysroot_path) orelse return null;
    const clang_root = b.pathJoin(&.{ toolchain_root, "lib", "clang" });

    platform.trackDir(b, clang_root);
    const found = platform.findNewestVersionedSubdir(b.allocator, b.graph.io, clang_root, &.{ "lib", "linux" });
    if (found == null) {
        std.log.warn(
            "Android NDK clang runtime libraries not found under {s} (expected <clang>/<version>/lib/linux); static libc linking may fail",
            .{clang_root},
        );
    }
    return found;
}

fn mergedDirName(
    allocator: std.mem.Allocator,
    builtins_name: []const u8,
    api_level: u32,
    sysroot_path: []const u8,
) []const u8 {
    return allocator.print("cross-android-{s}-{d}-{x}", .{
        builtins_name,
        api_level,
        std.hash.Wyhash.hash(0, sysroot_path),
    }) catch @panic("OOM");
}

fn createMergedStaticLibDir(
    b: *std.Build,
    arch: ArchNames,
    api_level: u32,
    sysroot_path: []const u8,
    lib_arch: []const u8,
    lib_api: []const u8,
) Error!Layout {
    const io = b.graph.io;

    const clang_linux_path = clangLinuxLibDir(b, sysroot_path) orelse return Error.StaticLibDirUnavailable;
    const builtins_src = b.fmt("libclang_rt.builtins-{s}-android.a", .{arch.builtins});
    const unwind_lib_path = b.pathJoin(&.{ clang_linux_path, arch.unwind });

    platform.trackDir(b, clang_linux_path);
    platform.trackDir(b, unwind_lib_path);

    const crtbegin_in_api = platform.pathExists(io, b.pathJoin(&.{ lib_api, "crtbegin_static.o" }));

    const dir_name = mergedDirName(b.allocator, arch.builtins, api_level, sysroot_path);

    const wf = b.addWriteFiles();
    wf.step.name = b.fmt("Merge Android static libs ({s})", .{dir_name});

    const copies = [_]struct {
        src_dir: []const u8,
        name: []const u8,
        dst: ?[]const u8 = null,
    }{
        .{ .src_dir = if (crtbegin_in_api) lib_api else lib_arch, .name = "crtbegin_static.o" },
        .{ .src_dir = lib_api, .name = "crtend_android.o" },
        .{ .src_dir = lib_api, .name = "crtbegin_so.o" },
        .{ .src_dir = lib_api, .name = "crtend_so.o" },
        .{ .src_dir = lib_api, .name = "crtbegin_dynamic.o" },
        .{ .src_dir = lib_arch, .name = "libc.a" },
        .{ .src_dir = lib_arch, .name = "libm.a" },
        .{ .src_dir = lib_arch, .name = "libdl.a" },
        .{ .src_dir = lib_api, .name = "libc.so" },
        .{ .src_dir = lib_api, .name = "libm.so" },
        .{ .src_dir = lib_api, .name = "libdl.so" },
        .{ .src_dir = clang_linux_path, .name = builtins_src, .dst = "libbuiltins.a" },
        .{ .src_dir = unwind_lib_path, .name = "libunwind.a" },
    };

    for (copies) |c| {
        const src_path = b.pathJoin(&.{ c.src_dir, c.name });
        if (!platform.pathExists(io, src_path)) {
            std.log.err(
                "Android NDK piece required for libc linking is missing: '{s}' (arch {s}, API {d})",
                .{ src_path, arch.builtins, api_level },
            );
            return Error.StaticLibDirUnavailable;
        }
        _ = wf.addCopyFile(b.graph.cwdRelativePath(src_path), c.dst orelse c.name);
    }

    const atomic_src = b.pathJoin(&.{ unwind_lib_path, "libatomic.a" });
    const has_atomic = platform.pathExists(io, atomic_src);
    if (has_atomic) _ = wf.addCopyFile(b.graph.cwdRelativePath(atomic_src), "libatomic.a");

    return .{ .dir = wf.getDirectory(), .has_atomic = has_atomic };
}

fn resolveSysroot(b: *std.Build, explicit: ?[]const u8) Error![]const u8 {
    if (explicit) |path| {
        try platform.checkDirTracked(b, path, "Android sysroot (Options.android_sysroot)");
        return path;
    }

    const ndk_home = try platform.requireEnvDir(b, "ANDROID_NDK_HOME", "the Android NDK root");
    const host_os = hostOsName(builtin.os.tag) orelse {
        std.log.err("Unsupported host OS: {s}", .{@tagName(builtin.os.tag)});
        return Error.UnsupportedHostOperatingSystem;
    };
    const host_arch = hostArchName(builtin.cpu.arch) orelse {
        std.log.err("Unsupported host arch: {s}", .{@tagName(builtin.cpu.arch)});
        return Error.UnsupportedHostArchitecture;
    };

    const sysroot = b.pathJoin(&.{
        ndk_home, "toolchains", "llvm", "prebuilt", b.fmt("{s}-{s}", .{ host_os, host_arch }), "sysroot",
    });
    try platform.checkDirTracked(b, sysroot, "Android sysroot");
    return sysroot;
}

pub fn configureCompile(compile: *std.Build.Step.Compile, paths: Paths, libc_file: std.Build.LazyPath) void {
    const graph = compile.step.owner.graph;
    platform.configureCompile(compile, .{
        .include = graph.cwdRelativePath(paths.include),
        .include_arch = graph.cwdRelativePath(paths.include_arch),
        .lib = &.{
            graph.cwdRelativePath(paths.lib_api),
            graph.cwdRelativePath(paths.lib_arch),
            paths.static_lib_dir,
        },
    }, libc_file);

    compile.root_module.linkSystemLibrary("unwind", .{ .use_pkg_config = .no });
    compile.root_module.linkSystemLibrary("builtins", .{ .use_pkg_config = .no });
    if (paths.has_atomic) {
        compile.root_module.linkSystemLibrary("atomic", .{ .use_pkg_config = .no });
    }
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, paths: Paths) void {
    const graph = translate_c.step.owner.graph;
    platform.configureTranslateC(translate_c, .{
        .include = graph.cwdRelativePath(paths.include),
        .include_arch = graph.cwdRelativePath(paths.include_arch),
    });
}

test "host OS names" {
    try std.testing.expectEqualStrings("windows", hostOsName(.windows).?);
    try std.testing.expectEqualStrings("linux", hostOsName(.linux).?);
    try std.testing.expectEqualStrings("darwin", hostOsName(.macos).?);
    try std.testing.expect(hostOsName(.freestanding) == null);
}

test "host arch names" {
    try std.testing.expectEqualStrings("x86_64", hostArchName(.x86_64).?);
    try std.testing.expectEqualStrings("aarch64", hostArchName(.aarch64).?);

    try std.testing.expect(hostArchName(.x86) == null);
    try std.testing.expect(hostArchName(.wasm32) == null);
}

test "arch names" {
    const aarch64 = archNames(.aarch64).?;
    try std.testing.expectEqualStrings("aarch64-linux-android", aarch64.triple);
    try std.testing.expectEqualStrings("aarch64", aarch64.builtins);
    try std.testing.expectEqualStrings("aarch64", aarch64.unwind);

    const thumb = archNames(.thumb).?;
    try std.testing.expectEqualStrings("arm-linux-androideabi", thumb.triple);
    try std.testing.expectEqualStrings("arm", thumb.builtins);
    try std.testing.expectEqualStrings("arm", thumb.unwind);

    const x86 = archNames(.x86).?;
    try std.testing.expectEqualStrings("i686-linux-android", x86.triple);
    try std.testing.expectEqualStrings("i686", x86.builtins);
    try std.testing.expectEqualStrings("i386", x86.unwind);

    try std.testing.expectEqualStrings("x86_64-linux-android", archNames(.x86_64).?.triple);
    try std.testing.expectEqualStrings("riscv64-linux-android", archNames(.riscv64).?.triple);
    try std.testing.expect(archNames(.mips) == null);
}

test "Android macros" {
    const m = macros("34");
    try std.testing.expectEqual(@as(usize, 3), m.len);
    try std.testing.expectEqualStrings("_FORTIFY_SOURCE", m[0].name);
    try std.testing.expectEqualStrings("0", m[0].value.?);
    try std.testing.expectEqualStrings("__ANDROID_API__", m[1].name);
    try std.testing.expectEqualStrings("34", m[1].value.?);
    try std.testing.expectEqualStrings("__ANDROID_MIN_SDK_VERSION__", m[2].name);
    try std.testing.expectEqualStrings("34", m[2].value.?);
}

test "merged dir names are scoped to arch + api + sysroot" {
    const allocator = std.testing.allocator;
    const aarch64_35 = mergedDirName(allocator, "aarch64", 35, "/ndk");
    defer allocator.free(aarch64_35);
    const aarch64_36 = mergedDirName(allocator, "aarch64", 36, "/ndk");
    defer allocator.free(aarch64_36);
    const other_ndk = mergedDirName(allocator, "aarch64", 35, "/other-ndk");
    defer allocator.free(other_ndk);
    const riscv64 = mergedDirName(allocator, "riscv64", 35, "/ndk");
    defer allocator.free(riscv64);

    try std.testing.expect(!std.mem.eql(u8, aarch64_35, aarch64_36));
    try std.testing.expect(!std.mem.eql(u8, aarch64_35, other_ndk));
    try std.testing.expect(!std.mem.eql(u8, aarch64_35, riscv64));
}
