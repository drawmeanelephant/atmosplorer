import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for the collection label catalog (`CollectionInfo`) and the
/// type-aware record extraction (`RecordContent`) that turns posts, likes,
/// follows, and starter packs into something browseable instead of raw JSON.
final class RecordContentTests: XCTestCase {
    // MARK: CollectionInfo

    func testKnownCollectionsGetHumanLabels() {
        XCTAssertEqual(CollectionInfo.info(for: "app.bsky.feed.post").label, "Posts")
        XCTAssertEqual(CollectionInfo.info(for: "app.bsky.feed.like").label, "Likes")
        XCTAssertEqual(CollectionInfo.info(for: "app.bsky.graph.follow").label, "Follows")
        XCTAssertEqual(CollectionInfo.info(for: "app.bsky.graph.starterpack").label, "Starter packs")
        XCTAssertEqual(CollectionInfo.info(for: "app.bsky.actor.profile").label, "Profile")
        XCTAssertEqual(CollectionInfo.info(for: "app.bsky.feed.post").symbol, "text.bubble")
        XCTAssertNotEqual(CollectionInfo.info(for: "app.bsky.feed.like").tint, .gray)
    }

    // MARK: referenced person identifiers (mirror pruning)

    /// The rule that decides who survives a re-mirror: likes point at the
    /// authority of a record URI, follows/blocks at the subject DID, and
    /// non-interaction records reference nobody.
    func testReferencedPersonIdentifiers() {
        // A like's subject is a record URI → the person is its authority.
        XCTAssertEqual(
            RecordContent(value: [
                "$type": "app.bsky.feed.like",
                "subject": ["uri": "at://alice.bsky.social/app.bsky.feed.post/abc", "cid": "bafy"],
            ]).referencedPersonIdentifiers,
            ["alice.bsky.social"])

        // A repost's subject is a record URI → the person is its authority too.
        XCTAssertEqual(
            RecordContent(value: [
                "$type": "app.bsky.feed.repost",
                "subject": ["uri": "at://bob.bsky.social/app.bsky.feed.post/xyz", "cid": "bafy"],
            ]).referencedPersonIdentifiers,
            ["bob.bsky.social"])

        // A follow's subject is a bare DID.
        XCTAssertEqual(
            RecordContent(value: ["$type": "app.bsky.graph.follow", "subject": "did:plc:alice"]).referencedPersonIdentifiers,
            ["did:plc:alice"])

        // A block's subject is a DID too.
        XCTAssertEqual(
            RecordContent(value: ["$type": "app.bsky.graph.block", "subject": ["did": "did:plc:bob"]]).referencedPersonIdentifiers,
            ["did:plc:bob"])

        // A starter pack's feeds are *entities*, not people — they must NOT
        // land in the person set (so they never share the account cache).
        let pack = RecordContent(value: [
            "$type": "app.bsky.graph.starterpack",
            "name": "Picks",
            "feeds": [
                ["uri": "at://did:plc:feedgen/app.bsky.feed.generator/abc", "cid": "bafy"],
                "did:plc:otherfeed",
            ],
        ])
        XCTAssertTrue(pack.referencedPersonIdentifiers.isEmpty)
        XCTAssertEqual(
            pack.referencedEntityIdentifiers,
            ["did:plc:feedgen", "did:plc:otherfeed"])

        // Posts and unknown lexicons reference nobody.
        XCTAssertEqual(
            RecordContent(value: ["$type": "app.bsky.feed.post", "text": "hi"]).referencedPersonIdentifiers,
            [])
        XCTAssertEqual(
            RecordContent(value: ["$type": "com.example.widget", "handle": "alice"]).referencedPersonIdentifiers,
            [])
    }

    func testRepostExtractsSubjectURI() {
        let content = RecordContent(value: [
            "$type": "app.bsky.feed.repost",
            "subject": ["uri": "at://bob.bsky.social/app.bsky.feed.post/xyz", "cid": "bafy"],
        ])
        guard case .repost(let repost) = content.kind else {
            return XCTFail("expected repost, got \(content.kind)")
        }
        XCTAssertEqual(repost.subjectURI, "at://bob.bsky.social/app.bsky.feed.post/xyz")
        XCTAssertEqual(content.preview, "Reposted at://bob.bsky.social/app.bsky.feed.post/xyz")
    }

