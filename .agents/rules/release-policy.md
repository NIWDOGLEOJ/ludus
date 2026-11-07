# Release & Deployment Policy

Whenever an update, bugfix, or feature is developed in this repository:

1. **Package a Formal Release Artifact**:
   - Always compile and package a formal release artifact inside `dist/` using `scripts/package-dmg.sh` (producing `dist/Ludus.dmg` and `dist/Ludus.app`).
   - Deliver release packages and summaries to `dist/` or `~/Downloads` for the user.
   - Provide clear release update notes describing the changes, fixes, and release binaries.

2. **Strict System App Isolation (Do NOT Modify `/Applications`)**:
   - **NEVER** copy, replace, install, or overwrite `/Applications/Ludus.app` (or any other application on the user's host system) during builds or automated tasks.
   - Keep all build outputs and artifacts strictly inside the project workspace directory (`dist/`).
   - The user retains sole discretion over when and how to install or update the application on their system from the generated release package.
