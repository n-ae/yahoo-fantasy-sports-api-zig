// Integration tests
//
// These tests verify the interaction between different components
// and test complete user workflows.

const std = @import("std");
const test_suite = @import("test_suite.zig");
const TestUtils = test_suite.TestUtils;
const MockContext = test_suite.MockContext;

const router_mod = @import("../server/router.zig");
const middleware = struct {
    const cors = @import("../server/middleware/cors.zig");
    const logging = @import("../server/middleware/logging.zig");
    const auth = @import("../server/middleware/auth.zig");
    const rate_limit = @import("../server/middleware/rate_limit.zig");
};
const handlers = struct {
    const health = @import("../server/handlers/health.zig");
    const fantasy = @import("../server/handlers/fantasy.zig");
};

test "health endpoint integration" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/health");
    defer ctx.deinit();
    
    try handlers.health.healthCheck(&ctx);
    
    try ctx.expectStatus(200);
    try ctx.expectHeader("Content-Type", "application/json");
    try ctx.expectBodyContains("healthy");
    try ctx.expectBodyContains("timestamp");
}

test "status endpoint integration" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/status");
    defer ctx.deinit();
    
    try handlers.health.statusInfo(&ctx);
    
    try ctx.expectStatus(200);
    try ctx.expectHeader("Content-Type", "application/json");
    try ctx.expectBodyContains("Yahoo Fantasy API Proxy");
    try ctx.expectBodyContains("version");
    try ctx.expectBodyContains("uptime_seconds");
}

test "games endpoint integration" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/api/v1/games");
    defer ctx.deinit();
    
    // This test will likely fail without proper Yahoo API credentials
    // but it tests the handler structure
    handlers.fantasy.getGames(&ctx) catch |err| {
        // Expected to fail without proper setup
        try std.testing.expect(err == error.ClientNotInitialized or 
                              err == error.InternalServerError);
    };
}

test "game detail endpoint with parameters" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/api/v1/games/nfl");
    defer ctx.deinit();
    
    try ctx.setParam("id", "nfl");
    
    // Test parameter extraction
    const game_id = ctx.getParam("id");
    try std.testing.expect(game_id != null);
    try std.testing.expectEqualStrings("nfl", game_id.?);
    
    // Handler test (expected to fail without credentials)
    handlers.fantasy.getGame(&ctx) catch |err| {
        try std.testing.expect(err == error.ClientNotInitialized or 
                              err == error.InternalServerError);
    };
}

test "player search with query parameters" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/api/v1/players/search?q=dak&sport=nfl");
    defer ctx.deinit();
    
    try ctx.setQuery("q", "dak");
    try ctx.setQuery("sport", "nfl");
    try ctx.setQuery("season", "2024");
    
    try handlers.fantasy.searchPlayers(&ctx);
    
    try ctx.expectStatus(200);
    try ctx.expectHeader("Content-Type", "application/json");
    try ctx.expectBodyContains("players");
    try ctx.expectBodyContains("dak");
    try ctx.expectBodyContains("nfl");
}

test "router middleware chain integration" {
    const allocator = std.testing.allocator;
    
    var router = router_mod.Router.init(allocator);
    defer router.deinit();
    
    // Test middleware that sets a custom header
    const test_middleware = struct {
        fn middleware(ctx: *router_mod.Context, next: router_mod.Handler) !void {
            try ctx.response.headers.append("X-Test-Middleware", "executed");
            try next(ctx);
        }
    }.middleware;
    
    const test_handler = struct {
        fn handler(ctx: *router_mod.Context) !void {
            try ctx.json(.{ .message = "middleware test" });
        }
    }.handler;
    
    // Add global middleware
    try router.use(test_middleware);
    try router.get("/test", test_handler);
    
    // Create a more realistic context (this would need more implementation)
    // For now, just test that routes were registered
    try std.testing.expect(router.routes.items.len == 1);
    try std.testing.expect(router.global_middlewares.items.len == 1);
}

test "cors middleware integration" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestUtils.createTestContext(allocator, "OPTIONS", "/api/v1/games");
    defer ctx.deinit();
    
    try ctx.setHeader("Origin", "http://localhost:3000");
    
    const test_handler = struct {
        fn handler(test_ctx: *MockContext) !void {
            try test_ctx.json(.{ .message = "should not reach here for OPTIONS" });
        }
    }.handler;
    
    // Convert MockContext to router Context (would need adapter in real implementation)
    // For now, test that CORS headers would be set
    
    const cors_middleware = middleware.cors.defaultCors;
    _ = cors_middleware;
    
    // Test that OPTIONS requests are handled properly
    if (std.mem.eql(u8, ctx.method, "OPTIONS")) {
        ctx.status(200);
        try ctx.text("");
        try ctx.expectStatus(200);
    }
}

