const std = @import("std");
const builtin = @import("builtin");
const opt = @import("opt");
const run = @import("run.zig");
const build_options = @import("build_options");

const version = build_options.version;
const Options = run.Options;

fn usage(io: std.Io) void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    opt.printUsage(Options, &stdout.interface);
    stdout.interface.flush() catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // libc malloc has per-thread caches; the debug allocator serializes every
    // path dupe/job closure on one mutex (~40% of walk time on big trees).
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .debug) {
        _ = dbg.deinit();
    };
    const allocator = if (builtin.mode == .debug) dbg.allocator() else std.heap.c_allocator;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const args = argv[1..];
    if (args.len == 0) {
        usage(io);
        return;
    }

    var options = Options{};
    var positional_buf: [65][]const u8 = undefined;
    const rest = opt.parse(Options, &options, args, &positional_buf) catch |e| switch (e) {
        error.Help => {
            usage(io);
            return;
        },
        error.UnknownOption, error.MissingValue, error.InvalidValue, error.TooManyPositionals, error.TooManyValues => std.process.exit(1),
        else => return e,
    };

    if (options.version) {
        var buf: [64]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buf);
        stdout.interface.print("zeegrep {s}\n", .{version}) catch {};
        stdout.interface.flush() catch {};
        return;
    }

    if (rest.len == 0) {
        usage(io);
        return;
    }
    const pattern = rest[0];

    const paths = rest[1..];

    var write_buf: [8 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &write_buf);
    run.run(allocator, io, init.environ_map.get("NO_COLOR") != null, &stdout.interface, options, pattern, paths) catch |e| switch (e) {
        error.NoMatches => {
            stdout.interface.flush() catch {};
            std.process.exit(1);
        },
        else => {
            stdout.interface.flush() catch {};
            std.process.exit(2);
        },
    };
    stdout.interface.flush() catch {};
}
