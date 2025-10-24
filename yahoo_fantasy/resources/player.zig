const std = @import("std");
const Client = @import("../client.zig").Client;

pub const EligiblePosition = enum {
    QB,
    RB,
    WR,
    TE,
    K,
    DEF,
    BN,
    IR,
};

pub const Player = struct {
    player_key: []const u8,
    player_id: u32,
    name: PlayerName,
    editorial_player_key: []const u8,
    editorial_team_key: []const u8,
    editorial_team_full_name: []const u8,
    editorial_team_abbr: []const u8,
    bye_weeks: std.ArrayList(u32),
    uniform_number: u32,
    display_position: []const u8,
    headshot: PlayerHeadshot,
    image_url: []const u8,
    is_undroppable: bool,
    position_type: []const u8,
    primary_position: []const u8,
    eligible_positions: std.ArrayList(EligiblePosition),

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !Player {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const player_obj = parsed.value.object.get("player") orelse return error.MissingPlayerData;
        
        var bye_weeks = std.ArrayList(u32).init(allocator);
        if (player_obj.object.get("bye_weeks")) |weeks| {
            for (weeks.object.get("week").?.array.items) |week_item| {
                try bye_weeks.append(@intCast(week_item.integer));
            }
        }

        var eligible_positions = std.ArrayList(EligiblePosition).init(allocator);
        if (player_obj.object.get("eligible_positions")) |positions| {
            for (positions.object.get("position").?.array.items) |pos_item| {
                const pos_str = pos_item.string;
                if (std.meta.stringToEnum(EligiblePosition, pos_str)) |pos| {
                    try eligible_positions.append(pos);
                }
            }
        }

        const name_obj = player_obj.object.get("name").?;
        const name = PlayerName{
            .full = try allocator.dupe(u8, name_obj.object.get("full").?.string),
            .first = try allocator.dupe(u8, name_obj.object.get("first").?.string),
            .last = try allocator.dupe(u8, name_obj.object.get("last").?.string),
            .ascii_first = try allocator.dupe(u8, name_obj.object.get("ascii_first").?.string),
            .ascii_last = try allocator.dupe(u8, name_obj.object.get("ascii_last").?.string),
        };

        const headshot_obj = player_obj.object.get("headshot").?;
        const headshot = PlayerHeadshot{
            .url = try allocator.dupe(u8, headshot_obj.object.get("url").?.string),
            .size = try allocator.dupe(u8, headshot_obj.object.get("size").?.string),
        };

        return Player{
            .player_key = try allocator.dupe(u8, player_obj.object.get("player_key").?.string),
            .player_id = @intCast(player_obj.object.get("player_id").?.integer),
            .name = name,
            .editorial_player_key = try allocator.dupe(u8, player_obj.object.get("editorial_player_key").?.string),
            .editorial_team_key = try allocator.dupe(u8, player_obj.object.get("editorial_team_key").?.string),
            .editorial_team_full_name = try allocator.dupe(u8, player_obj.object.get("editorial_team_full_name").?.string),
            .editorial_team_abbr = try allocator.dupe(u8, player_obj.object.get("editorial_team_abbr").?.string),
            .bye_weeks = bye_weeks,
            .uniform_number = @intCast(player_obj.object.get("uniform_number").?.integer),
            .display_position = try allocator.dupe(u8, player_obj.object.get("display_position").?.string),
            .headshot = headshot,
            .image_url = try allocator.dupe(u8, player_obj.object.get("image_url").?.string),
            .is_undroppable = player_obj.object.get("is_undroppable").?.integer == 1,
            .position_type = try allocator.dupe(u8, player_obj.object.get("position_type").?.string),
            .primary_position = try allocator.dupe(u8, player_obj.object.get("primary_position").?.string),
            .eligible_positions = eligible_positions,
        };
    }

    pub fn deinit(self: *Player, allocator: std.mem.Allocator) void {
        allocator.free(self.player_key);
        self.name.deinit(allocator);
        allocator.free(self.editorial_player_key);
        allocator.free(self.editorial_team_key);
        allocator.free(self.editorial_team_full_name);
        allocator.free(self.editorial_team_abbr);
        self.bye_weeks.deinit();
        allocator.free(self.display_position);
        self.headshot.deinit(allocator);
        allocator.free(self.image_url);
        allocator.free(self.position_type);
        allocator.free(self.primary_position);
        self.eligible_positions.deinit();
    }
};

pub const PlayerName = struct {
    full: []const u8,
    first: []const u8,
    last: []const u8,
    ascii_first: []const u8,
    ascii_last: []const u8,

    pub fn deinit(self: *PlayerName, allocator: std.mem.Allocator) void {
        allocator.free(self.full);
        allocator.free(self.first);
        allocator.free(self.last);
        allocator.free(self.ascii_first);
        allocator.free(self.ascii_last);
    }
};

pub const PlayerHeadshot = struct {
    url: []const u8,
    size: []const u8,

    pub fn deinit(self: *PlayerHeadshot, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.size);
    }
};

