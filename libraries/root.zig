pub const processor = struct {
    pub const documents = struct {
        pub const loader = @import("processor/documents/loader.zig");
        pub const manifest = @import("processor/documents/manifest.zig");
        pub const packer = @import("processor/documents/packer.zig");
    };
    pub const media = @import("processor/media/link.zig");
    pub const images = @import("processor/images/processor.zig");
    pub const videos = @import("processor/videos/processor.zig");
    pub const presentation = struct {
        pub const processor = @import("processor/presentation/processor.zig");
        pub const parser = @import("processor/presentation/parser.zig");
        pub const deck = @import("processor/presentation/deck.zig");
        pub const animation = @import("processor/presentation/renderer/animation.zig");
        pub const carousel = @import("processor/presentation/renderer/carousel.zig");
        pub const color = @import("processor/presentation/components/color.zig");
        pub const shape = @import("processor/presentation/components/shape.zig");
        pub const canvas = @import("processor/presentation/components/canvas.zig");
        pub const painter = @import("processor/presentation/components/painter.zig");
    };
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
    pub const pool = @import("uploader/pool.zig");
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
    _ = processor.presentation.processor;
    _ = processor.presentation.parser;
    _ = processor.presentation.deck;
    _ = processor.presentation.animation;
    _ = processor.presentation.carousel;
    _ = processor.presentation.color;
    _ = processor.presentation.shape;
    _ = uploader.cloudinary;
    _ = uploader.pool;
    _ = router;
    _ = dotenv.loader;
    _ = dotenv.binder;
    _ = validator;
}
