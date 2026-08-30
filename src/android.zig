const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

pub const Error = platform.Error || error{
    UnsupportedHostOperatingSystem,
    UnsupportedHostArchitecture,
    UnsupportedTargetArchitecture,
    StaticLibDirUnavailable,
};

pub const Paths = struct {
    include: []const u8,
    include_arch: []const u8,
    lib_arch: []const u8,
    lib_api: []const u8,
    static_lib_dir: []const u8,
    has_atomic: bool = false,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.include);
        allocator.free(self.include_arch);
        allocator.free(self.lib_arch);
        allocator.free(self.lib_api);
        allocator.free(self.static_lib_dir);
    }
};

pub fn macros(api_level: []const u8) [3]platform.Macro {
    return .{
        .{ .name = "_FORTIFY_SOURCE", .value = "0" },
        .{ .name = "__ANDROID_API__", .value = api_level },
        .{ .name = "__ANDROID_MIN_SDK_VERSION__", .value = api_level },
    };
}

pub fn hostOsName(host_os: std.Target.Os.Tag) ?[]const u8 {
    return switch (host_os) {
        .windows => "windows",
        .linux => "linux",
        .macos => "darwin",
        else => null,
    };
}

pub fn hostArchName(host_arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (host_arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => null,
    };
}

pub fn targetArchName(cpu_arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (cpu_arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        .riscv64 => "riscv64-linux-android",
        else => null,
    };
}

pub fn resolvePaths(b: *std.Build, target: std.Build.ResolvedTarget, sysroot: ?[]const u8) Error!Paths {
    const api_level = target.result.os.version_range.linux.android;
    const cpu_arch = target.result.cpu.arch;

    const sysroot_path = try resolveSysroot(b, sysroot);
    defer b.allocator.free(sysroot_path);

    const target_arch = targetArchName(cpu_arch) orelse {
        std.log.err("Unsupported target arch: {s}", .{@tagName(cpu_arch)});
        return Error.UnsupportedTargetArchitecture;
    };

    const include = try std.fs.path.join(b.allocator, &.{ sysroot_path, "usr", "include" });
    const include_arch = try std.fs.path.join(b.allocator, &.{ sysroot_path, "usr", "include", target_arch });
    const lib_arch = try std.fs.path.join(b.allocator, &.{ sysroot_path, "usr", "lib", target_arch });
    const api_str = try std.fmt.allocPrint(b.allocator, "{d}", .{api_level});
    defer b.allocator.free(api_str);
    const lib_api = try std.fs.path.join(b.allocator, &.{ lib_arch, api_str });
    try platform.checkDir(b.graph.io, include, "Android include directory");
    try platform.checkDir(b.graph.io, include_arch, "Android architecture include directory");
    try platform.checkDir(b.graph.io, lib_arch, "Android architecture library");
    if (!platform.dirExists(b.graph.io, lib_api)) {
        std.log.err("Android API library directory not found: {s}", .{lib_api});

        logAvailableApiDirs(b, lib_arch);
        return Error.SysrootNotFound;
    }

    const layout = try createMergedStaticLibDir(b, cpu_arch, api_level, sysroot_path, lib_arch, lib_api);
    return .{
        .include = include,
        .include_arch = include_arch,
        .lib_arch = lib_arch,
        .lib_api = lib_api,
        .static_lib_dir = layout.dir,
        .has_atomic = layout.has_atomic,
    };
}

const Layout = struct {
    dir: []const u8,
    has_atomic: bool = false,
};

fn logAvailableApiDirs(b: *std.Build, lib_arch: []const u8) void {
    const io = b.graph.io;
    var dir = std.Io.Dir.openDirAbsolute(io, lib_arch, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| b.allocator.free(n);
        names.deinit(b.allocator);
    }
    var it = dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch break;
        const entry = maybe_entry orelse break;
        if (entry.kind != .directory) continue;
        names.append(b.allocator, b.allocator.dupe(u8, entry.name) catch return) catch return;
    }
    if (names.items.len == 0) return;

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(b.allocator);
    for (names.items, 0..) |n, i| {
        if (i != 0) list.appendSlice(b.allocator, ", ") catch return;
        list.appendSlice(b.allocator, n) catch return;
    }
    std.log.err("  actual API levels in {s}: {s}", .{ lib_arch, list.items });

    if (names.items.len == 1) {
        std.log.err("  hint: this architecture ships a single API level ({s}); use -Dtarget={s}.{s}", .{ names.items[0], std.fs.path.basename(lib_arch), names.items[0] });
    }
}

