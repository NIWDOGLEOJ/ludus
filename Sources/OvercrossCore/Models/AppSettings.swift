import Foundation

struct AppSettings: Codable, Equatable {
    var preferredInstallDirectory: URL?
    var heroicLegendaryConfigDirectory: URL?
    var heroicInstallPrerequisites = false
    var performanceMonitoringEnabled = false
    var launchAtLogin = false
    var notificationsEnabled = false

    // Apple Silicon Performance & Gaming Controls
    var metalHUDEnabled = false
    var msyncEnabled = true
    var esyncEnabled = false
    var retinaScalingEnabled = false
    var defaultGraphicsBackend: GraphicsBackend = .automatic

    private static let storageKey = "overcross.settings"

    init(
        preferredInstallDirectory: URL? = nil,
        heroicLegendaryConfigDirectory: URL? = nil,
        heroicInstallPrerequisites: Bool = false,
        performanceMonitoringEnabled: Bool = false,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = false,
        metalHUDEnabled: Bool = false,
        msyncEnabled: Bool = true,
        esyncEnabled: Bool = false,
        retinaScalingEnabled: Bool = false,
        defaultGraphicsBackend: GraphicsBackend = .automatic
    ) {
        self.preferredInstallDirectory = preferredInstallDirectory
        self.heroicLegendaryConfigDirectory = heroicLegendaryConfigDirectory
        self.heroicInstallPrerequisites = heroicInstallPrerequisites
        self.performanceMonitoringEnabled = performanceMonitoringEnabled
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.metalHUDEnabled = metalHUDEnabled
        self.msyncEnabled = msyncEnabled
        self.esyncEnabled = esyncEnabled
        self.retinaScalingEnabled = retinaScalingEnabled
        self.defaultGraphicsBackend = defaultGraphicsBackend
    }

    private enum CodingKeys: String, CodingKey {
        case preferredInstallDirectory
        case heroicLegendaryConfigDirectory
        case heroicInstallPrerequisites
        case performanceMonitoringEnabled
        case launchAtLogin
        case notificationsEnabled
        case metalHUDEnabled
        case msyncEnabled
        case esyncEnabled
        case retinaScalingEnabled
        case defaultGraphicsBackend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredInstallDirectory = try container.decodeIfPresent(URL.self, forKey: .preferredInstallDirectory)
        heroicLegendaryConfigDirectory = try container.decodeIfPresent(URL.self, forKey: .heroicLegendaryConfigDirectory)
        heroicInstallPrerequisites = try container.decodeIfPresent(Bool.self, forKey: .heroicInstallPrerequisites) ?? false
        performanceMonitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .performanceMonitoringEnabled) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        metalHUDEnabled = try container.decodeIfPresent(Bool.self, forKey: .metalHUDEnabled) ?? false
        msyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .msyncEnabled) ?? true
        esyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .esyncEnabled) ?? false
        retinaScalingEnabled = try container.decodeIfPresent(Bool.self, forKey: .retinaScalingEnabled) ?? false
        defaultGraphicsBackend = try container.decodeIfPresent(GraphicsBackend.self, forKey: .defaultGraphicsBackend) ?? .automatic
    }

    static func load() -> AppSettings {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings(
                preferredInstallDirectory: nil,
                heroicLegendaryConfigDirectory: nil
            )
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
