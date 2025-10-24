// Yahoo Fantasy API comprehensive error types
//
// This module defines all error types used throughout the application.
// It follows a hierarchical approach for clear error handling.

const std = @import("std");

pub const YahooError = error{
    // Network errors
    ConnectionFailed,
    Timeout,
    DnsResolutionFailed,
    SslHandshakeFailed,
    
    // HTTP errors
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    TooManyRequests,
    InternalServerError,
    BadGateway,
    ServiceUnavailable,
    
    // OAuth errors
    InvalidToken,
    TokenExpired,
    InvalidSignature,
    InvalidConsumerKey,
    
    // API errors
    ApiUnavailable,
    RateLimited,
    InvalidParameter,
    InsufficientPrivileges,
    
    // Data errors
    ParseError,
    ValidationError,
    SerializationError,
    InvalidFormat,
    
    // Cache errors
    CacheExpired,
    CacheCorrupted,
    CacheFull,
    
    // System errors
    OutOfMemory,
    FileSystemError,
    ConfigurationError,
} || std.mem.Allocator.Error || std.http.Client.RequestError;

pub const ErrorContext = struct {
    message: []const u8,
    code: []const u8,
    timestamp: i64,
    request_id: ?[]const u8 = null,
    details: ?[]const u8 = null,
    
    pub fn init(_: std.mem.Allocator, err: YahooError, message: []const u8) ErrorContext {
        return ErrorContext{
            .message = message,
            .code = errorToCode(err),
            .timestamp = std.time.timestamp(),
        };
    }
    
    pub fn withRequestId(self: ErrorContext, request_id: []const u8) ErrorContext {
        var ctx = self;
        ctx.request_id = request_id;
        return ctx;
    }
    
    pub fn withDetails(self: ErrorContext, details: []const u8) ErrorContext {
        var ctx = self;
        ctx.details = details;
        return ctx;
    }
    
    pub fn toJson(self: ErrorContext, allocator: std.mem.Allocator) ![]u8 {
        // Simplified JSON serialization for compatibility
        if (self.request_id) |id| {
            if (self.details) |details| {
                return std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\",\"message\":\"{s}\",\"timestamp\":{d},\"request_id\":\"{s}\",\"details\":\"{s}\"}}", .{ self.code, self.message, self.timestamp, id, details });
            } else {
                return std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\",\"message\":\"{s}\",\"timestamp\":{d},\"request_id\":\"{s}\"}}", .{ self.code, self.message, self.timestamp, id });
            }
        } else {
            return std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\",\"message\":\"{s}\",\"timestamp\":{d}}}", .{ self.code, self.message, self.timestamp });
        }
    }
    
    pub fn isRetryable(self: ErrorContext) bool {
        const retryable_codes = [_][]const u8{
            "TIMEOUT",
            "CONNECTION_FAILED",
            "RATE_LIMITED",
            "SERVICE_UNAVAILABLE",
            "BAD_GATEWAY",
        };
        
        for (retryable_codes) |code| {
            if (std.mem.eql(u8, self.code, code)) {
                return true;
            }
        }
        return false;
    }
};

fn errorToCode(err: YahooError) []const u8 {
    return switch (err) {
        error.ConnectionFailed => "CONNECTION_FAILED",
        error.Timeout => "TIMEOUT",
        error.DnsResolutionFailed => "DNS_RESOLUTION_FAILED",
        error.SslHandshakeFailed => "SSL_HANDSHAKE_FAILED",
        
        error.BadRequest => "BAD_REQUEST",
        error.Unauthorized => "UNAUTHORIZED", 
        error.Forbidden => "FORBIDDEN",
        error.NotFound => "NOT_FOUND",
        error.TooManyRequests => "RATE_LIMITED",
        error.InternalServerError => "INTERNAL_SERVER_ERROR",
        error.BadGateway => "BAD_GATEWAY",
        error.ServiceUnavailable => "SERVICE_UNAVAILABLE",
        
        error.InvalidToken => "INVALID_TOKEN",
        error.TokenExpired => "TOKEN_EXPIRED",
        error.InvalidSignature => "INVALID_SIGNATURE",
        error.InvalidConsumerKey => "INVALID_CONSUMER_KEY",
        
        error.ApiUnavailable => "API_UNAVAILABLE",
        error.RateLimited => "RATE_LIMITED",
        error.InvalidParameter => "INVALID_PARAMETER",
        error.InsufficientPrivileges => "INSUFFICIENT_PRIVILEGES",
        
        error.ParseError => "PARSE_ERROR",
        error.ValidationError => "VALIDATION_ERROR",
        error.SerializationError => "SERIALIZATION_ERROR",
        error.InvalidFormat => "INVALID_FORMAT",
        
        error.CacheExpired => "CACHE_EXPIRED",
        error.CacheCorrupted => "CACHE_CORRUPTED",
        error.CacheFull => "CACHE_FULL",
        
        error.OutOfMemory => "OUT_OF_MEMORY",
        error.FileSystemError => "FILE_SYSTEM_ERROR",
        error.ConfigurationError => "CONFIGURATION_ERROR",
        
        else => "UNKNOWN_ERROR",
    };
}

pub fn httpStatusToError(status: u16) YahooError {
    return switch (status) {
        400 => error.BadRequest,
        401 => error.Unauthorized,
        403 => error.Forbidden,
        404 => error.NotFound,
        429 => error.TooManyRequests,
        500 => error.InternalServerError,
        502 => error.BadGateway,
        503 => error.ServiceUnavailable,
        else => error.ApiUnavailable,
    };
}

test "error context creation" {
    const allocator = std.testing.allocator;
    
    const ctx = ErrorContext.init(allocator, error.Unauthorized, "Invalid credentials");
    try std.testing.expectEqualStrings("UNAUTHORIZED", ctx.code);
    try std.testing.expectEqualStrings("Invalid credentials", ctx.message);
}

test "error context json serialization" {
    const allocator = std.testing.allocator;
    
    const ctx = ErrorContext.init(allocator, error.RateLimited, "Too many requests")
        .withRequestId("req-123");
    
    const json = try ctx.toJson(allocator);
    defer allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "RATE_LIMITED") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "req-123") != null);
}

test "retryable error detection" {
    const allocator = std.testing.allocator;
    
    const retryable_ctx = ErrorContext.init(allocator, error.Timeout, "Request timeout");
    try std.testing.expect(retryable_ctx.isRetryable());
    
    const non_retryable_ctx = ErrorContext.init(allocator, error.Unauthorized, "Invalid token");
    try std.testing.expect(!non_retryable_ctx.isRetryable());
}