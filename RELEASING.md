# Releasing Atmosplorer

How to ship a new version. Releases are git tags on `main` plus a GitHub
release with notes generated from what landed since the last tag. The
`CHANGELOG.md` at the repo root is the source of truth for what changed per
release; keep it updated as part of the process below.

## Versioning: semantic versioning

Atmosplorer follows [semver](https://semver.org), `MAJOR.MINOR.PATCH`. Until
`1.0.0` there is **no stable public API**, so the reach of each bump is:

- **PATCH (`v0.1.1`)** — bug fixes and internal polish; no user-facing or
  public-API changes. The safest bump; normal for ongoing maintenance.
- **MINOR (`v0.2.0`)** — new user-visible features, or additive changes to the
  3-layer boundary (Zig C ABI → `zat-swift` → app). Most feature landings land
  here. In the `0.x` range a minor *can* carry breaking changes; call them out
  loudly in the release notes when it does.
- **MAJOR (`v1.0.0`)** — the first stable release, and after that any breaking
  change to the public API or the `zat.h` C ABI contract. Reserve it.

What counts as the "public API" for semver purposes:

- The Swift package APIs in `zat-swift` (`ZatExplorer`, `ZatError`,
  `ZatModels`, …).
- The C ABI contract in `zat-swift/Sources/Czat/include/zat.h`.
- The `ZatAppCore` surface (session bridge, repo cache, search core) that the
  app's core tests pin down.
- The on-disk cache/search-index format. A change that invalidates caches is
  breaking.

## Before tagging

1. **`main` is green.** The last push must have passed CI (`swift build` +
   `swift test` for both packages). Don't tag over a red or mid-run workflow.
2. **Working tree is clean.** `git status --short` shows nothing but the branch
   line. Stray untracked files can hide in the tree; clean them first.
3. **The docs agree.** Bump any version/screenshot references in `README.md`
   if the release touches them. If the pinned upstream `zat` changed, keep
   `ZAT_PIN` in `sync-zat.sh` and the version mentions in `README.md` /
   `THIRD-PARTY.md` in sync.
4. **Update `CHANGELOG.md`.** Move the `Unreleased` entries up into the new
   version's section (newest first), add the date, and link the new version
   at the bottom. Dragging entries from `git log` is a good cross-check:
   ```sh
   git log --oneline <last-tag>..HEAD
   ```
   Group them into what landed (features vs. fixes vs. infra) instead of
   pasting raw commits.

## Tagging and releasing

The tag is **annotated** (carries a message) and points at current `main`. The
release is a **published** GitHub release (not a draft/prerelease) with notes
generated from the collected changelog.

```sh
# 1. Tag current main
git tag -a v0.2.0 -m "Atmosplorer v0.2.0 — <short summary>"

# 2. Push the tag (push commits to main first if not already there)
git push origin main
git push origin v0.2.0

# 3. Create the release. Write notes to a file to avoid shell-quoting issues.
gh release create v0.2.0 \
  --repo drawmeanelephant/atmosplorer \
  --title "Atmosplorer v0.2.0 — <short summary>" \
  --notes-file .release-notes.md
```

Then verify it landed:

```sh
gh release view v0.2.0 --repo drawmeanelephant/atmosplorer \
  --json name,tagName,publishedAt,isDraft,isPrerelease,targetCommitish
```

Expect `isDraft: false`, `isPrerelease: false`, and `targetCommitish: main`.

## Release notes template

Follow the `v0.1.0` release as the shape. A good set of notes:

1. A one-paragraph pitch: what the app is and the headline of this release.
2. **What has landed** — a checklist of user-visible features and notable
   fixes, one line each. Call out breaking changes (cache-format invalidation,
   C ABI changes) in their own highlighted bullet. This should track the
   release notes against what you just wrote in `CHANGELOG.md`.
3. **Try it** — the clone → `sync-zat.sh` → build/test → `swift run` block from
   the README, so the release page is self-contained for someone who just
   clicked in.
4. Requirements line (Zig version, Swift version, macOS) and pointers to
   `README.md` / `THIRD-PARTY.md`.

## After releasing

- Confirm the CI badge on the release's commit is green (it should be, from
  step 1).
- Update the "Status / what has landed" line in the README if the milestone
  count changed.
- Announce it — the whole point of a release is that it's shareable.