import Foundation

struct AntiCheatStatus: Equatable, Hashable, Sendable {
    let requiresKernelAntiCheat: Bool
    let antiCheatName: String?
    let warningMessage: String?

    static let supported = AntiCheatStatus(
        requiresKernelAntiCheat: false,
        antiCheatName: nil,
        warningMessage: nil
    )

    static func unsupported(name: String) -> AntiCheatStatus {
        AntiCheatStatus(
            requiresKernelAntiCheat: true,
            antiCheatName: name,
            warningMessage: "Requires \(name) (kernel driver), which cannot run under macOS compatibility layers. Downloading is not recommended."
        )
    }
}

struct AntiCheatRegistry: Sendable {
    private static let knownTitles: [(pattern: String, antiCheat: String)] = [
        ("fortnite", "Easy Anti-Cheat / BattlEye"),
        ("valorant", "Riot Vanguard"),
        ("destiny 2", "BattlEye"),
        ("rainbow six", "BattlEye"),
        ("pubg", "BattlEye / Wellbia"),
        ("apex legends", "Easy Anti-Cheat"),
        ("fall guys", "Easy Anti-Cheat"),
        ("genshin impact", "HoYoverse Anti-Cheat"),
        ("warzone", "Ricochet Anti-Cheat"),
        ("call of duty", "Ricochet Anti-Cheat"),
        ("ea sports fc", "EA AntiCheat"),
        ("fifa", "EA AntiCheat"),
        ("dead by daylight", "Easy Anti-Cheat"),
        ("rust", "Easy Anti-Cheat"),
        ("helldivers 2", "nProtect GameGuard")
    ]

    private static let knownSteamAppIDs: [String: String] = [
        "392100": "BattlEye (Destiny 2)",
        "359550": "BattlEye (Rainbow Six Siege)",
        "578080": "BattlEye (PUBG)",
        "1172470": "Easy Anti-Cheat (Apex Legends)",
        "563720": "Easy Anti-Cheat (Fall Guys)",
        "381210": "Easy Anti-Cheat (Dead by Daylight)",
        "252490": "Easy Anti-Cheat (Rust)",
        "553850": "nProtect GameGuard (Helldivers 2)"
    ]

    static func inspect(title: String, storeApplicationID: String? = nil) -> AntiCheatStatus {
        if let appID = storeApplicationID, let antiCheat = knownSteamAppIDs[appID] {
            return .unsupported(name: antiCheat)
        }

        let lower = title.lowercased()
        for (pattern, name) in knownTitles {
            if lower.contains(pattern) {
                return .unsupported(name: name)
            }
        }

        return .supported
    }
}
