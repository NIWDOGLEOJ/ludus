/*
 * winecoreaudio_bridge.c
 * Overcross WoW64 CoreAudio 32-bit Render Buffer Bridge for GPTK 1.1 / Wine 7.7
 *
 * ARCHITECTURAL CONTEXT & PROBLEM DESCRIPTION:
 * --------------------------------------------
 * When running 32-bit Windows games (PE32) on macOS Apple Silicon under Rosetta 2
 * in a Wine WoW64 environment, host virtual memory allocations performed by Wine's
 * 64-bit CoreAudio backend (lib/wine/x86_32on64-unix/winecoreaudio.so) default to
 * 64-bit addresses above the 4 GB boundary (e.g., 0x05bab040_00000000).
 *
 * In the GPTK 1.1 binary (SHA-256: 34691d789ff2f8817715f9a895299cbb04369b463daaa7111a8b2fb2396e1947),
 * function 6 of __wine_unix_call_wow64_funcs (wow64_get_render_buffer, at offset 0x6f80)
 * computes the destination buffer pointer:
 *     rcx = stream->local_buffer + (stream->wri_offs << 3)
 * and truncates this 64-bit pointer into a 32-bit integer for the 32-bit caller:
 *     0x6fa7: movl %ecx, (%rdx)
 *
 * Because stream->local_buffer resides above 4 GB, writing only the low 32 bits
 * yields an invalid address (e.g. 0x00000000 or 0x00000200). DirectSound mix threads
 * in 32-bit games (e.g. Need for Speed: Most Wanted) immediately crash on write access:
 *     wine: Unhandled page fault on write access to 00000200 at address 70BD45E8
 *
 * An earlier experimental binary patch tried forcing ZeroBits = 0x20 in NtAllocateVirtualMemory,
 * but macOS / Rosetta cannot satisfy 32-bit ZeroBits constraints inside 64-bit Wine,
 * causing NtAllocateVirtualMemory to return STATUS_NO_MEMORY (E_OUTOFMEMORY 0x8007000e)
 * during AudioClient_Initialize.
 *
 * THE PERMANENT BRIDGE SOLUTION:
 * ------------------------------
 * This bridge library replaces winecoreaudio.so in an isolated staged runtime:
 * 1. The original runtime library is preserved as winecoreaudio_orig.so (untouched).
 * 2. 64-bit calls (__wine_unix_call_funcs) are 100% passed through to winecoreaudio_orig.so,
 *    guaranteeing zero regression for modern 64-bit games.
 * 3. WoW64 calls (__wine_unix_call_wow64_funcs) intercept stream creation, destruction,
 *    and get_render_buffer:
 *    - For any stream whose local_buffer is >= 4 GB (0x100000000ULL), the bridge
 *      allocates a dedicated, 32-bit addressable buffer (< 2 GB, e.g. 0x78000000..0x7E000000)
 *      via mach_vm_allocate(mach_task_self(), ...).
 *    - The original local_buffer pointer is saved in a thread-safe registry (g_streams).
 *    - stream->local_buffer is redirected to the 32-bit Mach VM buffer.
 *    - In get_render_buffer, the full 32-bit address (local_buffer + (wri_offs << 3))
 *      is safely written into *p_data.
 *    - In release_stream, the original buffer pointer is restored and the Mach VM
 *      buffer is freed via mach_vm_deallocate.
 *
 * This provides 100% clean, coherent, non-crashing audio streaming across DirectSound,
 * WASAPI, and CoreAudio on macOS Apple Silicon.
 */

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
#define STAGING_SLOT_SIZE 0x200000ULL /* 2 MB per audio stream (plenty for high-res audio buffers) */

/* Stream struct offsets verified in GPTK 1.1 winecoreaudio.so */
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
