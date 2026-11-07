# Release & Deployment Policy

Whenever an update, bugfix, or feature is developed in this repository:

## 1. Strict Host System Protection (Never Modify `/Applications`)
- **NEVER** copy, replace, install, or overwrite `/Applications/Ludus.app` (or any other application installed on the user's host machine) during builds or automated tasks.
- Keep all compilation outputs strictly within the workspace directory (`dist/`).
- The user retains sole discretion over when and how to install or update the app on their system from the generated release package.

## 2. Mandatory Full-Spectrum Release Delivery
A release update is only complete when **all** of the following delivery steps are executed:
1. **Package Disk Image**: Build and sign `dist/Ludus.dmg` and `dist/Ludus.app` using `scripts/package-dmg.sh`.
2. **Direct Local Delivery**: Copy `dist/Ludus.dmg` to `$HOME/Downloads/Ludus-v<VERSION>.dmg` for immediate access.
3. **Remote Git Synchronization**: Push commits and version tags to GitHub (`git push origin main <TAG>`).
4. **Publish GitHub Release**: Run `gh release create <TAG> dist/Ludus.dmg --title ... --notes ...` so the in-app updater detects the new version.
5. **Direct Notification & Asset Dispatch**: Upload and send `Ludus.dmg` directly to the user's Telegram chat via `@ludus_crash_bot` using `sendDocument`.
