const std = @import("std");
const Client = @import("../client.zig").Client;

pub const Team = struct {
    team_key: []const u8,
    team_id: u32,
    name: []const u8,
    is_owned_by_current_login: bool,
    url: []const u8,
    team_logos: std.ArrayList(TeamLogo),
    waiver_priority: u32,
    number_of_moves: u32,
    number_of_trades: u32,
    roster_adds: RosterAdds,
    clinched_playoffs: bool,
    league_scoring_type: []const u8,
    has_draft_grade: bool,
    managers: std.ArrayList(Manager),

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !Team {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const team_obj = parsed.value.object.get("team") orelse return error.MissingTeamData;
        
        var team_logos = std.ArrayList(TeamLogo).init(allocator);
        if (team_obj.object.get("team_logos")) |logos| {
            for (logos.object.get("team_logo").?.array.items) |logo_item| {
                try team_logos.append(try TeamLogo.fromJson(allocator, try std.json.stringifyAlloc(allocator, logo_item, .{})));
            }
        }

        var managers = std.ArrayList(Manager).init(allocator);
        if (team_obj.object.get("managers")) |mgrs| {
            for (mgrs.object.get("manager").?.array.items) |manager_item| {
                try managers.append(try Manager.fromJson(allocator, try std.json.stringifyAlloc(allocator, manager_item, .{})));
            }
        }

        const roster_adds_obj = team_obj.object.get("roster_adds").?;
        const roster_adds = RosterAdds{
            .coverage_type = try allocator.dupe(u8, roster_adds_obj.object.get("coverage_type").?.string),
            .coverage_value = @intCast(roster_adds_obj.object.get("coverage_value").?.integer),
            .value = @intCast(roster_adds_obj.object.get("value").?.integer),
        };

        return Team{
            .team_key = try allocator.dupe(u8, team_obj.object.get("team_key").?.string),
            .team_id = @intCast(team_obj.object.get("team_id").?.integer),
            .name = try allocator.dupe(u8, team_obj.object.get("name").?.string),
            .is_owned_by_current_login = team_obj.object.get("is_owned_by_current_login").?.integer == 1,
            .url = try allocator.dupe(u8, team_obj.object.get("url").?.string),
            .team_logos = team_logos,
            .waiver_priority = @intCast(team_obj.object.get("waiver_priority").?.integer),
            .number_of_moves = @intCast(team_obj.object.get("number_of_moves").?.integer),
            .number_of_trades = @intCast(team_obj.object.get("number_of_trades").?.integer),
            .roster_adds = roster_adds,
            .clinched_playoffs = team_obj.object.get("clinched_playoffs").?.integer == 1,
            .league_scoring_type = try allocator.dupe(u8, team_obj.object.get("league_scoring_type").?.string),
            .has_draft_grade = team_obj.object.get("has_draft_grade").?.integer == 1,
            .managers = managers,
        };
    }

    pub fn deinit(self: *Team, allocator: std.mem.Allocator) void {
        allocator.free(self.team_key);
        allocator.free(self.name);
        allocator.free(self.url);
        
        for (self.team_logos.items) |*logo| {
            logo.deinit(allocator);
        }
        self.team_logos.deinit();

        allocator.free(self.roster_adds.coverage_type);
        allocator.free(self.league_scoring_type);
        
        for (self.managers.items) |*manager| {
            manager.deinit(allocator);
        }
        self.managers.deinit();
    }
};

pub const TeamLogo = struct {
    size: []const u8,
    url: []const u8,

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !TeamLogo {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        return TeamLogo{
            .size = try allocator.dupe(u8, parsed.value.object.get("size").?.string),
            .url = try allocator.dupe(u8, parsed.value.object.get("url").?.string),
        };
    }

    pub fn deinit(self: *TeamLogo, allocator: std.mem.Allocator) void {
        allocator.free(self.size);
        allocator.free(self.url);
    }
};

