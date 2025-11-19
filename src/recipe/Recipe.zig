const std = @import("std");

/// Recipe interface using VTable pattern for extensible pipeline actions
///
/// Recipes are instantiated in generated pipeline code with configuration,
/// execute their action, and clean up resources.
///
/// Example usage in generated code:
/// ```zig
/// var config = std.StringHashMap([]const u8).init(allocator);
/// try config.put("image", "nginx:latest");
///
/// var docker = try recipe_mod.docker.Docker.init(allocator, config);
/// defer docker.deinit(allocator);
///
/// try docker.recipe().run(allocator);
/// ```
pub const Recipe = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Initialize the recipe with configuration parameters
        init: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) anyerror!void,

        /// Execute the recipe action
        run: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void,

        /// Clean up recipe resources
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn init(self: Recipe, allocator: std.mem.Allocator, config: std.StringHashMap([]const u8)) !void {
        return self.vtable.init(self.ptr, allocator, config);
    }

    pub fn run(self: Recipe, allocator: std.mem.Allocator) !void {
        return self.vtable.run(self.ptr, allocator);
    }

    pub fn deinit(self: Recipe, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

