//! Yahoo Fantasy Sports SDK - Zig Implementation
//! Core API client with authentication, rate limiting, and caching

const std = @import("std");
const print = std.debug.print;
const json = std.json;
const fs = std.fs;

// Main SDK client
pub const YahooFantasyClient = struct {
    allocator: std.mem.Allocator,
    consumer_key: []const u8,
    consumer_secret: []const u8,
    access_token: ?[]const u8,
    access_token_secret: ?[]const u8,
    base_url: []const u8,
    rate_limiter: *RateLimiter,
    cache: *Cache,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, consumer_key: []const u8, consumer_secret: []const u8) !*Self {
        const client = try allocator.create(Self);
        client.* = Self{
            .allocator = allocator,
            .consumer_key = try allocator.dupe(u8, consumer_key),
            .consumer_secret = try allocator.dupe(u8, consumer_secret),
            .access_token = null,
            .access_token_secret = null,
            .base_url = "https://fantasysports.yahooapis.com/fantasy/v2",
            .rate_limiter = try RateLimiter.init(allocator),
            .cache = try Cache.init(allocator),
        };
        return client;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.consumer_key);
        self.allocator.free(self.consumer_secret);
        if (self.access_token) |token| self.allocator.free(token);
        if (self.access_token_secret) |secret| self.allocator.free(secret);
        self.rate_limiter.deinit();
        self.cache.deinit();
        self.allocator.destroy(self);
    }

    pub fn setTokens(self: *Self, access_token: []const u8, access_token_secret: []const u8) !void {
        if (self.access_token) |old_token| self.allocator.free(old_token);
        if (self.access_token_secret) |old_secret| self.allocator.free(old_secret);

        self.access_token = try self.allocator.dupe(u8, access_token);
        self.access_token_secret = try self.allocator.dupe(u8, access_token_secret);
    }

    pub fn isAuthenticated(self: *Self) bool {
        return self.access_token != null and self.access_token_secret != null;
    }

    pub fn getGames(self: *Self) ![]Game {
        // Mock implementation for testing
        var games = try self.allocator.alloc(Game, 3);
        games[0] = Game{
            .game_key = try self.allocator.dupe(u8, "nfl.2024"),
            .name = try self.allocator.dupe(u8, "NFL Football"),
            .code = try self.allocator.dupe(u8, "nfl"),
            .season = 2024,
        };
        games[1] = Game{
            .game_key = try self.allocator.dupe(u8, "nba.2024"),
            .name = try self.allocator.dupe(u8, "NBA Basketball"),
            .code = try self.allocator.dupe(u8, "nba"),
            .season = 2024,
        };
        games[2] = Game{
            .game_key = try self.allocator.dupe(u8, "mlb.2024"),
            .name = try self.allocator.dupe(u8, "MLB Baseball"),
            .code = try self.allocator.dupe(u8, "mlb"),
            .season = 2024,
        };
        return games;
    }

    pub fn getLeagues(self: *Self, game_key: []const u8) ![]League {
        _ = game_key; // Mock implementation
        var leagues = try self.allocator.alloc(League, 1);
        leagues[0] = League{
            .league_key = try self.allocator.dupe(u8, "423.l.12345"),
            .name = try self.allocator.dupe(u8, "My Test League"),
            .num_teams = 12,
            .current_week = 15,
        };
        return leagues;
    }
};

// Data structures
pub const Game = struct {
    game_key: []const u8,
    name: []const u8,
    code: []const u8,
    season: i32,

    pub fn deinit(self: *Game, allocator: std.mem.Allocator) void {
        allocator.free(self.game_key);
        allocator.free(self.name);
        allocator.free(self.code);
    }
};

pub const League = struct {
    league_key: []const u8,
    name: []const u8,
    num_teams: i32,
    current_week: i32,

    pub fn deinit(self: *League, allocator: std.mem.Allocator) void {
        allocator.free(self.league_key);
        allocator.free(self.name);
    }
};

