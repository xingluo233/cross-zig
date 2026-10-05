const std = @import("std");

pub const Error = error{
    SysrootNotFound,
    LibCRenderFailed,
    CacheDirUnavailable,
    CrtShimUnavailable,
};

pub const Macro = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const Sysroot = struct {
    include: []const u8,
    include_arch: []const u8,
    lib: []const []const u8 = &.{},
};

pub fn configureCompile(
    compile: *std.Build.Step.Compile,
    sysroot: Sysroot,
    libc_file: std.Build.LazyPath,
) void {
    const graph = compile.step.owner.graph;
    compile.root_module.addSystemIncludePath(graph.cwdRelativePath(sysroot.include));
    compile.root_module.addSystemIncludePath(graph.cwdRelativePath(sysroot.include_arch));
    for (sysroot.lib) |lib| {
        compile.root_module.addLibraryPath(graph.cwdRelativePath(lib));
    }
    compile.setLibCFile(libc_file);
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, sysroot: Sysroot) void {
    const graph = translate_c.step.owner.graph;
    translate_c.addSystemIncludePath(graph.cwdRelativePath(sysroot.include));
    translate_c.addSystemIncludePath(graph.cwdRelativePath(sysroot.include_arch));
}

pub fn applyCompileMacros(compile: *std.Build.Step.Compile, macros: []const Macro) void {
    for (macros) |m| {
        compile.root_module.addCMacro(m.name, m.value orelse "1");
    }
}

pub fn applyTranslateCMacros(translate_c: *std.Build.Step.TranslateC, macros: []const Macro) void {
    for (macros) |m| {
        translate_c.defineCMacro(m.name, m.value);
    }
}

pub fn createLibCConfig(
    b: *std.Build,
    include_dir: []const u8,
    sys_include_dir: []const u8,
    cc_dir: []const u8,
    crt_dir: []const u8,
    conf_name: []const u8,
) Error!std.Build.LazyPath {
    var writer = std.Io.Writer.Allocating.init(b.allocator);
    defer writer.deinit();

    const libc_installation = std.zig.LibCInstallation{
        .include_dir = include_dir,
        .sys_include_dir = sys_include_dir,
        .cc_dir = cc_dir,
        .crt_dir = crt_dir,
    };

    libc_installation.render(&writer.writer) catch |err| {
        std.log.err("Failed to render {s} libc installation configuration: {s}", .{ conf_name, @errorName(err) });
        return Error.LibCRenderFailed;
    };

    return b.addWriteFiles().add(conf_name, writer.written());
}

const local_cache_basename = ".zig-cache";
const staging_basename = "tmp";

pub fn openStagingDir(b: *std.Build) Error!std.Io.Dir {
    const io = b.graph.io;
    const cache_dir = b.root.root_dir.handle.createDirPathOpen(io, local_cache_basename, .{}) catch |err| {
        std.log.err(
            "unable to open the local cache directory '{s}': {s}",
            .{ local_cache_basename, @errorName(err) },
        );
        return Error.CacheDirUnavailable;
    };
    defer cache_dir.close(io);

    return cache_dir.createDirPathOpen(io, staging_basename, .{}) catch |err| {
        std.log.err(
            "unable to open the staging directory '{s}{c}{s}': {s}",
            .{ local_cache_basename, std.Io.Dir.path.sep, staging_basename, @errorName(err) },
        );
        return Error.CacheDirUnavailable;
    };
}

pub fn stagingPath(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.root.root_dir.join(b.allocator, &.{ local_cache_basename, staging_basename, sub_path }) catch @panic("OOM");
}

pub const CrtFileMapping = struct {
    src: []const u8,
    dst: []const u8,
};

