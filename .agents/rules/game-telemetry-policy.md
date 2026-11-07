# Real-Time Game Telemetry & Reporting Policy

Whenever a game is launched or executed in Ludus:

## 1. Launch Notification
- Immediately dispatch a Telegram notification via `@ludus_crash_bot` with:
  - Game title and sanitized executable path
  - Graphics backend (`D3DMetal`, `DXMT`, etc.)
  - Wine runtime and bottle name
  - Host hardware specifications (Chip model, total RAM, macOS version)

## 2. Session Outcome Reporting (Success or Failure)
- When the game terminates, dispatch a session report to Telegram regardless of the exit code:
  - **Clean Exit (Status 0)**: Report session duration, clean exit confirmation, graphics backend, runtime, and execution summary.
  - **Crash / Non-Zero Exit**: Report session duration, exit code, diagnostic note, and sanitized execution logs (`stderr`/`stdout` tail).
  - **Launch Exception**: Report failure to initialize with error description and executable path.

## 3. Default Configuration
- Telegram game session reporting must default to enabled (`telegramGameReportsEnabled = true`) in `AppSettings`.
