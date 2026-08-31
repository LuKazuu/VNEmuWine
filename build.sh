# build.sh — Termux package recipe for Hangover Wine (BALANCED build)
#
# Goal: IDENTICAL runtime performance to upstream LuKazuu/WinHubWine (which
# uses -Oz + llvm-strip), BUT keep enough symbol info that:
#   - WINEDEBUG output (relay, +dll, +seh, etc.) keeps working — already a
#     runtime flag, so it works on ANY build, stripped or not. Just documented
#     here for clarity.
#   - Crash backtraces (from `winedbg` or kernel segfault handler) show real
#     function names + source file + line numbers, so you can identify which
#     DLL / which code path errored without attaching gdb.
#
# How we achieve this:
#   1. KEEP the exact same compile-time optimizer as upstream: `-Oz`. No -O0,
#      no -Og. Performance is byte-for-byte identical to the stripped build.
#   2. KEEP the same linker GC flags as upstream (`--gc-sections`, `--icf=safe`,
#      `--rosegment`) — these only discard dead code/data, NOT symbol tables.
#      No perf cost either way; they were upstream for size reduction.
#   3. ADD `-g1` (line-tables only) on top of `-Oz`. This emits minimal DWARF
#      (just `.debug_line` + `.debug_abbrev` — NO `.debug_info`, NO variable
#      ranges). Effect on size: +10-15% over stripped. Effect on perf: ZERO
#      (DWARF is not loaded by the loader; it's only consumed by debuggers).
#   4. DO NOT STRIP. The upstream `llvm-strip --strip-unneeded` pass is GONE.
#      That pass was throwing away `.symtab` + `.strtab` + `.debug_*` sections
#      in one go. Without it, you get:
#         - .symtab/.strtab → crash backtraces show `KERNEL32.dll!CreateProcessW`
#                            instead of `?? ()`.
#         - .debug_line     → backtraces also show `dlls/kernel32/process.c:1234`.
#      This is what makes "debugging via WINEDEBUG + crash log" actually work.
#   5. STILL delete `*.a`, `*.lib`, `*.def`, `include/`, `share/man/` like
#      upstream — these are pure dev artifacts, irrelevant for running Wine
#      and irrelevant for runtime debugging. They just bloat the .deb.
#   6. STILL use ccache (ported from The412Banner/proton-wine). Subsequent
#      CI runs / local rebuilds that touch only a few files get cache hits.
#
# Bottom line for the user:
#   - Performance: SAME as upstream stripped build. Play games normally.
#   - Size: ~15-20% larger .deb than upstream (because of retained .symtab
#     and .debug_line). Still tiny compared to a full -O0 -g build.
#   - WINEDEBUG: works identically to upstream (it's a runtime flag).
#   - Crash logs: readable function names + file:line. No gdb required.
TERMUX_PKG_HOMEPAGE=https://www.winehq.org
TERMUX_PKG_DESCRIPTION="A compatibility layer for running Windows programs (Hangover fork)"
TERMUX_PKG_LICENSE="LGPL-2.1"
TERMUX_PKG_LICENSE_FILE="LICENSE, COPYING.LIB"
TERMUX_PKG_MAINTAINER="@LuKazuu"
TERMUX_PKG_VERSION="__WINE_VERSION__"
TERMUX_PKG_SRCURL="https://github.com/wine-mirror/wine/archive/refs/tags/wine-${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256="__WINE_SHA256__"
TERMUX_PKG_DEPENDS="alsa-lib, alsa-plugins, fontconfig, freetype, krb5, libandroid-spawn, libc++, libgmp, libgnutls, libxcb, libxcomposite, libxcursor, libxfixes, libxrender, opengl, pulseaudio, sdl2, vulkan-loader, xorg-xrandr"
TERMUX_PKG_BUILD_DEPENDS="libandroid-spawn-static, vulkan-loader-generic"
TERMUX_PKG_ANTI_BUILD_DEPENDS="vulkan-loader"
TERMUX_PKG_NO_STATICSPLIT=true
TERMUX_PKG_AUTO_UPDATE=false
TERMUX_PKG_EXCLUDED_ARCHES="arm, i686, x86_64"
TERMUX_PKG_HOSTBUILD=true
TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS="
--without-x
--disable-tests
"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
ac_cv_header_linux_userfaultfd_h=no
ac_cv_header_linux_ntsync_h=yes
ac_cv_path_GRADLE=no
enable_wineandroid_drv=no
enable_tools=yes
--prefix=$TERMUX_PREFIX/opt/hangover-wine
--exec-prefix=$TERMUX_PREFIX/opt/hangover-wine
--includedir=$TERMUX_PREFIX/opt/hangover-wine/include
--libdir=$TERMUX_PREFIX/opt/hangover-wine/lib
--with-wine-tools=$TERMUX_PKG_HOSTBUILD_DIR
--enable-nls
--disable-tests
--with-alsa
--without-capi
--without-coreaudio
--without-cups
--without-dbus
--without-ffmpeg
--with-fontconfig
--with-freetype
--without-gettext
--with-gettextpo=no
--without-gphoto
--with-gnutls
--without-gstreamer
--without-inotify
--with-krb5
--with-mingw=clang
--without-netapi
--without-opencl
--with-opengl
--without-osmesa
--without-oss
--without-pcap
--without-pcsclite
--with-pthread
--with-pulse
--without-sane
--with-sdl
--without-udev
--without-unwind
--without-usb
--without-v4l2
--with-vulkan
--with-xcomposite
--with-xcursor
--with-xfixes
--without-xinerama
--with-xinput
--with-xinput2
--with-xrandr
--with-xrender
--without-xshape
--without-xshm
--without-xxf86vm
--enable-archs=i386,aarch64,arm64ec
"
_setup_llvm_mingw_toolchain() {
        local _llvm_mingw_version=21
        local _version="20250319"
        local _url="https://github.com/mstorsjo/llvm-mingw/releases/download/$_version/llvm-mingw-$_version-ucrt-ubuntu-20.04-x86_64.tar.xz"
        local _path="$TERMUX_PKG_CACHEDIR/$(basename $_url)"
        local _sha256sum=ab2a1489416fa82b3e85e88cb877053ee8a591993408caf076737d8de5ae72ca
        termux_download $_url $_path $_sha256sum
        local _extract_path="$TERMUX_PKG_CACHEDIR/llvm-mingw-toolchain-$_llvm_mingw_version"
        if [ ! -d "$_extract_path" ]; then
                mkdir -p "$_extract_path"-tmp
                tar -C "$_extract_path"-tmp --strip-component=1 -xf "$_path"
                mv "$_extract_path"-tmp "$_extract_path"
        fi
        export PATH="$_extract_path/bin:$PATH"
}

