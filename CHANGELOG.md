# Changelog

All notable changes to Atmosplorer are documented here, newest first.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `RELEASING.md` for the versioning policy and the tag-and-release process.

## [Unreleased]

### Added
- **Star from any list.** Record rows in the collections browser, search
  results, and live preview now carry a trailing star, so records can be
  bookmarked straight from the list — the same toggle as the detail view's
  toolbar star. The Favorites section's rows show a filled star that unstars
  on click, alongside the existing context-menu remove.

## [0.2.0] - 2026-08-30

### Added
- **Favorites.** Star any record from its detail view and it's saved to an
  on-disk `favorites.json` — the decoded value rides along, so the sidebar's
  Favorites section reopens the record fully offline, even after the source
  repo is no longer cached.
- **Release tooling.** `RELEASING.md` (semver policy + the tag-and-release
  process), `CHANGELOG.md` (this file, the release source of truth), and the
  pointers to both in `README.md` / `CONTRIBUTING.md`.

## [0.1.0] - 2026-08-30

First tagged release: a native macOS desktop client for browsing AT Protocol
repos, fully offline.

### Added
- **Offline-first CAR browsing.** Mirror any repo once (e.g. `atproto.com`),
  then browse every post, like, follow, and starter pack with zero network —
  collections sidebar, record lists, and detail views.
- **Local search across every record.** Debounced `.searchable` on the browser
  with an on-disk index persisted lazily and a background `PreparedIndex` so
  scoring never blocks the UI. Backed by a benchmark at 275k records
  (per-keystroke scoring ~0.5s debug / well under 100ms release).
- **Three-layer architecture, one exit point.** `zat-overlay + upstream zat`
  (Zig) → `zat-swift` (typed Swift wrapper) → `app` (SwiftUI client); the app
  never touches the C ABI directly.
- **Offline-first tests.** 121 tests across the wrapper and app run fully
  offline (deterministic fixtures + `ZatFakeTransport`); live-network suites
  are opt-in behind `ZAT_INTEGRATION=1`.
- **Green CI on every push.** Swift 6.2 + Zig 0.16 pinned, vendored-source
  cache, and a hardened sync: retry-with-backoff on Tangled rate limits,
  fallback for a poisoned cache, and idempotent overlay copying.

[Unreleased]: https://github.com/drawmeanelephant/atmosplorer/compare/v0.2.0...main
[0.2.0]: https://github.com/drawmeanelephant/atmosplorer/releases/tag/v0.2.0
[0.1.0]: https://github.com/drawmeanelephant/atmosplorer/releases/tag/v0.1.0