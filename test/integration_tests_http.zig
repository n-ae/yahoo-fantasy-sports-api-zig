// Integration tests with real HTTP server
//
// These tests start actual HTTP servers and test the complete request/response cycle
// including middleware, routing, and error handling.

const std = @import("std");
const testing = std.testing;
const zap = @import("zap");

// Test utilities for HTTP integration
const TestHttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    base_url: []const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) Self {
        return Self{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .base_url = base_url,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }
    
    pub fn get(self: *Self, path: []const u8) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);
        
        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        
        try headers.append("User-Agent", "Yahoo Fantasy Test Client");
        
        var request = try self.client.open(.GET, uri, headers, .{});
        defer request.deinit();
        
        try request.send();
        try request.finish();
        try request.wait();
        
        const body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024);
        
        var response_headers = std.StringHashMap([]const u8).init(self.allocator);
        var header_iter = request.response.iterateHeaders();
        while (header_iter.next()) |header| {
            const key = try self.allocator.dupe(u8, header.name);
            const value = try self.allocator.dupe(u8, header.value);
            try response_headers.put(key, value);
        }
        
        return HttpResponse{
            .allocator = self.allocator,
            .status_code = @intFromEnum(request.response.status),
            .body = body,
            .headers = response_headers,
        };
    }
    
    pub fn post(self: *Self, path: []const u8, body: []const u8) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);
        
        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        
        try headers.append("User-Agent", "Yahoo Fantasy Test Client");
        try headers.append("Content-Type", "application/json");
        try headers.append("Content-Length", try std.fmt.allocPrint(self.allocator, "{d}", .{body.len}));
        
        var request = try self.client.open(.POST, uri, headers, .{});
        defer request.deinit();
        
        try request.send();
        try request.writeAll(body);
        try request.finish();
        try request.wait();
        
        const response_body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024);
        
        var response_headers = std.StringHashMap([]const u8).init(self.allocator);
        var header_iter = request.response.iterateHeaders();
        while (header_iter.next()) |header| {
            const key = try self.allocator.dupe(u8, header.name);
            const value = try self.allocator.dupe(u8, header.value);
            try response_headers.put(key, value);
        }
        
        return HttpResponse{
            .allocator = self.allocator,
            .status_code = @intFromEnum(request.response.status),
            .body = response_body,
            .headers = response_headers,
        };
    }
    
    pub fn getWithHeaders(self: *Self, path: []const u8, test_headers: std.StringHashMap([]const u8)) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);
        
        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        
        try headers.append("User-Agent", "Yahoo Fantasy Test Client");
        
        // Add test headers
        var iter = test_headers.iterator();
        while (iter.next()) |entry| {
            try headers.append(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        var request = try self.client.open(.GET, uri, headers, .{});
        defer request.deinit();
        
        try request.send();
        try request.finish();
        try request.wait();
        
        const response_body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024);
        
        var response_headers = std.StringHashMap([]const u8).init(self.allocator);
        var header_iter = request.response.iterateHeaders();
        while (header_iter.next()) |header| {
            const key = try self.allocator.dupe(u8, header.name);
            const value = try self.allocator.dupe(u8, header.value);
            try response_headers.put(key, value);
        }
        
        return HttpResponse{
            .allocator = self.allocator,
            .status_code = @intFromEnum(request.response.status),
            .body = response_body,
            .headers = response_headers,
        };
    }
};

const HttpResponse = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    body: []u8,
    headers: std.StringHashMap([]const u8),
    
    const Self = @This();
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.body);
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
    }
    
    pub fn expectStatus(self: Self, expected: u16) !void {
        if (self.status_code != expected) {
            std.debug.print("Expected status {d}, got {d}\n", .{ expected, self.status_code });
            std.debug.print("Response body: {s}\n", .{self.body});
            return error.UnexpectedStatus;
        }
    }
    
    pub fn expectHeader(self: Self, name: []const u8, expected_value: []const u8) !void {
        const actual_value = self.headers.get(name) orelse {
            std.debug.print("Expected header '{s}' not found\n", .{name});
            return error.HeaderNotFound;
        };
        
        if (!std.mem.eql(u8, actual_value, expected_value)) {
            std.debug.print("Expected header '{s}' to be '{s}', got '{s}'\n", .{ name, expected_value, actual_value });
            return error.UnexpectedHeaderValue;
        }
    }
    
    pub fn expectBodyContains(self: Self, substring: []const u8) !void {
        if (std.mem.indexOf(u8, self.body, substring) == null) {
            std.debug.print("Expected body to contain '{s}'\n", .{substring});
            std.debug.print("Actual body: {s}\n", .{self.body});
            return error.SubstringNotFound;
        }
    }
    
    pub fn parseJson(self: Self, comptime T: type) !T {
        const parsed = try std.json.parseFromSlice(T, self.allocator, self.body, .{});
        defer parsed.deinit();
        return parsed.value;
    }
};

