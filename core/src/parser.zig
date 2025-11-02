const std = @import("std");
const pipeline = @import("pipeline.zig");

/// Parse a pipeline definition file (JSON format)
pub fn parseDefinitionFile(allocator: std.mem.Allocator, file_path: []const u8) !pipeline.Pipeline {
    // Read the file
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    _ = try file.readAll(buffer);

    // Parse JSON
    return try parseDefinition(allocator, buffer);
}

/// Parse a pipeline definition from JSON string
pub fn parseDefinition(allocator: std.mem.Allocator, json_str: []const u8) !pipeline.Pipeline {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value.object;

    const name = try allocator.dupe(u8, root.get("name").?.string);
    const description = try allocator.dupe(u8, root.get("description").?.string);

    const steps_array = root.get("steps").?.array;
    const steps = try allocator.alloc(pipeline.Step, steps_array.items.len);

    for (steps_array.items, 0..) |step_json, i| {
        steps[i] = try parseStep(allocator, step_json.object);
    }

    return pipeline.Pipeline{
        .name = name,
        .description = description,
        .steps = steps,
    };
}

fn parseStep(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !pipeline.Step {
    const id = try allocator.dupe(u8, obj.get("id").?.string);
    const name = try allocator.dupe(u8, obj.get("name").?.string);

    // Parse dependencies
    const depends_on = if (obj.get("depends_on")) |deps_json|
        try parseDependencies(allocator, deps_json.array)
    else
        try allocator.alloc([]const u8, 0);

    // Parse environment variables
    var env = std.StringHashMap([]const u8).init(allocator);
    if (obj.get("env")) |env_json| {
        var it = env_json.object.iterator();
        while (it.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value = try allocator.dupe(u8, entry.value_ptr.*.string);
            try env.put(key, value);
        }
    }

    // Parse action
    const action_obj = obj.get("action").?.object;
    const action = try parseAction(allocator, action_obj);

    return pipeline.Step{
        .id = id,
        .name = name,
        .action = action,
        .depends_on = depends_on,
        .env = env,
    };
}

fn parseDependencies(allocator: std.mem.Allocator, array: std.json.Array) ![][]const u8 {
    const deps = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, i| {
        deps[i] = try allocator.dupe(u8, item.string);
    }
    return deps;
}

fn parseAction(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !pipeline.Action {
    const action_type = obj.get("type").?.string;

    if (std.mem.eql(u8, action_type, "shell")) {
        return pipeline.Action{
            .shell = .{
                .command = try allocator.dupe(u8, obj.get("command").?.string),
                .working_dir = if (obj.get("working_dir")) |wd|
                    try allocator.dupe(u8, wd.string)
                else
                    null,
            },
        };
    } else if (std.mem.eql(u8, action_type, "compile")) {
        const optimize_str = obj.get("optimize").?.string;
        const optimize = if (std.mem.eql(u8, optimize_str, "Debug"))
            pipeline.CompileAction.OptimizeMode.Debug
        else if (std.mem.eql(u8, optimize_str, "ReleaseSafe"))
            pipeline.CompileAction.OptimizeMode.ReleaseSafe
        else if (std.mem.eql(u8, optimize_str, "ReleaseFast"))
            pipeline.CompileAction.OptimizeMode.ReleaseFast
        else
            pipeline.CompileAction.OptimizeMode.ReleaseSmall;

        return pipeline.Action{
            .compile = .{
                .source_file = try allocator.dupe(u8, obj.get("source_file").?.string),
                .output_name = try allocator.dupe(u8, obj.get("output_name").?.string),
                .optimize = optimize,
            },
        };
    } else if (std.mem.eql(u8, action_type, "test")) {
        return pipeline.Action{
            .test_run = .{
                .test_file = try allocator.dupe(u8, obj.get("test_file").?.string),
                .filter = if (obj.get("filter")) |f|
                    try allocator.dupe(u8, f.string)
                else
                    null,
            },
        };
    } else if (std.mem.eql(u8, action_type, "checkout")) {
        return pipeline.Action{
            .checkout = .{
                .repository = try allocator.dupe(u8, obj.get("repository").?.string),
                .branch = try allocator.dupe(u8, obj.get("branch").?.string),
                .path = try allocator.dupe(u8, obj.get("path").?.string),
            },
        };
    } else if (std.mem.eql(u8, action_type, "artifact")) {
        return pipeline.Action{
            .artifact = .{
                .source_path = try allocator.dupe(u8, obj.get("source_path").?.string),
                .destination = try allocator.dupe(u8, obj.get("destination").?.string),
            },
        };
    } else {
        // Custom action
        var parameters = std.StringHashMap([]const u8).init(allocator);
        if (obj.get("parameters")) |params_json| {
            var it = params_json.object.iterator();
            while (it.next()) |entry| {
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
