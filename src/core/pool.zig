const std = @import("std");

pub const max_threads = 16;

pub const Pool = struct {
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.SinglyLinkedList = .{},
    running: bool = true,
    threads: [max_threads]std.Thread = undefined,
    n_threads: usize = 0,

    const Runnable = struct {
        node: std.SinglyLinkedList.Node = .{},
        run: *const fn (*Runnable, *std.heap.ArenaAllocator) void,
    };

    pub fn init(self: *Pool, allocator: std.mem.Allocator, io: std.Io, n_jobs: ?usize) !void {
        self.* = .{ .allocator = allocator, .io = io };
        errdefer self.deinit();
        const n = @max(1, @min(max_threads, n_jobs orelse (std.Thread.getCpuCount() catch 1)));
        while (self.n_threads < n) : (self.n_threads += 1) {
            self.threads[self.n_threads] = try std.Thread.spawn(.{}, worker, .{self});
        }
    }

    fn worker(self: *Pool) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            if (self.queue.popFirst()) |node| {
                const job: *Runnable = @fieldParentPtr("node", node);
                self.mutex.unlock(self.io);
                job.run(job, &arena);
                _ = arena.reset(.retain_capacity);
                self.mutex.lockUncancelable(self.io);
            } else if (!self.running) {
                return;
            } else {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
        }
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.running = false;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.threads[0..self.n_threads]) |thread| thread.join();
    }

    pub fn scope(self: *Pool) Scope {
        return .{ .pool = self };
    }
};

pub const Scope = struct {
    pool: *Pool,
    pending: usize = 0,

    pub fn spawn(self: *Scope, comptime func: anytype, args: anytype) void {
        const Closure = struct {
            arguments: @TypeOf(args),
            scope: *Scope,
            runnable: Pool.Runnable = .{ .run = run },

            fn run(runnable: *Pool.Runnable, arena: *std.heap.ArenaAllocator) void {
                const closure: *@This() = @fieldParentPtr("runnable", runnable);
                @call(.auto, func, .{arena} ++ closure.arguments);
                const scope = closure.scope;
                const pool = scope.pool;
                pool.mutex.lockUncancelable(pool.io);
                defer pool.mutex.unlock(pool.io);
                pool.allocator.destroy(closure);
                scope.pending -= 1;
                if (scope.pending == 0) pool.cond.broadcast(pool.io);
            }
        };
        const pool = self.pool;
        pool.mutex.lockUncancelable(pool.io);
        const closure = pool.allocator.create(Closure) catch {
            pool.mutex.unlock(pool.io);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            @call(.auto, func, .{&arena} ++ args);
            return;
        };
        closure.* = .{ .arguments = args, .scope = self };
        self.pending += 1;
        pool.queue.prepend(&closure.runnable.node);
        pool.cond.signal(pool.io);
        pool.mutex.unlock(pool.io);
    }

    pub fn wait(self: *Scope) void {
        const pool = self.pool;
        pool.mutex.lockUncancelable(pool.io);
        defer pool.mutex.unlock(pool.io);
        while (self.pending != 0) pool.cond.waitUncancelable(pool.io, &pool.mutex);
    }
};

test "pool drains queued jobs and falls back on allocation failure" {
    const Job = struct {
        fn run(arena: *std.heap.ArenaAllocator, count: *std.atomic.Value(usize)) void {
            const buf = arena.allocator().alloc(u8, 1024) catch unreachable;
            @memset(buf, 42);
            _ = count.fetchAdd(1, .monotonic);
        }
    };
    var count = std.atomic.Value(usize).init(0);
    {
        var pool: Pool = .{};
        try pool.init(std.testing.allocator, std.testing.io, 3);
        var scope = pool.scope();
        for (0..1000) |_| scope.spawn(Job.run, .{&count});
        pool.deinit();
        try std.testing.expectEqual(@as(usize, 1000), count.load(.monotonic));
    }
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var pool: Pool = .{};
        try pool.init(failing.allocator(), std.testing.io, 1);
        defer pool.deinit();
        var scope = pool.scope();
        scope.spawn(Job.run, .{&count});
        scope.wait();
        try std.testing.expectEqual(@as(usize, 1001), count.load(.monotonic));
    }
}

test "scope fork join" {
    var p: Pool = .{};
    try p.init(std.testing.allocator, std.testing.io, 2);
    defer p.deinit();

    var s = p.scope();
    var x: usize = 0;
    var m: std.Io.Mutex = .init;

    const Job = struct {
        fn run(_: *std.heap.ArenaAllocator, mutex: *std.Io.Mutex, n: *usize) void {
            mutex.lockUncancelable(std.testing.io);
            n.* += 1;
            mutex.unlock(std.testing.io);
        }
    };

    s.spawn(Job.run, .{ &m, &x });
    s.spawn(Job.run, .{ &m, &x });
    s.wait();
    try std.testing.expectEqual(@as(usize, 2), x);
}
