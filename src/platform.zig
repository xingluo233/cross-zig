const std = @import("std");

pub const Error = error{
    SysrootNotFound,
};

pub const Macro = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const Sysroot = struct {
    include: std.Build.LazyPath,

    include_arch: ?std.Build.LazyPath = null,
    lib: []const std.Build.LazyPath = &.{},
};

pub fn configureCompile(
    compile: *std.Build.Step.Compile,
    sysroot: Sysroot,
    libc_file: std.Build.LazyPath,
) void {
    compile.root_module.addSystemIncludePath(sysroot.include);
    if (sysroot.include_arch) |include_arch| {
        compile.root_module.addSystemIncludePath(include_arch);
    }
    for (sysroot.lib) |lib| {
        compile.root_module.addLibraryPath(lib);
    }
    compile.setLibCFile(libc_file);
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, sysroot: Sysroot) void {
    translate_c.addSystemIncludePath(sysroot.include);
    if (sysroot.include_arch) |include_arch| {
        translate_c.addSystemIncludePath(include_arch);
    }
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
    include_dir: std.Build.LazyPath,
    sys_include_dir: std.Build.LazyPath,
    cc_dir: std.Build.LazyPath,
    crt_dir: std.Build.LazyPath,
    conf_name: []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(libcConfWriter(b));

    run.addDirectoryArg2(include_dir, .{ .make_absolute = true });
    run.addDirectoryArg2(sys_include_dir, .{ .make_absolute = true });
    run.addDirectoryArg2(cc_dir, .{ .make_absolute = true });
    run.addDirectoryArg2(crt_dir, .{ .make_absolute = true });
    return run.addOutputFileArg2(conf_name, .{ .make_absolute = true });
}

fn libcConfWriter(b: *std.Build) *std.Build.Step.Compile {
    const source = b.addWriteFiles().add("libc_conf.zig", @embedFile("libc_conf.zig"));
    return b.addExecutable(.{
        .name = "cross-libc-conf",
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
}

pub const CrtFileMapping = struct {
    src: []const u8,
    dst: []const u8,
};

pub fn crtShimDir(
    b: *std.Build,
    source_dir: []const u8,
    mappings: []const CrtFileMapping,
) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    wf.step.name = b.fmt("Copy crt shim ({s})", .{std.Io.Dir.path.basename(source_dir)});
    for (mappings) |mapping| {
        _ = wf.addCopyFile(b.graph.cwdRelativePath(b.pathJoin(&.{ source_dir, mapping.src })), mapping.dst);
    }
    return wf.getDirectory();
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
    try checkDirTracked(b, value, env_var);
    return value;
}

pub fn trackDir(b: *std.Build, path: []const u8) void {
    b.dependOnDirectoryMetadata(b.graph.cwdRelativePath(path));
}

pub fn checkDirTracked(b: *std.Build, path: []const u8, label: []const u8) Error!void {
    trackDir(b, path);
    return checkDir(b.graph.io, path, label);
}
