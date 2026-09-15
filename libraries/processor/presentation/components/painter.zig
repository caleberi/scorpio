const zstd = @import("std");
/// Paint node kinds emitted by the compiler. The frontend draws these; Zig does not rasterize.
pub const Kind = enum {
    text,
    image,
    video,
    shape,
    table,
    mermaid,
    markdown,
    group,

    pub fn json(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn parse(name: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (zstd.mem.eql(u8, name, field.name))
                return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const Fit = enum {
    contain,
    cover,
    stretch,

    pub fn json(self: Fit) []const u8 {
        return @tagName(self);
    }
};

pub const ShapeKind = enum {
    rect,
    ellipse,

    pub fn json(self: ShapeKind) []const u8 {
        return @tagName(self);
    }
};
