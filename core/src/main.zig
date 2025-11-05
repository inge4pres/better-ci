const std = @import("std");
const pipeline = @import("pipeline.zig");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const envfile = @import("envfile.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create buffered writers for stdout and stderr
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "generate")) {
        if (args.len < 3) {
            try stderr.print("Error: generate command requires a pipeline definition file\n", .{});
            try printUsage(stderr);
            try stderr.flush();
            std.process.exit(1);
        }

        const definition_file = args[2];

        // Parse optional arguments
        var output_dir: []const u8 = "generated";
        var env_file: ?[]const u8 = null;

        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--env-file")) {
                if (i + 1 >= args.len) {
                    try stderr.print("Error: --env-file requires a file path\n", .{});
                    try printUsage(stderr);
                    try stderr.flush();
                    std.process.exit(1);
                }
                env_file = args[i + 1];
                i += 1;
            } else if (!std.mem.startsWith(u8, arg, "--")) {
                // Non-flag argument is treated as output directory
                output_dir = arg;
            }
        }

        try generatePipeline(allocator, definition_file, output_dir, env_file, stdout);
        try stdout.flush();
    } else if (std.mem.eql(u8, command, "help")) {
        try printUsage(stdout);
        try stdout.flush();
    } else if (std.mem.eql(u8, command, "version")) {
        try stdout.print("better-ci version 0.1.0\n", .{});
        try stdout.flush();
    } else {
        try stderr.print("Error: unknown command '{s}'\n", .{command});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }
}

fn generatePipeline(
    allocator: std.mem.Allocator,
    definition_file: []const u8,
    output_dir: []const u8,
    env_file_path: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    try writer.print("Generating pipeline from: {s}\n", .{definition_file});
    try writer.print("Output directory: {s}\n", .{output_dir});

    // Parse the pipeline definition
    var pipe = try parser.parseDefinitionFile(allocator, definition_file);
    defer pipe.deinit(allocator);

    // Load global environment variables if provided
    if (env_file_path) |env_path| {
        try writer.print("Loading environment from: {s}\n", .{env_path});
        const env_map = try envfile.parseEnvFile(allocator, env_path);
        try writer.print("Loaded {d} environment variables\n", .{env_map.count()});
        pipe.environment = env_map;
    }

    try writer.print("Parsed pipeline: {s}\n", .{pipe.name});
    try writer.print("Steps: {d}\n", .{pipe.steps.len});

    // Generate the code
    try codegen.generate(allocator, pipe, output_dir, writer);

    try writer.print("\nPipeline generated successfully!\n", .{});
    try writer.print("To build the pipeline executable:\n", .{});
    try writer.print("  cd {s} && zig build\n", .{output_dir});
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\better-ci - A faster, debuggable CI/CD system
        \\
        \\Usage:
        \\  better-ci <command> [options]
        \\
        \\Commands:
        \\  generate <file> [output-dir] [--env-file <path>]
        \\    Generate a pipeline executable from definition
        \\
        \\  help
        \\    Show this help message
        \\
        \\  version
        \\    Show version information
        \\
        \\Options:
        \\  --env-file <path>    Load global environment variables from file
        \\
        \\Examples:
        \\  better-ci generate pipeline.json
        \\  better-ci generate pipeline.json ./my-pipeline
        \\  better-ci generate pipeline.json --env-file .env
        \\  better-ci generate pipeline.json ./my-pipeline --env-file production.env
        \\
    );
}

// Tests
test {
    _ = @import("codegen.zig");
    _ = @import("envfile.zig");
    _ = @import("graph.zig");
    _ = @import("parser.zig");
    _ = @import("pipeline.zig");
    _ = @import("templates.zig");
}
