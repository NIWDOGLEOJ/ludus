# Phase 1 feasibility report

Date: 2026-10-22

## Current host evidence

The development host reports:

- Apple Silicon architecture: `arm64`.
- macOS 27.2 according to `sw_vers`.
- Swift 6.4 is available.
- The active developer directory is Command Line Tools, not the full Xcode application.

The most recent diagnostic build reached source compilation only after redirecting Swift/Clang module caches and disabling SwiftPM's sandbox, then stopped because the Command Line Tools installation could not load SwiftUI's `SwiftUIMacros` plugin for `@State`. This is an environment/toolchain limitation; it is not evidence that the native app has launched.

The last two items are directly observed on this machine. Full app-bundle build, signing, entitlements, and launch verification remain pending until Xcode is installed and selected.

## Feasible scope

The following parts are technically feasible as native Swift/SwiftUI modules:

1. A unified local library model and UI.
2. Persistent metadata, settings, favorites, categories, and user-selected install locations.
3. A runtime and prefix inventory layer that treats compatibility engines as external components.
4. Process launching with validated executable paths and captured stdout/stderr.
5. Store-specific adapters that never expose store credentials to Overcross.
6. Compatibility profiles with explicit provenance, verification date, test environment, and known issues.
7. Storage checks, cancellation state, bounded diagnostics, and native notifications.

## Feasibility risks

The hardest parts are not the SwiftUI shell:

- Steam and Epic authentication, entitlement visibility, and installation workflows must use currently supported mechanisms.
- Windows game execution depends on the game, launcher, DRM, anti-cheat, graphics API, runtime version, and prefix configuration. A library entry is not evidence of compatibility.
- A runtime component may have licensing or redistribution restrictions even when it is technically usable locally.
- Steam and Epic are separate systems and should not be coupled to one shared undocumented API.
- Apple Silicon support and graphics translation behavior must be verified on the exact runtime and macOS version used for testing.

## Current integration evidence

The current research supports these boundaries:

- Steam documents `GetOwnedGames` as an authenticated Web API method that requires a Steam Web API key and a SteamID, and notes that owned-game details depend on the user's library visibility. Steam also documents OpenID as a way to obtain a user's SteamID without asking the application to collect the Steam password. The public Web API host is appropriate for a regular user key; Steam documents the partner host as publisher-key-only. A native client must not embed a private publisher key or bypass privacy settings. See the [Steam IPlayerService documentation](https://partner.steamgames.com/doc/webapi/iplayerservice), [Steam Web API overview](https://partner.steamgames.com/doc/webapi_overview), and [Steam authentication documentation](https://partner.steamgames.com/doc/features/auth).
- Heroic's project documentation describes Epic support on macOS 14 or newer and lists installation, update, repair, move, and import workflows. Its project is GPLv3 and its implementation uses separate launcher components. This makes Heroic a plausible user-installed integration boundary. Overcross's local importer is deliberately user-selected and read-only for library evidence, while the optional install bridge invokes the bundled Legendary executable from an existing Heroic installation and reuses only the configuration directory selected through `installed.json`; Overcross does not implement account authentication or read credentials. See the [Heroic repository](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher) and its [configuration/troubleshooting guidance](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/wiki/Troubleshooting).
- Legendary's maintained command reference documents `list --third-party --platform <Platform> --json` for library discovery and `install <App Name> --base-path <path>` for installation, with `--update-only` available for updates. Overcross therefore treats these as an external, user-installed command boundary and still requires post-operation `installed.json` and filesystem verification before changing local metadata. See the [Legendary command reference](https://github.com/legendary-gl/legendary/blob/master/README.md).
- The original Whisky repository is archived and explicitly says it is no longer actively maintained. Overcross must not select that archived project as an automatic runtime dependency. See the [archived Whisky repository](https://github.com/Whisky-App/Whisky).

These sources are evidence for architecture decisions, not proof that any particular game will run. Runtime and game compatibility still require an actual test on the target Mac.

## Recommended order

1. Keep the current foundation small and buildable.
2. Add a runtime inventory and process-management test harness.
3. Select one supported Epic workflow and document its authentication boundary before coding it.
4. Select one supported Steam workflow and document whether it can install the intended Windows build.
5. Test one known-compatible title, recording the complete environment and result.
6. Only then add unified installation, automatic profiles, and broader library features.

## Claims not made by this repository

This initial version does not claim that any Windows game launches, that Steam or Epic accounts are connected, that a runtime is installed, or that any compatibility profile is verified. Those claims require evidence from a real account and a real test environment.
