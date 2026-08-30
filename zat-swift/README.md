# zat-swift

Swift wrapper over the [zat](../DEVKITS/zat-main) AT Protocol explorer core
(Zig, exposed through a C ABI).

## Layout

```
zat-swift/
├── Package.swift               # tools-version 6.1; macOS 13+ / iOS 16+
├── Scripts/sync-zat.sh         # vendor upstream zat + overlay → build → repack → package
├── Vendor/
│   ├── zat-overlay/            # OUR additions on top of upstream zat (checked in)
│   │   ├── README.md           # vendoring story + how the additions are implemented
│   │   ├── build.zig           # C ABI library/header + macOS 13.0 min-version pin
│   │   ├── include/zat.h       # the C ABI contract
│   │   └── src/                # Explorer facade / C ABI (explorer, c_api, c_root)
│   └── ZatC.xcframework        # prebuilt zat core statically linked (generated)
├── .vendor/zat-src/            # extracted upstream zat package (gitignored, generated)
├── Sources/Czat/               # C interop target: module map over zat.h
│   └── include/zat.h           # (generated; the ownership contract lives here)
├── Sources/Zat/                # the typed wrapper
│   ├── ZatExplorer.swift       # session class; owns the C handle
│   ├── ZatError.swift          # zat_status → Swift errors
│   ├── ZatModels.swift         # ZatIdentity, ZatRecord, ZatRecordPage, …
│   └── ZatJSONValue.swift      # Codable JSON tree for lexicon-less records
└── Tests/ZatTests/             # offline unit tests + live integration tests
```

## Workflow

Refresh the vendored core artifacts and rebuild:

```sh
Scripts/sync-zat.sh     # clone pinned upstream + overlay → zig build → package xcframework
swift build && swift test
```

`sync-zat.sh` never needs a `DEVKITS` checkout in this repo: it fetches the
hash-pinned upstream zat package via `zig fetch`
(`https://tangled.org/zat.dev/zat/archive/main`; override with
`ZAT_URL`/`ZAT_PIN`, or point `ZAT_SRC_DIR` at a local checkout), layers
`Vendor/zat-overlay/` on top, builds, repacks the archive for Apple's linker
(8-byte alignment + compiler-rt bundling), and regenerates
`Vendor/ZatC.xcframework` + the copied header. A failed sync never clobbers
the last good `Vendor/` output. The overlay carries the full implementation
of our additions (`explorer.zig` facade, `c_api.zig` marshalling,
`c_root.zig` export shim); see `Vendor/zat-overlay/README.md` for the design.

Live tests (real network, read-only) are gated:

```sh
ZAT_INTEGRATION=1 swift test --filter ZatExplorerIntegrationTests
```

## Usage

```swift
import ZatExplorer  // module "Zat"

// Bootstrap session for public lookups
let bootstrap = try ZatExplorer(host: "https://bsky.social")
let identity = try bootstrap.resolveIdentity("atproto.com")
let description = try bootstrap.describeRepo(identity.did)

// Typed records: decode record values into your own Codable models…
struct Post: Decodable { let text: String? }
let page = try bootstrap.listRecords(
    repo: identity.did, collection: "app.bsky.feed.post", limit: 25,
    as: Post.self)

// …or navigate raw JSON (Value must be given explicitly when not inferrable
// from context)
let raw = try bootstrap.listRecords(
    repo: identity.did, collection: "app.bsky.feed.post",
    as: ZatJSONValue.self)
let text = raw.records.first?.value["text"]?.stringValue

// Sync endpoints belong on the PDS: open a data session
let pds = try bootstrap.dataSession(for: identity)
let car = try pds.fetchRepoCar(did: identity.did)   // Data

// …or fetch the CAR and decode every record in one call — fully offline
// (commit block + MST walk + DAG-CBOR record decode in the core). Records
// come back in MST key order with their path, CID, and body as a JSON tree:
let records = try pds.fetchRepoCarRecords(did: identity.did)
for record in records.records {
    print(record.path, record.cid)                    // "app.bsky.feed.post/3jz" "bafy…"
    print(record.value["text"]?.stringValue ?? "")
}
// Decode an existing CAR you already hold (e.g. from disk) with
// `try pds.recordCar(from: data)`, or map a record body onto a Codable
// model with `record.value.decode(as: Post.self)`.

// Errors
do {
    _ = try bootstrap.resolveIdentity("not an identifier")
} catch let error as ZatError {
    // .invalidIdentifier — validated before any network activity
}

// Failed network calls carry the XRPC error envelope, so hosts can tell a
// rate limit from a bad request from a 404:
do {
    _ = try bootstrap.describeRepo("did:plc:missing")
} catch let error as ZatXrpcError {
    // code: ZatError (usually .invalidResponse)
    // details: ZatErrorDetails { httpStatus, errorName, message, retryAfterSeconds }
    // e.g. errorName == "RateLimitExceeded", httpStatus == 429
    print(error.errorDescription)   // envelope message when present
}
```

## Deterministic tests (no network)

`ZatFakeTransport` scripts every response and records every request, so
paging sequences, error envelopes, and rate-limit retries are testable
offline. A 429 with `retryAfter: 0` exercises the retry path instantly; a
non-2xx envelope surfaces as `ZatXrpcError` with `ZatErrorDetails`
(errorName/message/httpStatus/retryAfterSeconds), e.g. after three queued
429s the final `RateLimitExceeded` envelope is asserted:

```swift
let fake = try ZatFakeTransport()
try fake.queue(status: 200, body: #"{"records":[], "cursor":"t2"}"#)
try fake.queue(status: 429, body: "{}", retryAfter: 0)
try fake.queue(status: 200, body: #"{"did":"did:plc:abc","collections":[]}"#)

let explorer = try ZatExplorer(host: "https://fake.test", fakeTransport: fake)
// … run the session against the script …
XCTAssertEqual(fake.requestCount, 2)
XCTAssertEqual(try fake.lastURL(), "https://fake.test/xrpc/…")
```

## Ownership rules (Swift side)

- `ZatExplorer` is a `deinit`-managed handle: create it, use it, forget it.
- Everything returned from its methods is a plain Swift value type
  (`String`, `Data`, `Codable` structs); the wrapper consumes and frees all
  C-owned memory internally. **Never** call the `zat_*` functions or
  `zat_free` yourself.
- Sessions are not thread-safe — one per thread, or serialize access (the
  app's `AppSession` does exactly this with a serial queue).
- The full C-level contract is documented in `Sources/Czat/include/zat.h`.

## Desktop app

The SwiftUI client lives in [`../app`](../app) and depends on this package
(see its README for the `swift run Atmosplorer` flow and the async/error
model it builds on top of the wrapper).
