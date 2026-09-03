---
title: 'Hercules #2 — The master and the namespace'
summary: 'How Hercules keeps the file tree, hands out chunk handles, and persists metadata without a real operation log'
authors:
  - 'Adewole Caleb'
date: '2026-09-04'
topics:
  - 'Distributed Systems'
  - 'Golang'
  - 'GFS'
  - 'Metadata'
type: 'Blog'
image: '![image](../../../../blobs/replication-and-versioning.jpeg)'
highlight: coral
---

> Part 2. Previous: [chunks and the GFS idea](/posts/blog/projects/hercules/chunks-and-architecture). Series [intro](/posts/blog/projects/hercules-distributed-filesystem).

The master is the catalogue. If it lies, the cluster becomes a pile of anonymous `chunk-*.chk` files.

`MasterServer` itself is small. Most of the interesting state lives in two helpers.

```go
type MasterServer struct {
    listener           net.Listener
    rootDir            *filesystem.FileSystem
    namespaceManager   *namespacemanager.NamespaceManager
    chunkServerManager *ChunkServerManager
    detector           *detector.FailureDetector
    shutdownChan       chan os.Signal
    ServerAddr         common.ServerAddr
    sync.RWMutex
    isDead bool
}
```

`namespaceManager` knows paths. `chunkServerManager` knows handles, replicas, and leases. `rootDir` is just a local folder for `master.server.meta`. The detector is the φ stuff, which does not decide life or death today — more on that in [part 5](/posts/blog/projects/hercules/replication-and-failure).

Two maps, one process. That is the whole trick.

## The tree

A node in the namespace is `NsTree`:

```go
type NsTree struct {
    childrenNodes map[string]*NsTree
    Path          common.Path
    Length        int64
    Chunks        int64
    sync.RWMutex
    IsDir         bool
}
```

Directories have children keyed by basename. Files have `Length` and `Chunks`. The root is a fake node with `Path: "*"`.

Walking a path is `lockParents`. Split on `/`, take read locks on ancestors, take a write lock on the parent you are about to change. Nothing fancy. It is a tree with mutexes, not a distributed lock service.

`Create` is idempotent. `MkDir` is idempotent. `MkDirAll` walks components the way you would expect, except it skips creating a last segment that looks like a filename with an extension. That last bit is a bit cute. It exists because the client often asks for `/a/b/c.txt` and I did not want `c.txt` to become a directory by accident.

## Soft delete

Delete does not remove the node.

It renames it in the parent's map to `___deleted__` plus the original name, and drops the path into a `deleteCache`. Listing filters those keys so you do not see ghosts. A background worker, started with a 10 hour interval from the master constructor, later removes the tombstone for real.

```go
const DeletedNamespaceFilePrefix = "___deleted__"
```

Why the delay? Same reason trash folders exist. A mistaken delete should not instantly make the namespace forget the file existed. Chunk data is a separate decision. `RPCDeleteFileHandler` can also mark the handles as garbage so chunkservers delete the `.chk` files. Namespace delete and byte delete are not the same switch.

## The other map

`ChunkServerManager` is where handles live.

```go
type fileInfo struct {
    handles []common.ChunkHandle
}

type chunkInfo struct {
    expire    time.Time
    primary   common.ServerAddr
    checksum  common.Checksum
    path      common.Path
    locations []common.ServerAddr
    length    common.Offset
    version   common.ChunkVersion
}
```

A file path maps to an ordered slice of handles. A handle maps to locations, a primary, a lease expiry, a version.

These two worlds can drift. The tree says a file has 4 chunks. The manager might only know 3 handles if something failed mid-allocation. Heartbeats try to repair that by looking at what chunkservers report and calling `UpdateFileMetadata`. I am not going to pretend this is the cleanest part of the code. It is the part I still review.

## Files do not get chunks at create time

`RPCCreateFileHandler` only touches the namespace.

