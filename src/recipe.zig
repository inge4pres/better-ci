/// Recipe module - Extensible action types for stringr pipelines
///
/// This module provides the Recipe interface and implementations for
/// custom action types that extend beyond the core action set.
///
/// Recipes are instantiated in generated pipeline code, configured with
/// parameters, and executed through their run() method.

pub const Recipe = @import("recipe/Recipe.zig").Recipe;

// Recipe implementations
pub const docker = @import("recipe/docker.zig");
pub const cache = @import("recipe/cache.zig");
pub const http = @import("recipe/http.zig");
pub const slack = @import("recipe/slack.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
