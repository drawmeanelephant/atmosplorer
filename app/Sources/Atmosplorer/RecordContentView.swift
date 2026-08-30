import Zat
import SwiftUI
import ZatAppCore

/// Moments the type-aware body renderer is used: a compact list row preview
/// and a full detail view. Keeps the `RecordContentView` measurable while
/// still sharing the same extraction/kind logic.
enum RecordContentPresentation {
    case row
    case detail
}

/// Renders a record body using `RecordContent.Kind`, so posts, likes,
/// follows, and starter packs read as real content rather than raw JSON.
/// Unknown records fall back to a `generic` state. Blobs (images/uploads)
/// are CDN links that only resolve online — offline we show their captions
/// and aspect ratios, not the pixels; live, the same view shows the image via
/// an AsyncImage keyed on the original thumb/link when the embed carried one.
@MainActor
struct RecordContentView: View {
    let content: RecordContent
    var presentation: RecordContentPresentation = .detail

    var body: some View {
        switch content.kind {
        case .post(let post): PostView(post: post, presentation: presentation)
        case .like(let like): LikeView(like: like, presentation: presentation)
        case .repost(let repost): RepostView(repost: repost, presentation: presentation)
        case .follow(let follow): FollowView(follow: follow, content: content, presentation: presentation)
        case .block(let block): BlockView(block: block, content: content, presentation: presentation)
        case .starterPack(let pack): StarterPackView(pack: pack, presentation: presentation)
        case .generic:
            GenericValueView(preview: content.preview, presentation: presentation)
        }
    }
}

// MARK: - Post

private struct PostView: View {
    let post: RecordContent.Post
    let presentation: RecordContentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !post.text.isEmpty {
                Text(post.text)
                    .font(presentation == .row ? .callout : .body)
                    .lineLimit(presentation == .row ? 2 : nil)
                    .textSelection(.enabled)
            }
            if let quote = post.quote {
                quotedRow(quote)
            }
            if let external = post.external {
                externalCard(external)
            }
            if !post.images.isEmpty {
                imagesRow
            }
            if presentation == .detail, let createdAt = RecordContent.dateLabel(post.createdAt) {
                Text(createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func quotedRow(_ uri: String) -> some View {
        Label(uri, systemImage: "quote.opening")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func externalCard(_ external: RecordContent.ExternalLink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let thumb = external.thumbURI, presentation == .detail {
                AsyncImage(url: URL(string: thumb)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(external.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(external.uri)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !external.description.isEmpty {
                    Text(external.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var imagesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(post.images.enumerated().map { $0 }, id: \.offset) { index, image in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.alt.isEmpty ? "Image \(index + 1)" : image.alt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let ratio = image.aspectRatio {
                            Text(ratio)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Like

private struct LikeView: View {
    let like: RecordContent.Like
    let presentation: RecordContentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                SubjectHandleView(
                    identifier: SubjectIdentity.personIdentifier(uri: like.subjectURI, did: like.subjectDID),
                    fallback: like.subjectURI ?? like.subjectDID ?? "a record")
            } icon: {
                Image(systemName: "heart")
            }
            .font(.callout)
            if presentation == .detail, let createdAt = RecordContent.dateLabel(like.createdAt) {
                Text(createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Repost

private struct RepostView: View {
    let repost: RecordContent.Repost
    let presentation: RecordContentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                SubjectHandleView(
                    identifier: SubjectIdentity.personIdentifier(uri: repost.subjectURI, did: nil),
                    fallback: repost.subjectURI ?? "a record")
            } icon: {
                Image(systemName: "arrow.2.squarepath")
            }
            .font(.callout)
            if presentation == .detail, let createdAt = RecordContent.dateLabel(repost.createdAt) {
                Text(createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Follow

private struct FollowView: View {
    let follow: RecordContent.Follow
    let content: RecordContent
    let presentation: RecordContentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                SubjectHandleView(
                    identifier: SubjectIdentity.personIdentifier(uri: nil, did: follow.subjectDID),
                    fallback: follow.subjectDID ?? content.preview)
            } icon: {
                Image(systemName: "person.badge.plus")
            }
            .font(.callout)
            if presentation == .detail, let createdAt = RecordContent.dateLabel(follow.createdAt) {
                Text(createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BlockView: View {
    let block: RecordContent.Block
    let content: RecordContent
    let presentation: RecordContentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                SubjectHandleView(
                    identifier: SubjectIdentity.personIdentifier(uri: nil, did: block.subjectDID),
                    fallback: block.subjectDID ?? content.preview)
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(.callout)
            if presentation == .detail, let createdAt = RecordContent.dateLabel(block.createdAt) {
                Text(createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Generic fallback

private struct GenericValueView: View {
    let preview: String
    let presentation: RecordContentPresentation

    var body: some View {
        if presentation == .row {
            Text(preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            LabeledContent("Body", value: preview)
        }
    }
}

// MARK: - Starter pack

private struct StarterPackView: View {
    let pack: RecordContent.StarterPack
    let presentation: RecordContentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(pack.name.isEmpty ? "Starter pack" : pack.name)
                    .fontWeight(.semibold)
            }
            .font(.callout)
            if presentation == .detail {
                if !pack.description.isEmpty {
                    Text(pack.description)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                Text("\(pack.listItems) accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !pack.feeds.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pack.feeds, id: \.self) { feed in
                            Label {
                                SubjectHandleView(identifier: feed, fallback: feed, isEntity: true)
                            } icon: {
                                Image(systemName: "bolt")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }
}