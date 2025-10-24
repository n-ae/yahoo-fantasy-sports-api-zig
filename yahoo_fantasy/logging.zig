// Structured logging system
//
// This module provides structured logging with different levels
// and output formats for development and production environments.

const std = @import("std");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
    
    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
    
    pub fn fromString(s: []const u8) ?LogLevel {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }
    
    pub fn shouldLog(self: LogLevel, min_level: LogLevel) bool {
        const level_values = [_]u8{ 0, 1, 2, 3 }; // debug, info, warn, err
        return level_values[@intFromEnum(self)] >= level_values[@intFromEnum(min_level)];
    }
};

pub const LogFormat = enum {
    text,
    json,
};

pub const LogContext = struct {
    request_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    status_code: ?u16 = null,
    
    pub fn with(self: LogContext, comptime field: []const u8, value: anytype) LogContext {
        var ctx = self;
        
        if (comptime std.mem.eql(u8, field, "request_id")) {
            ctx.request_id = value;
        } else if (comptime std.mem.eql(u8, field, "user_id")) {
            ctx.user_id = value;
        } else if (comptime std.mem.eql(u8, field, "endpoint")) {
            ctx.endpoint = value;
        } else if (comptime std.mem.eql(u8, field, "duration_ms")) {
            ctx.duration_ms = value;
        } else if (comptime std.mem.eql(u8, field, "status_code")) {
            ctx.status_code = value;
        }
        
        return ctx;
    }
};

pub const Logger = struct {
    level: LogLevel,
    format: LogFormat,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, level: LogLevel, format: LogFormat) Self {
        return Self{
            .level = level,
            .format = format,
            .allocator = allocator,
        };
    }
    
    pub fn debug(self: Self, comptime message: []const u8, args: anytype) void {
        self.logWithContext(.debug, message, args, LogContext{});
    }
    
    pub fn info(self: Self, comptime message: []const u8, args: anytype) void {
        self.logWithContext(.info, message, args, LogContext{});
    }
    
    pub fn warn(self: Self, comptime message: []const u8, args: anytype) void {
        self.logWithContext(.warn, message, args, LogContext{});
    }
    
    pub fn err(self: Self, comptime message: []const u8, args: anytype) void {
        self.logWithContext(.err, message, args, LogContext{});
    }
    
    pub fn debugCtx(self: Self, context: LogContext, comptime message: []const u8, args: anytype) void {
        self.logWithContext(.debug, message, args, context);
    }
    
    pub fn infoCtx(self: Self, context: LogContext, comptime message: []const u8, args: anytype) void {
        self.logWithContext(.info, message, args, context);
    }
    
    pub fn warnCtx(self: Self, context: LogContext, comptime message: []const u8, args: anytype) void {
        self.logWithContext(.warn, message, args, context);
    }
    
    pub fn errCtx(self: Self, context: LogContext, comptime message: []const u8, args: anytype) void {
        self.logWithContext(.err, message, args, context);
    }
    
    pub fn logRequest(self: Self, method: []const u8, path: []const u8, status: u16, duration_ms: u64) void {
        var context = LogContext{};
        context = context.with("endpoint", path);
        context = context.with("status_code", status);
        context = context.with("duration_ms", duration_ms);
        
        if (status >= 400) {
            self.warnCtx(context, "{s} {s} - {d} ({d}ms)", .{ method, path, status, duration_ms });
        } else {
            self.infoCtx(context, "{s} {s} - {d} ({d}ms)", .{ method, path, status, duration_ms });
        }
    }
    
    pub fn logError(self: Self, context: LogContext, error_name: []const u8, error_message: []const u8) void {
        self.errCtx(context, "Error: {s} - {s}", .{ error_name, error_message });
    }
    
    fn logWithContext(self: Self, log_level: LogLevel, comptime message: []const u8, args: anytype, context: LogContext) void {
        if (!log_level.shouldLog(self.level)) {
            return;
        }
        
        const timestamp = std.time.timestamp();
        
        switch (self.format) {
            .text => self.logText(timestamp, log_level, message, args, context),
            .json => self.logJson(timestamp, log_level, message, args, context),
        }
    }
    
    fn logText(self: Self, timestamp: i64, log_level: LogLevel, comptime message: []const u8, args: anytype, context: LogContext) void {
        const formatted_message = std.fmt.allocPrint(self.allocator, message, args) catch return;
        defer self.allocator.free(formatted_message);
        
        var context_str = std.ArrayList(u8).init(self.allocator);
        defer context_str.deinit();
        
        if (context.request_id) |req_id| {
            std.fmt.format(context_str.writer(), " req_id={s}", .{req_id}) catch return;
        }
        if (context.user_id) |user_id| {
            std.fmt.format(context_str.writer(), " user_id={s}", .{user_id}) catch return;
        }
        if (context.endpoint) |endpoint| {
            std.fmt.format(context_str.writer(), " endpoint={s}", .{endpoint}) catch return;
        }
        if (context.duration_ms) |duration| {
            std.fmt.format(context_str.writer(), " duration_ms={d}", .{duration}) catch return;
        }
        if (context.status_code) |status| {
            std.fmt.format(context_str.writer(), " status={d}", .{status}) catch return;
        }
        
        std.debug.print("[{d}] {s}: {s}{s}\n", .{ timestamp, log_level.toString(), formatted_message, context_str.items });
    }
    
    fn logJson(self: Self, timestamp: i64, log_level: LogLevel, comptime message: []const u8, args: anytype, context: LogContext) void {
        const formatted_message = std.fmt.allocPrint(self.allocator, message, args) catch return;
        defer self.allocator.free(formatted_message);
        
        var json_obj = std.json.ObjectMap.init(self.allocator);
        defer json_obj.deinit();
        
        json_obj.put("timestamp", std.json.Value{ .integer = timestamp }) catch return;
        json_obj.put("level", std.json.Value{ .string = log_level.toString() }) catch return;
        json_obj.put("message", std.json.Value{ .string = formatted_message }) catch return;
        
        if (context.request_id) |req_id| {
            json_obj.put("request_id", std.json.Value{ .string = req_id }) catch return;
        }
        if (context.user_id) |user_id| {
            json_obj.put("user_id", std.json.Value{ .string = user_id }) catch return;
        }
        if (context.endpoint) |endpoint| {
            json_obj.put("endpoint", std.json.Value{ .string = endpoint }) catch return;
        }
        if (context.duration_ms) |duration| {
            json_obj.put("duration_ms", std.json.Value{ .integer = @intCast(duration) }) catch return;
        }
        if (context.status_code) |status| {
            json_obj.put("status_code", std.json.Value{ .integer = status }) catch return;
        }
        
        const json_value = std.json.Value{ .object = json_obj };
        const json_string = std.json.stringify(json_value, .{}, self.allocator) catch return;
        defer self.allocator.free(json_string);
        
        std.debug.print("{s}\n", .{json_string});
    }
};

