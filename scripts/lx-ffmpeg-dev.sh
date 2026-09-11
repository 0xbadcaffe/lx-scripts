#!/usr/bin/env bash
# FFmpeg development prerequisites for Ubuntu 22.04+ / Debian 11+.
# Run as your normal user. Only APT uses sudo. No source downloads/builds.
# Reviewed 2026-09-11. This is a host-package installer, not a claim that
# distro libraries satisfy every optional feature of every FFmpeg revision.
# The selected source tree's configure script is the final compatibility test.
# References:
#   https://www.ffmpeg.org/developer.html
#   https://www.ffmpeg.org/fate.html
#   https://www.ffmpeg.org/platform.html
#   https://ffmpeg.org/doxygen/trunk/md_LICENSE.html
#   https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/configure
#   https://packages.debian.org/   https://packages.ubuntu.com/
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: bash install-ffmpeg-dev-prereqs.sh [OPTIONS]

Default: native build tools; common audio/video/subtitle/network development
libraries; SDL2; debugging, profiling, FATE/coverage and patch tools.

  --minimal       Core native build tools + compression development libraries.
  --gpl           Also install x264/x265 and optional GPL filter/codec libraries.
  --hardware      Try VA-API, VDPAU, DRM, Vulkan/OpenCL, Intel QSV and NV headers.
                  No GPU driver/CUDA toolkit installation or permissions change.
  --llvm          Also install distro Clang/LLVM/LLD and available analysis tools.
  --docs          Also install Texinfo, Doxygen and Graphviz documentation tools.
  --system-libs   Also install distro libav*-dev libraries for YOUR applications.
                  Not needed to build FFmpeg itself; do not mix their ABI with
                  an unrelated source-built FFmpeg.
  --dry-run       Print the requested plan; no sudo, update, downloads or writes.
  --check-only    Check installed packages/tools; no APT changes or downloads.
                  May compile/link/run tiny probes in a temporary directory.
  --strict        Return exit 2 if any supplementary package/check is missing.
  -h, --help      Show this help.

--minimal can be combined with explicitly requested groups, e.g. --minimal --gpl.
--dry-run and --check-only are mutually exclusive.

Uses only enabled APT repositories, without enabling universe/non-free/PPAs.
Unavailable supplementary packages are reported. Missing required packages fail.
No FFmpeg build/install, source cloning, FATE sample download, rustup/pip,
compiler-default changes, locale changes or host security changes are performed.

Exit 0: selected core checks passed (warnings may remain unless --strict).
Exit 1: invalid request, unsupported host, APT or required verification failed.
Exit 2: --strict selected and supplementary packages/checks are missing.
A successful prerequisite check is NOT a successful FFmpeg build or FATE run.
EOF
}

log() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }

parse_args() {
    MINIMAL=0; GPL=0; HARDWARE=0; LLVM=0; DOCS=0; SYSTEM_LIBS=0
    STRICT=0; MODE=install; HELP=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --minimal) MINIMAL=1 ;;
            --gpl) GPL=1 ;;
            --hardware) HARDWARE=1 ;;
            --llvm) LLVM=1 ;;
            --docs) DOCS=1 ;;
            --system-libs) SYSTEM_LIBS=1 ;;
            --strict) STRICT=1 ;;
            --dry-run)
                [[ "$MODE" != check ]] || die '--dry-run conflicts with --check-only.'
                MODE=plan ;;
            --check-only)
                [[ "$MODE" != plan ]] || die '--check-only conflicts with --dry-run.'
                MODE=check ;;
            -h|--help) HELP=1 ;;
            *) die "Unknown argument: $arg (use --help)." ;;
        esac
    done
}

host_info() {
    [[ -r /etc/os-release ]] || die 'Missing /etc/os-release.'
    # Trusted system file; never source a file from the working directory.
    # shellcheck disable=SC1091
    source /etc/os-release
    local minimum
    case "${ID:-}" in
        ubuntu) minimum=22.04 ;;
        debian) minimum=11 ;;
        *) die 'Only Ubuntu 22.04+ and Debian 11+ are supported by this installer.' ;;
    esac
    [[ -n "${VERSION_ID:-}" ]] || die 'A numeric distro VERSION_ID is required.'
    command -v dpkg >/dev/null || die 'dpkg is required.'
    dpkg --compare-versions "$VERSION_ID" ge "$minimum" || die "Host too old: ${PRETTY_NAME:-$ID}."
    HOST_ARCH=$(dpkg --print-architecture)
}

