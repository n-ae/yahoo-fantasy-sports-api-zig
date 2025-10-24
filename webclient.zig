//! Yahoo Fantasy Web Client (Zig)
//!
//! Frontend web application that provides a user interface for Yahoo Fantasy Sports,
//! consuming data from the Web API server and rendering server-side HTML with HTMX.

const std = @import("std");
const print = std.debug.print;

// ============================================================================
// Core Web Client
// ============================================================================

pub const WebClient = struct {
    allocator: std.mem.Allocator,
    port: u16,
    api_base_url: []const u8,
    
    const Self = @This();
    
    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        api_base_url: []const u8,
    ) !*Self {
        var client = try allocator.create(Self);
        client.* = Self{
            .allocator = allocator,
            .port = port,
            .api_base_url = try allocator.dupe(u8, api_base_url),
        };
        return client;
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.api_base_url);
        self.allocator.destroy(self);
    }
    
    /// Start the web client server
    pub fn start(self: *Self) !void {
        print("Starting Yahoo Fantasy Web Client on port {d}\n", .{self.port});
        print("API Base URL: {s}\n", .{self.api_base_url});
        print("Available pages:\n");
        print("  GET /               - Home page\n");
        print("  GET /games          - Games list\n");
        print("  GET /leagues/:game  - Leagues for game\n");
        print("  GET /teams/:league  - Teams in league\n");
        print("  GET /roster/:team   - Team roster\n");
        print("  GET /search         - Player search\n");
        print("  GET /auth           - Authentication setup\n");
        print("  POST /auth/set      - Set OAuth tokens\n");
        print("\nWeb client ready at http://localhost:{d}\n", .{self.port});
        
        // Simple HTTP server implementation
        var server = std.http.Server.init(self.allocator, .{ .reuse_address = true });
        defer server.deinit();
        
        const address = std.net.Address.parseIp("127.0.0.1", self.port) catch unreachable;
        try server.listen(address);
        
        while (true) {
            var response = try server.accept(.{
                .allocator = self.allocator,
            });
            defer response.deinit();
            
            while (response.reset() != .closing) {
                response.wait() catch |err| switch (err) {
                    error.HttpHeadersInvalid => continue,
                    error.EndOfStream => continue,
                    else => return err,
                };
                
                try self.handleRequest(&response);
            }
        }
    }
    
    /// Handle incoming HTTP requests
    fn handleRequest(self: *Self, response: *std.http.Server.Response) !void {
        const method = response.request.method;
        const target = response.request.target;
        
        print("[{s}] {s}\n", .{ @tagName(method), target });
        
        // Route requests
        if (std.mem.eql(u8, target, "/")) {
            try self.handleHome(response);
        } else if (std.mem.eql(u8, target, "/games")) {
            try self.handleGames(response);
        } else if (std.mem.startsWith(u8, target, "/leagues/")) {
            try self.handleLeagues(response, target);
        } else if (std.mem.startsWith(u8, target, "/teams/")) {
            try self.handleTeams(response, target);
        } else if (std.mem.startsWith(u8, target, "/roster/")) {
            try self.handleRoster(response, target);
        } else if (std.mem.eql(u8, target, "/search")) {
            try self.handleSearch(response);
        } else if (std.mem.eql(u8, target, "/auth")) {
            try self.handleAuth(response);
        } else if (std.mem.eql(u8, target, "/auth/set") and method == .POST) {
            try self.handleSetAuth(response);
        } else if (std.mem.startsWith(u8, target, "/static/")) {
            try self.handleStatic(response, target);
        } else {
            try self.send404(response);
        }
    }
    
    // ========================================================================
    // Page Handlers
    // ========================================================================
    
    fn handleHome(self: *Self, response: *std.http.Server.Response) !void {
        const html = 
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>Yahoo Fantasy Sports</title>
        \\    <script src="https://unpkg.com/htmx.org@1.9.10"></script>
        \\    <style>
        \\        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        \\        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        \\        .header { text-align: center; margin-bottom: 40px; }
        \\        .card { background: #f8f9fa; padding: 20px; margin: 20px 0; border-radius: 6px; border-left: 4px solid #007bff; }
        \\        .nav { display: flex; gap: 20px; margin: 20px 0; justify-content: center; }
        \\        .nav a { padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; }
        \\        .nav a:hover { background: #0056b3; }
        \\        .status { padding: 10px; margin: 10px 0; border-radius: 4px; }
        \\        .status.success { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        \\        .status.error { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        \\        .status.warning { background: #fff3cd; color: #856404; border: 1px solid #ffeaa7; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <div class="header">
        \\            <h1>🏆 Yahoo Fantasy Sports</h1>
        \\            <p>Web Client (Zig Implementation)</p>
        \\        </div>
        \\        
        \\        <div class="nav">
        \\            <a href="/games">📊 Games</a>
        \\            <a href="/search">🔍 Search Players</a>
        \\            <a href="/auth">🔐 Authentication</a>
        \\        </div>
        \\        
        \\        <div class="card">
        \\            <h2>🚀 Welcome to Yahoo Fantasy Sports</h2>
        \\            <p>This is a modern web client built with Zig that provides a clean interface to access Yahoo Fantasy Sports data.</p>
        \\            
        \\            <h3>✨ Features</h3>
        \\            <ul>
        \\                <li><strong>Games Overview</strong> - Browse available fantasy sports games</li>
        \\                <li><strong>League Management</strong> - View your leagues and teams</li>
        \\                <li><strong>Player Search</strong> - Find and analyze players across all sports</li>
        \\                <li><strong>Team Rosters</strong> - Examine team compositions and strategies</li>
        \\                <li><strong>Real-time Updates</strong> - Dynamic content loading with HTMX</li>
        \\            </ul>
        \\        </div>
        \\        
        \\        <div class="card">
        \\            <h3>🔧 Architecture</h3>
        \\            <p><strong>Frontend:</strong> Zig Web Client (Server-side rendering + HTMX)</p>
        \\            <p><strong>API:</strong> RESTful Web API Server</p>
        \\            <p><strong>SDK:</strong> Yahoo Fantasy API Client Library</p>
        \\            <p><strong>Data Source:</strong> Yahoo Fantasy Sports API</p>
        \\        </div>
        \\        
        \\        <div class="card" id="api-status">
        \\            <h3>📡 API Status</h3>
        \\            <button hx-get="/api-status" hx-target="#api-status" hx-swap="innerHTML">Check API Status</button>
        \\        </div>
        \\        
        \\        <div class="status warning">
        \\            <strong>⚠️ Setup Required:</strong> Please configure OAuth tokens in the <a href="/auth">Authentication</a> section to access Yahoo Fantasy data.
        \\        </div>
        \\    </div>
        \\</body>
        \\</html>
        ;
        
        try self.sendHtml(response, html);
    }
    
    fn handleGames(self: *Self, response: *std.http.Server.Response) !void {
        // Fetch games data from API
        const api_data = self.fetchFromApi("/api/games") catch |err| {
            try self.sendError(response, "Failed to fetch games data", err);
            return;
        };
        defer self.allocator.free(api_data);
        
        var html_buf: [4096]u8 = undefined;
        const html = try std.fmt.bufPrint(&html_buf,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>Games - Yahoo Fantasy Sports</title>
        \\    <script src="https://unpkg.com/htmx.org@1.9.10"></script>
        \\    <style>
        \\        body {{ font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }}
        \\        .container {{ max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }}
        \\        .header {{ text-align: center; margin-bottom: 40px; }}
        \\        .game-card {{ background: #f8f9fa; padding: 20px; margin: 15px 0; border-radius: 6px; border-left: 4px solid #28a745; cursor: pointer; transition: all 0.2s; }}
        \\        .game-card:hover {{ background: #e9ecef; transform: translateX(5px); }}
        \\        .nav {{ display: flex; gap: 20px; margin: 20px 0; justify-content: center; }}
        \\        .nav a {{ padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; }}
        \\        .nav a:hover {{ background: #0056b3; }}
        \\        .status {{ padding: 15px; margin: 15px 0; border-radius: 4px; }}
        \\        .status.error {{ background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }}
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <div class="header">
        \\            <h1>📊 Available Games</h1>
        \\            <p>Select a fantasy sports game to view your leagues</p>
        \\        </div>
        \\        
        \\        <div class="nav">
        \\            <a href="/">🏠 Home</a>
        \\            <a href="/search">🔍 Search Players</a>
        \\            <a href="/auth">🔐 Authentication</a>
        \\        </div>
        \\        
        \\        <div id="games-content">
        \\            {s}
        \\        </div>
        \\    </div>
        \\</body>
        \\</html>
        , .{api_data});
        
        try self.sendHtml(response, html);
    }
    
    fn handleSearch(self: *Self, response: *std.http.Server.Response) !void {
        const html = 
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>Player Search - Yahoo Fantasy Sports</title>
        \\    <script src="https://unpkg.com/htmx.org@1.9.10"></script>
        \\    <style>
        \\        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        \\        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        \\        .header { text-align: center; margin-bottom: 40px; }
        \\        .search-form { background: #f8f9fa; padding: 20px; border-radius: 6px; margin: 20px 0; }
        \\        .form-row { display: flex; gap: 15px; margin: 15px 0; align-items: end; }
        \\        .form-group { flex: 1; }
        \\        .form-group label { display: block; margin-bottom: 5px; font-weight: bold; }
        \\        .form-group input, .form-group select { width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; }
        \\        .search-btn { padding: 8px 20px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        \\        .search-btn:hover { background: #0056b3; }
        \\        .player-card { background: #f8f9fa; padding: 15px; margin: 10px 0; border-radius: 6px; border-left: 4px solid #ffc107; }
        \\        .nav { display: flex; gap: 20px; margin: 20px 0; justify-content: center; }
        \\        .nav a { padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; }
        \\        .nav a:hover { background: #0056b3; }
        \\        .loading { text-align: center; padding: 20px; color: #6c757d; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <div class="header">
        \\            <h1>🔍 Player Search</h1>
        \\            <p>Search for fantasy players across all sports</p>
        \\        </div>
        \\        
        \\        <div class="nav">
        \\            <a href="/">🏠 Home</a>
        \\            <a href="/games">📊 Games</a>
        \\            <a href="/auth">🔐 Authentication</a>
        \\        </div>
        \\        
        \\        <div class="search-form">
        \\            <h3>🎯 Search Parameters</h3>
        \\            <form hx-get="/search-results" hx-target="#search-results" hx-indicator="#loading">
        \\                <div class="form-row">
        \\                    <div class="form-group">
        \\                        <label for="game">Game</label>
        \\                        <select name="game" id="game" required>
        \\                            <option value="">Select a game...</option>
        \\                            <option value="nfl">NFL Football</option>
        \\                            <option value="nba">NBA Basketball</option>
        \\                            <option value="mlb">MLB Baseball</option>
        \\                        </select>
        \\                    </div>
        \\                    <div class="form-group">
        \\                        <label for="query">Player Name</label>
        \\                        <input type="text" name="q" id="query" placeholder="Enter player name..." required>
        \\                    </div>
        \\                    <div class="form-group">
        \\                        <button type="submit" class="search-btn">🔍 Search</button>
        \\                    </div>
        \\                </div>
        \\            </form>
        \\        </div>
        \\        
        \\        <div id="loading" class="loading htmx-indicator">
        \\            <p>🔄 Searching players...</p>
        \\        </div>
        \\        
        \\        <div id="search-results">
        \\            <div class="player-card">
        \\                <h4>💡 How to Search</h4>
        \\                <p>1. Select a fantasy game (NFL, NBA, MLB)</p>
        \\                <p>2. Enter a player name or partial name</p>
        \\                <p>3. Click Search to find matching players</p>
        \\                <p><em>Note: Authentication required for live data</em></p>
        \\            </div>
        \\        </div>
        \\    </div>
        \\</body>
        \\</html>
        ;
        
        try self.sendHtml(response, html);
    }
    
    fn handleAuth(self: *Self, response: *std.http.Server.Response) !void {
        const html = 
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>Authentication - Yahoo Fantasy Sports</title>
        \\    <script src="https://unpkg.com/htmx.org@1.9.10"></script>
        \\    <style>
        \\        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        \\        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        \\        .header { text-align: center; margin-bottom: 40px; }
        \\        .auth-form { background: #f8f9fa; padding: 25px; border-radius: 6px; margin: 20px 0; }
        \\        .form-group { margin: 20px 0; }
        \\        .form-group label { display: block; margin-bottom: 8px; font-weight: bold; color: #495057; }
        \\        .form-group input { width: 100%; padding: 12px; border: 1px solid #ddd; border-radius: 4px; font-size: 14px; }
        \\        .form-group input:focus { border-color: #007bff; outline: none; box-shadow: 0 0 0 2px rgba(0,123,255,0.25); }
        \\        .auth-btn { width: 100%; padding: 12px; background: #28a745; color: white; border: none; border-radius: 4px; font-size: 16px; font-weight: bold; cursor: pointer; }
        \\        .auth-btn:hover { background: #218838; }
        \\        .nav { display: flex; gap: 20px; margin: 20px 0; justify-content: center; }
        \\        .nav a { padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; }
        \\        .nav a:hover { background: #0056b3; }
        \\        .info-card { background: #d1ecf1; border: 1px solid #bee5eb; padding: 20px; border-radius: 6px; margin: 20px 0; }
        \\        .warning-card { background: #fff3cd; border: 1px solid #ffeaa7; padding: 20px; border-radius: 6px; margin: 20px 0; }
        \\        .status { padding: 15px; margin: 15px 0; border-radius: 4px; }
        \\        .status.success { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        \\        .status.error { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <div class="header">
        \\            <h1>🔐 OAuth Authentication</h1>
        \\            <p>Configure your Yahoo Fantasy API credentials</p>
        \\        </div>
        \\        
        \\        <div class="nav">
        \\            <a href="/">🏠 Home</a>
        \\            <a href="/games">📊 Games</a>
        \\            <a href="/search">🔍 Search Players</a>
        \\        </div>
        \\        
        \\        <div class="info-card">
        \\            <h3>📋 Setup Instructions</h3>
        \\            <ol>
        \\                <li>Register your application at <a href="https://developer.yahoo.com/apps/" target="_blank">Yahoo Developer Console</a></li>
        \\                <li>Complete the OAuth 1.0 flow to obtain access tokens</li>
        \\                <li>Enter your access token and token secret below</li>
        \\                <li>Click "Set Authentication" to activate API access</li>
        \\            </ol>
        \\        </div>
        \\        
        \\        <div class="auth-form">
        \\            <h3>🎫 OAuth Tokens</h3>
        \\            <form hx-post="/auth/set" hx-target="#auth-status" hx-indicator="#auth-loading">
        \\                <div class="form-group">
        \\                    <label for="access_token">Access Token</label>
        \\                    <input type="text" name="access_token" id="access_token" 
        \\                           placeholder="Your OAuth access token..." required>
        \\                </div>
        \\                
        \\                <div class="form-group">
        \\                    <label for="access_token_secret">Access Token Secret</label>
        \\                    <input type="password" name="access_token_secret" id="access_token_secret" 
        \\                           placeholder="Your OAuth access token secret..." required>
        \\                </div>
        \\                
        \\                <div class="form-group">
        \\                    <button type="submit" class="auth-btn">🚀 Set Authentication</button>
        \\                </div>
        \\            </form>
        \\            
        \\            <div id="auth-loading" class="status htmx-indicator">
        \\                <p>🔄 Setting authentication tokens...</p>
        \\            </div>
        \\        </div>
        \\        
        \\        <div id="auth-status">
        \\            <div class="warning-card">
        \\                <strong>⚠️ Not Authenticated:</strong> Please enter your OAuth tokens above to access Yahoo Fantasy data.
        \\            </div>
        \\        </div>
        \\    </div>
        \\</body>
        \\</html>
        ;
        
        try self.sendHtml(response, html);
    }
    
    fn handleSetAuth(self: *Self, response: *std.http.Server.Response) !void {
        // Read form data
        var body_buffer: [1024]u8 = undefined;
        const body_len = try response.request.reader().readAll(&body_buffer);
        const body = body_buffer[0..body_len];
        
        // Parse form data (simplified)
        var access_token: ?[]const u8 = null;
        var access_token_secret: ?[]const u8 = null;
        
        var params = std.mem.split(u8, body, "&");
        while (params.next()) |param| {
            var kv = std.mem.split(u8, param, "=");
            const key = kv.next() orelse continue;
            const value = kv.next() orelse continue;
            
            if (std.mem.eql(u8, key, "access_token")) {
                access_token = value;
            } else if (std.mem.eql(u8, key, "access_token_secret")) {
                access_token_secret = value;
            }
        }
        
        if (access_token == null or access_token_secret == null) {
            const error_html = 
            \\<div class="status error">
            \\    <strong>❌ Error:</strong> Both access token and access token secret are required.
            \\</div>
            ;
            try self.sendHtml(response, error_html);
            return;
        }
        
        // Send tokens to API
        const result = self.setApiTokens(access_token.?, access_token_secret.?) catch |err| {
            var error_buf: [256]u8 = undefined;
            const error_html = try std.fmt.bufPrint(&error_buf,
            \\<div class="status error">
            \\    <strong>❌ Error:</strong> Failed to set authentication tokens: {}
            \\</div>
            , .{err});
            try self.sendHtml(response, error_html);
            return;
        };
        
        if (result) {
            const success_html = 
            \\<div class="status success">
            \\    <strong>✅ Success:</strong> Authentication tokens have been set! You can now access Yahoo Fantasy data.
            \\    <br><br>
            \\    <a href="/games" style="display: inline-block; margin-top: 10px; padding: 8px 16px; background: #007bff; color: white; text-decoration: none; border-radius: 4px;">
            \\        📊 View Games
            \\    </a>
            \\</div>
            ;
            try self.sendHtml(response, success_html);
        } else {
            const error_html = 
            \\<div class="status error">
            \\    <strong>❌ Error:</strong> Failed to authenticate with the API server.
            \\</div>
            ;
            try self.sendHtml(response, error_html);
        }
    }
    
    // Handle other routes with placeholder implementations
    fn handleLeagues(self: *Self, response: *std.http.Server.Response, target: []const u8) !void {
        _ = target;
        try self.sendPlaceholder(response, "Leagues", "This page will show leagues for the selected game.");
    }
    
    fn handleTeams(self: *Self, response: *std.http.Server.Response, target: []const u8) !void {
        _ = target;
        try self.sendPlaceholder(response, "Teams", "This page will show teams in the selected league.");
    }
    
    fn handleRoster(self: *Self, response: *std.http.Server.Response, target: []const u8) !void {
        _ = target;
        try self.sendPlaceholder(response, "Roster", "This page will show the team's roster and player details.");
    }
    
    fn handleStatic(self: *Self, response: *std.http.Server.Response, target: []const u8) !void {
        _ = target;
        try self.send404(response);
    }
    
    // ========================================================================
    // Helper Methods
    // ========================================================================
    
    /// Fetch data from the Web API
    fn fetchFromApi(self: *Self, endpoint: []const u8) ![]u8 {
        // Simple HTTP client implementation
        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ self.api_base_url, endpoint });
        
        // Mock response for demonstration
        if (std.mem.indexOf(u8, endpoint, "games") != null) {
            return try self.allocator.dupe(u8,
                \\<div class="game-card" hx-get="/leagues/nfl" hx-target="body" hx-push-url="true">
                \\    <h3>🏈 NFL Football</h3>
                \\    <p>National Football League - 2024 Season</p>
                \\    <p><em>Click to view your NFL leagues</em></p>
                \\</div>
                \\<div class="game-card" hx-get="/leagues/nba" hx-target="body" hx-push-url="true">
                \\    <h3>🏀 NBA Basketball</h3>
                \\    <p>National Basketball Association - 2024 Season</p>
                \\    <p><em>Click to view your NBA leagues</em></p>
                \\</div>
                \\<div class="game-card" hx-get="/leagues/mlb" hx-target="body" hx-push-url="true">
                \\    <h3>⚾ MLB Baseball</h3>
                \\    <p>Major League Baseball - 2024 Season</p>
                \\    <p><em>Click to view your MLB leagues</em></p>
                \\</div>
            );
        }
        
        return self.allocator.dupe(u8, "<p>No data available</p>");
    }
    
    /// Set authentication tokens via API call
    fn setApiTokens(self: *Self, access_token: []const u8, access_token_secret: []const u8) !bool {
        // In a real implementation, this would make an HTTP POST to /api/auth/tokens
        _ = self;
        _ = access_token;
        _ = access_token_secret;
        
        // Mock success for demonstration
        return true;
    }
    
    fn sendHtml(self: *Self, response: *std.http.Server.Response, html: []const u8) !void {
        _ = self;
        
        response.status = .ok;
        response.transfer_encoding = .{ .content_length = html.len };
        try response.headers.append("content-type", "text/html; charset=utf-8");
        try response.do();
        
        _ = try response.writeAll(html);
        try response.finish();
    }
    
    fn sendError(self: *Self, response: *std.http.Server.Response, message: []const u8, err: anytype) !void {
        var error_buf: [1024]u8 = undefined;
        const error_html = try std.fmt.bufPrint(&error_buf,
        \\<!DOCTYPE html>
        \\<html><head><title>Error</title></head>
        \\<body style="font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5;">
        \\    <div style="max-width: 600px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px;">
        \\        <h1 style="color: #dc3545;">❌ Error</h1>
        \\        <p><strong>Message:</strong> {s}</p>
        \\        <p><strong>Details:</strong> {}</p>
        \\        <a href="/" style="display: inline-block; margin-top: 20px; padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 4px;">🏠 Back to Home</a>
        \\    </div>
        \\</body></html>
        , .{ message, err });
        
        try self.sendHtml(response, error_html);
    }
    
    fn sendPlaceholder(self: *Self, response: *std.http.Server.Response, title: []const u8, description: []const u8) !void {
        var html_buf: [2048]u8 = undefined;
        const html = try std.fmt.bufPrint(&html_buf,
        \\<!DOCTYPE html>
        \\<html><head><title>{s} - Yahoo Fantasy Sports</title></head>
        \\<body style="font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5;">
        \\    <div style="max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px;">
        \\        <h1>🚧 {s}</h1>
        \\        <p>{s}</p>
        \\        <div style="background: #f8f9fa; padding: 20px; border-radius: 6px; margin: 20px 0;">
        \\            <h3>🔜 Coming Soon</h3>
        \\            <p>This feature is currently under development and will be available in the next update.</p>
        \\        </div>
        \\        <a href="/" style="display: inline-block; margin-top: 20px; padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 4px;">🏠 Back to Home</a>
        \\    </div>
        \\</body></html>
        , .{ title, title, description });
        
        try self.sendHtml(response, html);
    }
    
    fn send404(self: *Self, response: *std.http.Server.Response) !void {
        const html = 
        \\<!DOCTYPE html>
        \\<html><head><title>404 - Page Not Found</title></head>
        \\<body style="font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5;">
        \\    <div style="max-width: 600px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px;">
        \\        <h1 style="color: #dc3545;">🔍 404 - Page Not Found</h1>
        \\        <p>The requested page could not be found.</p>
        \\        <a href="/" style="display: inline-block; margin-top: 20px; padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 4px;">🏠 Back to Home</a>
        \\    </div>
        \\</body></html>
        ;
        
        response.status = .not_found;
        response.transfer_encoding = .{ .content_length = html.len };
        try response.headers.append("content-type", "text/html; charset=utf-8");
        try response.do();
        
        _ = try response.writeAll(html);
        try response.finish();
    }
};

// ============================================================================
// Demo/Example Usage
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("Yahoo Fantasy Web Client (Zig)\n");
    print("==============================\n\n");
    
    // Initialize web client
    var client = try WebClient.init(
        allocator,
        3000, // Client runs on port 3000
        "http://localhost:8080", // API server on port 8080
    );
    defer client.deinit();
    
    print("Web client configuration:\n");
    print("  Port: {d}\n", .{client.port});
    print("  API Base URL: {s}\n", .{client.api_base_url});
    print("\nStarting web client server...\n\n");
    
    // Start the web client (this will block)
    try client.start();
}

// ============================================================================
// Tests
// ============================================================================

test "WebClient initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var client = try WebClient.init(allocator, 3000, "http://localhost:8080");
    defer client.deinit();
    
    try testing.expect(client.port == 3000);
    try testing.expectEqualStrings("http://localhost:8080", client.api_base_url);
}