#!/usr/bin/env bash
# Native x86-64 kernel development on Debian 12/13 or Ubuntu 22.04/24.04.
# Bash orchestrates Kbuild, initramfs-tools and kexec-tools. No embedded Python.
# Default: read-only preflight. --apply: build -> install -> load, NEVER reboot.
# SPDX-License-Identifier: MIT
# References and operational limitations: lx-kernel-hacking-README.md
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: lx-kernel-hacking.sh [options]

Default: inspect the local source/host and print a plan, without running make,
installing packages, writing files or loading a kernel. Changes need --apply.

  --source DIR          Existing Linux source tree (default: ~/src/linux)
  --build-dir DIR       Separate output directory (default: ~/build/linux-lxdev)
  --config FILE         Seed configuration for a NEW output directory
                        Otherwise reuse its .config, or the running config
  --jobs N              Parallel jobs (default: RAM-aware, at most 4)
  --localversion TEXT   Explicit suffix, e.g. -lxdev-test1 (must start -lxdev)
                        Default: -lxdev-<UTC timestamp>-<pid>
  --menuconfig          Open menuconfig before compiling
  --clear-distro-certs  Clear extra trusted/revoked certificate filenames in
                        THIS development config only; review security implications
  --install-deps        With --apply, install native build/runtime APT packages
  --build-only         Configure and compile; no module install/initramfs/kexec
  --no-load            Build and install a bundle, but do not load it
  --load-only          Load an already installed bundle; requires --release
  --release RELEASE    Exact release for --load-only
  --cmdline TEXT       Replace the entire boot command line (advanced)
                        Default: kexec --reuse-cmdline
  --status             Show running release, normal/crash kexec slots and policy
  --unload             Unload NORMAL kexec slot; requires --apply, not --release
  --apply              Allow the selected actions; still NEVER reboot
  --dry-run            Explicit read-only mode (incompatible with --apply)
  --yes                Skip BUILD/INSTALL/LOAD/UNLOAD prompts; never implies reboot
  -h, --help           Show this help

Examples:
  ./lx-kernel-hacking.sh --source ~/src/linux
  ./lx-kernel-hacking.sh --source ~/src/linux --install-deps --apply
  ./lx-kernel-hacking.sh --source ~/src/linux --menuconfig --build-only --apply
  ./lx-kernel-hacking.sh --load-only --release <exact-release> --apply
  ./lx-kernel-hacking.sh --status
  ./lx-kernel-hacking.sh --unload --apply

Run as your normal user, NOT sudo ./lx-kernel-hacking.sh.
Keep your distribution kernel and a recovery console. Build success and a loaded
kexec slot do NOT prove the new kernel will boot or support your hardware.
EOF
}

info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
show_cmd() { printf ' +'; printf ' %q' "$@"; printf '\n'; }
on_error() {
    local rc=$1 line=$2
    trap - ERR
    printf '\nERROR: stopped at line %s (exit %s).\n' "$line" "$rc" >&2
    [[ -z ${LOG_FILE:-} ]] || printf 'Log: %s\n' "$LOG_FILE" >&2
    printf 'No reboot requested. Partial outputs are kept; nothing is auto-deleted.\n' >&2
    exit "$rc"
}
confirm() {
    local token=$1 answer
    (( YES )) && return 0
    [[ -t 0 ]] || die "Interactive confirmation required; use --yes after reviewing the plan."
    read -r -p "Type $token to continue: " answer
    [[ $answer == "$token" ]] || die 'Cancelled.'
}

