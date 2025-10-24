// Comprehensive unit tests for SDK components
//
// This module contains detailed unit tests for each SDK component,
// focusing on isolated functionality and edge cases.

const std = @import("std");
const testing = std.testing;

// Import SDK modules
const errors = @import("../yahoo_fantasy/errors.zig");
const rate_limiter = @import("../yahoo_fantasy/rate_limiter.zig");
const cache = @import("../yahoo_fantasy/cache.zig");
const logging = @import("../yahoo_fantasy/logging.zig");
const oauth = @import("../yahoo_fantasy/oauth.zig");
const client = @import("../yahoo_fantasy/client.zig");

// ===== ERROR HANDLING TESTS =====

test "ErrorContext creation and properties" {
    const allocator = testing.allocator;
    
    const ctx = errors.ErrorContext.init(allocator, error.Unauthorized, "Test error message");
    
    try testing.expectEqualStrings("UNAUTHORIZED", ctx.code);
    try testing.expectEqualStrings("Test error message", ctx.message);
    try testing.expect(ctx.timestamp > 0);
}

test "ErrorContext with additional context" {
    const allocator = testing.allocator;
    
    const ctx = errors.ErrorContext.init(allocator, error.NotFound, "Resource not found")
        .withRequestId("req-123")
        .withDetails("Additional error details");
    
    try testing.expectEqualStrings("NOT_FOUND", ctx.code);
    try testing.expectEqualStrings("req-123", ctx.request_id.?);
    try testing.expectEqualStrings("Additional error details", ctx.details.?);
}

test "ErrorContext JSON serialization" {
    const allocator = testing.allocator;
    
    const ctx = errors.ErrorContext.init(allocator, error.RateLimited, "Too many requests")
        .withRequestId("req-456");
    
    const json = try ctx.toJson(allocator);
    defer allocator.free(json);
    
    // Should contain all expected fields
    try testing.expect(std.mem.indexOf(u8, json, "RATE_LIMITED") != null);
    try testing.expect(std.mem.indexOf(u8, json, "Too many requests") != null);
    try testing.expect(std.mem.indexOf(u8, json, "req-456") != null);
    try testing.expect(std.mem.indexOf(u8, json, "timestamp") != null);
}

test "ErrorContext retryable detection" {
    const allocator = testing.allocator;
    
    // Retryable errors
    const retryable_errors = [_]errors.YahooError{
        error.Timeout,
        error.ConnectionFailed,
        error.RateLimited,
        error.ServiceUnavailable,
        error.BadGateway,
    };
    
    for (retryable_errors) |err| {
        const ctx = errors.ErrorContext.init(allocator, err, "Test");
        try testing.expect(ctx.isRetryable());
    }
    
    // Non-retryable errors
    const non_retryable_errors = [_]errors.YahooError{
        error.Unauthorized,
        error.Forbidden,
        error.NotFound,
        error.BadRequest,
    };
    
    for (non_retryable_errors) |err| {
        const ctx = errors.ErrorContext.init(allocator, err, "Test");
        try testing.expect(!ctx.isRetryable());
    }
}

test "HTTP status to error conversion" {
    try testing.expectError(error.BadRequest, errors.httpStatusToError(400));
    try testing.expectError(error.Unauthorized, errors.httpStatusToError(401));
    try testing.expectError(error.Forbidden, errors.httpStatusToError(403));
    try testing.expectError(error.NotFound, errors.httpStatusToError(404));
    try testing.expectError(error.TooManyRequests, errors.httpStatusToError(429));
    try testing.expectError(error.InternalServerError, errors.httpStatusToError(500));
    try testing.expectError(error.BadGateway, errors.httpStatusToError(502));
    try testing.expectError(error.ServiceUnavailable, errors.httpStatusToError(503));
    try testing.expectError(error.ApiUnavailable, errors.httpStatusToError(999));
}

// ===== RATE LIMITER TESTS =====

test "RateLimiter initialization" {
    var limiter = rate_limiter.RateLimiter.init(10.0, 1.0); // 10 tokens, 1 per second
    
    try testing.expect(limiter.getRemainingTokens() == 10.0);
    try testing.expect(limiter.canMakeRequest());
}

