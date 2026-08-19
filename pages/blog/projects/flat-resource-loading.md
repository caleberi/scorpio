---
title: 'Flat Resource Loading Using ArrayList'
summary: 'Loading directories and file resources from a flat array of descriptors using ArrayList'
authors:
  - 'Adewole Caleb'
date: '2026-08-17'
topics:
  - 'Zig'
  - 'Engineering'
  - 'ArrayList'
type: 'Blog'
image: '![image](../../../blobs/cover8.webp)'
---

Thinking about how to load files and directory in a fast and efficient way is probably alway one dimensional. So what I mean by one dimenisonal is that the people approach this by just walking through a directory and then picking out the files and directories they want.

What if we could load a limited amount of file and directoryinformation and also their path location instead at once and probably load the rest of the information later on when we need it?

Something like an in-memory index of files and directories that we can use to quickly and efficiently load the files and directories we need. Don't get me wrong, this is just me working through my thoughts how to improve the speed of accessing resources in directories.

Why this thinking ? Well, I was working on a project that required me to load a lot of files and directories and I was like, "Why not use a flat array of descriptors to load the files and directories I need?"

Let's try something simple, I won't be adding the file descriptor but I sticking with path, folder index, file index, modified at, created at, size, etc. Limited infomration so we don't overwhelm the memory. I have thoughts about prefetching but I don't know how to do it yet. 

```zig
const File = struct {
    path: []const u8,
    folder_index: usize,
    file_index: usize,
    modified_at: i128,
    created_at: i128,
    size: u64,

    pub fn name(self: File) []const u8 {
        return fs.path.basename(self.path);
    }
};
```

Representing Folder in a similar way but with more information on file indices and child folder indices.

```zig

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

```
By having the parent index, we can move up and down the directory tree easily.Similarly for files we can get folder index and locate it easily.

## Building A Directory Tree

Mirroring a minimal flat array representation of a directory tree requires having a couple of arraylist to track folders and files and an hashmap to files to folder and folder to files via their paths.

```zig
const Directory = struct {
    allocator: zstd.mem.Allocator,
    arena: zstd.heap.ArenaAllocator,

    root_path: []const u8,
    folders: []Folder,
    files: []File,

    folder_by_path: zstd.StringHashMap(usize),
    file_by_path: zstd.StringHashMap(usize),
};
```

Using an arena allocator to manage memory allocation of strings especially for paths seems like a reasonable choice. I have been used to using the general purpose allocator for strings but that leads to a lot of memory fragmentation and allocation overhead (I haven't confirmed this yet personally).


Creating a loading function is the next thing to do. We need to load the files and directories from the root path and then build the directory tree.

```zig
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
   
   ....
}

```

> Why are we using arena allocator here? We are trying to work with unknown amount of strings and it give use a way to manage memory allocation of strings efficiently without have to worry about freeing each allocted memory individally but as a collective.

After this we can initialize all folder & file indices arrays to empty and folder & file by path hashmaps to empty.

```zig

pub fn load(allocator: zstd.mem.Allocator, path: []const u8) !Directory {

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

    /// add the root folder first
    ...............
}

```

By using `errdefer` we can ensure that we free all allocated memory if the function fails.Just one of those facilities Zig provides use to make our lives easier. Something I wished Golang had.


In order to add the root folder, we need to append it to the folders array and add the file indices and child indices arrays to the folder_file_indices and folder_child_indices arrays respectively.

```zig
fn appendFolder(allocator: zstd.mem.Allocator, strings: zstd.mem.Allocator, folders: *zstd.ArrayList(Folder), folder_file_indices: *zstd.ArrayList(zstd.ArrayList(usize)), folder_child_indices: *zstd.ArrayList(zstd.ArrayList(usize)), folder_by_path: *zstd.StringHashMap(usize), path: []const u8, parent_index: ?usize, stat: fs.Stat) !usize {
    
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

```

Remember that we are using an arena allocator to manage memory allocation of strings so we need to dupe the path string to avoid memory leaks.
We create a similar function for appending files to the files array and adding the file index to the file_by_path hashmap.

```zig
fn appendFile(allocator: zstd.mem.Allocator, strings: zstd.mem.Allocator, files: *zstd.ArrayList(File), file_by_path: *zstd.StringHashMap(usize), path: []const u8, folder_index: usize, stat: fs.Stat) !usize {
    const path_owned = try strings.dupe(u8, path);

    const file_index = files.items.len;
    try files.append(allocator, .{
        .path = path_owned,
        .folder_index = folder_index,
        .modified_at = stat.mtime,
        .created_at = stat.ctime,
        .size = stat.size,
    });
    errdefer {
        var file = files.pop().?;
        file.deinit(allocator);
    }

    try file_by_path.put(path_owned, file_index);
    return file_index;
}

```

With this two function we can now walk through the directory and append the folders and files to the arrays and hashmaps.

```zig
pub fn load(allocator: zstd.mem.Allocator, path: []const u8) !Directory {
    // ....


    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
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
```

With this we can now load the directory and build the directory tree.Also we can locate files and directories by their paths easily in constant time. Building the directory tree is a O(n) operation where n is the number of files and directories in the directory.

It was a fun exercise to work through this and I learned a lot about how to work with directories and files in Zig. I hope you enjoyed reading this as much as I enjoyed writing it.