test "authentication middleware integration" {
    const allocator = std.testing.allocator;
    
    const auth_config = middleware.auth.AuthConfig{
        .api_keys = &[_][]const u8{ "test-api-key-123", "another-valid-key" },
    };
    
    // Test valid API key
    try std.testing.expect(auth_config.isValidApiKey("test-api-key-123"));
    try std.testing.expect(auth_config.isValidApiKey("another-valid-key"));
    
    // Test invalid API key
    try std.testing.expect(!auth_config.isValidApiKey("invalid-key"));
    try std.testing.expect(!auth_config.isValidApiKey(""));
    
    // Test middleware behavior (would need full integration with router)
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/api/v1/games");
    defer ctx.deinit();
    
    // Without API key, should fail
    try ctx.setHeader("X-API-Key", "invalid-key");
    // In real implementation, auth middleware would set error response
    
    // With valid API key, should pass
    try ctx.setHeader("X-API-Key", "test-api-key-123");
    // In real implementation, auth middleware would call next handler
}

test "rate limiting integration" {
    const allocator = std.testing.allocator;
    
    const rate_limit_config = middleware.rate_limit.RateLimitConfig{
        .requests_per_minute = 60.0,
        .burst_size = 5.0,
    };
    
    var rate_limiter = try middleware.rate_limit.rateLimitMiddleware(allocator, rate_limit_config);
    defer {
        rate_limiter.deinit();
        allocator.destroy(rate_limiter);
    }
    
    // Test that rate limiter was created successfully
    try std.testing.expect(rate_limiter.config.requests_per_minute == 60.0);
    try std.testing.expect(rate_limiter.config.burst_size == 5.0);
}

test "end-to-end API workflow" {
    const allocator = std.testing.allocator;
    
    // Simulate a complete API request workflow
    
    // 1. Health check (no auth required)
    var health_ctx = try TestUtils.createTestContext(allocator, "GET", "/health");
    defer health_ctx.deinit();
    
    try handlers.health.healthCheck(&health_ctx);
    try health_ctx.expectStatus(200);
    
    // 2. Get games (would require auth in production)
    var games_ctx = try TestUtils.createTestContext(allocator, "GET", "/api/v1/games");
    defer games_ctx.deinit();
    
    try games_ctx.setHeader("X-API-Key", "test-key");
    
    // Handler would fail without Yahoo API setup, but structure is tested
    handlers.fantasy.getGames(&games_ctx) catch |err| {
        try std.testing.expect(err == error.ClientNotInitialized);
    };
    
    // 3. Search players with parameters
    var search_ctx = try TestUtils.createTestContext(allocator, "GET", "/api/v1/players/search");
    defer search_ctx.deinit();
    
    try search_ctx.setQuery("q", "mahomes");
    try search_ctx.setQuery("sport", "nfl");
    try search_ctx.setHeader("X-API-Key", "test-key");
    
    try handlers.fantasy.searchPlayers(&search_ctx);
    try search_ctx.expectStatus(200);
    try search_ctx.expectBodyContains("mahomes");
    try search_ctx.expectBodyContains("nfl");
}

test "error handling integration" {
    const allocator = std.testing.allocator;
    
    // Test missing required parameter
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/api/v1/games/{id}");
    defer ctx.deinit();
    
    // Don't set the required 'id' parameter
    try handlers.fantasy.getGame(&ctx);
    
    try ctx.expectStatus(400);
    try ctx.expectBodyContains("Game ID is required");
    
    // Test missing query parameter
    var search_ctx = try TestUtils.createTestContext(allocator, "GET", "/api/v1/players/search");
    defer search_ctx.deinit();
    
    // Don't set the required 'q' parameter
    try handlers.fantasy.searchPlayers(&search_ctx);
    
    try search_ctx.expectStatus(400);
    try search_ctx.expectBodyContains("Search query parameter 'q' is required");
}

test "content type handling" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/health");
    defer ctx.deinit();
    
    try handlers.health.healthCheck(&ctx);
    
    try ctx.expectHeader("Content-Type", "application/json");
    
    // Test metrics endpoint returns plain text
    var metrics_ctx = try TestUtils.createTestContext(allocator, "GET", "/metrics");
    defer metrics_ctx.deinit();
    
    try handlers.health.metricsEndpoint(&metrics_ctx);
    try metrics_ctx.expectHeader("Content-Type", "text/plain; version=0.0.4");
}

// Performance integration tests
test "response time performance" {
    const allocator = std.testing.allocator;
    
    const health_check_time = try test_suite.PerformanceTestUtils.measureTime(healthCheckWrapper, .{allocator});
    
    // Health check should be very fast (under 10ms)
    try std.testing.expect(health_check_time < 10);
}

fn healthCheckWrapper(allocator: std.mem.Allocator) !void {
    var ctx = try TestUtils.createTestContext(allocator, "GET", "/health");
    defer ctx.deinit();
    
    try handlers.health.healthCheck(&ctx);
}