# Enable ccache for both unix clang (CC/CXX) and mingw clang (PATH-resolved).
# Ported from The412Banner/proton-wine build-step-x86_64.sh.
# Safe no-op when ccache is not installed.
_setup_ccache() {
        if ! command -v ccache >/dev/null 2>&1; then
                echo "[ccache] not found on PATH — direct compile (no cache)."
                return 0
        fi
        # When running inside Termux's package-builder Docker image, the
        # termux-packages repo is mounted at /home/builder/termux-packages and
        # is the only path that is visible to the host runner. Putting the
        # ccache dir INSIDE that mount lets GitHub Actions `actions/cache@v4`
        # persist it across runs (huge speedup when iterating on patches).
        if [ "${CI:-false}" = "true" ] && [ -d /home/builder/termux-packages ]; then
                export CCACHE_DIR="${CCACHE_DIR:-/home/builder/termux-packages/.ccache}"
        else
                export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
        fi
        ccache -M 5G >/dev/null 2>&1 || true
        ccache --set-config=hash_dir=false >/dev/null 2>&1 || true
        ccache --set-config=compression=true >/dev/null 2>&1 || true

        # Masquerade dir — Wine's PE side uses `--with-mingw=clang`, which resolves
        # `clang` from PATH. Putting ccache symlinks first on PATH makes every
        # cross-compile invocation go through ccache too.
        local _ccache_bin="$HOME/ccache-bin"
        mkdir -p "$_ccache_bin"
        ln -sf "$(command -v ccache)" "$_ccache_bin/clang"
        ln -sf "$(command -v ccache)" "$_ccache_bin/clang++"
        export PATH="$_ccache_bin:$PATH"

        # Wrap the unix-side compiler too. CC/CXX may already be set by Termux;
        # avoid double-wrapping if we already ran this once.
        case "${CC:-}" in
                *ccache*) ;;
                *) export CC="ccache ${CC:-clang}"
                   export CXX="ccache ${CXX:-clang++}" ;;
        esac
        case "${HOSTCC:-}" in
                *ccache*) ;;
                *) export HOSTCC="ccache ${HOSTCC:-cc}"
                   export HOSTCXX="ccache ${HOSTCXX:-c++}" ;;
        esac
        echo "[ccache] enabled, cache_dir=$CCACHE_DIR, CC=$CC"
        ccache -s 2>/dev/null || true
}

