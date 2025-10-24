// Comprehensive test suite
//
// This module runs all tests and provides test utilities
// for the Yahoo Fantasy API project.

const std = @import("std");

// Import all test modules
const oauth_tests = @import("../yahoo_fantasy/oauth.zig");
const client_tests = @import("../yahoo_fantasy/client.zig");
const errors_tests = @import("../yahoo_fantasy/errors.zig");
const rate_limiter_tests = @import("../yahoo_fantasy/rate_limiter.zig");
const cache_tests = @import("../yahoo_fantasy/cache.zig");
const logging_tests = @import("../yahoo_fantasy/logging.zig");
const router_tests = @import("../server/router.zig");
const cors_tests = @import("../server/middleware/cors.zig");
const logging_middleware_tests = @import("../server/middleware/logging.zig");
const auth_tests = @import("../server/middleware/auth.zig");
const rate_limit_middleware_tests = @import("../server/middleware/rate_limit.zig");
const health_tests = @import("../server/handlers/health.zig");
const fantasy_tests = @import("../server/handlers/fantasy.zig");

// Test utilities
pub const TestUtils = struct {
    pub fn createTestAllocator() std.testing.Allocator {
        return std.testing.allocator;
    }
    
    pub fn createMockClient(allocator: std.mem.Allocator) !@import("../yahoo_fantasy/client.zig").Client {
        const credentials = @import("../yahoo_fantasy/oauth.zig").Credentials{
            .consumer_key = "test_key",
            .consumer_secret = "test_secret",
        };
        return @import("../yahoo_fantasy/client.zig").Client.init(allocator, credentials);
    }
    
    pub fn expectJsonEqual(expected: []const u8, actual: []const u8) !void {
        // Parse both JSON strings and compare
        const allocator = std.testing.allocator;
        
        const expected_parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            expected,
            .{},
        );
        defer expected_parsed.deinit();
        
        const actual_parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            actual,
            .{},
        );
        defer actual_parsed.deinit();
        
        try expectJsonValueEqual(expected_parsed.value, actual_parsed.value);
    }
    
    fn expectJsonValueEqual(expected: std.json.Value, actual: std.json.Value) !void {
        switch (expected) {
            .null => try std.testing.expect(actual == .null),
            .bool => |exp_bool| {
                try std.testing.expect(actual == .bool);
                try std.testing.expect(actual.bool == exp_bool);
            },
            .integer => |exp_int| {
                try std.testing.expect(actual == .integer);
                try std.testing.expect(actual.integer == exp_int);
            },
            .float => |exp_float| {
                try std.testing.expect(actual == .float);
                try std.testing.expect(actual.float == exp_float);
            },
            .string => |exp_str| {
                try std.testing.expect(actual == .string);
                try std.testing.expectEqualStrings(exp_str, actual.string);
            },
            .array => |exp_array| {
                try std.testing.expect(actual == .array);
                try std.testing.expect(exp_array.items.len == actual.array.items.len);
                for (exp_array.items, actual.array.items) |exp_item, act_item| {
                    try expectJsonValueEqual(exp_item, act_item);
                }
            },
            .object => |exp_obj| {
                try std.testing.expect(actual == .object);
                try std.testing.expect(exp_obj.count() == actual.object.count());
                
                var exp_iterator = exp_obj.iterator();
                while (exp_iterator.next()) |exp_entry| {
                    const act_value = actual.object.get(exp_entry.key_ptr.*) orelse {
                        std.debug.print("Missing key in actual: {s}\n", .{exp_entry.key_ptr.*});
                        return error.TestExpectedEqual;
                    };
                    try expectJsonValueEqual(exp_entry.value_ptr.*, act_value);
                }
            },
        }
    }
    
    pub fn createTestContext(allocator: std.mem.Allocator, method: []const u8, path: []const u8) !MockContext {
        return MockContext.init(allocator, method, path);
    }
};

// Mock context for testing handlers
pub const MockContext = struct {
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    params: std.StringHashMap([]const u8),
    query: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    response_status: u16 = 200,
    response_body: ?[]const u8 = null,
    response_headers: std.StringHashMap([]const u8),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, method: []const u8, path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .method = method,
            .path = path,
            .params = std.StringHashMap([]const u8).init(allocator),
            .query = std.StringHashMap([]const u8).init(allocator),
            .headers = std.StringHashMap([]const u8).init(allocator),
            .response_headers = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.params.deinit();
        self.query.deinit();
        self.headers.deinit();
        self.response_headers.deinit();
        if (self.response_body) |body| {
            self.allocator.free(body);
        }
    }
    
    pub fn setParam(self: *Self, key: []const u8, value: []const u8) !void {
        try self.params.put(key, value);
    }
    
    pub fn setQuery(self: *Self, key: []const u8, value: []const u8) !void {
        try self.query.put(key, value);
    }
    
    pub fn setHeader(self: *Self, key: []const u8, value: []const u8) !void {
        try self.headers.put(key, value);
    }
    
    pub fn getParam(self: *Self, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }
    
    pub fn getQuery(self: *Self, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }
    
    pub fn json(self: *Self, data: anytype) !void {
        const json_string = try std.json.stringify(data, .{}, self.allocator);
        if (self.response_body) |old_body| {
            self.allocator.free(old_body);
        }
        self.response_body = json_string;
        try self.response_headers.put("Content-Type", "application/json");
    }
    
    pub fn text(self: *Self, content: []const u8) !void {
        if (self.response_body) |old_body| {
            self.allocator.free(old_body);
        }
        self.response_body = try self.allocator.dupe(u8, content);
        try self.response_headers.put("Content-Type", "text/plain");
    }
    
    pub fn status(self: *Self, code: u16) *Self {
        self.response_status = code;
        return self;
    }
    
    pub fn notFound(self: *Self) !void {
        self.status(404);
        try self.json(.{ .error = "Not Found", .message = "The requested resource was not found" });
    }
    
    pub fn badRequest(self: *Self, message: []const u8) !void {
        self.status(400);
        try self.json(.{ .error = "Bad Request", .message = message });
    }
    
    pub fn internalServerError(self: *Self, message: []const u8) !void {
        self.status(500);
        try self.json(.{ .error = "Internal Server Error", .message = message });
    }
    
    pub fn expectStatus(self: *Self, expected_status: u16) !void {
        try std.testing.expect(self.response_status == expected_status);
    }
    
    pub fn expectHeader(self: *Self, key: []const u8, expected_value: []const u8) !void {
        const actual_value = self.response_headers.get(key) orelse {
            std.debug.print("Expected header '{s}' not found\n", .{key});
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(expected_value, actual_value);
    }
    
    pub fn expectBodyContains(self: *Self, expected_substring: []const u8) !void {
        const body = self.response_body orelse {
            std.debug.print("Expected response body to contain '{s}' but body is null\n", .{expected_substring});
            return error.TestExpectedEqual;
        };
        
        if (std.mem.indexOf(u8, body, expected_substring) == null) {
            std.debug.print("Expected response body to contain '{s}'\nActual body: {s}\n", .{ expected_substring, body });
            return error.TestExpectedEqual;
        }
    }
};

