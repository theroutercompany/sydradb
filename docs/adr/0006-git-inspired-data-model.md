# ADR 0006: Git-Inspired Storage Model for SydraDB

## Status
Proposed

## Context
- SydraDB currently relies on WAL segments and columnar time-series segments without a first-class versioned metadata model.
- We plan to support advanced retention, branching, and replay scenarios reminiscent of DVCS workflows (branching, commits, diffs).
- The allocator roadmap (#61) will introduce shard-local arenas that can benefit from an object-store style layout.

## Goals
- Provide a content-addressable object graph for series metadata, schemas, and compaction manifests.
- Enable lightweight branching/checkpoint semantics for WAL replay and experimentation.
- Integrate with forthcoming custom allocator features (per-shard arenas, append-only segments).

## Proposed Architecture
### Object Types
1. Blobs: immutable payloads for segment manifests, tag dictionaries, WAL bundle summaries. Stored as `[type-prefix | hash | payload]`.
2. Trees: directory-like objects mapping logical paths (`series/<series-id>/segment/<segment-id>`) to blob or tree hashes.
3. Commits: point-in-time snapshots referencing a root tree, parent commit hashes, metadata (`timestamp`, `author`, `message`, optional `branch`).
4. Refs: named pointers (`main`, `snapshots/<date>`) resolved lazily; stored as plain text files within ref namespace for quick updates.

### Storage Layout
- Content-addressable store under `data/object/<first-two-bytes>/<full-hash>.obj`.
- Separate ref namespace `data/refs/*` mimicking Git's `refs/heads`, `refs/tags`.
- Object serialization uses Zig-friendly framing (length-prefixed sections) to avoid zlib; compression delegated to codec layer.

### WAL Integration
- WAL append produces objects:
  * `wal/chunk/<sequence>` blob describing offsets and checksums.
  * `wal/index/<sequence>` tree linking to chunk blobs.
- Periodic checkpoints create commits referencing latest segment manifests + WAL index.
- Replay uses refs to locate appropriate commit, then streams WAL chunks in hash order.

### Compaction & Segments
- Compaction outputs a blob per segment (metadata + column stats).
- Tree entries track per-rollup segments; commit update becomes atomic rename (`old-hash` replaced with `new-hash`).
- Segment GC implemented via reachability from current refs (mark-sweep).

### Allocator Tie-in
- Shard-local arenas allocate temporary nodes when building trees before flushing to object store.
- Append-only blob creation leverages new bump allocators; cross-shard references remain content-addressed.
- Deferred reclamation aligns with commit rollbacks by discarding unreferenced arenas.

## Migration Plan
1. Implement object store primitives (hashing, storage paths, blob encoding).
2. Introduce commit writer in compaction pipeline; maintain `refs/heads/main`.
3. Update WAL replay to resolve commit graph before reading segments.
4. Add reachability-based GC CLI command.

## Open Questions
- Hash algorithm: choose between BLAKE3 (fast, 32 bytes) vs SHA-256 (interoperability). Leaning BLAKE3.
- Security considerations for user-provided blobs; need validation.
- Multi-node coordination: eventual replication strategy for refs and objects.
- Exposure via API? Possibly `GET /debug/objects/<hash>` for diagnostics.

## Options Considered
1. Stick with current manifest files (status quo): simpler but no branching, more manual GC.
2. Leverage existing git repository: operationally heavy, requires external tooling, not Zig-native.
3. Adopt content-addressable object store (chosen): fits allocator roadmap, extensible for branching.

## References
- Issue #61 (Allocator), upcoming data-model issue (to be opened).
- Git internal docs as inspiration: commits, trees, blobs, refs.