    func testStarterPackFeedsExtractIdentifiers() {
        let content = RecordContent(value: [
            "$type": "app.bsky.graph.starterpack",
            "name": "Picks",
            "feeds": [
                ["uri": "at://did:plc:feedgen/app.bsky.feed.generator/abc", "cid": "bafy"],
                "did:plc:otherfeed",
                "https://example.com/feed",  // no identity → dropped
            ],
            "listItems": [["uri": "at://x/1"]],
        ])
        guard case .starterPack(let pack) = content.kind else {
            return XCTFail("expected starterPack, got \(content.kind)")
        }
        XCTAssertEqual(pack.feeds, ["did:plc:feedgen", "did:plc:otherfeed"])
        XCTAssertEqual(pack.listItems, 1)
    }

    func testUnknownCollectionFallsBackToNeutralLabel() {
        let info = CollectionInfo.info(for: "com.example.weird.widget")
        XCTAssertEqual(info.label, "Records")
        XCTAssertEqual(info.tint, .gray)
        XCTAssertEqual(info.symbol, "tray.full")
    }

    // MARK: posts

    func testPostExtractsText() {
        let content = RecordContent(value: [
            "$type": "app.bsky.feed.post",
            "text": "hello world",
            "createdAt": "2026-08-28T12:00:00Z",
        ])
        guard case .post(let post) = content.kind else {
            return XCTFail("expected post, got \\(content.kind)")
        }
        XCTAssertEqual(post.text, "hello world")
        XCTAssertEqual(content.preview, "hello world")
        XCTAssertNil(post.external)
        XCTAssertNil(post.quote)
        XCTAssertTrue(post.images.isEmpty)
    }

    func testPostEmbeddedExternalLink() {
        let content = RecordContent(value: [
            "$type": "app.bsky.feed.post",
            "text": "",
            "embed": [
                "external": [
                    "title": "Some Site",
                    "uri": "https://example.com/x",
                    "description": "A link card",
                    "thumb": ["href": "https://example.com/x.jpg"],
                ],
            ],
        ])
        guard case .post(let post) = content.kind else {
            return XCTFail("expected post")
        }
        XCTAssertEqual(post.external?.title, "Some Site")
        XCTAssertEqual(post.external?.uri, "https://example.com/x")
        XCTAssertEqual(post.external?.thumbURI, "https://example.com/x.jpg")
        // Empty text falls back to the link card title for the row preview.
        XCTAssertEqual(content.preview, "Some Site")
    }

    func testPostEmbeddedImagesCaptureAltAndAspectRatio() {
        let content = RecordContent(value: [
            "$type": "app.bsky.feed.post",
            "text": "look",
            "embed": [
                "images": [
                    [
                        "alt": "a cat",
                        "aspectRatio": ["width": 16, "height": 9],
                    ],
                    ["alt": ""],
                ],
            ],
        ])
        guard case .post(let post) = content.kind else { return XCTFail("expected post") }
        XCTAssertEqual(post.images.count, 2)
        XCTAssertEqual(post.images[0].alt, "a cat")
        XCTAssertEqual(post.images[0].aspectRatio, "16×9")
        XCTAssertEqual(post.images[1].alt, "")
        XCTAssertNil(post.images[1].aspectRatio)
    }

    func testPostEmbeddedQuoteResolvesRecordRef() {
        let uri = "at://did:plc:alice/app.bsky.feed.post/abc"
        let content = RecordContent(value: [
            "$type": "app.bsky.feed.post",
            "text": "quoting this",
            "embed": ["record": ["uri": .string(uri), "cid": "bafy-quote"]],
        ])
        guard case .post(let post) = content.kind else { return XCTFail("expected post") }
        XCTAssertEqual(post.quote, uri)
    }

    func testPostQuoteCanBePlainStringOnOlderRecords() {
        let uri = "at://did:plc:alice/app.bsky.feed.post/abc"
        let content = RecordContent(value: [
            "$type": "app.bsky.feed.post",
            "text": "quoting",
            "embed": ["record": .string(uri)],
        ])
        guard case .post(let post) = content.kind else { return XCTFail("expected post") }
        XCTAssertEqual(post.quote, uri)
    }

    // MARK: likes

    func testLikeResolvesRecordSubjectURI() {
        let content = RecordContent(value: [
            "$type": "app.bsky.feed.like",
            "subject": ["uri": "at://did:plc:alice/app.bsky.feed.post/abc", "cid": "bafy-1"],
            "createdAt": "2026-08-27T01:30:00Z",
        ])
        guard case .like(let like) = content.kind else { return XCTFail("expected like") }
        XCTAssertEqual(like.subjectURI, "at://did:plc:alice/app.bsky.feed.post/abc")
        XCTAssertEqual(content.preview, "Liked at://did:plc:alice/app.bsky.feed.post/abc")
    }