test "RateLimiter token consumption" {
    var limiter = rate_limiter.RateLimiter.init(3.0, 1.0); // 3 tokens, 1 per second
    
    // Should allow 3 requests
    try testing.expect(limiter.canMakeRequest());
    try testing.expect(limiter.canMakeRequest());
    try testing.expect(limiter.canMakeRequest());
    
    // Fourth request should be denied
    try testing.expect(!limiter.canMakeRequest());
    
    // Should have 0 tokens remaining
    try testing.expect(limiter.getRemainingTokens() == 0.0);
}

test "RateLimiter token refill simulation" {
    var limiter = rate_limiter.RateLimiter.init(1.0, 2.0); // 1 token, 2 per second
    
    // Use the token
    try testing.expect(limiter.canMakeRequest());
    try testing.expect(!limiter.canMakeRequest());
    
    // Simulate 1 second passing
    limiter.last_refill -= 1;
    
    // Should have refilled approximately 2 tokens, but capped at capacity (1)
    try testing.expect(limiter.getRemainingTokens() > 0.5);
    try testing.expect(limiter.canMakeRequest());
}

test "RateLimiter wait time calculation" {
    var limiter = rate_limiter.RateLimiter.init(1.0, 1.0); // 1 token per second
    
    // Use the token
    try testing.expect(limiter.canMakeRequest());
    
    // Should need to wait approximately 1 second
    const wait_time = limiter.getWaitTime();
    try testing.expect(wait_time >= 900 and wait_time <= 1100); // Allow some variance
}

test "RateLimiter reset functionality" {
    var limiter = rate_limiter.RateLimiter.init(2.0, 1.0);
    
    // Exhaust tokens
    try testing.expect(limiter.canMakeRequest());
    try testing.expect(limiter.canMakeRequest());
    try testing.expect(!limiter.canMakeRequest());
    
    // Reset should restore all tokens
    limiter.reset();
    try testing.expect(limiter.canMakeRequest());
    try testing.expect(limiter.canMakeRequest());
}

test "RateLimiter endpoint-specific limiters" {
    const fantasy_limiter = rate_limiter.getLimiterForEndpoint("/fantasy/games");
    const oauth_limiter = rate_limiter.getLimiterForEndpoint("/oauth/token");
    const metadata_limiter = rate_limiter.getLimiterForEndpoint("/other/endpoint");
    
    // Should return different limiter instances
    try testing.expect(fantasy_limiter != oauth_limiter);
    try testing.expect(oauth_limiter != metadata_limiter);
    
    // Should be consistent for same endpoint type
    const another_fantasy = rate_limiter.getLimiterForEndpoint("/fantasy/leagues");
    try testing.expect(fantasy_limiter == another_fantasy);
}

test "Yahoo rate limit configurations" {
    const fantasy_config = rate_limiter.YahooRateLimits.FANTASY_API;
    try testing.expect(fantasy_config.capacity == 100.0);
    try testing.expect(fantasy_config.refill_rate == 100.0 / 3600.0);
    
    const oauth_config = rate_limiter.YahooRateLimits.OAUTH_API;
    try testing.expect(oauth_config.capacity == 10.0);
    try testing.expect(oauth_config.refill_rate == 10.0 / 300.0);
}

// ===== CACHE TESTS =====

test "Cache basic operations" {
    var cache_obj = cache.Cache.init(testing.allocator, 10, 60); // 10 items, 60s TTL
    defer cache_obj.deinit();
    
    // Test put and get
    try cache_obj.put("key1", "value1");
    const value = cache_obj.get("key1");
    try testing.expect(value != null);
    try testing.expectEqualStrings("value1", value.?);
    
    // Test non-existent key
    const missing = cache_obj.get("missing_key");
    try testing.expect(missing == null);
}

test "Cache TTL functionality" {
    var cache_obj = cache.Cache.init(testing.allocator, 10, 1); // 1 second TTL
    defer cache_obj.deinit();
    
    try cache_obj.put("key1", "value1");
    
    // Should be available immediately
    try testing.expect(cache_obj.get("key1") != null);
    
    // Manually expire the entry
    if (cache_obj.entries.getPtr("key1")) |entry| {
        entry.expires_at = std.time.timestamp() - 1; // Set to past
    }
    
    // Should be expired now
    try testing.expect(cache_obj.get("key1") == null);
}

