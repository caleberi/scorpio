---
title: 'A comptime field plan parser in Zig'
summary: 'Parsing nested struct fields at compile time with a flat array of descriptors'
authors:
  - 'Adewole Caleb'
date: '2026-08-17'
topics:
  - 'Zig'
  - 'Engineering'
type: 'Blog'
image: '![image](../../../blobs/cover6.webp)'
---

Working on a parser for environment variables in Zig was tricky because I needed to walk the fields of a struct at comptime. Comptime is a different world from runtime: you cannot call runtime functions or touch runtime variables there. You have to think the way the compiler prepares types.

The awkward part of an environment parser is that values arrive at runtime, while the types those values must inhabit are known at compile time. My first idea was a comptime struct that stored every field, then recursively parsed environment variables from that. That is not a great fit. You pay a lot of memory to hold the field list without a known size, which runs against NASA's Power of 10 rule that you should not use dynamic memory allocation after initialization.

What I needed instead was a comptime field plan: walk the struct once at compile time and store the result in a flat array of descriptors whose length is known before any runtime work begins.

Take a struct like this:

```zig
struct {
    foo: i32,
    bar: *struct {
        baz: i32,
    },
}
```

The plan flattens it into leaf sites and allocation sites:

```zig
// leaves
[{ .path = &.{"foo"}, .key = "foo" }, { .path = &.{ "bar", "baz" }, .key = "bar_baz" }]

// allocs
[{ .path = &.{"bar"} }]
```

`path` is the walk through nested field names. `key` is those names joined with underscores. At runtime the parser uppercases the key (and an optional prefix) before looking it up in the environment. From that plan it can recover each field's type, allocate nested structs, and fill leaves.

To size the arrays we count leaf sites by walking the struct and treating every non-pointer field as a leaf. Nested `*struct` fields are descended into:

```zig
fn isNestedStructPtr(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .pointer or type_info.pointer.size != .one)
        return false;
    return @typeInfo(type_info.pointer.child) == .@"struct";
}

fn leafCount(comptime T: type) usize {
    var n: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isNestedStructPtr(field.type)) {
            n += leafCount(@typeInfo(field.type).pointer.child);
        } else {
            n += 1;
        }
    }
    return n;
}
```

Allocation sites are the nested pointers themselves. Each one is counted, then we recurse into the child struct in case it has more nested pointers:

```zig
fn allocSiteCount(comptime T: type) usize {
    var n: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isNestedStructPtr(field.type)) {
            n += 1 + allocSiteCount(@typeInfo(field.type).pointer.child);
        }
    }
    return n;
}
```

The path has to travel with us, otherwise the plan cannot tell the binder how to construct the struct. Two small descriptors are enough:

```zig
const LeafDesc = struct {
    path: []const []const u8, // walk through the struct
    key: []const u8, // environment variable name
};

const AllocDesc = struct {
    path: []const []const u8,
};
```

`FieldPlan` then materializes two fixed-size arrays at comptime. Their lengths come from the counts above, so nothing here is dynamically sized:

```zig
fn FieldPlan(comptime T: type) type {
    const n_leaves = leafCount(T);
    const n_allocs = allocSiteCount(T);

    const leaf_buffer = blk: {
        var buf: [n_leaves]LeafDesc = undefined;
        _ = appendLeaves(T, &.{}, "", &buf, 0);
        break :blk buf;
    };

    const alloc_buffer = blk: {
        var buf: [n_allocs]AllocDesc = undefined;
        _ = appendAllocSites(T, &.{}, &buf, 0);
        break :blk buf;
    };

    return struct {
        pub const leaves: [n_leaves]LeafDesc = leaf_buffer;
        pub const allocs: [n_allocs]AllocDesc = alloc_buffer;
    };
}
```

Filling the leaf array is a recursive walk. Nested structs keep the parent path and a joined key prefix; actual leaves write a descriptor and move on:

```zig
fn appendLeaves(
    comptime T: type,
    comptime path_prefix: []const []const u8,
    comptime key_prefix: []const u8,
    comptime out: []LeafDesc,
    comptime start: usize,
) usize {
    var i: usize = start;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const field_path = path_prefix ++ &[_][]const u8{field.name};
        const field_key = joinKey(key_prefix, field.name);
        if (comptime isNestedStructPtr(field.type)) {
            i = appendLeaves(
                @typeInfo(field.type).pointer.child,
                field_path,
                field_key,
                out,
                i,
            );
        } else {
            out[i] = .{
                .path = field_path,
                .key = field_key,
            };
            i += 1;
        }
    }
    return i;
}
```

Allocation sites do the same walk, but they record the nested pointer *before* recursing. That order matters: the runtime binder allocates parents first so children have somewhere to live.

