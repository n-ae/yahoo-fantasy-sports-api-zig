const std = @import("std");
const http = std.http;

pub const OAuthError = error{
    InvalidCredentials,
    AuthorizationFailed,
    NetworkError,
    InvalidResponse,
} || std.mem.Allocator.Error;

pub const Credentials = struct {
    consumer_key: []const u8,
    consumer_secret: []const u8,
    access_token: ?[]const u8 = null,
    access_token_secret: ?[]const u8 = null,
};

pub const RequestToken = struct {
    token: []const u8,
    token_secret: []const u8,
    authorization_url: []const u8,
};

pub const AccessToken = struct {
    token: []const u8,
    token_secret: []const u8,
};

pub const OAuthClient = struct {
    allocator: std.mem.Allocator,
    credentials: Credentials,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, credentials: Credentials) Self {
        return Self{
            .allocator = allocator,
            .credentials = credentials,
        };
    }

    pub fn generateAuthHeader(
        self: *const Self,
        method: []const u8,
        url: []const u8,
        params: ?std.StringHashMap([]const u8),
    ) ![]u8 {
        var oauth_params = std.StringHashMap([]const u8).init(self.allocator);
        defer oauth_params.deinit();

        try oauth_params.put("oauth_consumer_key", self.credentials.consumer_key);
        try oauth_params.put("oauth_signature_method", "HMAC-SHA1");
        try oauth_params.put("oauth_timestamp", try self.generateTimestamp());
        try oauth_params.put("oauth_nonce", try self.generateNonce());
        try oauth_params.put("oauth_version", "1.0");

        if (self.credentials.access_token) |token| {
            try oauth_params.put("oauth_token", token);
        }

        const signature = try self.generateSignature(method, url, &oauth_params, params);
        try oauth_params.put("oauth_signature", signature);

        return try self.buildAuthHeader(&oauth_params);
    }

    fn generateTimestamp(self: *const Self) ![]u8 {
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        return try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
    }

    fn generateNonce(self: *const Self) ![]u8 {
        var buf: [16]u8 = undefined;
        std.crypto.random.bytes(&buf);
        return try std.fmt.allocPrint(self.allocator, "{x}", .{std.fmt.fmtSliceHexLower(&buf)});
    }

    fn generateSignature(
        self: *const Self,
        method: []const u8,
        url: []const u8,
        oauth_params: *std.StringHashMap([]const u8),
        request_params: ?std.StringHashMap([]const u8),
    ) ![]u8 {
        var all_params = std.StringHashMap([]const u8).init(self.allocator);
        defer all_params.deinit();

        var oauth_iter = oauth_params.iterator();
        while (oauth_iter.next()) |entry| {
            try all_params.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        if (request_params) |params| {
            var param_iter = params.iterator();
            while (param_iter.next()) |entry| {
                try all_params.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        const param_string = try self.buildParameterString(&all_params);
        defer self.allocator.free(param_string);

        const base_string = try std.fmt.allocPrint(
            self.allocator,
            "{s}&{s}&{s}",
            .{ method, try self.percentEncode(url), try self.percentEncode(param_string) },
        );
        defer self.allocator.free(base_string);

        const signing_key = if (self.credentials.access_token_secret) |secret|
            try std.fmt.allocPrint(self.allocator, "{s}&{s}", .{ self.credentials.consumer_secret, secret })
        else
            try std.fmt.allocPrint(self.allocator, "{s}&", .{self.credentials.consumer_secret});
        defer self.allocator.free(signing_key);

        var hmac: [20]u8 = undefined;
        std.crypto.auth.hmac.Hmac(std.crypto.hash.Sha1).create(&hmac, base_string, signing_key);

        const base64_encoder = std.base64.standard.Encoder;
        var signature_buf: [28]u8 = undefined;
        return try self.allocator.dupe(u8, base64_encoder.encode(&signature_buf, &hmac));
    }

    fn buildParameterString(self: *const Self, params: *std.StringHashMap([]const u8)) ![]u8 {
        var sorted_params = std.ArrayList(struct { key: []const u8, value: []const u8 }).init(self.allocator);
        defer sorted_params.deinit();

        var param_iter = params.iterator();
        while (param_iter.next()) |entry| {
            try sorted_params.append(.{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        const SortContext = struct {
            fn lessThan(context: void, lhs: @TypeOf(sorted_params.items[0]), rhs: @TypeOf(sorted_params.items[0])) bool {
                _ = context;
                return std.mem.order(u8, lhs.key, rhs.key) == .lt;
            }
        };
        std.mem.sort(@TypeOf(sorted_params.items[0]), sorted_params.items, {}, SortContext.lessThan);

        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        for (sorted_params.items, 0..) |param, i| {
            if (i > 0) try result.append('&');
            try result.appendSlice(try self.percentEncode(param.key));
            try result.append('=');
            try result.appendSlice(try self.percentEncode(param.value));
        }

        return try result.toOwnedSlice();
    }

    fn buildAuthHeader(self: *const Self, params: *std.StringHashMap([]const u8)) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        try result.appendSlice("OAuth ");

        var is_first = true;
        var param_iter = params.iterator();
        while (param_iter.next()) |entry| {
            if (!is_first) try result.appendSlice(", ");
            is_first = false;

            try result.appendSlice(try self.percentEncode(entry.key_ptr.*));
            try result.appendSlice("=\"");
            try result.appendSlice(try self.percentEncode(entry.value_ptr.*));
            try result.append('"');
        }

        return try result.toOwnedSlice();
    }

    fn percentEncode(self: *const Self, input: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        for (input) |byte| {
            switch (byte) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => {
                    try result.append(byte);
                },
                else => {
                    try result.appendSlice(try std.fmt.allocPrint(self.allocator, "%{X:0>2}", .{byte}));
                },
            }
        }

        return try result.toOwnedSlice();
    }
};

test "oauth client initialization" {
    const allocator = std.testing.allocator;
    const credentials = Credentials{
        .consumer_key = "test_key",
        .consumer_secret = "test_secret",
    };

    const client = OAuthClient.init(allocator, credentials);
    try std.testing.expectEqualSlices(u8, "test_key", client.credentials.consumer_key);
    try std.testing.expectEqualSlices(u8, "test_secret", client.credentials.consumer_secret);
}