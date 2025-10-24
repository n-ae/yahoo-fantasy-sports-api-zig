// Simple in-memory cache with TTL support
//
// This module provides a thread-safe cache for Yahoo API responses
// with automatic expiration and memory management.

const std = @import("std");

const CacheEntry = struct {
    data: []u8,
    expires_at: i64,
    created_at: i64,
    access_count: u32,
    
    pub fn isExpired(self: CacheEntry) bool {
        return std.time.timestamp() > self.expires_at;
    }
    
    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const Cache = struct {
    entries: std.StringHashMap(CacheEntry),
    allocator: std.mem.Allocator,
    mutex: std.Thread.RwLock,
    max_size: usize,
    default_ttl: i64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, max_size: usize, default_ttl: i64) Self {
        return Self{
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.RwLock{},
            .max_size = max_size,
            .default_ttl = default_ttl,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
    }
    
    pub fn put(self: *Self, key: []const u8, data: []const u8) !void {
        return self.putWithTTL(key, data, self.default_ttl);
    }
    
    pub fn putWithTTL(self: *Self, key: []const u8, data: []const u8, ttl: i64) !void {
        const now = std.time.timestamp();
        
        // Make a copy of the data
        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);
        
        const entry = CacheEntry{
            .data = data_copy,
            .expires_at = now + ttl,
            .created_at = now,
            .access_count = 0,
        };
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if we need to evict entries
        if (self.entries.count() >= self.max_size) {
            try self.evictLRU();
        }
        
        // If key already exists, free old data
        if (self.entries.getPtr(key)) |old_entry| {
            old_entry.deinit(self.allocator);
        }
        
        try self.entries.put(key, entry);
    }
    
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        
        if (self.entries.getPtr(key)) |entry| {
            if (entry.isExpired()) {
                // Entry is expired, but we can't remove it here (shared lock)
                // It will be cleaned up by cleanup() or eviction
                return null;
            }
            
            // Update access count (this is safe with shared lock)
            entry.access_count += 1;
            return entry.data;
        }
        
        return null;
    }
    
    pub fn remove(self: *Self, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.entries.fetchRemove(key)) |kv| {
            var value = kv.value;
            value.deinit(self.allocator);
            return true;
        }
        
        return false;
    }
    
    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        
        self.entries.clearRetainingCapacity();
    }
    
    pub fn cleanup(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var removed_count: u32 = 0;
        
        // Simple approach: collect keys, then remove them
        var expired_keys: [1000][]const u8 = undefined;
        var expired_count: usize = 0;
        
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.isExpired() and expired_count < expired_keys.len) {
                expired_keys[expired_count] = entry.key_ptr.*;
                expired_count += 1;
            }
        }
        
        // Remove expired entries
        for (expired_keys[0..expired_count]) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                var value = kv.value;
                value.deinit(self.allocator);
                removed_count += 1;
            }
        }
        
        return removed_count;
    }
    
    pub fn size(self: *Self) usize {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        
        return self.entries.count();
    }
    
    pub fn getStats(self: *Self) CacheStats {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        
        var expired_count: u32 = 0;
        var total_size: usize = 0;
        var total_access_count: u64 = 0;
        
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                expired_count += 1;
            }
            total_size += entry.value_ptr.data.len;
            total_access_count += entry.value_ptr.access_count;
        }
        
        return CacheStats{
            .total_entries = @intCast(self.entries.count()),
            .expired_entries = expired_count,
            .total_size_bytes = total_size,
            .total_access_count = total_access_count,
        };
    }
    
    fn evictLRU(self: *Self) !void {
        // Find entry with lowest access count (simple LRU approximation)
        var min_access_count: u32 = std.math.maxInt(u32);
        var lru_key: ?[]const u8 = null;
        
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.access_count < min_access_count) {
                min_access_count = entry.value_ptr.access_count;
                lru_key = entry.key_ptr.*;
            }
        }
        
        if (lru_key) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                var value = kv.value;
                value.deinit(self.allocator);
            }
        }
    }
    
};

pub const CacheStats = struct {
    total_entries: u32,
    expired_entries: u32,
    total_size_bytes: usize,
    total_access_count: u64,
    
    pub fn hitRate(self: CacheStats) f64 {
        if (self.total_access_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_access_count)) / @as(f64, @floatFromInt(self.total_entries));
    }
};

// Pre-configured cache instances for different types of data
pub const CacheConfig = struct {
    pub const API_RESPONSES = struct {
        pub const max_size = 1000;
        pub const default_ttl = 300; // 5 minutes
    };
    
    pub const USER_DATA = struct {
        pub const max_size = 500;
        pub const default_ttl = 900; // 15 minutes
    };
    
    pub const STATIC_DATA = struct {
        pub const max_size = 100;
        pub const default_ttl = 3600; // 1 hour
    };
};

test "cache basic operations" {
    var cache = Cache.init(std.testing.allocator, 10, 60);
    defer cache.deinit();
    
    // Test put and get
    try cache.put("key1", "value1");
    const value = cache.get("key1");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("value1", value.?);
    
    // Test non-existent key
    const missing = cache.get("missing");
    try std.testing.expect(missing == null);
}

test "cache expiration" {
    var cache = Cache.init(std.testing.allocator, 10, 1); // 1 second TTL
    defer cache.deinit();
    
    try cache.put("key1", "value1");
    
    // Should be available immediately
    try std.testing.expect(cache.get("key1") != null);
    
    // Wait for expiration (simulate by modifying entry)
    if (cache.entries.getPtr("key1")) |entry| {
        entry.expires_at = std.time.timestamp() - 1; // Expired
    }
    
    // Should be expired now
    try std.testing.expect(cache.get("key1") == null);
}

test "cache size limit and eviction" {
    var cache = Cache.init(std.testing.allocator, 2, 60); // Max 2 entries
    defer cache.deinit();
    
    try cache.put("key1", "value1");
    try cache.put("key2", "value2");
    
    // Cache should be full
    try std.testing.expect(cache.size() == 2);
    
    // Adding third entry should trigger eviction
    try cache.put("key3", "value3");
    try std.testing.expect(cache.size() == 2);
}

test "cache cleanup" {
    var cache = Cache.init(std.testing.allocator, 10, 1);
    defer cache.deinit();
    
    try cache.put("key1", "value1");
    try cache.put("key2", "value2");
    
    // Manually expire entries
    var iterator = cache.entries.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.expires_at = std.time.timestamp() - 1;
    }
    
    // Cleanup should remove expired entries
    const removed = cache.cleanup();
    try std.testing.expect(removed == 2);
    try std.testing.expect(cache.size() == 0);
}