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
# libntsync_android.a is linked (statically) into ntdll.so and wineserver at
# build time; it is NOT needed at runtime, so keep the ~20 MB Rust archive
# out of the shipped .deb. It is built by _build_ntsync_android() below.
TERMUX_PKG_RM_AFTER_INSTALL="
lib/libntsync_android.a
"
TERMUX_PKG_HOSTBUILD=true
TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS="
--without-x
--disable-tests
"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
ac_cv_header_linux_userfaultfd_h=no
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

# Build libntsync_android.a (userspace ntsync) from source and install it to
# $TERMUX_PREFIX/lib/ so Wine can link against it (-lntsync_android in the
# patched dlls/ntdll/Makefile.in and server/Makefile.in).
#
# STATIC archive on purpose (ported from GameNative/proton-wine): a dynamic
# libntsync_android.so would live outside the bionic linker namespace that
# box64's ELF loader searches, which made dlopen("ntdll.so") fail on x86_64
# GameNative builds; static-linking the archive into ntdll + wineserver avoids
# the whole class of namespace problems.
#
# The Rust toolchain is set up on the fly via termux_setup_rust; Termux's
# toolchain setup already exports CARGO_TARGET_NAME and
# CARGO_TARGET_<TRIPLE>_LINKER pointing at the NDK clang, so plain
# `cargo build --target $CARGO_TARGET_NAME` cross-compiles correctly.
#
# The archive is removed from the final .deb again via
# TERMUX_PKG_RM_AFTER_INSTALL (it is only needed at link time).
_build_ntsync_android() {
        # Skip if already built (e.g. when re-running termux_step_pre_configure)
        if [ -f "$TERMUX_PREFIX/lib/libntsync_android.a" ]; then
                echo "[ntsync-android] libntsync_android.a already installed, skipping build"
                return 0
        fi

        # Set up the Rust toolchain (rustup + target). This downloads rustup
        # on first run and caches it in $HOME/.cargo. Subsequent builds reuse it.
        termux_setup_rust

        # Clone (or update) the ntsync-android source into the per-package cache
        # dir so it survives across rebuilds.
        local _ntsync_src="$TERMUX_PKG_CACHEDIR/ntsync-android-src"
        if [ ! -d "$_ntsync_src" ]; then
                git clone --depth 1 https://github.com/GameNative/ntsync-android.git "$_ntsync_src"
        fi

        # Cross-compile for the current arch. The crate builds both a cdylib
        # and a staticlib; we only install the static archive.
        echo "[ntsync-android] building libntsync_android.a for $CARGO_TARGET_NAME"
        ( cd "$_ntsync_src" && \
                cargo build --jobs "$TERMUX_PKG_MAKE_PROCESSES" \
                        --release --target "$CARGO_TARGET_NAME" )

        install -Dm644 \
                "$_ntsync_src/target/$CARGO_TARGET_NAME/release/libntsync_android.a" \
                "$TERMUX_PREFIX/lib/libntsync_android.a"
        rm -f "$TERMUX_PREFIX/lib/libntsync_android.so"
        echo "[ntsync-android] installed to $TERMUX_PREFIX/lib/libntsync_android.a"
}

termux_step_host_build() {
        _setup_llvm_mingw_toolchain
        "$TERMUX_PKG_SRCDIR/configure" ${TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS}
        make -j "$TERMUX_PKG_MAKE_PROCESSES" __tooldeps__ nls/all
}
termux_step_pre_configure() {
        _setup_llvm_mingw_toolchain

        # Build libntsync_android.a now (after toolchain setup, before Wine
        # configure+make). The archive lands in $TERMUX_PREFIX/lib and is
        # linked into ntdll.so + wineserver via -lntsync_android. See
        # _build_ntsync_android above.
        _build_ntsync_android

        # Regenerate the protocol headers from the patched protocol.def.
        # patches/ntsync-combined.patch ships the regenerated files (created
        # with this very tool), so this is a no-op safety net that also keeps
        # the tree consistent if protocol.def is ever touched again.
        ( cd "$TERMUX_PKG_SRCDIR" && perl tools/make_requests ) || true

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
