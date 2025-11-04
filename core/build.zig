const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The core compiler executable
    const exe = b.addExecutable(.{
        .name = "better-ci",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
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

    const run_step = b.step("run", "Run the better-ci compiler");
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

    // Generate example pipelines
    const examples_step = b.step("examples", "Generate example pipelines");

    // List of example definitions to generate
    const example_definitions = [_]struct { json: []const u8, output: []const u8 }{
        .{ .json = "examples/hello-world.json", .output = "examples/_generated/hello-world" },
        .{ .json = "examples/simple-pipeline.json", .output = "examples/_generated/simple-pipeline" },
        .{ .json = "examples/parallel-pipeline.json", .output = "examples/_generated/parallel-pipeline" },
    };

    inline for (example_definitions) |example| {
        const generate_cmd = b.addRunArtifact(exe);
        generate_cmd.step.dependOn(b.getInstallStep());
        generate_cmd.addArgs(&.{ "generate", example.json, example.output });
        examples_step.dependOn(&generate_cmd.step);
    }
}
