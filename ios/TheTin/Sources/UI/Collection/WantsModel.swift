import Foundation
import Observation

@MainActor @Observable
final class WantsModel {
    private(set) var wanted: Set<String> = []
    private let repo: WantsRepository
    private let uid: String

    init(repo: WantsRepository, uid: String) {
        self.repo = repo; self.uid = uid
        Task { for await set in repo.stream(uid: uid) { self.wanted = set } }
    }
    func isWanted(_ cardId: String) -> Bool { wanted.contains(cardId) }
    func toggle(_ cardId: String) {
        let next = !wanted.contains(cardId)
        if next { wanted.insert(cardId) } else { wanted.remove(cardId) }   // optimistic
        Task {
            do { try await repo.setWanted(uid: uid, cardId: cardId, wanted: next) }
            catch {
                // Write failed — snap the heart back so the UI never shows a wish that
                // wasn't saved. (The stream would eventually correct it; this is immediate.)
                if next { wanted.remove(cardId) } else { wanted.insert(cardId) }
            }
        }
    }
}
