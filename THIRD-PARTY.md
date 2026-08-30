# Third-party credits & attribution

This project is a thin SwiftUI app over an existing AT Protocol primitives kit in
Zig. We want the credit story to be unambiguous: our own code (the `app/`
SwiftUI client and the `zat-swift/` Swift wrapper) is MIT-licensed (see
`LICENSE`); the underlying AT Protocol engine is a separate, already-published
MIT-licensed project, vendored in this workspace and used as-is.

## zat — AT Protocol building blocks for Zig

- **Project:** [zat](https://zat.dev) · repo: https://tangled.org/zat.dev/zat
- **Author:** nate nowack / zzstoatzz.io
- **License:** MIT — see `LICENSE` in the vendored zat package
- **Version in this workspace:** `0.4.5` (see `zat-swift/.vendor/zat-src/build.zig.zon`)

zat is the AT Protocol core this app is built on: syntax + identity resolution,
XRPC clients, CBOR / CAR / MST, firehose + jetstream, OAuth, and crypto. It is
vendored into `zat-swift/Vendor/ZatC.xcframework` — a C static library
(`libzat_c.a`) with a header (`zat.h`) that the Swift wrapper links against.

We extend the reader-facing pieces on top of it — most notably an `Explorer`
facade and its CAR record iterator in the Zig core (`explorer.zig`), and the
C ABI (`c_api.zig`) that forms the Swift boundary — but zat itself is not our
code, and its copyright and license are retained in full.

### Synchronizing from upstream

The core is vendored as **upstream zat (hash-pinned package) + our overlay**
(`zat-swift/Vendor/zat-overlay`, which carries our additions and build
wiring). To refresh or re-vendor it:

```sh
zat-swift/Scripts/sync-zat.sh
```

That script fetches the pinned upstream zat package the canonical Zig way —
`zig fetch https://tangled.org/zat.dev/zat/archive/main`, verified against its
package hash — extracts it into a gitignored cache, layers the overlay on
top, runs `zig build`, repacks the archive for Apple's linker (8-byte
alignment + compiler-rt bundling), and regenerates
`zat-swift/Vendor/ZatC.xcframework` and the copied header. Those products are
build artifacts and are gitignored; a fresh clone must run the sync once
before `swift build`.

Our three implementation files — `src/explorer.zig` (the Explorer facade +
CAR record iterator), `src/c_api.zig` (the C ABI marshalling), and
`src/c_root.zig` (the export shim) in `zat-swift/Vendor/zat-overlay/` — were
deleted along with the old dev checkout and have since been **reimplemented**
against `include/zat.h`, the Swift wrapper, and the test suites. `sync-zat.sh`
now builds the vendored core end-to-end from upstream + overlay. See
`zat-swift/Vendor/zat-overlay/README.md` for the design and the behavioral
notes.

## atproto-interop-tests

The Zig core's test suite pulls the public
[bluesky-social/atproto-interop-tests](https://github.com/bluesky-social/atproto-interop-tests)
repository (pinned in `zat-swift/.vendor/zat-src/build.zig.zon`) for deterministic
fixtures: identifier syntax vectors, DID/crypto fixtures, data-model fixtures,
and MST key-height fixtures. Lazily fetched only when running `zig build test`.

## websocket.zig

zat depends on [websocket.zig](https://tangled.org/zzstoatzz.io/websocket.zig)
v0.1.12 (pinned in `zat-swift/.vendor/zat-src/build.zig.zon`) for its
firehose/jetstream clients.

## What is ours

- `app/` — the SwiftUI desktop client (Windows/views/view-models). MIT.
- `zat-swift/` — the typed Swift wrapper over the zat C ABI. MIT.
- The `Explorer` facade / CAR iterator / C ABI additions that this project
  contributed on top of upstream zat, carried in
  `zat-swift/Vendor/zat-overlay/` (see the vendoring section above).

Both `app/` and `zat-swift/` depend only on local packages; there are no other
third-party Swift dependencies in the build graph.