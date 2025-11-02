const std = @import("std");
const pipeline = @import("pipeline.zig");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(stderr);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "generate")) {
        if (args.len < 3) {
            try stderr.print("Error: generate command requires a pipeline definition file\n", .{});
            try printUsage(stderr);
            std.process.exit(1);
        }

        const definition_file = args[2];
        const output_dir = if (args.len > 3) args[3] else "generated";

        try generatePipeline(allocator, definition_file, output_dir, stdout);
    } else if (std.mem.eql(u8, command, "help")) {
        try printUsage(stdout);
    } else if (std.mem.eql(u8, command, "version")) {
        try stdout.print("better-ci version 0.1.0\n", .{});
    } else {
        try stderr.print("Error: unknown command '{s}'\n", .{command});
        try printUsage(stderr);
        std.process.exit(1);
    }
}

fn generatePipeline(
    allocator: std.mem.Allocator,
    definition_file: []const u8,
    output_dir: []const u8,
    writer: anytype,
) !void {
    try writer.print("Generating pipeline from: {s}\n", .{definition_file});
    try writer.print("Output directory: {s}\n", .{output_dir});

    // Parse the pipeline definition
    const pipe = try parser.parseDefinitionFile(allocator, definition_file);
    defer pipe.deinit(allocator);

    try writer.print("Parsed pipeline: {s}\n", .{pipe.name});
    try writer.print("Steps: {d}\n", .{pipe.steps.len});

    // Generate the code
    try codegen.generate(allocator, pipe, output_dir, writer);

    try writer.print("\nPipeline generated successfully!\n", .{});
    try writer.print("To build the pipeline executable:\n", .{});
    try writer.print("  cd {s} && zig build\n", .{output_dir});
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\better-ci - A faster, debuggable CI/CD system
        \\
        \\Usage:
        \\  better-ci <command> [options]
        \\
        \\Commands:
        \\  generate <file> [output-dir]  Generate a pipeline executable from definition
        \\  help                          Show this help message
        \\  version                       Show version information
        \\
        \\Examples:
        \\  better-ci generate pipeline.json
        \\  better-ci generate pipeline.json ./my-pipeline
        \\
    );
}

test "basic functionality" {
    const testing = std.testing;
    try testing.expect(true);
}
