const std = @import("std");

const modules = .{
    @import("target.zig"),
    @import("platform.zig"),
    @import("android.zig"),
    @import("ohos.zig"),
    @import("emscripten.zig"),
};

test {
    inline for (modules) |m| std.testing.refAllDecls(m);
}
