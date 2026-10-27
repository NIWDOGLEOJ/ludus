# Ludus 🎮

**Ludus** is a high-performance native macOS gaming hub and Windows compatibility platform crafted specifically for Apple Silicon. It unifies legitimate Steam and Epic Games libraries with isolated Windows compatibility environments, native Apple Silicon graphics translation (D3DMetal, DXVK, DXMT, MSync), and automatic in-app updates.

---

## ✨ Features

- **Apple Silicon Native**: Built from the ground up for M1/M2/M3/M4 Macs with full Metal 3, MSync (Mach-port synchronization), and Retina high-DPI scaling support.
- **Unified Game Library**: Seamlessly access and manage both your Steam and Epic Games libraries alongside standalone local Windows titles in a clean, modern poster grid.
- **Zero-Friction Bootstrap**: Automatically provisions and manages Wine-CX runtime components and store bridges into isolated, sandboxed application storage.
- **WoW64 CoreAudio Mach VM Bridge**: Custom Mach virtual-memory audio bridge for 32-bit PE32 titles, eliminating legacy pointer truncation without memory allocation failures.
- **Privacy & Security First**: Never requests or stores Epic or Steam passwords. Integrates via local manifests, standard launch handoffs, and OAuth browser callbacks.
- **Automated GitHub Updates**: Built-in update engine checks for new GitHub Releases, displays update banners, and downloads/mounts the latest release DMG with a single click.

---

## 🚀 Installation

1. Head to the **[Releases](https://github.com/NIWDOGLEOJ/ludus/releases)** section.
2. Download the latest **`Ludus.dmg`**.
3. Open the disk image and drag **Ludus.app** into your **Applications** folder.

---

## 🛠️ Building from Source

### Prerequisites
- macOS 14.4 or newer (Apple Silicon)
- Xcode 16+ or Command Line Tools (Swift 6.0+)

### Commands
```bash
# Clone the repository
git clone https://github.com/NIWDOGLEOJ/ludus.git
cd ludus

# Run the test suite (100 unit tests)
DEVELOPER_DIR="/Volumes/sata ssd 1/Applications/Xcode.app" swift run LudusTestRunner

# Package Ludus.app and Ludus.dmg
zsh scripts/package-dmg.sh

# The packaged DMG will be located at dist/Ludus.dmg
```

---

## 📄 License & Boundaries

Ludus adheres strictly to software boundaries: it does not bypass DRM, anti-cheat, or entitlement verification, does not redistribute third-party proprietary binaries, and delegates account management directly to respective store workflows.