# Build libntsync_android.so from source and install it to $TERMUX_PREFIX/lib/
# so Wine can link against it (-lntsync_android in LDFLAGS). The .so gets
# bundled into the hangover-wine .deb automatically — anything installed to
# $TERMUX_PREFIX during the build is captured by the termux package builder.
#
# We build ntsync-android inline rather than as a separate termux package,
# so users don't need to install anything extra. The Rust toolchain is set
# up on the fly via termux_setup_rust (downloads rustup + the right target).
#
# ntsync-android's own .cargo/config.toml adds the 16KB page-size alignment
# flag (-Wl,-z,max-page-size=16384) required by Google Play for Android 15+,
# so we don't need to set that here.
_build_ntsync_android() {
        # Skip if already built (e.g. when re-running termux_step_pre_configure)
        if [ -f "$TERMUX_PREFIX/lib/libntsync_android.so" ]; then
                echo "[ntsync-android] libntsync_android.so already installed, skipping build"
                return 0
        fi

        # Set up the Rust toolchain (rustup + target). This downloads rustup
        # on first run and caches it in $HOME/.cargo. Subsequent builds reuse it.
        termux_setup_rust

        # Clone (or update) ntsync-android source into the per-package cache
        # dir so it survives across rebuilds.
        local _ntsync_src="$TERMUX_PKG_CACHEDIR/ntsync-android-src"
        if [ ! -d "$_ntsync_src" ]; then
                git clone --depth 1 https://github.com/joshuatam/ntsync-android.git "$_ntsync_src"
        fi

        # Cross-compile for the current arch. termux_setup_toolchain already
        # set CARGO_TARGET_NAME and CARGO_TARGET_*_LINKER for us, so cargo
        # knows where the NDK clang is.
        echo "[ntsync-android] building libntsync_android.so for $CARGO_TARGET_NAME"
        ( cd "$_ntsync_src" && \
                cargo build --jobs "$TERMUX_PKG_MAKE_PROCESSES" \
                        --release --target "$CARGO_TARGET_NAME" )

        # Install the .so to $TERMUX_PREFIX/lib so Wine's linker finds it
        # at build time, and so the termux package builder bundles it into
        # the hangover-wine .deb (it captures everything installed to
        # $TERMUX_PREFIX during the build).
        install -Dm644 \
                "$_ntsync_src/target/$CARGO_TARGET_NAME/release/libntsync_android.so" \
                "$TERMUX_PREFIX/lib/libntsync_android.so"
        echo "[ntsync-android] installed to $TERMUX_PREFIX/lib/libntsync_android.so"
}

