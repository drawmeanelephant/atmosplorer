import Zat
import Foundation
import ZatAppCore

/// Drives the window's main flow: take a handle/DID, resolve it to an
/// identity, describe its repo, and expose the collection list for the
/// records walk. Holds the bootstrap session so the records view can reuse it.
@MainActor
final class RootModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var identity: ZatIdentity?
    @Published var description: ZatRepoDescription?
    @Published var selectedCollection: String?
    @Published var errorMessage: String?

    /// The bootstrap session (bound to an appview); reused by child views.
    private(set) var session: AppSession?

    var isLoading: Bool { phase == .loading }

    /// Resolve `input` (handle or DID) and load its collections.
    func explore(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isLoading else { return }

        phase = .loading
        errorMessage = nil
        identity = nil
        description = nil
        selectedCollection = nil
        session = nil

        do {
            // Public bootstrap reads are served by an appview; a later
            // milestone can resolve against the handle's own host.
            let bootstrap = try AppSession(host: "https://bsky.social")
            let resolved = try await bootstrap.resolveIdentity(trimmed)
            let repo = try await bootstrap.describeRepo(resolved.did)
            session = bootstrap
            identity = resolved
            description = repo
            selectedCollection = repo.collections.first
            phase = .loaded
        } catch let error as AppError {
            phase = .failed(error.userMessage)
            errorMessage = error.userMessage
        } catch {
            phase = .failed("Something unexpected went wrong.")
            errorMessage = "Something unexpected went wrong."
        }
    }
}
