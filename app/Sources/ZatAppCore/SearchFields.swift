import Foundation
import Zat

/// Searchable plain-text fields extracted from a record body, so the search
/// index stores only what matching needs — no blobs, no raw JSON trees.
///
/// `SearchFields` is the search counterpart of `RecordContent`: same `$type`
/// switch, same tolerance for unknown lexicons (they fall through to the
/// generic extractor rather than becoming invisible), but it returns raw
/// *text to match on* with a weight per field instead of a one-line preview.
/// Weights express what a user cares about: a post's body text is a stronger
/// match than its link card's description, which is stronger than nothing.
///
/// Pure and fully testable — no views, no network. The stored index keeps the
/// extracted fields (not the record JSON), so search never re-parses the CAR.
public struct SearchFields: Sendable, Equatable, Codable {
    /// The record's `$type`, e.g. `app.bsky.feed.post`. Nil when the record
    /// carries no `$type` (the generic fallback).
    public let kind: String?
    /// The record's `createdAt` as stored (ISO 8601), for recency ranking.
    public let date: String?
    /// Searchable text with a weight per field, in extraction order.
    public let text: [FieldWeightedText]

    /// Build the searchable fields for a decoded record body.
    public init(value: ZatJSONValue) {
        let type = value["$type"]?.stringValue
        self.kind = type
        self.date = value["createdAt"]?.stringValue
        switch type {
        case "app.bsky.feed.post":
            self.text = Self.post(value)
        case "app.bsky.actor.profile":
            self.text = Self.named(value, nameKey: "displayName")
        case "app.bsky.graph.starterpack", "app.bsky.graph.list":
            self.text = Self.named(value, nameKey: "name")
        case "app.bsky.feed.generator", "app.bsky.feed.feed",
             "app.bsky.labeler.service":
            self.text = Self.named(value, nameKey: "displayName")
        case "app.bsky.feed.like", "app.bsky.feed.repost":
            self.text = Self.subject(value, subjectKey: "subject")
        case "app.bsky.graph.follow", "app.bsky.graph.block":
            self.text = Self.subject(value, subjectKey: "subject")
        default:
            self.text = Self.generic(value)
        }
    }

    // MARK: extraction

    /// Posts: body text high, link-card title + image alts medium, link
    /// description low.
    private static func post(_ content: ZatJSONValue) -> [FieldWeightedText] {
        var fields: [FieldWeightedText] = []
        if let text = content["text"]?.stringValue, !text.isEmpty {
            fields.append(.init(text: text, weight: .high))
        }
        if let external = content["embed"]?["external"] {
            if let title = external["title"]?.stringValue, !title.isEmpty {
                fields.append(.init(text: title, weight: .medium))
            }
            if let description = external["description"]?.stringValue, !description.isEmpty {
                fields.append(.init(text: description, weight: .low))
            }
        }
        for image in content["embed"]?["images"]?.arrayValue ?? [] {
            if let alt = image["alt"]?.stringValue, !alt.isEmpty {
                fields.append(.init(text: alt, weight: .medium))
            }
        }
        return fields
    }

    /// Profiles / starter packs / lists / feed generators / labelers: the
    /// display name high, the description medium.
    private static func named(_ content: ZatJSONValue, nameKey: String) -> [FieldWeightedText] {
        var fields: [FieldWeightedText] = []
        if let name = content[nameKey]?.stringValue, !name.isEmpty {
            fields.append(.init(text: name, weight: .high))
        }
        if let description = content["description"]?.stringValue, !description.isEmpty {
            fields.append(.init(text: description, weight: .medium))
        }
        return fields
    }

    /// Likes / reposts / follows / blocks: who the interaction points at —
    /// the record-URI authority (or bare DID) of the subject, medium weight,
    /// so \"who did I like/follow\" is searchable.
    private static func subject(_ content: ZatJSONValue, subjectKey: String) -> [FieldWeightedText] {
        guard let subject = content[subjectKey] else { return [] }
        var identifier: String?
        if let uri = subject["uri"]?.stringValue {
            identifier = SubjectIdentity.authority(ofATURI: uri) ?? uri
        } else if let did = subject["did"]?.stringValue {
            identifier = did
        } else if case .string(let value) = subject {
            identifier = value.hasPrefix("at://")
                ? (SubjectIdentity.authority(ofATURI: value) ?? value)
                : value
        }
        guard let identifier, !identifier.isEmpty else { return [] }
        return [.init(text: identifier, weight: .medium)]
    }

    /// Unknown lexicons (and records with no `$type`): any present preview
    /// candidate is searchable, high weight, so nothing is invisible.
    private static func generic(_ content: ZatJSONValue) -> [FieldWeightedText] {
        let candidates = ["text", "displayName", "name", "handle", "description", "title"]
        return candidates.compactMap { key in
            guard let text = content[key]?.stringValue, !text.isEmpty else { return nil }
            return FieldWeightedText(text: text, weight: .high)
        }
    }
}

/// One searchable text field with its match weight.
public struct FieldWeightedText: Sendable, Equatable, Codable {
    /// The raw text (not lowercased — the matcher lowercases at query time,
    /// so the index stays lossless for display).
    public let text: String
    /// How strongly a match in this field should count toward ranking.
    public let weight: Weight

    public init(text: String, weight: Weight) {
        self.text = text
        self.weight = weight
    }

    public enum Weight: String, Sendable, Equatable, Codable {
        case high, medium, low

        /// Rank weight used in scoring (high 3, medium 2, low 1).
        var score: Int {
            switch self {
            case .high: return 3
            case .medium: return 2
            case .low: return 1
            }
        }
    }
}