termux_step_post_get_source() {
        # Install the ntsync-android shim headers into the Termux sysroot so
        # Wine's configure detects "linux/ntsync.h" and the patched source
        # can #include it. We embed the headers as heredocs here so the
        # package recipe is fully self-contained — no extra files needed
        # beyond build.sh and patches/ntsync-android.patch.
        #
        # ntsync_user.h  — verbatim copy of the C header from the
        #                  ntsync-android upstream repo (defines
        #                  ntsync_create_sem, ntsync_wait_any,
        #                  NTSYNC_ANDROID_USED_BY_SERVER, etc.).
        # linux/ntsync.h — shim that includes ntsync_user.h and defines the
        #                  NTSYNC_IOC_* constants as non-zero sentinels so
        #                  Wine's existing #ifdef NTSYNC_IOC_EVENT_READ code
        #                  paths compile. The numeric values are never used
        #                  at runtime — all ioctl() call sites are replaced
        #                  by direct ntsync_* function calls in
        #                  patches/ntsync-android.patch.
        cat > "$TERMUX_PREFIX/include/ntsync_user.h" <<'NTSYNC_USER_H_EOF'
/*
 * Userspace ntsync library for Android - C API.
 *
 * Copyright (C) 2026 Joshua Tam <297250+joshuatam@users.noreply.github.com>
 *
 * This library is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, version 3 only.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library. If not, see <https://www.gnu.org/licenses/>.
 *
 * Mirrors the Linux /dev/ntsync ioctl interface (include/uapi/linux/ntsync.h)
 * with u32 handles in place of kernel fds. All functions return 0 on success
 * or a negative errno, exactly like the kernel ioctls.
 *
 * Objects live in a file-backed shared mapping and are cross-process: any
 * process that opens the same region path sees the same handles. Waits use
 * futexes on the shared pages.
 *
 * Alertable waits are supported: if ntsync_wait_args.alert is nonzero it
 * names an event object that aborts the wait; the wait returns success with
 * index == count, exactly like the kernel ioctls.
 * Divergence from the kernel: closing an object other threads are waiting on
 * fails those waits with -EINVAL; objects leaked by a crashed process must
 * be reclaimed with ntsync_sweep_dead().
 *
 * SPDX-License-Identifier: LGPL-3.0-only
 */
#ifndef NTSYNC_USER_H
#define NTSYNC_USER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct ntsync_sem_args {
    uint32_t count;
    uint32_t max;
};

struct ntsync_mutex_args {
    uint32_t owner;
    uint32_t count;
};

struct ntsync_event_args {
    uint32_t manual;
    uint32_t signaled;
};

#define NTSYNC_WAIT_REALTIME 0x1

struct ntsync_wait_args {
    /* Absolute timeout in ns; CLOCK_MONOTONIC, or CLOCK_REALTIME if
     * NTSYNC_WAIT_REALTIME is set. UINT64_MAX = infinite. */
    uint64_t timeout;
    /* Pointer to an array of `count` uint32_t handles. */
    uint64_t objs;
    uint32_t count;
    /* Out: index of the object that satisfied the wait. */
    uint32_t index;
    uint32_t flags;
    /* In: owner tid used to acquire mutexes. */
    uint32_t owner;
    /* In: optional alert event handle (0 = none); aborts the wait, which
     * then returns success with index == count. */
    uint32_t alert;
    uint32_t pad;
};

#define NTSYNC_MAX_WAIT_COUNT 64

/* Wine integration: wineserver reports userspace ntsync to clients by
 * putting this sentinel in the inproc_device field of the init_first_thread
 * reply, and passes object handles in the fsync_shm_idx reply field instead
 * of SCM_RIGHTS fd passing. */
#define NTSYNC_ANDROID_USED_BY_SERVER 0x7eadfe01

/* Initialize the shared region. `path` may be NULL to use
 * $TMPDIR/ntsync_userspace.shm (the caller must export TMPDIR); a layout
 * version is inserted before the ".shm" extension (ntsync_userspace.vN.shm).
 * Idempotent; all other functions auto-initialize on first use. */
int32_t ntsync_init(const char *path);

/* Free all objects whose creator process no longer exists. Userspace has no
 * fd-close-on-death hook, so a launcher/server should call this after a
 * process exits. Returns the number of freed objects or a negative errno. */
int32_t ntsync_sweep_dead(void);

/* Create objects. Return 0 and store the handle, or a negative errno.
 * Handles are never 0: slot 0 is permanently reserved because 0 is the
 * "no alert" sentinel in ntsync_wait_args.alert. */
int32_t ntsync_create_sem(uint32_t *out_handle, const struct ntsync_sem_args *args);
int32_t ntsync_create_mutex(uint32_t *out_handle, const struct ntsync_mutex_args *args);
int32_t ntsync_create_event(uint32_t *out_handle, const struct ntsync_event_args *args);

/* Destroy an object. Returns -EINVAL for a bad handle. */
int32_t ntsync_close(uint32_t handle);

