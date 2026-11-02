# Nixxes & Sony D3D12 Game Compatibility Rules

When developing, optimizing, or configuring launch pipelines for Windows DirectX 12 titles (especially Nixxes/Sony PC ports such as Spider-Man, Ratchet & Clank, Ghost of Tsushima, Horizon) on Apple Silicon:

1. **Essential DLL Preservation**:
   - Never neutralize or rename `sl.interposer.dll` to `.bak`.
   - Never disable `sl.interposer` in `WINEDLLOVERRIDES`.
   - `sl.interposer.dll` is an essential Direct3D 12 and DXGI veneer through which the game delay-loads `D3D12SerializeRootSignature` and `D3D12CreateDevice`. Removing it triggers Windows exception `0xc06d007e` (`ERROR_MOD_NOT_FOUND`).
   - Only disable/neutralize vendor-specific DLSS modules: `nvngx.dll`, `nvngx_dlss.dll`, `nvngx_dlssd.dll`, `nvngx_dlssg.dll`, `sl.dlss.dll`, `sl.dlss_d.dll`.

2. **Audio Channel Topology & Buffer Latency**:
   - `[Software\Wine\DirectSound]\SpeakerConfig` must default to `dword:00000002` (DSSPEAKER_STEREO), never quad or surround (`dword:00000004`), when targeting macOS 2-channel speaker/headphone devices.
   - For high-CPU D3D12 games, ensure `STAGING_AUDIO_DURATION=100000` (100 ms buffer headroom) is injected to prevent CoreAudio buffer underrun clicks.
   - DualSense controller speaker mode must be disabled in-game to prevent packet dropping over Wine.

3. **Swapchain Thread-Safety**:
   - Ensure CrossOver `winemac.so` has the `dispatch_once` thread-safety patch applied to prevent multi-threaded reentrancy SEH loops in `macdrv_app_icon` during window/swapchain initialization.
