# Contributing to Atmosplorer

Thanks for stopping by. This is a small three-layer project — a Zig AT
Protocol core, a Swift wrapper over it, and a SwiftUI app — so the fastest
way to be useful is to know which layer you're in. Everything is testable
offline; live-network tests are opt-in.

## Getting a dev environment

Prerequisites (same as the README):

- **Zig 0.16+** — the vendored core is built from source, never fetched
  prebuilt.
- **Swift 6.1+** (Xcode / CLT), macOS 13+.

A fresh clone needs the vendored core built once, because the
`ZatC.xcframework` is a gitignored build artifact:

```sh
cd zat-swift
Scripts/sync-zat.sh     # fetch hash-pinned upstream zat + overlay → zig build → xcframework
swift build
swift test              # offline

cd ../app
swift build
swift test              # fully offline (ZatFakeTransport + embedded CAR fixture)
```

## Where things live

| Layer | Path | What it is |
|---|---|---|
| Zig core | `zat-swift/Vendor/zat-overlay/` | our additions (Explorer facade, CAR iterator, C ABI) on top of upstream [zat](https://tangled.org/zat.dev/zat) |
| Swift wrapper | `zat-swift/Sources/Zat/` | typed API over the C ABI (`ZatExplorer`, `ZatError`, `ZatJSONValue`, …) |
| App | `app/Sources/ZatAppCore/` | SwiftUI-free testable core (session bridge, repo cache, search) |
| App | `app/Sources/Atmosplorer/` | the SwiftUI shell |

A change usually lands in one layer plus its tests; keep the C ABI contract
(`zat-swift/Sources/Czat/include/zat.h`) stable unless you're deliberately
changing the boundary.

## Running the tests

Offline suites (run in CI):

```sh
cd zat-swift && swift test
cd app && swift test
```

Opt-in live suites (real network, read-only — useful when touching session
or identity code):

```sh
ZAT_INTEGRATION=1 swift test --filter ZatExplorerIntegrationTests   # wrapper
ZAT_INTEGRATION=1 swift test --filter AppLiveTraversalIntegrationTests  # app
```

## Bumping the upstream zat pin

`sync-zat.sh` fetches a hash-pinned tarball from `tangled.org/zat.dev/zat`.
To move to a newer upstream:

```sh
# from a scratch dir with a build.zig (sync-zat.sh does this internally)
zig fetch --save https://tangled.org/zat.dev/zat/archive/main
```

Take the printed `zat-X.Y.Z-<hash>` and update `ZAT_PIN` in
`Scripts/sync-zat.sh` (and the version mentioned in `README.md` /
`THIRD-PARTY.md`). If the fetch hash doesn't match the pin, `sync-zat.sh`
fails loudly on purpose — that's the supply-chain guard, don't bypass it.

## Pull request checklist

- [ ] `swift build` passes in the layer(s) you touched
- [ ] offline tests pass (`swift test`)
- [ ] changes are covered by tests when they add or change behavior
- [ ] no unrelated formatting churn (keep the diff reviewable)
- [ ] if you touched the Zig core, rerun `Scripts/sync-zat.sh` and keep the
      generated products out of the commit (they're gitignored)

Small, focused PRs land much faster than large rewrites. When in doubt,
open an issue first to talk through the approach.
