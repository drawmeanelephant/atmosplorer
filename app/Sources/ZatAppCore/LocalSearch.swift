import Foundation

/// Deterministic, dependency-free local search over a repo's indexed records.
///
/// Matching is tiered, strongest first: an exact token match beats a token
/// *prefix* match, which beats a plain *substring* match. Within a tier,
/// higher-weight fields (post body > link title > link description) score
/// more, and all query tokens must match for a record to surface. Every
/// match is returned regardless of score; the score only orders, with record
/// recency as the tiebreak and path as a final stable tiebreak.
///
/// Scoring is O(entries) per query — acceptable because the caller owns the
/// expensive parts: `prepare` tokenizes every field and parses every date
/// **once**, and the prepared index is reused across keystrokes. (A naive
/// per-query re-tokenize plus a per-comparison date parse is a ~30 s
/// keystroke at 275k records; the prepared index scores the same repo in
/// well under half a second.) Pure and fully testable — no views, no
/// network, no regex.
public struct LocalSearch: Sendable {
    /// Filtering + result-shaping knobs for a query.
    public struct Options: Sendable, Equatable {
        /// Restrict to these `$type` values when set. A record with no
        /// `$type` never matches a kind-filtered query (it can't prove
        /// membership).
        public var kinds: Set<String>?
        /// Cap the number of results (best ranked survive). Nil = all.
        public var limit: Int?

        public init(kinds: Set<String>? = nil, limit: Int? = nil) {
            self.kinds = kinds
            self.limit = limit
        }
    }

    /// A single search hit: the matched entry plus its ranking score.
    public struct Result: Sendable, Equatable {
        public let entry: SearchIndexEntry
        public let score: Int

        public init(entry: SearchIndexEntry, score: Int) {
            self.entry = entry
            self.score = score
        }
    }

    /// A tokenized, rank-ready view of a repo's index. Built once by the
    /// caller (the browser layer owns this memoization) and reused for every
    /// keystroke, so each query's work is scoring only. Value type and
    /// `Sendable` — safe to build on a background thread and hand to another.
    public struct PreparedIndex: Sendable {
        /// The entries in index order; results reference them by position.
        public let entries: [SearchIndexEntry]
        /// Per-entry tokenized fields, index-aligned with `entries`.
        let tokenized: [[PreparedField]]
        /// Per-entry precomputed recency ranks, index-aligned with `entries`;
        /// `-.greatestFiniteMagnitude` when the date is absent or unparseable.
        let ranks: [Double]

        init(entries: [SearchIndexEntry]) {
            self.entries = entries
            var tokenized: [[PreparedField]] = []
            tokenized.reserveCapacity(entries.count)
            var ranks: [Double] = []
            ranks.reserveCapacity(entries.count)
            // One formatter reused across all entries — allocating one per
            // entry (as a naive sort would per comparison) is a quadratic
            // trap at repo scale.
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                tokenized.append(entry.fields.text.map { field in
                    PreparedField(
                        tokens: LocalSearch.tokens(in: field.text),
                        text: field.text.lowercased(),
                        weight: field.weight)
                })
                if let iso = entry.fields.date, let date = formatter.date(from: iso) {
                    ranks.append(date.timeIntervalSince1970)
                } else {
                    ranks.append(-.greatestFiniteMagnitude)
                }
            }
            self.tokenized = tokenized
            self.ranks = ranks
        }
    }

    /// One entry's searchable field, pre-tokenized for matching.
    struct PreparedField: Sendable {
        let tokens: [String]
        /// Lowercased raw text (the substring tier needs it; tokens cover
        /// the exact and prefix tiers).
        let text: String
        let weight: FieldWeightedText.Weight
    }

    /// Build the reusable, tokenized index for a repo's entries. Call once
    /// (e.g. when the index finishes loading), then `results(for:prepared:)`
    /// per keystroke.
    public static func prepare(_ entries: [SearchIndexEntry]) -> PreparedIndex {
        PreparedIndex(entries: entries)
    }

    /// One-shot convenience: prepare + score in a single call. Prefer the
    /// two-step form when the same entries are searched repeatedly — the
    /// search UI's hot path — since preparing tokenizes every field.
    public static func results(
        for query: String,
        in entries: [SearchIndexEntry],
        options: Options = Options()
    ) -> [Result] {
        results(for: query, prepared: prepare(entries), options: options)
    }

    /// Match `query` against a prepared index, ranked best-first.
    public static func results(
        for query: String,
        prepared: PreparedIndex,
        options: Options = Options()
    ) -> [Result] {
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }

        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(prepared.entries.count)
        for (index, entry) in prepared.entries.enumerated() {
            // Kind filter: with a filter set, only records whose kind is in
            // the set match (nil kind can't prove membership).
            if let kinds = options.kinds, !(entry.fields.kind.map(kinds.contains) ?? false) {
                continue
            }
            var score = 0
            for token in queryTokens {
                var best = 0
                for field in prepared.tokenized[index] {
                    let tier: Int
                    if field.tokens.contains(token) {
                        tier = 3                       // exact
                    } else if field.tokens.contains(where: { $0.hasPrefix(token) }) {
                        tier = 2                       // prefix
                    } else if field.text.contains(token) {
                        tier = 1                       // substring
                    } else {
                        continue
                    }
                    best = max(best, tier * field.weight.score)
                }
                guard best > 0 else {
                    // Every query token must match somewhere.
                    score = 0
                    break
                }
                score += best
            }
            if score > 0 {
                scored.append((index, score))
            }
        }

        // Rank by score, then precomputed recency, then path. All per-entry
        // work (tokenization, date parsing) happened in `prepare`, so this
        // sort is cheap even for tens of thousands of hits.
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let date0 = prepared.ranks[$0.index]
            let date1 = prepared.ranks[$1.index]
            if date0 != date1 { return date0 > date1 }
            return prepared.entries[$0.index].path < prepared.entries[$1.index].path
        }
        if let limit = options.limit, limit >= 0 {
            return scored.prefix(limit).map { Result(entry: prepared.entries[$0.index], score: $0.score) }
        }
        return scored.map { Result(entry: prepared.entries[$0.index], score: $0.score) }
    }

    /// Lowercase tokens from a string: split on anything that isn't a Unicode
    /// letter or digit, so punctuation and emoji never pollute matches.
    public static func tokens(in string: String) -> [String] {
        string.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
