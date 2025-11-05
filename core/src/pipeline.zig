const std = @import("std");

/// Represents a complete CI pipeline
pub const Pipeline = struct {
    name: []const u8,
    description: []const u8,
    steps: []Step,
    environment: ?std.StringHashMap([]const u8) = null, // Optional global environment variables

    pub fn deinit(self: Pipeline, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        for (self.steps) |step| {
            step.deinit(allocator);
        }
        allocator.free(self.steps);

        // Free global environment variables if present
        if (self.environment) |*env| {
            var it = env.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            var env_copy = env.*;
            env_copy.deinit();
        }
    }
};

/// Represents a single step in the pipeline
pub const Step = struct {
    id: []const u8,
    name: []const u8,
    action: Action,
    depends_on: [][]const u8, // IDs of steps this depends on
    env: std.StringHashMap([]const u8), // Environment variables for this step

    pub fn deinit(self: Step, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.action.deinit(allocator);
        for (self.depends_on) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.depends_on);

        var it = self.env.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        var env_copy = self.env;
        env_copy.deinit();
    }
};

/// Different types of actions a step can perform
pub const Action = union(enum) {
    /// Run a shell command
    shell: ShellAction,

    /// Compile a Zig executable
    compile: CompileAction,

    /// Run tests
    test_run: TestAction,

    /// Checkout code from a repository
    checkout: CheckoutAction,

    /// Upload artifacts
    artifact: ArtifactAction,

    /// Custom action (for extensibility)
    custom: CustomAction,

    pub fn deinit(self: Action, allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |a| a.deinit(allocator),
        }
    }
};

pub const ShellAction = struct {
    command: []const u8,
    working_dir: ?[]const u8,

    pub fn deinit(self: ShellAction, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.working_dir) |wd| {
            allocator.free(wd);
        }
    }
};

pub const CompileAction = struct {
    source_file: []const u8,
    output_name: []const u8,
    optimize: OptimizeMode,

    pub const OptimizeMode = enum {
        Debug,
        ReleaseSafe,
        ReleaseFast,
        ReleaseSmall,
    };

    pub fn deinit(self: CompileAction, allocator: std.mem.Allocator) void {
        allocator.free(self.source_file);
        allocator.free(self.output_name);
    }
};

pub const TestAction = struct {
    test_file: []const u8,
    filter: ?[]const u8, // Optional test name filter

    pub fn deinit(self: TestAction, allocator: std.mem.Allocator) void {
        allocator.free(self.test_file);
        if (self.filter) |f| {
            allocator.free(f);
        }
    }
};

pub const CheckoutAction = struct {
    repository: []const u8,
    branch: []const u8,
    path: []const u8, // Where to checkout

    pub fn deinit(self: CheckoutAction, allocator: std.mem.Allocator) void {
        allocator.free(self.repository);
        allocator.free(self.branch);
        allocator.free(self.path);
    }
};

pub const ArtifactAction = struct {
    source_path: []const u8,
    destination: []const u8,

    pub fn deinit(self: ArtifactAction, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.destination);
    }
};

pub const CustomAction = struct {
    type_name: []const u8,
    parameters: std.StringHashMap([]const u8),

    pub fn deinit(self: CustomAction, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
        var it = self.parameters.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        var params_copy = self.parameters;
        params_copy.deinit();
    }
};

test "pipeline creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var steps = try allocator.alloc(Step, 1);

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    steps[0] = Step{
        .id = try allocator.dupe(u8, "step1"),
        .name = try allocator.dupe(u8, "Test Step"),
        .action = Action{
            .shell = ShellAction{
                .command = try allocator.dupe(u8, "echo hello"),
                .working_dir = null,
            },
        },
        .depends_on = &.{},
        .env = env,
    };

    const pipe = Pipeline{
        .name = try allocator.dupe(u8, "test-pipeline"),
        .description = try allocator.dupe(u8, "A test pipeline"),
        .steps = steps,
        .environment = null,
    };

    try testing.expectEqualStrings("test-pipeline", pipe.name);
    try testing.expectEqual(@as(usize, 1), pipe.steps.len);

    pipe.deinit(allocator);
}
