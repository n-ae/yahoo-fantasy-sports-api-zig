const std = @import("std");
const Client = @import("../client.zig").Client;

pub const ScoringType = enum {
    head2head,
    points,
    rotisserie,
};

pub const League = struct {
    league_key: []const u8,
    league_id: u32,
    name: []const u8,
    url: []const u8,
    logo_url: ?[]const u8,
    password: ?[]const u8,
    draft_status: []const u8,
    num_teams: u32,
    edit_key: u32,
    weekly_deadline: []const u8,
    league_update_timestamp: u64,
    scoring_type: ScoringType,
    league_type: []const u8,
    renew: ?[]const u8,
    renewed: ?[]const u8,
    iris_group_chat_id: ?[]const u8,
    allow_add_to_dl_extra_pos: bool,
    is_pro_league: bool,
    is_cash_league: bool,
    current_week: u32,
    start_week: u32,
    start_date: []const u8,
    end_week: u32,
    end_date: []const u8,
    game_code: []const u8,
    season: u16,

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !League {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const league_obj = parsed.value.object.get("league") orelse return error.MissingLeagueData;
        
        return League{
            .league_key = try allocator.dupe(u8, league_obj.object.get("league_key").?.string),
            .league_id = @intCast(league_obj.object.get("league_id").?.integer),
            .name = try allocator.dupe(u8, league_obj.object.get("name").?.string),
            .url = try allocator.dupe(u8, league_obj.object.get("url").?.string),
            .logo_url = if (league_obj.object.get("logo_url")) |logo| try allocator.dupe(u8, logo.string) else null,
            .password = if (league_obj.object.get("password")) |pwd| try allocator.dupe(u8, pwd.string) else null,
            .draft_status = try allocator.dupe(u8, league_obj.object.get("draft_status").?.string),
            .num_teams = @intCast(league_obj.object.get("num_teams").?.integer),
            .edit_key = @intCast(league_obj.object.get("edit_key").?.integer),
            .weekly_deadline = try allocator.dupe(u8, league_obj.object.get("weekly_deadline").?.string),
            .league_update_timestamp = @intCast(league_obj.object.get("league_update_timestamp").?.integer),
            .scoring_type = std.meta.stringToEnum(ScoringType, league_obj.object.get("scoring_type").?.string) orelse .head2head,
            .league_type = try allocator.dupe(u8, league_obj.object.get("league_type").?.string),
            .renew = if (league_obj.object.get("renew")) |renew| try allocator.dupe(u8, renew.string) else null,
            .renewed = if (league_obj.object.get("renewed")) |renewed| try allocator.dupe(u8, renewed.string) else null,
            .iris_group_chat_id = if (league_obj.object.get("iris_group_chat_id")) |chat| try allocator.dupe(u8, chat.string) else null,
            .allow_add_to_dl_extra_pos = league_obj.object.get("allow_add_to_dl_extra_pos").?.integer == 1,
            .is_pro_league = league_obj.object.get("is_pro_league").?.integer == 1,
            .is_cash_league = league_obj.object.get("is_cash_league").?.integer == 1,
            .current_week = @intCast(league_obj.object.get("current_week").?.integer),
            .start_week = @intCast(league_obj.object.get("start_week").?.integer),
            .start_date = try allocator.dupe(u8, league_obj.object.get("start_date").?.string),
            .end_week = @intCast(league_obj.object.get("end_week").?.integer),
            .end_date = try allocator.dupe(u8, league_obj.object.get("end_date").?.string),
            .game_code = try allocator.dupe(u8, league_obj.object.get("game_code").?.string),
            .season = @intCast(league_obj.object.get("season").?.integer),
        };
    }

    pub fn deinit(self: *League, allocator: std.mem.Allocator) void {
        allocator.free(self.league_key);
        allocator.free(self.name);
        allocator.free(self.url);
        if (self.logo_url) |logo| allocator.free(logo);
        if (self.password) |pwd| allocator.free(pwd);
        allocator.free(self.draft_status);
        allocator.free(self.weekly_deadline);
        allocator.free(self.league_type);
        if (self.renew) |renew| allocator.free(renew);
        if (self.renewed) |renewed| allocator.free(renewed);
        if (self.iris_group_chat_id) |chat| allocator.free(chat);
        allocator.free(self.start_date);
        allocator.free(self.end_date);
        allocator.free(self.game_code);
    }
};

