# zat vendoring overlay

This directory is **our additions on top of upstream
[zat](https://tangled.org/zat.dev/zat)** (MIT, © nate nowack / zzstoatzz.io).
`Scripts/sync-zat.sh` fetches the upstream zat package the canonical Zig way
— `zig fetch` of the hash-pinned tarball
(`https://tangled.org/zat.dev/zat/archive/main`, verified against its package
hash) — layers this overlay over it, builds the C ABI static library, repacks
it for Apple's linker, and packages `Vendor/ZatC.xcframework` + copies
`Sources/Czat/include/zat.h`.

Upstream zat is a primitives library (syntax, identity resolution, XRPC,
CBOR/CAR/MST, firehose/jetstream, OAuth, crypto). Everything the Swift wrapper
links against — the **Explorer facade**, the **CAR record iterator**, and the
**C ABI** — is our code and lives here (or in this tree's `src/`).

## What's checked in

| Path            | What it is                                                          |
|-----------------|---------------------------------------------------------------------|
| `build.zig`     | Upstream's `build.zig`, **trimmed to what the package can build** (the zig package ships only `build.zig` + `build.zig.zon` + `src/`, so upstream's smoke/example/bench steps are dropped), plus the C ABI library + header install and the macOS 13.0 minimum-version pin (keeps Apple `ld` from warning "built for newer macOS" when the app links). The test step + interop fixtures are kept verbatim. |
| `include/zat.h` | The C ABI contract (also regenerated into `Sources/Czat/include/zat.h` at sync time) |
| `src/`          | The three implementation files (see below)                          |

## The three implementation files

These are **our code**, reimplemented against the contract and verified by the
wrapper + app test suites:

- **`src/explorer.zig`** — the Explorer facade: identity resolution (handle /
  DID → { did, handle, pds } via DNS-over-HTTPS + PLC/did:web), the reader
  XRPC calls (getRecord / listRecords / describeRepo / getRepo), fully-offline
  CAR→record iteration (commit block + MST walk + DAG-CBOR → { path, cid,
  json }), a CBOR→JSON writer (links/bytes become `{"$link"}`/`{"$bytes"}`
  objects per atproto convention), and a scripted `FakeTransport` for
  deterministic tests (FIFO responses, retry policy, request count / last URL).
- **`src/c_api.zig`** — C marshalling for every `zat_*` symbol in
  `include/zat.h`. Owns the allocation contract (malloc-backed memory freed
  only via the deinit exports / `zat_free`, NUL-terminated strings with `len`
  authoritative, absent optionals as `{NULL, 0}`) and maps `ExplorerError`
  onto `zat_status`, writing the XRPC error envelope into `zat_error_details`
  on non-2xx responses.
- **`src/c_root.zig`** — the thin export shim re-exporting `c_api`'s symbols
  into the `zat_c` static library under their `zat_*` names.

### Behavioral notes worth knowing

- `iterateCarRecords` lifts upstream's 2 MB CAR cap (set to the input size) so
  the mirror flow can decode arbitrarily large repos; block hash verification
  stays on.
- CBOR→JSON renders DAG-CBOR CIDs and byte strings as `{"$link":"bafy…"}` and
  `{"$bytes":"<base64>"}` so they survive JSON round-tripping on the Swift
  side.
- `getRecord` decomposes its `at://` URI into `repo`/`collection`/`rkey`
  params (the reference PDS rejects a bare `uri`).
- `FakeTransport.create` initializes every field via a struct literal — the
  `request_count`/`last_url` defaults only apply with a literal, and missing
  them freed a garbage pointer.

### Updating the source when the Swift contract changes

The authoritative test surface is `zat-swift/Tests/` (offline
`ZatFakeTransport` / `ZatRecordCar` tests + gated live integration tests).
After editing any `src/` file, re-run `Scripts/sync-zat.sh` and then the full
wrapper + app suites.

## Updating the overlay when upstream bumps

- Run `zig fetch --save https://tangled.org/zat.dev/zat/archive/main` and update
  `ZAT_PIN` in `Scripts/sync-zat.sh` to the printed name+version+hash.
- Rebase `build.zig` against the new upstream `build.zig` (keep the C ABI
  block + min-version pin on top; keep it trimmed to what the package ships).
- Re-verify `explorer.zig` against any changed upstream APIs (XRPC client,
  CAR/CBOR/MST, identity resolvers).