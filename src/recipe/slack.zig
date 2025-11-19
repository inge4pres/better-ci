const std = @import("std");
const Recipe = @import("Recipe.zig").Recipe;

const log = std.log.scoped(.slack);

/// Slack recipe - send notifications to Slack
///
/// Supported parameters:
/// - webhook_url: Slack webhook URL (or use SLACK_WEBHOOK_URL env var)
/// - message (required): Message text to send
/// - channel: Override default channel (e.g., "#builds", "@user")
/// - username: Override bot username
/// - icon_emoji: Emoji icon (e.g., ":rocket:", ":white_check_mark:")
/// - color: Attachment color - "good", "warning", "danger", or hex code (e.g., "#FF0000")
pub const Slack = struct {
    config: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) !Slack {
        return Slack{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *Slack, allocator: std.mem.Allocator) !void {
        const webhook_url = self.config.get("webhook_url") orelse blk: {
            const env_url = std.posix.getenv("SLACK_WEBHOOK_URL");
            if (env_url == null) {
                log.err("SLACK_WEBHOOK_URL not set and webhook_url parameter not provided", .{});
                return error.MissingSlackWebhookUrl;
            }
            break :blk env_url.?;
        };
        const message = self.config.get("message") orelse return error.MissingSlackMessage;
        const channel = self.config.get("channel");
        const username = self.config.get("username");
        const icon_emoji = self.config.get("icon_emoji");
        const color = self.config.get("color");

        log.info("Sending Slack notification", .{});
        if (channel) |ch| {
            log.info("Channel: {s}", .{ch});
        }

        // Build JSON payload
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(allocator);
        const payload_writer = payload.writer(allocator);

        // Build JSON manually (simple escaping for quotes and backslashes)
        try payload_writer.writeAll("{\"text\":\"");
        for (message) |c| {
            if (c == '"' or c == '\\') try payload_writer.writeByte('\\');
            try payload_writer.writeByte(c);
        }
        try payload_writer.writeAll("\"");

        // Channel
        if (channel) |ch| {
            try payload_writer.writeAll(",\"channel\":\"");
            for (ch) |c| {
                if (c == '"' or c == '\\') try payload_writer.writeByte('\\');
                try payload_writer.writeByte(c);
            }
            try payload_writer.writeAll("\"");
        }

        // Username
        if (username) |un| {
            try payload_writer.writeAll(",\"username\":\"");
            for (un) |c| {
                if (c == '"' or c == '\\') try payload_writer.writeByte('\\');
                try payload_writer.writeByte(c);
            }
            try payload_writer.writeAll("\"");
        }

        // Icon emoji
        if (icon_emoji) |ie| {
            try payload_writer.writeAll(",\"icon_emoji\":\"");
            for (ie) |c| {
                if (c == '"' or c == '\\') try payload_writer.writeByte('\\');
                try payload_writer.writeByte(c);
            }
            try payload_writer.writeAll("\"");
        }

        // Attachments for color
        if (color) |col| {
            try payload_writer.writeAll(",\"attachments\":[{\"color\":\"");
            for (col) |c| {
                if (c == '"' or c == '\\') try payload_writer.writeByte('\\');
                try payload_writer.writeByte(c);
            }
            try payload_writer.writeAll("\",\"text\":\"");
            for (message) |c| {
                if (c == '"' or c == '\\') try payload_writer.writeByte('\\');
                try payload_writer.writeByte(c);
            }
            try payload_writer.writeAll("\"}]");
        }

        try payload_writer.writeAll("}");

        // Send request using curl
        var curl_args = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-d",
            payload.items,
            "--max-time",
            "10",
            "-f",
            webhook_url,
        };

        var child = std.process.Child.init(&curl_args, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var stdout_buffer: std.ArrayList(u8) = .empty;
        defer stdout_buffer.deinit(allocator);
        var stderr_buffer: std.ArrayList(u8) = .empty;
        defer stderr_buffer.deinit(allocator);

        try child.collectOutput(allocator, &stdout_buffer, &stderr_buffer, 1024 * 1024);
        const term = try child.wait();

        if (stderr_buffer.items.len > 0) {
            log.err("{s}", .{stderr_buffer.items});
        }

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    log.err("Slack notification failed with exit code {d}", .{code});
                    return error.SlackNotificationFailed;
                }
            },
            else => {
                log.err("Slack notification terminated abnormally", .{});
                return error.SlackNotificationFailed;
            },
        }

        log.info("Slack notification sent successfully", .{});
    }

    pub fn deinit(self: *Slack, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
        // Config is owned by caller, no cleanup needed
    }

    // VTable implementation
    fn initVTable(ptr: *anyopaque, allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) anyerror!void {
        const self: *Slack = @ptrCast(@alignCast(ptr));
        const slack = try Slack.init(allocator, config);
        self.* = slack;
    }

    fn runVTable(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *Slack = @ptrCast(@alignCast(ptr));
        try self.run(allocator);
    }

    fn deinitVTable(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Slack = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub const vtable = Recipe.VTable{
        .init = initVTable,
        .run = runVTable,
        .deinit = deinitVTable,
    };

    pub fn recipe(self: *Slack) Recipe {
        return Recipe{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

test "slack recipe" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var config = std.StringHashMap([]const u8).init(allocator);
    defer config.deinit();

    try config.put("message", "Build complete");
    try config.put("channel", "#builds");

    var slack = try Slack.init(allocator, config);
    defer slack.deinit(allocator);

    try testing.expectEqual(true, slack.config.contains("message"));
}