test "Cache size limits and eviction" {
    var cache_obj = cache.Cache.init(testing.allocator, 2, 60); // Max 2 entries
    defer cache_obj.deinit();
    
    try cache_obj.put("key1", "value1");
    try cache_obj.put("key2", "value2");
    
    // Should be at capacity
    try testing.expect(cache_obj.size() == 2);
    
    // Adding third item should trigger eviction
    try cache_obj.put("key3", "value3");
    try testing.expect(cache_obj.size() == 2);
    
    // New item should be present
    try testing.expect(cache_obj.get("key3") != null);
}

test "Cache custom TTL" {
    var cache_obj = cache.Cache.init(testing.allocator, 10, 60); // Default 60s
    defer cache_obj.deinit();
    
    try cache_obj.putWithTTL("short_lived", "value", 1); // 1 second TTL
    try cache_obj.put("long_lived", "value"); // Default TTL
    
    // Both should be available initially
    try testing.expect(cache_obj.get("short_lived") != null);
    try testing.expect(cache_obj.get("long_lived") != null);
    
    // Manually expire short-lived entry
    if (cache_obj.entries.getPtr("short_lived")) |entry| {
        entry.expires_at = std.time.timestamp() - 1;
    }
    
    // Only long-lived should remain
    try testing.expect(cache_obj.get("short_lived") == null);
    try testing.expect(cache_obj.get("long_lived") != null);
}

test "Cache cleanup functionality" {
    var cache_obj = cache.Cache.init(testing.allocator, 10, 1);
    defer cache_obj.deinit();
    
    try cache_obj.put("key1", "value1");
    try cache_obj.put("key2", "value2");
    try cache_obj.put("key3", "value3");
    
    // Manually expire all entries
    var iterator = cache_obj.entries.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.expires_at = std.time.timestamp() - 1;
    }
    
    // Cleanup should remove all expired entries
    const removed = cache_obj.cleanup();
    try testing.expect(removed == 3);
    try testing.expect(cache_obj.size() == 0);
}

test "Cache statistics" {
    var cache_obj = cache.Cache.init(testing.allocator, 10, 60);
    defer cache_obj.deinit();
    
    try cache_obj.put("key1", "value1");
    try cache_obj.put("key2", "value2");
    
    // Access entries to increase access count
    _ = cache_obj.get("key1");
    _ = cache_obj.get("key1");
    _ = cache_obj.get("key2");
    
    const stats = cache_obj.getStats();
    try testing.expect(stats.total_entries == 2);
    try testing.expect(stats.expired_entries == 0);
    try testing.expect(stats.total_access_count == 3);
}

test "Cache remove functionality" {
    var cache_obj = cache.Cache.init(testing.allocator, 10, 60);
    defer cache_obj.deinit();
    
    try cache_obj.put("key1", "value1");
    try testing.expect(cache_obj.get("key1") != null);
    
    // Remove the key
    const removed = cache_obj.remove("key1");
    try testing.expect(removed);
    try testing.expect(cache_obj.get("key1") == null);
    
    // Removing non-existent key should return false
    const not_removed = cache_obj.remove("non_existent");
    try testing.expect(!not_removed);
}

test "Cache clear functionality" {
    var cache_obj = cache.Cache.init(testing.allocator, 10, 60);
    defer cache_obj.deinit();
    
    try cache_obj.put("key1", "value1");
    try cache_obj.put("key2", "value2");
    try testing.expect(cache_obj.size() == 2);
    
    cache_obj.clear();
    try testing.expect(cache_obj.size() == 0);
    try testing.expect(cache_obj.get("key1") == null);
    try testing.expect(cache_obj.get("key2") == null);
}

// ===== LOGGING TESTS =====

