---
title: 'Lessons From Building A Distributed File System'
summary: 'A field report from building Hercules — a Go implementation of the Google File System design. Master–chunkserver architecture, 64 MB chunks, lease-based mutations, and the bugs that came with turning a paper into running code.'
authors:
  - 'Caleb Erioluwa Adewole'
date: '2026-09-15'
topics:
  - 'Distributed Systems'
  - 'Golang'
  - 'GFS'
  - 'Talks'
fps: 30
size: 1920x1080
background: '#0a0d14'
color: '#eef1f7'
font: 'Bricolage Grotesque, Inter, system-ui, sans-serif'
image: '![image](../../../../blobs/cover53.webp)'
---

Gophers Nigeria Meetup talk notes. The original HTML deck (theme toggle, live GitHub snippet tabs, φ slider, protocol click-animations) is flattened here: tagged `slide` blocks compile this README into a canvas deck.

Source: [github.com/caleberi/hercules-dfs](https://github.com/caleberi/hercules-dfs).

<slide id="title" duration="8s" transition="fade" color="#eef1f7">
# Lessons From Building A Distributed File System {color="#f6c244"}

A field report from building Hercules — a Go implementation of the Google File System design. Master–chunkserver architecture, 64 MB chunks, lease-based mutations, an HTTP gateway, and every bug that came with turning a research paper into running code.

Speaker: **Caleb Erioluwa Adewole** · Distributed Systems · Go · Gophers Nigeria Meetup

- GFS-inspired architecture
- Go · net/rpc over TCP
- φ Accrual failure detection
- Lease-based writes

![Hercules in action](https://github.com/user-attachments/assets/faf3553a-ace8-402b-8e81-9515685d9ad6){kind="video" id="hero"}

[github.com/caleberi/hercules-dfs](https://github.com/caleberi/hercules-dfs)

<animate target="title" from="0ms" to="800ms" ease="cubic-out">
  <keyframe at="0%" translate="0,40" scale="0.9" rotate="0" opacity="0"/>
  <keyframe at="100%" translate="0,0" scale="1" rotate="0" opacity="1"/>
</animate>
</slide>

<slide id="roadmap" duration="6s" transition="fade">
# How this talk is laid out

Ten stops: the paper, the reading method, the language choice, the two server types, locking, failure detection, integrity, the SDK, then the wrap-up.

1. The paper
2. Reading the paper
3. Why Go?
4. Master server
5. Chunk server
6. Locking and leasing
7. Failure detection
8. Data integrity
9. Client SDK
10. Field notes, summary, closing
</slide>

<slide id="the-paper" duration="8s">
# The paper: The Google File System

Ghemawat, Gobioff & Leung · SOSP 2003. GFS was built for Google's own workloads: huge files, mostly-append writes, commodity hardware that fails routinely, and a small number of large streaming reads rather than millions of small random ones.

Its central bet: push complexity into a single logical master for metadata, and keep chunkservers dumb, replicated, and easy to replace. Failure is treated as the normal case, not the exception.

What Hercules borrows:

- Single master, many chunkservers
- Large fixed-size chunks (64 MB)
- Lease-based mutation ordering
- Heartbeats as the source of liveness truth
- Relaxed consistency, strong enough for its workload

Hercules isn't a port — it's a from-scratch Go reimplementation of the paper's ideas, built to actually run. Local paper figures from the original talk are omitted here so missing images cannot fail pack.
</slide>

<slide id="reading-the-paper" duration="8s">
# Breaking it down with Keshav's three-pass method

Before writing a line of Go, I read GFS the way S. Keshav's *How to Read a Paper* recommends — three passes, each going deeper than the last.

1. **Get the gist (5–10 min).** Title, abstract, section headings, conclusions. For GFS: yes — a production filesystem design, published with real operational numbers.
2. **Grasp the content (~1 hour).** Read in order, note figures, skip proofs. This is where the master/chunkserver split, the lease protocol, and the relaxed consistency model became clear.
3. **Re-implement it.** Hercules *is* this pass — every gap between my first instinct and the paper's actual design became a design decision I had to make consciously.

GFS is dense with implied detail. Pass three is where version numbers, stale-replica handling, and lease renewal races surface. None of that is optional once you're writing Go instead of reading English.
</slide>

<slide id="why-go" duration="6s">
# Why Golang?

**Simplicity.** A small language surface means the code reads like the paper's own pseudocode.

**Concurrency semantics.** GFS is concurrent actors — a master juggling heartbeats, leases and replication, chunkservers serving reads while accepting writes. Goroutines + channels + `sync.RWMutex` map onto that shape.

**Batteries included.** `net/rpc`, `encoding/gob`, `crypto/sha256`, and `math` (for the φ Accrual CDF) come from the standard library.

Only two direct third-party dependencies: Gin for the HTTP gateway, and a Redis client for the failure detector's sample window.
</slide>

<slide id="master-server" duration="8s">
# Master server: five jobs, one process

The original talk had live GitHub tabs for each handler. Flattened here to the five jobs and what the master actually owns.

- Metadata persistence (`master_server/master_server.go`)
- Garbage collection (`master_server/cs_manager.go`)
- Namespace management (`namespace_manager/nsmanager.go`)
- Chunk placement (`master_server/cs_manager.go`)
- Heartbeat handling (`master_server/master_server.go`)

What the master owns:

- The namespace tree — every path, file and directory
- The chunk map — handle → replica locations
- Leases — who is allowed to write, and until when
- Liveness — who's still heartbeating

It never touches file bytes. Every card here is metadata work, not data work.
</slide>

<slide id="chunk-server" duration="8s">
# Chunk server: dumb storage, done well

Chunkservers are intentionally simple: talk to the master, talk to the local filesystem, apply what you're told.

- Communication to master — heartbeats, lease extensions, garbage
- POSIX-style file writes into `chunk-{handle}.chk`
- Atomic record appends from a download buffer
- Snapshotting for replication (copy bytes, then apply on the target)

What a chunkserver owns:

- The actual bytes, as local files
- Its own liveness reporting to the master
- Applying mutations in the order the primary assigns
- Serving reads directly — the master is never in this path
</slide>

<slide id="locking-and-leasing" duration="8s">
# Two kinds of locking, one correctness story

Namespace locking keeps directory operations safe; leases keep chunk writes ordered without a distributed lock.

- **Namespace locks** — per-directory RW locks, acquired root-to-leaf, so two clients can create files in different directories without blocking each other.
- **Chunk leases** — a 120 s write monopoly granted to one chunkserver per chunk. Not a mutex; a time-bounded authority the master hands out.

The lease is what makes GFS's relaxed consistency model safe: as long as only the lease holder serializes writes, replicas can apply mutations in the same order without a distributed lock.
</slide>

<slide id="failure-detection" duration="8s">
# Failure detection: soft suspicion, hard decisions

φ Accrual turns "missed heartbeat" into a continuous suspicion score instead of a binary flag; a plain 60 s timeout still makes the actual removal decision.

```
φ = -log10(1 - F(z))
z = (t - μ) / σ
```

The original talk had an interactive φ slider. That widget is out of scope for this canvas player — diagrams here are static.

φ is advisory — it's logged, not acted on directly. The hard timeout (60 s of silence) is what actually removes a server and triggers re-replication.

Reference: Hayashibara et al., *φ Accrual Failure Detection*; Arpit Bhayani's write-up of the same formula.
</slide>

<slide id="data-integrity" duration="8s">
# Checksums and versioning: two different failure modes

One catches corruption at rest; the other catches replicas that quietly fell behind.

- **Checksums** catch silent corruption — whole-chunk SHA-256, recomputed lazily so a busy chunk isn't rehashed on every write.
- **Versioning** catches staleness — a replica that missed a mutation reports a lower version and gets flagged before it's trusted again.

Neither one fixes the other's problem. A checksum can't tell you a replica is merely *behind*; a version number can't tell you a byte flipped on disk.
</slide>

<slide id="client-sdk" duration="8s">
# Building an SDK wrapper worth using

A native Go client that turns paths and byte offsets into chunk handles, leases and RPC calls — so callers never see the plumbing.

The surface the client exposes:

- `MkDir` · `CreateFile` · `List`
- `Read` · `Write` · `Append`
- `RenameFile` · `DeleteFile` · `GetFile`

Leases are cached on the client and refreshed from the master when expired. The public API reads like a POSIX-ish filesystem client. Underneath, every call is chunk math, lease negotiation, and RPC retries.
</slide>

<slide id="field-notes" duration="8s">
# Bugs, reversals, and "why did I think that would work"

The paper describes the shape of the system. Git history is where the real questions showed up.

- **Dedup race.** A deposit-path check ran outside the primary's lock. Fix: serialize on the lease holder. Still open: GFS serial numbers never landed.
- **Leases looked optional.** Early versions let any replica accept a write. Fix: 120 s lease, one primary. Still open: docs still say 60 s; no explicit revoke.
- **Checksums that verified nothing.** Re-replication compared checksums after the copy was already accepted. Fix: check version, length and checksum *before* `registerReplicas`.
- **φ is advisory.** Suspicion stays a log line. The 60 s heartbeat timeout is what removes a server.
</slide>

<slide id="summary" duration="8s">
# What building Hercules actually taught me

1. **Read in three passes.** The third pass — re-implementing — is where a paper's real assumptions surface.
2. **Go's simplicity is a feature for systems code.** Fewer abstractions between the design and the implementation.
3. **Separate control from data, always.** The master answers "where," chunkservers answer "what."
4. **Leases aren't locks — they're time-bounded authority.**
5. **Suspicion and decision are different jobs.** φ Accrual estimates; a timeout decides.
6. **Integrity needs two checks, not one.** Checksums catch corruption; versions catch staleness.
7. **A good SDK is a translation layer.**
</slide>

<slide id="closing" duration="6s" transition="fade">
# Everything you saw is in the repo

Clone it, break it, read the tests, or open an issue: [github.com/caleberi/hercules-dfs](https://github.com/caleberi/hercules-dfs)

- Ghemawat et al., *The Google File System* (2003)
- Hayashibara et al., *φ Accrual Failure Detection*
- Keshav, *How to Read a Paper*
- `master_server/` · `chunkserver/` · `detector/`
- `namespace_manager/` · `hercules/` · `gateway/`
- `common/constants.go` · `shared/rpc.go`

Caleb Erioluwa Adewole · Gophers Nigeria Meetup
</slide>
