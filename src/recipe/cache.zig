const std = @import("std");
const Recipe = @import("Recipe.zig").Recipe;

/// Cache recipe - cache files and directories to speed up builds
///
/// Supported parameters:
/// - action (required): "restore" or "save"
/// - key (required): Cache key identifier (e.g., "node-modules-v1")
/// - paths (required): Comma-separated list of paths to cache
/// - cache_dir: Directory to store cache (default: "~/.cache/stringr")
pub const Cache = struct {
    config: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) !Cache {
        return Cache{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *Cache, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
        const action = self.config.get("action") orelse return error.MissingCacheAction;
        const key = self.config.get("key") orelse return error.MissingCacheKey;
        const paths = self.config.get("paths") orelse return error.MissingCachePaths;

        // Track if we allocated cache_dir so we can free it later
        var cache_dir_allocated: ?[]const u8 = null;
        defer if (cache_dir_allocated) |cd| allocator.free(cd);

        const cache_dir = self.config.get("cache_dir") orelse blk: {
            const home = std.posix.getenv("HOME") orelse ".";
            if (std.fmt.allocPrint(allocator, "{s}/.cache/stringr", .{home})) |dir| {
                cache_dir_allocated = dir;
                break :blk dir;
            } else |_| {
                break :blk ".cache/stringr";
            }
        };

        try writer.print("Cache {s}: key={s}\n", .{ action, key });

        if (std.mem.eql(u8, action, "restore")) {
            // Restore cache
            const cache_file = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ cache_dir, key });
            defer allocator.free(cache_file);

            const cache_exists = blk: {
                std.fs.cwd().access(cache_file, .{}) catch {
                    break :blk false;
                };
                break :blk true;
            };

            if (!cache_exists) {
                try writer.print("Cache miss: {s} not found\n", .{key});
                return;
            }

            try writer.print("Cache hit: restoring from {s}\n", .{cache_file});

            var restore_args = [_][]const u8{ "tar", "xzf", cache_file };
            var child = std.process.Child.init(&restore_args, allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            try child.spawn();

            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(allocator);

            try child.collectOutput(allocator, &stdout_buffer, &stderr_buffer, 10 * 1024 * 1024);
            const term = try child.wait();

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        try writer.print("Cache restore failed with exit code {d}\n", .{code});
                        if (stderr_buffer.items.len > 0) {
                            try writer.print("{s}", .{stderr_buffer.items});
                        }
                        return error.CacheRestoreFailed;
                    }
                },
                else => {
                    try writer.print("Cache restore terminated abnormally\n", .{});
                    return error.CacheRestoreFailed;
                },
            }

            try writer.print("Cache restored successfully\n", .{});
        } else if (std.mem.eql(u8, action, "save")) {
            // Save cache
            try std.fs.cwd().makePath(cache_dir);

            const cache_file = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ cache_dir, key });
            defer allocator.free(cache_file);

            try writer.print("Saving cache to {s}\n", .{cache_file});

            var save_args: std.ArrayList([]const u8) = .empty;
            defer save_args.deinit(allocator);

            try save_args.append(allocator, "tar");
            try save_args.append(allocator, "czf");
            try save_args.append(allocator, cache_file);

            // Add all paths to archive
            var path_iter = std.mem.splitSequence(u8, paths, ",");
            while (path_iter.next()) |path| {
                const trimmed = std.mem.trim(u8, path, " ");
                if (trimmed.len > 0) {
                    // Check if path exists before adding
                    std.fs.cwd().access(trimmed, .{}) catch {
                        try writer.print("Warning: path {s} does not exist, skipping\n", .{trimmed});
                        continue;
                    };
                    try save_args.append(allocator, trimmed);
                }
            }

            if (save_args.items.len <= 3) {
                try writer.print("No valid paths to cache\n", .{});
                return;
            }

            var child = std.process.Child.init(save_args.items, allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            try child.spawn();

            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(allocator);

            try child.collectOutput(allocator, &stdout_buffer, &stderr_buffer, 10 * 1024 * 1024);
            const term = try child.wait();

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        try writer.print("Cache save failed with exit code {d}\n", .{code});
                        if (stderr_buffer.items.len > 0) {
                            try writer.print("{s}", .{stderr_buffer.items});
                        }
                        return error.CacheSaveFailed;
                    }
                },
                else => {
                    try writer.print("Cache save terminated abnormally\n", .{});
                    return error.CacheSaveFailed;
                },
            }

            try writer.print("Cache saved successfully\n", .{});
        } else {
            try writer.print("Invalid cache action: {s} (must be 'restore' or 'save')\n", .{action});
            return error.InvalidCacheAction;
        }
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
        // Config is owned by caller, no cleanup needed
    }

    // VTable implementation
    fn initVTable(ptr: *anyopaque, allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) anyerror!void {
        const self: *Cache = @ptrCast(@alignCast(ptr));
        const cache = try Cache.init(allocator, config);
        self.* = cache;
    }

    fn runVTable(ptr: *anyopaque, allocator: std.mem.Allocator, writer: *std.Io.Writer) anyerror!void {
        const self: *Cache = @ptrCast(@alignCast(ptr));
        try self.run(allocator, writer);
    }

    fn deinitVTable(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Cache = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub const vtable = Recipe.VTable{
        .init = initVTable,
        .run = runVTable,
        .deinit = deinitVTable,
    };

    pub fn recipe(self: *Cache) Recipe {
        return Recipe{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

test "cache recipe" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var config = std.StringHashMap([]const u8).init(allocator);
    defer config.deinit();

    try config.put("action", "save");
    try config.put("key", "test-cache");
    try config.put("paths", ".zig-cache");

    var cache = try Cache.init(allocator, config);
    defer cache.deinit(allocator);

    try testing.expectEqual(true, cache.config.contains("action"));
}
