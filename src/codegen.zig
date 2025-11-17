const std = @import("std");
const pipeline = @import("pipeline.zig");
const graph = @import("graph.zig");
const templates = @import("templates.zig");
const recipe = @import("recipe.zig");

/// Sanitize a step ID to be a valid Zig identifier
/// Replaces hyphens with underscores
fn sanitizeIdentifier(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, id.len);
    for (id, 0..) |char, i| {
        result[i] = if (char == '-') '_' else char;
    }
    return result;
}

/// Add indentation to each line of a string
fn indentLines(allocator: std.mem.Allocator, text: []const u8, indent: []const u8) ![]const u8 {
    if (indent.len == 0) return try allocator.dupe(u8, text);

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.appendSlice("\n");
        first = false;
        if (line.len > 0) {
            try result.appendSlice(indent);
        }
        try result.appendSlice(line);
    }

    return result.toOwnedSlice();
}

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

    // Generate build.zig.zon
    try writer.print("Generating build.zig.zon...\n", .{});
    try generateBuildZigZon(allocator, pipe, output_dir);

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

fn generateBuildZigZon(allocator: std.mem.Allocator, pipe: pipeline.Pipeline, output_dir: []const u8) !void {
    const zon_path = try std.fs.path.join(allocator, &.{ output_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    const file = try std.fs.cwd().createFile(zon_path, .{});
    defer file.close();

    // Generate build.zig.zon content
    const zon_content = try templates.buildZigZon(allocator, pipe.name);
    defer allocator.free(zon_content);

    try file.writeAll(zon_content);
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

    // Add scoped log declaration
    const log_decl = try templates.mainLogDeclaration(pipe.name);
    defer std.heap.page_allocator.free(log_decl);
    try writer.writeAll(log_decl);
    try writer.writeAll("\n");

    for (pipe.steps) |step| {
        const safe_id = try sanitizeIdentifier(allocator, step.id);
        defer allocator.free(safe_id);
        try writer.print("const step_{s} = @import(\"step_{s}.zig\");\n", .{ safe_id, step.id });
    }
    try writer.writeAll("\n");

    // Write main function header
    try writer.writeAll(templates.main_function_header);
    try writer.print("{s}", .{pipe.name});
    try writer.writeAll(templates.main_log_dir_suffix);

    // Print pipeline header
    try writer.print("    log.info(\"=== Pipeline: {s} ===\", .{{}});\n", .{pipe.name});
    try writer.print("    log.info(\"Description: {s}\", .{{}});\n\n", .{pipe.description});

    // Compute execution plan for parallel execution
    const plan = try graph.computeExecutionPlan(allocator, pipe);
    defer plan.deinit();

    // Always generate StepResult struct since we use thread-based execution
    try writer.writeAll(templates.step_result_struct);

    // For each execution level
    for (plan.levels, 0..) |level, level_idx| {
        try writer.print("    // Level {d}: {d} step(s) in parallel\n", .{ level_idx, level.len });

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
        , .{ level.len, level.len, level.len });

        // Create log paths for each step
        for (level, 0..) |step_idx, i| {
            const step = pipe.steps[step_idx];
            try writer.print("        log_paths[{d}] = try std.fmt.allocPrint(allocator, \"{{s}}/step_{s}.log\", .{{log_dir}});\n", .{ i, step.id });
        }
        try writer.print("        defer for (log_paths) |lp| allocator.free(lp);\n\n", .{});

        // Define thread function for each step in this level
        for (level, 0..) |step_idx, i| {
            const step = pipe.steps[step_idx];
            const safe_id = try sanitizeIdentifier(allocator, step.id);
            defer allocator.free(safe_id);
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
            , .{ i, step.name, safe_id });
        }

        // Spawn threads
        try writer.print("        log.info(\"Running {{d}} steps in parallel...\", .{{{d}}});\n", .{level.len});
        for (level, 0..) |_, i| {
            try writer.print("        threads[{d}] = try std.Thread.spawn(.{{}}, step{d}_fn, .{{&results[{d}], log_paths[{d}]}});\n", .{ i, i, i, i });
        }

        // Wait for all threads
        try writer.print("\n", .{});
        for (level, 0..) |_, i| {
            try writer.print("        threads[{d}].join();\n", .{i});
        }

        // Check for errors and display logs using a for loop
        try writer.print(
            \\        for (results, 0..) |result, i| {{
            \\            if (result.err) |err| {{
            \\                const err_name = result.error_name orelse "UnknownError";
            \\                log.err("✗ Step {{s}} failed: {{s}}", .{{result.step_name, err_name}});
            \\                // Display failed step's log
            \\                if (std.fs.cwd().readFileAlloc(allocator, log_paths[i], 1024 * 1024)) |log_content| {{
            \\                    defer allocator.free(log_content);
            \\                    if (log_content.len > 0) {{
            \\                        try stdout.print("{{s}}", .{{log_content}});
            \\                    }}
            \\                }} else |read_err| {{
            \\                    log.warn("Could not read log: {{any}}", .{{read_err}});
            \\                }}
            \\                return err;
            \\            }}
            \\            // Display successful step's log
            \\            if (std.fs.cwd().readFileAlloc(allocator, log_paths[i], 1024 * 1024)) |log_content| {{
            \\                defer allocator.free(log_content);
            \\                if (log_content.len > 0) {{
            \\                    try stdout.print("{{s}}", .{{log_content}});
            \\                }}
            \\            }} else |read_err| {{
            \\                log.warn("Could not read log for step {{s}}: {{any}}", .{{result.step_name, read_err}});
            \\            }}
            \\            log.info("✓ Step {{s}} completed", .{{result.step_name}});
            \\        }}
            \\
        , .{});
        try writer.print(
            \\        try stdout.print("\n", .{{}});
            \\    }}
            \\
            \\
        , .{});
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

        try generateStepImplementation(writer, pipe.name, step, pipe.environment);
    }
}