// Integration test helpers
pub const IntegrationTestHelper = struct {
    pub fn setupTestEnvironment() void {
        // Set test environment variables
        std.process.setEnvVar("LOG_LEVEL", "debug") catch {};
        std.process.setEnvVar("LOG_FORMAT", "text") catch {};
        std.process.setEnvVar("ENVIRONMENT", "test") catch {};
    }
    
    pub fn cleanupTestEnvironment() void {
        // Cleanup any test artifacts
    }
    
    pub fn runTestServer(allocator: std.mem.Allocator, port: u16) !std.Thread {
        _ = allocator;
        _ = port;
        // This would start a test server instance in a separate thread
        return std.Thread.spawn(.{}, testServerMain, .{});
    }
    
    fn testServerMain() void {
        // Test server implementation
    }
};

// Performance test utilities
pub const PerformanceTestUtils = struct {
    pub fn measureTime(comptime func: anytype, args: anytype) !i64 {
        const start = std.time.milliTimestamp();
        _ = try @call(.auto, func, args);
        const end = std.time.milliTimestamp();
        return end - start;
    }
    
    pub fn runBenchmark(comptime func: anytype, args: anytype, iterations: u32) !struct { min: i64, max: i64, avg: i64 } {
        var times = try std.ArrayList(i64).initCapacity(std.testing.allocator, iterations);
        defer times.deinit();
        
        for (0..iterations) |_| {
            const time = try measureTime(func, args);
            try times.append(time);
        }
        
        var min: i64 = std.math.maxInt(i64);
        var max: i64 = std.math.minInt(i64);
        var sum: i64 = 0;
        
        for (times.items) |time| {
            min = @min(min, time);
            max = @max(max, time);
            sum += time;
        }
        
        const avg = @divTrunc(sum, @as(i64, @intCast(iterations)));
        
        return .{ .min = min, .max = max, .avg = avg };
    }
};

// Run all tests
test {
    std.testing.refAllDecls(@This());
    
    // Setup test environment
    IntegrationTestHelper.setupTestEnvironment();
    defer IntegrationTestHelper.cleanupTestEnvironment();
    
    // Run imported tests
    std.testing.refAllDecls(oauth_tests);
    std.testing.refAllDecls(client_tests);
    std.testing.refAllDecls(errors_tests);
    std.testing.refAllDecls(rate_limiter_tests);
    std.testing.refAllDecls(cache_tests);
    std.testing.refAllDecls(logging_tests);
    std.testing.refAllDecls(router_tests);
    std.testing.refAllDecls(cors_tests);
    std.testing.refAllDecls(logging_middleware_tests);
    std.testing.refAllDecls(auth_tests);
    std.testing.refAllDecls(rate_limit_middleware_tests);
    std.testing.refAllDecls(health_tests);
    std.testing.refAllDecls(fantasy_tests);
}

test "test utilities work correctly" {
    const allocator = std.testing.allocator;
    
    // Test mock context
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/test");
    defer ctx.deinit();
    
    try ctx.setParam("id", "123");
    try ctx.setQuery("page", "1");
    
    try std.testing.expectEqualStrings("123", ctx.getParam("id").?);
    try std.testing.expectEqualStrings("1", ctx.getQuery("page").?);
    
    // Test JSON response
    try ctx.json(.{ .message = "test", .code = 200 });
    try ctx.expectStatus(200);
    try ctx.expectHeader("Content-Type", "application/json");
    try ctx.expectBodyContains("test");
}

test "performance measurement works" {
    const test_func = struct {
        fn dummy(value: u32) u32 {
            return value * 2;
        }
    }.dummy;
    
    const time = try PerformanceTestUtils.measureTime(test_func, .{42});
    try std.testing.expect(time >= 0);
    
    const benchmark = try PerformanceTestUtils.runBenchmark(test_func, .{42}, 10);
    try std.testing.expect(benchmark.min <= benchmark.avg);
    try std.testing.expect(benchmark.avg <= benchmark.max);
}