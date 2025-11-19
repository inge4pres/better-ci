const std = @import("std");
const Recipe = @import("Recipe.zig").Recipe;

const log = std.log.scoped(.docker);

/// Docker recipe - run commands in Docker containers
///
/// Supported parameters:
/// - image (required): Docker image to use (e.g., "nginx:latest", "ubuntu:22.04")
/// - command: Command to run in the container (default: container's default command)
/// - working_dir: Working directory inside the container
/// - pull: Pull policy - "always", "missing", "never" (default: "missing")
/// - rm: Remove container after execution - "true" or "false" (default: "true")
/// - volumes: Comma-separated list of volume mounts (e.g., "./src:/app/src,./data:/data")
/// - ports: Comma-separated list of port mappings (e.g., "8080:80,443:443")
/// - network: Docker network to use
/// - user: User to run as (e.g., "1000:1000")
pub const Docker = struct {
    config: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) !Docker {
        return Docker{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn run(self: *Docker, allocator: std.mem.Allocator) !void {
        const image = self.config.get("image") orelse return error.MissingDockerImage;
        const command = self.config.get("command");
        const working_dir = self.config.get("working_dir");
        const pull = self.config.get("pull") orelse "missing";
        const rm = self.config.get("rm") orelse "true";
        const volumes = self.config.get("volumes");
        const ports = self.config.get("ports");
        const network = self.config.get("network");
        const user = self.config.get("user");

        var docker_args: std.ArrayList([]const u8) = .empty;
        defer docker_args.deinit(allocator);

        try docker_args.append(allocator, "docker");
        try docker_args.append(allocator, "run");

        // Remove container after execution
        if (std.mem.eql(u8, rm, "true")) {
            try docker_args.append(allocator, "--rm");
        }

        // Pull policy
        if (std.mem.eql(u8, pull, "always")) {
            try docker_args.append(allocator, "--pull");
            try docker_args.append(allocator, "always");
        } else if (std.mem.eql(u8, pull, "never")) {
            try docker_args.append(allocator, "--pull");
            try docker_args.append(allocator, "never");
        }

        // Working directory
        if (working_dir) |wd| {
            try docker_args.append(allocator, "-w");
            try docker_args.append(allocator, wd);
        }

        // User
        if (user) |u| {
            try docker_args.append(allocator, "--user");
            try docker_args.append(allocator, u);
        }

        // Network
        if (network) |net| {
            try docker_args.append(allocator, "--network");
            try docker_args.append(allocator, net);
        }

        // Volumes
        if (volumes) |vol_list| {
            var vol_iter = std.mem.splitSequence(u8, vol_list, ",");
            while (vol_iter.next()) |vol| {
                const trimmed = std.mem.trim(u8, vol, " ");
                if (trimmed.len > 0) {
                    try docker_args.append(allocator, "-v");
                    try docker_args.append(allocator, trimmed);
                }
            }
        }

        // Ports
        if (ports) |port_list| {
            var port_iter = std.mem.splitSequence(u8, port_list, ",");
            while (port_iter.next()) |port| {
                const trimmed = std.mem.trim(u8, port, " ");
                if (trimmed.len > 0) {
                    try docker_args.append(allocator, "-p");
                    try docker_args.append(allocator, trimmed);
                }
            }
        }

        // Image
        try docker_args.append(allocator, image);

        // Command (if provided)
        if (command) |cmd| {
            try docker_args.append(allocator, "sh");
            try docker_args.append(allocator, "-c");
            try docker_args.append(allocator, cmd);
        }

        log.info("Running Docker container: {s}", .{image});
        if (command) |cmd| {
            log.info("Command: {s}", .{cmd});
        }

        var child = std.process.Child.init(docker_args.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var stdout_buffer: std.ArrayList(u8) = .empty;
        defer stdout_buffer.deinit(allocator);
        var stderr_buffer: std.ArrayList(u8) = .empty;
        defer stderr_buffer.deinit(allocator);

        try child.collectOutput(allocator, &stdout_buffer, &stderr_buffer, 10 * 1024 * 1024);

        const term = try child.wait();

        if (stdout_buffer.items.len > 0) {
            log.info("{s}", .{stdout_buffer.items});
        }
        if (stderr_buffer.items.len > 0) {
            log.err("{s}", .{stderr_buffer.items});
        }

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    log.err("Docker command failed with exit code {d}", .{code});
                    return error.DockerCommandFailed;
                }
            },
            else => {
                log.err("Docker command terminated abnormally", .{});
                return error.DockerCommandFailed;
            },
        }

        log.info("Docker container completed successfully", .{});
    }

    pub fn deinit(self: *Docker, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
        // Config is owned by caller, no cleanup needed
    }

    // VTable implementation
    fn initVTable(ptr: *anyopaque, allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) anyerror!void {
        const self: *Docker = @ptrCast(@alignCast(ptr));
        const docker = try Docker.init(allocator, config);
        self.* = docker;
    }

    fn runVTable(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *Docker = @ptrCast(@alignCast(ptr));
        try self.run(allocator);
    }

    fn deinitVTable(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Docker = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    pub const vtable = Recipe.VTable{   
        .init = initVTable,
        .run = runVTable,
        .deinit = deinitVTable,
    };

    pub fn recipe(self: *Docker) Recipe {
        return Recipe{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

test "docker recipe" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var config = std.StringHashMap([]const u8).init(allocator);
    defer config.deinit();

    try config.put("image", "alpine:latest");
    try config.put("command", "echo hello");

    var docker = try Docker.init(allocator, config);
    defer docker.deinit(allocator);

    try testing.expectEqual(true, docker.config.contains("image"));
}