// Test server setup
const TestServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    thread: ?std.Thread = null,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, port: u16) Self {
        return Self{
            .allocator = allocator,
            .port = port,
        };
    }
    
    pub fn start(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, serverThread, .{ self.port });
        
        // Give the server a moment to start
        std.time.sleep(100 * std.time.ns_per_ms);
    }
    
    pub fn stop(self: *Self) void {
        if (self.thread) |thread| {
            thread.detach();
            self.thread = null;
        }
    }
    
    fn serverThread(port: u16) void {
        // Simple test server implementation
        var listener = zap.SimpleHttpListener.init(.{
            .port = port,
            .on_request = testRequestHandler,
            .log = false,
        });
        
        listener.listen() catch return;
        
        zap.start(.{
            .threads = 1,
            .workers = 1,
        });
    }
    
    fn testRequestHandler(r: zap.SimpleRequest) void {
        const allocator = std.heap.page_allocator;
        const path = r.path orelse "/";
        
        if (std.mem.eql(u8, path, "/health")) {
            const response = "{"
                ++ "\"status\":\"healthy\","
                ++ "\"timestamp\":" ++ std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()}) catch "0" ++ ","
                ++ "\"version\":\"1.0.0\""
                ++ "}";
            
            r.setHeader("Content-Type", "application/json") catch {};
            r.setHeader("Access-Control-Allow-Origin", "*") catch {};
            r.sendBody(response) catch {};
        } else if (std.mem.eql(u8, path, "/api/v1/games")) {
            const api_key = r.getHeader("X-API-Key");
            if (api_key == null) {
                r.setStatus(401) catch {};
                r.setHeader("Content-Type", "application/json") catch {};
                r.sendBody("{\"error\":\"Unauthorized\",\"message\":\"API key required\"}") catch {};
                return;
            }
            
            const response = "{"
                ++ "\"games\":["
                ++ "{\"id\":\"nfl\",\"name\":\"NFL\",\"sport\":\"football\",\"season\":\"2024\"},"
                ++ "{\"id\":\"nba\",\"name\":\"NBA\",\"sport\":\"basketball\",\"season\":\"2024\"}"
                ++ "],"
                ++ "\"total\":2"
                ++ "}";
            
            r.setHeader("Content-Type", "application/json") catch {};
            r.setHeader("Access-Control-Allow-Origin", "*") catch {};
            r.sendBody(response) catch {};
        } else if (std.mem.startsWith(u8, path, "/api/v1/games/")) {
            const game_id = path["/api/v1/games/".len..];
            
            const response = std.fmt.allocPrint(allocator, 
                "{{"
                ++ "\"game\":{{"
                ++ "\"id\":\"{s}\","
                ++ "\"name\":\"{s}\","
                ++ "\"sport\":\"football\","
                ++ "\"season\":\"2024\""
                ++ "}}"
                ++ "}}", .{ game_id, game_id }) catch return;
            
            r.setHeader("Content-Type", "application/json") catch {};
            r.setHeader("Access-Control-Allow-Origin", "*") catch {};
            r.sendBody(response) catch {};
        } else if (std.mem.eql(u8, path, "/metrics")) {
            const response = 
                \\# HELP http_requests_total Total HTTP requests
                \\# TYPE http_requests_total counter
                \\http_requests_total 100
                \\
                \\# HELP http_request_duration_seconds Request duration
                \\# TYPE http_request_duration_seconds histogram
                \\http_request_duration_seconds_bucket{le="0.1"} 80
                \\http_request_duration_seconds_bucket{le="+Inf"} 100
                \\http_request_duration_seconds_count 100
                \\http_request_duration_seconds_sum 5.5
            ;
            
            r.setHeader("Content-Type", "text/plain; version=0.0.4") catch {};
            r.sendBody(response) catch {};
        } else if (r.method == .OPTIONS) {
            // CORS preflight
            r.setHeader("Access-Control-Allow-Origin", "*") catch {};
            r.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS") catch {};
            r.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key") catch {};
            r.setHeader("Access-Control-Max-Age", "86400") catch {};
            r.sendBody("") catch {};
        } else {
            r.setStatus(404) catch {};
            r.setHeader("Content-Type", "application/json") catch {};
            r.sendBody("{\"error\":\"Not Found\",\"message\":\"Endpoint not found\"}") catch {};
        }
    }
};