```zig
fn appendAllocSites(
    comptime T: type,
    comptime path_prefix: []const []const u8,
    comptime out: []AllocDesc,
    comptime start: usize,
) usize {
    var i: usize = start;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isNestedStructPtr(field.type)) {
            const field_path = path_prefix ++ &[_][]const u8{field.name};
            out[i] = .{ .path = field_path };
            i += 1;
            i = appendAllocSites(
                @typeInfo(field.type).pointer.child,
                field_path,
                out,
                i,
            );
        }
    }
    return i;
}
```

At this point the plan is a compile-time constant. Binding is runtime work: `T` is comptime, but the allocator, optional prefix, and environment map are not.

```zig
pub fn parse(
    comptime T: type,
    allocator: zstd.mem.Allocator,
    prefix: ?[]const u8,
    env: zstd.process.Environ.Map,
) !*T {
    if (@typeInfo(T) != .@"struct")
        return ParseError.InvalidContainer;

    const Plan = FieldPlan(T);
    const container = try allocator.create(T);

    var nested_allocated: usize = 0;
    var leaves_initialized: usize = 0;
    errdefer freePartial(
        T,
        allocator,
        container,
        nested_allocated,
        leaves_initialized,
    );

    inline for (Plan.allocs) |site| {
        const parent = nestedPtr(T, container, site.path[0 .. site.path.len - 1]);
        const field_name = site.path[site.path.len - 1];
        const Child = ParentTypeAt(T, site.path);
        @field(parent.*, field_name) = try allocator.create(Child);
        nested_allocated += 1;
    }

    inline for (Plan.leaves, 0..) |leaf, leaf_idx| {
        const FieldType = LeafTypeAt(T, leaf.path);
        const env_key = try makePrefixedKey(allocator, prefix, leaf.key);
        defer allocator.free(env_key);

        var uppercase_key = try allocator.alloc(u8, env_key.len);
        defer allocator.free(uppercase_key);

        uppercase_key = zstd.ascii.upperString(uppercase_key, env_key);
        const key: []const u8 = uppercase_key[0..env_key.len];

        const dest = leafPtr(T, container, leaf.path);

        if (env.get(key)) |val| {
            dest.* = try convertValue(FieldType, allocator, val);
        } else if (comptime defaultForLeaf(T, leaf.path)) |default_ptr| {
            dest.* = try duplicateIfNeeded(FieldType, allocator, default_ptr.*);
        } else if (comptime isOptionalLeaf(FieldType)) {
            dest.* = null;
        } else {
            return ParseError.MissingRequiredField;
        }

        leaves_initialized = leaf_idx + 1;
    }

    return container;
}
```

If binding fails halfway through, `errdefer` runs `freePartial`, which only tears down the leaves and nested pointers that actually got created. A full `deinit` walks the same plan in reverse: free leaf-owned memory (strings, for example), destroy nested structs from the inside out, then destroy the root.

```zig
fn freePartial(
    comptime T: type,
    allocator: zstd.mem.Allocator,
    container: *T,
    nested_allocated: usize,
    leaves_initialized: usize,
) void {
    const Plan = FieldPlan(T);

    inline for (Plan.leaves, 0..) |leaf, i| {
        if (i < leaves_initialized) {
            freeLeaf(LeafTypeAt(T, leaf.path), allocator, leafPtr(T, container, leaf.path).*);
        }
    }

    comptime var a = Plan.allocs.len;
    inline while (a > 0) {
        a -= 1;
        if (a < nested_allocated) {
            const site = Plan.allocs[a];
            const parent = nestedPtr(T, container, site.path[0 .. site.path.len - 1]);
            allocator.destroy(@field(parent.*, site.path[site.path.len - 1]));
        }
    }

    allocator.destroy(container);
}

fn free(comptime T: type, allocator: zstd.mem.Allocator, container: *T) void {
    const Plan = FieldPlan(T);

    inline for (Plan.leaves) |leaf| {
        freeLeaf(LeafTypeAt(T, leaf.path), allocator, leafPtr(T, container, leaf.path).*);
    }

    comptime var a = Plan.allocs.len;
    inline while (a > 0) {
        a -= 1;
        const site = Plan.allocs[a];
        const parent_path = site.path[0 .. site.path.len - 1];
        const field_name = site.path[site.path.len - 1];
        const parent = nestedPtr(T, container, parent_path);
        const child_ptr = @field(parent.*, field_name);
        allocator.destroy(child_ptr);
    }

    allocator.destroy(container);
}

pub fn deinit(comptime T: type, allocator: zstd.mem.Allocator, container: *T) void {
    free(T, allocator, container);
}
```

That is the whole shape: a comptime-sized plan, a runtime binder that follows it, and cleanup that can stop at whatever point allocation reached. Nested structs still need a real allocator at runtime. The win is that the *shape* of that work is decided before `main` runs.


The recursive approach can be viewed here:
<script src="https://gist.github.com/caleberi/eaa188cd290a61e211b5157e98114691.js"></script>