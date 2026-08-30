# ZAT CORE CONTEXT BRIEF (for an external AI helper)

> Purpose: hand this to a chatbot / source-knowledge tool so it can help a human
> developer working on this repo. It explains **what the project is**, **what was
> just reimplemented**, **where things stand**, and **exactly what we're trying to
> learn**. It is a plain context dump — not documentation.

## 1. Repo & project

- Repo root (local): `/Users/tbuddy/t3/shower-thoughts/atmosplorer` (also __github__-style name "atmosplorer").
- Product: **Atmosplorer**, a native macOS SwiftUI desktop app for browsing
  [AT Protocol](https://atproto.com) repos **offline-first**: you "mirror" a
  repo by pulling its full CAR archive once, then browse every post/like/follow
  from the local copy with zero network.
- The whole app is three layers:
  ```
  Zig core (upstream "zat" kit + OUR overlay) ──compiles to──► libzat_c.a + zat.h
        │  (the C ABI / Swift boundary)
        ▼
  zat-swift/  (typed Swift wrapper: ZatExplorer, ZatError, ZatFakeTransport, models)
        ▼
  app/        (SwiftUI desktop client; depends only on ../zat-swift)
  ```
- There is a gitignored **`DEVKITS/`** dir referenced in some old docs — it
  held a full local checkout of the Zig core. It was **intentionally deleted by
  the developer** (it was only "review material", never a source of truth).

## 2. The Zig core ("zat")

- Upstream: [zat](https://tangled.org/zat.dev/zat) by nate nowack /
  zzstoatzz.io — a Zig **primitives** library (MIT) for AT Protocol: string
  syntax + validation (Did/Handle/Nsid/Rkey/AtUri/Tid/Datetime), identity
  resolution (DidResolver / HandleResolver / DidDocument), an XRPC client +
  HTTP transport, CBOR / CAR / MST (repo data structures), streaming
  (firehose / jetstream), OAuth, crypto.
- Version vendored: **`0.4.5`** (`build.zig.zon`). Toolchain: **Zig 0.16.0**
  (`/opt/homebrew/Cellar/zig/0.16.0_1`). Note: this is a **0.16.0 dev syntax**
  codebase — the std API differs from older Zig (e.g. `std.Io.Threaded`,
  instance-based `std.base64.standard.Encoder`, one-arg `@alignCast`,
  `callconv(.c)` lowercase, array-list methods take an allocator param).
- **Upstream provides NO Explorer facade, NO CAR→record decode high-level
  API, and NO C ABI.** Everything the Swift wrapper links is **our code**,
  layered on top of upstream in the overlay.

## 3. The overlay (OUR code, under `zat-swift/Vendor/zat-overlay/`)

- `build.zig` — upstream `build.zig` **trimmed to what the zig package can
  build** (the package ships only `build.zig`, `build.zig.zon`, `src/`; the
  smoke/example/bench steps reference files not in the package and were
  dropped), **plus** the C ABI static library step + `include/zat.h` install
  and a **macOS 13.0 minimum-version pin** (avoids Apple `ld` "built for newer
  macOS" warnings).
- `include/zat.h` — the full C ABI contract (also copied to
  `zat-swift/Sources/Czat/include/zat.h`).
- `src/explorer.zig` — the **Explorer facade** (see §5).
- `src/c_api.zig` — **C ABI marshalling** for every `zat_*` symbol (see §5).
- `src/c_root.zig` — the exporting shim (`@export`s `c_api` symbols into
  `libzat_c.a`).

`Scripts/sync-zat.sh` fetches upstream with
`zig fetch https://tangled.org/zat.dev/zat/archive/main` (hash-pinned), layers
the overlay, runs `zig build`, repacks the archive for Apple's linker, and
regenerates `zat-swift/Vendor/ZatC.xcframework` + copied header. A failed sync
never clobbers the last good `Vendor/` output.

## 4. What just happened / current state

The three overlay sources (`explorer.zig`, `c_api.zig`, `c_root.zig`) were
**lost** with the deleted `DEVKITS/` tree. The compiled `Vendor/ZatC.xcframework`
still contained the code, and the contract was documented in `zat.h` + the
Swift wrapper + the tests — so a developer **reimplemented them from scratch**
against those, iterating against the Zig 0.16 compiler and the test suites.

**Current state: everything builds and all tests pass.**

> **Verified 2026-08-30** (full re-run of every suite, offline + live + UI):
>
> - `sync-zat.sh` build: clean (no warnings/errors), produces `libzat_c_aligned.a`
>   with all 22 `zat_*` symbols (verified with `nm`), macOS 13.0 pin active.
>   The vendored `Vendor/ZatC.xcframework` (built 2026-08-28) matches the
>   restored overlay sources — no re-sync needed.
> - Swift wrapper `zat-swift`:
>   - offline `swift test`: **29 tests, 9 skipped (live), 0 failures**
>   - live `ZAT_INTEGRATION=1 swift test --filter ZatExplorerIntegrationTests`: **9/9 pass** against real bsky infrastructure (re-verified 2026-08-30, ~15.5s)
> - App `app`:
>   - offline `swift test`: **65 tests, 6 skipped (live), 0 failures** (up from 38 — significant new coverage landed since this brief was first written)
>   - live `ZAT_INTEGRATION=1 swift test --filter AppLiveTraversalIntegrationTests`: **8/8 pass** (resolve → describe → list across small/medium/large repos; re-verified 2026-08-30, ~23.6s)
> - **Offline browse verified end to end** (`ZAT_OFFLINE_VERIFY=1 swift test`,
>   new opt-in tests in `app/Tests/ZatAppCoreTests/`):
>   - `OfflineMirrorVerificationTests` — loads the *real* mirrored 79.2 MB CAR
>     of `deborah-10.bsky.social` from the desktop app's cache
>     (`~/Library/Application Support/Atmosplorer/caches/`) and decodes all
>     275,457 records through a session pinned to `https://offline.invalid`,
>     so any network touch would fail. Record count matches the mirror-time
>     count; every collection non-empty; every record has CID + content.
>   - `OfflineRenderVerificationTests` — UI-level rendering proof: the decoded
>     records are pushed through the same `RecordContent` extraction that
>     `RecordContentView`/`RecordRow` render. Asserts real post texts
>     (>50 non-empty), >50% of post rows render body content, likes/follows/
>     reposts route to their typed renderers, and **zero** records fall
>     through to the generic JSON dump.
> - **UI smoke test passed** (2026-08-30): `swift run Atmosplorer` launches;
>   handle resolution works; **Mirror repo** works end to end — including the
>   large-repo confirmation path (79 MB > 25 MB threshold → "Mirror anyway"
>   alert → confirm → download → decode → atomic save). Cache index verified
>   on disk: `filed.fyi` (618 KB, 1,212 records) and `deborah-10.bsky.social`
>   (79.2 MB, 275,457 records), well-formed `index.json` with mirror history.
>
> Remaining known gap: none functional. The only untested path is a manual
> visual pass over the SwiftUI windows (layout/appearance), which cannot be
> asserted from tests.

### Verification history

Log of each test campaign so future runs have a baseline to diff against.
Append a row — never rewrite old ones. "Live" columns are the opt-in
`ZAT_INTEGRATION=1` suites; verification tests are the opt-in
`ZAT_OFFLINE_VERIFY=1` suites added on 2026-08-30.

| Date | Campaign | Wrapper offline | Wrapper live | App offline | App live | Verification / UI | Notes |
|---|---|---|---|---|---|---|---|
| 2026-08-28 | Initial reimplementation check | 29/29 | 9/9 | 38/38 | 5/5 | — | Numbers as first recorded in this brief; overlay sources restored, xcframework rebuilt this day |
| 2026-08-30 | Full re-run (offline + live) | 29/29 | 9/9 (~15.5s) | 65/65 | 8/8 (~23.6s) | — | First re-verification after the break; app offline suite had grown 38 → 65 |
| 2026-08-30 | UI smoke + first offline-mirror verification | — | — | — | — | decode 275,457 records from real 79.2 MB CAR, 0 network; UI launch/resolve/mirror incl. large-repo confirm | Added `OfflineMirrorVerificationTests` |
| 2026-08-30 | Offline render verification | — | — | — | — | 2/2 (real post texts + typed kind routing, zero generic fallback) | Added `OfflineRenderVerificationTests` |

Reproduce any row with the commands in §7 plus the two opt-in flags
(`ZAT_INTEGRATION=1`, `ZAT_OFFLINE_VERIFY=1`). A future row that regresses any
column vs. the last row for that column is a finding worth a bug before
continuing.

Bugs already found + fixed during reimplementation (for context):
- a use-after-free in `zat_car_records_deinit` that wrote to a freed struct (caused heap corruption / SIGSEGV under Swift),
- an uninitialized-field free in `FakeTransport.create` (`allocator.create`
  doesn't apply struct-field defaults),
- `getRecord` sent a single `uri` param — the PDS rejects that; must
  decompose to `repo`/`collection`/`rkey`,
- Zig-0.16 API migrations (see §2).

## 5. What our code does (the reimplementation in detail)

### `src/explorer.zig` (Explorer facade)
- **Identity resolution** (`resolveIdentity`): parses input as `Did` or
  `Handle` (returns `InvalidIdentifier` otherwise), resolves via
  `DidResolver.resolve` / `HandleResolver.resolve` + `DidResolver`, and returns
  `{ did, handle?, pds? }` from the resulting `DidDocument` (`doc.id`,
  `doc.handle()`, `doc.pdsEndpoint()`).
  - Handle policy the dev chose: DID input → primary `alsoKnownAs` handle from
    the doc; handle input → the input handle.
- **Reader XRPC calls** (each returns `XrpcClient.Result`):
  - `getRecordJson` — validates `AtUri`, decomposes into
    `repo`/`collection`/`rkey` params → `com.atproto.repo.getRecord`.
  - `listRecordsJson(repo, collection, limit, cursor?)` → `listRecords`.
  - `describeRepoJson(repo)` → `describeRepo`.
  - `fetchRepoCar(did)` → `com.atproto.sync.getRepo?format=car`.
  - All route through `queryChecked`, which either hits the real
    `XrpcClient.queryParamsChecked(nsid, params, RetryPolicy{})` or a
    scripted `FakeTransport` (deterministic tests).
- **Offline CAR→record iteration** (`iterateCarRecords`):
  `car.readWithOptions` (cap lifted to input size) → find commit block →
  decode commit CBOR → `data` CID → `mst.Mst.loadFromBlocks` → `walk` → per
  record block `cbor.decodeAll` → serialize to JSON → collect
  `{ path = "collection/rkey", cid = multibase string, json }` in MST key order.
- **CBOR→JSON writer** (`cborToJson`): plain values map to JSON; **CID →**
  `{"$link":"bafy…"}`, **byte strings →** `{"$bytes":"<base64>"}` (standard
  alphabet, `=` padding). Confirmed as the AT Proto JSON convention.
- **`FakeTransport`**: FIFO queued responses, records request count + last
  URL, mirrors the XRPC client's retry policy (429s retry per Retry-After;
  `0` = instant).

### `src/c_api.zig` (C ABI marshalling)
- Implements every symbol below. Memory: `std.heap.c_allocator` (malloc),
  freed only via `zat_free` / the `zat_*_deinit` exports; strings
  NUL-terminated with `len` authoritative; absent optionals `{NULL,0}`.
- Maps `ExplorerError` → `zat_status`. A non-2xx XRPC envelope → returns
  `ZAT_ERROR_INVALID_RESPONSE` (3) and fills `zat_error_details`
  (http_status / error_name / message / retry_after).

### `src/c_root.zig`
- `@export`s, with `callconv(.c)`, every shown symbol under its `zat_*` name.

### Full C ABI surface (22 functions + types, defined in `zat.h`)
`zat_version` · `zat_free` · `zat_explorer_create` ·
`zat_explorer_create_with_fake` · `zat_explorer_destroy` ·
`zat_resolve_identity` · `zat_identity_deinit` · `zat_string_deinit` ·
`zat_blob_deinit` · `zat_error_details_deinit` · `zat_get_record_json` ·
`zat_list_records_json` · `zat_describe_repo_json` · `zat_fetch_repo_car` ·
`zat_iterate_car_records` · `zat_car_records_deinit` ·
`zat_fake_transport_create` · `zat_fake_transport_destroy` ·
`zat_fake_transport_queue_response` · `zat_fake_transport_request_count` ·
`zat_fake_transport_last_url`.
Types: `zat_status`, `zat_string`, `zat_blob`, `zat_error_details`,
`zat_identity`, `zat_explorer`, `zat_car_record`, `zat_car_records`,
`zat_fake_transport`.

## 6. Problemspaces / open questions we'd love ground truth on

Most of these are "does the *original*, now-deleted, implementation do X, and
what was the design intent?" — the tests pass, so behavior is verified, but we
want to know where our design choices may diverge from the original.

1. **`zat_version()` return value/mechanism**: We hardcode `"0.4.5"`. Did the
   original read the version from a `build_options` module (the build.zig
   already wires `{ name = "build_options" }` carrying `.version`), or use a
   different banner string? Exact string + mechanism, please.
2. **CAR record JSON serialization**: Confirmed it should be `{"$link":…}` /
   `{"$bytes":…}` (matches spec + our impl). Any divergence in the original
   (e.g. also emitting a `/` DAG-JSON key, or special handling for key
   sorting / `$type`)?
3. **`resolveIdentity` handle policy**: DID input → we return the doc's
   primary `alsoKnownAs` handle; handle input → the input. What did the
   original do? (Spec is silent — internal design.)
4. **Envelope→status mapping**: For a non-2xx XRPC response carrying an error
   envelope we return `invalidResponse` (3) and fill `zat_error_details`. Did
   the original ever return `network` (6) instead, or vary by HTTP status?
5. **The actual original source** — do you have, or can you reconstruct,
   `src/explorer.zig`, `src/c_api.zig`, `src/c_root.zig`? If you can produce
   them (or partial fragments / the relevant functions), we will diff and
   reconcile.

### §6 answers (investigated 2026-08-30)

A full artifact hunt was run before answering: the workspace has **no git
history** (no `.git`), no `.zig.bak`/`.orig` files, no pre-2026-08-28 build
artifacts (the entire `zat-swift/.vendor/` tree, including `zig-out/` and
`.zig-cache/`, was created fresh on 2026-08-28 during the reimplementation),
and `.freebuff/` contains only a project id. **The original sources are not
recoverable from this machine.** Answers below are therefore grounded in the
upstream zat 0.4.5 package (fetched, hash-pinned) plus our own test suite —
not in the lost original.

1. **`zat_version()` mechanism — the original most likely read
   `build_options`.** Evidence: the overlay `build.zig` (kept from the
   original wiring) creates `build_options` with
   `addOption([]const u8, "version", version)` where
   `version = @import("build.zig.zon").version` ("0.4.5"), and injects the
   module into the `zat` module — but *not* into the `zat_c` module. Upstream
   zat itself exposes no version constant in `src/`. Since upstream has no use
   for a version option of its own, the only plausible consumer of that
   `build_options` module is the (lost) C ABI layer. The current
   implementation hardcodes `"0.4.5"` in `c_api.zig` and is covered by
   `testCoreVersionMatchesZigCore`. **Recommended reconciliation:** import
   `build_options` in `c_root.zig`'s module (one line in `build.zig`) and
   return `build_options.version` — this makes the string track
   `build.zig.zon` automatically on future upstream bumps. Behavior-identical
   today (same "0.4.5"), so low priority.
   > **APPLIED 2026-08-30:** `build_options` is now wired into the `zat_c`
   > module (shared single module instance — calling `createModule()` twice
   > on the same Options makes Zig reject the duplicate file root) and
   > `zat_version()` returns `build_options.version` (declared as
   > `[:0]const u8` so it is a valid C string). Core rebuilt via
   > `sync-zat.sh`; all 22 symbols exported; wrapper (29) + app (68) offline
   > suites green; `testCoreVersionMatchesZigCore` passes against the rebuilt
   > archive.

2. **CAR record JSON serialization — `{$link}` / `{$bytes}` is correct, and
   is the only defensible convention.** It matches the atproto spec's
   DAG-JSON link representation and the interop-test fixtures. The DAG-JSON
   `/` (map) key is *not* part of the atproto record convention (it belongs to
   full IPLD DAG-JSON); emitting it would break round-tripping against
   `com.atproto.repo.getRecord` responses. No key-sorting or `$type`
   special-casing is needed: records are serialized as decoded, and the MST
   walk order already determines record order. Verdict: no divergence to
   reconcile; the current implementation should stay as is.

3. **`resolveIdentity` handle policy — internal design, no external truth.**
   Upstream `HandleResolver`/`DidResolver` return documents, not display
   policies, so the policy (DID input → doc's primary `alsoKnownAs` handle;
   handle input → echo the input) is necessarily the author's choice. The
   current policy is sensible: it guarantees a non-null handle for handle
   input (no surprise from DNS/DID-doc drift) and reports the *authoritative*
   handle for DID input. Both branches are pinned by tests. Keep as is.

4. **Envelope→status mapping — `invalidResponse` (3) for non-2xx envelopes is
   the right call.** In upstream zat, transport-level failures (DNS, connect,
   timeout) surface as Zig errors, while a completed HTTP exchange with a
   non-2xx status is a *response* carrying an XRPC error envelope — a
   semantically invalid response to the query, not a network failure. Mapping
   it to `ZAT_ERROR_INVALID_RESPONSE` and filling `zat_error_details`
   (http_status / error_name / message / retry_after) preserves the
   distinction the Swift wrapper needs (retry vs. report). Returning
   `network` (6) for HTTP errors would conflate the two and mislead retry
   logic. Verdict: keep; no variation by HTTP status is needed because the
   details struct already carries the status.

5. **Original source — unrecoverable locally; reconstruction not attempted.**
   As documented above, no artifact predating 2026-08-28 exists on this
   machine (checked: git, editor backups, `.vendor` zig-cache, `zig-out`,
   xcframework build dirs, `.freebuff`). The current implementation is the
   source of truth: it compiles clean, passes 582/582 upstream Zig tests,
   29 wrapper + 65 app offline tests, and 9 + 8 live integration tests
   (see §4 Verification history). If the original ever surfaces (e.g. from a
   remote backup or another clone), diff it against
   `zat-swift/Vendor/zat-overlay/src/` — but nothing in this repository
   depends on reconciling with it.

## 7. Environment / how to reproduce

```sh
cd zat-swift && ./Scripts/sync-zat.sh      # fetch upstream + overlay → zig build → package xcframework
cd zat-swift && swift build && swift test   # offline (live gated)
ZAT_INTEGRATION=1 swift test --filter ZatExplorerIntegrationTests   # wrapper live
cd ../app && swift build && swift test      # app offline
ZAT_INTEGRATION=1 swift test --filter AppLiveTraversalIntegrationTests  # app live
```
Relevant source locations (relative to repo root):
- `zat-swift/Vendor/zat-overlay/src/{explorer,c_api,c_root}.zig`
- `zat-swift/Vendor/zat-overlay/include/zat.h`
- `zat-swift/Sources/Zat/ZatExplorer.swift`, `ZatCString.swift`, `ZatError.swift`
- `zat-swift/Sources/Czat/include/zat.h` (regenerated copy)
- `zat-swift/Tests/ZatTests/` (offline + live tests pinning behavior)
- `zat-swift/Scripts/sync-zat.sh`

Key upstream internals we build against (in the fetched package, gitignored at
`zat-swift/.vendor/zat-src/src/internal/`):
`xrpc/xrpc.zig` (`XrpcClient`, `QueryParam`, `Response`, `Result`,
`XrpcError.fromResponse`, `RetryPolicy`), `xrpc/transport.zig`
(`HttpTransport`, `RateLimitHeaders`, `std.Io.Threaded`),
`identity/did_resolver.zig`, `identity/handle_resolver.zig`,
`identity/did_document.zig` (`id`, `handle()`, `pdsEndpoint()`, `deinit`),
`repo/car.zig` (`readWithOptions`, `ReadOptions`, `findBlock`),
`repo/cbor.zig` (`Value` union, `Cid.toString`), `repo/mst.zig`
(`Mst.loadFromBlocks`, `Walker` = `{ ctx: *anyopaque, entryFn }`, `WalkEntry`),
`syntax/{did,handle,nsid,at_uri,rkey}.zig` (`.parse(...)?`, offsets for
AtUri `authority_end`/`collection_end`).

> This brief intentionally includes implementation-level decisions so the AI
> has enough to answer precisely or tell us confidently "that's internal — no
> external truth exists."