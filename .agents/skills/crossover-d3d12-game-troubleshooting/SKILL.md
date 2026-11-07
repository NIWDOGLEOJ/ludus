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

## 4. AMD AGS & Vendor-Extension Failure (`REASON="NoDevice"` / Exit Status 1 at ~800–900 MB RAM)
* **Symptom**: Game loads splash screen, allocates ~800–900 MB RAM, and cleanly terminates with exit code 1 or log notes stating `REASON="NoDevice"`.
* **Diagnosis**:
  - Direct3D 12 adapter reports AMD vendor ID `0x1002` by default on Apple Silicon D3DMetal.
  - The game detects AMD and attempts to initialize AMD GPU Services (`amd_ags_x64.dll`).
  - D3DMetal does not support AMD proprietary driver extensions (`Amdrx64.dll`), causing `agsInitialize` to fail. The engine fails its hardware profile check and deliberately terminates.
* **Resolution**:
  - Automatically spoof an **NVIDIA RTX 4070** profile for any non-Sony title shipping `amd_ags_x64.dll` or `amd_ags.dll` (e.g. Forza series):
    - `D3DM_VENDOR_ID="0x10de"`
    - `D3DM_DEVICE_ID="0x2786"`
    - `D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 4070"`
    - `D3DM_MULTITHREADED_INTERFACE_ENABLE="0"`
    - `D3DM_ENABLE_ASYNC_COMMIT="0"`
    - `HB_D3D12_TSSHIM="1"`
  - This causes the engine to bypass AMD AGS paths and safely invoke standard `D3D12CreateDevice`.

## 5. Bundled MSVC 2015–2022 Runtime Mismatch (`0xC0000005` in `concrt140.dll` at ~36 MB RAM)
* **Symptom**: Game process aborts within 1–2 seconds at ~36 MB RAM with an unhandled access violation `0xC0000005` inside `concrt140.dll`.
* **Diagnosis**:
  - Wine's built-in `concrt140.dll` / `vcruntime140.dll` has an ABI mismatch with titles compiled against modern MSVC 2015–2022 CRT builds.
* **Resolution**:
  - Inspect the game directory for bundled MSVC DLLs (`concrt140.dll`, `msvcp140.dll`, `vcruntime140.dll`).
  - Inject native overrides into `WINEDLLOVERRIDES`:
    `concrt140,msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,msvcp140_codecvt_ids,vcruntime140,vcruntime140_1,vcruntime140_threads=native,builtin`
  - Renaming bundled `d3d12core.dll` to `.bak` is also required if the game bundles Microsoft Agility SDK binaries to prevent initialization conflicts.
