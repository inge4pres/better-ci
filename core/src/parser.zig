const std = @import("std");
const pipeline = @import("pipeline.zig");

/// Validation errors with context
pub const ParseError = error{
    MissingField,
    InvalidFieldValue,
    DuplicateStepId,
    EmptyPipeline,
    InvalidJson,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.StatError;

/// JSON schema structs for deserialization
/// Action JSON schema
const Action = struct {
    type: []const u8,
    // Shell action fields
    command: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
    // Compile action fields
    source_file: ?[]const u8 = null,
    output_name: ?[]const u8 = null,
    optimize: ?[]const u8 = null,
    // Test action fields
    test_file: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    // Checkout action fields
    repository: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    path: ?[]const u8 = null,
    // Artifact action fields
    source_path: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    // Custom action fields
    parameters: ?std.json.Value = null,
};

/// Define a step in the execution.
/// Depends is a list of other steps' ids.
const Step = struct {
    id: []const u8,
    name: []const u8,
    action: Action,
    depends_on: ?[][]const u8 = null,
    env: ?std.json.Value = null,
};

/// Pipeline schema describes the overall pipeline structure
const PipelineSchema = struct {
    name: []const u8,
    description: []const u8,
    steps: []Step,
};

/// Parse a pipeline definition file (JSON format)
pub fn parseDefinitionFile(allocator: std.mem.Allocator, file_path: []const u8) ParseError!pipeline.Pipeline {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("Error: Failed to open file '{s}': {s}\n", .{ file_path, @errorName(err) });
        return err;
    };
    defer file.close();

    const file_size = (try file.stat()).size;

    if (file_size == 0) {
        std.debug.print("Error: File '{s}' is empty\n", .{file_path});
        return ParseError.InvalidJson;
    }

    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    _ = try file.readAll(buffer);

    // Parse JSON
    return parseDefinition(allocator, buffer) catch |err| {
        std.debug.print("Error: Failed to parse '{s}': {s}\n", .{ file_path, @errorName(err) });
        return err;
    };
}

/// Parse a pipeline definition from JSON string
pub fn parseDefinition(allocator: std.mem.Allocator, json_str: []const u8) ParseError!pipeline.Pipeline {
    // Deserialize JSON into schema struct
    const parsed = std.json.parseFromSlice(
        PipelineSchema,
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        std.debug.print("Error: Invalid JSON syntax or structure: {s}\n", .{@errorName(err)});
        return ParseError.InvalidJson;
    };
    defer parsed.deinit();

    const pipe_json = parsed.value;

    // Validate pipeline-level fields
    if (pipe_json.name.len == 0) {
        std.debug.print("Error: Field 'name' must be a non-empty string\n", .{});
        return ParseError.InvalidFieldValue;
    }
    if (pipe_json.steps.len == 0) {
        std.debug.print("Error: Pipeline must contain at least one step\n", .{});
        return ParseError.EmptyPipeline;
    }

    // Allocate and copy pipeline name and description
    const name = try allocator.dupe(u8, pipe_json.name);
    errdefer allocator.free(name);

    const description = try allocator.dupe(u8, pipe_json.description);
    errdefer allocator.free(description);

    // Parse and validate steps
    const steps = try allocator.alloc(pipeline.Step, pipe_json.steps.len);
    var steps_parsed: usize = 0;
    errdefer {
        for (steps[0..steps_parsed]) |*step| {
            step.deinit(allocator);
        }
        allocator.free(steps);
    }

    // Track step IDs to detect duplicates
    var step_ids = std.StringHashMap(void).init(allocator);
    defer step_ids.deinit();

    for (pipe_json.steps, 0..) |step_json, i| {
        steps[i] = try parseStepFromJson(allocator, step_json, i);
        steps_parsed += 1;

        // Check for duplicate step IDs
        const gop = try step_ids.getOrPut(steps[i].id);
        if (gop.found_existing) {
            std.debug.print("Error: Duplicate step ID '{s}'\n", .{steps[i].id});
            return ParseError.DuplicateStepId;
        }
    }

    return pipeline.Pipeline{
        .name = name,
        .description = description,
        .steps = steps,
        .environment = null, // Will be set by CLI if env file is provided
    };
}

