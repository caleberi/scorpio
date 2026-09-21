# How both parsers operate

Example config used in the diagrams:

```zig
const Db = struct { url: []const u8, timeout: i32 = 30 };
const Config = struct {
    name: []const u8,
    db: *Db,
};
// Env: NAME=scorpio, DB_URL=postgres://..., DB_TIMEOUT=60
```

---

## Side-by-side overview

```mermaid
flowchart LR
  subgraph GIST["Gist: recursive DFS"]
    direction TB
    G0["parse(Config, prefix=null)"] --> G1["create Config"]
    G1 --> G2["field name → leaf"]
    G2 --> G3["field db → *Db"]
    G3 --> G4["alloc nested_prefix = 'db'"]
    G4 --> G5["parse(Db, prefix='db')"]
    G5 --> G6["create Db + fill leaves"]
    G6 --> G7["return *Config"]
  end

  subgraph FP["FieldPlan: comptime plan + 2 passes"]
    direction TB
    F0["comptime FieldPlan(Config)"] --> F1["allocs: [db]<br/>leaves: [name, db_url, db_timeout]"]
    F1 --> F2["Pass 1: create nested *Db"]
    F2 --> F3["Pass 2: fill every leaf via path"]
    F3 --> F4["return *Config"]
  end

  ENV["EnvMap"] --> GIST
  ENV --> FP
```

---

## Gist — recursive field walk

At runtime, each struct level walks its fields. Nested `*Struct` fields recurse with a newly allocated prefix string.

```mermaid
flowchart TD
  START(["parse(T, prefix, env)"]) --> CREATE["allocator.create(T)"]
  CREATE --> LOOP{"next field"}

  LOOP -->|done| RET(["return *T"])
  LOOP -->|field| KIND{"field type?"}

  KIND -->|"*NestedStruct"| NP["makePrefixedKey(prefix, field.name)<br/>runtime alloc"]
  NP --> REC["parse(Nested, nested_prefix, env)"]
  REC --> STORE_N["store child pointer on parent"]
  STORE_N --> LOOP

  KIND -->|leaf| KEY["makePrefixedKey(prefix, field.name)<br/>+ uppercase"]
  KEY --> GET{"env.get(KEY)?"}
  GET -->|yes| CONV["convertValue → write field"]
  GET -->|no, has default| DEF["duplicate default → write field"]
  GET -->|no, optional| OPT["write null"]
  GET -->|no, required| ERR(["MissingRequiredField"])
  CONV --> LOOP
  DEF --> LOOP
  OPT --> LOOP

  style NP fill:#f6d6a8,stroke:#a65c00
  style REC fill:#f6d6a8,stroke:#a65c00
```

### Call tree for `Config`

```mermaid
sequenceDiagram
  participant P as parse(Config, null)
  participant E as EnvMap
  participant C as parse(Db, "db")

  P->>P: create Config
  P->>E: get("NAME")
  E-->>P: "scorpio"
  P->>P: name = dupe("scorpio")
  P->>P: nested_prefix = "db"  (heap)
  P->>C: parse(Db, "db")
  C->>C: create Db
  C->>E: get("DB_URL")
  E-->>C: "postgres://..."
  C->>E: get("DB_TIMEOUT")
  E-->>C: "60"
  C-->>P: *Db
  P-->>P: return *Config
```

**Cost drivers:** one recursive call + one prefix allocation per nesting level; leaf key work repeats the same pattern at every depth.

---

## FieldPlan — comptime plan, flat runtime

### Phase A — compile time

Walk `T` once into two static tables. Keys like `db_url` are joined at comptime (no heap).

```mermaid
flowchart TD
  T["comptime T = Config"] --> WALK["inline walk struct fields"]
  WALK --> LEAVES["leaves[]<br/>{path:[name], key:name}<br/>{path:[db,url], key:db_url}<br/>{path:[db,timeout], key:db_timeout}"]
  WALK --> ALLOCS["allocs[]<br/>{path:[db]}"]
  LEAVES --> PLAN["FieldPlan(T)<br/>static leaves + allocs"]
  ALLOCS --> PLAN
```

### Phase B — runtime (two passes)

```mermaid
flowchart TD
  START(["parse(T, prefix, env)"]) --> PLAN["Plan = FieldPlan(T)"]
  PLAN --> ROOT["allocator.create(T)"]

  ROOT --> P1["Pass 1: for each alloc site"]
  P1 --> A1["nestedPtr(parent path)<br/>create(Child)<br/>attach pointer"]
  A1 --> P1
  P1 -->|done| P2["Pass 2: for each leaf"]

  P2 --> L1["makePrefixedKey(prefix, leaf.key)<br/>+ uppercase"]
  L1 --> L2["leafPtr(root, leaf.path)"]
  L2 --> GET{"env.get(KEY)?"}
  GET -->|yes| CONV["convertValue → dest.*"]
  GET -->|default| DEF["duplicate default → dest.*"]
  GET -->|optional| OPT["dest.* = null"]
  GET -->|missing| ERR(["MissingRequiredField"])
  CONV --> P2
  DEF --> P2
  OPT --> P2
  P2 -->|done| RET(["return *T"])

  style P1 fill:#b8e0c8,stroke:#1b6b3a
  style P2 fill:#b8d4e8,stroke:#1a4f7a
```

### Passes for `Config`

```mermaid
sequenceDiagram
  participant CT as comptime FieldPlan
  participant R as parse runtime
  participant E as EnvMap

  Note over CT: leaves = [name, db_url, db_timeout]<br/>allocs = [db]

  R->>R: create Config
  Note over R: Pass 1 — alloc sites
  R->>R: create Db → config.db

  Note over R: Pass 2 — leaves
  R->>E: get("NAME")
  E-->>R: "scorpio"
  R->>R: leafPtr([name]).* = ...
  R->>E: get("DB_URL")
  E-->>R: "postgres://..."
  R->>R: leafPtr([db,url]).* = ...
  R->>E: get("DB_TIMEOUT")
  E-->>R: "60"
  R->>R: leafPtr([db,timeout]).* = ...
  R-->>R: return *Config
```

**Cost drivers:** nested prefixes are free (comptime); nested structs are allocated in one flat pass; leaf fills walk paths with `leafPtr` (small constant overhead on flat configs).

---

## Where the time goes

```mermaid
flowchart LR
  subgraph SAME["Same work (both)"]
    S1["uppercase key"]
    S2["EnvMap.get"]
    S3["convert / dupe string"]
  end

  subgraph GONLY["Gist only — grows with nesting"]
    G1["runtime nested_prefix alloc"]
    G2["recursive parse call per *Struct"]
    G3["per-level initialized[] bookkeeping"]
  end

  subgraph FPONLY["FieldPlan only"]
    F1["comptime path/key tables"]
    F2["leafPtr / nestedPtr walks"]
  end
```

| | Gist | FieldPlan |
|---|---|---|
| Struct discovery | runtime `inline for` per level | comptime `FieldPlan` tables |
| Nested `*Struct` | recurse + alloc prefix | Pass 1 create only |
| Leaf keys | `prefix_field` at each depth | comptime `db_url`, optional runtime app prefix |
| Flat configs | same leaf work | same leaf work + path indirection |
| Nested configs | extra allocs + recursion | fewer allocs → faster in bench |