pub const LeagueResource = struct {
    client: *Client,

    const Self = @This();

    pub fn init(client: *Client) Self {
        return Self{ .client = client };
    }

    pub fn getLeague(self: *Self, league_key: []const u8) !League {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "league/{s}", .{league_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        return try League.fromJson(self.client.allocator, response.body);
    }

    pub fn getUserLeagues(self: *Self, game_key: []const u8) !std.ArrayList(League) {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "users;use_login=1/games;game_keys={s}/leagues", .{game_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        var leagues = std.ArrayList(League).init(self.client.allocator);
        
        var parsed = std.json.parseFromSlice(std.json.Value, self.client.allocator, response.body, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const leagues_array = parsed.value.object.get("fantasy_content").?.object.get("users").?.object.get("0").?.object.get("user").?.array[1].object.get("games").?.object.get("0").?.object.get("game").?.array[1].object.get("leagues").?.array;
        
        for (leagues_array.items) |league_item| {
            if (league_item.object.get("league")) |league_data| {
                const league = try League.fromJson(self.client.allocator, try std.json.stringifyAlloc(self.client.allocator, league_data, .{}));
                try leagues.append(league);
            }
        }

        return leagues;
    }

    pub fn getLeagueStandings(self: *Self, league_key: []const u8) !std.json.Value {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "league/{s}/standings", .{league_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.client.allocator, response.body, .{});
        return parsed.value;
    }

    pub fn getLeagueScoreboard(self: *Self, league_key: []const u8, week: ?u32) !std.json.Value {
        var endpoint: []u8 = undefined;
        if (week) |w| {
            endpoint = try std.fmt.allocPrint(self.client.allocator, "league/{s}/scoreboard;week={d}", .{ league_key, w });
        } else {
            endpoint = try std.fmt.allocPrint(self.client.allocator, "league/{s}/scoreboard", .{league_key});
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

        const parsed = try std.json.parseFromSlice(std.json.Value, self.client.allocator, response.body, .{});
        return parsed.value;
    }
};

test "league parsing from json" {
    const allocator = std.testing.allocator;
    const json_str = 
        \\{
        \\  "league": {
        \\    "league_key": "449.l.123456",
        \\    "league_id": 123456,
        \\    "name": "Test League",
        \\    "url": "https://football.fantasysports.yahoo.com/f1/123456",
        \\    "logo_url": "https://yahoofantasysports-res.cloudinary.com/image/upload/league_logos/123456.jpg",
        \\    "draft_status": "postdraft",
        \\    "num_teams": 12,
        \\    "edit_key": 2024,
        \\    "weekly_deadline": "intraday",
        \\    "league_update_timestamp": 1640995200,
        \\    "scoring_type": "head2head",
        \\    "league_type": "private",
        \\    "allow_add_to_dl_extra_pos": 0,
        \\    "is_pro_league": 0,
        \\    "is_cash_league": 0,
        \\    "current_week": 17,
        \\    "start_week": 1,
        \\    "start_date": "2024-09-05",
        \\    "end_week": 17,
        \\    "end_date": "2024-12-30",
        \\    "game_code": "nfl",
        \\    "season": 2024
        \\  }
        \\}
    ;

    var league = try League.fromJson(allocator, json_str);
    defer league.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "449.l.123456", league.league_key);
    try std.testing.expectEqual(@as(u32, 123456), league.league_id);
    try std.testing.expectEqualSlices(u8, "Test League", league.name);
    try std.testing.expectEqual(ScoringType.head2head, league.scoring_type);
    try std.testing.expectEqual(@as(u32, 12), league.num_teams);
    try std.testing.expectEqual(@as(u16, 2024), league.season);
    try std.testing.expectEqual(false, league.allow_add_to_dl_extra_pos);
    try std.testing.expectEqual(false, league.is_pro_league);
    try std.testing.expectEqual(false, league.is_cash_league);
}