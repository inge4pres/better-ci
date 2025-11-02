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
        return error.InvalidJson;
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
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{},
    ) catch |err| {
        std.debug.print("Error: Invalid JSON syntax: {s}\n", .{@errorName(err)});
        return error.InvalidJson;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("Error: Pipeline definition must be a JSON object\n", .{});
        return error.InvalidJson;
    }

    const root = parsed.value.object;

    // Validate required fields
    const name_value = root.get("name") orelse {
        std.debug.print("Error: Missing required field 'name' in pipeline definition\n", .{});
        return error.MissingField;
    };
    if (name_value != .string or name_value.string.len == 0) {
        std.debug.print("Error: Field 'name' must be a non-empty string\n", .{});
        return error.InvalidFieldValue;
    }
    const name = try allocator.dupe(u8, name_value.string);
    errdefer allocator.free(name);

    const description_value = root.get("description") orelse {
        std.debug.print("Error: Missing required field 'description' in pipeline definition\n", .{});
        return error.MissingField;
    };
    if (description_value != .string) {
        std.debug.print("Error: Field 'description' must be a string\n", .{});
        return error.InvalidFieldValue;
    }
    const description = try allocator.dupe(u8, description_value.string);
    errdefer allocator.free(description);

    const steps_value = root.get("steps") orelse {
        std.debug.print("Error: Missing required field 'steps' in pipeline definition\n", .{});
        return error.MissingField;
    };
    if (steps_value != .array) {
        std.debug.print("Error: Field 'steps' must be an array\n", .{});
        return error.InvalidFieldValue;
    }

    const steps_array = steps_value.array;
    if (steps_array.items.len == 0) {
        std.debug.print("Error: Pipeline must contain at least one step\n", .{});
        return error.EmptyPipeline;
    }

    const steps = try allocator.alloc(pipeline.Step, steps_array.items.len);
    var steps_parsed: usize = 0;
    errdefer {
        // Only deinit the steps that were successfully parsed
        for (steps[0..steps_parsed]) |*step| {
            step.deinit(allocator);
        }
        allocator.free(steps);
    }

    // Track step IDs to detect duplicates
    var step_ids = std.StringHashMap(void).init(allocator);
    defer step_ids.deinit();

    for (steps_array.items, 0..) |step_json, i| {
        if (step_json != .object) {
            std.debug.print("Error: Step at index {d} must be a JSON object\n", .{i});
            return error.InvalidFieldValue;
        }
        steps[i] = try parseStep(allocator, step_json.object, i);
        steps_parsed += 1;

        // Check for duplicate step IDs
        const gop = try step_ids.getOrPut(steps[i].id);
        if (gop.found_existing) {
            std.debug.print("Error: Duplicate step ID '{s}'\n", .{steps[i].id});
            return error.DuplicateStepId;
        }
    }

    return pipeline.Pipeline{
        .name = name,
        .description = description,
        .steps = steps,
    };
}

