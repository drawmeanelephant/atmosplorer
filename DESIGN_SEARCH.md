# Design: local offline search

Scope of this doc: **per-repo, offline search over the records in a mirrored
CAR**. It names the data model, the on-disk index layout, the matching
strategy, and where it slots into the existing CachedRepo browser — and it
ends with the scope choices worth a decision before building.

This is grounded in the code as it stands today:

- Mirroring already **decodes every record once at download time** to count
  records (`CacheModel` → `AppSession.decodeCar(recordCount)`), then saves
  `<did>.car` next to an `index.json` in `~/Library/Application
  Support/Atmosplorer/caches` (`RepoCache`).
- Browsing a cached repo loads that CAR and hands it to
  `AppSession.decodeCar` again — clamping on `ZatAppCore`'s `NSLock`ed
  `RepoCache` and the offline session's serial queue — to produce an
  in-memory `OfflineRepo` (all `ZatCarRecord`s, `path` = "collection/rkey",
  `.value` = `ZatJSONValue`), which `CachedRepoBrowserModel` shapes into
  collections → records (`OfflineRepo.records(in:)`, synthesizing the at://
  URI the same way the live walk does).
- `RecordContent` already parses each record body by `$type` into a `Kind`
  + one-line `preview` (posts, likes, follows, blocks, starter packs,
  generic fallback).

## 1. What "search" means here

Two bounds first:

- **Repo-scoped, not global.** Search operates over the records of the repo
  currently open in the browser. A cross-repo search over every cached CAR is
  a natural next milestone but multiplies the index/union story, so it is
  explicitly out of v1 (see §6).
- **The record is the atom.** A match resolves to a record (its at:// URI,
  `path`, `cid`), which the UI opens with the exact same `RecordSelection` /
  `RecordRow` / `RecordDetailView` used by today's drill-down. Search is a
  different *entry point* into the same records, not a parallel content
  pipeline.

## 2. Data model: search fields per record

`RecordContent` collapses a record to a display preview. Search needs richer
*plain text to match on*, plus facets to filter/sort. Add a pure, testable
extractor (sibling to `RecordContent`, both walk `ZatJSONValue`) that returns,
per `ZatCarRecord`:

```swift
struct SearchFields: Sendable, Equatable {
    var kind: String?          // "app.bsky.feed.post", … (nil for unknown)
    var collection: String     // OfflineRepo.collection(of: path)
    var date: String?          // createdAt as stored (post/like/follow/…)
    var text: [FieldWeightedText]  // lowercased searchable text by weight
}

struct FieldWeightedText: Sendable, Equatable {
    var text: String
    var weight: Weight         // high/medium/low
}
```

Weights per kind, mirroring what matters to a user:

| kind | high | medium | low |
|---|---|---|---|
| post | body text | external.title, image alts | external.description |
| profile | displayName | description | handle |
| starter pack | name | description | — |
| list / feed generator | name | description | — |
| like / repost | subject handle/URI | — | createdAt |
| follow / block | subject handle/DID | — | createdAt |
| generic | any present of text/displayName/name/handle/description/title | — | — |

Two notes on what we deliberately do **not** index in v1:

- **Quoted-post body text.** `RecordContent` keeps only the quote's *uri*, not
  its text, so indexing quote bodies would mean re-pulling records. Cheap win
  folded into a later milestone (§6).
- **Blob bytes.** Image `alt` text is indexed (it's just a string in the
  record); the pixel data is CDN-only and never on disk.

Reusing the `$type` switch keeps the index kind-aware for free: a profile
match and a post match can be grouped, and the generic fallback guarantees no
record is invisible to search — the same tolerance `RecordContent` and
`CollectionInfo` already provide for new lexicons.

## 3. On-disk index layout

**Built at mirror time, owned by `RepoCache`, stored beside the CAR.** The
mirror decode pass already iterates every record to count them; reusing that
single pass to also extract `SearchFields` and write the index costs almost
nothing and guarantees the index always matches the CAR being saved. This is
the key design decision: *attach the index to the mirror transaction*, not to
first search.

Concretely, one new line-oriented file per repo, following the existing
`<did>.<suffix>.json` convention:

