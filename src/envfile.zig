const std = @import("std");

/// Parse errors
pub const ParseError = error{
    InvalidFormat,
    MissingEquals,
    EmptyKey,
} || std.fs.File.OpenError || std.fs.File.ReadError || std.mem.Allocator.Error;

/// Parse a .env file and return a StringHashMap with environment variables
/// The caller is responsible for freeing both the map and its contents
pub fn parseEnvFile(allocator: std.mem.Allocator, file_path: []const u8) ParseError!std.StringHashMap([]const u8) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB
    defer allocator.free(content);

    return try parseEnvString(allocator, content);
}

/// Parse environment variables from a string in .env format
/// The caller is responsible for freeing both the map and its contents
pub fn parseEnvString(allocator: std.mem.Allocator, content: []const u8) ParseError!std.StringHashMap([]const u8) {
    var env_map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env_map.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Find the equals sign
        const equals_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            return ParseError.MissingEquals;
        };

        if (equals_pos == 0) {
            return ParseError.EmptyKey;
        }

        const key = std.mem.trim(u8, trimmed[0..equals_pos], " \t");
        const value = if (equals_pos + 1 < trimmed.len)
            std.mem.trim(u8, trimmed[equals_pos + 1 ..], " \t")
        else
            "";

        // Validate key contains only alphanumeric and underscore
        for (key) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                return ParseError.InvalidFormat;
            }
        }

        // Check if key already exists
        const existing_entry = env_map.getEntry(key);
        if (existing_entry) |entry| {
            // Key exists - just replace the value
            const value_copy = try allocator.dupe(u8, value);
            allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = value_copy;
        } else {
            // New key - allocate both key and value
            const key_copy = try allocator.dupe(u8, key);
            errdefer allocator.free(key_copy);
            const value_copy = try allocator.dupe(u8, value);
            errdefer allocator.free(value_copy);

            try env_map.put(key_copy, value_copy);
        }
    }

    return env_map;
}

/// Free an environment map created by parseEnvFile or parseEnvString
pub fn freeEnvMap(allocator: std.mem.Allocator, env_map: *std.StringHashMap([]const u8)) void {
    var it = env_map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    env_map.deinit();
}

// Tests

test "parse simple env file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "KEY1=value1\nKEY2=value2\n";

    var env_map = try parseEnvString(allocator, content);
    defer freeEnvMap(allocator, &env_map);

    try testing.expectEqual(@as(usize, 2), env_map.count());
    try testing.expectEqualStrings("value1", env_map.get("KEY1").?);
    try testing.expectEqualStrings("value2", env_map.get("KEY2").?);
}

test "parse env with whitespace" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "  KEY1  =  value1  \n\tKEY2\t=\tvalue2\t\n";

    var env_map = try parseEnvString(allocator, content);
    defer freeEnvMap(allocator, &env_map);

    try testing.expectEqual(@as(usize, 2), env_map.count());
    try testing.expectEqualStrings("value1", env_map.get("KEY1").?);
    try testing.expectEqualStrings("value2", env_map.get("KEY2").?);
}

test "parse env with empty lines and comments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content =
        \\# This is a comment
        \\KEY1=value1
        \\
        \\# Another comment
        \\KEY2=value2
        \\
        \\
    ;

    var env_map = try parseEnvString(allocator, content);
    defer freeEnvMap(allocator, &env_map);

    try testing.expectEqual(@as(usize, 2), env_map.count());
    try testing.expectEqualStrings("value1", env_map.get("KEY1").?);
    try testing.expectEqualStrings("value2", env_map.get("KEY2").?);
}

test "parse env with empty value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "KEY1=\nKEY2=value2\n";

    var env_map = try parseEnvString(allocator, content);
    defer freeEnvMap(allocator, &env_map);

    try testing.expectEqual(@as(usize, 2), env_map.count());
    try testing.expectEqualStrings("", env_map.get("KEY1").?);
    try testing.expectEqualStrings("value2", env_map.get("KEY2").?);
}

test "parse env with duplicate keys - last wins" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "KEY1=value1\nKEY1=value2\n";

    var env_map = try parseEnvString(allocator, content);
    defer freeEnvMap(allocator, &env_map);

    try testing.expectEqual(@as(usize, 1), env_map.count());
    try testing.expectEqualStrings("value2", env_map.get("KEY1").?);
}

test "parse env with underscores in key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "MY_KEY_1=value1\n_PRIVATE=value2\n";

    var env_map = try parseEnvString(allocator, content);
    defer freeEnvMap(allocator, &env_map);

    try testing.expectEqual(@as(usize, 2), env_map.count());
    try testing.expectEqualStrings("value1", env_map.get("MY_KEY_1").?);
    try testing.expectEqualStrings("value2", env_map.get("_PRIVATE").?);
}

test "parse env missing equals - error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "KEY1value1\n";

    const result = parseEnvString(allocator, content);
    try testing.expectError(ParseError.MissingEquals, result);
}

test "parse env empty key - error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "=value1\n";

    const result = parseEnvString(allocator, content);
    try testing.expectError(ParseError.EmptyKey, result);
}

test "parse env invalid key characters - error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "KEY-1=value1\n";

    const result = parseEnvString(allocator, content);
    try testing.expectError(ParseError.InvalidFormat, result);
}

test "parse env file - integration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create temporary .env file
    const temp_path = "/tmp/test-stringr.env";
    const file = try std.fs.cwd().createFile(temp_path, .{});
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    try file.writeAll("# Test env file\nTEST_KEY=test_value\nANOTHER=123\n");
    file.close();

    var env_map = try parseEnvFile(allocator, temp_path);
    defer freeEnvMap(allocator, &env_map);

    try testing.expectEqual(@as(usize, 2), env_map.count());
    try testing.expectEqualStrings("test_value", env_map.get("TEST_KEY").?);
    try testing.expectEqualStrings("123", env_map.get("ANOTHER").?);
}