fn parseStep(allocator: std.mem.Allocator, obj: std.json.ObjectMap, step_index: usize) ParseError!pipeline.Step {
    // Validate required field: id
    const id_value = obj.get("id") orelse {
        std.debug.print("Error: Missing required field 'id' in step at index {d}\n", .{step_index});
        return error.MissingField;
    };
    if (id_value != .string or id_value.string.len == 0) {
        std.debug.print("Error: Field 'id' must be a non-empty string in step at index {d}\n", .{step_index});
        return error.InvalidFieldValue;
    }
    // Validate ID contains only valid characters (alphanumeric, underscore, hyphen)
    for (id_value.string) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            std.debug.print("Error: Step ID '{s}' contains invalid character '{c}'. Only alphanumeric, underscore, and hyphen are allowed\n", .{ id_value.string, c });
            return error.InvalidFieldValue;
        }
    }

    // Now allocate after validation passes
    const id = try allocator.dupe(u8, id_value.string);
    errdefer allocator.free(id);

    // Validate required field: name
    const name_value = obj.get("name") orelse {
        std.debug.print("Error: Missing required field 'name' in step '{s}'\n", .{id});
        return error.MissingField;
    };
    if (name_value != .string or name_value.string.len == 0) {
        std.debug.print("Error: Field 'name' must be a non-empty string in step '{s}'\n", .{id});
        return error.InvalidFieldValue;
    }
    const name = try allocator.dupe(u8, name_value.string);
    errdefer allocator.free(name);

    // Parse dependencies
    const depends_on = if (obj.get("depends_on")) |deps_json| blk: {
        if (deps_json != .array) {
            std.debug.print("Error: Field 'depends_on' must be an array in step '{s}'\n", .{id});
            return error.InvalidFieldValue;
        }
        break :blk try parseDependencies(allocator, deps_json.array, id);
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
    if (obj.get("env")) |env_json| {
        if (env_json != .object) {
            std.debug.print("Error: Field 'env' must be an object in step '{s}'\n", .{id});
            return error.InvalidFieldValue;
        }
        var it = env_json.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) {
                std.debug.print("Error: Environment variable '{s}' must be a string in step '{s}'\n", .{ entry.key_ptr.*, id });
                return error.InvalidFieldValue;
            }
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = try allocator.dupe(u8, entry.value_ptr.*.string);
            try env.put(key, value);
        }
    }

    // Parse action
    const action_value = obj.get("action") orelse {
        std.debug.print("Error: Missing required field 'action' in step '{s}'\n", .{id});
        return error.MissingField;
    };
    if (action_value != .object) {
        std.debug.print("Error: Field 'action' must be an object in step '{s}'\n", .{id});
        return error.InvalidFieldValue;
    }
    const action = try parseAction(allocator, action_value.object, id);

    return pipeline.Step{
        .id = id,
        .name = name,
        .action = action,
        .depends_on = depends_on,
        .env = env,
    };
}

fn parseDependencies(allocator: std.mem.Allocator, array: std.json.Array, step_id: []const u8) ParseError![][]const u8 {
    const deps = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, i| {
        if (item != .string or item.string.len == 0) {
            std.debug.print("Error: Dependency at index {d} must be a non-empty string in step '{s}'\n", .{ i, step_id });
            return error.InvalidFieldValue;
        }
        deps[i] = try allocator.dupe(u8, item.string);
    }
    return deps;
}