// Global logger instance
var global_logger: ?Logger = null;
var logger_init_once = std.once(initGlobalLogger);

fn initGlobalLogger() void {
    const allocator = std.heap.page_allocator;
    const level_str = std.process.getEnvVarOwned(allocator, "LOG_LEVEL") catch "info";
    defer allocator.free(level_str);
    
    const format_str = std.process.getEnvVarOwned(allocator, "LOG_FORMAT") catch "text";
    defer allocator.free(format_str);
    
    const level = LogLevel.fromString(level_str) orelse .info;
    const format = if (std.mem.eql(u8, format_str, "json")) LogFormat.json else LogFormat.text;
    
    global_logger = Logger.init(allocator, level, format);
}

pub fn getLogger() *Logger {
    logger_init_once.call();
    return &global_logger.?;
}

// Convenience functions for global logger
pub fn debug(comptime message: []const u8, args: anytype) void {
    getLogger().debug(message, args);
}

pub fn info(comptime message: []const u8, args: anytype) void {
    getLogger().info(message, args);
}

pub fn warn(comptime message: []const u8, args: anytype) void {
    getLogger().warn(message, args);
}

pub fn err(comptime message: []const u8, args: anytype) void {
    getLogger().err(message, args);
}

pub fn debugCtx(context: LogContext, comptime message: []const u8, args: anytype) void {
    getLogger().debugCtx(context, message, args);
}

pub fn infoCtx(context: LogContext, comptime message: []const u8, args: anytype) void {
    getLogger().infoCtx(context, message, args);
}

pub fn warnCtx(context: LogContext, comptime message: []const u8, args: anytype) void {
    getLogger().warnCtx(context, message, args);
}

pub fn errCtx(context: LogContext, comptime message: []const u8, args: anytype) void {
    getLogger().errCtx(context, message, args);
}

pub fn logRequest(method: []const u8, path: []const u8, status: u16, duration_ms: u64) void {
    getLogger().logRequest(method, path, status, duration_ms);
}

pub fn logError(context: LogContext, error_name: []const u8, error_message: []const u8) void {
    getLogger().logError(context, error_name, error_message);
}

test "log level filtering" {
    const allocator = std.testing.allocator;
    _ = Logger.init(allocator, .warn, .text);
    
    // These should log (warn level and above)
    try std.testing.expect(LogLevel.warn.shouldLog(.warn));
    try std.testing.expect(LogLevel.err.shouldLog(.warn));
    
    // These should not log (below warn level)
    try std.testing.expect(!LogLevel.debug.shouldLog(.warn));
    try std.testing.expect(!LogLevel.info.shouldLog(.warn));
}

test "log context building" {
    var context = LogContext{};
    context = context.with("request_id", "req-123");
    context = context.with("status_code", @as(u16, 200));
    
    try std.testing.expectEqualStrings("req-123", context.request_id.?);
    try std.testing.expect(context.status_code.? == 200);
}

test "log level string conversion" {
    try std.testing.expectEqualStrings("INFO", LogLevel.info.toString());
    try std.testing.expect(LogLevel.fromString("debug") == .debug);
    try std.testing.expect(LogLevel.fromString("invalid") == null);
}