```go
func (ma *MasterServer) RPCCreateFileHandler(args rpc_struct.CreateFileArgs,
    reply *rpc_struct.CreateFileReply) error {
    return ma.namespaceManager.Create(args.Path)
}
```

Chunks appear when someone asks for a handle. `RPCGetChunkHandleHandler` looks at the requested index. If it equals the current chunk count, we are appending a new chunk. Then we pick servers and call `createChunk`.

```go
if args.Index == common.ChunkIndex(file.Chunks) {
    addrs, err := ma.chunkServerManager.chooseServers(common.MinimumReplicationFactor + 1)
    reply.Handle, addrs, err = ma.chunkServerManager.createChunk(args.Path, addrs)
    file.Chunks++
    ma.chunkServerManager.addChunk(addrs, reply.Handle)
}
```

`chooseServers(MinimumReplicationFactor + 1)` means we try to place on 4 machines even though the minimum replica count is 3. Extra room for a failure during create. Servers are sorted by `RoundTripProximityTime` first, then sampled. I wanted closer machines to be preferred. Whether that ping is a good distance signal in Docker is a fair question.

`createChunk` assigns the next integer handle and RPCs `CRPCCreateChunkHandler` to each chosen server so they touch an empty `chunk-{handle}.chk` on disk.

## Persistence is a snapshot, not a log

GFS masters write an operation log and take checkpoints. Hercules writes a GOB file.

```go
type PesistentMeta struct {
    Namespace []namespacemanager.SerializedNsTreeNode
    ChunkInfo []serialChunkInfo
}
```

Every 15 hours, and again on shutdown, `persistMetaData` serializes the tree and a slim view of chunks (handle, version, checksum, length, path). Not replica locations. Not who holds the lease. Not the live server set.

On boot, `loadMetadata` decodes that file. If GOB is corrupt, the file is renamed to `master.server.meta.corrupt.<unix>` and we start empty. Chunkservers then heartbeat in, report their inventory, and the master rebuilds locations from that.

That is a deliberate shortcut. A crash in the 15 hour window can lose in-memory namespace updates that never hit disk, unless you shut down cleanly. I know. It is on the review list. A real ops log is the obvious next step if this ever needs to be more than a study project.

## What the master is doing in the background

`NewMasterServer` starts a ticker loop:

| Interval | Work |
| --- | --- |
| 10s | `serverHeartBeat` — find dead servers, probe live ones, drain re-replication |
| 15h | persist metadata |
| 10s | `detector.Predict` — log a φ suspicion, do not kill anyone |

Dead, for the purpose of actually removing a server, is "no heartbeat for 60 seconds". Simple. The fancy detector is a side channel.

When a server is removed, its chunks are subtracted from `locations`. If a handle drops below 3 replicas, it goes on `replicaMigration`. That queue is how copies get made again. [Part 5](/posts/blog/projects/hercules/replication-and-failure) walks the copy.

## The RPCs that matter

These are the ones the client actually uses:

| Handler | Job |
| --- | --- |
| `RPCCreateFileHandler` | namespace create |
| `RPCGetChunkHandleHandler` | allocate or look up a handle |
| `RPCGetPrimaryAndSecondaryServersInfoHandler` | grant / return a lease |
| `RPCGetReplicasHandler` | replica list for reads |
| `RPCGetFileInfoHandler` | length, chunk count, isDir |
| `RPCUpdateFileMetadataHandler` | client telling us the file grew |
| `RPCHeartBeatHandler` | chunkservers checking in |
| `RPCListHandler` / `RPCMkdirHandler` / `RPCRenameHandler` / `RPCDeleteFileHandler` | tree edits |

If you only remember one thing from this post: creating a file and creating a chunk are different moments. The master is lazy on purpose. No point reserving 64MB on three disks for a file nobody wrote to.

Next: [writes, leases, and the download buffer](/posts/blog/projects/hercules/writes-leases-and-the-buffer).
