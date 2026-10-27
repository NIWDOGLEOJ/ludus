# Dependency and licensing audit

This is an initial audit boundary, not legal advice and not a final redistribution approval.

## Current repository dependencies

The initial app uses Apple platform frameworks only:

- Swift standard library
- Foundation
- CryptoKit
- SwiftUI

No third-party runtime, launcher, binary, or game content is bundled by this repository.

The Heroic integration invokes the executable already present inside a user-installed Heroic application. It does not copy, redistribute, or link Heroic or Legendary into Overcross. The user remains responsible for installing Heroic under its own license and completing Epic authentication there.

## Components requiring a separate review

Before bundling or redistributing any of the following, record the exact upstream project, version, license, notices, source obligations, and distribution permission:

- Wine and any selected Wine distribution.
- DXVK or other Direct3D translation components.
- D3DMetal or any related distribution component.
- MoltenVK, if used.
- Heroic Games Launcher or an integration library.
- Steam or Epic launcher binaries and their terms of use.

The project must distinguish between “can interoperate with an installed component” and “may redistribute this component.” The former does not imply the latter.

## Security review requirements

- Verify downloaded runtime archives with signatures or checksums where available.
- Pin versions and record provenance.
- Do not execute arbitrary community scripts automatically.
- Validate executable paths and subprocess arguments.
- Keep credentials and reusable tokens in Keychain only when the selected supported flow permits it.
- Do not upload logs or host information without explicit consent.

## Release gate

No runtime or launcher should be shipped in an Overcross release until a maintainer has completed the exact-version licensing and distribution review and added the resulting notices to the release artifact.
