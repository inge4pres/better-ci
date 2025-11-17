const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // dependencies
    const clap = b.dependency("clap", .{});

    // The core compiler executable
    const exe = b.addExecutable(.{
        .name = "stringr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "clap",
                    .module = clap.module("clap"),
                },
            },
        }),
    });

    b.installArtifact(exe);

    // Run command for testing the compiler
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow passing arguments to the compiler
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the stringr compiler");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Recipes module - exported for use by generated pipelines
    const recipes_mod = b.addModule("recipes", .{
        .root_source_file = b.path("src/recipe.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Test recipes module
    const run_recipes_tests = b.addTest(.{
        .root_module = recipes_mod,
    });

    const run_recipes_test = b.addRunArtifact(run_recipes_tests);
    test_step.dependOn(&run_recipes_test.step);

    // Generate example pipelines
    const examples_step = b.step("examples", "Generate example pipelines");

    // Dynamically discover all .json files in examples directory
    // Use b.path() to get a path relative to build.zig, which works regardless of where build is executed from
    const examples_path = b.path("examples").getPath3(b, null);
    var examples_dir = examples_path.openDir("", .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open examples directory: {}\n", .{err});
        return;
    };
    defer examples_dir.close();

    var iterator = examples_dir.iterate();
    while (iterator.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        // Only process .json files
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        // Extract the base name (without .json extension)
        const base_name = entry.name[0 .. entry.name.len - 5];

        // Build the paths
        const json_path = b.fmt("examples/{s}", .{entry.name});
        const output_path = b.fmt("examples/_generated/{s}", .{base_name});

        // Create the generate command for this example
        const generate_cmd = b.addRunArtifact(exe);
        generate_cmd.step.dependOn(b.getInstallStep());
        generate_cmd.addArgs(&.{ "generate", "--in", json_path, "--out", output_path });
        examples_step.dependOn(&generate_cmd.step);
    }
}