fn parseStepFromJson(allocator: std.mem.Allocator, step_json: Step, step_index: usize) ParseError!pipeline.Step {
    // Validate step ID
    if (step_json.id.len == 0) {
        std.debug.print("Error: Field 'id' must be a non-empty string in step at index {d}\n", .{step_index});
        return ParseError.InvalidFieldValue;
    }
    // Validate ID contains only valid characters (alphanumeric, underscore, hyphen)
    for (step_json.id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            std.debug.print("Error: Step ID '{s}' contains invalid character '{c}'. Only alphanumeric, underscore, and hyphen are allowed\n", .{ step_json.id, c });
            return ParseError.InvalidFieldValue;
        }
    }

    // Validate name
    if (step_json.name.len == 0) {
        std.debug.print("Error: Field 'name' must be a non-empty string in step '{s}'\n", .{step_json.id});
        return ParseError.InvalidFieldValue;
    }

    // Allocate and copy ID and name
    const id = try allocator.dupe(u8, step_json.id);
    errdefer allocator.free(id);

    const name = try allocator.dupe(u8, step_json.name);
    errdefer allocator.free(name);

    // Parse dependencies
    const depends_on = if (step_json.depends_on) |deps| blk: {
        const deps_copy = try allocator.alloc([]const u8, deps.len);
        for (deps, 0..) |dep, i| {
            if (dep.len == 0) {
                std.debug.print("Error: Dependency at index {d} must be a non-empty string in step '{s}'\n", .{ i, id });
                return ParseError.InvalidFieldValue;
            }
            deps_copy[i] = try allocator.dupe(u8, dep);
        }
        break :blk deps_copy;
    } else try allocator.alloc([]const u8, 0);
    errdefer {
        for (depends_on) |dep| {
            allocator.free(dep);
        }
        allocator.free(depends_on);
    }

    // Parse environment variables
    var env = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = env.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env.deinit();
    }
    if (step_json.env) |env_json| {
        if (env_json != .object) {
            std.debug.print("Error: Field 'env' must be an object in step '{s}'\n", .{id});
            return ParseError.InvalidFieldValue;
        }
        var it = env_json.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) {
                std.debug.print("Error: Environment variable '{s}' must be a string in step '{s}'\n", .{ entry.key_ptr.*, id });
                return ParseError.InvalidFieldValue;
            }
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = try allocator.dupe(u8, entry.value_ptr.*.string);
            try env.put(key, value);
        }
    }

    // Parse action
    const action = try parseActionFromJson(allocator, step_json.action, id);

    return pipeline.Step{
        .id = id,
        .name = name,
        .action = action,
        .depends_on = depends_on,
        .env = env,
    };
}

