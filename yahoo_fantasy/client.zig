const std = @import("std");
const http = std.http;
const OAuth = @import("oauth.zig");
const errors = @import("errors.zig");
const rate_limiter = @import("rate_limiter.zig");
const cache = @import("cache.zig");
const logging = @import("logging.zig");

pub const ClientError = errors.YahooError;

pub const ApiResponse = struct {
    status_code: u16,
    body: []u8,
    headers: std.StringHashMap([]const u8),

    pub fn deinit(self: *ApiResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    oauth_client: OAuth.OAuthClient,
    base_url: []const u8,
    response_cache: cache.Cache,
    rate_limiters: std.StringHashMap(*rate_limiter.RateLimiter),
    retry_count: u8,

    const Self = @This();
    const BASE_URL = "https://fantasysports.yahooapis.com/fantasy/v2";

    pub fn init(allocator: std.mem.Allocator, credentials: OAuth.Credentials) !Self {
        const rate_limiters_map = std.StringHashMap(*rate_limiter.RateLimiter).init(allocator);
        
        return Self{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .oauth_client = OAuth.OAuthClient.init(allocator, credentials),
            .base_url = BASE_URL,
            .response_cache = cache.Cache.init(allocator, cache.CacheConfig.API_RESPONSES.max_size, cache.CacheConfig.API_RESPONSES.default_ttl),
            .rate_limiters = rate_limiters_map,
            .retry_count = 3,
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        self.response_cache.deinit();
        self.rate_limiters.deinit();
    }

    pub fn get(self: *Self, endpoint: []const u8, params: ?std.StringHashMap([]const u8)) !ApiResponse {
        return try self.requestWithCache("GET", endpoint, params, null);
    }

    pub fn post(self: *Self, endpoint: []const u8, params: ?std.StringHashMap([]const u8), body: ?[]const u8) !ApiResponse {
        return try self.request("POST", endpoint, params, body);
    }

    pub fn put(self: *Self, endpoint: []const u8, params: ?std.StringHashMap([]const u8), body: ?[]const u8) !ApiResponse {
        return try self.request("PUT", endpoint, params, body);
    }

    pub fn delete(self: *Self, endpoint: []const u8, params: ?std.StringHashMap([]const u8)) !ApiResponse {
        return try self.request("DELETE", endpoint, params, null);
    }

    fn requestWithCache(
        self: *Self,
        method: []const u8,
        endpoint: []const u8,
        params: ?std.StringHashMap([]const u8),
        body: ?[]const u8,
    ) !ApiResponse {
        // Only cache GET requests
        if (std.mem.eql(u8, method, "GET")) {
            const cache_key = try self.buildCacheKey(endpoint, params);
            defer self.allocator.free(cache_key);
            
            if (self.response_cache.get(cache_key)) |cached_body| {
                logging.debug("Cache hit for {s}", .{endpoint});
                const body_copy = try self.allocator.dupe(u8, cached_body);
                return ApiResponse{
                    .status_code = 200,
                    .body = body_copy,
                    .headers = std.StringHashMap([]const u8).init(self.allocator),
                };
            }
            
            const response = try self.request(method, endpoint, params, body);
            
            // Cache successful responses
            if (response.status_code == 200) {
                self.response_cache.put(cache_key, response.body) catch |err| {
                    logging.warn("Failed to cache response: {}", .{err});
                };
            }
            
            return response;
        }
        
        return try self.request(method, endpoint, params, body);
    }
    
    fn request(
        self: *Self,
        method: []const u8,
        endpoint: []const u8,
        params: ?std.StringHashMap([]const u8),
        body: ?[]const u8,
    ) !ApiResponse {
        // Rate limiting
        const limiter = rate_limiter.getLimiterForEndpoint(endpoint);
        if (!limiter.canMakeRequest()) {
            const wait_time = limiter.getWaitTime();
            logging.warn("Rate limited on {s}, waiting {d}ms", .{ endpoint, wait_time });
            if (wait_time > 5000) { // Don't wait more than 5 seconds
                return error.RateLimited;
            }
            limiter.waitForToken();
        }
        
        const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_url, endpoint });
        defer self.allocator.free(url);
        
        const start_time = std.time.milliTimestamp();
        
        logging.debug("Making {s} request to {s}", .{ method, endpoint });

        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();

        const auth_header = try self.oauth_client.generateAuthHeader(method, url, params);
        defer self.allocator.free(auth_header);

        try headers.append("Authorization", auth_header);
        try headers.append("Accept", "application/json");
        try headers.append("User-Agent", "Yahoo Fantasy Zig Client/1.0");

        if (body != null) {
            try headers.append("Content-Type", "application/json");
        }

        var req = try self.http_client.open(
            if (std.mem.eql(u8, method, "GET")) .GET 
            else if (std.mem.eql(u8, method, "POST")) .POST
            else if (std.mem.eql(u8, method, "PUT")) .PUT
            else if (std.mem.eql(u8, method, "DELETE")) .DELETE
            else return ClientError.RequestFailed,
            uri,
            headers,
            .{},
        );
        defer req.deinit();

        req.transfer_encoding = .chunked;

        try req.send();

        if (body) |request_body| {
            try req.writeAll(request_body);
        }

        try req.finish();
        try req.wait();

        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);

        var response_headers = std.StringHashMap([]const u8).init(self.allocator);
        var header_iter = req.response.iterateHeaders();
        while (header_iter.next()) |header| {
            const key = try self.allocator.dupe(u8, header.name);
            const value = try self.allocator.dupe(u8, header.value);
            try response_headers.put(key, value);
        }

        const duration = std.time.milliTimestamp() - start_time;
        const status_code = @intFromEnum(req.response.status);
        
        logging.logRequest(method, endpoint, status_code, @intCast(duration));
        
        // Handle HTTP errors
        if (status_code >= 400) {
            const error_ctx = errors.ErrorContext.init(self.allocator, errors.httpStatusToError(status_code), "HTTP request failed");
            var log_ctx = logging.LogContext{};
            log_ctx = log_ctx.with("endpoint", endpoint);
            log_ctx = log_ctx.with("status_code", status_code);
            logging.errCtx(log_ctx, "Request failed: {s}", .{error_ctx.message});
            
            if (status_code == 429) {
                return error.RateLimited;
            } else if (status_code == 401) {
                return error.Unauthorized;
            } else if (status_code == 404) {
                return error.NotFound;
            }
        }
        
        return ApiResponse{
            .status_code = status_code,
            .body = response_body,
            .headers = response_headers,
        };
    }
    
    fn buildCacheKey(self: *Self, endpoint: []const u8, params: ?std.StringHashMap([]const u8)) ![]u8 {
        var key_parts = std.ArrayList(u8).init(self.allocator);
        defer key_parts.deinit();
        
        try key_parts.appendSlice(endpoint);
        
        if (params) |param_map| {
            // Sort parameters for consistent cache keys
            var param_list = std.ArrayList(struct { key: []const u8, value: []const u8 }).init(self.allocator);
            defer param_list.deinit();
            
            var iterator = param_map.iterator();
            while (iterator.next()) |entry| {
                try param_list.append(.{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
            }
            
            // Simple sort by key
            std.mem.sort(@TypeOf(param_list.items[0]), param_list.items, {}, struct {
                fn lessThan(context: void, lhs: @TypeOf(param_list.items[0]), rhs: @TypeOf(param_list.items[0])) bool {
                    _ = context;
                    return std.mem.lessThan(u8, lhs.key, rhs.key);
                }
            }.lessThan);
            
            for (param_list.items) |param| {
                try key_parts.append('&');
                try key_parts.appendSlice(param.key);
                try key_parts.append('=');
                try key_parts.appendSlice(param.value);
            }
        }
        
        return self.allocator.dupe(u8, key_parts.items);
    }
};

test "client initialization" {
    const allocator = std.testing.allocator;
    const credentials = OAuth.Credentials{
        .consumer_key = "test_key",
        .consumer_secret = "test_secret",
    };

    var client = try Client.init(allocator, credentials);
    defer client.deinit();

    try std.testing.expectEqualSlices(u8, "test_key", client.oauth_client.credentials.consumer_key);
}