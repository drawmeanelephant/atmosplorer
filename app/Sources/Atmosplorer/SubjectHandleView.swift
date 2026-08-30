import SwiftUI
import ZatAppCore

private struct IdentityResolverKey: EnvironmentKey {
    static let defaultValue: IdentityResolver? = nil
}

extension EnvironmentValues {
    /// A resolver for turning interaction subjects (DIDs / handles) into
    /// human names, injected at the browse root. Serves both people and
    /// entities from one shared cache; views degrade gracefully when it's
    /// absent.
    var identityResolver: IdentityResolver? {
        get { self[IdentityResolverKey.self] }
        set { self[IdentityResolverKey.self] = newValue }
    }
}

/// Shows an interaction subject "as a person": the resolved handle when one
/// is available, otherwise the raw identifier. Resolves lazily and caches via
/// the `IdentityResolver` in the environment; when no resolver is present (or
/// the subject can't be resolved — e.g. fully offline), it just shows the
/// fallback, so the offline browse never depends on the network.
struct SubjectHandleView: View {
    /// The DID/handle to resolve to a person's name.
    let identifier: String?
    /// The raw string to show until/unless `identifier` resolves (and always
    /// when there's no identifier to resolve).
    let fallback: String
    /// Resolve as an entity (starter-pack feed) rather than a person, so the
    /// write-through lands in the entities map instead of the people map.
    /// The shared cache still answers either role without re-resolving.
    var isEntity: Bool = false

    @Environment(\.identityResolver) private var resolver
    @State private var name: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            if identifier != nil && name == nil && resolver != nil {
                ProgressView().controlSize(.mini)
            }
        }
        .task(id: identifier) {
            guard let identifier, let resolver else {
                name = nil
                return
            }
            name = await resolver.person(for: identifier, role: isEntity ? .entity : .person)
        }
    }

    private var displayName: String {
        name ?? fallback
    }
}