import Foundation
import Zat

/// A type-aware preview of a record's body, parsed (offline) from the record
/// JSON. Renders posts, likes, follows, and starter packs as real content
/// instead of a raw JSON dump; unknown records fall back to a `generic`
/// case so no record is ever invisible.
///
/// Everything here is pure and fully testable — no views, no network. The
/// views switch on `RecordContent.Kind` (see `RecordContentView`).
public struct RecordContent: Sendable, Equatable {
    /// The kind of record, used by the views to pick a renderer.
    public let kind: Kind

    /// A one-line preview for list rows (the post text, a "followed X"
    /// summary, an embedded link's title, a starter pack's name, etc.).
    public let preview: String

    public enum Kind: Sendable, Equatable {
        case post(Post)
        case like(Like)
        case repost(Repost)
        case follow(Follow)
        case block(Block)
        case starterPack(StarterPack)
        case generic
    }

    /// The AT identifiers this record references as *people* subjects — for
    /// persistence bookkeeping, so a re-mirror knows which resolved handles
    /// to keep (a like's record-URI authority, a follow/block's subject DID).
    /// Uses the same rule as the browse so pruned keys always match.
    public var referencedPersonIdentifiers: Set<String> {
        switch kind {
        case .like(let like):
            return SubjectIdentity.personIdentifier(uri: like.subjectURI, did: like.subjectDID).map { [$0] } ?? []
        case .repost(let repost):
            return SubjectIdentity.personIdentifier(uri: repost.subjectURI, did: nil).map { [$0] } ?? []
        case .follow(let follow):
            return SubjectIdentity.personIdentifier(uri: nil, did: follow.subjectDID).map { [$0] } ?? []
        case .block(let block):
            return SubjectIdentity.personIdentifier(uri: nil, did: block.subjectDID).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// AT identifiers this record references as *entities* (non-account
    /// things with identity) — currently a starter pack's embedded feed
    /// generators. Kept separate from people so feed DIDs never share the
    /// account-name cache; a re-mirror prunes each map with its own set.
    public var referencedEntityIdentifiers: Set<String> {
        if case .starterPack(let pack) = kind { return Set(pack.feeds) }
        return []
    }

    public struct Post: Sendable, Equatable {
        public let text: String
        /// External embed (a link card) if present.
        public let external: ExternalLink?
        /// Quoted post (`embed.record`) if present.
        public let quote: String?
        /// Image embeds — captions/aspect ratios. The blobs themselves are
        /// CDN links that only resolve online, so we show their text.
        public let images: [Image]
        /// Facet-rich text becomes plain text here (we drop the link data;
        /// the detail view keeps the raw body).
        public let createdAt: String?

        public init(
            text: String,
            external: ExternalLink? = nil,
            quote: String? = nil,
            images: [Image] = [],
            createdAt: String? = nil
        ) {
            self.text = text
            self.external = external
            self.quote = quote
            self.images = images
            self.createdAt = createdAt
        }
    }

    public struct Like: Sendable, Equatable {
        /// URI of the liked record, when it's a record reference
        /// (at://... for a post/like/repost).
        public let subjectURI: String?
        /// DID when the subject is just an actor reference.
        public let subjectDID: String?
        /// ISO 8601 timestamp, re-formatted for humans.
        public let createdAt: String?
    }

    public struct Repost: Sendable, Equatable {
        /// URI of the reposted record (`at://...`), whose **author** is the
        /// person the repost points back at.
        public let subjectURI: String?
        public let createdAt: String?
    }

    public struct Follow: Sendable, Equatable {
        /// Handle if the record stored one (rare), else the DID.
        public let subjectDID: String?
        public let createdAt: String?
    }

    public struct Block: Sendable, Equatable {
        /// The blocked actor's DID.
        public let subjectDID: String?
        public let createdAt: String?
    }

    public struct StarterPack: Sendable, Equatable {
        public let name: String
        public let description: String
        public let listItems: Int
        /// Feed generators embedded in the pack.
        public let feeds: [String]
    }

    public struct ExternalLink: Sendable, Equatable {
        public let title: String
        public let uri: String
        public let description: String
        /// OGP thumbnail, if the embed carried one. Note: an image link, not
        /// a blob, so it can resolve on a live session.
        public let thumbURI: String?
    }

    public struct Image: Sendable, Equatable {
        public let alt: String
        public let aspectRatio: String?
    }

    // MARK: - extraction

    /// Build `RecordContent` from a record value (already decoded).
    public init(value: ZatJSONValue) {
        let type = value["$type"]?.stringValue ?? ""
        switch type {
        case "app.bsky.feed.post":
            self = Self.post(content: value)
        case "app.bsky.feed.like":
            self = Self.like(content: value)
        case "app.bsky.feed.repost":
            self = Self.repost(content: value)
        case "app.bsky.graph.follow":
            self = Self.follow(content: value)
        case "app.bsky.graph.block":
            self = Self.block(content: value)
        case "app.bsky.graph.starterpack":
            self = Self.starterPack(content: value)
        default:
            self.init(kind: .generic, preview: Self.genericPreview(value))
        }
    }

    private init(kind: Kind, preview: String) {
        self.kind = kind
        self.preview = preview
    }

    private static let controllers = [
        (first: "$type", second: "text"),
        (first: "name", second: "description"),
        (first: "displayName", second: "description"),
        (first: "handle", second: "description"),
    ]

    // MARK: posts

    private static func post(content: ZatJSONValue) -> RecordContent {
        let text = content["text"]?.stringValue ?? ""
        let external = externalLink(content["embed"]?["external"])
        let images = imageEmbeds(content["embed"])
        var quote: String?
        if let record = content["embed"]?["record"],
           let uri = referencedURI(record) {
            quote = uri
        }
        return RecordContent(
            kind: .post(Post(
                text: text,
                external: external,
                quote: quote,
                images: images,
                createdAt: content["createdAt"]?.stringValue
            )),
            preview: text.isEmpty
                ? (external?.title ?? quote ?? "Post")
                : text
        )
    }

    private static func externalLink(_ node: ZatJSONValue?) -> ExternalLink? {
        guard let title = node?["title"]?.stringValue, !title.isEmpty else { return nil }
        return ExternalLink(
            title: title,
            uri: node?["uri"]?.stringValue ?? "",
            description: node?["description"]?.stringValue ?? "",
            thumbURI: node?["thumb"]?["href"]?.stringValue ?? node?["thumb"]?["uri"]?.stringValue
        )
    }

    private static func imageEmbeds(_ embed: ZatJSONValue?) -> [Image] {
        guard let images = embed?["images"]?.arrayValue else { return [] }
        return images.enumerated().map { index, image in
            let ratio = image["aspectRatio"]
            var aspectText: String?
            if let w = ratio?["width"]?.intValue, let h = ratio?["height"]?.intValue {
                aspectText = "\(w)×\(h)"
            }
            return Image(
                alt: image["alt"]?.stringValue ?? "",
                aspectRatio: aspectText
            )
        }
    }

    private static func referencedURI(_ node: ZatJSONValue) -> String? {
        // record.ref is {  uri, cid } — the plain string form (older records)
        // is a direct at:// URI.
        if let uri = node["uri"]?.stringValue, isATURI(uri) {
            return uri
        }
        if case .string(let value) = node, isATURI(value) {
            return value
        }
        return nil
    }

    private static func isATURI(_ value: String) -> Bool {
        value.hasPrefix("at://")
    }

    // MARK: likes

    private static func like(content: ZatJSONValue) -> RecordContent {
        var subjectURI: String?
        var subjectDID: String?
        if let subject = content["subject"] {
            if let uri = subject["uri"]?.stringValue { subjectURI = uri }
            if let did = subject["did"]?.stringValue { subjectDID = did }
            if case .string(let value) = subject, isATURI(value) { subjectURI = value }
        }
        let subject = subjectURI ?? subjectDID ?? "a record"
        return RecordContent(
            kind: .like(Like(
                subjectURI: subjectURI, subjectDID: subjectDID,
                createdAt: content["createdAt"]?.stringValue
            )),
            preview: "Liked \(subject)"
        )
    }

    // MARK: reposts

    private static func repost(content: ZatJSONValue) -> RecordContent {
        var subjectURI: String?
        if let subject = content["subject"] {
            if let uri = subject["uri"]?.stringValue { subjectURI = uri }
            else if case .string(let value) = subject, isATURI(value) { subjectURI = value }
        }
        let subject = subjectURI ?? "a record"
        return RecordContent(
            kind: .repost(Repost(
                subjectURI: subjectURI, createdAt: content["createdAt"]?.stringValue
            )),
            preview: "Reposted \(subject)"
        )
    }

    // MARK: follows

    private static func follow(content: ZatJSONValue) -> RecordContent {
        let subjectDID = content["subject"]?["did"]?.stringValue
            ?? content["subject"]?.stringValue
        return RecordContent(
            kind: .follow(Follow(
                subjectDID: subjectDID, createdAt: content["createdAt"]?.stringValue
            )),
            preview: subjectDID.map { "Followed \($0)" } ?? "Follow"
        )
    }

    // MARK: blocks

    private static func block(content: ZatJSONValue) -> RecordContent {
        let subjectDID = content["subject"]?["did"]?.stringValue
            ?? content["subject"]?.stringValue
        return RecordContent(
            kind: .block(Block(
                subjectDID: subjectDID, createdAt: content["createdAt"]?.stringValue
            )),
            preview: subjectDID.map { "Blocked \($0)" } ?? "Block"
        )
    }

    // MARK: starter packs

    private static func starterPack(content: ZatJSONValue) -> RecordContent {
        let name = content["name"]?.stringValue ?? ""
        let description = content["description"]?.stringValue ?? ""
        var listCount = 0
        var feeds: [String] = []
        if let items = content["listItems"]?.arrayValue {
            listCount = items.count
        }
        if let feedsArray = content["feeds"]?.arrayValue {
            // Each feed is either a record ref `{uri, cid}` pointing at a feed
            // generator, a bare DID, or a URL. We keep the AT identifier (the
            // record-URI authority, or a direct DID/handle) so feeds display
            // and resolve as entities; plain URLs carry no identity.
            feeds = feedsArray.compactMap { item in
                if let did = item["did"]?.stringValue { return did }
                if let uri = item["uri"]?.stringValue,
                   let authority = SubjectIdentity.authority(ofATURI: uri) {
                    return authority
                }
                if case .string(let value) = item, value.hasPrefix("did:") { return value }
                return nil
            }
        }
        let preview = name.isEmpty ? "Starter pack" : name
        return RecordContent(
            kind: .starterPack(StarterPack(
                name: name, description: description,
                listItems: listCount, feeds: feeds
            )),
            preview: preview
        )
    }

    // MARK: generic fallback

    private static func genericPreview(_ value: ZatJSONValue) -> String {
        let candidates = ["text", "displayName", "name", "handle", "description", "title"]
        for key in candidates {
            if let text = value[key]?.stringValue, !text.isEmpty {
                return text
            }
        }
        return "Record"
    }

    // MARK: date formatting

    /// Nicer presentation of an ISO 8601 timestamp, e.g. "Aug 28, 2026 at
    /// 12:04". Not a timezone shift — just a more readable form of the string
    /// that was stored.
    public static func dateLabel(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}