pub fn crtShimDir(
    b: *std.Build,
    dir_name: []const u8,
    source_dir: []const u8,
    mappings: []const CrtFileMapping,
) Error![]const u8 {
    const io = b.graph.io;

    const cache_dir = try openStagingDir(b);
    defer cache_dir.close(io);

    const shim_dir = cache_dir.createDirPathOpen(io, dir_name, .{}) catch |err| {
        std.log.err("failed to open the crt shim directory {s}: {s}", .{ dir_name, @errorName(err) });
        return Error.CrtShimUnavailable;
    };
    defer shim_dir.close(io);

    var src_dir = std.Io.Dir.openDirAbsolute(io, source_dir, .{}) catch |err| {
        std.log.err("failed to open crt source directory {s}: {s}", .{ source_dir, @errorName(err) });
        return Error.CrtShimUnavailable;
    };
    defer src_dir.close(io);

    for (mappings) |mapping| {
        copyFileIfMissing(io, src_dir, mapping.src, shim_dir, mapping.dst) catch |err| {
            std.log.err("failed to copy {s} to {s}: {s}", .{ mapping.src, mapping.dst, @errorName(err) });
            return Error.CrtShimUnavailable;
        };
    }

    return stagingPath(b, dir_name);
}

pub fn copyFileIfMissing(
    io: std.Io,
    src_dir: std.Io.Dir,
    src_name: []const u8,
    dst_dir: std.Io.Dir,
    dst_name: []const u8,
) !void {
    dst_dir.access(io, dst_name, .{}) catch
        return std.Io.Dir.copyFile(src_dir, src_name, dst_dir, dst_name, io, .{});
}

pub fn findNewestVersionedSubdir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    extra_parts: []const []const u8,
) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    const parts = allocator.alloc([]const u8, extra_parts.len + 2) catch @panic("OOM");
    defer allocator.free(parts);
    parts[0] = root;
    @memcpy(parts[2..], extra_parts);

    const Best = struct { version: [3]u32, path: []const u8 };
    var best: ?Best = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        const version = parseVersion(entry.name) orelse continue;
        parts[1] = entry.name;
        const candidate = std.Io.Dir.path.join(allocator, parts) catch @panic("OOM");
        if (!dirExists(io, candidate)) {
            allocator.free(candidate);
            continue;
        }
        if (best == null or versionNewer(version, best.?.version)) {
            if (best) |old| allocator.free(old.path);
            best = .{ .version = version, .path = candidate };
        } else {
            allocator.free(candidate);
        }
    }

    return if (best) |found| found.path else null;
}

pub fn dirExists(io: std.Io, path: []const u8) bool {
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn parseVersion(name: []const u8) ?[3]u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var idx: usize = 0;
    var it = std.mem.tokenizeScalar(u8, name, '.');
    while (it.next()) |part| {
        if (idx >= parts.len) return null;
        parts[idx] = std.fmt.parseUnsigned(u32, part, 10) catch return null;
        idx += 1;
    }
    if (idx == 0) return null;
    return parts;
}

fn versionNewer(a: [3]u32, b: [3]u32) bool {
    for (a, b) |x, y| {
        if (x != y) return x > y;
    }
    return false;
}

test "parseVersion: edge cases" {
    try std.testing.expectEqual(@as(?[3]u32, .{ 0, 0, 0 }), parseVersion("0"));
    try std.testing.expectEqual(@as(?[3]u32, .{ 1, 2, 0 }), parseVersion("1.2"));
    try std.testing.expectEqual(@as(?[3]u32, .{ 12, 34, 56 }), parseVersion("12.34.56"));
    try std.testing.expectEqual(@as(?[3]u32, .{ 1, 0, 0 }), parseVersion("01"));

    try std.testing.expectEqual(@as(?[3]u32, .{ 1, 2, 0 }), parseVersion("1..2"));
    try std.testing.expect(parseVersion("v1") == null);
    try std.testing.expect(parseVersion("-1") == null);
    try std.testing.expect(parseVersion("1.2x") == null);
    try std.testing.expect(parseVersion(" 1") == null);
    try std.testing.expect(parseVersion("1.2.3.4") == null);
    try std.testing.expect(parseVersion("") == null);
}

