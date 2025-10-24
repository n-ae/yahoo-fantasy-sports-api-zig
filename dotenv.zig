const std = @import("std");

pub const DotEnv = struct {
    allocator: std.mem.Allocator,
    env_vars: std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .env_vars = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.env_vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env_vars.deinit();
    }

    pub fn load(self: *Self) !void {
        return self.loadFile(".env");
    }

    pub fn loadFile(self: *Self, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // .env file is optional, continue without error
                return;
            },
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            
            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");

                if (key.len == 0) continue;

                const key_owned = try self.allocator.dupe(u8, key);
                const value_owned = try self.allocator.dupe(u8, value);

                try self.env_vars.put(key_owned, value_owned);
            }
        }
    }

    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        // First check our loaded env vars
        if (self.env_vars.get(key)) |value| {
            return value;
        }
        
        // Fall back to system environment variables
        return std.process.getEnvVarOwned(self.allocator, key) catch null;
    }

    pub fn getOwned(self: *const Self, key: []const u8) !?[]u8 {
        // First check our loaded env vars
        if (self.env_vars.get(key)) |value| {
            return try self.allocator.dupe(u8, value);
        }
        
        // Fall back to system environment variables
        return std.process.getEnvVarOwned(self.allocator, key) catch null;
    }
};

test "dotenv basic functionality" {
    const allocator = std.testing.allocator;
    
    // Create a test .env file
    const test_env_content = "TEST_KEY=test_value\nANOTHER_KEY=another_value\n# This is a comment\nEMPTY_KEY=\n";
    
    var test_file = try std.fs.cwd().createFile(".test_env", .{});
    defer test_file.close();
    defer std.fs.cwd().deleteFile(".test_env") catch {};
    
    try test_file.writeAll(test_env_content);
    
    var env = DotEnv.init(allocator);
    defer env.deinit();
    
    try env.loadFile(".test_env");
    
    try std.testing.expectEqualSlices(u8, "test_value", env.get("TEST_KEY").?);
    try std.testing.expectEqualSlices(u8, "another_value", env.get("ANOTHER_KEY").?);
    try std.testing.expectEqualSlices(u8, "", env.get("EMPTY_KEY").?);
    try std.testing.expect(env.get("NONEXISTENT_KEY") == null);
}