pub const PlayerStats = struct {
    stats: std.StringHashMap(f64),
    coverage_type: []const u8,
    coverage_value: []const u8,

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !PlayerStats {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        var stats = std.StringHashMap(f64).init(allocator);
        const stats_obj = parsed.value.object.get("player_stats").?.object.get("stats").?.object.get("stat").?.array;
        
        for (stats_obj.items) |stat_item| {
            const stat_id = stat_item.object.get("stat_id").?.integer;
            const value = stat_item.object.get("value").?.float;
            const key = try std.fmt.allocPrint(allocator, "{d}", .{stat_id});
            try stats.put(key, value);
        }

        const coverage = parsed.value.object.get("player_stats").?.object.get("coverage_type").?.string;
        const coverage_val = parsed.value.object.get("player_stats").?.object.get("coverage_value").?.string;

        return PlayerStats{
            .stats = stats,
            .coverage_type = try allocator.dupe(u8, coverage),
            .coverage_value = try allocator.dupe(u8, coverage_val),
        };
    }

    pub fn deinit(self: *PlayerStats, allocator: std.mem.Allocator) void {
        var iter = self.stats.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.stats.deinit();
        allocator.free(self.coverage_type);
        allocator.free(self.coverage_value);
    }
};

pub const PlayerResource = struct {
    client: *Client,

    const Self = @This();

    pub fn init(client: *Client) Self {
        return Self{ .client = client };
    }

    pub fn getPlayer(self: *Self, player_key: []const u8) !Player {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "player/{s}", .{player_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        return try Player.fromJson(self.client.allocator, response.body);
    }

    pub fn getPlayerStats(self: *Self, player_key: []const u8, week: ?u32) !PlayerStats {
        var endpoint: []u8 = undefined;
        if (week) |w| {
            endpoint = try std.fmt.allocPrint(self.client.allocator, "player/{s}/stats;type=week;week={d}", .{ player_key, w });
        } else {
            endpoint = try std.fmt.allocPrint(self.client.allocator, "player/{s}/stats", .{player_key});
        }
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        return try PlayerStats.fromJson(self.client.allocator, response.body);
    }

    pub fn searchPlayers(self: *Self, search: []const u8, game_key: []const u8) !std.ArrayList(Player) {
        var params = std.StringHashMap([]const u8).init(self.client.allocator);
        defer params.deinit();

        try params.put("search", search);

        const endpoint = try std.fmt.allocPrint(self.client.allocator, "league/{s}/players", .{game_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, params);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        var players = std.ArrayList(Player).init(self.client.allocator);
        
        var parsed = std.json.parseFromSlice(std.json.Value, self.client.allocator, response.body, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const players_array = parsed.value.object.get("fantasy_content").?.object.get("league").?.array[1].object.get("players").?.array;
        
        for (players_array.items) |player_item| {
            if (player_item.object.get("player")) |player_data| {
                const player = try Player.fromJson(self.client.allocator, try std.json.stringifyAlloc(self.client.allocator, player_data, .{}));
                try players.append(player);
            }
        }

        return players;
    }

    pub fn getLeaguePlayers(self: *Self, league_key: []const u8, start: ?u32, count: ?u32) !std.ArrayList(Player) {
        var params = std.StringHashMap([]const u8).init(self.client.allocator);
        defer params.deinit();

        if (start) |s| {
            const start_str = try std.fmt.allocPrint(self.client.allocator, "{d}", .{s});
            try params.put("start", start_str);
        }

        if (count) |c| {
            const count_str = try std.fmt.allocPrint(self.client.allocator, "{d}", .{c});
            try params.put("count", count_str);
        }

        const endpoint = try std.fmt.allocPrint(self.client.allocator, "league/{s}/players", .{league_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, params);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        var players = std.ArrayList(Player).init(self.client.allocator);
        
        var parsed = std.json.parseFromSlice(std.json.Value, self.client.allocator, response.body, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const players_array = parsed.value.object.get("fantasy_content").?.object.get("league").?.array[1].object.get("players").?.array;
        
        for (players_array.items) |player_item| {
            if (player_item.object.get("player")) |player_data| {
                const player = try Player.fromJson(self.client.allocator, try std.json.stringifyAlloc(self.client.allocator, player_data, .{}));
                try players.append(player);
            }
        }

        return players;
    }
};

test "eligible position enum parsing" {
    try std.testing.expectEqual(EligiblePosition.QB, std.meta.stringToEnum(EligiblePosition, "QB"));
    try std.testing.expectEqual(EligiblePosition.RB, std.meta.stringToEnum(EligiblePosition, "RB"));
    try std.testing.expectEqual(EligiblePosition.WR, std.meta.stringToEnum(EligiblePosition, "WR"));
    try std.testing.expectEqual(@as(?EligiblePosition, null), std.meta.stringToEnum(EligiblePosition, "INVALID"));
}