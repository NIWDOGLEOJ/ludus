import CryptoKit
import Foundation

/// Applies the permanent WoW64 CoreAudio Mach VM bridge workaround for the
/// verified GPTK 1.1 / Wine 7.7 runtime binary. The source runtime is never
/// modified. A private staged copy is created instead, so the operation is
/// completely reversible by removing the staged directory or selecting the
/// original runtime.
///
/// WoW64 pointer truncation in the original GPTK 1.1 winecoreaudio.so causes
/// 32-bit games like Need for Speed: Most Wanted to receive high-memory pointers
/// truncated to 32 bits, resulting in write access page faults to corrupted addresses
/// (e.g. 0x00000200).
///
/// This service compiles and installs an isolated WoW64 CoreAudio bridge dylib
/// that safely maps 32-bit addressable Mach VM render buffers (< 2 GB) for
/// 32-bit callers while passing 64-bit native calls directly through to the
/// original untouched winecoreaudio_orig.so binary.
struct AudioRepairService: Sendable {
    struct Preparation: Sendable {
        let executableURL: URL
        let status: String
    }

    enum Error: LocalizedError, Sendable {
        case runtimeRootNotFound
        case unsupportedRuntime
        case sourceBinaryUnreadable
        case stagingFailed(String)
        case compilationFailed(String)

        var errorDescription: String? {
            switch self {
            case .runtimeRootNotFound:
                "The selected runtime's Wine bundle could not be located."
            case .unsupportedRuntime:
                "The selected runtime does not match the verified WoW64 CoreAudio repair manifest."
            case .sourceBinaryUnreadable:
                "The runtime's WoW64 winecoreaudio.so could not be read."
            case .stagingFailed(let reason):
                "The isolated audio-repair runtime could not be prepared: \(reason)"
            case .compilationFailed(let reason):
                "The WoW64 CoreAudio bridge compilation failed: \(reason)"
            }
        }
    }

    // These are file offsets for the GPTK 1.1 x86_32on64-unix binary whose
    // SHA-256 is listed below. They are verified before staging.
    private static let allocationZeroBitsOffset = 0x548d
    private static let allocationZeroBitsInstruction = [UInt8](arrayLiteral: 0x41, 0xb8, 0xff, 0xff, 0xff, 0x7f, 0x4c, 0x0f, 0x44, 0xc1)
    private static let renderBufferOffset = 0x6fa7
    private static let renderBufferInstruction = [UInt8](arrayLiteral: 0x89, 0x0a)

    // GPTK 1.1 x86_32on64-unix/winecoreaudio.so observed on the supported
    // runtime. A byte-level match is required before this is used.
    static let supportedSourceSHA256 = "34691d789ff2f8817715f9a895299cbb04369b463daaa7111a8b2fb2396e1947"

    /// Embedded C source code for the WoW64 CoreAudio 32-bit Render Buffer Bridge.
    static let bridgeSourceCode: String = #"""
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <stdint.h>
    #include <dlfcn.h>
    #include <mach/mach.h>
    #include <mach/mach_vm.h>
    #include <pthread.h>

    #define MAX_STREAMS 64
    #define STAGING_BASE_ADDR 0x78000000ULL
    #define STAGING_MAX_ADDR  0x7e000000ULL
    #define STAGING_SLOT_SIZE 0x200000ULL /* 2 MB per audio stream */

    #define STREAM_BUFSIZE_OFFSET     0x58
    #define STREAM_WRI_OFFS_OFFSET    0x68
    #define STREAM_GETBUF_LAST_OFFSET 0x88
    #define STREAM_LOCAL_BUF_OFFSET   0x98

    #define S_OK 0
    #define E_INVALIDARG 0x80070057

    typedef uint32_t NTSTATUS;

    typedef struct {
        void *stream;
        mach_vm_address_t staging_buffer;
        size_t alloc_size;
        char *orig_buffer;
        int in_use;
    } stream_entry_t;

    static stream_entry_t g_streams[MAX_STREAMS];
    static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
    static pthread_mutex_t g_init_mutex = PTHREAD_MUTEX_INITIALIZER;

