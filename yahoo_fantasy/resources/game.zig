const std = @import("std");
const Client = @import("../client.zig").Client;

pub const GameType = enum {
    full,
    pickem,
};

pub const GameCode = enum {
    nfl,
    nhl,
    nba,
    mlb,
};

pub const Game = struct {
    game_key: []const u8,
    game_id: u32,
    name: []const u8,
    code: GameCode,
    type: GameType,
    url: []const u8,
    season: u16,
    is_registration_over: bool,
    is_game_over: bool,
    is_offseason: bool,

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !Game {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const game_obj = parsed.value.object.get("game") orelse return error.MissingGameData;
        
        return Game{
            .game_key = try allocator.dupe(u8, game_obj.object.get("game_key").?.string),
            .game_id = @intCast(game_obj.object.get("game_id").?.integer),
            .name = try allocator.dupe(u8, game_obj.object.get("name").?.string),
            .code = std.meta.stringToEnum(GameCode, game_obj.object.get("code").?.string) orelse .nfl,
            .type = std.meta.stringToEnum(GameType, game_obj.object.get("type").?.string) orelse .full,
            .url = try allocator.dupe(u8, game_obj.object.get("url").?.string),
            .season = @intCast(game_obj.object.get("season").?.integer),
            .is_registration_over = game_obj.object.get("is_registration_over").?.integer == 1,
            .is_game_over = game_obj.object.get("is_game_over").?.integer == 1,
            .is_offseason = game_obj.object.get("is_offseason").?.integer == 1,
        };
    }

    pub fn deinit(self: *Game, allocator: std.mem.Allocator) void {
        allocator.free(self.game_key);
        allocator.free(self.name);
        allocator.free(self.url);
    }
};

pub const GameResource = struct {
    client: *Client,

    const Self = @This();

    pub fn init(client: *Client) Self {
        return Self{ .client = client };
    }

    pub fn getGame(self: *Self, game_key: []const u8) !Game {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "game/{s}", .{game_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        return try Game.fromJson(self.client.allocator, response.body);
    }

    pub fn getGames(self: *Self) !std.ArrayList(Game) {
        const response = try self.client.get("games", null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        var games = std.ArrayList(Game).init(self.client.allocator);
        
        var parsed = std.json.parseFromSlice(std.json.Value, self.client.allocator, response.body, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const games_array = parsed.value.object.get("fantasy_content").?.object.get("games").?.array;
        
        for (games_array.items) |game_item| {
            if (game_item.object.get("game")) |game_data| {
                const game = try Game.fromJson(self.client.allocator, try std.json.stringifyAlloc(self.client.allocator, game_data, .{}));
                try games.append(game);
            }
        }

        return games;
    }

    pub fn getGamesByIds(self: *Self, game_ids: []const u32) !std.ArrayList(Game) {
        var params = std.StringHashMap([]const u8).init(self.client.allocator);
        defer params.deinit();

        var ids_str = std.ArrayList(u8).init(self.client.allocator);
        defer ids_str.deinit();

        for (game_ids, 0..) |id, i| {
            if (i > 0) try ids_str.append(',');
            try ids_str.writer().print("{d}", .{id});
        }

        try params.put("game_keys", try ids_str.toOwnedSlice());

        const response = try self.client.get("games", params);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        var games = std.ArrayList(Game).init(self.client.allocator);
        
        var parsed = std.json.parseFromSlice(std.json.Value, self.client.allocator, response.body, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const games_array = parsed.value.object.get("fantasy_content").?.object.get("games").?.array;
        
        for (games_array.items) |game_item| {
            if (game_item.object.get("game")) |game_data| {
                const game = try Game.fromJson(self.client.allocator, try std.json.stringifyAlloc(self.client.allocator, game_data, .{}));
                try games.append(game);
            }
        }

        return games;
    }
};

test "game parsing from json" {
    const allocator = std.testing.allocator;
    const json_str = 
        \\{
        \\  "game": {
        \\    "game_key": "nfl",
        \\    "game_id": 449,
        \\    "name": "Football",
        \\    "code": "nfl",
        \\    "type": "full",
        \\    "url": "https://football.fantasysports.yahoo.com/f1",
        \\    "season": 2024,
        \\    "is_registration_over": 0,
        \\    "is_game_over": 0,
        \\    "is_offseason": 1
        \\  }
        \\}
    ;

    var game = try Game.fromJson(allocator, json_str);
    defer game.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "nfl", game.game_key);
    try std.testing.expectEqual(@as(u32, 449), game.game_id);
    try std.testing.expectEqualSlices(u8, "Football", game.name);
    try std.testing.expectEqual(GameCode.nfl, game.code);
    try std.testing.expectEqual(GameType.full, game.type);
    try std.testing.expectEqual(@as(u16, 2024), game.season);
    try std.testing.expectEqual(false, game.is_registration_over);
    try std.testing.expectEqual(false, game.is_game_over);
    try std.testing.expectEqual(true, game.is_offseason);
}