fn parseActionFromJson(allocator: std.mem.Allocator, action_json: Action, step_id: []const u8) ParseError!pipeline.Action {
    const action_type = action_json.type;

    if (std.mem.eql(u8, action_type, "shell")) {
        const command = action_json.command orelse {
            std.debug.print("Error: Missing required field 'command' for shell action in step '{s}'\n", .{step_id});
            return ParseError.MissingField;
        };
        if (command.len == 0) {
            std.debug.print("Error: Field 'command' must be a non-empty string in shell action for step '{s}'\n", .{step_id});
            return ParseError.InvalidFieldValue;
        }
        return pipeline.Action{
            .shell = .{
                .command = try allocator.dupe(u8, command),
                .working_dir = if (action_json.working_dir) |wd| try allocator.dupe(u8, wd) else null,
            },
        };
    } else if (std.mem.eql(u8, action_type, "compile")) {
        const source_file = action_json.source_file orelse {
            std.debug.print("Error: Missing required field 'source_file' for compile action in step '{s}'\n", .{step_id});
            return ParseError.MissingField;
        };
        if (source_file.len == 0) {
            std.debug.print("Error: Field 'source_file' must be a non-empty string in compile action for step '{s}'\n", .{step_id});
            return ParseError.InvalidFieldValue;
        }

        const output_name = action_json.output_name orelse {
            std.debug.print("Error: Missing required field 'output_name' for compile action in step '{s}'\n", .{step_id});
            return ParseError.MissingField;
        };
        if (output_name.len == 0) {
            std.debug.print("Error: Field 'output_name' must be a non-empty string in compile action for step '{s}'\n", .{step_id});
            return ParseError.InvalidFieldValue;
        }

        const optimize_str = action_json.optimize orelse {
            std.debug.print("Error: Missing required field 'optimize' for compile action in step '{s}'\n", .{step_id});
            return ParseError.MissingField;
        };
        const optimize = if (std.mem.eql(u8, optimize_str, "Debug"))
            pipeline.CompileAction.OptimizeMode.Debug
        else if (std.mem.eql(u8, optimize_str, "ReleaseSafe"))
            pipeline.CompileAction.OptimizeMode.ReleaseSafe
        else if (std.mem.eql(u8, optimize_str, "ReleaseFast"))
            pipeline.CompileAction.OptimizeMode.ReleaseFast
        else if (std.mem.eql(u8, optimize_str, "ReleaseSmall"))
            pipeline.CompileAction.OptimizeMode.ReleaseSmall
        else {
            std.debug.print("Error: Invalid optimize mode '{s}' in step '{s}'. Must be Debug, ReleaseSafe, ReleaseFast, or ReleaseSmall\n", .{ optimize_str, step_id });
            return ParseError.InvalidFieldValue;
        };

        return pipeline.Action{
            .compile = .{
                .source_file = try allocator.dupe(u8, source_file),
                .output_name = try allocator.dupe(u8, output_name),
                .optimize = optimize,
            },
        };
    } else if (std.mem.eql(u8, action_type, "test")) {
        const test_file = action_json.test_file orelse {
            std.debug.print("Error: Missing required field 'test_file' for test action in step '{s}'\n", .{step_id});
            return ParseError.MissingField;
        };
        if (test_file.len == 0) {
            std.debug.print("Error: Field 'test_file' must be a non-empty string in test action for step '{s}'\n", .{step_id});
            return ParseError.InvalidFieldValue;
        }

        return pipeline.Action{
            .test_run = .{
                .test_file = try allocator.dupe(u8, test_file),
                .filter = if (action_json.filter) |f| try allocator.dupe(u8, f) else null,
            },
        };
    } else if (std.mem.eql(u8, action_type, "checkout")) {
        const repository = action_json.repository orelse {
            std.debug.print("Error: Missing required field 'repository' for checkout action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (repository.len == 0) {
            std.debug.print("Error: Field 'repository' must be a non-empty string in checkout action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        const branch = action_json.branch orelse {
            std.debug.print("Error: Missing required field 'branch' for checkout action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (branch.len == 0) {
            std.debug.print("Error: Field 'branch' must be a non-empty string in checkout action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        const path = action_json.path orelse {
            std.debug.print("Error: Missing required field 'path' for checkout action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (path.len == 0) {
            std.debug.print("Error: Field 'path' must be a non-empty string in checkout action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        return pipeline.Action{
            .checkout = .{
                .repository = try allocator.dupe(u8, repository),
                .branch = try allocator.dupe(u8, branch),
                .path = try allocator.dupe(u8, path),
            },
        };
    } else if (std.mem.eql(u8, action_type, "artifact")) {
        const source_path = action_json.source_path orelse {
            std.debug.print("Error: Missing required field 'source_path' for artifact action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (source_path.len == 0) {
            std.debug.print("Error: Field 'source_path' must be a non-empty string in artifact action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        const destination = action_json.destination orelse {
            std.debug.print("Error: Missing required field 'destination' for artifact action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (destination.len == 0) {
            std.debug.print("Error: Field 'destination' must be a non-empty string in artifact action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        return pipeline.Action{
            .artifact = .{
                .source_path = try allocator.dupe(u8, source_path),
                .destination = try allocator.dupe(u8, destination),
            },
        };
    } else {
        // Custom action
        var parameters = std.StringHashMap([]const u8).init(allocator);
        if (action_json.parameters) |params_json| {
            if (params_json != .object) {
                std.debug.print("Error: Field 'parameters' must be an object in custom action for step '{s}'\n", .{step_id});
                return error.InvalidFieldValue;
            }
            var it = params_json.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string) {
                    std.debug.print("Error: Parameter '{s}' must be a string in custom action for step '{s}'\n", .{ entry.key_ptr.*, step_id });
                    return error.InvalidFieldValue;
                }
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const value = try allocator.dupe(u8, entry.value_ptr.*.string);
                try parameters.put(key, value);
            }
        }

        return pipeline.Action{
            .custom = .{
                .type_name = try allocator.dupe(u8, action_type),
                .parameters = parameters,
            },
        };
    }
}

test "parse simple pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "name": "test-pipeline",
        \\  "description": "A test pipeline",
        \\  "steps": [
        \\    {
        \\      "id": "build",
        \\      "name": "Build",
        \\      "action": {
        \\        "type": "shell",
        \\        "command": "zig build"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const pipe = try parseDefinition(allocator, json);
    defer pipe.deinit(allocator);

    try testing.expectEqualStrings("test-pipeline", pipe.name);
    try testing.expectEqual(@as(usize, 1), pipe.steps.len);
    try testing.expectEqualStrings("build", pipe.steps[0].id);
}

test "parse pipeline with dependencies" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "name": "complex-pipeline",
        \\  "description": "A complex pipeline",
        \\  "steps": [
        \\    {
        \\      "id": "checkout",
        \\      "name": "Checkout code",
        \\      "action": {
        \\        "type": "checkout",
        \\        "repository": "https://github.com/user/repo",
        \\        "branch": "main",
        \\        "path": "."
        \\      }
        \\    },
        \\    {
        \\      "id": "build",
        \\      "name": "Build",
        \\      "depends_on": ["checkout"],
        \\      "action": {
        \\        "type": "shell",
        \\        "command": "zig build"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const pipe = try parseDefinition(allocator, json);
    defer pipe.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), pipe.steps.len);
    try testing.expectEqual(@as(usize, 1), pipe.steps[1].depends_on.len);
    try testing.expectEqualStrings("checkout", pipe.steps[1].depends_on[0]);
}

test "parse pipeline with environment variables" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json =
        \\{
        \\  "name": "env-test",
        \\  "description": "Test env vars",
        \\  "steps": [
        \\    {
        \\      "id": "test",
        \\      "name": "Test",
        \\      "action": {
        \\        "type": "shell",
        \\        "command": "echo $VAR1"
        \\      },
        \\      "env": {
        \\        "VAR1": "value1",
        \\        "VAR2": "value2"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const pipe = try parseDefinition(allocator, json);
    defer pipe.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), pipe.steps.len);
    try testing.expectEqual(@as(usize, 2), pipe.steps[0].env.count());
    try testing.expectEqualStrings("value1", pipe.steps[0].env.get("VAR1").?);
    try testing.expectEqualStrings("value2", pipe.steps[0].env.get("VAR2").?);
}

test "parse all action types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test compile action
    const compile_json =
        \\{
        \\  "name": "test",
        \\  "description": "test",
        \\  "steps": [{
        \\    "id": "compile",
        \\    "name": "Compile",
        \\    "action": {
        \\      "type": "compile",
        \\      "source_file": "main.zig",
        \\      "output_name": "app",
        \\      "optimize": "ReleaseFast"
        \\    }
        \\  }]
        \\}
    ;
    const pipe1 = try parseDefinition(allocator, compile_json);
    defer pipe1.deinit(allocator);
    try testing.expect(pipe1.steps[0].action == .compile);

    // Test artifact action
    const artifact_json =
        \\{
        \\  "name": "test",
        \\  "description": "test",
        \\  "steps": [{
        \\    "id": "artifact",
        \\    "name": "Artifact",
        \\    "action": {
        \\      "type": "artifact",
        \\      "source_path": "app",
        \\      "destination": "dist/app"
        \\    }
        \\  }]
        \\}
    ;
    const pipe2 = try parseDefinition(allocator, artifact_json);
    defer pipe2.deinit(allocator);
    try testing.expect(pipe2.steps[0].action == .artifact);
}