// Rate limiter using token bucket algorithm
const RateLimiter = struct {
    allocator: std.mem.Allocator,
    tokens: f64,
    max_tokens: f64,
    refill_rate: f64,
    last_refill: i64,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*RateLimiter {
        const limiter = try allocator.create(RateLimiter);
        limiter.* = RateLimiter{
            .allocator = allocator,
            .tokens = 100.0,
            .max_tokens = 100.0,
            .refill_rate = 0.83, // ~3000 requests/hour
            .last_refill = std.time.timestamp(),
            .mutex = std.Thread.Mutex{},
        };
        return limiter;
    }

    pub fn deinit(self: *RateLimiter) void {
        self.allocator.destroy(self);
    }

    pub fn canMakeRequest(self: *RateLimiter) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.refillTokens();
        return self.tokens >= 1.0;
    }

    pub fn recordRequest(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
        }
    }

    fn refillTokens(self: *RateLimiter) void {
        const now = std.time.timestamp();
        const time_passed = @as(f64, @floatFromInt(now - self.last_refill));

        const tokens_to_add = time_passed * self.refill_rate;
        self.tokens = @min(self.max_tokens, self.tokens + tokens_to_add);
        self.last_refill = now;
    }
};

// Simple in-memory cache with TTL
const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    max_size: usize,
    mutex: std.Thread.Mutex,

    const CacheEntry = struct {
        data: []const u8,
        timestamp: i64,
        ttl: i64,

        pub fn isExpired(self: CacheEntry) bool {
            return std.time.timestamp() > (self.timestamp + self.ttl);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !*Cache {
        const cache = try allocator.create(Cache);
        cache.* = Cache{
            .allocator = allocator,
            .entries = std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .max_size = 1000,
            .mutex = std.Thread.Mutex{},
        };
        return cache;
    }

    pub fn deinit(self: *Cache) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.data);
        }
        self.entries.deinit();
        self.allocator.destroy(self);
    }

    pub fn get(self: *Cache, key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(key)) |entry| {
            if (!entry.isExpired()) {
                return entry.data;
            } else {
                // Remove expired entry
                _ = self.entries.remove(key);
            }
        }
        return null;
    }

    pub fn put(self: *Cache, key: []const u8, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = CacheEntry{
            .data = try self.allocator.dupe(u8, data),
            .timestamp = std.time.timestamp(),
            .ttl = 300, // 5 minutes
        };

        const key_copy = try self.allocator.dupe(u8, key);
        try self.entries.put(key_copy, entry);
    }
};

// Load environment variable from .env file
fn loadEnvVar(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    // First try to get from actual environment
    if (std.process.getEnvVarOwned(allocator, key)) |value| {
        return value;
    } else |_| {
        // If not found, try to load from .env file
        const env_file = fs.cwd().openFile("../.env", .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer env_file.close();

        const content = try env_file.readToEndAlloc(allocator, 4096);
        defer allocator.free(content);

        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
                const env_key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                const env_value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

                if (std.mem.eql(u8, env_key, key)) {
                    return try allocator.dupe(u8, env_value);
                }
            }
        }

        return null;
    }
}

// Demo function
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("Yahoo Fantasy Sports SDK - Zig Implementation\n", .{});
    print("===========================================\n\n", .{});

    // Load credentials from environment
    const consumer_key = try loadEnvVar(allocator, "YAHOO_CONSUMER_KEY");
    const consumer_secret = try loadEnvVar(allocator, "YAHOO_CONSUMER_SECRET");

    if (consumer_key == null or consumer_secret == null) {
        print("Error: YAHOO_CONSUMER_KEY and YAHOO_CONSUMER_SECRET must be set\n", .{});
        print("Please check your .env file or environment variables\n", .{});
        return;
    }

    defer if (consumer_key) |key| allocator.free(key);
    defer if (consumer_secret) |secret| allocator.free(secret);

    var client = try YahooFantasyClient.init(allocator, consumer_key.?, consumer_secret.?);
    defer client.deinit();

    print("✓ SDK Client initialized\n", .{});
    print("  Authenticated: {}\n", .{client.isAuthenticated()});

    // Demo with mock data
    try client.setTokens("mock_token", "mock_secret");
    print("✓ Tokens set, authenticated: {}\n", .{client.isAuthenticated()});

    const games = try client.getGames();
    defer {
        for (games) |*game| {
            game.deinit(allocator);
        }
        allocator.free(games);
    }

    print("\n✓ Retrieved {} games:\n", .{games.len});
    for (games) |game| {
        print("  - {} ({s}): {s}\n", .{ game.season, game.code, game.name });
    }

    print("\n✓ Zig SDK demo completed successfully\n", .{});
}