package_plan() {
    REQUIRED=(
        build-essential binutils make pkg-config git ca-certificates curl wget
        python3 perl patch diffutils coreutils findutils grep sed gawk file
        tar gzip bzip2 xz-utils unzip zstd rsync procps util-linux
        zlib1g-dev libbz2-dev liblzma-dev
    )
    OPTIONAL=()
    # Modern FFmpeg uses NASM for optimized x86 assembly, not YASM.
    case "$HOST_ARCH" in amd64|i386) REQUIRED+=(nasm) ;; esac
    if (( ! MINIMAL )); then
        # These also help build optional external libraries. FFmpeg itself
        # uses its own configure + GNU make, not CMake/autotools.
        OPTIONAL+=(
            autoconf automake libtool libtool-bin cmake ninja-build meson ccache
            gdb strace valgrind lcov git-email ripgrep universal-ctags
            libsdl2-dev libass-dev libfreetype6-dev libfontconfig1-dev
            libfribidi-dev libharfbuzz-dev
            libaom-dev libdav1d-dev libvpx-dev libsvtav1enc-dev
            libopus-dev libvorbis-dev libmp3lame-dev libspeex-dev libtheora-dev
            libwebp-dev libopenjp2-7-dev libsoxr-dev libgnutls28-dev
            libasound2-dev libpulse-dev libxcb1-dev libxcb-shm0-dev
            libxcb-xfixes0-dev libv4l-dev libxml2-dev
        )
        case "$ID" in
            debian) OPTIONAL+=(linux-perf) ;;
            ubuntu)
                OPTIONAL+=(linux-tools-common)
                # A vendor/container kernel may have no matching package.
                # Never install a different kernel to obtain perf.
                if [[ "$(uname -r)" =~ ^[a-zA-Z0-9.+-]+$ ]]; then
                    OPTIONAL+=("linux-tools-$(uname -r)")
                fi ;;
        esac
    fi
    if (( GPL )); then
        REQUIRED+=(libx264-dev libx265-dev)
        OPTIONAL+=(libxvidcore-dev libvidstab-dev librubberband-dev)
    fi
    if (( HARDWARE )); then
        OPTIONAL+=(
            libdrm-dev libva-dev libvdpau-dev libvulkan-dev
            glslang-dev glslang-tools spirv-tools libshaderc-dev
            opencl-headers ocl-icd-opencl-dev libplacebo-dev
            vainfo vulkan-tools clinfo libffmpeg-nvenc-dev
        )
        case "$HOST_ARCH" in
            amd64|i386)
                # Select one QSV development API; don't assume both can coexist.
                OPTIONAL+=('libvpl-dev|libmfx-dev') ;;
        esac
    fi
    if (( LLVM )); then
        REQUIRED+=(clang llvm lld)
        OPTIONAL+=(clang-tools clang-format clang-tidy)
    fi
    if (( DOCS )); then
        REQUIRED+=(texinfo doxygen graphviz)
        OPTIONAL+=(texi2html)
    fi
    if (( SYSTEM_LIBS )); then
        REQUIRED+=(
            libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev
            libavdevice-dev libswscale-dev libswresample-dev
        )
    fi
}