fn builtinsName(cpu_arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (cpu_arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        .x86 => "i686",
        .arm, .thumb => "arm",
        .riscv64 => "riscv64",
        else => null,
    };
}

fn unwindDir(cpu_arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (cpu_arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        .x86 => "i386",
        .arm, .thumb => "arm",
        .riscv64 => "riscv64",
        else => null,
    };
}

fn clangLinuxLibDir(b: *std.Build, sysroot_path: []const u8) Error!?[]const u8 {
    const io = b.graph.io;
    const toolchain_root = std.fs.path.dirname(sysroot_path) orelse return null;
    const clang_root = try std.fs.path.join(b.allocator, &.{ toolchain_root, "lib", "clang" });
    defer b.allocator.free(clang_root);

    var clang_dir = std.Io.Dir.openDirAbsolute(io, clang_root, .{ .iterate = true }) catch |err| {
        std.log.warn("Android NDK clang dir not found at {s} ({s}); static libc linking may fail", .{ clang_root, @errorName(err) });
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
        const linux_dir = try std.fs.path.join(b.allocator, &.{ clang_root, entry.name, "lib", "linux" });
        if (!platform.dirExists(io, linux_dir)) {
            b.allocator.free(linux_dir);
            continue;
        }
        if (best == null or platform.versionNewer(version, best.?.version)) {
            if (best) |old| b.allocator.free(old.path);
            best = .{ .version = version, .path = linux_dir };
        } else {
            b.allocator.free(linux_dir);
        }
    }

    if (best) |found| return found.path;

    std.log.warn(
        "Android NDK clang runtime libraries not found under {s}; static libc linking may fail",
        .{clang_root},
    );
    return null;
}