init_defaults() {
    SRC=${HOME:?}/src/linux; BUILD=$HOME/build/linux-lxdev
    CONFIG_INPUT=''; JOBS=''; SUFFIX=''; MODE=full; RELEASE=''
    APPLY=0; DRY=0; YES=0; MENU=0; CLEAR_CERTS=0; INSTALL_DEPS=0
    CMDLINE=''; CUSTOM_CMDLINE=0; LOG_FILE=''; SEED=''; SEED_GZIP=0
    BOOT_DIR=/boot; MODULES_BASE=/lib/modules
    BUNDLES_BASE=/var/lib/lx-kernel-hacking
    KEXEC_SLOT=/sys/kernel/kexec_loaded
    CRASH_SLOT=/sys/kernel/kexec_crash_loaded
    LOAD_DISABLED=/proc/sys/kernel/kexec_load_disabled
    LOCKDOWN=/sys/kernel/security/lockdown
}
arg_value() {
    [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 needs a value."
}
set_mode() {
    [[ $MODE == full ]] || die 'Choose only one of --build-only/--no-load/--load-only/--status/--unload.'
    MODE=$1
}
parse_args() {
    while (($#)); do
        case $1 in
            --source) arg_value "$@"; SRC=$2; shift 2 ;;
            --build-dir) arg_value "$@"; BUILD=$2; shift 2 ;;
            --config) arg_value "$@"; CONFIG_INPUT=$2; shift 2 ;;
            --jobs|-j) arg_value "$@"; JOBS=$2; shift 2 ;;
            --localversion) arg_value "$@"; SUFFIX=$2; shift 2 ;;
            --release) arg_value "$@"; RELEASE=$2; shift 2 ;;
            --cmdline) arg_value "$@"; CMDLINE=$2; CUSTOM_CMDLINE=1; shift 2 ;;
            --menuconfig) MENU=1; shift ;;
            --clear-distro-certs) CLEAR_CERTS=1; shift ;;
            --install-deps) INSTALL_DEPS=1; shift ;;
            --build-only) set_mode build; shift ;;
            --no-load) set_mode install; shift ;;
            --load-only) set_mode load; shift ;;
            --status) set_mode status; shift ;;
            --unload) set_mode unload; shift ;;
            --apply) APPLY=1; shift ;;
            --dry-run) DRY=1; shift ;;
            --yes) YES=1; shift ;;
            --help|-h) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    (( ! (APPLY && DRY) )) || die '--dry-run and --apply are mutually exclusive.'
    [[ -z $JOBS || $JOBS =~ ^[1-9][0-9]{0,3}$ ]] || die '--jobs must be 1..9999.'
    [[ -z $SUFFIX || $SUFFIX =~ ^-lxdev[A-Za-z0-9._+-]{0,35}$ ]] || die 'Use a suffix starting -lxdev, with at most 41 safe characters.'
    if (( CUSTOM_CMDLINE )); then
        [[ $CMDLINE != *[$'\001'-$'\037'$'\177']* && ${#CMDLINE} -le 2047 ]] || die '--cmdline must be one printable line, at most 2047 bytes.'
    fi
    if [[ $MODE == load ]]; then
        valid_release "$RELEASE" || die '--load-only requires a safe --release containing -lxdev.'
    elif [[ -n $RELEASE ]]; then die '--release is only used with --load-only.'; fi
    if [[ $MODE == load || $MODE == status || $MODE == unload ]]; then
        (( !MENU && !CLEAR_CERTS && !INSTALL_DEPS )) || die 'Build/dependency flags are not valid for this action.'
        [[ -z $CONFIG_INPUT && -z $SUFFIX && -z $JOBS ]] || die 'Config/version/jobs flags are not valid for this action.'
    fi
    if (( CUSTOM_CMDLINE )) && [[ $MODE != full && $MODE != load ]]; then
        die '--cmdline applies only when loading a kernel.'
    fi
}
valid_release() {
    [[ $1 =~ ^[0-9][A-Za-z0-9._+-]*-lxdev[A-Za-z0-9._+-]*$ && ${#1} -le 64 ]]
}
require_normal_user() { (( EUID != 0 )) || die 'Run as a normal user; the script uses sudo only for privileged operations.'; }

read_value() { if [[ -r $1 ]]; then cat -- "$1"; else printf 'unavailable'; fi; }
show_status() {
    printf 'Running kernel: %s\n' "$(uname -r)"
    printf 'Normal kexec slot (0=empty, 1=loaded): %s\n' "$(read_value "$KEXEC_SLOT")"
    printf 'Crash kexec slot (not modified):      %s\n' "$(read_value "$CRASH_SLOT")"
    printf 'kexec_load_disabled:                 %s\n' "$(read_value "$LOAD_DISABLED")"
    printf 'Lockdown:                            %s\n' "$(read_value "$LOCKDOWN")"
    if command -v mokutil >/dev/null; then mokutil --sb-state 2>/dev/null || true; fi
    echo 'The normal slot flag does not identify the loaded release.'
}
platform_check() {
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'This script supports native Linux x86-64 only; it is not an ARM cross-build loader.'
    [[ -r /etc/os-release ]] || die 'Missing /etc/os-release.'
    # shellcheck disable=SC1091
    source /etc/os-release
    case ${ID:-}:${VERSION_ID:-} in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
        *) die "Supported hosts: Debian 12/13, Ubuntu 22.04/24.04. Found ${PRETTY_NAME:-unknown}." ;;
    esac
    printf 'Host: %s\n' "$PRETTY_NAME"
    if [[ $MODE != build ]]; then
        if [[ -e /.dockerenv || -e /run/.containerenv ]] ||
           { command -v systemd-detect-virt >/dev/null && systemd-detect-virt --container --quiet; }; then
            die 'Install/load/unload is refused in a container. Use --build-only or a native development host.'
        fi
        [[ $(uname -r) != *[Mm]icrosoft* ]] || die 'WSL install/kexec is outside this script scope.'
    fi
}
protected_host() {
    if [[ -r $LOCKDOWN ]] && grep -Eq '\[(integrity|confidentiality)\]' "$LOCKDOWN"; then return 0; fi
    local f flag
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -r $f ]] || continue
        flag=$(od -An -j4 -N1 -tu1 -- "$f")
        [[ ${flag//[[:space:]]/} == 1 ]] && return 0
    done
    return 1
}
runtime_check() {
    [[ -r $KEXEC_SLOT ]] || die 'Normal kexec status is unavailable. Current kernel may lack kexec, or /sys is restricted.'
    [[ $(read_value "$LOAD_DISABLED") != 1 ]] || die 'kernel.kexec_load_disabled=1. No policy change is attempted.'
    if [[ $MODE != unload ]] && protected_host; then
        die 'Secure Boot/lockdown is active. This unsigned-kernel workflow will not load. Use --build-only/--no-load, then a trusted signing/enrollment workflow. No bypass is attempted.'
    fi
    if [[ $MODE != unload ]]; then
        if [[ -r $BOOT_DIR/config-$(uname -r) ]] &&
           ! grep -q '^CONFIG_KEXEC_FILE=y$' "$BOOT_DIR/config-$(uname -r)"; then
            die 'Running-kernel configuration lacks CONFIG_KEXEC_FILE=y. This helper requires kexec_file_load; use --build-only/--no-load.'
        fi
        [[ $(read_value "$KEXEC_SLOT") == 0 ]] || die 'A normal kexec image is already loaded. Review it and explicitly unload before replacing it.'
    fi
}

canonical_build_path() {
    local path=$1
    [[ $path != *[[:space:]]* && $path != *['#$%:;\\']* ]] || die 'Use source/output paths without whitespace or Make-special characters.'
    realpath -m -- "$path"
}
resolve_source() {
    SRC=$(canonical_build_path "$SRC"); BUILD=$(canonical_build_path "$BUILD")
    [[ -d $SRC && -f $SRC/Makefile && -f $SRC/Kconfig && -d $SRC/arch/x86 && -f $SRC/scripts/config ]] || die "No complete Linux source tree at $SRC. Clone/extract trusted kernel source first."
    [[ $BUILD != / && $BUILD != "$HOME" && $BUILD != "$SRC" && $BUILD != "$SRC"/* && $SRC != "$BUILD"/* ]] || die 'Use a dedicated output directory OUTSIDE the source tree, not an ancestor of it.'
    if [[ -f $SRC/.config || -d $SRC/include/config || -d $SRC/include/generated ]]; then
        die 'Source contains in-tree build output. Use a clean checkout/worktree for O= builds; no mrproper is run automatically.'
    fi
    if [[ -e $BUILD ]]; then
        [[ -d $BUILD && -O $BUILD && -w $BUILD ]] || die 'Output directory must be writable and owned by you.'
        if [[ -f $BUILD/.lx-source ]]; then
            [[ $(cat "$BUILD/.lx-source") == "$SRC" ]] || die 'This output directory belongs to a different source tree.'
        elif [[ -n $(find "$BUILD" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            die 'Existing nonempty output directory is not managed by this script. Choose a new directory.'
        fi
    fi
    if [[ -n $CONFIG_INPUT ]]; then
        [[ ! -e $BUILD/.config ]] || die '--config cannot overwrite an existing output .config. Use --menuconfig or a new --build-dir.'
        SEED=$(realpath -e -- "$CONFIG_INPUT")
        [[ -f $SEED && -r $SEED ]] || die "Unreadable config: $CONFIG_INPUT"
        [[ $SEED != *.gz ]] || die '--config expects a plain-text Kconfig .config, not gzip.'
    elif [[ -r $BUILD/.config ]]; then SEED=$BUILD/.config
    elif [[ -r $BOOT_DIR/config-$(uname -r) ]]; then SEED=$BOOT_DIR/config-$(uname -r)
    elif [[ -r /proc/config.gz ]]; then SEED=/proc/config.gz; SEED_GZIP=1
    else die 'Running-kernel configuration not readable. Supply --config /path/to/compatible/.config.'; fi
    [[ -n $SUFFIX ]] || SUFFIX="-lxdev-$(date -u +%Y%m%d-%H%M%S)-$$"
    if [[ -z $JOBS ]]; then
        local cpus ram_jobs mib
        cpus=$(nproc); mib=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
        mib=${mib:-2048}; ram_jobs=$(( (mib - 1024) / 2048 )); (( ram_jobs >= 1 )) || ram_jobs=1
        JOBS=$cpus; (( JOBS <= 4 )) || JOBS=4; (( JOBS <= ram_jobs )) || JOBS=$ram_jobs
    fi
}
space_report() {
    local near=$BUILD
    while [[ ! -d $near ]]; do near=$(dirname -- "$near"); done
    info 'Space and memory (not a build-size forecast; quotas may differ)'
    df -h -- "$near" /var/lib /lib/modules "$BOOT_DIR" /var/tmp
    free -h
    warn 'Distro configurations with debugging and many modules can need tens of GiB or more. Parallel job selection is a heuristic, not an OOM guarantee.'
}

packages=(build-essential bc bison flex libssl-dev libelf-dev libncurses-dev
          dwarves pkg-config openssl perl python3 file git gawk rsync kmod
          cpio gzip bzip2 xz-utils zstd lz4 util-linux procps
          initramfs-tools-core kexec-tools)
install_dependencies() {
    info 'Installing native build/runtime prerequisites'
    warn 'APT may run package/service hooks; review its transaction. No security bypass or auto-reboot setting is configured by this script.'
    confirm INSTALL
    sudo -v
    sudo apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 \
        -o APT::Update::Error-Mode=any update
    sudo apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends --no-remove "${packages[@]}"
}
dependency_check() {
    local allow_missing=${1:-0} x missing=() libs
    for x in make gcc g++ ld as objcopy bc bison flex perl python3 gawk pkg-config openssl rsync gzip cpio file flock; do
        command -v "$x" >/dev/null || missing+=("$x")
    done
    if [[ $MODE != build ]]; then
        for x in sudo depmod mkinitramfs lsinitramfs; do command -v "$x" >/dev/null || missing+=("$x"); done
    fi
    if [[ $MODE == full ]]; then command -v kexec >/dev/null || missing+=(kexec); fi
    if command -v pkg-config >/dev/null; then
        for libs in libelf openssl ncursesw; do pkg-config --exists "$libs" || missing+=("pkg-config:$libs"); done
    fi
    if ((${#missing[@]})); then
        printf 'Missing prerequisites: %s\n' "${missing[*]}" >&2
        (( !APPLY || allow_missing )) || die 'Install prerequisites (or use --install-deps with --apply).'
    fi
    echo 'The selected tree Documentation/process/changes.rst and Kbuild checks decide exact tool versions.'
}

# Use the native distro GCC/binutils, not a sourced Yocto cross-SDK toolchain.
kmake() {
    make --no-print-directory -C "$SRC" "O=$BUILD" ARCH=x86 CROSS_COMPILE= \
        CC=gcc HOSTCC=gcc HOSTCXX=g++ LD=ld AR=ar NM=nm OBJCOPY=objcopy \
        OBJDUMP=objdump READELF=readelf STRIP=strip LOCALVERSION= "$@"
}
logged() { show_cmd "$@"; "$@" 2>&1 | tee -a "$LOG_FILE"; }
cfg_get() {
    local line
    line=$(grep -m1 "^CONFIG_$1=" "$BUILD/.config" || true)
    line=${line#*=}; line=${line#\"}; line=${line%\"}; printf '%s' "$line"
}
check_config_files() {
    local sym value part
    for sym in SYSTEM_TRUSTED_KEYS SYSTEM_REVOCATION_KEYS; do
        value=$(cfg_get "$sym")
        # Kconfig accepts a whitespace-separated filename list for these fields.
        read -r -a cert_files <<< "$value"
        for part in "${cert_files[@]}"; do
            if [[ ! -f $SRC/$part && ! -f $BUILD/$part && ! ( $part == /* && -f $part ) ]]; then
                die "CONFIG_$sym references missing $part. Provide the certificate, edit --menuconfig, or explicitly choose --clear-distro-certs for a local development kernel."
            fi
        done
    done
    value=$(cfg_get MODULE_SIG_KEY)
    if [[ -n $value && $value != certs/signing_key.pem && $value != pkcs11:* ]]; then
        [[ -f $SRC/$value || -f $BUILD/$value || ( $value == /* && -f $value ) ]] || die "Missing custom CONFIG_MODULE_SIG_KEY=$value. Configure your signing key explicitly."
    fi
    if [[ $(cfg_get DEBUG_INFO_BTF) == y ]]; then
        command -v pahole >/dev/null || die 'CONFIG_DEBUG_INFO_BTF=y requires pahole. Install dwarves/pahole or adjust --menuconfig.'
        pahole --version
    fi
    if [[ $(cfg_get RUST) == y ]]; then
        logged kmake rustavailable
    fi
    for sym in X86_64 MODULES BLK_DEV_INITRD RD_GZIP; do
        [[ $(cfg_get "$sym") == y ]] || die "CONFIG_$sym=y is required by this native module/initramfs workflow. Adjust --menuconfig."
    done
    if [[ $(cfg_get MODULE_SIG_FORCE) == y && $(cfg_get MODULE_SIG_ALL) != y ]]; then
        die 'MODULE_SIG_FORCE=y but MODULE_SIG_ALL is not y. Configure automatic signing or use a separate manual module-signing workflow.'
    fi
    [[ $(cfg_get KEXEC_FILE) == y ]] || warn 'New kernel does not enable KEXEC_FILE: another file-syscall kexec after boot may be unavailable.'
}
prepare_build() {
    mkdir -m 700 -p -- "$BUILD"
    exec 9>"$BUILD/.lx-build.lock"
    flock -n 9 || die 'Another run is using this output directory.'
    if [[ ! -f $BUILD/.lx-source ]]; then printf '%s\n' "$SRC" > "$BUILD/.lx-source"; fi
    mkdir -p -- "$BUILD/lx-logs"
    LOG_FILE=$BUILD/lx-logs/run-$(date -u +%Y%m%dT%H%M%SZ)-$$.log
    : > "$LOG_FILE"; chmod 600 "$LOG_FILE"
    if [[ ! -f $BUILD/.config ]]; then
        if (( SEED_GZIP )); then gzip -dc -- "$SEED" > "$BUILD/.config"
        else cp -- "$SEED" "$BUILD/.config"; fi
    fi
    cp -- "$BUILD/.config" "${LOG_FILE%.log}.config-before"
    logged kmake olddefconfig
    "$SRC/scripts/config" --file "$BUILD/.config" --set-str LOCALVERSION "$SUFFIX"
    "$SRC/scripts/config" --file "$BUILD/.config" --disable LOCALVERSION_AUTO
    if (( CLEAR_CERTS )); then
        warn 'Clearing extra trusted/revoked certificate lists in the NEW kernel only; this changes that kernel trust policy. Module signature enforcement is not disabled.'
        "$SRC/scripts/config" --file "$BUILD/.config" --set-str SYSTEM_TRUSTED_KEYS ''
        "$SRC/scripts/config" --file "$BUILD/.config" --set-str SYSTEM_REVOCATION_KEYS ''
    fi
    logged kmake olddefconfig
    if (( MENU )); then
        [[ -t 0 && -t 1 ]] || die '--menuconfig requires a real interactive terminal.'
        kmake menuconfig
        logged kmake olddefconfig
    fi
    check_config_files
    RELEASE=$(kmake -s kernelrelease)
    valid_release "$RELEASE" || die "Invalid/unmarked release: $RELEASE (max 64 bytes). Keep CONFIG_LOCALVERSION starting -lxdev."
    [[ $RELEASE != "$(uname -r)" ]] || die 'Refusing to install/build under the running kernel release.'
    if [[ $MODE != build ]]; then check_install_destinations; fi
    info "Building $RELEASE with $JOBS jobs"
    logged kmake "-j$JOBS" bzImage modules
    for file_name in arch/x86/boot/bzImage vmlinux System.map modules.order modules.builtin; do
        [[ -s $BUILD/$file_name || ( ( $file_name == modules.order || $file_name == modules.builtin ) && -f $BUILD/$file_name ) ]] || die "Build artifact missing: $BUILD/$file_name"
    done
    [[ $(kmake -s kernelrelease) == "$RELEASE" ]] || die 'Kernel release changed during build.'
    [[ -f $BUILD/include/config/kernel.release && $(cat "$BUILD/include/config/kernel.release") == "$RELEASE" ]] || die 'Generated kernel.release does not match.'
    file -- "$BUILD/arch/x86/boot/bzImage"
    printf '%s\n' "$RELEASE" > "$BUILD/.lx-last-release"
    cat > "$BUILD/lx-build-info.txt" <<EOF
release=$RELEASE
source=$SRC
output=$BUILD
built_utc=$(date -u +%FT%TZ)
build_host_kernel=$(uname -r)
jobs=$JOBS
EOF
    if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'source_commit=%s\n' "$(git -C "$SRC" rev-parse HEAD)" >> "$BUILD/lx-build-info.txt"
    fi
    info "Build complete: $RELEASE"
    printf 'Config: %s\nSymbols: %s\nLog: %s\n' "$BUILD/.config" "$BUILD/vmlinux" "$LOG_FILE"
}

check_install_destinations() {
    # No reuse/overwrite: a new release isolates modules and leaves distro kernels intact.
    local dst
    for dst in "$MODULES_BASE/$RELEASE" "$BUNDLES_BASE/$RELEASE" "$BOOT_DIR/config-$RELEASE"; do
        if [[ -e $dst || -L $dst ]]; then die "Destination exists: $dst. Choose a NEW --localversion; no files will be overwritten."; fi
    done
}
install_bundle() {
    local stage staged_modules base_size free_size bundle
    info 'Staging modules as your user (kernel Makefiles are not run under sudo)'
    stage=$(mktemp -d "$BUILD/.lx-stage.XXXXXXXX")
    logged kmake "INSTALL_MOD_PATH=$stage" DEPMOD=/bin/true modules_install
    staged_modules=$stage/lib/modules/$RELEASE
    [[ -d $staged_modules && ! -L $staged_modules ]] || die 'Staged modules directory missing or symlinked.'
    # Estimate only staged module storage; initramfs size and filesystem quotas vary.
    base_size=$(du -sk -- "$stage" | awk '{print $1}')
    free_size=$(df -Pk -- "$MODULES_BASE" | awk 'END {print $4}')
    (( free_size > base_size + 1048576 )) || die 'Insufficient space for staged modules plus 1 GiB reserve on module filesystem.'
    warn 'Out-of-tree/DKMS modules are NOT rebuilt here. Check storage, filesystem, network and GPU dependencies before booting.'
    info 'Installing a separate development bundle; no make install or bootloader update'
    sudo -v
    # Main bundle directory must be root-owned and not symlinked.
    if [[ ! -e $BUNDLES_BASE && ! -L $BUNDLES_BASE ]]; then sudo install -d -o root -g root -m 755 -- "$BUNDLES_BASE"; fi
    [[ -d $BUNDLES_BASE && ! -L $BUNDLES_BASE && $(stat -c %u -- "$BUNDLES_BASE") == 0 ]] || die 'Bundle root must be a real root-owned directory.'
    [[ $(stat -c %a -- "$BUNDLES_BASE") == 755 || $(stat -c %a -- "$BUNDLES_BASE") == 700 ]] || die 'Bundle root must have permissions 755 or 700.'
    check_install_destinations
    bundle=$BUNDLES_BASE/$RELEASE
    # mkdir (without -p) reserves exact new versioned destinations atomically.
    sudo mkdir -m 755 -- "$MODULES_BASE/$RELEASE"
    sudo mkdir -m 700 -- "$bundle"
    logged sudo cp -a -- "$staged_modules/." "$MODULES_BASE/$RELEASE/"
    sudo chown -hR root:root -- "$MODULES_BASE/$RELEASE"
    logged sudo depmod -a "$RELEASE"
    sudo install -o root -g root -m 644 -- "$BUILD/.config" "$BOOT_DIR/config-$RELEASE"
    sudo install -o root -g root -m 600 -- "$BUILD/.config" "$bundle/config"
    sudo install -o root -g root -m 600 -- "$BUILD/arch/x86/boot/bzImage" "$bundle/vmlinuz"
    sudo install -o root -g root -m 600 -- "$BUILD/System.map" "$bundle/System.map"
    sudo install -o root -g root -m 600 -- "$BUILD/lx-build-info.txt" "$bundle/build-info.txt"
    # mkinitramfs directly avoids update-initramfs bootloader hooks. Host hooks
    # for cryptsetup/LVM/RAID still run; the host's configuration remains intact.
    logged sudo mkinitramfs -c gzip -o "$bundle/initrd.img" "$RELEASE"
    sudo chmod 600 -- "$bundle/initrd.img"
    sudo test -s "$bundle/initrd.img" || die 'Empty initramfs.'
    sudo lsinitramfs "$bundle/initrd.img" > "$BUILD/lx-initramfs-list.txt"
    grep -Eq '(^|/)init$' "$BUILD/lx-initramfs-list.txt" || die 'No init entry found in the generated initramfs.'
    grep -Fq "lib/modules/$RELEASE/" "$BUILD/lx-initramfs-list.txt" || die 'No matching module directory found in initramfs; inspect it before booting.'
    # Hash manifest uses relative, fixed filenames and is never sourced as code.
    sudo bash -c 'set -e; cd -- "$1"; sha256sum vmlinuz initrd.img config System.map build-info.txt > SHA256SUMS; chmod 600 SHA256SUMS; : > COMPLETE; chmod 600 COMPLETE' bash "$bundle"
    info "Installed bundle: $bundle"
    printf 'Modules: %s\nBuild configuration: %s\n' "$MODULES_BASE/$RELEASE" "$BOOT_DIR/config-$RELEASE"
    printf 'Module staging retained at %s (remove manually when no longer needed).\n' "$stage"
    warn 'These are manually installed development files, not dpkg-managed packages. Nothing is auto-pruned.'
}
load_bundle() {
    local bundle=$BUNDLES_BASE/$RELEASE
    valid_release "$RELEASE" || die 'Invalid release.'
    [[ $RELEASE != "$(uname -r)" ]] || die 'Refusing to reload the running release with this helper.'
    command -v kexec >/dev/null || die 'kexec-tools is missing.'
    runtime_check
    info "Load $RELEASE into the NORMAL kexec slot (does not reboot)"
    printf 'Bundle: %s\n' "$bundle"
    if (( CUSTOM_CMDLINE )); then printf 'Custom command line: %s\n' "$CMDLINE";
    else printf 'Reuse current command line (kexec removes BOOT_IMAGE):\n'; cat /proc/cmdline; fi
    warn 'On systemd, an ordinary reboot can also use a preloaded kexec kernel. Unload it first to return to the normal boot path.'
    confirm LOAD
    sudo -v
    sudo test -f "$bundle/COMPLETE" || die 'Bundle incomplete/missing. Refusing to load.'
    [[ ! -L $bundle && ! -L $BUNDLES_BASE ]] || die 'Bundle path is symlinked.'
    [[ $(sudo stat -c %u -- "$bundle") == 0 ]] || die 'Bundle must be root-owned.'
    sudo bash -c 'set -e; cd -- "$1"; sha256sum --check SHA256SUMS' bash "$bundle"
    [[ -d $MODULES_BASE/$RELEASE ]] || die 'Matching installed modules are missing.'
    runtime_check
    local argv=(kexec --kexec-file-syscall --load "$bundle/vmlinuz" "--initrd=$bundle/initrd.img")
    if (( CUSTOM_CMDLINE )); then argv+=("--command-line=$CMDLINE"); else argv+=(--reuse-cmdline); fi
    show_cmd sudo "${argv[@]}"
    if sudo "${argv[@]}"; then :
    else
        die 'kexec_file_load failed. Check signature/trust, CONFIG_KEXEC_FILE, memory and lockdown. No legacy fallback or security-policy change is attempted.'
    fi
    [[ $(read_value "$KEXEC_SLOT") == 1 ]] || die 'kexec returned success but normal-slot verification did not report 1.'
    cat <<EOF

Loaded: $RELEASE
No reboot was requested. Save work and ensure a recovery console is available.

When YOU are ready to stop services and boot the loaded kernel:
    sudo systemctl kexec

To cancel the pending kernel instead:
    sudo kexec --kexec-file-syscall --unload

After boot:
    uname -r
Expected: $RELEASE
EOF
}
unload_kernel() {
    show_status
    if [[ $(read_value "$KEXEC_SLOT") == 0 ]]; then info 'No normal kexec kernel is loaded.'; return; fi
    if (( !APPLY )); then show_cmd sudo kexec --kexec-file-syscall --unload; echo 'Preview only.'; return; fi
    require_normal_user; runtime_check
    warn 'Unloading the normal slot regardless of who loaded it; the crash/kdump slot is untouched.'
    confirm UNLOAD
    sudo kexec --kexec-file-syscall --unload
    [[ $(read_value "$KEXEC_SLOT") == 0 ]] || die 'Normal kexec slot is still loaded.'
    info 'Normal kexec slot unloaded.'
}

main() {
    init_defaults
    parse_args "$@"
    # Avoid cross-SDK tools and inherited make overrides. No shell startup files edited.
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    unset MAKEFLAGS MFLAGS MAKEOVERRIDES KBUILD_OUTPUT KBUILD_SRC KBUILD_EXTMOD
    unset KCONFIG_CONFIG KCONFIG_ALLCONFIG KCONFIG_SEED KCONFIG_OVERWRITECONFIG
    unset KERNELRELEASE LOCALVERSION ARCH CROSS_COMPILE LLVM LLVM_IAS
    unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS KCFLAGS KCPPFLAGS KAFLAGS KRUSTFLAGS
    unset CC HOSTCC HOSTCXX LD AR NM OBJCOPY OBJDUMP STRIP PKG_CONFIG_PATH
    unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR HOSTCFLAGS HOSTCXXFLAGS HOSTLDFLAGS
    unset INSTALL_MOD_PATH INSTALL_MOD_STRIP MODLIB DEPMOD
    if [[ $MODE == status ]]; then show_status; return; fi
    platform_check
    if [[ $MODE == unload ]]; then unload_kernel; return; fi
    if [[ $MODE == load ]]; then
        show_status
        if (( !APPLY )); then
            printf 'Preview: verify and load %s/%s; no reboot.\n' "$BUNDLES_BASE" "$RELEASE"
            return
        fi
        require_normal_user; load_bundle; return
    fi
    [[ -z ${SDKTARGETSYSROOT:-} && -z ${OECORE_NATIVE_SYSROOT:-} ]] || die 'A Yocto cross-SDK is active. Start a clean terminal for this native GCC build.'
    resolve_source
    printf 'Source: %s\nOutput: %s\nSeed: %s\nSuffix: %s\nJobs: %s\nMode: %s\n' "$SRC" "$BUILD" "$SEED" "$SUFFIX" "$JOBS" "$MODE"
    space_report
    dependency_check "$INSTALL_DEPS"
    if (( !APPLY )); then
        if (( INSTALL_DEPS )); then show_cmd sudo apt-get install --no-install-recommends --no-remove "${packages[@]}"; fi
        echo 'Plan: seed/reuse .config; olddefconfig; mark local version; build bzImage + modules.'
        (( !MENU )) || echo 'Plan: open menuconfig before compilation.'
        (( !CLEAR_CERTS )) || warn 'Requested clearing of extra certificate lists applies only to the new config.'
        [[ $MODE == build ]] || echo 'Plan: stage/install modules, store separate bundle, create matching gzip initramfs.'
        [[ $MODE != full ]] || echo 'Plan: load with kexec_file_load after confirmation. NO reboot.'
        show_status
        echo 'Preview complete: no files written, no make targets executed, no sudo or downloads.'
        return
    fi
    require_normal_user
    [[ $MODE != full ]] || runtime_check
    confirm BUILD
    (( !INSTALL_DEPS )) || install_dependencies
    dependency_check
    prepare_build
    [[ $MODE != build ]] || return 0
    confirm INSTALL
    install_bundle
    if [[ $MODE == full ]]; then load_bundle
    else
        printf '\nTo load later:\n  %q --load-only --release %q --apply\n' "$0" "$RELEASE"
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    trap 'on_error "$?" "$LINENO"' ERR
    trap 'printf "\nInterrupted. No reboot requested; partial files retained.\n" >&2; exit 130' INT
    trap 'printf "\nTerminated. No reboot requested; partial files retained.\n" >&2; exit 143' TERM
    main "$@"
fi