print_plan() {
    log "Host: ${PRETTY_NAME:-$ID} / $HOST_ARCH"
    printf 'Mode: %s; minimal=%s gpl=%s hardware=%s llvm=%s docs=%s system-libs=%s\n' \
        "$MODE" "$MINIMAL" "$GPL" "$HARDWARE" "$LLVM" "$DOCS" "$SYSTEM_LIBS"
    printf '\nRequired packages:\n'; printf '  %s\n' "${REQUIRED[@]}"
    if ((${#OPTIONAL[@]})); then
        printf '\nSupplementary packages (A|B means choose one available alternative):\n'
        printf '  %s\n' "${OPTIONAL[@]}"
    fi
    if (( GPL )); then
        printf '\nGPL libraries selected. Enabling them in FFmpeg requires --enable-gpl.\n'
        printf 'Installing headers alone does not change the license of an existing FFmpeg.\n'
    fi
    if (( HARDWARE )); then
        printf '\nHardware selection supplies headers/loaders/tools, NOT working GPU support.\n'
        printf 'Drivers, devices, permissions and FFmpeg/header versions still have to match.\n'
    fi
    printf '\nNo FFmpeg executable is requested. Normal APT dependencies may be installed/upgraded.\n'
}

installed() {
    local state
    state=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
    [[ "$state" == 'install ok installed' ]]
}

candidate_available() {
    local candidate
    candidate=$(apt-cache policy "$1" 2>/dev/null | awk '$1 == "Candidate:" {print $2}') || return 1
    [[ -n "$candidate" && "$candidate" != '(none)' ]]
}

pick_package() {
    # Return a real package name, not a shell string or virtual package guess.
    local spec="$1" pkg
    local -a alternatives=()
    IFS='|' read -r -a alternatives <<< "$spec"
    for pkg in "${alternatives[@]}"; do
        if [[ "$MODE" == check ]]; then
            if installed "$pkg"; then printf '%s\n' "$pkg"; return 0; fi
        elif installed "$pkg" || candidate_available "$pkg"; then
            printf '%s\n' "$pkg"; return 0
        fi
    done
    return 1
}

resolve_packages() {
    SELECTED=(); SELECTED_REQUIRED=(); SELECTED_OPTIONAL=(); SKIPPED=()
    local -a missing=()
    local spec pkg
    local -A seen=()
    for spec in "${REQUIRED[@]}"; do
        if pkg=$(pick_package "$spec"); then
            SELECTED_REQUIRED+=("$pkg")
            if [[ -z "${seen[$pkg]:-}" ]]; then SELECTED+=("$pkg"); seen[$pkg]=1; fi
        else
            missing+=("$spec")
        fi
    done
    for spec in "${OPTIONAL[@]}"; do
        if pkg=$(pick_package "$spec"); then
            SELECTED_OPTIONAL+=("$pkg")
            if [[ -z "${seen[$pkg]:-}" ]]; then SELECTED+=("$pkg"); seen[$pkg]=1; fi
        else
            SKIPPED+=("$spec")
        fi
    done
    if ((${#missing[@]})); then
        printf '\nRequired packages unavailable/not installed:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        die 'Check enabled repositories and architecture, or install the required packages first.'
    fi
    if ((${#SKIPPED[@]})); then
        warn 'Some supplementary packages are unavailable/not installed:'
        printf '  %s\n' "${SKIPPED[@]}" >&2
        printf 'No repository was enabled. For Ubuntu, some packages require universe.\n' >&2
    fi
}

verify_tools() {
    log 'Tool versions (not a branch-specific compatibility guarantee)'
    local cmd output
    for cmd in gcc g++ make ld git python3 perl pkg-config rsync; do
        command -v "$cmd" >/dev/null || die "Required tool missing: $cmd"
        output=$("$cmd" --version 2>&1) || die "Could not run $cmd --version."
        # sed consumes all input (avoids pipefail/SIGPIPE from head).
        printf '%-12s %s\n' "$cmd" "$(printf '%s\n' "$output" | sed -n '/./{p;q;}')"
    done
    case "$HOST_ARCH" in
        amd64|i386) nasm -v || die 'NASM is required for this native x86 profile.' ;;
    esac
    if (( LLVM )); then clang --version; llvm-config --version; ld.lld --version; fi
    if (( ! MINIMAL )); then
        if command -v perf >/dev/null; then
            if ! perf --version; then warn 'perf wrapper found, but matching kernel tools may be missing.'; fi
        else
            warn 'perf is not available for this host/kernel.'
        fi
    fi
}

verify_libraries() {
    log 'Installed library metadata'
    local pkg module version
    local -a modules=(zlib liblzma)
    if (( ! MINIMAL )); then
        modules+=(
            sdl2 libass freetype2 fontconfig fribidi harfbuzz
            aom dav1d vpx SvtAv1Enc opus vorbis vorbisenc
            speex theoradec theoraenc libwebp libopenjp2 soxr gnutls
            alsa libpulse xcb xcb-shm xcb-xfixes libv4l2 libxml-2.0
        )
    fi
    if (( GPL )); then modules+=(x264 x265 xvidcore vidstab rubberband); fi
    if (( HARDWARE )); then modules+=(libdrm libva vdpau vulkan OpenCL libplacebo ffnvcodec vpl libmfx); fi
    if (( SYSTEM_LIBS )); then modules+=(libavcodec libavformat libavutil libavfilter libavdevice libswscale libswresample); fi
    for module in "${modules[@]}"; do
        if version=$(pkg-config --modversion "$module" 2>/dev/null); then
            printf '%-20s %s\n' "$module" "$version"
        else
            printf '%-20s %s\n' "$module" 'not found via pkg-config (may be optional/API alternative)'
        fi
    done
    # These are the small mandatory smoke-test libraries, or explicitly selected APIs.
    pkg-config --exists zlib liblzma || die 'Compression pkg-config metadata missing.'
    if (( GPL )); then pkg-config --exists x264 x265 || die 'x264/x265 pkg-config metadata missing.'; fi
    if (( SYSTEM_LIBS )); then
        pkg-config --exists libavcodec libavformat libavutil libavfilter libavdevice libswscale libswresample \
            || die 'Requested system FFmpeg development metadata missing.'
    fi
    for pkg in "${SELECTED_REQUIRED[@]}"; do installed "$pkg" || die "Required package not installed: $pkg"; done
    for pkg in "${SELECTED_OPTIONAL[@]}"; do installed "$pkg" || warn "Supplementary package not installed: $pkg"; done
    printf '\nNot all libraries ship .pc files. LAME/bzip2 can use direct compiler checks.\n'
    printf 'Presence does not establish the minimum version required by your FFmpeg checkout.\n'
}

smoke_checks() {
    log 'Native C17, linking and assembly checks'
    local directory="$1" format
    cat > "$directory/probe.c" <<'C'
#include <stdio.h>
#include <zlib.h>
#include <bzlib.h>
#include <lzma.h>
#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 201710L
#error A C17 compiler is required for this development profile.
#endif
int main(void) {
    printf("C17/link smoke OK: zlib %s; bzip2 %s; liblzma %s\n",
           zlibVersion(), BZ2_bzlibVersion(), lzma_version_string());
    return 0;
}
C
    timeout 60 gcc -std=c17 -Wall -Wextra -Werror "$directory/probe.c" \
        -o "$directory/probe" -lz -lbz2 -llzma
    timeout 10 "$directory/probe" || die 'Cannot run smoke binary; check executable-mount/security restrictions.'
    case "$HOST_ARCH" in
        amd64|i386)
            format=elf64; [[ "$HOST_ARCH" != i386 ]] || format=elf32
            printf 'section .text\nglobal ffmpeg_prereq_probe\nffmpeg_prereq_probe:\n    ret\n' > "$directory/probe.asm"
            timeout 30 nasm -f "$format" "$directory/probe.asm" -o "$directory/probe-asm.o"
            file "$directory/probe-asm.o" ;;
    esac
    if (( LLVM )); then
        timeout 60 clang -std=c17 -Wall -Wextra -Werror -fuse-ld=lld \
            "$directory/probe.c" -o "$directory/probe-clang" -lz -lbz2 -llzma
        timeout 10 "$directory/probe-clang"
    fi
    if (( SYSTEM_LIBS )); then
        cat > "$directory/libav-probe.c" <<'C'
#include <stdio.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
int main(void) {
    printf("Distro libav linking OK: avcodec=%u avformat=%u\n",
           avcodec_version(), avformat_version());
    return 0;
}
C
        # pkg-config output follows the system tool's whitespace-flag convention.
        # This probe intentionally uses the distro /usr paths, not SDK overrides.
        local -a cflags=() libs=()
        read -r -a cflags <<< "$(pkg-config --cflags libavcodec libavformat)"
        read -r -a libs <<< "$(pkg-config --libs libavcodec libavformat)"
        timeout 60 gcc -std=c17 -Wall -Wextra -Werror "${cflags[@]}" \
            "$directory/libav-probe.c" -o "$directory/libav-probe" "${libs[@]}"
        timeout 10 "$directory/libav-probe"
    fi
}

next_steps() {
    log 'Next steps (printed only; no FFmpeg build is started)'
    cat <<'EOF'
From a trusted FFmpeg source checkout, inspect ./configure --help first.
A base debug build, without optional external auto-detection:

    ./configure --disable-autodetect --disable-doc \
        --enable-debug=3 --disable-stripping --assert-level=2
    make -j"$(nproc)"
    ./ffmpeg -version
    make fate

For external libraries, reconfigure explicitly with the matching --enable-* flags.
Examples: --enable-libopus --enable-libvpx --enable-libass --enable-sdl2.
Check configure's summary for which encoders, decoders, filters and tools exist.

Many FATE cases require sample data. Download it only when you choose:

    make fate-rsync SAMPLES="$HOME/src/fate-suite"
    make fate SAMPLES="$HOME/src/fate-suite"

Use a separate clean build/configuration for each coverage or Valgrind run:
    --toolchain=gcov                 (then run tests and make lcov)
    --toolchain=valgrind-memcheck     (then run FATE)
    --toolchain=valgrind-massif       (heap profiling)

FATE samples can use substantial storage/bandwidth. They were NOT downloaded.
Do not disable assembly for performance comparisons just to bypass a tool error.
EOF
    if (( GPL )); then
        printf '\nFor x264/x265 builds: --enable-gpl --enable-libx264 --enable-libx265\n'
        printf 'Enabling GPL components changes the resulting FFmpeg licensing requirements.\n'
    fi
    if (( LLVM )); then printf '\nFor Clang builds: add --cc=clang --cxx=clang++ after reviewing configure help.\n'; fi
    if (( DOCS )); then printf '\nFor docs: omit --disable-doc; review make doc / make doxygen in your tree.\n'; fi
    if (( HARDWARE )); then
        cat <<'EOF'

GPU headers alone are not proof of acceleration. Driver, API/header, hardware,
FFmpeg version and device permissions must match. No runtime GPU was validated.
Do not enable both --enable-libvpl and --enable-libmfx in one configuration.
FDK-AAC, CUDA SDKs/NPP and --enable-nonfree are outside this installer.
EOF
    fi
}

main() {
    WARNINGS=0; TEMP_WORK=''
    parse_args "$@"
    if (( HELP )); then usage; return 0; fi
    # Keep a sourced Poky/SDK or Python/Conda environment out of native checks.
    # These changes exist only in this script process; the caller is untouched.
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CPP AR AS LD NM RANLIB STRIP
    unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH LD_LIBRARY_PATH
    unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR PKG_CONFIG
    unset GCC_EXEC_PREFIX COMPILER_PATH MAKEFLAGS MFLAGS CONFIG_SITE
    host_info
    package_plan
    print_plan
    if [[ "$MODE" == plan ]]; then
        printf '\nDry run: no changes. Availability/version/dependency resolution NOT checked.\n'
        return 0
    fi
    if [[ "$MODE" == install ]]; then
        (( EUID != 0 )) || die 'Run as your normal user, WITHOUT sudo. The script uses sudo for APT only.'
        command -v sudo >/dev/null || die 'Install sudo and grant your user package-install privileges first.'
        sudo -v
        local -a apt_options=(-o DPkg::Lock::Timeout=120 -o Acquire::Retries=3)
        sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" \
            -o APT::Update::Error-Mode=any update
        resolve_packages
        log 'APT dependency check (no removals permitted)'
        apt-get "${apt_options[@]}" --simulate install --no-install-recommends --no-remove "${SELECTED[@]}"
        log 'Installing prerequisites'
        sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" \
            install -y --no-install-recommends --no-remove "${SELECTED[@]}"
    else
        resolve_packages
    fi
    # Restrict pkg-config verification to the distro's native library directories.
    local triplet
    triplet=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
    export PKG_CONFIG_LIBDIR="/usr/lib/$triplet/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
    verify_tools
    verify_libraries
    TEMP_WORK=$(mktemp -d /tmp/ffmpeg-prereqs.XXXXXXXX)
    smoke_checks "$TEMP_WORK"
    log 'Host diagnostics'
    free -h
    df -h -- "$PWD"
    if [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
        printf 'perf_event_paranoid: '; cat /proc/sys/kernel/perf_event_paranoid
        printf 'Profiling access is governed by the host policy; no sysctl was changed.\n'
    fi
    next_steps
    printf '\nRequired package and native smoke checks passed. Supplementary warnings: %s\n' "$WARNINGS"
    printf 'No FFmpeg build, FATE run or hardware-acceleration test was performed.\n'
    if (( STRICT && WARNINGS )); then return 2; fi
    return 0
}

# The main guard also allows tests to load functions without running APT.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'rc=$?; printf "\nERROR at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
    trap 'if [[ -n "${TEMP_WORK:-}" && -d "$TEMP_WORK" ]]; then rm -rf -- "$TEMP_WORK"; fi' EXIT
    main "$@"
fi