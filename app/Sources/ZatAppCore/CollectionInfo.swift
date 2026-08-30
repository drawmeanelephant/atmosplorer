import Foundation

/// Display metadata for a repo collection (an NSID like
/// `app.bsky.feed.post`), mapping the raw identifier to a human label, an
/// SF Symbol, and the icon tint used across the sidebar and record rows.
///
/// Unknown collections fall back to a neutral "Records" row showing the raw
/// NSID, so the app never breaks on a new lexicon — it just shows the
/// identifier until/unless a catalog entry is added.
public struct CollectionInfo: Sendable, Equatable {
    /// Raw NSID, e.g. `app.bsky.feed.post`.
    public let nsid: String
    /// Human label, e.g. "Posts".
    public let label: String
    /// SF Symbol name for the row icon.
    public let symbol: String
    /// Which of a few generic tint buckets the row falls into, so related
    /// collections share a color without per-NISD hex values.
    public let tint: Tint

    public enum Tint: String, Sendable, Equatable {
        case blue, green, purple, orange, red, teal, gray

        var colorName: String {
            switch self {
            case .blue: return "blue"
            case .green: return "green"
            case .purple: return "purple"
            case .orange: return "orange"
            case .red: return "red"
            case .teal: return "teal"
            case .gray: return "gray"
            }
        }
    }

    /// Look up a collection, falling back to a neutral "Records" descriptor.
    public static func info(for nsid: String) -> CollectionInfo {
        catalog[nsid] ?? CollectionInfo(
            nsid: nsid, label: "Records", symbol: "tray.full", tint: .gray)
    }
}

public extension CollectionInfo.Tint {
    /// Whether this tint should use a solid (filled) style. A tiny central
    /// switch so views render fills for the colored buckets and outline for
    /// gray (the "unknown/neutral" bucket).
    var isFilled: Bool { self != .gray }
}

private extension CollectionInfo {
    /// Known AT Protocol collections, keyed by NSID. Unknown NSIDs fall back
    /// to the neutral entry above.
    static let catalog: [String: CollectionInfo] = [
        // Feed
        "app.bsky.feed.post": .init(nsid: "app.bsky.feed.post", label: "Posts", symbol: "text.bubble", tint: .blue),
        "app.bsky.feed.like": .init(nsid: "app.bsky.feed.like", label: "Likes", symbol: "heart", tint: .red),
        "app.bsky.feed.repost": .init(nsid: "app.bsky.feed.repost", label: "Reposts", symbol: "arrow.2.squarepath", tint: .green),
        "app.bsky.feed.threadgate": .init(nsid: "app.bsky.feed.threadgate", label: "Thread gates", symbol: "lock", tint: .gray),
        "app.bsky.feed.postgate": .init(nsid: "app.bsky.feed.postgate", label: "Post gates", symbol: "lock.rectangle.stack", tint: .gray),
        "app.bsky.feed.feed": .init(nsid: "app.bsky.feed.feed", label: "Feeds", symbol: "rectangle.3.group", tint: .teal),
        "app.bsky.feed.generator": .init(nsid: "app.bsky.feed.generator", label: "Feed generators", symbol: "bolt", tint: .teal),
        "app.bsky.feed.savedfeed": .init(nsid: "app.bsky.feed.savedfeed", label: "Saved feeds", symbol: "bookmark", tint: .teal),

        // Graph
        "app.bsky.graph.follow": .init(nsid: "app.bsky.graph.follow", label: "Follows", symbol: "person.crop.circle.badge.plus", tint: .green),
        "app.bsky.graph.starterpack": .init(nsid: "app.bsky.graph.starterpack", label: "Starter packs", symbol: "sparkles", tint: .purple),
        "app.bsky.graph.list": .init(nsid: "app.bsky.graph.list", label: "Lists", symbol: "list.bullet.rectangle", tint: .purple),
        "app.bsky.graph.listitem": .init(nsid: "app.bsky.graph.listitem", label: "List items", symbol: "checkmark.circle", tint: .purple),
        "app.bsky.graph.block": .init(nsid: "app.bsky.graph.block", label: "Blocks", symbol: "hand.raised", tint: .red),

        // Actor
        "app.bsky.actor.profile": .init(nsid: "app.bsky.actor.profile", label: "Profile", symbol: "person.crop.circle", tint: .blue),
        "app.bsky.actor.defs": .init(nsid: "app.bsky.actor.defs", label: "Actor", symbol: "person.2", tint: .blue),

        // Labeler
        "app.bsky.labeler.service": .init(nsid: "app.bsky.labeler.service", label: "Labeler", symbol: "checkmark.seal", tint: .purple),
    ]
}