test "versionNewer: ordering edge cases" {
    try std.testing.expect(!versionNewer(.{ 0, 0, 0 }, .{ 0, 0, 0 }));
    try std.testing.expect(versionNewer(.{ 0, 0, 1 }, .{ 0, 0, 0 }));
    try std.testing.expect(!versionNewer(.{ 0, 1, 0 }, .{ 0, 1, 0 }));
    try std.testing.expect(versionNewer(.{ 2, 0, 0 }, .{ 1, 99, 99 }));
}

test "fs helpers on real paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDirPath(io, "subdir");

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    try std.testing.expect(dirExists(io, root));
    try std.testing.expect(pathExists(io, root));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const subdir = try std.mem.print(&path_buf, "{s}{c}subdir", .{ root, std.Io.Dir.path.sep });
    try std.testing.expect(dirExists(io, subdir));

    const file_path = try std.mem.print(&path_buf, "{s}{c}file.txt", .{ root, std.Io.Dir.path.sep });
    try std.testing.expect(!dirExists(io, file_path));
    try std.testing.expect(pathExists(io, file_path));

    const missing = try std.mem.print(&path_buf, "{s}{c}missing", .{ root, std.Io.Dir.path.sep });
    try std.testing.expect(!dirExists(io, missing));
    try std.testing.expect(!pathExists(io, missing));

    try checkDir(io, root, "root");
}

test "copyFileIfMissing copies once and preserves existing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "payload" });
    try tmp.dir.writeFile(io, .{ .sub_path = "exists.txt", .data = "original" });

    try copyFileIfMissing(io, tmp.dir, "src.txt", tmp.dir, "dst.txt");
    const copied = try tmp.dir.readFileAlloc(io, "dst.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("payload", copied);

    try copyFileIfMissing(io, tmp.dir, "src.txt", tmp.dir, "exists.txt");
    const unchanged = try tmp.dir.readFileAlloc(io, "exists.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("original", unchanged);

    try std.testing.expectError(error.FileNotFound, copyFileIfMissing(io, tmp.dir, "missing.txt", tmp.dir, "dst2.txt"));
}

test "findNewestVersionedSubdir picks the newest complete match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try tmp.dir.createDirPath(io, "17/lib/linux");
    try tmp.dir.createDirPath(io, "18.1.0/lib/linux");
    try tmp.dir.createDirPath(io, "19/lib");
    try tmp.dir.createDirPath(io, "notaversion/lib/linux");
    try tmp.dir.writeFile(io, .{ .sub_path = "20", .data = "a file, not a version dir" });

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const found = findNewestVersionedSubdir(allocator, io, root, &.{ "lib", "linux" });
    try std.testing.expect(found != null);
    defer allocator.free(found.?);

    const expected = try std.Io.Dir.path.join(allocator, &.{ root, "18.1.0", "lib", "linux" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, found.?);

    try tmp.dir.createDirPath(io, "21/lib");
    const other = findNewestVersionedSubdir(allocator, io, root, &.{"lib"});
    try std.testing.expect(other != null);
    defer allocator.free(other.?);
    const expected_other = try std.Io.Dir.path.join(allocator, &.{ root, "21", "lib" });
    defer allocator.free(expected_other);
    try std.testing.expectEqualStrings(expected_other, other.?);

    const missing_root = try std.Io.Dir.path.join(allocator, &.{ root, "does-not-exist" });
    defer allocator.free(missing_root);
    try std.testing.expect(findNewestVersionedSubdir(allocator, io, missing_root, &.{"lib"}) == null);
}

pub fn checkDir(io: std.Io, path: []const u8, label: []const u8) Error!void {
    if (dirExists(io, path)) return;
    if (pathExists(io, path)) {
        std.log.err("{s} is not a directory: {s}", .{ label, path });
    } else {
        std.log.err("{s} not accessible: {s}", .{ label, path });
    }
    return Error.SysrootNotFound;
}

pub fn requireEnvDir(b: *std.Build, env_var: []const u8, label: []const u8) Error![]const u8 {
    const value = b.graph.environ_map.get(env_var) orelse {
        std.log.err("Environment variable '{s}' is not set (needed to locate {s}).", .{ env_var, label });
        return Error.SysrootNotFound;
    };
    try checkDir(b.graph.io, value, env_var);
    return value;
}
