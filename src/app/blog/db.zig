const std = @import("std");
const pg = @import("pg");

pub const Comment = struct {
    id: []const u8,
    blog_id: []const u8,
    author: []const u8,
    body: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Reply = struct {
    id: []const u8,
    comment_id: []const u8,
    blog_id: []const u8,
    author: []const u8,
    body: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const BlogDb = struct {
    pool: *pg.Pool,

    pub fn init(pool: *pg.Pool) BlogDb {
        return .{ .pool = pool };
    }

    pub fn blogIdBySlug(self: *BlogDb, allocator: std.mem.Allocator, slug: []const u8) !?[]u8 {
        var row = (try self.pool.row("select id::text from blogs where slug = $1", .{slug})) orelse return null;
        defer row.deinit() catch {};
        return try allocator.dupe(u8, try row.get([]const u8, 0));
    }

    pub fn listComments(
        self: *BlogDb,
        allocator: std.mem.Allocator,
        blog_id: []const u8,
    ) ![]Comment {
        var result = try self.pool.query(
            \\select id::text, blog_id::text, author, body,
            \\       created_at::text, updated_at::text
            \\from comments where blog_id = $1::uuid
            \\order by created_at asc
        ,
            .{blog_id},
        );
        defer result.deinit();

        var list: std.ArrayList(Comment) = .empty;
        errdefer {
            for (list.items) |c| freeComment(allocator, c);
            list.deinit(allocator);
        }

        while (try result.next()) |row| {
            try list.append(allocator, .{
                .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
                .blog_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
                .author = try allocator.dupe(u8, try row.get([]const u8, 2)),
                .body = try allocator.dupe(u8, try row.get([]const u8, 3)),
                .created_at = try allocator.dupe(u8, try row.get([]const u8, 4)),
                .updated_at = try allocator.dupe(u8, try row.get([]const u8, 5)),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn listReplies(
        self: *BlogDb,
        allocator: std.mem.Allocator,
        comment_id: []const u8,
    ) ![]Reply {
        var result = try self.pool.query(
            \\select id::text, comment_id::text, blog_id::text, author, body,
            \\       created_at::text, updated_at::text
            \\from replies where comment_id = $1::uuid
            \\order by created_at asc
        ,
            .{comment_id},
        );
        defer result.deinit();

        var list: std.ArrayList(Reply) = .empty;
        errdefer {
            for (list.items) |r| freeReply(allocator, r);
            list.deinit(allocator);
        }

        while (try result.next()) |row| {
            try list.append(allocator, .{
                .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
                .comment_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
                .blog_id = try allocator.dupe(u8, try row.get([]const u8, 2)),
                .author = try allocator.dupe(u8, try row.get([]const u8, 3)),
                .body = try allocator.dupe(u8, try row.get([]const u8, 4)),
                .created_at = try allocator.dupe(u8, try row.get([]const u8, 5)),
                .updated_at = try allocator.dupe(u8, try row.get([]const u8, 6)),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn createComment(
        self: *BlogDb,
        allocator: std.mem.Allocator,
        blog_id: []const u8,
        author: []const u8,
        body: []const u8,
    ) !Comment {
        var row = (try self.pool.row(
            \\insert into comments (blog_id, author, body)
            \\values ($1::uuid, $2, $3)
            \\returning id::text, blog_id::text, author, body,
            \\          created_at::text, updated_at::text
        ,
            .{ blog_id, author, body },
        )) orelse return error.InsertFailed;
        defer row.deinit() catch {};
        return try readComment(allocator, &row);
    }

    pub fn updateComment(
        self: *BlogDb,
        allocator: std.mem.Allocator,
        blog_id: []const u8,
        comment_id: []const u8,
        body: []const u8,
    ) !?Comment {
        var row = (try self.pool.row(
            \\update comments set body = $1, updated_at = NOW()
            \\where id = $2::uuid and blog_id = $3::uuid
            \\returning id::text, blog_id::text, author, body,
            \\          created_at::text, updated_at::text
        ,
            .{ body, comment_id, blog_id },
        )) orelse return null;
        defer row.deinit() catch {};
        return try readComment(allocator, &row);
    }

    pub fn deleteComment(self: *BlogDb, blog_id: []const u8, comment_id: []const u8) !bool {
        const n = try self.pool.exec(
            "delete from comments where id = $1::uuid and blog_id = $2::uuid",
            .{ comment_id, blog_id },
        );
        return (n orelse 0) > 0;
    }

    pub fn createReply(
        self: *BlogDb,
        allocator: std.mem.Allocator,
        blog_id: []const u8,
        comment_id: []const u8,
        author: []const u8,
        body: []const u8,
    ) !?Reply {
        // Ensure comment belongs to blog.
        var owns = try self.pool.row(
            "select 1 from comments where id = $1::uuid and blog_id = $2::uuid",
            .{ comment_id, blog_id },
        );
        if (owns == null) return null;
        defer owns.?.deinit() catch {};

        var row = (try self.pool.row(
            \\insert into replies (comment_id, blog_id, author, body)
            \\values ($1::uuid, $2::uuid, $3, $4)
            \\returning id::text, comment_id::text, blog_id::text, author, body,
            \\          created_at::text, updated_at::text
        ,
            .{ comment_id, blog_id, author, body },
        )) orelse return error.InsertFailed;
        defer row.deinit() catch {};
        return try readReply(allocator, &row);
    }

    pub fn updateReply(
        self: *BlogDb,
        allocator: std.mem.Allocator,
        blog_id: []const u8,
        comment_id: []const u8,
        reply_id: []const u8,
        body: []const u8,
    ) !?Reply {
        var row = (try self.pool.row(
            \\update replies set body = $1, updated_at = NOW()
            \\where id = $2::uuid and comment_id = $3::uuid and blog_id = $4::uuid
            \\returning id::text, comment_id::text, blog_id::text, author, body,
            \\          created_at::text, updated_at::text
        ,
            .{ body, reply_id, comment_id, blog_id },
        )) orelse return null;
        defer row.deinit() catch {};
        return try readReply(allocator, &row);
    }

    pub fn deleteReply(
        self: *BlogDb,
        blog_id: []const u8,
        comment_id: []const u8,
        reply_id: []const u8,
    ) !bool {
        const n = try self.pool.exec(
            \\delete from replies
            \\where id = $1::uuid and comment_id = $2::uuid and blog_id = $3::uuid
        ,
            .{ reply_id, comment_id, blog_id },
        );
        return (n orelse 0) > 0;
    }
};

fn readComment(allocator: std.mem.Allocator, row: anytype) !Comment {
    return .{
        .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
        .blog_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
        .author = try allocator.dupe(u8, try row.get([]const u8, 2)),
        .body = try allocator.dupe(u8, try row.get([]const u8, 3)),
        .created_at = try allocator.dupe(u8, try row.get([]const u8, 4)),
        .updated_at = try allocator.dupe(u8, try row.get([]const u8, 5)),
    };
}

fn readReply(allocator: std.mem.Allocator, row: anytype) !Reply {
    return .{
        .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
        .comment_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
        .blog_id = try allocator.dupe(u8, try row.get([]const u8, 2)),
        .author = try allocator.dupe(u8, try row.get([]const u8, 3)),
        .body = try allocator.dupe(u8, try row.get([]const u8, 4)),
        .created_at = try allocator.dupe(u8, try row.get([]const u8, 5)),
        .updated_at = try allocator.dupe(u8, try row.get([]const u8, 6)),
    };
}

pub fn freeComment(allocator: std.mem.Allocator, c: Comment) void {
    allocator.free(c.id);
    allocator.free(c.blog_id);
    allocator.free(c.author);
    allocator.free(c.body);
    allocator.free(c.created_at);
    allocator.free(c.updated_at);
}

pub fn freeReply(allocator: std.mem.Allocator, r: Reply) void {
    allocator.free(r.id);
    allocator.free(r.comment_id);
    allocator.free(r.blog_id);
    allocator.free(r.author);
    allocator.free(r.body);
    allocator.free(r.created_at);
    allocator.free(r.updated_at);
}
