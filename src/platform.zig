const std = @import("std");

pub const Error = error{
    SysrootNotFound,
    LibCRenderFailed,
    OutOfMemory,
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
    compile.root_module.addSystemIncludePath(.{ .cwd_relative = sysroot.include });
    compile.root_module.addSystemIncludePath(.{ .cwd_relative = sysroot.include_arch });
    for (sysroot.lib) |lib| {
        compile.root_module.addLibraryPath(.{ .cwd_relative = lib });
    }
    compile.setLibCFile(libc_file);
}

pub fn configureTranslateC(translate_c: *std.Build.Step.TranslateC, sysroot: Sysroot) void {
    translate_c.addSystemIncludePath(.{ .cwd_relative = sysroot.include });
    translate_c.addSystemIncludePath(.{ .cwd_relative = sysroot.include_arch });
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
    crt_dir: []const u8,
    conf_name: []const u8,
) Error!std.Build.LazyPath {
    var writer = std.Io.Writer.Allocating.init(b.allocator);
    defer writer.deinit();

    const libc_installation = std.zig.LibCInstallation{
        .include_dir = include_dir,
        .sys_include_dir = sys_include_dir,
        .crt_dir = crt_dir,
    };

    libc_installation.render(&writer.writer) catch |err| {
        std.log.err("Failed to render {s} libc installation configuration: {s}", .{ conf_name, @errorName(err) });
        return Error.LibCRenderFailed;
    };

    return b.addWriteFiles().add(conf_name, writer.written());
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

pub fn parseVersion(name: []const u8) ?[3]u32 {
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

pub fn versionNewer(a: [3]u32, b: [3]u32) bool {
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
    const subdir = try std.fmt.bufPrint(&path_buf, "{s}{c}subdir", .{ root, std.fs.path.sep });
    try std.testing.expect(dirExists(io, subdir));

    const file_path = try std.fmt.bufPrint(&path_buf, "{s}{c}file.txt", .{ root, std.fs.path.sep });
    try std.testing.expect(!dirExists(io, file_path));
    try std.testing.expect(pathExists(io, file_path));

    const missing = try std.fmt.bufPrint(&path_buf, "{s}{c}missing", .{ root, std.fs.path.sep });
    try std.testing.expect(!dirExists(io, missing));
    try std.testing.expect(!pathExists(io, missing));

    try checkDir(io, root, "root");
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
