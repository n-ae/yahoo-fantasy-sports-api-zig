//! Yahoo Fantasy Sports API Zig bindings
const std = @import("std");

pub const Client = @import("yahoo_fantasy/client.zig").Client;
pub const ClientError = @import("yahoo_fantasy/client.zig").ClientError;
pub const OAuth = @import("yahoo_fantasy/oauth.zig");
pub const errors = @import("yahoo_fantasy/errors.zig");
pub const rate_limiter = @import("yahoo_fantasy/rate_limiter.zig");
pub const cache = @import("yahoo_fantasy/cache.zig");
pub const logging = @import("yahoo_fantasy/logging.zig");
pub const Game = @import("yahoo_fantasy/resources/game.zig");
pub const League = @import("yahoo_fantasy/resources/league.zig");
pub const Team = @import("yahoo_fantasy/resources/team.zig");
pub const Player = @import("yahoo_fantasy/resources/player.zig");

test {
    std.testing.refAllDecls(@This());
}
