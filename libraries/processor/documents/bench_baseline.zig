//! Snapshot of the pre-refactor `Directory` index from `main`.
//! Used only by `bench.zig` so the compact `Tree` can be timed against the
//! old HashMap + full-path layout.

const zstd = @import("std");
const fs = @import("libraries").fs;
const manifest = @import("libraries").processor.documents.manifest;

pub const File = struct {
    path: []const u8,

    folder_index: usize,
    modified_at: i128,
    created_at: i128,
    size: u64,

    pub fn name(self: File) []const u8 {
        return fs.path.basename(self.path);
    }
};

pub const Folder = struct {
    path: []const u8,

    parent_index: ?usize,
    file_indices: []usize,
    child_indices: []usize,
    modified_at: i128,
    created_at: i128,
    size: u64,

    pub fn name(self: Folder) []const u8 {
        return fs.path.basename(self.path);
    }

    pub fn deinit(self: *Folder, allocator: zstd.mem.Allocator) void {
        allocator.free(self.file_indices);
        allocator.free(self.child_indices);
    }
};

pub const Directory = struct {
    allocator: zstd.mem.Allocator,
    arena: zstd.heap.ArenaAllocator,

    root_path: []const u8,
    folders: []Folder,
    files: []File,

    file_by_path: zstd.StringHashMap(usize),
    folder_by_path: zstd.StringHashMap(usize),

    pub fn load(allocator: zstd.mem.Allocator, path: []const u8) !Directory {
        var arena = zstd.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const strings = arena.allocator();
        const root_path = try fs.realpathAlloc(strings, path);

        var root_dir = try fs.openDirAbsolute(
            root_path,
            .{
                .iterate = true,
            },
        );
        defer root_dir.close();

        const root_stat = try root_dir.stat();
        var folders: zstd.ArrayList(Folder) = .empty;
        errdefer {
            for (folders.items) |*folder| folder.deinit(allocator);
            folders.deinit(allocator);
        }

        var files: zstd.ArrayList(File) = .empty;
        errdefer files.deinit(allocator);

        var folder_file_indices: zstd.ArrayList(zstd.ArrayList(usize)) = .empty;
        errdefer {
            for (folder_file_indices.items) |*list| list.deinit(allocator);
            folder_file_indices.deinit(allocator);
        }

        var folder_child_indices: zstd.ArrayList(zstd.ArrayList(usize)) = .empty;
        errdefer {
            for (folder_child_indices.items) |*list| list.deinit(allocator);
            folder_child_indices.deinit(allocator);
        }

        var folder_by_path = zstd.StringHashMap(usize).init(allocator);
        errdefer folder_by_path.deinit();

        var file_by_path = zstd.StringHashMap(usize).init(allocator);
        errdefer file_by_path.deinit();

        _ = try appendFolder(
            allocator,
            strings,
            &folders,
            &folder_file_indices,
            &folder_child_indices,
            &folder_by_path,
            root_path,
            null,
            root_stat,
        );

        var walker = try root_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    const abs_path = try fs.path.join(allocator, &.{ root_path, entry.path });
                    defer allocator.free(abs_path);

                    const parent_path = fs.path.dirname(abs_path) orelse root_path;
                    const parent_index = folder_by_path.get(parent_path) orelse return error.MissingParentFolder;
                    const stat = try entry.dir.statFile(entry.basename);

                    const folder_index = try appendFolder(
                        allocator,
                        strings,
                        &folders,
                        &folder_file_indices,
                        &folder_child_indices,
                        &folder_by_path,
                        abs_path,
                        parent_index,
                        stat,
                    );
                    try folder_child_indices.items[parent_index].append(allocator, folder_index);
                },
                .file => {
                    const abs_path = try fs.path.join(allocator, &.{ root_path, entry.path });
                    defer allocator.free(abs_path);

                    const parent_path = fs.path.dirname(abs_path) orelse root_path;
                    const folder_index = folder_by_path.get(parent_path) orelse return error.MissingParentFolder;
                    const stat = try entry.dir.statFile(entry.basename);

                    const file_index = try appendFile(
                        allocator,
                        strings,
                        &files,
                        &file_by_path,
                        abs_path,
                        folder_index,
                        stat,
                    );
                    try folder_file_indices.items[folder_index].append(allocator, file_index);
                },
                else => {},
            }
        }

        for (folders.items, 0..) |*folder, i| {
            folder.file_indices = try folder_file_indices.items[i].toOwnedSlice(allocator);
            folder.child_indices = try folder_child_indices.items[i].toOwnedSlice(allocator);
        }
        folder_file_indices.deinit(allocator);
        folder_child_indices.deinit(allocator);
        folder_file_indices = .empty;
        folder_child_indices = .empty;

        return .{
            .allocator = allocator,
            .arena = arena,
            .root_path = root_path,
            .folders = try folders.toOwnedSlice(allocator),
            .files = try files.toOwnedSlice(allocator),
            .folder_by_path = folder_by_path,
            .file_by_path = file_by_path,
        };
    }

    pub fn deinit(self: *Directory) void {
        const allocator = self.allocator;
        for (self.folders) |*folder| folder.deinit(allocator);
        allocator.free(self.folders);
        allocator.free(self.files);
        self.folder_by_path.deinit();
        self.file_by_path.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn getFolder(self: *const Directory, path: []const u8) ?*Folder {
        const index = self.folder_by_path.get(path) orelse return null;
        return &self.folders[index];
    }

    pub fn getFile(self: *const Directory, path: []const u8) ?*File {
        const index = self.file_by_path.get(path) orelse return null;
        return &self.files[index];
    }
};