fn dirExistsIn(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const d = dir.openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn copyIfMissing(io: std.Io, src_dir: std.Io.Dir, src_name: []const u8, dst_dir: std.Io.Dir, dst_name: []const u8) bool {
    if (dst_dir.access(io, dst_name, .{})) |_| {
        return true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return false,
    }
    std.Io.Dir.copyFile(src_dir, src_name, dst_dir, dst_name, io, .{}) catch return false;
    return true;
}

pub fn mergedDirName(
    allocator: std.mem.Allocator,
    cpu_arch: std.Target.Cpu.Arch,
    api_level: u32,
    sysroot_path: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const name = builtinsName(cpu_arch) orelse return null;
    return try std.fmt.allocPrint(allocator, "cross-android-{s}-{d}-{x}", .{
        name,
        api_level,
        std.hash.Wyhash.hash(0, sysroot_path),
    });
}

fn createMergedStaticLibDir(
    b: *std.Build,
    cpu_arch: std.Target.Cpu.Arch,
    api_level: u32,
    sysroot_path: []const u8,
    lib_arch: []const u8,
    lib_api: []const u8,
) Error!Layout {
    const io = b.graph.io;

    const builtins_name = builtinsName(cpu_arch) orelse return Error.UnsupportedTargetArchitecture;
    const arch_name = unwindDir(cpu_arch) orelse return Error.UnsupportedTargetArchitecture;

    const clang_linux = try clangLinuxLibDir(b, sysroot_path);
    defer if (clang_linux) |dir| b.allocator.free(dir);
    if (clang_linux == null) return Error.StaticLibDirUnavailable;

    const dir_name = try mergedDirName(b.allocator, cpu_arch, api_level, sysroot_path) orelse return Error.UnsupportedTargetArchitecture;
    const cache_dir = b.cache_root.handle;
    if (!dirExistsIn(cache_dir, io, dir_name)) {
        cache_dir.createDirPath(io, dir_name) catch |err| {
            std.log.err("failed to create {s} in the zig cache: {s}", .{ dir_name, @errorName(err) });
            return Error.StaticLibDirUnavailable;
        };
    }

    const dest_rel = if (b.cache_root.path) |p|
        try std.fs.path.join(b.allocator, &.{ p, dir_name })
    else
        try b.allocator.dupe(u8, dir_name);

    var lib_api_dir = std.Io.Dir.openDirAbsolute(io, lib_api, .{}) catch return Error.StaticLibDirUnavailable;
    defer lib_api_dir.close(io);
    var lib_arch_dir = std.Io.Dir.openDirAbsolute(io, lib_arch, .{}) catch return Error.StaticLibDirUnavailable;
    defer lib_arch_dir.close(io);

    const crtbegin_from_api = platform.pathExists(io, try std.fs.path.join(b.allocator, &.{ lib_api, "crtbegin_static.o" }));

    const clang_linux_dir = std.Io.Dir.openDirAbsolute(io, clang_linux.?, .{}) catch return Error.StaticLibDirUnavailable;
    defer clang_linux_dir.close(io);
    const builtins_src = try std.fmt.allocPrint(b.allocator, "libclang_rt.builtins-{s}-android.a", .{builtins_name});
    defer b.allocator.free(builtins_src);

    var unwind_dir = std.Io.Dir.openDirAbsolute(io, try std.fs.path.join(b.allocator, &.{ clang_linux.?, arch_name }), .{}) catch |err| {
        std.log.err("Android NDK unwind library dir not found at {s}/{s}: {s}", .{ clang_linux.?, arch_name, @errorName(err) });
        return Error.StaticLibDirUnavailable;
    };
    defer unwind_dir.close(io);

    const copies = [_]struct {
        src: std.Io.Dir,
        name: []const u8,
        dst: []const u8,
    }{
        .{ .src = if (crtbegin_from_api) lib_api_dir else lib_arch_dir, .name = "crtbegin_static.o", .dst = "crtbegin_static.o" },
        .{ .src = lib_api_dir, .name = "crtend_android.o", .dst = "crtend_android.o" },

        .{ .src = lib_api_dir, .name = "crtbegin_so.o", .dst = "crtbegin_so.o" },
        .{ .src = lib_api_dir, .name = "crtend_so.o", .dst = "crtend_so.o" },
        .{ .src = lib_api_dir, .name = "crtbegin_dynamic.o", .dst = "crtbegin_dynamic.o" },
        .{ .src = lib_arch_dir, .name = "libc.a", .dst = "libc.a" },
        .{ .src = lib_arch_dir, .name = "libm.a", .dst = "libm.a" },
        .{ .src = lib_arch_dir, .name = "libdl.a", .dst = "libdl.a" },

        .{ .src = lib_api_dir, .name = "libc.so", .dst = "libc.so" },
        .{ .src = lib_api_dir, .name = "libm.so", .dst = "libm.so" },
        .{ .src = lib_api_dir, .name = "libdl.so", .dst = "libdl.so" },
        .{ .src = clang_linux_dir, .name = builtins_src, .dst = "libbuiltins.a" },
        .{ .src = unwind_dir, .name = "libunwind.a", .dst = "libunwind.a" },
    };

    var missing: []const u8 = "";
    for (copies) |c| {
        const dst_path = try std.fs.path.join(b.allocator, &.{ dir_name, c.dst });
        if (!copyIfMissing(io, c.src, c.name, cache_dir, dst_path)) {
            missing = c.name;
            break;
        }
    }
    if (missing.len != 0) {
        std.log.err(
            "Android NDK piece required for libc linking is missing: '{s}' (arch {s}, API {d})",
            .{ missing, builtins_name, api_level },
        );
        return Error.StaticLibDirUnavailable;
    }

    const has_atomic = copyIfMissing(io, unwind_dir, "libatomic.a", cache_dir, try std.fs.path.join(b.allocator, &.{ dir_name, "libatomic.a" }));

    return .{ .dir = dest_rel, .has_atomic = has_atomic };
}

fn resolveSysroot(b: *std.Build, explicit: ?[]const u8) Error![]const u8 {
    if (explicit) |path| {
        try platform.checkDir(b.graph.io, path, "Android sysroot (Options.android_sysroot)");
        return try b.allocator.dupe(u8, path);
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
    const host_tag = b.fmt("{s}-{s}", .{ host_os, host_arch });

    const sysroot = try std.fs.path.join(b.allocator, &.{
        ndk_home, "toolchains", "llvm", "prebuilt", host_tag, "sysroot",
    });
    try platform.checkDir(b.graph.io, sysroot, "Android sysroot");
    return sysroot;
}

pub fn configureCompile(compile: *std.Build.Step.Compile, paths: Paths, libc_file: std.Build.LazyPath) void {
    platform.configureCompile(compile, .{
        .include = paths.include,
        .include_arch = paths.include_arch,
        .lib = &.{ paths.lib_api, paths.lib_arch },
    }, libc_file);

    compile.root_module.addLibraryPath(.{ .cwd_relative = paths.static_lib_dir });

    compile.root_module.linkSystemLibrary("unwind", .{});
    compile.root_module.linkSystemLibrary("builtins", .{});
    if (paths.has_atomic) {
        compile.root_module.linkSystemLibrary("atomic", .{});
    }
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, paths: Paths) void {
    platform.configureTranslateC(translate_c, .{
        .include = paths.include,
        .include_arch = paths.include_arch,
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

test "merged dir names are scoped to arch + api + sysroot" {
    const a1 = try mergedDirName(std.testing.allocator, .aarch64, 35, "/ndk") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(a1);
    const a2 = try mergedDirName(std.testing.allocator, .aarch64, 36, "/ndk") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(a2);
    const other_ndk = try mergedDirName(std.testing.allocator, .aarch64, 35, "/other-ndk") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(other_ndk);
    const rv = try mergedDirName(std.testing.allocator, .riscv64, 35, "/ndk") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(rv);

    try std.testing.expect(!std.mem.eql(u8, a1, a2));
    try std.testing.expect(!std.mem.eql(u8, a1, other_ndk));
    try std.testing.expect(!std.mem.eql(u8, a1, rv));
    try std.testing.expect(std.mem.eql(u8, a1, a1));
    try std.testing.expect((try mergedDirName(std.testing.allocator, .mips, 35, "/ndk")) == null);
}

test "Android target arch names" {
    try std.testing.expectEqualStrings("aarch64-linux-android", targetArchName(.aarch64).?);
    try std.testing.expectEqualStrings("x86_64-linux-android", targetArchName(.x86_64).?);
    try std.testing.expectEqualStrings("arm-linux-androideabi", targetArchName(.arm).?);
    try std.testing.expectEqualStrings("arm-linux-androideabi", targetArchName(.thumb).?);
    try std.testing.expectEqualStrings("i686-linux-android", targetArchName(.x86).?);
    try std.testing.expectEqualStrings("riscv64-linux-android", targetArchName(.riscv64).?);
    try std.testing.expect(targetArchName(.mips) == null);
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

test "compiler-rt arch names" {
    try std.testing.expectEqualStrings("aarch64", builtinsName(.aarch64).?);
    try std.testing.expectEqualStrings("x86_64", builtinsName(.x86_64).?);
    try std.testing.expectEqualStrings("i686", builtinsName(.x86).?);
    try std.testing.expectEqualStrings("arm", builtinsName(.arm).?);
    try std.testing.expectEqualStrings("arm", builtinsName(.thumb).?);
    try std.testing.expectEqualStrings("riscv64", builtinsName(.riscv64).?);
    try std.testing.expect(builtinsName(.mips) == null);
}

test "unwind dir names" {
    try std.testing.expectEqualStrings("aarch64", unwindDir(.aarch64).?);
    try std.testing.expectEqualStrings("x86_64", unwindDir(.x86_64).?);
    try std.testing.expectEqualStrings("i386", unwindDir(.x86).?);
    try std.testing.expectEqualStrings("arm", unwindDir(.arm).?);
    try std.testing.expectEqualStrings("arm", unwindDir(.thumb).?);
    try std.testing.expectEqualStrings("riscv64", unwindDir(.riscv64).?);
    try std.testing.expect(unwindDir(.mips) == null);
}

test "arch name sets agree" {
    const supported = [_]std.Target.Cpu.Arch{ .aarch64, .x86_64, .x86, .arm, .thumb, .riscv64 };
    for (supported) |arch| {
        try std.testing.expect(targetArchName(arch) != null);
        try std.testing.expect(builtinsName(arch) != null);
        try std.testing.expect(unwindDir(arch) != null);
    }

    try std.testing.expect(targetArchName(.mips) == null);
    try std.testing.expect(builtinsName(.mips) == null);
    try std.testing.expect(unwindDir(.mips) == null);
}

test "copyIfMissing copies once and preserves existing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "payload" });
    try tmp.dir.writeFile(io, .{ .sub_path = "exists.txt", .data = "original" });

    try std.testing.expect(copyIfMissing(io, tmp.dir, "src.txt", tmp.dir, "dst.txt"));
    const copied = try tmp.dir.readFileAlloc(io, "dst.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("payload", copied);

    try std.testing.expect(copyIfMissing(io, tmp.dir, "src.txt", tmp.dir, "exists.txt"));
    const unchanged = try tmp.dir.readFileAlloc(io, "exists.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("original", unchanged);

    try std.testing.expect(!copyIfMissing(io, tmp.dir, "missing.txt", tmp.dir, "dst2.txt"));
}
