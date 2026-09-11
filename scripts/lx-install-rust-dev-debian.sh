#!/usr/bin/env bash
# Debian 12/13 Rust development setup. Preview by default; changes require --apply.
# Sources checked 2026-09-11:
# https://rust-lang.org/tools/install/
# https://rust-lang.github.io/rustup/installation/other.html
# https://rust-lang.github.io/rustup/concepts/components.html
# https://doc.rust-lang.org/cargo/commands/cargo-install.html
# https://nexte.st/docs/installation/from-source/
# https://github.com/taiki-e/cargo-llvm-cov
# https://rustsec.org/
# https://embarkstudios.github.io/cargo-deny/
# https://github.com/bnjbvr/cargo-machete
# https://dystroy.org/bacon/
# https://github.com/flamegraph-rs/flamegraph
# https://github.com/rust-lang/miri
# https://rust-fuzz.github.io/book/cargo-fuzz/setup.html
# No project edits, sudo cargo, distro upgrades, removals, or security-policy changes.

usage() {
    cat <<'EOF'
Usage: ./install-rust-dev-debian.sh [OPTIONS]

Default: PREVIEW ONLY. No sudo, downloads, or installation.
Supported host: Debian 12 (bookworm) / 13 (trixie), amd64 or arm64.
Run as your normal user, not sudo ./script.

  --apply             Install selected packages, Rust components and helpers.
                      Refreshes APT indexes first; does NOT run a distro upgrade.
  --yes               Skip confirmation (only meaningful with --apply).
  --dry-run           Explicit preview; cannot be combined with --apply.
  --list              List the complete catalog and exit; changes nothing.
  --check-only        Check the selected setup without installation/downloads.
                      Offline smoke builds create temporary local artifacts.
  --minimal           Native prerequisites, stable Rust, rustfmt and Clippy only.
  --no-cargo-tools    Omit extra Cargo-installed helpers.
  --profiling         Add perf, Valgrind, strace, flamegraph and cargo-bloat.
  --nightly           Add a Miri-capable nightly + cargo-fuzz; keep the default.
  --arm64             Add aarch64-unknown-linux-gnu + GNU cross-linker/sysroot.
  --embedded          Add thumbv7em-none-eabihf (Cortex-M4F/M7 hard-float).
  --docs              Add Rust's offline documentation component.
  --update            Update an existing stable toolchain and selected helpers.
                      Without it, existing stable/tools are kept, not refreshed.
  --jobs N            Limit helper compilation to N jobs (default: 2).
  -h, --help          Show this help.

Normal profile:
  rustfmt, Clippy, rust-analyzer, rust-src, matching LLVM tools;
  cargo-nextest, cargo-llvm-cov, cargo-audit, cargo-deny, cargo-machete, bacon;
  native/FFI build libraries, CMake/Ninja, Clang/LLD, GDB/LLDB.

Safety:
  Preserves an existing rustup default, project pins and shell dotfiles.
  Fresh installations use stable. Cargo helpers build with stable and --locked.
  Does not upgrade rustup itself, run audit databases, fuzz projects, flash a
  board, tune perf permissions, add APT repositories, install editors/plugins,
  remove packages or modify global Cargo config. Failed helpers are reported.

Exit codes: 0 success/preview; 1 invalid input or core failure; 2 partial setup.
EOF
}

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
issue() { issues+=("$*"); printf 'WARNING: %s\n' "$*" >&2; }