```
caches/
├── index.json
├── did:plc:xxx.car
├── did:plc:xxx.names.json
├── did:plc:xxx.entities.json
└── did:plc:xxx.searchindex.jsonl     ← new
```

Format: a `jsonl` text file with a **single header line** then **one JSON
object per record** (the same `SearchFields`), UTF-8, ordered by path.

```jsonlines
{"schemaVersion":1,"did":"did:plc:xxx","recordCount":275457,"indexedAt":1289472034}
{"path":"app.bsky.feed.post/3jz","cid":"bafy…","kind":"app.bsky.feed.post","collection":"app.bsky.feed.post","date":"2026-08-01T12:04:00Z","text":[{"text":"…","weight":"high"}]}
…
```

Why line-oriented rather than a single JSON array:

- **Streaming build and parse.** One record decoded → appended, no giant
  intermediate `Data`; on load, resolve only the header to validate, then
  stream the lines. A monolith array forces a full decode of tens of MB.
- **Live-sync friendly.** When mirroring later upgrades to incrementally
  mirroring changed records, the append-per-line layout lets sync rewrite only
  the affected lines instead of invalidating one giant blob. Keeping that open
  is worth the slightly less compact format (see the visibility note in §5 of
  `ZAT_CONTEXT_BRIEF.md`'s mirror philosophy).

`SearchIndex` (new, in `ZatAppCore`, thread-safe like `RepoCache`) owns:
write-at-mirror, stream-load, and validation via the header. **Staleness**
is the one real consistency rule to enforce:

- The index is valid only while `header.recordCount == index.json[did].recordCount`
  and `schemaVersion` matches. Anything else (old CAR re-mirrored before the
  feature, corruption, a future version bump) means **rebuild**, which after a
  CAR re-mirror is just *re-running the same pass that built it*. The cascade
  rule: a CAR with no valid index → lazy in-memory build from the decoding
  `OfflineRepo` at first search (zero extra disk I/O, correct if the disk
  index went missing), then a background persist.

`RepoCache.delete(did:)` already removes the `.names`/`.entities` maps; add the
`.searchindex.jsonl` file to the same cleanup so deleting a repo never orphans
its index.

### Sizing sanity check

The largest fixture on record in `ZAT_CONTEXT_BRIEF.md` is a 79.2 MB CAR with
275,457 records. The index holds only per-record search text + a small header,
so a line-per-record plain-text file of that repo lands in the low tens of MB
— the same order as the CAR it describes, with no lossy blobs. If it ever
matters, `NSData.compressed(using:)` (Foundation, no new dependency) shrinks
this several-fold at the cost of losing the append-friendly story, so defer
that until live sync picks a format.

## 4. Matching strategy

Pure, Foundation-only, deterministic — matching `OfflineRepo`/`RecordContent`
testability. Tokenization and scoring live behind small structs so the
tokenizer or ranker can be swapped without touching the UI.

- **Tokenize** the query and each `FieldWeightedText` to lowercase tokens
  (split on whitespace + punctuation/Unicode non-letters). Keep the tokenizer
  a separate piece so a later `NSLinguisticTagger`-based or N-gram tokenizer
  drops in without rework.
- **Match tiers**, in order of strength:
  1. token equals a document token (phrase/word match),
  2. token is a prefix of a document token ("atl" → "atproto"),
  3. token appears as a substring of any document string.
  All three tiers are cheap containment tests — no regex, viable over 275k
  records.
- **Rank** results by a small score sum: matched tier weight (exact > prefix
  > substring) × field weight (high > medium > low), plus `date` recency as a
  tiebreak so newest posts float up. Every match is surfaced regardless of
  score; the score only orders.

Deliberately out: boolean operators, regex, fuzzy/typo tolerance, and
cross-field AND/OR semantics. Each is a clean "later" that slots into the
ranker, none is required for the first useful bite.

**Measured (synthetic 275k-record repo, debug build, `LocalSearchBenchmarkTests`).**
The naive "score per keystroke from raw entries" implementation was a ~30 s
common-token query at 275k — two hidden costs: every query re-tokenized every
field of every record, and the recency tiebreak allocated an `ISO8601DateFormatter`
**per sort comparison** (quadratic at tens of thousands of hits). Fixes, both in
`LocalSearch`:

- **Caller-owned memoization.** `LocalSearch.prepare(_:)` builds a `PreparedIndex`
  that tokenizes every field and parses every date **once**; `results(for:prepared:)`
  then scores per keystroke. One prepare ≈ 6.6 s debug / ~1 s release at 275k
  (one-time, background, amortized); per-keystroke scoring ≈ 500 ms debug /
  well under 100 ms release for common, AND, and no-hit queries alike.
- **Precomputed recency ranks.** Dates parse once into a rank array; the sort
  compares ranks, never formatters.

A one-shot `results(for:in:)` convenience remains for small/miscellaneous use;
callers in the hot path must prepare once and reuse.

## 5. Where it hooks into the CachedRepo browser

Add a `SearchModel` (`@MainActor`, `ObservableObject`, next to
`CachedRepoBrowserModel`) and a `.searchable` field on `CachedRepoView` scoped
to the open repo. No new window — search is an affordance *inside* the browser
over the repo already on screen.

- **Source of entries.** If a valid persisted index exists, stream-load it
  (fast path; no CAR decode needed). Otherwise derive `SearchFields` from the
  already-decoded `OfflineRepo.records` (the model holds it after `load()`),
  preferred over re-reading disk.
- **Query execution.** Debounce typing (~150–200 ms), then run matching. The
  typical open repo is tens of thousands of records, so a full re-tokenize per
  keystroke is wasteful; memoize the token→records map on first query and
  filter the ranked result per keystroke. For the very large fixture, do the
  full scoring on a serial background `DispatchQueue` (the same pattern the app
  already uses for the explorer) and publish results back to the main actor.
- **Result rendering.** Matches become the same `RecordSelection(uri:cid:value:)`
  the drill-down uses, rendered by `RecordRow`, opening `RecordDetailView` —
  and, from a matched post/like, the known collection drill-down. Show a
  per-result one-line `RecordContent.preview` plus its collection label
  (`CollectionInfo`), so a hit is recognizable at a glance.
- **Empty/missing-index UX.** Before the first mirror produces an index, search
  still works (in-memory build); the only difference is a first-query pause the
  size of the in-memory build. Surface an "indexing on first search" state when
  a build is in flight, matching the existing `Phase.loading` pattern.

## 6. Scope decisions to make before building

1. **Repo-scoped (recommended) vs global.** Repo-scoped reuses today's browser
   and one `index.jsonl`. Global search unions every repo's index and needs a
   combined "which repo" result column — defer it.
2. **Mirror-time build (recommended) vs lazy.** Mirror-time reuses the pass
   that already decodes for `recordCount` and attaches to the mirror
   transaction. Lazy defers I/O but re-decodes or re-extracts later and never
   covers repos mirrored before the feature ships. Go mirror-time, keep the
   lazy path only as a rebuild fallback.
3. **Quote-text indexing.** Only the *uri* is kept today; enriched quotes
   (indexing the quoted post's text) need `RecordContent` to extract body text
   from a quote, which is a slightly bigger change and can land second.
4. **Index compression.** Plain-text `jsonl` is adopted for append-friendliness
   and zero new deps; revisit only if disk footprint or the live-sync format
   argues otherwise.

## 7. Tests (offline, matching the repo's conventions)

- `SearchIndexTests` — mirror-time build writes the file; load/validation;
  recordCount mismatch, corruption, and schema bump each trigger rebuild;
  delete removes the file.
- `LocalSearchTests` — query tokenization; exact vs prefix vs substring tiers;
  field-weight ordering; kind filtering; recency tiebreak; no-network.
- `SearchFieldsTests` — extraction per `$type` (a blumpy, non-Swift UI-free
  walk of `ZatJSONValue`, exactly `RecordContent`'s shape).
- End-to-end offline: search the real mirrored Deborah CAR under
  `ZAT_OFFLINE_VERIFY=1`, asserting every returned record's indexed text
  contains the query and no transport is touched — the same rigor as
  `OfflineMirrorVerificationTests`.