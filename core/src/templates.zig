const std = @import("std");

// Build.zig Templates

pub const build_header =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) !void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // Pipeline executable
    \\    const exe = b.addExecutable(.{
    \\        .name = "
;

pub const build_middle =
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
;

// Main.zig Templates

pub const main_imports_header = "const std = @import(\"std\");\n";

pub fn stepImport(step_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "const step_{s} = @import(\"step_{s}.zig\");\n",
        .{ step_id, step_id },
    );
}

pub const main_function_header =
    \\pub fn main() !void {
    \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    \\    defer _ = gpa.deinit();
    \\    const allocator = gpa.allocator();
    \\
    \\    var stdout_buffer: [4096]u8 = undefined;
    \\    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    \\    const stdout = &stdout_writer.interface;
    \\    defer stdout.flush() catch {};
    \\
    \\    // Create log directory for step outputs
    \\    const log_dir = try std.fmt.allocPrint(allocator, "/tmp/better-ci-
;

pub const main_log_dir_suffix =
    \\-{d}", .{std.time.milliTimestamp()});
    \\    defer allocator.free(log_dir);
    \\    try std.fs.cwd().makePath(log_dir);
    \\    defer std.fs.cwd().deleteTree(log_dir) catch {};
    \\
;

pub const step_result_struct =
    \\    // Step execution results
    \\    const StepResult = struct {
    \\        step_name: []const u8,
    \\        error_name: ?[]const u8 = null,
    \\        err: ?anyerror = null,
    \\    };
    \\
    \\
;

pub const main_success_footer =
    \\    try stdout.print("=== Pipeline completed successfully ===\n", .{});
    \\}
    \\
;

// Single step execution template
pub const single_step_execution =
    \\    try stdout.print("Running step: {s}...\n", .{{}});
    \\    const log_path_{s} = try std.fmt.allocPrint(allocator, "{{s}}/step_{s}.log", .{{log_dir}});
    \\    defer allocator.free(log_path_{s});
    \\    try step_{s}.execute(allocator, log_path_{s});
    \\    // Display step output
    \\    const log_content_{s} = try std.fs.cwd().readFileAlloc(allocator, log_path_{s}, 1024 * 1024);
    \\    defer allocator.free(log_content_{s});
    \\    if (log_content_{s}.len > 0) {{
    \\        try stdout.print("{{s}}", .{{log_content_{s}}});
    \\    }}
    \\    try stdout.print("✓ Step {s} completed\n\n", .{{}});
    \\
    \\
;

// Parallel step execution templates
pub const ParallelStepExecution = struct {
    pub fn allocateThreads(count: usize) ![]const u8 {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            \\    {{
            \\        var threads = try allocator.alloc(std.Thread, {d});
            \\        defer allocator.free(threads);
            \\        var results = try allocator.alloc(StepResult, {d});
            \\        defer allocator.free(results);
            \\        @memset(results, .{{ .step_name = "", .error_name = null, .err = null }});
            \\        var log_paths = try allocator.alloc([]const u8, {d});
            \\        defer allocator.free(log_paths);
            \\
            \\
            ,
            .{ count, count, count },
        );
    }

    pub fn threadFunction(index: usize, step_id: []const u8, step_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            \\        const step{d}_fn = struct {{
            \\            fn run(result: *StepResult, log_path: []const u8) void {{
            \\                var thread_gpa = std.heap.GeneralPurposeAllocator(.{{}}){{}};;
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
            ,
            .{ index, step_name, step_id },
        );
    }

    pub fn closeParallelBlock() []const u8 {
        return "    }\n\n";
    }
};

// Step implementation templates

pub const step_header =
    \\const std = @import("std");
    \\
    \\pub fn execute(allocator: std.mem.Allocator, log_path: []const u8) !void {
    \\    // Create log file for step output
    \\    const log_file = try std.fs.cwd().createFile(log_path, .{});
    \\    defer log_file.close();
    \\    var log_buffer: [4096]u8 = undefined;
    \\    var log_writer = log_file.writer(&log_buffer);
    \\    const stdout = &log_writer.interface;
    \\    defer stdout.flush() catch {};
    \\
    \\
;

pub const step_env_setup =
    \\    // Create environment map
    \\    var env_map = try std.process.getEnvMap(allocator);
    \\    defer env_map.deinit();
    \\
;

pub const step_footer = "}\n";

// Action-specific templates
pub const ShellAction = struct {
    pub const working_dir_change =
        \\    const original_dir = try std.process.getCwd();
        \\    try std.posix.chdir("{s}");
        \\    defer std.posix.chdir(original_dir) catch {};
        \\
        \\
    ;

    pub const execute_with_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "sh", "-c", "{s}" }},
        \\        .env_map = &env_map,
        \\    }});
        \\
    ;

    pub const execute_without_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "sh", "-c", "{s}" }},
        \\    }});
        \\
    ;

    pub const cleanup_and_check =
        \\    defer allocator.free(result.stdout);
        \\    defer allocator.free(result.stderr);
        \\
        \\    if (result.stdout.len > 0) {
        \\        try stdout.print("{s}", .{result.stdout});
        \\    }
        \\    if (result.stderr.len > 0) {
        \\        try stdout.print("{s}", .{result.stderr});
        \\    }
        \\
        \\    switch (result.term) {
        \\        .Exited => |code| if (code != 0) return error.CommandFailed,
        \\        else => return error.CommandFailed,
        \\    }
        \\
    ;
};

