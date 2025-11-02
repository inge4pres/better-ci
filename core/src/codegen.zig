const std = @import("std");
const pipeline = @import("pipeline.zig");

/// Generate all files needed for the pipeline executable
pub fn generate(
    allocator: std.mem.Allocator,
    pipe: pipeline.Pipeline,
    output_dir: []const u8,
    writer: anytype,
) !void {
    // Create output directory
    try std.fs.cwd().makePath(output_dir);

    // Create src subdirectory
    const src_path = try std.fs.path.join(allocator, &.{ output_dir, "src" });
    defer allocator.free(src_path);
    try std.fs.cwd().makePath(src_path);

    // Generate build.zig
    try writer.print("Generating build.zig...\n", .{});
    try generateBuildZig(allocator, pipe, output_dir);

    // Generate main.zig
    try writer.print("Generating src/main.zig...\n", .{});
    try generateMainZig(allocator, pipe, output_dir);

    // Generate step implementations
    try writer.print("Generating step implementations...\n", .{});
    try generateStepFiles(allocator, pipe, output_dir);
}

fn generateBuildZig(allocator: std.mem.Allocator, pipe: pipeline.Pipeline, output_dir: []const u8) !void {
    const build_path = try std.fs.path.join(allocator, &.{ output_dir, "build.zig" });
    defer allocator.free(build_path);

    const file = try std.fs.cwd().createFile(build_path, .{});
    defer file.close();

    const writer = file.deprecatedWriter();

    try writer.writeAll(
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) !void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    // Pipeline executable
        \\    const exe = b.addExecutable(.{
        \\        .name = "
    );
    try writer.print("{s}", .{pipe.name});
    try writer.writeAll(
        \\",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\
        \\    b.installArtifact(exe);
        \\
        \\    // Run command
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\
        \\    if (b.args) |args| {
        \\        run_cmd.addArgs(args);
        \\    }
        \\
        \\    const run_step = b.step("run", "Run the pipeline");
        \\    run_step.dependOn(&run_cmd.step);
        \\}
        \\
    );
}