fn generateStepImplementation(writer: *std.Io.Writer, pipeline_name: []const u8, step: pipeline.Step, global_env: ?std.StringHashMap([]const u8)) !void {
    const step_header = try templates.stepHeader(pipeline_name, step.id);
    defer std.heap.page_allocator.free(step_header);
    try writer.writeAll(step_header);

    // If there's a condition, add check at the start
    if (step.condition) |cond| {
        const cond_code = try cond.generateCode(std.heap.page_allocator);
        defer std.heap.page_allocator.free(cond_code);

        try writer.print("    // Conditional execution\n", .{});
        try writer.print("    const should_execute = {s};\n", .{cond_code});
        try writer.writeAll("    if (!should_execute) {\n");
        try writer.writeAll("        log.info(\"Condition not met, skipping step\", .{});\n");
        try writer.writeAll("        return;\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    log.info(\"Condition met, executing step\", .{});\n\n");
    }

    // Determine if this action type supports environment variables
    const action_supports_env = switch (step.action) {
        .shell, .compile, .test_run, .checkout => true,
        .artifact, .recipe => false,
    };

    // Determine if we need to create an environment map
    const has_global_env = if (global_env) |env| env.count() > 0 else false;
    const has_step_env = step.env.count() > 0;
    const needs_env = action_supports_env and (has_global_env or has_step_env);

    // Create environment map if there are any env vars (global or step-specific)
    if (needs_env) {
        try writer.writeAll(templates.step_env_setup);

        // First, add global environment variables
        if (global_env) |env| {
            var it = env.iterator();
            while (it.next()) |entry| {
                try writer.print("    try env_map.put(\"{s}\", \"{s}\");\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        // Then, add/override with step-specific environment variables
        if (has_step_env) {
            var it = step.env.iterator();
            while (it.next()) |entry| {
                try writer.print("    try env_map.put(\"{s}\", \"{s}\");\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
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

            if (needs_env) {
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

            if (needs_env) {
                try writer.print(templates.CompileAction.execute_with_env, .{ compile.source_file, optimize_str, compile.output_name });
            } else {
                try writer.print(templates.CompileAction.execute_without_env, .{ compile.source_file, optimize_str, compile.output_name });
            }
            try writer.writeAll(templates.CompileAction.cleanup_and_check);
        },

        .test_run => |test_action| {
            try writer.writeAll("    // Run tests\n");
            if (test_action.filter) |filter| {
                if (needs_env) {
                    try writer.print(templates.TestAction.execute_with_filter_and_env, .{ test_action.test_file, filter });
                } else {
                    try writer.print(templates.TestAction.execute_with_filter_no_env, .{ test_action.test_file, filter });
                }
            } else {
                if (needs_env) {
                    try writer.print(templates.TestAction.execute_without_filter_with_env, .{test_action.test_file});
                } else {
                    try writer.print(templates.TestAction.execute_without_filter_no_env, .{test_action.test_file});
                }
            }
            try writer.writeAll(templates.TestAction.cleanup_and_check);
        },

        .checkout => |checkout| {
            try writer.writeAll("    // Checkout code from repository\n");
            if (needs_env) {
                try writer.print(templates.CheckoutAction.execute_with_env, .{ checkout.branch, checkout.repository, checkout.path });
            } else {
                try writer.print(templates.CheckoutAction.execute_without_env, .{ checkout.branch, checkout.repository, checkout.path });
            }
            try writer.writeAll(templates.CheckoutAction.cleanup_and_check);
        },

        .artifact => |artifact| {
            try writer.print(templates.ArtifactAction.copy_artifact, .{ artifact.destination, artifact.source_path, artifact.destination, artifact.source_path, artifact.destination });
        },

        .recipe => |r| {
            // Generate recipe instantiation code
            try writer.writeAll("    // Recipe: ");
            try writer.writeAll(r.type_name);
            try writer.writeAll("\n");
            try writer.writeAll("    const recipe_mod = @import(\"recipe\");\n");
            try writer.writeAll("    var config = std.StringHashMap([]const u8).init(allocator);\n");
            try writer.writeAll("    defer config.deinit();\n");

            // Add all parameters to the config HashMap
            var it = r.parameters.iterator();
            while (it.next()) |entry| {
                try writer.print("    try config.put(\"{s}\", \"{s}\");\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }

            try writer.writeAll("\n");

            // Generate recipe-specific instantiation and execution
            const recipe_type_capitalized = blk: {
                if (std.mem.eql(u8, r.type_name, "docker")) break :blk "Docker";
                if (std.mem.eql(u8, r.type_name, "cache")) break :blk "Cache";
                if (std.mem.eql(u8, r.type_name, "http")) break :blk "Http";
                if (std.mem.eql(u8, r.type_name, "slack")) break :blk "Slack";
                break :blk null;
            };

            if (recipe_type_capitalized) |recipe_type| {
                try writer.print("    var {s}_instance = try recipe_mod.{s}.{s}.init(allocator, config);\n", .{ r.type_name, r.type_name, recipe_type });
                try writer.print("    defer {s}_instance.deinit(allocator);\n", .{r.type_name});
                try writer.writeAll("\n");
                try writer.print("    var {s}_recipe = {s}_instance.recipe();\n", .{ r.type_name, r.type_name });
                try writer.print("    try {s}_recipe.run(allocator, stdout);\n", .{r.type_name});
            } else {
                // Unknown recipe - use fallback template
                try writer.print(templates.Recipe.not_implemented, .{ r.type_name, r.type_name });
            }
        },
    }

    try writer.writeAll(templates.step_footer);
}

test "generate basic pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var steps = try allocator.alloc(pipeline.Step, 1);

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
        .environment = null,
    };
    defer pipe.deinit(allocator);

    const ArrayList = std.array_list.AlignedManaged(u8, null);
    var output = ArrayList.init(allocator);
    defer output.deinit();

    // This would generate files, skip in test
    // try generate(allocator, pipe, "/tmp/test-output", output.writer());
}