pub const CompileAction = struct {
    pub const execute_with_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "zig", "build-exe", "{s}", "-O{s}", "--name", "{s}" }},
        \\        .env_map = &env_map,
        \\    }});
        \\
    ;

    pub const execute_without_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "zig", "build-exe", "{s}", "-O{s}", "--name", "{s}" }},
        \\    }});
        \\
    ;

    pub const cleanup_and_check =
        \\    defer allocator.free(result.stdout);
        \\    defer allocator.free(result.stderr);
        \\
        \\    if (result.stdout.len > 0) try stdout.print("{s}", .{result.stdout});
        \\    if (result.stderr.len > 0) try stdout.print("{s}", .{result.stderr});
        \\
        \\    switch (result.term) {
        \\        .Exited => |code| if (code != 0) return error.CompileFailed,
        \\        else => return error.CompileFailed,
        \\    }
        \\
    ;
};

pub const TestAction = struct {
    pub const execute_with_filter_and_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "zig", "test", "{s}", "--test-filter", "{s}" }},
        \\        .env_map = &env_map,
        \\    }});
        \\
    ;

    pub const execute_with_filter_no_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "zig", "test", "{s}", "--test-filter", "{s}" }},
        \\    }});
        \\
    ;

    pub const execute_without_filter_with_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "zig", "test", "{s}" }},
        \\        .env_map = &env_map,
        \\    }});
        \\
    ;

    pub const execute_without_filter_no_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "zig", "test", "{s}" }},
        \\    }});
        \\
    ;

    pub const cleanup_and_check =
        \\    defer allocator.free(result.stdout);
        \\    defer allocator.free(result.stderr);
        \\
        \\    if (result.stdout.len > 0) try stdout.print("{s}", .{result.stdout});
        \\    if (result.stderr.len > 0) try stdout.print("{s}", .{result.stderr});
        \\
        \\    switch (result.term) {
        \\        .Exited => |code| if (code != 0) return error.TestsFailed,
        \\        else => return error.TestsFailed,
        \\    }
        \\
    ;
};

pub const CheckoutAction = struct {
    pub const execute_with_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "git", "clone", "--branch", "{s}", "--depth", "1", "{s}", "{s}" }},
        \\        .env_map = &env_map,
        \\    }});
        \\
    ;

    pub const execute_without_env =
        \\    const result = try std.process.Child.run(.{{
        \\        .allocator = allocator,
        \\        .argv = &.{{ "git", "clone", "--branch", "{s}", "--depth", "1", "{s}", "{s}" }},
        \\    }});
        \\
    ;

    pub const cleanup_and_check =
        \\    defer allocator.free(result.stdout);
        \\    defer allocator.free(result.stderr);
        \\
        \\    if (result.stdout.len > 0) try stdout.print("{s}", .{result.stdout});
        \\    if (result.stderr.len > 0) try stdout.print("{s}", .{result.stderr});
        \\
        \\    switch (result.term) {
        \\        .Exited => |code| if (code != 0) return error.CheckoutFailed,
        \\        else => return error.CheckoutFailed,
        \\    }
        \\
    ;
};

pub const ArtifactAction = struct {
    pub const copy_artifact =
        \\    // Copy artifact
        \\    _ = allocator;
        \\    try std.fs.cwd().makePath(std.fs.path.dirname("{s}") orelse ".");
        \\    try std.fs.cwd().copyFile("{s}", std.fs.cwd(), "{s}", .{{}});
        \\    try stdout.print("Artifact copied: {s} -> {s}\\n", .{{}});
        \\
    ;
};

pub const CustomAction = struct {
    pub const not_implemented =
        \\    // Custom action: {s}
        \\    // TODO: Implement custom action
        \\    try stdout.print("Custom action '{s}' not yet implemented\\n", .{{}});
        \\    return error.NotImplemented;
        \\
    ;
};