fn generateMainZig(allocator: std.mem.Allocator, pipe: pipeline.Pipeline, output_dir: []const u8) !void {
    const main_path = try std.fs.path.join(allocator, &.{ output_dir, "src", "main.zig" });
    defer allocator.free(main_path);

    const file = try std.fs.cwd().createFile(main_path, .{});
    defer file.close();

    const writer = file.deprecatedWriter();

    // Write imports
    try writer.writeAll("const std = @import(\"std\");\n");
    for (pipe.steps) |step| {
        try writer.print("const step_{s} = @import(\"step_{s}.zig\");\n", .{ step.id, step.id });
    }
    try writer.writeAll("\n");

    // Write main function
    try writer.writeAll(
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    const stdout = std.fs.File.stdout().deprecatedWriter();
        \\
        \\    try stdout.print("=== Pipeline:
    );
    try writer.print("{s}", .{pipe.name});
    try writer.writeAll(" ===\\n\", .{});\n");
    try writer.writeAll(
        \\    try stdout.print("Description:
    );
    try writer.print("{s}", .{pipe.description});
    try writer.writeAll("\\n\\n\", .{});\n\n");

    // Execute steps in order (respecting dependencies)
    // For now, simple sequential execution
    // TODO: Implement parallel execution based on dependency graph
    for (pipe.steps) |step| {
        try writer.print("    try stdout.print(\"Running step: {s}...\\n\", .{{}});\n", .{step.name});
        try writer.print("    try step_{s}.execute(allocator, stdout);\n", .{step.id});
        try writer.print("    try stdout.print(\"✓ Step {s} completed\\n\\n\", .{{}});\n\n", .{step.name});
    }

    try writer.writeAll(
        \\    try stdout.print("=== Pipeline completed successfully ===\n", .{});
        \\}
        \\
    );
}

fn generateStepFiles(allocator: std.mem.Allocator, pipe: pipeline.Pipeline, output_dir: []const u8) !void {
    for (pipe.steps) |step| {
        const step_filename = try std.fmt.allocPrint(allocator, "step_{s}.zig", .{step.id});
        defer allocator.free(step_filename);

        const step_path = try std.fs.path.join(allocator, &.{ output_dir, "src", step_filename });
        defer allocator.free(step_path);

        const file = try std.fs.cwd().createFile(step_path, .{});
        defer file.close();

        try generateStepImplementation(file.deprecatedWriter(), step);
    }
}

fn generateStepImplementation(writer: anytype, step: pipeline.Step) !void {
    try writer.writeAll("const std = @import(\"std\");\n\n");
    try writer.writeAll("pub fn execute(allocator: std.mem.Allocator, stdout: anytype) !void {\n");

    // Create environment map if there are env vars
    if (step.env.count() > 0) {
        try writer.writeAll("    // Create environment map\n");
        try writer.writeAll("    var env_map = try std.process.getEnvMap(allocator);\n");
        try writer.writeAll("    defer env_map.deinit();\n");
        var it = step.env.iterator();
        while (it.next()) |entry| {
            try writer.print("    try env_map.put(\"{s}\", \"{s}\");\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try writer.writeAll("\n");
    }

    // Generate action-specific code
    switch (step.action) {
        .shell => |shell| {
            try writer.writeAll("    // Execute shell command\n");
            if (shell.working_dir) |wd| {
                try writer.print("    const original_dir = try std.process.getCwd();\n", .{});
                try writer.print("    try std.posix.chdir(\"{s}\");\n", .{wd});
                try writer.print("    defer std.posix.chdir(original_dir) catch {{}};\n\n", .{});
            }

            try writer.print("    const result = try std.process.Child.run(.{{\n", .{});
            try writer.print("        .allocator = allocator,\n", .{});
            try writer.print("        .argv = &.{{ \"sh\", \"-c\", \"{s}\" }},\n", .{shell.command});
            if (step.env.count() > 0) {
                try writer.print("        .env_map = &env_map,\n", .{});
            }
            try writer.print("    }});\n", .{});
            try writer.writeAll("    defer allocator.free(result.stdout);\n");
            try writer.writeAll("    defer allocator.free(result.stderr);\n\n");
            try writer.writeAll("    if (result.stdout.len > 0) {\n");
            try writer.writeAll("        try stdout.print(\"{s}\", .{result.stdout});\n");
            try writer.writeAll("    }\n");
            try writer.writeAll("    if (result.stderr.len > 0) {\n");
            try writer.writeAll("        try stdout.print(\"{s}\", .{result.stderr});\n");
            try writer.writeAll("    }\n\n");
            try writer.writeAll("    if (result.term.Exited != 0) {\n");
            try writer.writeAll("        return error.CommandFailed;\n");
            try writer.writeAll("    }\n");
        },

        .compile => |compile| {
            try writer.writeAll("    // Compile Zig executable\n");
            const optimize_str = switch (compile.optimize) {
                .Debug => "Debug",
                .ReleaseSafe => "ReleaseSafe",
                .ReleaseFast => "ReleaseFast",
                .ReleaseSmall => "ReleaseSmall",
            };

            try writer.print("    const result = try std.process.Child.run(.{{\n", .{});
            try writer.print("        .allocator = allocator,\n", .{});
            try writer.print("        .argv = &.{{ \"zig\", \"build-exe\", \"{s}\", \"-O{s}\", \"--name\", \"{s}\" }},\n", .{ compile.source_file, optimize_str, compile.output_name });
            if (step.env.count() > 0) {
                try writer.print("        .env_map = &env_map,\n", .{});
            }
            try writer.print("    }});\n", .{});
            try writer.writeAll("    defer allocator.free(result.stdout);\n");
            try writer.writeAll("    defer allocator.free(result.stderr);\n\n");
            try writer.writeAll("    if (result.stdout.len > 0) try stdout.print(\"{s}\", .{result.stdout});\n");
            try writer.writeAll("    if (result.stderr.len > 0) try stdout.print(\"{s}\", .{result.stderr});\n\n");
            try writer.writeAll("    if (result.term.Exited != 0) return error.CompileFailed;\n");
        },

        .test_run => |test_action| {
            try writer.writeAll("    // Run tests\n");
            if (test_action.filter) |filter| {
                try writer.print("    const result = try std.process.Child.run(.{{\n", .{});
                try writer.print("        .allocator = allocator,\n", .{});
                try writer.print("        .argv = &.{{ \"zig\", \"test\", \"{s}\", \"--test-filter\", \"{s}\" }},\n", .{ test_action.test_file, filter });
                if (step.env.count() > 0) {
                    try writer.print("        .env_map = &env_map,\n", .{});
                }
                try writer.print("    }});\n", .{});
            } else {
                try writer.print("    const result = try std.process.Child.run(.{{\n", .{});
                try writer.print("        .allocator = allocator,\n", .{});
                try writer.print("        .argv = &.{{ \"zig\", \"test\", \"{s}\" }},\n", .{test_action.test_file});
                if (step.env.count() > 0) {
                    try writer.print("        .env_map = &env_map,\n", .{});
                }
                try writer.print("    }});\n", .{});
            }
            try writer.writeAll("    defer allocator.free(result.stdout);\n");
            try writer.writeAll("    defer allocator.free(result.stderr);\n\n");
            try writer.writeAll("    if (result.stdout.len > 0) try stdout.print(\"{s}\", .{result.stdout});\n");
            try writer.writeAll("    if (result.stderr.len > 0) try stdout.print(\"{s}\", .{result.stderr});\n\n");
            try writer.writeAll("    if (result.term.Exited != 0) return error.TestsFailed;\n");
        },

        .checkout => |checkout| {
            try writer.writeAll("    // Checkout code from repository\n");
            try writer.print("    const result = try std.process.Child.run(.{{\n", .{});
            try writer.print("        .allocator = allocator,\n", .{});
            try writer.print("        .argv = &.{{ \"git\", \"clone\", \"--branch\", \"{s}\", \"--depth\", \"1\", \"{s}\", \"{s}\" }},\n", .{ checkout.branch, checkout.repository, checkout.path });
            if (step.env.count() > 0) {
                try writer.print("        .env_map = &env_map,\n", .{});
            }
            try writer.print("    }});\n", .{});
            try writer.writeAll("    defer allocator.free(result.stdout);\n");
            try writer.writeAll("    defer allocator.free(result.stderr);\n\n");
            try writer.writeAll("    if (result.stdout.len > 0) try stdout.print(\"{s}\", .{result.stdout});\n");
            try writer.writeAll("    if (result.stderr.len > 0) try stdout.print(\"{s}\", .{result.stderr});\n\n");
            try writer.writeAll("    if (result.term.Exited != 0) return error.CheckoutFailed;\n");
        },

        .artifact => |artifact| {
            try writer.writeAll("    // Copy artifact\n");
            try writer.writeAll("    _ = allocator;\n");
            try writer.print("    try std.fs.cwd().makePath(std.fs.path.dirname(\"{s}\") orelse \".\");\n", .{artifact.destination});
            try writer.print("    try std.fs.cwd().copyFile(\"{s}\", std.fs.cwd(), \"{s}\", .{{}});\n", .{ artifact.source_path, artifact.destination });
            try writer.print("    try stdout.print(\"Artifact copied: {s} -> {s}\\n\", .{{}});\n", .{ artifact.source_path, artifact.destination });
        },

        .custom => |custom| {
            try writer.print("    // Custom action: {s}\n", .{custom.type_name});
            try writer.writeAll("    // TODO: Implement custom action\n");
            try writer.print("    try stdout.print(\"Custom action '{s}' not yet implemented\\n\", .{{}});\n", .{custom.type_name});
            try writer.writeAll("    return error.NotImplemented;\n");
        },
    }

    try writer.writeAll("}\n");
}

test "generate basic pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var steps = try allocator.alloc(pipeline.Step, 1);
    defer allocator.free(steps);

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    steps[0] = pipeline.Step{
        .id = try allocator.dupe(u8, "test_step"),
        .name = try allocator.dupe(u8, "Test Step"),
        .action = pipeline.Action{
            .shell = .{
                .command = try allocator.dupe(u8, "echo hello"),
                .working_dir = null,
            },
        },
        .depends_on = &.{},
        .env = env,
    };

    const pipe = pipeline.Pipeline{
        .name = try allocator.dupe(u8, "test-pipeline"),
        .description = try allocator.dupe(u8, "Test"),
        .steps = steps,
    };
    defer pipe.deinit(allocator);

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    // This would generate files, skip in test
    // try generate(allocator, pipe, "/tmp/test-output", output.writer());
}
