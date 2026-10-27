# Repository architecture

## Module boundaries

```text
OvercrossCore (Swift Library Target - Swift 6 Sendable & Concurrency)
├── Models
│   ├── Game.swift                    Store-neutral game records, platform & ownership evidence
│   ├── WinePrefix.swift              Prefix architectures, paths, and metadata
│   ├── RuntimeInfo.swift             Detected & verified runtime models
│   ├── CompatibilityProfile.swift    Profiles, backends, and verification evidence
│   ├── DownloadOperation.swift       Operation kinds, states, fractions, and detail logs
│   ├── PerformanceSnapshot.swift     Host and process memory/uptime telemetry
│   ├── LaunchLogRecord.swift         Bounded execution output and exit status
│   └── AppSettings.swift             Settings, directories, and feature flags
├── Services
│   ├── ProcessRunner.swift           Bounded subprocess execution & cancellation
│   ├── KeychainSecretStore.swift     macOS Keychain API storage for sensitive tokens
│   ├── SteamAccountStore.swift       SteamID persistence and Keychain integration
│   ├── SteamOpenIDService.swift      Loopback HTTP server (NWListener) on ephemeral ports
│   ├── SteamWebAPIClient.swift       Documented POST visible-library discovery
│   ├── SteamLibraryImporter.swift    Selected local appmanifest parser
│   ├── SteamLaunchService.swift      steam://run/<AppId> URL builder & launcher
│   ├── HeroicLibraryImporter.swift   User-selected installed.json parser
│   ├── HeroicLibraryService.swift    Legendary JSON library listing bridge
│   ├── HeroicGameInfoService.swift   Legendary JSON size metadata & storage preflight
│   ├── HeroicInstallService.swift    Legendary install bridge with progress streaming
│   ├── HeroicUninstallService.swift  Confirmed Legendary removal & state verification
│   ├── HeroicMoveService.swift       Legendary move bridge with destination validation
│   ├── HeroicLaunchService.swift     Heroic custom scheme URL builder & launcher
│   ├── DownloadOperationStore.swift  Bounded ISO-8601 operation history persistence
│   ├── GameLibraryStore.swift        Application Support JSON library persistence
│   ├── GameLibraryMergeService.swift Multi-source deduplication & executable promotion
│   ├── GameLaunchService.swift       Validated execution, bounded pipes, and Wine guards
│   ├── RuntimeDiagnosticsService.swift System architecture, Wine, and toolchain discovery
│   ├── RuntimeStore.swift            User-selected runtime records persistence
│   ├── RuntimeBundleInstaller.swift  Verified SHA-256 runtime bundle importer
│   ├── WinePrefixService.swift       wineboot -i prefix initialization & verification
│   ├── WinePrefixStore.swift         Prefix registration & JSON persistence
│   ├── WinePrefixArchiveService.swift Safe prefix backup, restore & path-checked deletion
│   ├── CompatibilityProfileStore.swift ISO-8601 profile library import & persistence
│   ├── CompatibilityProfileSelectionService.swift Exact-match verified-profile gating
│   ├── NotificationService.swift     Native UserNotifications integration
│   ├── StorageUsageService.swift     Directory sizing & disk space measurement
│   ├── StorageVolumeService.swift    macOS volume URL capacity queries
│   └── ApplicationCacheService.swift Dedicated ~/Library/Caches/Overcross management
└── ViewModels
    └── AppModel.swift                @MainActor observable state orchestrator

OvercrossApp (macOS GUI Executable Target)
├── OvercrossApp.swift                App entry point and scene configuration
└── Views
    ├── ContentView.swift             Navigation split view, sidebar, and detail host
    ├── HomeView.swift                Library summaries, storage, and quick actions
    ├── LibraryViews.swift            Game grid/list, filtering, sorting, and game details
    ├── SystemViews.swift             Runtime manager, prefix manager, downloads, settings
    ├── DiagnosticsView.swift         Host environment, runtime inventory & launch logs
    └── SharedViews.swift             Reusable cards, badges, pickers, and alerts

OvercrossTestRunner (Standalone CLI Test Executable)
├── XCTestShim.swift                  In-process test assertions & reporting engine
├── GameLibraryStoreTests.swift       57 comprehensive unit tests for all domain logic
└── main.swift                        CLI runner reporting execution timings and results

Packaging
└── scripts/package-app.sh            SwiftPM executable to macOS .app bundle wrapper
```

## Data flow

```text
Store adapter -> normalized Game records -> unified library UI
                                         -> compatibility profile lookup
                                         -> installation manager
Runtime manager -> verified runtime/prefix records -> launch configuration
Process manager -> stdout/stderr + exit status -> launch result + diagnostics
Steam OpenID browser session -> verified SteamID -> optional Web API library discovery
Steam local importer -> selected app manifests -> normalized Steam records
Steam game launch -> steam://run/<AppId> -> Steam-managed authentication/DRM/process
Epic handoff -> installed Heroic application -> user-managed authentication/launch
Heroic local importer -> selected installed.json -> installed Epic evidence only
Epic account discovery -> selected Heroic config -> Legendary JSON library output -> normalized Epic records
Epic game launch -> Heroic launch URL -> Heroic-managed authentication/DRM/prefix/process
Epic game install -> user-selected installed.json parent -> Heroic bundled Legendary -> installed.json verification -> normalized installed record
Epic game uninstall -> explicit confirmation -> Heroic bundled Legendary -> installed.json/file verification -> normalized local state
```

Store adapters must not own compatibility logic. Compatibility services must not invent entitlements or download store content. The installation manager must report the state returned by the actual operation and must not use elapsed time as a substitute for progress. The optional Heroic install bridge invokes only a user-installed bundled Legendary executable, reuses the configuration directory selected by the user, and never reads or stores credentials. Compatibility profiles enter through an explicit user-selected JSON import and are launch-selectable only when their exact game match, result, and test-environment evidence satisfy the conservative selector. The local import paths are deliberately separate from store ownership: selecting an executable or importing Heroic's installed cache never implies that the user owns a store entitlement or that the game is compatible.

## Initial implementation choices

- `@MainActor` owns UI-facing state.
- Models are `Codable` where persistence or diagnostic export will eventually require it.
- Runtime checks are read-only unless the user explicitly creates, restores, or removes a managed prefix.
- Empty states are honest: no mock accounts, games, progress, or compatibility results.
- Settings, game metadata, prefixes, profiles, launch logs, and bounded download-operation history are local JSON/Keychain-backed persistence surfaces; schema migrations remain future work.
- Application cache cleanup is deliberately scoped to a dedicated Overcross-owned directory; it never treats game, prefix, runtime, log, or settings paths as cache content.