fn appendFolder(
    allocator: zstd.mem.Allocator,
    strings: zstd.mem.Allocator,
    folders: *zstd.ArrayList(Folder),
    folder_file_indices: *zstd.ArrayList(zstd.ArrayList(usize)),
    folder_child_indices: *zstd.ArrayList(zstd.ArrayList(usize)),
    folder_by_path: *zstd.StringHashMap(usize),
    path: []const u8,
    parent_index: ?usize,
    stat: fs.Stat,
) !usize {
    const path_owned = try strings.dupe(u8, path);

    try folder_file_indices.append(allocator, .empty);
    errdefer {
        var list = folder_file_indices.pop().?;
        list.deinit(allocator);
    }
    try folder_child_indices.append(allocator, .empty);
    errdefer {
        var list = folder_child_indices.pop().?;
        list.deinit(allocator);
    }

    const folder_index = folders.items.len;
    try folders.append(allocator, .{
        .path = path_owned,
        .parent_index = parent_index,
        .file_indices = &.{},
        .child_indices = &.{},
        .modified_at = stat.mtime,
        .created_at = stat.ctime,
        .size = stat.size,
    });
    errdefer {
        var folder = folders.pop().?;
        folder.deinit(allocator);
    }

    try folder_by_path.put(path_owned, folder_index);
    return folder_index;
}

fn appendFile(
    allocator: zstd.mem.Allocator,
    strings: zstd.mem.Allocator,
    files: *zstd.ArrayList(File),
    file_by_path: *zstd.StringHashMap(usize),
    path: []const u8,
    folder_index: usize,
    stat: fs.Stat,
) !usize {
    const path_owned = try strings.dupe(u8, path);

    const file_index = files.items.len;
    try files.append(allocator, .{
        .path = path_owned,
        .folder_index = folder_index,
        .modified_at = stat.mtime,
        .created_at = stat.ctime,
        .size = stat.size,
    });
    errdefer _ = files.pop();

    try file_by_path.put(path_owned, file_index);
    return file_index;
}

pub fn linearSlugIndex(docs: []const manifest.DocumentEntry, slug: []const u8) ?usize {
    for (docs, 0..) |doc, i| {
        if (zstd.mem.eql(u8, doc.slug, slug)) return i;
    }
    return null;
}

pub fn linearChunkById(chunks: []const manifest.ChunkEntry, id: u32) ?*const manifest.ChunkEntry {
    for (chunks) |*chunk| {
        if (chunk.id == id) return chunk;
    }
    return null;
}
