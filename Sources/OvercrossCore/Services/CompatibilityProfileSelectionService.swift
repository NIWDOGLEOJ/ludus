import Foundation

struct CompatibilityProfileSelectionService: Sendable {
    func verifiedProfile(
        for game: Game,
        profiles: [CompatibilityProfile]
    ) -> CompatibilityProfile? {
        if let appID = game.storeApplicationID {
            if let matched = profiles.first(where: {
                $0.store == game.store &&
                $0.storeApplicationID == appID &&
                $0.isVerified
            }) {
                return matched
            }
        }

        // Automatic fallback to TitleOptimizationRegistry (Proton & steamac database)
        if let rule = TitleOptimizationRegistry.rule(forAppID: game.storeApplicationID, executablePath: game.executableURL?.path) {
            var env = rule.additionalEnvironment
            if let level = rule.vkd3dFeatureLevel {
                env["VKD3D_FEATURE_LEVEL"] = level
            }
            if let sm = rule.vkd3dShaderModel {
                env["VKD3D_SHADER_MODEL"] = sm
            }
            if let ext = rule.vkd3dDisableExtensions {
                env["VKD3D_DISABLE_EXTENSIONS"] = ext
            }
            if rule.dxvkAsync == true {
                env["DXVK_ASYNC"] = "1"
            }

            return CompatibilityProfile(
                id: UUID(),
                store: game.store,
                storeApplicationID: game.storeApplicationID,
                executableRelativePath: nil,
                graphicsBackend: rule.recommendedBackend ?? .automatic,
                dependencies: [],
                launchArguments: rule.recommendedArguments,
                environment: env,
                knownWorkarounds: [rule.notes].filter { !$0.isEmpty },
                knownIssues: [],
                testEnvironment: "Overcross Title Optimization Registry",
                testResult: .working
            )
        }

        return nil
    }
}
