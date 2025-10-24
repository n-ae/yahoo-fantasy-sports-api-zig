// Simple token bucket rate limiter
//
// This module provides a thread-safe token bucket rate limiter
// for controlling Yahoo API request rates.

const std = @import("std");

pub const RateLimiter = struct {
    tokens: f64,
    capacity: f64,
    refill_rate: f64,
    last_refill: i64,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(capacity: f64, refill_rate: f64) Self {
        return Self{
            .tokens = capacity,
            .capacity = capacity,
            .refill_rate = refill_rate,
            .last_refill = std.time.timestamp(),
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn canMakeRequest(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.refill();
        
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        
        return false;
    }
    
    pub fn waitForToken(self: *Self) void {
        while (!self.canMakeRequest()) {
            std.time.sleep(100 * std.time.ns_per_ms); // 100ms
        }
    }
    
    pub fn getWaitTime(self: *Self) i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.refill();
        
        if (self.tokens >= 1.0) {
            return 0;
        }
        
        const tokens_needed = 1.0 - self.tokens;
        const wait_seconds = tokens_needed / self.refill_rate;
        return @intFromFloat(wait_seconds * 1000); // Convert to milliseconds
    }
    
    pub fn getRemainingTokens(self: *Self) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.refill();
        return self.tokens;
    }
    
    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.tokens = self.capacity;
        self.last_refill = std.time.timestamp();
    }
    
    fn refill(self: *Self) void {
        const now = std.time.timestamp();
        const time_passed = @as(f64, @floatFromInt(now - self.last_refill));
        
        if (time_passed > 0) {
            const tokens_to_add = time_passed * self.refill_rate;
            self.tokens = @min(self.capacity, self.tokens + tokens_to_add);
            self.last_refill = now;
        }
    }
};

// Predefined rate limiters for different Yahoo API endpoints
pub const YahooRateLimits = struct {
    // Yahoo's documented rate limits
    pub const FANTASY_API = RateLimiter.init(100.0, 100.0 / 3600.0); // 100 requests per hour
    pub const OAUTH_API = RateLimiter.init(10.0, 10.0 / 300.0);      // 10 requests per 5 minutes
    pub const METADATA_API = RateLimiter.init(50.0, 50.0 / 3600.0);  // 50 requests per hour
    
    pub fn getForEndpoint(endpoint: []const u8) RateLimiter {
        if (std.mem.startsWith(u8, endpoint, "/fantasy/")) {
            return FANTASY_API;
        } else if (std.mem.startsWith(u8, endpoint, "/oauth/")) {
            return OAUTH_API;
        } else {
            return METADATA_API;
        }
    }
};

// Global rate limiter instances
var fantasy_limiter: ?RateLimiter = null;
var oauth_limiter: ?RateLimiter = null;
var metadata_limiter: ?RateLimiter = null;
var limiter_init_once = std.once(initLimiters);

fn initLimiters() void {
    fantasy_limiter = YahooRateLimits.FANTASY_API;
    oauth_limiter = YahooRateLimits.OAUTH_API;
    metadata_limiter = YahooRateLimits.METADATA_API;
}

pub fn getLimiterForEndpoint(endpoint: []const u8) *RateLimiter {
    limiter_init_once.call();
    
    if (std.mem.startsWith(u8, endpoint, "/fantasy/")) {
        return &fantasy_limiter.?;
    } else if (std.mem.startsWith(u8, endpoint, "/oauth/")) {
        return &oauth_limiter.?;
    } else {
        return &metadata_limiter.?;
    }
}

test "rate limiter basic functionality" {
    var limiter = RateLimiter.init(2.0, 1.0); // 2 tokens, 1 per second
    
    // Should allow first request
    try std.testing.expect(limiter.canMakeRequest());
    
    // Should allow second request
    try std.testing.expect(limiter.canMakeRequest());
    
    // Should deny third request (no tokens left)
    try std.testing.expect(!limiter.canMakeRequest());
}

test "rate limiter refill" {
    var limiter = RateLimiter.init(1.0, 2.0); // 1 token, 2 per second
    
    // Use the token
    try std.testing.expect(limiter.canMakeRequest());
    try std.testing.expect(!limiter.canMakeRequest());
    
    // Manually set last_refill to simulate time passage
    limiter.last_refill -= 1; // 1 second ago
    
    // Should have refilled
    try std.testing.expect(limiter.canMakeRequest());
}

test "rate limiter wait time calculation" {
    var limiter = RateLimiter.init(1.0, 1.0); // 1 token per second
    
    // Use the token
    try std.testing.expect(limiter.canMakeRequest());
    
    // Should need to wait approximately 1 second (1000ms)
    const wait_time = limiter.getWaitTime();
    try std.testing.expect(wait_time > 900 and wait_time < 1100);
}

test "rate limiter reset" {
    var limiter = RateLimiter.init(2.0, 1.0);
    
    // Use all tokens
    try std.testing.expect(limiter.canMakeRequest());
    try std.testing.expect(limiter.canMakeRequest());
    try std.testing.expect(!limiter.canMakeRequest());
    
    // Reset should restore all tokens
    limiter.reset();
    try std.testing.expect(limiter.canMakeRequest());
    try std.testing.expect(limiter.canMakeRequest());
}