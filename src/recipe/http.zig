const std = @import("std");
const Recipe = @import("Recipe.zig").Recipe;

const log = std.log.scoped(.http);

/// HTTP recipe - make HTTP requests (webhooks, API calls, etc.)
///
/// Supported parameters:
/// - url (required): URL to request
/// - method: HTTP method (GET, POST, PUT, DELETE, PATCH) (default: "GET")
/// - headers: Comma-separated headers (e.g., "Content-Type: application/json, Authorization: Bearer token")
/// - body: Request body (for POST, PUT, PATCH)
/// - body_file: Path to file containing request body
/// - output: File path to save response to
/// - fail_on_error: "true" or "false" - fail if HTTP status >= 400 (default: "true")
/// - timeout: Request timeout in seconds (default: "30")
pub const Http = struct {
    config: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) !Http {
        return Http{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *Http, allocator: std.mem.Allocator) !void {
        const url = self.config.get("url") orelse return error.MissingHttpUrl;
        const method = self.config.get("method") orelse "GET";
        const headers = self.config.get("headers");
        const body = self.config.get("body");
        const body_file = self.config.get("body_file");
        const output = self.config.get("output");
        const fail_on_error = self.config.get("fail_on_error") orelse "true";
        const timeout = self.config.get("timeout") orelse "30";

        log.info("HTTP {s} {s}", .{ method, url });

        var curl_args: std.ArrayList([]const u8) = .empty;
        defer curl_args.deinit(allocator);

        try curl_args.append(allocator, "curl");
        try curl_args.append(allocator, "-X");
        try curl_args.append(allocator, method);

        // Timeout
        try curl_args.append(allocator, "--max-time");
        try curl_args.append(allocator, timeout);

        // Show response headers
        try curl_args.append(allocator, "-i");

        // Follow redirects
        try curl_args.append(allocator, "-L");

        // Fail on HTTP errors (4xx, 5xx)
        if (std.mem.eql(u8, fail_on_error, "true")) {
            try curl_args.append(allocator, "-f");
        }

        // Headers
        if (headers) |header_list| {
            var header_iter = std.mem.splitSequence(u8, header_list, ",");
            while (header_iter.next()) |header| {
                const trimmed = std.mem.trim(u8, header, " ");
                if (trimmed.len > 0) {
                    try curl_args.append(allocator, "-H");
                    try curl_args.append(allocator, trimmed);
                }
            }
        }

        // Body
        if (body) |b| {
            try curl_args.append(allocator, "-d");
            try curl_args.append(allocator, b);
        } else if (body_file) |bf| {
            try curl_args.append(allocator, "-d");
            const file_data = try std.fmt.allocPrint(allocator, "@{s}", .{bf});
            try curl_args.append(allocator, file_data);
        }

        // Output to file
        if (output) |out| {
            try curl_args.append(allocator, "-o");
            try curl_args.append(allocator, out);
            log.info("Saving response to: {s}", .{out});
        }

        // URL (must be last)
        try curl_args.append(allocator, url);

        var child = std.process.Child.init(curl_args.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var stdout_buffer: std.ArrayList(u8) = .empty;
        defer stdout_buffer.deinit(allocator);
        var stderr_buffer: std.ArrayList(u8) = .empty;
        defer stderr_buffer.deinit(allocator);

        try child.collectOutput(allocator, &stdout_buffer, &stderr_buffer, 10 * 1024 * 1024);
        const term = try child.wait();

        if (stdout_buffer.items.len > 0 and output == null) {
            log.info("{s}", .{stdout_buffer.items});
        }
        if (stderr_buffer.items.len > 0) {
            log.err("{s}", .{stderr_buffer.items});
        }

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    log.err("HTTP request failed with exit code {d}", .{code});
                    return error.HttpRequestFailed;
                }
            },
            else => {
                log.err("HTTP request terminated abnormally", .{});
                return error.HttpRequestFailed;
            },
        }

        log.info("HTTP request completed successfully", .{});
    }

    pub fn deinit(self: *Http, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
        // Config is owned by caller, no cleanup needed
    }

    // VTable implementation
    fn initVTable(ptr: *anyopaque, allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) anyerror!void {
        const self: *Http = @ptrCast(@alignCast(ptr));
        const http = try Http.init(allocator, config);
        self.* = http;
    }

    fn runVTable(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *Http = @ptrCast(@alignCast(ptr));
        try self.run(allocator);
    }

    fn deinitVTable(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Http = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub const vtable = Recipe.VTable{
        .init = initVTable,
        .run = runVTable,
        .deinit = deinitVTable,
    };

    pub fn recipe(self: *Http) Recipe {
        return Recipe{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

test "http recipe" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var config = std.StringHashMap([]const u8).init(allocator);
    defer config.deinit();

    try config.put("url", "https://httpbin.org/get");
    try config.put("method", "GET");

    var http = try Http.init(allocator, config);
    defer http.deinit(allocator);

    try testing.expectEqual(true, http.config.contains("url"));
}
