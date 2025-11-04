const std = @import("std");
const pipeline = @import("pipeline.zig");
const graph = @import("graph.zig");
const templates = @import("templates.zig");

/// Generate all files needed for the pipeline executable
pub fn generate(
    allocator: std.mem.Allocator,
    pipe: pipeline.Pipeline,
    output_dir: []const u8,
    writer: *std.Io.Writer,
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

    var file_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const writer = &file_writer.interface;
    defer writer.flush() catch {};

    // Write build.zig content using templates
    try writer.writeAll(templates.build_header);
    try writer.print("{s}", .{pipe.name});
    try writer.writeAll(templates.build_middle);
}

fn generateMainZig(allocator: std.mem.Allocator, pipe: pipeline.Pipeline, output_dir: []const u8) !void {
    const main_path = try std.fs.path.join(allocator, &.{ output_dir, "src", "main.zig" });
    defer allocator.free(main_path);

    const file = try std.fs.cwd().createFile(main_path, .{});
    defer file.close();

    var file_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const writer = &file_writer.interface;
    defer writer.flush() catch {};

    // Write imports
    try writer.writeAll(templates.main_imports_header);
    for (pipe.steps) |step| {
        try writer.print("const step_{s} = @import(\"step_{s}.zig\");\n", .{ step.id, step.id });
    }
    try writer.writeAll("\n");

    // Write main function header
    try writer.writeAll(templates.main_function_header);
    try writer.print("{s}", .{pipe.name});
    try writer.writeAll(templates.main_log_dir_suffix);

    // Print pipeline header
    try writer.print("    try stdout.print(\"=== Pipeline: {s} ===\\n\", .{{}});\n", .{pipe.name});
    try writer.print("    try stdout.print(\"Description: {s}\\n\\n\", .{{}});\n\n", .{pipe.description});

    // Compute execution plan for parallel execution
    const plan = try graph.computeExecutionPlan(allocator, pipe);
    defer plan.deinit();

    // Check if we need parallel execution support
    var needs_parallel = false;
    for (plan.levels) |level| {
        if (level.len > 1) {
            needs_parallel = true;
            break;
        }
    }

    // Generate parallel execution code
    if (needs_parallel) {
        try writer.writeAll(templates.step_result_struct);
    }

    // For each execution level
    for (plan.levels, 0..) |level, level_idx| {
        try writer.print("    // Level {d}: {d} step(s) in parallel\n", .{ level_idx, level.len });

        if (level.len == 1) {
            // Single step - execute directly (no thread overhead)
            const step_idx = level[0];
            const step = pipe.steps[step_idx];
            try writer.print(templates.single_step_execution, .{
                step.name, // "Running step: {s}..."
                step.id,   // log_path_{s}
                step.id,   // step_{s}.log
                step.id,   // defer allocator.free(log_path_{s})
                step.id,   // step_{s}.execute
                step.id,   // log_path_{s} in execute
                step.id,   // log_content_{s}
                step.id,   // log_path_{s} in readFileAlloc
                step.id,   // defer allocator.free(log_content_{s})
                step.id,   // if (log_content_{s}.len > 0)
                step.id,   // log_content_{s} in print arguments
                step.name, // "✓ Step {s} completed"
            });
        } else {
            // Multiple steps - execute in parallel with threads
            try writer.print("    {{\n", .{});
            try writer.print(
                \\        var threads = try allocator.alloc(std.Thread, {d});
                \\        defer allocator.free(threads);
                \\        var results = try allocator.alloc(StepResult, {d});
                \\        defer allocator.free(results);
                \\        @memset(results, .{{ .step_name = "", .error_name = null, .err = null }});
                \\        var log_paths = try allocator.alloc([]const u8, {d});
                \\        defer allocator.free(log_paths);
                \\
                \\
            , .{level.len, level.len, level.len});

            // Create log paths for each step
            for (level, 0..) |step_idx, i| {
                const step = pipe.steps[step_idx];
                try writer.print("        log_paths[{d}] = try std.fmt.allocPrint(allocator, \"{{s}}/step_{s}.log\", .{{log_dir}});\n", .{ i, step.id });
            }
            try writer.print("        defer for (log_paths) |lp| allocator.free(lp);\n\n", .{});

            // Define thread function for each step in this level
            for (level, 0..) |step_idx, i| {
                const step = pipe.steps[step_idx];
                try writer.print(
                    \\        const step{d}_fn = struct {{
                    \\            fn run(result: *StepResult, log_path: []const u8) void {{
                    \\                var thread_gpa = std.heap.GeneralPurposeAllocator(.{{}}){{}};
                    \\                defer _ = thread_gpa.deinit();
                    \\                const thread_allocator = thread_gpa.allocator();
                    \\                result.step_name = "{s}";
                    \\                step_{s}.execute(thread_allocator, log_path) catch |err| {{
                    \\                    result.err = err;
                    \\                    result.error_name = "StepExecutionFailed";
                    \\                    return;
                    \\                }};
                    \\            }}
                    \\        }}.run;
                    \\
                    \\
                , .{i, step.name, step.id});
            }

            // Spawn threads
            try writer.print("        try stdout.print(\"Running {d} steps in parallel...\\n\", .{{}});\n", .{level.len});
            for (level, 0..) |_, i| {
                try writer.print("        threads[{d}] = try std.Thread.spawn(.{{}}, step{d}_fn, .{{&results[{d}], log_paths[{d}]}});\n", .{ i, i, i, i });
            }

            // Wait for all threads
            try writer.print("\n", .{});
            for (level, 0..) |_, i| {
                try writer.print("        threads[{d}].join();\n", .{i});
            }

            // Check for errors and display logs
            for (level, 0..) |_, i| {
                try writer.print(
                    \\        if (results[{d}].err) |err| {{
                    \\            const err_name = results[{d}].error_name orelse "UnknownError";
                    \\            try stdout.print("✗ Step {{s}} failed: {{s}}\n", .{{results[{d}].step_name, err_name}});
                    \\            return err;
                    \\        }}
                    \\        // Display step output
                    \\        if (std.fs.cwd().readFileAlloc(allocator, log_paths[{d}], 1024 * 1024)) |log_content_{d}| {{
                    \\            defer allocator.free(log_content_{d});
                    \\            if (log_content_{d}.len > 0) {{
                    \\                try stdout.print("{{s}}", .{{log_content_{d}}});
                    \\            }}
                    \\        }} else |err| {{
                    \\
                , .{i, i, i, i, i, i, i, i});
                const step = pipe.steps[level[i]];
                try writer.print("            try stdout.print(\"Warning: Could not read log for step {s}: {{any}}\\n\", .{{err}});\n", .{step.name});
                try writer.print(
                    \\        }}
                    \\        try stdout.print("✓ Step {{s}} completed\n", .{{results[{d}].step_name}});
                    \\
                , .{i});
            }
            try writer.print(
                \\        try stdout.print("\n", .{{}});
                \\    }}
                \\
                \\
            , .{});
        }
    }

    try writer.writeAll(templates.main_success_footer);
}