parse_args() {
    apply=0; dry=0; yes=0; listing=0; check_only=0; minimal=0
    no_tools=0; profiling=0; nightly=0; arm64=0; embedded=0; docs=0; update=0; jobs=2
    while (($#)); do
        case "$1" in
            --apply) apply=1 ;;
            --dry-run) dry=1 ;;
            --yes) yes=1 ;;
            --list) listing=1 ;;
            --check-only) check_only=1 ;;
            --minimal) minimal=1 ;;
            --no-cargo-tools) no_tools=1 ;;
            --profiling) profiling=1 ;;
            --nightly) nightly=1 ;;
            --arm64) arm64=1 ;;
            --embedded) embedded=1 ;;
            --docs) docs=1 ;;
            --update) update=1 ;;
            --jobs)
                (($# >= 2)) || fail '--jobs needs a positive integer.'
                shift; jobs=$1
                [[ "$jobs" =~ ^[1-9][0-9]{0,2}$ ]] || fail '--jobs must be 1..999.'
                ;;
            -h|--help) usage; exit 0 ;;
            *) fail "Unknown argument: $1. Use --help." ;;
        esac
        shift
    done
    (( !(apply && dry) )) || fail 'Choose --apply or --dry-run, not both.'
    (( !(check_only && (apply || dry || listing)) )) || fail '--check-only is a separate mode.'
    (( !(listing && apply) )) || fail '--list cannot be combined with --apply.'
    (( !yes || apply )) || fail '--yes requires --apply.'
}

catalog() {
    # One entry per line; fields: group | crate | executable | description.
    cat <<'EOF'
standard|cargo-nextest|cargo-nextest|Test runner (also run cargo test --doc for doctests)
standard|cargo-llvm-cov|cargo-llvm-cov|LLVM source-based coverage
standard|cargo-audit|cargo-audit|Known-vulnerability checks against RustSec
standard|cargo-deny|cargo-deny|Dependency/license/source policy checks
standard|cargo-machete|cargo-machete|Find potentially unused dependencies
standard|bacon|bacon|Terminal background check/test watcher
profiling|flamegraph|cargo-flamegraph|Linux perf-based flamegraphs
profiling|cargo-bloat|cargo-bloat|Inspect binary size contributors
nightly|cargo-fuzz|cargo-fuzz|libFuzzer integration; fuzz runs need nightly
EOF
}

select_packages() {
    # Keep one package per line for easy editing.
    core_packages=(
        build-essential  # GCC/G++, Make, binutils and libc development files
        pkg-config       # Native library discovery
        libssl-dev       # OpenSSL headers for native TLS/FFI crates
        ca-certificates  # HTTPS trust roots
        curl             # Official rustup bootstrap download
        git              # Source control / git dependencies
        python3          # Build helpers and inspection
        file             # Verify output architecture
        xz-utils         # Archive support
    )
    dev_packages=(
        cmake
        ninja-build
        clang
        lld
        libclang-dev     # bindgen uses libclang, not just the clang executable
        gdb
        lldb
        zlib1g-dev
    )
    profile_packages=(
        linux-perf
        valgrind
        strace
        time
    )
    arm_packages=(
        gcc-aarch64-linux-gnu
        binutils-aarch64-linux-gnu
        libc6-dev-arm64-cross
    )
    required=("${core_packages[@]}")
    components=(rustfmt clippy)
    optional=(); targets=(); selected_tools=()
    if ((!minimal)); then
        required+=("${dev_packages[@]}")
        components+=(rust-analyzer rust-src llvm-tools-preview)
    fi
    if ((profiling)); then
        optional+=("${profile_packages[@]}")
        components+=(llvm-tools-preview)
    fi
    if ((nightly && minimal)); then required+=(clang); fi
    if ((arm64)); then required+=("${arm_packages[@]}"); targets+=(aarch64-unknown-linux-gnu); fi
    if ((embedded)); then targets+=(thumbv7em-none-eabihf); components+=(rust-src); fi
    if ((docs)); then components+=(rust-docs); fi
    local group crate bin description
    while IFS='|' read -r group crate bin description; do
        ((no_tools)) && continue
        case "$group" in
            standard) ((minimal)) && continue ;;
            profiling) ((!profiling)) && continue ;;
            nightly) ((!nightly)) && continue ;;
        esac
        selected_tools+=("$crate|$bin|$description")
    done < <(catalog)
    # Deduplicate component names without spawning sort.
    local c
    local -A seen=()
    local -a unique=()
    for c in "${components[@]}"; do
        if [[ ! ${seen[$c]+yes} ]]; then unique+=("$c"); seen[$c]=1; fi
    done
    components=("${unique[@]}")
}