/* Semaphores. On success, sem_release overwrites *count with the previous
 * count; returns -EOVERFLOW (state unchanged) if count would exceed max. */
int32_t ntsync_sem_release(uint32_t handle, uint32_t *count);
int32_t ntsync_sem_read(uint32_t handle, struct ntsync_sem_args *args);

/* Mutexes. args->owner is input; on success args->count is overwritten with
 * the previous recursion count. Returns -EPERM if not the owner.
 * mutex_read returns -EOWNERDEAD if the mutex is abandoned. */
int32_t ntsync_mutex_unlock(uint32_t handle, struct ntsync_mutex_args *args);
int32_t ntsync_mutex_kill(uint32_t handle, uint32_t owner);
int32_t ntsync_mutex_read(uint32_t handle, struct ntsync_mutex_args *args);

/* Events. On success, set/reset/pulse store the previous signaled state in
 * *prev (if non-NULL), like the kernel ioctls. */
int32_t ntsync_event_set(uint32_t handle, uint32_t *prev);
int32_t ntsync_event_reset(uint32_t handle, uint32_t *prev);
int32_t ntsync_event_pulse(uint32_t handle, uint32_t *prev);
int32_t ntsync_event_read(uint32_t handle, struct ntsync_event_args *args);

/* Waits. Return 0 and set args->index on success, -EOWNERDEAD (and set
 * args->index) when an abandoned mutex was acquired, -ETIMEDOUT on timeout,
 * -EINVAL on bad arguments. */
int32_t ntsync_wait_any(struct ntsync_wait_args *args);
int32_t ntsync_wait_all(struct ntsync_wait_args *args);

#ifdef __cplusplus
}
#endif

#endif /* NTSYNC_USER_H */
NTSYNC_USER_H_EOF

        mkdir -p "$TERMUX_PREFIX/include/linux"
        cat > "$TERMUX_PREFIX/include/linux/ntsync.h" <<'NTSYNC_SHIM_EOF'
/*
 * linux/ntsync.h shim for Android.
 *
 * Android's kernel has no /dev/ntsync driver, so Wine's native ntsync
 * fast-path (which uses ioctl(fd, NTSYNC_IOC_*, ...) on /dev/ntsync)
 * cannot work as-is. The ntsync-android userspace library
 * (https://github.com/joshuatam/ntsync-android) provides a drop-in
 * replacement that mirrors the kernel ioctl ABI but uses u32 handles
 * in shared memory instead of fds.
 *
 * This shim header makes Wine's configure detect "linux/ntsync.h" so
 * that the existing NTSYNC_IOC_EVENT_READ code paths compile. The
 * actual ioctl() calls in Wine's source are redirected to the
 * ntsync-android C functions by patches/ntsync-android.patch.
 *
 * SPDX-License-Identifier: LGPL-3.0-only
 */
#ifndef __LINUX_NTSYNC_H_SHIM
#define __LINUX_NTSYNC_H_SHIM

#include <ntsync_user.h>

/*
 * Define the NTSYNC_IOC_* constants that Wine's source tests for via
 * #ifdef NTSYNC_IOC_EVENT_READ. The numeric values are never used at
 * runtime — all ioctl() call sites are replaced by direct ntsync_*
 * function calls in the patch — but the symbols must exist for the
 * preprocessor.
 */
#define NTSYNC_IOC_CREATE_SEM       0xdead0001
#define NTSYNC_IOC_CREATE_MUTEX     0xdead0002
#define NTSYNC_IOC_CREATE_EVENT     0xdead0003
#define NTSYNC_IOC_SEM_RELEASE      0xdead0004
#define NTSYNC_IOC_SEM_READ         0xdead0005
#define NTSYNC_IOC_MUTEX_UNLOCK     0xdead0006
#define NTSYNC_IOC_MUTEX_KILL       0xdead0007
#define NTSYNC_IOC_MUTEX_READ       0xdead0008
#define NTSYNC_IOC_EVENT_SET        0xdead0009
#define NTSYNC_IOC_EVENT_RESET      0xdead000a
#define NTSYNC_IOC_EVENT_PULSE      0xdead000b
#define NTSYNC_IOC_EVENT_READ       0xdead000c
#define NTSYNC_IOC_WAIT_ANY         0xdead000d
#define NTSYNC_IOC_WAIT_ALL         0xdead000e