fn parseAction(allocator: std.mem.Allocator, obj: std.json.ObjectMap, step_id: []const u8) ParseError!pipeline.Action {
    const type_value = obj.get("type") orelse {
        std.debug.print("Error: Missing required field 'type' in action for step '{s}'\n", .{step_id});
        return error.MissingField;
    };
    if (type_value != .string or type_value.string.len == 0) {
        std.debug.print("Error: Field 'type' must be a non-empty string in action for step '{s}'\n", .{step_id});
        return error.InvalidFieldValue;
    }
    const action_type = type_value.string;

    if (std.mem.eql(u8, action_type, "shell")) {
        const command_value = obj.get("command") orelse {
            std.debug.print("Error: Missing required field 'command' for shell action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (command_value != .string or command_value.string.len == 0) {
            std.debug.print("Error: Field 'command' must be a non-empty string in shell action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }
        return pipeline.Action{
            .shell = .{
                .command = try allocator.dupe(u8, command_value.string),
                .working_dir = if (obj.get("working_dir")) |wd| blk: {
                    if (wd != .string) {
                        std.debug.print("Error: Field 'working_dir' must be a string in shell action for step '{s}'\n", .{step_id});
                        return error.InvalidFieldValue;
                    }
                    break :blk try allocator.dupe(u8, wd.string);
                } else null,
            },
        };
    } else if (std.mem.eql(u8, action_type, "compile")) {
        const source_file_value = obj.get("source_file") orelse {
            std.debug.print("Error: Missing required field 'source_file' for compile action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (source_file_value != .string or source_file_value.string.len == 0) {
            std.debug.print("Error: Field 'source_file' must be a non-empty string in compile action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        const output_name_value = obj.get("output_name") orelse {
            std.debug.print("Error: Missing required field 'output_name' for compile action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (output_name_value != .string or output_name_value.string.len == 0) {
            std.debug.print("Error: Field 'output_name' must be a non-empty string in compile action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        const optimize_value = obj.get("optimize") orelse {
            std.debug.print("Error: Missing required field 'optimize' for compile action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (optimize_value != .string) {
            std.debug.print("Error: Field 'optimize' must be a string in compile action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }
        const optimize_str = optimize_value.string;
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
            return error.InvalidFieldValue;
        };

        return pipeline.Action{
            .compile = .{
                .source_file = try allocator.dupe(u8, source_file_value.string),
                .output_name = try allocator.dupe(u8, output_name_value.string),
                .optimize = optimize,
            },
        };
    } else if (std.mem.eql(u8, action_type, "test")) {
        const test_file_value = obj.get("test_file") orelse {
            std.debug.print("Error: Missing required field 'test_file' for test action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (test_file_value != .string or test_file_value.string.len == 0) {
            std.debug.print("Error: Field 'test_file' must be a non-empty string in test action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        return pipeline.Action{
            .test_run = .{
                .test_file = try allocator.dupe(u8, test_file_value.string),
                .filter = if (obj.get("filter")) |f| blk: {
                    if (f != .string) {
                        std.debug.print("Error: Field 'filter' must be a string in test action for step '{s}'\n", .{step_id});
                        return error.InvalidFieldValue;
                    }
                    break :blk try allocator.dupe(u8, f.string);
                } else null,
            },
        };
    } else if (std.mem.eql(u8, action_type, "checkout")) {
        const repository_value = obj.get("repository") orelse {
            std.debug.print("Error: Missing required field 'repository' for checkout action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (repository_value != .string or repository_value.string.len == 0) {
            std.debug.print("Error: Field 'repository' must be a non-empty string in checkout action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        const branch_value = obj.get("branch") orelse {
            std.debug.print("Error: Missing required field 'branch' for checkout action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (branch_value != .string or branch_value.string.len == 0) {
            std.debug.print("Error: Field 'branch' must be a non-empty string in checkout action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        const path_value = obj.get("path") orelse {
            std.debug.print("Error: Missing required field 'path' for checkout action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (path_value != .string or path_value.string.len == 0) {
            std.debug.print("Error: Field 'path' must be a non-empty string in checkout action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        return pipeline.Action{
            .checkout = .{
                .repository = try allocator.dupe(u8, repository_value.string),
                .branch = try allocator.dupe(u8, branch_value.string),
                .path = try allocator.dupe(u8, path_value.string),
            },
        };
    } else if (std.mem.eql(u8, action_type, "artifact")) {
        const source_path_value = obj.get("source_path") orelse {
            std.debug.print("Error: Missing required field 'source_path' for artifact action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (source_path_value != .string or source_path_value.string.len == 0) {
            std.debug.print("Error: Field 'source_path' must be a non-empty string in artifact action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        const destination_value = obj.get("destination") orelse {
            std.debug.print("Error: Missing required field 'destination' for artifact action in step '{s}'\n", .{step_id});
            return error.MissingField;
        };
        if (destination_value != .string or destination_value.string.len == 0) {
            std.debug.print("Error: Field 'destination' must be a non-empty string in artifact action for step '{s}'\n", .{step_id});
            return error.InvalidFieldValue;
        }

        return pipeline.Action{
            .artifact = .{
                .source_path = try allocator.dupe(u8, source_path_value.string),
                .destination = try allocator.dupe(u8, destination_value.string),
            },
        };
    } else {
        // Custom action
        var parameters = std.StringHashMap([]const u8).init(allocator);
        if (obj.get("parameters")) |params_json| {
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