list_all() {
    printf 'Core APT packages:\n  %s\n' "${core_packages[*]}"
    printf '\nStandard native/debug APT packages:\n  %s\n' "${dev_packages[*]}"
    printf '\nProfiling APT packages:\n  %s\n' "${profile_packages[*]}"
    printf '\nARM64 APT packages:\n  %s\n' "${arm_packages[*]}"
    printf '\nRustup: stable + rustfmt, clippy; standard adds rust-analyzer, rust-src, llvm-tools-preview.\n'
    printf 'Optional: rust-docs; nightly with miri/rust-src; ARM64 and Cortex-M targets.\n\n'
    printf '%-11s %-18s %s\n' GROUP CRATE PURPOSE
    local group crate bin description
    while IFS='|' read -r group crate bin description; do
        printf '%-11s %-18s %s\n' "$group" "$crate" "$description"
    done < <(catalog)
}

check_host() {
    [[ -r /etc/os-release ]] || fail 'Missing /etc/os-release.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == debian ]] || fail 'This script is for Debian 12/13, not derivatives or Ubuntu.'
    case "${VERSION_ID:-}" in 12|13) ;; *) fail "Unsupported Debian release: ${VERSION_ID:-unknown}." ;; esac
    arch=$(dpkg --print-architecture)
    case "$arch" in amd64|arm64) ;; *) fail "Supported/test-planned host architectures: amd64/arm64; detected $arch." ;; esac
    [[ ${HOME:-} == /* && -d "$HOME" ]] || fail 'HOME must be an existing absolute directory.'
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
    for path in "$CARGO_HOME" "$RUSTUP_HOME"; do
        [[ "$path" == /* && "$path" != / ]] || fail 'CARGO_HOME and RUSTUP_HOME must be absolute non-root paths.'
        [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || fail 'Rust home paths cannot contain newlines.'
        [[ ! -e "$path" || -d "$path" ]] || fail "Expected a directory: $path"
    done
    printf 'Host: %s / %s\n' "${PRETTY_NAME:-Debian}" "$arch"
}

find_rustup() {
    rustup_bin=''
    if [[ -x "$CARGO_HOME/bin/rustup" ]]; then
        rustup_bin="$CARGO_HOME/bin/rustup"
    elif [[ -n ${rustup_hint:-} && -x "$rustup_hint" ]]; then
        rustup_bin="$rustup_hint"
    elif command -v rustup >/dev/null 2>&1; then
        rustup_bin=$(command -v rustup)
    fi
}

nearest_existing() {
    local p=$1
    while [[ ! -d "$p" && "$p" != / ]]; do p=$(dirname -- "$p"); done
    printf '%s\n' "$p"
}

space_report() {
    printf '\nFilesystem space (%s; not a promised Rust download/build-size estimate):\n' "$1"
    df -h -- / "$(nearest_existing "$CARGO_HOME")" "$(nearest_existing "$RUSTUP_HOME")" "${TMPDIR:-/tmp}"
}

package_candidate() {
    apt-cache -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= policy "$1" 2>/dev/null |
        awk '/^[[:space:]]*Candidate:/ { if ($2 != "(none)") print $2; exit }'
}

resolve_packages() {
    packages=(); missing_core=()
    local pkg version
    for pkg in "${required[@]}"; do
        version=$(package_candidate "$pkg")
        if [[ -n "$version" ]]; then packages+=("$pkg"); else missing_core+=("$pkg"); fi
    done
    for pkg in "${optional[@]}"; do
        version=$(package_candidate "$pkg")
        if [[ -n "$version" ]]; then packages+=("$pkg"); else issue "No candidate for optional package: $pkg"; fi
    done
}

apt_preview() {
    # No sudo, downloads, locks, or APT cache writes. Uses existing indexes only.
    apt-get -s -o Debug::NoLocking=1 -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= \
        --no-install-recommends --no-remove install "${packages[@]}"
}

plan() {
    log 'Selected installation plan'
    printf 'APT required: %s\n' "${required[*]}"
    printf 'APT optional: %s\n' "${optional[*]:-(none)}"
    printf 'Rustup stable components: %s\n' "${components[*]}"
    printf 'Rust targets: %s\n' "${targets[*]:-(native only)}"
    if ((nightly)); then printf 'Nightly: minimal + miri + rust-src (default preserved).\n'; fi
    printf 'Cargo helper compilation jobs: %s\n' "$jobs"
    printf 'Cargo home: %s\nRustup home: %s\n' "$CARGO_HOME" "$RUSTUP_HOME"
    local crate bin description entry
    for entry in "${selected_tools[@]}"; do
        IFS='|' read -r crate bin description <<< "$entry"
        printf '  %-18s %s\n' "$crate" "$description"
    done
    if ((update)); then
        echo 'Updates requested: refresh stable and selected Cargo helpers.'
    else
        echo 'Existing stable/tool executables are kept. Use --update to refresh them.'
    fi
    echo 'Rustup itself is not self-updated; an existing default and all project pins are preserved.'
    echo 'No shell/profile/global Cargo settings will be edited. No crate will be installed with --force.'
    echo 'Cargo helpers compile from crates.io using --locked. This executes downloaded build code as your user.'
    echo 'Rust downloads, crate caches and temporary compilation sizes are unknown until resolution/build.'
    echo 'APT simulation below estimates only APT changes; it cannot estimate total Rust setup size.'
}

cleanup() {
    if [[ -n ${workdir:-} && -d "$workdir" ]]; then rm -rf -- "$workdir"; fi
}

prepare_user_runtime() {
    ((EUID != 0)) || fail 'Run as your normal user, WITHOUT sudo. Only APT is elevated.'
    [[ -z ${OECORE_NATIVE_SYSROOT:-} && -z ${SDKTARGETSYSROOT:-} ]] ||
        fail 'Open a fresh host shell outside the sourced Yocto SDK before running this installer.'
    local p
    for p in "$CARGO_HOME" "$RUSTUP_HOME"; do
        if [[ -e "$p" ]]; then
            [[ -O "$p" && -w "$p" ]] || fail "Not a writable user-owned directory: $p"
        fi
    done
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/rust-dev-setup.XXXXXXXX")
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Deliberately leave the user's repository before invoking Cargo/rustup.
    cd "$workdir"
    export PATH="$CARGO_HOME/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
    export RUSTUP_AUTO_INSTALL=0 CARGO_LLVM_COV_SETUP=no
    unset RUSTUP_TOOLCHAIN RUSTC RUSTDOC CARGO_BUILD_TARGET CARGO_TARGET_DIR
    unset RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTC_BOOTSTRAP
    unset RUSTFLAGS RUSTDOCFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_ENCODED_RUSTDOCFLAGS
    unset CC CXX CPP AR AS LD NM RANLIB STRIP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
    unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR PKG_CONFIG_PATH CMAKE_TOOLCHAIN_FILE
    unset LLVM_COV LLVM_PROFDATA CARGO_LLVM_COV_TARGET_DIR CARGO_LLVM_COV_BUILD_DIR
    export CARGO_BUILD_JOBS="$jobs"
}

ensure_rustup() {
    find_rustup
    if [[ -n "$rustup_bin" ]]; then "$rustup_bin" --version; return; fi
    local cmd
    for cmd in rustc cargo; do
        if command -v "$cmd" >/dev/null 2>&1; then
            fail "Found $cmd without rustup ($(command -v "$cmd")). Reconcile that installation first; nothing will be removed automatically."
        fi
    done
    log 'Downloading the official rustup installer (user installation)'
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --connect-timeout 20 --max-time 180 --retry 3 \
        https://sh.rustup.rs -o "$workdir/rustup-init.sh"
    [[ -s "$workdir/rustup-init.sh" ]] || fail 'Empty rustup installer.'
    sh "$workdir/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain none
    rustup_bin="$CARGO_HOME/bin/rustup"
    [[ -x "$rustup_bin" ]] || fail 'rustup did not install at the selected Cargo home.'
}

stable_exists() {
    "$rustup_bin" toolchain list | grep -Eq '^stable(-|[[:space:]]|$)'
}

setup_toolchains() {
    if ((update)) || ! stable_exists; then
        "$rustup_bin" toolchain install stable --profile minimal --no-self-update
    fi
    # Read only: no implicit change of an already configured global default.
    if ! "$rustup_bin" default >/dev/null 2>&1; then "$rustup_bin" default stable; fi
    "$rustup_bin" component add --toolchain stable "${components[@]}"
    if ((${#targets[@]})); then "$rustup_bin" target add --toolchain stable "${targets[@]}"; fi
    if ((nightly)); then
        if ! "$rustup_bin" toolchain install nightly --profile minimal --component miri --component rust-src \
            --allow-downgrade --no-self-update; then
            issue 'Nightly/Miri installation failed. Stable remains usable; no default was changed.'
        fi
    fi
}

rust() { "$rustup_bin" run stable "$@"; }

install_helpers() {
    local entry crate bin description
    for entry in "${selected_tools[@]}"; do
        IFS='|' read -r crate bin description <<< "$entry"
        if [[ -x "$CARGO_HOME/bin/$bin" ]] && ((!update)); then
            printf 'Keep existing helper: %s (use --update to refresh).\n' "$bin"
            continue
        fi
        log "Installing $crate"
        # Use --target so a user's global build.target cannot cross-compile our tools.
        if ! CARGO_TARGET_DIR="$workdir/helper-target" rust cargo install --locked --registry crates-io \
            --root "$CARGO_HOME" --target "$host_triple" --jobs "$jobs" "$crate"; then
            issue "$crate installation failed; no automatic --force/replacement attempted."
        fi
    done
}

verify_setup() {
    local pkg version entry crate bin description cmd
    log 'Installed packages and compiler checks'
    for pkg in "${required[@]}" "${optional[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then
            issue "Package not installed: $pkg"
        fi
    done
    find_rustup
    if [[ -z "$rustup_bin" ]] || ! stable_exists; then
        issue 'No rustup-managed stable toolchain is installed.'
        return
    fi
    rust rustc -vV
    rust cargo --version
    host_triple=$(rust rustc -vV | sed -n 's/^host: //p')
    [[ -n "$host_triple" ]] || fail 'Could not identify the Rust host target.'
    for cmd in rustfmt cargo-clippy; do
        if ! rust "$cmd" --version; then issue "Missing/broken stable component: $cmd"; fi
    done
    if ((!minimal)); then
        if ! rust rust-analyzer --version; then issue 'rust-analyzer unavailable in stable.'; fi
    fi
    local installed c key
    installed=$("$rustup_bin" component list --installed --toolchain stable)
    for c in "${components[@]}"; do
        key=${c%-preview}
        if ! grep -Eq "^${key}(-preview)?(-|[[:space:]]|$)" <<< "$installed"; then
            issue "Selected stable component missing: $c"
        fi
    done
    for entry in "${selected_tools[@]}"; do
        IFS='|' read -r crate bin description <<< "$entry"
        if [[ ! -x "$CARGO_HOME/bin/$bin" ]]; then issue "Helper missing from Cargo home: $bin"; continue; fi
        case "$bin" in
            cargo-*)
                if ! rust cargo "${bin#cargo-}" --version; then issue "Cannot run $bin --version"; fi ;;
            *) if ! "$CARGO_HOME/bin/$bin" --version; then issue "Cannot run $bin --version"; fi ;;
        esac
    done
    if ((nightly)); then
        if ! "$rustup_bin" run nightly cargo miri --version; then issue 'Nightly Miri is not available.'; fi
    fi
    log 'Offline scratch-project smoke: build, unit tests, doctests, formatting, Clippy'
    # This project has no external dependencies and is never written into a user repo.
    mkdir -p "$workdir/smoke/src"
    cat > "$workdir/smoke/Cargo.toml" <<'EOF'
[package]
name = "rust_dev_setup_smoke"
version = "0.1.0"
edition = "2021"
publish = false

[workspace]
EOF
    cat > "$workdir/smoke/src/lib.rs" <<'EOF'
/// Add two small integers.
/// ```
/// assert_eq!(rust_dev_setup_smoke::add(2, 3), 5);
/// ```
pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn add_works() {
        assert_eq!(super::add(20, 22), 42);
    }
}
EOF
    cat > "$workdir/smoke/src/main.rs" <<'EOF'
fn main() {
    assert_eq!(rust_dev_setup_smoke::add(20, 22), 42);
    println!("Rust development smoke: OK");
}
EOF
    (
        cd "$workdir/smoke"
        export CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$workdir/smoke-target"
        rust cargo generate-lockfile --offline &&
        rust cargo fmt --all --check &&
        rust cargo clippy --frozen --target "$host_triple" --all-targets -- -D warnings &&
        rust cargo test --frozen --target "$host_triple" &&
        rust cargo run --frozen --target "$host_triple"
    ) || fail 'Native Rust smoke failed. Check toolchain, native linker and global Cargo configuration.'
    if [[ -x "$CARGO_HOME/bin/cargo-nextest" ]] && ((!no_tools && !minimal)); then
        if ! (cd "$workdir/smoke"; CARGO_TARGET_DIR="$workdir/smoke-target" rust cargo nextest run --frozen --target "$host_triple"); then
            issue 'Nextest scratch test failed.'
        fi
    fi
    if [[ -x "$CARGO_HOME/bin/cargo-llvm-cov" ]] && ((!no_tools && !minimal)); then
        if ! (cd "$workdir/smoke"; CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$workdir/coverage-target" \
            rust cargo llvm-cov --frozen --target "$host_triple" --lcov --output-path "$workdir/coverage.lcov") ||
            [[ ! -s "$workdir/coverage.lcov" ]]; then
            issue 'LLVM coverage scratch test failed.'
        fi
    fi
    local target
    printf '#![no_std]\npub fn add(a: u32, b: u32) -> u32 { a + b }\n' > "$workdir/cross.rs"
    for target in "${targets[@]}"; do
        if rust rustc --crate-type lib --crate-name cross_smoke --target "$target" \
            "$workdir/cross.rs" -o "$workdir/$target.rlib"; then
            printf 'Cross target %s: no_std library compilation OK (not a firmware/linker test).\n' "$target"
        else issue "Cross-target smoke failed: $target"; fi
    done
    if ((arm64)); then
        printf 'int main(void) { return 0; }\n' > "$workdir/arm64.c"
        if aarch64-linux-gnu-gcc "$workdir/arm64.c" -o "$workdir/arm64-native-link"; then
            file "$workdir/arm64-native-link"
        else issue 'ARM64 C linker/sysroot smoke failed.'; fi
    fi
    if ((profiling)); then
        printf '\nperf_event_paranoid: '; cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true
        printf 'kptr_restrict: '; cat /proc/sys/kernel/kptr_restrict 2>/dev/null || true
        if command -v perf >/dev/null 2>&1; then perf --version || issue 'perf exists but cannot run.'; fi
        echo 'Profiling access was not changed/tested; kernel/container policy may restrict perf.'
    fi
}

finish() {
    log 'Shell setup (this script does not edit dotfiles)'
    printf 'export CARGO_HOME=%q\nexport RUSTUP_HOME=%q\n' "$CARGO_HOME" "$RUSTUP_HOME"
    printf 'export PATH=%q:"$PATH"\n' "$CARGO_HOME/bin"
    echo 'Then: hash -r; rustup show; rustc --version; cargo --version'
    echo 'An existing default is preserved. Use cargo +stable explicitly if your default is not stable.'
    if ((arm64)); then
        echo 'ARM64 project linker (set only when needed):'
        echo 'export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc'
        echo 'cargo +stable build --target aarch64-unknown-linux-gnu'
        echo 'Native/FFI dependencies still need a matching target sysroot.'
    fi
    if ((embedded)); then
        echo 'Cortex-M target: thumbv7em-none-eabihf; the project still needs its BSP/HAL, memory map and runner.'
    fi
    if ((nightly)); then echo 'Miri/fuzz installed only; no project Miri run or fuzz campaign was performed.'; fi
    if ((${#issues[@]})); then
        printf '\nPARTIAL: %s issue(s):\n' "${#issues[@]}"
        printf '  - %s\n' "${issues[@]}"
        return 2
    fi
    echo 'Selected setup checks passed. No existing application or kernel was built or modified.'
}

main() {
    set -Eeuo pipefail
    trap 'printf "\nERROR at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR
    issues=(); workdir=''; host_triple=''
    parse_args "$@"
    select_packages
    if ((listing)); then list_all; return; fi
    # Native APT tools rather than a sourced SDK PATH. Keep a detected rustup path.
    local original_rustup
    original_rustup=$(type -P rustup || true)
    rustup_hint=$original_rustup
    export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
    export LC_ALL=C
    check_host
    if [[ -n "$original_rustup" ]]; then
        export PATH="$(dirname -- "$original_rustup"):$PATH"
    fi
    plan
    space_report BEFORE
    if ((!apply && !check_only)); then
        resolve_packages
        if ((${#missing_core[@]})); then
            printf '\nAPT indexes have no candidate for: %s\n' "${missing_core[*]}"
            echo 'Preview incomplete: --apply refreshes indexes, then checks again before installation.'
        elif ! apt_preview; then
            echo 'APT simulation failed; the installation path will refuse an unresolved transaction.'
        fi
        echo 'PREVIEW ONLY: no packages, Rust toolchains or Cargo helpers installed; no downloads or sudo.'
        return 0
    fi
    prepare_user_runtime
    if ((check_only)); then
        export CARGO_NET_OFFLINE=true
        verify_setup
        cleanup; workdir=''
        space_report AFTER_CHECK
        finish
        return
    fi
    command -v sudo >/dev/null 2>&1 || fail 'Install sudo and grant your user APT access first.'
    find_rustup
    if [[ -z "$rustup_bin" ]] && { command -v cargo >/dev/null 2>&1 || command -v rustc >/dev/null 2>&1; }; then
        fail 'Existing Rust without rustup detected. Reconcile it first; no automatic removal or overwrite.'
    fi
    if ((!yes)); then
        [[ -t 0 ]] || fail 'Interactive confirmation required; use --apply --yes after reviewing the preview.'
        local response
        read -r -p 'Refresh APT and install this selected setup? Type INSTALL: ' response
        [[ "$response" == INSTALL ]] || { echo 'Cancelled.'; return 0; }
    fi
    sudo -v
    local -a apt_options=(-o DPkg::Lock::Timeout=120 -o Acquire::Retries=3)
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" -o APT::Update::Error-Mode=any update
    resolve_packages
    ((${#missing_core[@]} == 0)) || fail "Required packages unavailable: ${missing_core[*]}. No repositories were added."
    apt_preview || fail 'APT cannot resolve the selected packages without removals.'
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y \
        --no-install-recommends --no-remove "${packages[@]}"
    ensure_rustup
    setup_toolchains
    host_triple=$(rust rustc -vV | sed -n 's/^host: //p')
    [[ -n "$host_triple" ]] || fail 'Could not identify native Rust target.'
    install_helpers
    verify_setup
    # Report after cleanup, excluding only this script's temporary build artifacts.
    cleanup; workdir=''
    space_report AFTER
    finish
}

# Sourcing only defines functions: useful for isolated tests; normal execution runs main.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