    static void *orig_handle = NULL;
    static void **orig_unix_funcs = NULL;
    static void **orig_wow64_funcs = NULL;
    static int g_debug_audio = -1;

    typedef NTSTATUS (*unix_func_t)(void *args);

    static int is_debug_audio(void) {
        if (g_debug_audio == -1) {
            const char *env = getenv("OVERCROSS_DEBUG_AUDIO");
            g_debug_audio = (env && (strcmp(env, "1") == 0 || strcmp(env, "true") == 0)) ? 1 : 0;
        }
        return g_debug_audio;
    }

    static void ensure_initialized(void) {
        if (orig_handle) return;
        pthread_mutex_lock(&g_init_mutex);
        if (!orig_handle) {
            setvbuf(stderr, NULL, _IONBF, 0);
            Dl_info info;
            char orig_path[1024];
            if (dladdr((void*)ensure_initialized, &info) && info.dli_fname) {
                strncpy(orig_path, info.dli_fname, sizeof(orig_path) - 32);
                char *slash = strrchr(orig_path, '/');
                if (slash) {
                    strcpy(slash + 1, "winecoreaudio_orig.so");
                } else {
                    strcpy(orig_path, "winecoreaudio_orig.so");
                }
            } else {
                strcpy(orig_path, "winecoreaudio_orig.so");
            }

            orig_handle = dlopen(orig_path, RTLD_NOW | RTLD_LOCAL);
            if (!orig_handle) {
                fprintf(stderr, "[overcross-audio] ERROR: Failed to dlopen %s: %s\n", orig_path, dlerror());
            } else {
                orig_unix_funcs = (void**)dlsym(orig_handle, "__wine_unix_call_funcs");
                orig_wow64_funcs = (void**)dlsym(orig_handle, "__wine_unix_call_wow64_funcs");
                fprintf(stderr, "[overcross-audio] Successfully loaded %s and resolved call tables\n", orig_path);
            }
            fflush(stderr);
        }
        pthread_mutex_unlock(&g_init_mutex);
    }

    static mach_vm_address_t allocate_32bit_buffer(size_t size) {
        for (mach_vm_address_t cand = STAGING_BASE_ADDR; cand <= STAGING_MAX_ADDR; cand += STAGING_SLOT_SIZE) {
            mach_vm_address_t addr = cand;
            kern_return_t kr = mach_vm_allocate(mach_task_self(), &addr, size, VM_FLAGS_FIXED);
            if (kr == KERN_SUCCESS) {
                if (is_debug_audio()) {
                    fprintf(stderr, "[overcross-audio] allocate_32bit_buffer SUCCESS at 0x%llx\n", (unsigned long long)addr);
                    fflush(stderr);
                }
                return addr;
            }
        }
        return 0;
    }

    static void ensure_32bit_local_buffer(void *stream) {
        if (!stream) return;
        char *local_buf = *(char**)((char*)stream + STREAM_LOCAL_BUF_OFFSET);

        if ((uintptr_t)local_buf >= 0x100000000ULL) {
            pthread_mutex_lock(&g_mutex);
            local_buf = *(char**)((char*)stream + STREAM_LOCAL_BUF_OFFSET);
            if ((uintptr_t)local_buf >= 0x100000000ULL) {
                mach_vm_address_t addr = allocate_32bit_buffer(STAGING_SLOT_SIZE);
                if (addr) {
                    memset((void*)addr, 0, STAGING_SLOT_SIZE);

                    for (int i = 0; i < MAX_STREAMS; i++) {
                        if (!g_streams[i].in_use) {
                            g_streams[i].stream = stream;
                            g_streams[i].staging_buffer = addr;
                            g_streams[i].alloc_size = STAGING_SLOT_SIZE;
                            g_streams[i].orig_buffer = local_buf;
                            g_streams[i].in_use = 1;
                            break;
                        }
                    }
                    *(char**)((char*)stream + STREAM_LOCAL_BUF_OFFSET) = (char*)addr;
                    fprintf(stderr, "[overcross-audio] Successfully migrated stream %p local_buffer to 0x%llx (32-bit addressable)\n",
                            stream, (unsigned long long)addr);
                    fflush(stderr);
                } else {
                    fprintf(stderr, "[overcross-audio] CRITICAL: FAILED to allocate 32-bit buffer for stream %p!\n", stream);
                    fflush(stderr);
                }
            }
            pthread_mutex_unlock(&g_mutex);
        }
    }

