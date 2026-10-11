const std = @import("std");
const Timer = @This();

io: std.Io,
started: std.Io.Timestamp,

pub fn start(io: std.Io) Timer {
    return .{ .io = io, .started = std.Io.Clock.awake.now(io) };
}

pub fn read(self: *const Timer) u64 {
    return @intCast(self.started.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds());
}

pub fn reset(self: *Timer) void {
    self.started = std.Io.Clock.awake.now(self.io);
}

test "read elapsed nanoseconds and reset" {
    const Fake = struct {
        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            std.debug.assert(clock == .awake);
            const ns: *i96 = @ptrCast(@alignCast(userdata.?));
            return .fromNanoseconds(ns.*);
        }
    };
    var ns: i96 = 100;
    var vtable = std.testing.io.vtable.*;
    vtable.now = Fake.now;
    var timer = start(.{ .userdata = &ns, .vtable = &vtable });
    ns = 150;
    try std.testing.expectEqual(@as(u64, 50), timer.read());
    try std.testing.expectEqual(@as(u64, 50), timer.read());
    timer.reset();
    try std.testing.expectEqual(@as(u64, 0), timer.read());
    ns = 175;
    try std.testing.expectEqual(@as(u64, 25), timer.read());
}
