const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();

    const include_dir = try nextAbsolutePath(&args);
    const sys_include_dir = try nextAbsolutePath(&args);
    const cc_dir = try nextAbsolutePath(&args);
    const crt_dir = try nextAbsolutePath(&args);
    const out_path = try nextAbsolutePath(&args);

    const libc: std.zig.LibCInstallation = .{
        .include_dir = include_dir,
        .sys_include_dir = sys_include_dir,
        .cc_dir = cc_dir,
        .crt_dir = crt_dir,
    };

    var rendered: std.Io.Writer.Allocating = .init(arena);
    defer rendered.deinit();
    try libc.render(&rendered.writer);

    var file = try std.Io.Dir.createFileAbsolute(io, out_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, rendered.written());
}

fn nextAbsolutePath(args: *std.process.Args.Iterator) ![]const u8 {
    const value = args.next() orelse return error.MissingArgument;
    if (!std.Io.Dir.path.isAbsolute(value)) {
        std.log.err(
            "expected an absolute path, got '{s}'; the build runner must honor make_absolute = true for the cross-libc-conf arguments",
            .{value},
        );
        return error.AbsolutePathRequired;
    }
    return value;
}