    static NTSTATUS bridge_wow64_create_stream(void *args) {
        ensure_initialized();
        unix_func_t orig = (unix_func_t)orig_wow64_funcs[1];
        NTSTATUS status = orig(args);

        int32_t result = *(int32_t*)((char*)args + 0x24);
        uint32_t stream_ptr_32 = *(uint32_t*)((char*)args + 0x28);
        void *stream = NULL;
        if (stream_ptr_32) {
            stream = *(void**)(uintptr_t)stream_ptr_32;
        }

        if (is_debug_audio()) {
            fprintf(stderr, "[overcross-audio] wow64_create_stream: status=%u, result=0x%x, stream=%p\n",
                    status, result, stream);
            fflush(stderr);
        }

        if (status == 0 && result == S_OK && stream) {
            ensure_32bit_local_buffer(stream);
        }
        return status;
    }

    static NTSTATUS bridge_wow64_release_stream(void *args) {
        ensure_initialized();
        void *stream = *(void**)args;
        if (stream) {
            pthread_mutex_lock(&g_mutex);
            for (int i = 0; i < MAX_STREAMS; i++) {
                if (g_streams[i].in_use && g_streams[i].stream == stream) {
                    *(char**)((char*)stream + STREAM_LOCAL_BUF_OFFSET) = g_streams[i].orig_buffer;
                    mach_vm_deallocate(mach_task_self(), g_streams[i].staging_buffer, g_streams[i].alloc_size);
                    if (is_debug_audio()) {
                        fprintf(stderr, "[overcross-audio] Deallocated 32-bit buffer at 0x%llx for stream %p\n",
                                (unsigned long long)g_streams[i].staging_buffer, stream);
                        fflush(stderr);
                    }
                    g_streams[i].stream = NULL;
                    g_streams[i].staging_buffer = 0;
                    g_streams[i].orig_buffer = NULL;
                    g_streams[i].in_use = 0;
                    break;
                }
            }
            pthread_mutex_unlock(&g_mutex);
        }
        unix_func_t orig = (unix_func_t)orig_wow64_funcs[2];
        return orig(args);
    }

    static NTSTATUS bridge_wow64_get_render_buffer(void *args) {
        ensure_initialized();
        void *stream = *(void**)args;
        uint32_t frames = *(uint32_t*)((char*)args + 8);
        int32_t *p_result = (int32_t*)((char*)args + 12);
        uint32_t data_out_ptr = *(uint32_t*)((char*)args + 16);
        uint32_t *p_data = (uint32_t*)(uintptr_t)data_out_ptr;

        if (!stream || !p_data) {
            if (p_result) *p_result = E_INVALIDARG;
            return 0;
        }

        /* Ensure buffer is in 32-bit addressable range */
        ensure_32bit_local_buffer(stream);

        char *local_buf = *(char**)((char*)stream + STREAM_LOCAL_BUF_OFFSET);
        uint32_t wri_offs = *(uint32_t*)((char*)stream + STREAM_WRI_OFFS_OFFSET);
        uint32_t bufsize_frames = *(uint32_t*)((char*)stream + STREAM_BUFSIZE_OFFSET);

        if (wri_offs >= bufsize_frames) wri_offs = 0;
        char *target = local_buf + ((size_t)wri_offs << 3);

        *p_data = (uint32_t)(uintptr_t)target;
        *(uint32_t*)((char*)stream + STREAM_GETBUF_LAST_OFFSET) = frames;

        if (p_result) *p_result = S_OK;

        if (is_debug_audio()) {
            fprintf(stderr, "[overcross-audio] get_render_buffer: frames=%u, wrote *p_data=0x%08x\n",
                    frames, *p_data);
            fflush(stderr);
        }
        return 0;
    }

