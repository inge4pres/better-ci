const std = @import("std");
const clap = @import("clap");
const pipeline = @import("pipeline.zig");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const envfile = @import("envfile.zig");

const SubCommands = enum {
    generate,
    help,
    version,
};

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

    // Parse main command with subcommand support
    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    // Skip the executable name
    iter.skip();

    const main_parsers = .{
        .command = clap.parsers.enumeration(SubCommands),
    };

    const main_params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help and exit
        \\<command>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        try stderr.flush();
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    const command = res.positionals[0] orelse {
        try stderr.print("Error: no command provided\n\n", .{});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    };

    switch (command) {
        .generate => try runGenerate(allocator, &iter, stdout, stderr),
        .help => {
            try printUsage(stdout);
            try stdout.flush();
        },
        .version => {
            try stdout.print("better-ci version 0.1.0\n", .{});
            try stdout.flush();
        },
    }
}

fn runGenerate(
    allocator: std.mem.Allocator,
    iter: *std.process.ArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // Define parameters for the generate subcommand
    const params = comptime clap.parseParamsComptime(
        \\<STR>...              Positional arguments: <file> [output-dir]
        \\--env-file <STR>      Load global environment variables from file
        \\-h, --help            Display this help and exit
        \\
    );

    const parsers = comptime .{
        .STR = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        try stderr.flush();
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printGenerateUsage(stdout);
        try stdout.flush();
        return;
    }

    // Get required positional argument
    if (res.positionals[0].len == 0) {
        try stderr.print("Error: generate command requires a pipeline definition file\n\n", .{});
        try printGenerateUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    const definition_file = res.positionals[0][0];

    // Get optional positional argument with default
    const output_dir = if (res.positionals[0].len > 1)
        res.positionals[0][1]
    else
        "generated";

    // Get optional flag argument
    const env_file = res.args.@"env-file";

    try generatePipeline(allocator, definition_file, output_dir, env_file, stdout);
    try stdout.flush();
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

fn printGenerateUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: better-ci generate <file> [output-dir] [options]
        \\
        \\Generate a pipeline executable from a JSON definition file
        \\
        \\Arguments:
        \\  <file>           Pipeline definition file (required)
        \\  [output-dir]     Output directory (default: generated)
        \\
        \\Options:
        \\  --env-file <path>  Load global environment variables from file
        \\  -h, --help         Display this help and exit
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
    _ = @import("condition.zig");
    _ = @import("envfile.zig");
    _ = @import("graph.zig");
    _ = @import("parser.zig");
    _ = @import("pipeline.zig");
    _ = @import("recipe.zig");
    _ = @import("templates.zig");
}