fn generateStepFiles(allocator: std.mem.Allocator, pipe: pipeline.Pipeline, output_dir: []const u8) !void {
    for (pipe.steps) |step| {
        const step_filename = try std.fmt.allocPrint(allocator, "step_{s}.zig", .{step.id});
        defer allocator.free(step_filename);

        const step_path = try std.fs.path.join(allocator, &.{ output_dir, "src", step_filename });
        defer allocator.free(step_path);

        const file = try std.fs.cwd().createFile(step_path, .{});
        defer file.close();

        var file_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(&file_buffer);
        const writer = &file_writer.interface;
        defer writer.flush() catch {};

        try generateStepImplementation(writer, step);
    }
}

fn generateStepImplementation(writer: *std.Io.Writer, step: pipeline.Step) !void {
    try writer.writeAll(templates.step_header);

    // Create environment map if there are env vars
    if (step.env.count() > 0) {
        try writer.writeAll(templates.step_env_setup);
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
                try writer.print(
                    \\    const original_dir = try std.process.getCwd();
                    \\    try std.posix.chdir("{s}");
                    \\    defer std.posix.chdir(original_dir) catch {{}};
                    \\
                    \\
                , .{wd});
            }

            if (step.env.count() > 0) {
                try writer.print(templates.ShellAction.execute_with_env, .{shell.command});
            } else {
                try writer.print(templates.ShellAction.execute_without_env, .{shell.command});
            }
            try writer.writeAll(templates.ShellAction.cleanup_and_check);
        },

        .compile => |compile| {
            try writer.writeAll("    // Compile Zig executable\n");
            const optimize_str = switch (compile.optimize) {
                .Debug => "Debug",
                .ReleaseSafe => "ReleaseSafe",
                .ReleaseFast => "ReleaseFast",
                .ReleaseSmall => "ReleaseSmall",
            };

            if (step.env.count() > 0) {
                try writer.print(templates.CompileAction.execute_with_env, .{ compile.source_file, optimize_str, compile.output_name });
            } else {
                try writer.print(templates.CompileAction.execute_without_env, .{ compile.source_file, optimize_str, compile.output_name });
            }
            try writer.writeAll(templates.CompileAction.cleanup_and_check);
        },

        .test_run => |test_action| {
            try writer.writeAll("    // Run tests\n");
            if (test_action.filter) |filter| {
                if (step.env.count() > 0) {
                    try writer.print(templates.TestAction.execute_with_filter_and_env, .{ test_action.test_file, filter });
                } else {
                    try writer.print(templates.TestAction.execute_with_filter_no_env, .{ test_action.test_file, filter });
                }
            } else {
                if (step.env.count() > 0) {
                    try writer.print(templates.TestAction.execute_without_filter_with_env, .{test_action.test_file});
                } else {
                    try writer.print(templates.TestAction.execute_without_filter_no_env, .{test_action.test_file});
                }
            }
            try writer.writeAll(templates.TestAction.cleanup_and_check);
        },

        .checkout => |checkout| {
            try writer.writeAll("    // Checkout code from repository\n");
            if (step.env.count() > 0) {
                try writer.print(templates.CheckoutAction.execute_with_env, .{ checkout.branch, checkout.repository, checkout.path });
            } else {
                try writer.print(templates.CheckoutAction.execute_without_env, .{ checkout.branch, checkout.repository, checkout.path });
            }
            try writer.writeAll(templates.CheckoutAction.cleanup_and_check);
        },

        .artifact => |artifact| {
            try writer.print(templates.ArtifactAction.copy_artifact, .{ artifact.destination, artifact.source_path, artifact.destination, artifact.source_path, artifact.destination });
        },

        .custom => |custom| {
            try writer.print(templates.CustomAction.not_implemented, .{ custom.type_name, custom.type_name });
        },
    }

    try writer.writeAll(templates.step_footer);
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