    func testLikeFallsBackToDIDSubject() {
        let content = RecordContent(value: [
            "$type": "app.bsky.feed.like",
            "subject": ["did": "did:plc:bob"],
        ])
        guard case .like(let like) = content.kind else { return XCTFail("expected like") }
        XCTAssertNil(like.subjectURI)
        XCTAssertEqual(like.subjectDID, "did:plc:bob")
    }

    // MARK: follows

    func testFollowResolvesSubjectDID() {
        let content = RecordContent(value: [
            "$type": "app.bsky.graph.follow",
            "subject": "did:plc:carol",
        ])
        guard case .follow(let follow) = content.kind else { return XCTFail("expected follow") }
        XCTAssertEqual(follow.subjectDID, "did:plc:carol")
        XCTAssertEqual(content.preview, "Followed did:plc:carol")
    }

    func testFollowObjectSubject() {
        let content = RecordContent(value: [
            "$type": "app.bsky.graph.follow",
            "subject": ["did": "did:plc:dave"],
        ])
        guard case .follow(let follow) = content.kind else { return XCTFail("expected follow") }
        XCTAssertEqual(follow.subjectDID, "did:plc:dave")
    }

    // MARK: blocks

    func testBlockResolvesSubjectDID() {
        let content = RecordContent(value: [
            "$type": "app.bsky.graph.block",
            "subject": "did:plc:mallory",
        ])
        guard case .block(let block) = content.kind else {
            return XCTFail("expected block")
        }
        XCTAssertEqual(block.subjectDID, "did:plc:mallory")
        XCTAssertEqual(content.preview, "Blocked did:plc:mallory")
    }

    // MARK: subject identity (for "as people" resolution)

    func testSubjectIdentityExtractsATURIAuthority() {
        XCTAssertEqual(
            SubjectIdentity.authority(ofATURI: "at://did:plc:alice/app.bsky.feed.post/abc"),
            "did:plc:alice")
        XCTAssertEqual(
            SubjectIdentity.authority(ofATURI: "at://alice.bsky.social/app.bsky.feed.post/x"),
            "alice.bsky.social")
        XCTAssertNil(SubjectIdentity.authority(ofATURI: "https://example.com"))
    }

    func testSubjectIdentityPrefersRecordAuthorOverDirectDID() {
        XCTAssertEqual(
            SubjectIdentity.personIdentifier(uri: "at://did:plc:alice/app.bsky.feed.post/abc", did: nil),
            "did:plc:alice")
        XCTAssertEqual(
            SubjectIdentity.personIdentifier(uri: nil, did: "did:plc:bob"),
            "did:plc:bob")
        XCTAssertNil(SubjectIdentity.personIdentifier(uri: nil, did: nil))
    }

    // MARK: starter packs

    func testStarterPackExtractsNameDescriptionFeeds() {
        let content = RecordContent(value: [
            "$type": "app.bsky.graph.starterpack",
            "name": "Cozy corner",
            "description": "books and tea",
            "listItems": [
                ["uri": "at://did:plc:alice/app.bsky.graph.listitem/1"],
                ["uri": "at://did:plc:bob/app.bsky.graph.listitem/2"],
            ],
            "feeds": [
                ["did": "did:plc:feed1"],
                ["did": "did:plc:feed2"],
            ],
        ])
        guard case .starterPack(let pack) = content.kind else { return XCTFail("expected starter pack") }
        XCTAssertEqual(pack.name, "Cozy corner")
        XCTAssertEqual(pack.description, "books and tea")
        XCTAssertEqual(pack.listItems, 2)
        XCTAssertEqual(pack.feeds, ["did:plc:feed1", "did:plc:feed2"])
        XCTAssertEqual(content.preview, "Cozy corner")
    }

    // MARK: fallback

    func testUnknownRecordFallsBackToGeneric() {
        let content = RecordContent(value: ["someKey": "whatever", "name": "Widget"])
        XCTAssertEqual(content.kind, .generic)
        XCTAssertEqual(content.preview, "Widget")
    }

    func testUnrelatedNSIDIsNotTreatedAsPost() {
        let content = RecordContent(value: ["$type": "com.example.something", "text": "hi"])
        XCTAssertEqual(content.kind, .generic)
        XCTAssertEqual(content.preview, "hi")
    }
}