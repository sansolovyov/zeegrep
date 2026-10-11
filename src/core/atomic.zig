const std = @import("std");

pub fn replaceFileAtomic(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    var file = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    file.file.sync(io) catch {};
    try file.replace(io);
}

test "atomic replace writes bytes" {
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    try td.dir.writeFile(std.testing.io, .{ .sub_path = "x.txt", .data = "old\n" });
    try replaceFileAtomic(std.testing.io, td.dir, "x.txt", "new\n");

    var buf: [16]u8 = undefined;
    const got = try td.dir.readFile(std.testing.io, "x.txt", &buf);
    try std.testing.expectEqualStrings("new\n", got);
}
