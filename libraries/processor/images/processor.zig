const std = @import("std");
const cloudinary = @import("../../uploader/cloudinary.zig");
const link = @import("../media/link.zig");

pub const Kind = link.Kind;
pub const Lifecycle = link.Lifecycle;
pub const AssetEntry = link.AssetEntry;
pub const LinkageData = link.LinkageData;
pub const Processor = link.Processor;

pub const extensions = link.image_extensions;

pub const Config = struct {
    input_dir: []const u8,
    output_dir: []const u8,
    asset_root: ?[]const u8 = null,
    linkage_name: []const u8 = "images-links.json",
    public_id_prefix: []const u8 = link.project_name,
    included_extensions: []const []const u8 = &link.image_extensions,
    allow_delete: bool = true,
    prune_orphans: bool = false,

    fn toLink(self: Config) link.Config {
        return .{
            .input_dir = self.input_dir,
            .output_dir = self.output_dir,
            .asset_root = self.asset_root,
            .linkage_name = self.linkage_name,
            .public_id_prefix = self.public_id_prefix,
            .included_extensions = self.included_extensions,
            .resource_type = .image,
            .allow_delete = self.allow_delete,
            .prune_orphans = self.prune_orphans,
        };
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    cloud: *cloudinary.Cloudinary,
) Processor {
    return Processor.init(allocator, config.toLink(), cloud);
}

const testing = std.testing;

test "image config maps to the image resource type and defaults" {
    const cfg = Config{ .input_dir = "src", .output_dir = "stage" };
    const mapped = cfg.toLink();
    try testing.expectEqual(cloudinary.ResourceType.image, mapped.resource_type);
    try testing.expectEqualStrings("images-links.json", mapped.linkage_name);
    try testing.expectEqual(link.image_extensions.len, mapped.included_extensions.len);
}
