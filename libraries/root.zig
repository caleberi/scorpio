pub const processor = struct {
    pub const documents = struct {
        pub const loader = @import("processor/documents/loader.zig");
        pub const manifest = @import("processor/documents/manifest.zig");
        pub const packer = @import("processor/documents/packer.zig");
    };
    pub const media = @import("processor/media/link.zig");
    pub const images = @import("processor/images/processor.zig");
    pub const videos = @import("processor/videos/processor.zig");
};

pub const validation = struct {
    pub const types = @import("validation/types.zig");
    pub const schema = @import("validation/schema.zig");
    pub const engine = @import("validation/engine.zig");
    pub const lexer = @import("validation/lexer.zig");
    pub const parser = @import("validation/parser.zig");
    pub const default = @import("validation/default.zig");
    pub const cursor = @import("validation/cursor.zig");
};

pub const dotenv = struct {
    pub const loader = @import("env/loader.zig");
    pub const binder = @import("env/bind.zig");
};

pub const uploader = struct {
    pub const cloudinary = @import("uploader/cloudinary.zig");
};

pub const router = @import("router/root.zig");
pub const fs = @import("compat_fs.zig");
pub const validator = @import("validator.zig");

test {
    _ = validation.types;
    _ = validation.schema;
    _ = validation.engine;
    _ = validation.lexer;
    _ = validation.parser;
    _ = processor.documents.loader;
    _ = processor.documents.manifest;
    _ = processor.documents.packer;
    _ = processor.media;
    _ = processor.images;
    _ = processor.videos;
    _ = uploader.cloudinary;
    _ = router;
    _ = dotenv.loader;
    _ = dotenv.binder;
    _ = validator;
}