test "LogLevel comparison and filtering" {
    try testing.expect(logging.LogLevel.debug.shouldLog(.debug));
    try testing.expect(logging.LogLevel.info.shouldLog(.debug));
    try testing.expect(logging.LogLevel.warn.shouldLog(.debug));
    try testing.expect(logging.LogLevel.err.shouldLog(.debug));
    
    try testing.expect(!logging.LogLevel.debug.shouldLog(.info));
    try testing.expect(logging.LogLevel.info.shouldLog(.info));
    try testing.expect(logging.LogLevel.warn.shouldLog(.info));
    try testing.expect(logging.LogLevel.err.shouldLog(.info));
    
    try testing.expect(!logging.LogLevel.debug.shouldLog(.err));
    try testing.expect(!logging.LogLevel.info.shouldLog(.err));
    try testing.expect(!logging.LogLevel.warn.shouldLog(.err));
    try testing.expect(logging.LogLevel.err.shouldLog(.err));
}

test "LogLevel string conversion" {
    try testing.expectEqualStrings("DEBUG", logging.LogLevel.debug.toString());
    try testing.expectEqualStrings("INFO", logging.LogLevel.info.toString());
    try testing.expectEqualStrings("WARN", logging.LogLevel.warn.toString());
    try testing.expectEqualStrings("ERROR", logging.LogLevel.err.toString());
    
    try testing.expect(logging.LogLevel.fromString("debug") == .debug);
    try testing.expect(logging.LogLevel.fromString("info") == .info);
    try testing.expect(logging.LogLevel.fromString("warn") == .warn);
    try testing.expect(logging.LogLevel.fromString("error") == .err);
    try testing.expect(logging.LogLevel.fromString("invalid") == null);
}

test "LogContext builder pattern" {
    var context = logging.LogContext{};
    context = context.with("request_id", "req-123");
    context = context.with("status_code", @as(u16, 200));
    context = context.with("duration_ms", @as(u64, 150));
    
    try testing.expectEqualStrings("req-123", context.request_id.?);
    try testing.expect(context.status_code.? == 200);
    try testing.expect(context.duration_ms.? == 150);
}

test "Logger initialization" {
    const allocator = testing.allocator;
    const logger = logging.Logger.init(allocator, .info, .text);
    
    try testing.expect(logger.level == .info);
    try testing.expect(logger.format == .text);
}

// ===== OAUTH TESTS =====

test "OAuth credentials validation" {
    const valid_creds = oauth.Credentials{
        .consumer_key = "test_key",
        .consumer_secret = "test_secret",
    };
    
    try testing.expectEqualStrings("test_key", valid_creds.consumer_key);
    try testing.expectEqualStrings("test_secret", valid_creds.consumer_secret);
    try testing.expect(valid_creds.access_token == null);
    try testing.expect(valid_creds.access_token_secret == null);
    
    const full_creds = oauth.Credentials{
        .consumer_key = "test_key",
        .consumer_secret = "test_secret",
        .access_token = "access_token",
        .access_token_secret = "access_secret",
    };
    
    try testing.expectEqualStrings("access_token", full_creds.access_token.?);
    try testing.expectEqualStrings("access_secret", full_creds.access_token_secret.?);
}

test "OAuth client initialization" {
    const allocator = testing.allocator;
    const credentials = oauth.Credentials{
        .consumer_key = "test_key",
        .consumer_secret = "test_secret",
    };
    
    const oauth_client = oauth.OAuthClient.init(allocator, credentials);
    
    try testing.expectEqualStrings("test_key", oauth_client.credentials.consumer_key);
    try testing.expectEqualStrings("test_secret", oauth_client.credentials.consumer_secret);
}

test "OAuth parameter encoding" {
    const allocator = testing.allocator;
    
    // Test URL encoding of special characters
    const encoded = try oauth.percentEncode(allocator, "hello world & special+chars");
    defer allocator.free(encoded);
    
    try testing.expect(std.mem.indexOf(u8, encoded, "%20") != null); // space
    try testing.expect(std.mem.indexOf(u8, encoded, "%26") != null); // &
    try testing.expect(std.mem.indexOf(u8, encoded, "%2B") != null); // +
}

// ===== CLIENT TESTS =====

