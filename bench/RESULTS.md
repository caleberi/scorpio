# Env parse benchmark: gist vs FieldPlan

Compares the recursive `EnvironmentParser` core from
[gist eaa188cd…](https://gist.github.com/caleberi/eaa188cd290a61e211b5157e98114691)
against the FieldPlan rewrite (comptime leaf/alloc plan + two flat runtime passes).

## Method

- Zig **0.15.2**, `-OReleaseFast`
- Fair parse-only path: both take a prebuilt `std.process.EnvMap`
  (file load / `${VAR}` regex from the gist are excluded)
- Workload: `parse` + `deinit`, 50 000 iterations/case after 10% warmup
- Metrics: wall ns/op, heap allocs/op, bytes allocated/op
- Correctness: parity tests for flat and nested configs (`zig build test`)

Run:

```bash
cd bench
zig build test --release=fast
zig build run --release=fast
```

## Results (x86_64 Linux)

| Case | gist ns/op | FieldPlan ns/op | Speedup | gist allocs | FieldPlan allocs |
|------|-----------:|----------------:|--------:|------------:|-----------------:|
| flat | 64 863 | 65 384 | **0.99×** | 13 | 13 |
| nested | 110 024 | 62 046 | **1.77×** | 35 | 23 |
| deep-nested | 142 791 | 100 860 | **1.42×** | 44 | 24 |
| wide-flat | 207 830 | 228 435 | **0.91×** | 51 | 51 |
| flat+prefix | 135 488 | 140 139 | **0.97×** | 23 | 23 |

Raw console capture: `RESULTS.txt`.

## Takeaways

1. **Nested configs are where FieldPlan wins.** Recursive prefix string
   building and per-level container recursion in the gist cost both time
   and allocations. FieldPlan builds keys at comptime and allocates nested
   structs in one flat pass → **~1.4–1.8× faster**, **~1.5–1.8× fewer allocs**,
   and much lower bytes/op (nested: 1014 B → 282 B; deep: 1512 B → 322 B).

2. **Flat configs are a wash (or slightly slower).** With no nesting, both
   implementations do the same per-field key alloc / uppercase / EnvMap get /
   convert work. FieldPlan’s path indirection (`leafPtr`) adds a small
   constant overhead (~1–9% slower on flat/wide).

3. **Allocation count only diverges with nesting.** Flat and wide show
   identical allocs/op; nested savings come from dropping recursive
   `nested_prefix` allocations and redundant per-level bookkeeping.

## Files

| File | Role |
|------|------|
| `src/gist_env.zig` | Recursive gist parse core |
| `src/fieldplan_env.zig` | FieldPlan rewrite |
| `src/main.zig` | Harness + parity tests |