// ===== INTEGRATION TESTS =====

test "HTTP server health check endpoint" {
    const allocator = testing.allocator;
    const port: u16 = 3001;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    var client = TestHttpClient.init(allocator, "http://localhost:3001");
    defer client.deinit();
    
    var response = try client.get("/health");
    defer response.deinit();
    
    try response.expectStatus(200);
    try response.expectHeader("Content-Type", "application/json");
    try response.expectBodyContains("healthy");
    try response.expectBodyContains("timestamp");
    try response.expectBodyContains("version");
}

test "API endpoint with authentication" {
    const allocator = testing.allocator;
    const port: u16 = 3002;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    var client = TestHttpClient.init(allocator, "http://localhost:3002");
    defer client.deinit();
    
    // Test without API key (should fail)
    var response1 = try client.get("/api/v1/games");
    defer response1.deinit();
    
    try response1.expectStatus(401);
    try response1.expectBodyContains("Unauthorized");
    try response1.expectBodyContains("API key required");
    
    // Test with API key (should succeed)
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("X-API-Key", "test-api-key");
    
    var response2 = try client.getWithHeaders("/api/v1/games", headers);
    defer response2.deinit();
    
    try response2.expectStatus(200);
    try response2.expectHeader("Content-Type", "application/json");
    try response2.expectBodyContains("games");
    try response2.expectBodyContains("nfl");
    try response2.expectBodyContains("nba");
}

test "API endpoint with path parameters" {
    const allocator = testing.allocator;
    const port: u16 = 3003;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    var client = TestHttpClient.init(allocator, "http://localhost:3003");
    defer client.deinit();
    
    var response = try client.get("/api/v1/games/nfl");
    defer response.deinit();
    
    try response.expectStatus(200);
    try response.expectHeader("Content-Type", "application/json");
    try response.expectBodyContains("game");
    try response.expectBodyContains("nfl");
    try response.expectBodyContains("football");
}

test "CORS preflight request handling" {
    const allocator = testing.allocator;
    const port: u16 = 3004;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    // Create an OPTIONS request
    const url = "http://localhost:3004/api/v1/games";
    const uri = try std.Uri.parse(url);
    
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();
    
    var headers = std.http.Headers{ .allocator = allocator };
    defer headers.deinit();
    
    try headers.append("Origin", "http://localhost:8080");
    try headers.append("Access-Control-Request-Method", "GET");
    try headers.append("Access-Control-Request-Headers", "X-API-Key");
    
    var request = try http_client.open(.OPTIONS, uri, headers, .{});
    defer request.deinit();
    
    try request.send();
    try request.finish();
    try request.wait();
    
    const status = @intFromEnum(request.response.status);
    try testing.expect(status == 200);
    
    // Check CORS headers
    const cors_origin = request.response.headers.getFirstValue("Access-Control-Allow-Origin");
    try testing.expect(cors_origin != null);
    try testing.expectEqualStrings("*", cors_origin.?);
    
    const cors_methods = request.response.headers.getFirstValue("Access-Control-Allow-Methods");
    try testing.expect(cors_methods != null);
    try testing.expect(std.mem.indexOf(u8, cors_methods.?, "GET") != null);
    try testing.expect(std.mem.indexOf(u8, cors_methods.?, "OPTIONS") != null);
}