    #define DEF_FWD_UNIX(idx) \
    static NTSTATUS fwd_unix_##idx(void *args) { \
        ensure_initialized(); \
        unix_func_t fn = (unix_func_t)orig_unix_funcs[idx]; \
        return fn ? fn(args) : 0; \
    }

    #define DEF_FWD_WOW64(idx) \
    static NTSTATUS fwd_wow64_##idx(void *args) { \
        ensure_initialized(); \
        unix_func_t fn = (unix_func_t)orig_wow64_funcs[idx]; \
        return fn ? fn(args) : 0; \
    }

    /* 64-bit native CoreAudio calls: 100% passthrough for modern 64-bit games */
    DEF_FWD_UNIX(0)  DEF_FWD_UNIX(1)  DEF_FWD_UNIX(2)  DEF_FWD_UNIX(3)
    DEF_FWD_UNIX(4)  DEF_FWD_UNIX(5)  DEF_FWD_UNIX(6)  DEF_FWD_UNIX(7)
    DEF_FWD_UNIX(8)  DEF_FWD_UNIX(9)  DEF_FWD_UNIX(10) DEF_FWD_UNIX(11)
    DEF_FWD_UNIX(12) DEF_FWD_UNIX(13) DEF_FWD_UNIX(14) DEF_FWD_UNIX(15)
    DEF_FWD_UNIX(16) DEF_FWD_UNIX(17) DEF_FWD_UNIX(18) DEF_FWD_UNIX(19)
    DEF_FWD_UNIX(20) DEF_FWD_UNIX(21) DEF_FWD_UNIX(22)

    /* WoW64 CoreAudio calls */
    DEF_FWD_WOW64(0)
    /* func[1] = bridge_wow64_create_stream */
    /* func[2] = bridge_wow64_release_stream */
    DEF_FWD_WOW64(3)  DEF_FWD_WOW64(4)  DEF_FWD_WOW64(5)
    /* func[6] = bridge_wow64_get_render_buffer */
    DEF_FWD_WOW64(7)
    DEF_FWD_WOW64(8)  DEF_FWD_WOW64(9)  DEF_FWD_WOW64(10) DEF_FWD_WOW64(11)
    DEF_FWD_WOW64(12) DEF_FWD_WOW64(13) DEF_FWD_WOW64(14) DEF_FWD_WOW64(15)
    DEF_FWD_WOW64(16) DEF_FWD_WOW64(17) DEF_FWD_WOW64(18) DEF_FWD_WOW64(19)
    DEF_FWD_WOW64(20) DEF_FWD_WOW64(21) DEF_FWD_WOW64(22)

    __attribute__((visibility("default"))) void *__wine_unix_call_funcs[32] = {
        fwd_unix_0,  fwd_unix_1,  fwd_unix_2,  fwd_unix_3,
        fwd_unix_4,  fwd_unix_5,  fwd_unix_6,  fwd_unix_7,
        fwd_unix_8,  fwd_unix_9,  fwd_unix_10, fwd_unix_11,
        fwd_unix_12, fwd_unix_13, fwd_unix_14, fwd_unix_15,
        fwd_unix_16, fwd_unix_17, fwd_unix_18, fwd_unix_19,
        fwd_unix_20, fwd_unix_21, fwd_unix_22, NULL
    };

    __attribute__((visibility("default"))) void *__wine_unix_call_wow64_funcs[32] = {
        fwd_wow64_0,
        bridge_wow64_create_stream,
        bridge_wow64_release_stream,
        fwd_wow64_3,  fwd_wow64_4,  fwd_wow64_5,
        bridge_wow64_get_render_buffer,
        fwd_wow64_7,
        fwd_wow64_8,  fwd_wow64_9,  fwd_wow64_10, fwd_wow64_11,
        fwd_wow64_12, fwd_wow64_13, fwd_wow64_14, fwd_wow64_15,
        fwd_wow64_16, fwd_wow64_17, fwd_wow64_18, fwd_wow64_19,
        fwd_wow64_20, fwd_wow64_21, fwd_wow64_22, NULL
    };
    """#

    func prepare(runtimeExecutableURL: URL) throws -> Preparation {
        let resolvedExecutable = runtimeExecutableURL.resolvingSymlinksInPath()
        guard let runtimeRoot = findRuntimeRoot(for: resolvedExecutable) else {
            throw Error.runtimeRootNotFound
        }

        let sourceLibrary = runtimeRoot
            .appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio.so")
        guard let sourceData = try? Data(contentsOf: sourceLibrary) else {
            throw Error.sourceBinaryUnreadable
        }
        guard isSupported(sourceData) else {
            throw Error.unsupportedRuntime
        }

        let sourceHash = sha256(sourceData)
        let stagingRoot = try stagingRoot(for: sourceHash)
        let relativeExecutable = relativePath(of: resolvedExecutable, from: runtimeRoot)
        let stagedExecutable = stagingRoot.appendingPathComponent(relativeExecutable)
        let stagedLibrary = stagingRoot
            .appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio.so")
        let stagedOrigLibrary = stagingRoot
            .appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio_orig.so")
        let stagedManifest = stagingRoot
            .appendingPathComponent("overcross-audio-repair.json")

        // Reuse existing staged runtime if valid and matches bridge architecture
        if FileManager.default.isExecutableFile(atPath: stagedExecutable.path),
           FileManager.default.fileExists(atPath: stagedLibrary.path),
           let origData = try? Data(contentsOf: stagedOrigLibrary),
           sha256(origData) == Self.supportedSourceSHA256,
           let manifestData = try? Data(contentsOf: stagedManifest),
           let manifestString = String(data: manifestData, encoding: .utf8),
           manifestString.contains("wow64-coreaudio-machvm-bridge") {
            return Preparation(
                executableURL: stagedExecutable,
                status: "Validated WoW64 CoreAudio Mach VM bridge reused from isolated runtime cache."
            )
        }

        let fileManager = FileManager.default
        let parent = stagingRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryRoot = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        do {
            try fileManager.copyItem(at: runtimeRoot, to: temporaryRoot)

            let tempLibraryDir = temporaryRoot.appendingPathComponent("lib/wine/x86_32on64-unix")
            let tempLibrary = tempLibraryDir.appendingPathComponent("winecoreaudio.so")
            let tempOrigLibrary = tempLibraryDir.appendingPathComponent("winecoreaudio_orig.so")

            guard let rawOriginalData = try? Data(contentsOf: tempLibrary),
                  isSupported(rawOriginalData) else {
                throw Error.unsupportedRuntime
            }

            // Rename original winecoreaudio.so to winecoreaudio_orig.so
            try fileManager.moveItem(at: tempLibrary, to: tempOrigLibrary)

            // Compile the bridge library directly for x86_64-apple-darwin
            let bridgeSourceFile = tempLibraryDir.appendingPathComponent("winecoreaudio_bridge.c")
            try Self.bridgeSourceCode.write(to: bridgeSourceFile, atomically: true, encoding: .utf8)

            try Self.compileBridge(sourceFile: bridgeSourceFile, outputFile: tempLibrary)
            try? fileManager.removeItem(at: bridgeSourceFile)

            let manifest = """
            {
              "repair": "wow64-coreaudio-machvm-bridge",
              "source_sha256": "\(sourceHash)",
              "source_runtime": "\(runtimeRoot.path)",
              "compiler": "Apple clang x86_64",
              "target_architecture": "x86_64-apple-darwin",
              "address_range": "0x78000000 - 0x7E000000",
              "original_runtime_untouched": true,
              "created_at": "\(ISO8601DateFormatter().string(from: Date()))",
              "status": "active"
            }
            """
            try manifest.write(to: temporaryRoot.appendingPathComponent("overcross-audio-repair.json"), atomically: true, encoding: .utf8)

            if fileManager.fileExists(atPath: stagingRoot.path) {
                try fileManager.removeItem(at: stagingRoot)
            }
            try fileManager.moveItem(at: temporaryRoot, to: stagingRoot)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.stagingFailed(error.localizedDescription)
        }

        return Preparation(
            executableURL: stagedExecutable,
            status: "Validated WoW64 CoreAudio Mach VM bridge staged in an isolated runtime copy."
        )
    }

    /// Compiles the C bridge dylib for x86_64 Darwin.
    static func compileBridge(sourceFile: URL, outputFile: URL) throws {
        let clangExecutable = URL(fileURLWithPath: "/usr/bin/clang")
        guard FileManager.default.isExecutableFile(atPath: clangExecutable.path) else {
            throw Error.compilationFailed("Clang compiler not found at /usr/bin/clang.")
        }

        let process = Process()
        process.executableURL = clangExecutable
        process.arguments = [
            "-target", "x86_64-apple-darwin",
            "-dynamiclib", "-shared",
            "-O2", "-Wall", "-Wextra",
            sourceFile.path,
            "-o", outputFile.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw Error.compilationFailed(error.localizedDescription)
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Clang compilation exited with status \(process.terminationStatus)."
            throw Error.compilationFailed(errorOutput)
        }
    }

    /// Reverts and removes the staged runtime cache for a runtime executable without touching the source.
    func rollback(for runtimeExecutableURL: URL) throws {
        let resolvedExecutable = runtimeExecutableURL.resolvingSymlinksInPath()
        guard let runtimeRoot = findRuntimeRoot(for: resolvedExecutable) else { return }
        let sourceLibrary = runtimeRoot.appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio.so")
        guard let sourceData = try? Data(contentsOf: sourceLibrary) else { return }
        let sourceHash = sha256(sourceData)
        let staging = try stagingRoot(for: sourceHash)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
    }

    func isStaged(for runtimeExecutableURL: URL) -> Bool {
        let resolvedExecutable = runtimeExecutableURL.resolvingSymlinksInPath()
        guard let runtimeRoot = findRuntimeRoot(for: resolvedExecutable) else { return false }
        let sourceLibrary = runtimeRoot.appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio.so")
        guard let sourceData = try? Data(contentsOf: sourceLibrary) else { return false }
        let sourceHash = sha256(sourceData)
        guard let staging = try? stagingRoot(for: sourceHash) else { return false }
        let stagedLibrary = staging.appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio.so")
        let stagedOrigLibrary = staging.appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio_orig.so")
        return FileManager.default.fileExists(atPath: stagedLibrary.path) &&
               FileManager.default.fileExists(atPath: stagedOrigLibrary.path)
    }

    func isSupported(_ data: Data) -> Bool {
        sha256(data) == Self.supportedSourceSHA256 &&
            bytes(data, at: Self.allocationZeroBitsOffset, count: Self.allocationZeroBitsInstruction.count) == Self.allocationZeroBitsInstruction &&
            bytes(data, at: Self.renderBufferOffset, count: Self.renderBufferInstruction.count) == Self.renderBufferInstruction
    }

    private func bytes(_ data: Data, at offset: Int, count: Int) -> [UInt8] {
        guard offset >= 0, offset + count <= data.count else { return [] }
        return Array(data[offset..<(offset + count)])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func findRuntimeRoot(for executableURL: URL) -> URL? {
        let fileManager = FileManager.default
        var candidate = executableURL.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let library = candidate.appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio.so")
            if fileManager.fileExists(atPath: library.path) { return candidate }
            candidate.deleteLastPathComponent()
        }

        if let contentsRange = executableURL.path.range(of: "/Contents/") {
            let appRoot = URL(fileURLWithPath: String(executableURL.path[..<contentsRange.lowerBound]))
            let resourceRoot = appRoot
                .appendingPathComponent("Contents/Resources/wine", isDirectory: true)
            let library = resourceRoot.appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio.so")
            if fileManager.fileExists(atPath: library.path) { return resourceRoot }
        }
        return nil
    }

    private func stagingRoot(for sourceHash: String) throws -> URL {
        return LudusStorage.applicationSupportURL
            .appendingPathComponent("AudioRepairRuntimes", isDirectory: true)
            .appendingPathComponent(sourceHash, isDirectory: true)
    }

    private func relativePath(of file: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : file.lastPathComponent
    }
}
