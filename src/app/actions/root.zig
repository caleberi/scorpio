pub const blogs = struct {
    pub const List = @import("blogs/list.zig").List;
    pub const Get = @import("blogs/get.zig").Get;
};

pub const comments = struct {
    pub const List = @import("comments/list.zig").List;
    pub const Create = @import("comments/create.zig").Create;
    pub const Update = @import("comments/update.zig").Update;
    pub const Delete = @import("comments/delete.zig").Delete;
};

pub const replies = struct {
    pub const Create = @import("replies/create.zig").Create;
    pub const Update = @import("replies/update.zig").Update;
    pub const Delete = @import("replies/delete.zig").Delete;
};