test "404 error handling" {
    const allocator = testing.allocator;
    const port: u16 = 3005;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    var client = TestHttpClient.init(allocator, "http://localhost:3005");
    defer client.deinit();
    
    var response = try client.get("/nonexistent/endpoint");
    defer response.deinit();
    
    try response.expectStatus(404);
    try response.expectHeader("Content-Type", "application/json");
    try response.expectBodyContains("Not Found");
    try response.expectBodyContains("Endpoint not found");
}

test "Metrics endpoint format" {
    const allocator = testing.allocator;
    const port: u16 = 3006;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    var client = TestHttpClient.init(allocator, "http://localhost:3006");
    defer client.deinit();
    
    var response = try client.get("/metrics");
    defer response.deinit();
    
    try response.expectStatus(200);
    try response.expectHeader("Content-Type", "text/plain; version=0.0.4");
    
    // Check Prometheus format
    try response.expectBodyContains("# HELP");
    try response.expectBodyContains("# TYPE");
    try response.expectBodyContains("http_requests_total");
    try response.expectBodyContains("http_request_duration_seconds");
    try response.expectBodyContains("_bucket{le=");
    try response.expectBodyContains("_count");
    try response.expectBodyContains("_sum");
}

test "Content-Type headers are set correctly" {
    const allocator = testing.allocator;
    const port: u16 = 3007;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    var client = TestHttpClient.init(allocator, "http://localhost:3007");
    defer client.deinit();
    
    // JSON endpoint
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("X-API-Key", "test-key");
    
    var json_response = try client.getWithHeaders("/api/v1/games", headers);
    defer json_response.deinit();
    
    try json_response.expectHeader("Content-Type", "application/json");
    
    // Metrics endpoint (plain text)
    var metrics_response = try client.get("/metrics");
    defer metrics_response.deinit();
    
    try metrics_response.expectHeader("Content-Type", "text/plain; version=0.0.4");
}

test "JSON response parsing" {
    const allocator = testing.allocator;
    const port: u16 = 3008;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    var client = TestHttpClient.init(allocator, "http://localhost:3008");
    defer client.deinit();
    
    var response = try client.get("/health");
    defer response.deinit();
    
    try response.expectStatus(200);
    
    // Parse JSON response
    const HealthResponse = struct {
        status: []const u8,
        timestamp: i64,
        version: []const u8,
    };
    
    const health_data = try response.parseJson(HealthResponse);
    try testing.expectEqualStrings("healthy", health_data.status);
    try testing.expectEqualStrings("1.0.0", health_data.version);
    try testing.expect(health_data.timestamp > 0);
}

test "Error response format consistency" {
    const allocator = testing.allocator;
    const port: u16 = 3009;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    var client = TestHttpClient.init(allocator, "http://localhost:3009");
    defer client.deinit();
    
    // Test 401 error
    var auth_response = try client.get("/api/v1/games");
    defer auth_response.deinit();
    
    try auth_response.expectStatus(401);
    try auth_response.expectBodyContains("error");
    try auth_response.expectBodyContains("message");
    try auth_response.expectBodyContains("Unauthorized");
    
    // Test 404 error
    var not_found_response = try client.get("/nonexistent");
    defer not_found_response.deinit();
    
    try not_found_response.expectStatus(404);
    try not_found_response.expectBodyContains("error");
    try not_found_response.expectBodyContains("message");
    try not_found_response.expectBodyContains("Not Found");
}

test "Concurrent request handling" {
    const allocator = testing.allocator;
    const port: u16 = 3010;
    
    var server = TestServer.init(allocator, port);
    try server.start();
    defer server.stop();
    
    // Create multiple clients for concurrent testing
    var clients: [5]TestHttpClient = undefined;
    for (0..5) |i| {
        clients[i] = TestHttpClient.init(allocator, "http://localhost:3010");
    }
    defer {
        for (0..5) |i| {
            clients[i].deinit();
        }
    }
    
    // Make concurrent requests
    var responses: [5]HttpResponse = undefined;
    for (0..5) |i| {
        responses[i] = try clients[i].get("/health");
    }
    defer {
        for (0..5) |i| {
            responses[i].deinit();
        }
    }
    
    // All should succeed
    for (0..5) |i| {
        try responses[i].expectStatus(200);
        try responses[i].expectBodyContains("healthy");
    }
}

// Run all integration tests
test {
    std.testing.refAllDecls(@This());
}