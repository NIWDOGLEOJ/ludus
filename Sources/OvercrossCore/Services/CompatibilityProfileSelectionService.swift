import Foundation

struct CompatibilityProfileSelectionService: Sendable {
    func verifiedProfile(
        for game: Game,
        profiles: [CompatibilityProfile]
    ) -> CompatibilityProfile? {
        guard let appID = game.storeApplicationID else { return nil }
        return profiles.first {
            $0.store == game.store &&
            $0.storeApplicationID == appID &&
            $0.isVerified
        }
    }
}