pub const Manager = struct {
    manager_id: u32,
    nickname: []const u8,
    guid: []const u8,
    is_commissioner: bool,
    is_current_login: bool,
    email: ?[]const u8,
    image_url: ?[]const u8,

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !Manager {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const manager_obj = parsed.value.object.get("manager") orelse parsed.value;

        return Manager{
            .manager_id = @intCast(manager_obj.object.get("manager_id").?.integer),
            .nickname = try allocator.dupe(u8, manager_obj.object.get("nickname").?.string),
            .guid = try allocator.dupe(u8, manager_obj.object.get("guid").?.string),
            .is_commissioner = manager_obj.object.get("is_commissioner").?.integer == 1,
            .is_current_login = manager_obj.object.get("is_current_login").?.integer == 1,
            .email = if (manager_obj.object.get("email")) |email| try allocator.dupe(u8, email.string) else null,
            .image_url = if (manager_obj.object.get("image_url")) |img| try allocator.dupe(u8, img.string) else null,
        };
    }

    pub fn deinit(self: *Manager, allocator: std.mem.Allocator) void {
        allocator.free(self.nickname);
        allocator.free(self.guid);
        if (self.email) |email| allocator.free(email);
        if (self.image_url) |img| allocator.free(img);
    }
};

pub const RosterAdds = struct {
    coverage_type: []const u8,
    coverage_value: u32,
    value: u32,
};

pub const TeamResource = struct {
    client: *Client,

    const Self = @This();

    pub fn init(client: *Client) Self {
        return Self{ .client = client };
    }

    pub fn getTeam(self: *Self, team_key: []const u8) !Team {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "team/{s}", .{team_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        return try Team.fromJson(self.client.allocator, response.body);
    }

    pub fn getLeagueTeams(self: *Self, league_key: []const u8) !std.ArrayList(Team) {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "league/{s}/teams", .{league_key});
        defer self.client.allocator.free(endpoint);

        const response = try self.client.get(endpoint, null);
        defer {
            var mut_response = response;
            mut_response.deinit(self.client.allocator);
        }

        if (response.status_code != 200) {
            return error.RequestFailed;
        }

        var teams = std.ArrayList(Team).init(self.client.allocator);
        
        var parsed = std.json.parseFromSlice(std.json.Value, self.client.allocator, response.body, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const teams_array = parsed.value.object.get("fantasy_content").?.object.get("league").?.array[1].object.get("teams").?.array;
        
        for (teams_array.items) |team_item| {
            if (team_item.object.get("team")) |team_data| {
                const team = try Team.fromJson(self.client.allocator, try std.json.stringifyAlloc(self.client.allocator, team_data, .{}));
                try teams.append(team);
            }
        }

        return teams;
    }

    pub fn getTeamRoster(self: *Self, team_key: []const u8, week: ?u32) !std.json.Value {
        var endpoint: []u8 = undefined;
        if (week) |w| {
            endpoint = try std.fmt.allocPrint(self.client.allocator, "team/{s}/roster;week={d}", .{ team_key, w });
        } else {
            endpoint = try std.fmt.allocPrint(self.client.allocator, "team/{s}/roster", .{team_key});
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

    pub fn getTeamMatchup(self: *Self, team_key: []const u8, week: u32) !std.json.Value {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "team/{s}/matchups;weeks={d}", .{ team_key, week });
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

test "team logo parsing from json" {
    const allocator = std.testing.allocator;
    const json_str = 
        \\{
        \\  "size": "large",
        \\  "url": "https://yahoofantasysports-res.cloudinary.com/image/upload/team_logos/123456.jpg"
        \\}
    ;

    var logo = try TeamLogo.fromJson(allocator, json_str);
    defer logo.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "large", logo.size);
    try std.testing.expectEqualSlices(u8, "https://yahoofantasysports-res.cloudinary.com/image/upload/team_logos/123456.jpg", logo.url);
}