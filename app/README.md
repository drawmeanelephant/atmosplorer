# Atmosplorer

SwiftUI desktop client over the [zat](../DEVKITS/zat-main) AT Protocol explorer
core, via the [zat-swift](../zat-swift) wrapper package.

This covers milestones 1–3 of the roadmap in `DEVKITS/zat-main/HANDOFF.md`:
a window that takes a handle, resolves it, lists its collections, and walks
its records — plus the offline cache (download a repo's CAR once, then browse
every record with zero network), and browseable content (posts, likes,
follows, and starter packs render as real content with human collection
labels instead of raw NSIDs). Local search and live sync build on top.

## Run

```sh
cd app
swift run Atmosplorer        # debug
swift build -c release       # release binary at .build/release/Atmosplorer
```

The app is a bare SPM executable (no `.app` bundle yet — that's a later
packaging milestone); `AtmosplorerApp.init` claims regular app activation so
the window appears normally.

## Layout

```
app/
├── Package.swift            # depends only on the local ../zat-swift package
├── Sources/
│   ├── ZatAppCore/          # testable, SwiftUI-free core
│   │   ├── AppSession.swift # async bridge over the blocking C-backed wrapper
│   │   ├── AppError.swift   # single user-facing error type + mapping
│   │   ├── RepoCache.swift  # offline CAR storage (one .car file per repo + index)
│   │   ├── OfflineRepo.swift# decoded CAR grouped into collections/records
│   │   ├── CollectionInfo.swift # human labels + icons for collection NSIDs
│   │   └── RecordContent.swift  # $type-aware record body extraction

│   └── Atmosplorer/         # the SwiftUI shell
│       ├── AtmosplorerApp.swift      # @main + activation
│       ├── RootModel.swift           # handle → identity → collections
│       ├── RootView.swift            # routes detail: live walk vs. cached browse
│       ├── SidebarView.swift         # entry, identity (+ download), collections, cached repos
│       ├── CacheModel.swift          # download flow + cached-repo library
│       ├── RecordsModel.swift        # paged listRecords walk (cursor chaining)
│       ├── RecordsView.swift         # live records list + load-more + navigation
│       ├── CachedRepoBrowserModel.swift # load CAR from disk, decode offline
│       ├── CachedRepoView.swift      # offline collections drill-down
│       ├── CachedRecordsView.swift   # offline records list (reuses live rows)
│       ├── RecordRow.swift           # collection-tinted icon + type-aware preview
│       ├── RecordContentView.swift   # body renderer switched on $type
│       ├── CollectionLabel.swift     # icon + label for a collection NSID
│       └── RecordDetailView.swift    # URI/CID + collapsible JSON tree
└── Tests/ZatAppCoreTests/   # offline: sessions, error mapping, cache round
                             # trips, offline browsing, content extraction
                             # (embedded fixture)
```

## Browseable content (milestone 3)

Collections and records now read as content, not raw JSON. Two building blocks
in `ZatAppCore`, both pure and fully testable:

- **`CollectionInfo`** maps known NSIDs to a human label (`app.bsky.feed.post`
  → "Posts", `app.bsky.graph.follow` → "Follows", …), an SF Symbol, and a
  color bucket. Unknown NSIDs fall back to a neutral "Records" row showing
  the raw identifier, so a new lexicon can't break the app.
- **`RecordContent`** parses a record body by `$type` into a `Kind` and a
  one-line `preview`. Posts carry their text, an external link card (title /
  uri / description / OGP thumbnail), a quoted-post ref, and image embeds
  (captions + aspect ratios); likes carry what was liked; follows who was
  followed; starter packs their name, description, and feeds. Unknown records
  fall back to a sensible preview.

`RecordContentView` renders the `Kind` in both list rows and the detail view,
and both the live sidebar and the offline collections list show each
collection's human label under a tinted icon (`CollectionLabel`), with the
raw NSID kept as a subtitle.
└── Tests/ZatAppCoreTests/   # offline: sessions, error mapping, cache round
                             # trips, offline browsing (embedded fixture)
```

## The two decisions milestone 1 forced

**Async.** `ZatExplorer` runs blocking C calls and is not thread-safe. The app
serializes by owning one explorer behind a dedicated serial `DispatchQueue`
per session and bridging with `withCheckedThrowingContinuation`
(`AppSession.run`). Blocking never happens on the main thread or the
cooperative pool; the explorer is only touched from its own queue, which is
what makes `AppSession`'s `@unchecked Sendable` sound.

**Errors.** The wrapper distinguishes "never reached the network"
(`ZatError`) from "server answered with an XRPC envelope" (`ZatXrpcError`).
The app collapses both into one `AppError` with a human-readable
`userMessage`, mapped in exactly one place (`AppError.from`). Views never
switch over raw wrapper errors. Local cache failures throw
`AppError.cache` so the same rule holds for disk I/O.

## Offline cache (milestone 2)

The bet of this app: a repo's CAR is self-contained (commit block + every
MST node + every record block), so one download buys permanent offline
browsing. The flow:

1. Resolve a handle → the identity summary gains **Download for offline**.
   The download opens a data session on the identity's PDS (sync endpoints
   like `com.atproto.sync.getRepo` live there, not on appviews), fetches the
   raw CAR, decodes it once for the record count, and saves it.
2. `RepoCache` writes `<did>.car` plus an `index.json` (DID → handle /
   cached-at / record-count) under
   `~/Library/Application Support/Atmosplorer/caches`. Listing reads only the
   index, so the sidebar shows the library instantly; timestamps are stored
   as `secondsSince1970` so "most recent first" ordering is exact.
3. The sidebar's **Cached (offline)** section lists every downloaded repo.
   Selecting one loads the CAR from disk and decodes it on the offline
   session's queue — **no network** — and the detail column drills
   collections → records → record detail, reusing the exact same rows and
   JSON tree as the live walk (`OfflineRepo` shapes CAR records into
   `ZatRecord` values with synthesized at:// URIs).

## Tests

Offline-only, mirroring the wrapper's fake-transport pattern:

```sh
cd app && swift test
```

32 tests: the session bridge (describe/list round trip, cursor paging, 400
envelope → `AppError.server`, three-429 retry exhaustion →
`AppError.rateLimited`), error mapping, `dataSession` requiring a PDS,
`RepoCache` round trips (save/list/load/delete, overwrite-in-place,
most-recent-first ordering, missing-load → `.cache`), `OfflineRepo`
grouping, and the milestone's demo test — save a CAR, list it, load it,
decode it, browse collections and records, all with no transport at all;
and content extraction — `CollectionInfo` labels, and `RecordContent` for
posts (text, link card, image captions/aspect, quoted posts), likes, follows,
starter packs, and the generic fallback. CAR fixtures come from a shared
`TestFixtures.swift` (the deterministic output of the zat core's `zig build
gen-car-fixture`, base64-embedded).
Identity resolution is intentionally not tested offline — it uses the
network even with a fake transport, matching the wrapper's own tests.
