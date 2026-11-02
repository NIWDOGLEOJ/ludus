---
name: crossover-d3d12-game-troubleshooting
description: Diagnose and resolve DirectX 12 launch stalls, multi-threaded swapchain deadlocks, delay-load crashes (0xc06d007e), and audio crackling on Apple Silicon (CrossOver / Wine / D3DMetal).
---

# CrossOver / Wine D3D12 Game Troubleshooting Runbook

Use this skill when a Windows D3D12 game running on Apple Silicon via CrossOver or Wine hangs at launch, freezes at a specific memory threshold (~700 MB), crashes with `0xc06d007e`, or experiences audio distortion.

## 1. The ~700 MB Swapchain Hang (Infinite SEH Exception Loop)
* **Symptom**: Process memory caps at ~700 MB RSS. The log shows window creation but hangs before swapchain completion. Log files grow rapidly (GBs of `c0000005` exceptions).
* **Diagnosis**:
  1. Inspect thread stack traces during window creation.
  2. Check if multiple threads (`RenderThread` and `xinput_hid_update`) call `winemac.so!macdrv_app_icon` concurrently.
  3. A null function pointer in `user_callback_handler` triggers `ntdll.dll!RtlVirtualUnwind2` with `r14=0`, creating an infinite unwind loop.
* **Resolution**:
  - In `lib/wine/x86_64-unix/winemac.so`, patch the `helldivers2.exe` conditional branch (`85 c0 74 0f e8 ...`) at offset `+2` from `74 0f` to `eb 1a` (or `eb 32`) to route all executables through the thread-safe `dispatch_once` block.
  - Re-sign with `codesign -f -s - <path_to_winemac.so>`.

## 2. Delay-Load Module Failure (`0xc06d007e`)
* **Symptom**: Log reports `Unhandled exception at address ... (code: 0xc06d007e): "Unknown exception"`.
* **Diagnosis**:
  - `0xc06d007e` is MSVC `VcppException(ERROR_SEVERITY_ERROR, ERROR_MOD_NOT_FOUND)` (error code 126 / `0x7e`).
  - Parse the `.mdmp` ExceptionStream: `ExceptionInformation[0]` is a pointer to `DelayLoadInfo`.
  - Unpack `DelayLoadInfo.szDll` to find which DLL the binary failed to load (e.g., `sl.interposer.dll`).
* **Resolution**:
  - Check whether the DLL was renamed to `.bak` or disabled in `WINEDLLOVERRIDES`.
  - Do NOT disable interposer modules that export DirectX functions (`D3D12SerializeRootSignature`, `D3D12CreateDevice`). Keep them native.

## 3. Audio Crackling, Distortion & Dropouts
* **Symptom**: Game renders smoothly, but audio pops, crackles, or cuts out periodically.
* **Diagnosis & Resolution**:
  1. **DualSense Controller Speaker**: Check if the game is attempting to stream to a controller speaker. Turn **Controller Speaker Mode OFF** in in-game settings.
  2. **Multi-Channel Downmixing**: Set in-game Listening Mode to **Stereo / TV**. Do not use **3D Spatial Audio / Headphones 3D** or **7.1 Surround**.
  3. **DirectSound Stereo Topology**: Ensure `[Software\Wine\DirectSound]\SpeakerConfig` is `dword:00000002` (Stereo), not `dword:00000004`.
  4. **Buffer Headroom**: In `DirectSound`, increase `HelMargin` to `40` (`0x28`) and `SndQueueMax` to `64` (`0x40`). Set environment variable `STAGING_AUDIO_DURATION=100000`.