#endif /* __LINUX_NTSYNC_H_SHIM */
NTSYNC_SHIM_EOF

        # Regenerate protocol headers from the patched protocol.def
        # (patches/ntsync-android.patch adds an `ntsync_handle` field to
        # get_inproc_sync_fd_reply). Wine's build system normally does
        # this itself via tools/make_requests when protocol.def is newer
        # than the generated headers, but we run it explicitly to be safe.
        ( cd "$TERMUX_PKG_SRCDIR" && perl tools/make_requests ) || true
}

termux_step_host_build() {
        _setup_llvm_mingw_toolchain
        _setup_ccache
        "$TERMUX_PKG_SRCDIR/configure" ${TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS}
        make -j "$TERMUX_PKG_MAKE_PROCESSES" __tooldeps__ nls/all
}
termux_step_pre_configure() {
        _setup_llvm_mingw_toolchain
        _setup_ccache

        # Build libntsync_android.so now (after toolchain setup, before Wine
        # configure). The .so lands in $TERMUX_PREFIX/lib and gets bundled
        # into the hangover-wine .deb. See _build_ntsync_android above.
        _build_ntsync_android

        # --- Strip Termux's hardening flags (matches upstream behaviour) ------
        # Upstream LuKazuu removes these because they don't play nice with Wine's
        # loader; we keep that removal for behavioural parity.
        CPPFLAGS="${CPPFLAGS/-Oz/}"
        CFLAGS="${CFLAGS/-Oz/}"
        CXXFLAGS="${CXXFLAGS/-Oz/}"

        CPPFLAGS="${CPPFLAGS/-fstack-protector-strong/}"
        CFLAGS="${CFLAGS/-fstack-protector-strong/}"
        CXXFLAGS="${CXXFLAGS/-fstack-protector-strong/}"

        LDFLAGS="${LDFLAGS/-Wl,-z,relro,-z,now/}"

        # --- Performance + minimal-debug compile flags (unix/ELF side) -------
        # -Oz          -> SAME as upstream. Optimize for size; perf is on par
        #                 with -O2 on Wine's workload (mostly IPC + syscall glue).
        # -g1          -> line-tables only. Emits just .debug_line + .debug_abbrev.
        #                 NO .debug_info, NO variable location ranges. Tiny size
        #                 overhead (~10-15% over stripped), but enough for
        #                 winedbg / crash backtrace to show file:line.
        # -fno-lto     -> kill any LTO that might be in the toolchain. LTO would
        #                 inline functions across modules and make backtraces
        #                 show weird frames; we want clean 1-source-line mapping.
        # NOTE: we DO NOT use -fno-omit-frame-pointer here. Upstream doesn't use
        #       it and aarch64 unwinder is reliable enough with -Oz -g1.
        local _balanced_flags="-Oz -g1 -fno-lto"
        CFLAGS+=" $_balanced_flags"
        CXXFLAGS+=" $_balanced_flags"

        # --- PE (mingw cross-compile) side -------------------------------------
        # Wine's configure reads CROSSCFLAGS / CROSSLDFLAGS and passes them to
        # the mingw clang for every .dll/.exe/.drv/.sys. Without this, the
        # cross side would inherit whatever the toolchain default is (usually
        # -O2 -g0) and you'd get un-debuggable PE binaries. Force the same
        # -Oz -g1 here so Windows-side DLLs also have line tables for backtraces.
        export CROSSCFLAGS="${CROSSCFLAGS:-} $_balanced_flags"
        export CROSSLDFLAGS="${CROSSLDFLAGS:-}"

        # Required by Wine's loader on Android (libandroid-spawn for posix_spawn).
        # The upstream --rosegment / --gc-sections / --icf=safe trio is also kept,
        # because they only discard dead code/sections — symbol tables and DWARF
        # .debug_line survive all three.
        LDFLAGS+=" -landroid-spawn"
        LDFLAGS+=" -Wl,--rosegment -Wl,--gc-sections -Wl,--icf=safe"

        # ntsync-android: the patched wineserver and ntdll/unix/sync.c call
        # ntsync_init(), ntsync_create_sem(), ntsync_wait_any(), ... directly
        # (see patches/ntsync-android.patch). Link the shared library so
        # every Wine process has access to the shared-memory ntsync region.
        LDFLAGS+=" -lntsync_android"

        # Section-level dead-code elimination. These work WITH --gc-sections to
        # let the linker drop unused function/data. They do NOT touch .symtab
        # or .debug_*, so backtraces are unaffected.
        CFLAGS+=" -ffunction-sections -fdata-sections"
        CXXFLAGS+=" -ffunction-sections -fdata-sections"
}
termux_step_make() {
        make -j $TERMUX_PKG_MAKE_PROCESSES
}
termux_step_make_install() {
        make -j $TERMUX_PKG_MAKE_PROCESSES install
        mkdir -p $TERMUX_PREFIX/bin
        cat << EOF > $TERMUX_PREFIX/bin/hangover-wine
#!$TERMUX_PREFIX/bin/env sh
exec $TERMUX_PREFIX/opt/hangover-wine/bin/wine "\$@"
EOF
        chmod +x $TERMUX_PREFIX/bin/hangover-wine
}
termux_step_post_make_install() {
        local _dll_dir="${TERMUX_PKG_BUILDER_DIR}/fex-dlls"
        if [ ! -d "$_dll_dir" ]; then
                echo "ERROR: $_dll_dir does not exist" >&2; exit 1
        fi
        local _dll
        for _dll in wowbox64.dll libwow64fex.dll libarm64ecfex.dll; do
                if [ -f "$_dll_dir/$_dll" ]; then
                        install -Dm644 "$_dll_dir/$_dll" \
                                "$TERMUX_PREFIX"/opt/hangover-wine/lib/wine/aarch64-windows/$_dll
                else
                        echo "ERROR: $_dll not found" >&2; exit 1
                fi
        done
        mkdir -p "$TERMUX_PREFIX"/share/doc/hangover \
                 "$TERMUX_PREFIX"/share/doc/hangover-libarm64ecfex \
                 "$TERMUX_PREFIX"/share/doc/hangover-libwow64fex \
                 "$TERMUX_PREFIX"/share/doc/hangover-wowbox64
        cp "$TERMUX_PKG_SRCDIR/LICENSE" "$TERMUX_PREFIX"/share/doc/hangover/copyright
        curl -L "https://raw.githubusercontent.com/FEX-Emu/FEX/main/LICENSE" -o "$TERMUX_PREFIX"/share/doc/hangover-libarm64ecfex/copyright
        cp "$TERMUX_PREFIX"/share/doc/hangover-libarm64ecfex/copyright "$TERMUX_PREFIX"/share/doc/hangover-libwow64fex/copyright
        curl -L "https://raw.githubusercontent.com/ptitSeb/box64/main/LICENSE" -o "$TERMUX_PREFIX"/share/doc/hangover-wowbox64/copyright

        # --- LIGHTWEIGHT SIZE REDUCTION (NO STRIP) ---------------------------
        # We DELETE the same dev artifacts as upstream (static libs, def files,
        # headers, man pages) — these are irrelevant for running Wine AND
        # irrelevant for runtime debugging (WINEDEBUG + crash backtraces).
        #
        # We DO NOT run llvm-strip. The strip pass upstream was throwing away:
        #   - .symtab / .strtab  -> function name resolution in backtraces
        #   - .debug_line        -> file:line in backtraces
        # By skipping strip, you keep both, so `winedbg --gdb` / kernel
        # segfault logs / WINEDEBUG=+seh all show real names + file:line.
        echo "Removing dev artifacts (static libs, headers, man pages)..."
        find "$TERMUX_PREFIX/opt/hangover-wine" -type f \( -name "*.a" -o -name "*.lib" -o -name "*.def" \) -delete
        rm -rf "$TERMUX_PREFIX/opt/hangover-wine/include" "$TERMUX_PREFIX/opt/hangover-wine/share/man"
        echo "Balanced install complete (no strip, -Oz -g1, full perf)."
}