test "Client initialization with credentials" {
    const allocator = testing.allocator;
    const credentials = oauth.Credentials{
        .consumer_key = "test_key",
        .consumer_secret = "test_secret",
    };
    
    var test_client = try client.Client.init(allocator, credentials);
    defer test_client.deinit();
    
    try testing.expectEqualStrings("test_key", test_client.oauth_client.credentials.consumer_key);
    try testing.expect(test_client.retry_count == 3);
}

test "Client cache key generation" {
    const allocator = testing.allocator;
    const credentials = oauth.Credentials{
        .consumer_key = "test_key",
        .consumer_secret = "test_secret",
    };
    
    var test_client = try client.Client.init(allocator, credentials);
    defer test_client.deinit();
    
    // Test cache key generation with parameters
    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    
    try params.put("page", "1");
    try params.put("limit", "10");
    
    const cache_key = try test_client.buildCacheKey("games", params);
    defer allocator.free(cache_key);
    
    // Should contain endpoint and sorted parameters
    try testing.expect(std.mem.indexOf(u8, cache_key, "games") != null);
    try testing.expect(std.mem.indexOf(u8, cache_key, "limit=10") != null);
    try testing.expect(std.mem.indexOf(u8, cache_key, "page=1") != null);
}

// ===== INTEGRATION TESTS FOR COMPONENT INTERACTION =====

test "Error context with logging integration" {
    const allocator = testing.allocator;
    
    const error_ctx = errors.ErrorContext.init(allocator, error.RateLimited, "API rate limit exceeded")
        .withRequestId("req-789")
        .withDetails("Try again in 60 seconds");
    
    // Should be retryable
    try testing.expect(error_ctx.isRetryable());
    
    // Should serialize to JSON with all fields
    const json = try error_ctx.toJson(allocator);
    defer allocator.free(json);
    
    try testing.expect(std.mem.indexOf(u8, json, "RATE_LIMITED") != null);
    try testing.expect(std.mem.indexOf(u8, json, "req-789") != null);
}

test "Cache integration with rate limiter" {
    var cache_obj = cache.Cache.init(testing.allocator, 5, 30);
    defer cache_obj.deinit();
    
    var limiter = rate_limiter.RateLimiter.init(3.0, 1.0);
    
    // Simulate caching API responses to reduce rate limit pressure
    if (limiter.canMakeRequest()) {
        try cache_obj.put("api_response", "cached_data");
    }
    
    // First request should hit the "API" (consume token)
    try testing.expect(limiter.canMakeRequest());
    
    // Subsequent requests should use cache (no token consumed)
    const cached_data = cache_obj.get("api_response");
    try testing.expect(cached_data != null);
    try testing.expectEqualStrings("cached_data", cached_data.?);
    
    // Rate limiter should still have tokens since we used cache
    try testing.expect(limiter.getRemainingTokens() >= 2.0);
}

// ===== CONFIGURATION AND ENVIRONMENT TESTS =====

test "Cache configuration presets" {
    try testing.expect(cache.CacheConfig.API_RESPONSES.max_size == 1000);
    try testing.expect(cache.CacheConfig.API_RESPONSES.default_ttl == 300);
    
    try testing.expect(cache.CacheConfig.USER_DATA.max_size == 500);
    try testing.expect(cache.CacheConfig.USER_DATA.default_ttl == 900);
    
    try testing.expect(cache.CacheConfig.STATIC_DATA.max_size == 100);
    try testing.expect(cache.CacheConfig.STATIC_DATA.default_ttl == 3600);
}

test "Rate limiter configurations match Yahoo API limits" {
    // These should match Yahoo's documented rate limits
    const fantasy_limits = rate_limiter.YahooRateLimits.FANTASY_API;
    try testing.expect(fantasy_limits.capacity == 100.0);
    try testing.expect(fantasy_limits.refill_rate == 100.0 / 3600.0); // per second
    
    const oauth_limits = rate_limiter.YahooRateLimits.OAUTH_API;
    try testing.expect(oauth_limits.capacity == 10.0);
    try testing.expect(oauth_limits.refill_rate == 10.0 / 300.0); // per 5 minutes
}

// Run all unit tests
test {
    std.testing.refAllDecls(@This());
}