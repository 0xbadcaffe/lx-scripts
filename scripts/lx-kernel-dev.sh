#!/usr/bin/env bash
# Native Linux-kernel development prerequisites for Ubuntu / Debian.
# Run as your normal user. Only APT operations use sudo.
#
# Reference baseline checked on 2026-09-11:
# https://docs.kernel.org/process/changes.html
# https://docs.kernel.org/admin-guide/quickly-build-trimmed-linux.html
# https://docs.kernel.org/kbuild/llvm.html
# https://docs.kernel.org/rust/quick-start.html
# https://kernel-team.pages.debian.net/kernel-handbook/ch-common-tasks.html
#
# Uses enabled APT repositories. Does not add repositories, change security
# policy, configure Git/email, change compiler alternatives, clone sources,
# build/install/boot a kernel, load modules, or start tracing/VMs.
# APT may update requested packages and their dependencies and run package hooks.
# This is NOT the complete Build-Depends list for Ubuntu/Debian kernel packaging
# or every optional kernel configuration, selftest, architecture, or Rust tree.

set -Eeuo pipefail
trap 'rc=$?; printf "\nERROR: line %s failed (exit %s). No further steps will run.\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

usage() {
    cat <<'EOF'
Usage: bash install-kernel-dev-prereqs.sh [options]

Default: native C kernel-build prerequisites, menuconfig, pahole/BTF tooling,
         debugging, tracing/perf, static analysis, patch tools, .deb helpers,
         device-tree tools, and common perf/BPF development libraries.

  --minimal          Core native build + menuconfig + pahole only.
  --llvm             Add the newest complete LLVM >=17 suite in enabled APT.
  --llvm-version N   Choose a particular LLVM major (e.g. 18); implies --llvm.
  --arm64            Add aarch64-linux-gnu GCC/binutils and dtc/mkimage.
  --arm              Add arm-linux-gnueabihf GCC/binutils and dtc/mkimage.
  --qemu             Add system emulators for the native/selected ARM targets.
  --headers          Request headers for EXACTLY the running kernel.
  --docs             Add common HTML kernel-documentation dependencies.
  --dry-run          Print the plan; no sudo, downloads, writes, or compilation.
  -h, --help         Show this help.

Host scope: Ubuntu 22.04+ / Debian 11+. Older repos may supply tools too old
for your kernel tree, especially pahole and LLVM. Missing extras are reported;
no third-party repository, backport, or source-built tool is installed for you.

Rust is intentionally not installed or changed: rustc, rust-src, bindgen and
libclang must match your kernel tree's requirements. Use its rustavailable
check. This script never replaces an existing Rust toolchain.

--headers is for out-of-tree modules against the running kernel, not needed
merely to compile a full kernel from source. Header package hooks may rebuild
already-registered DKMS modules; the script itself never invokes DKMS.

Exit 0: package installation + basic checks passed; NOT a verified kernel build.
Exit 1: invalid invocation, core dependency, installation, or core check failed.
Exit 2: installed, but missing extras / version or tooling advisories remain.
EOF
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; warnings=$((warnings + 1)); }

reset_options() {
    minimal=0; dry_run=0; want_llvm=0; llvm_requested=''; llvm_major=''
    arm64=0; arm=0; qemu=0; headers=0; docs=0; warnings=0
    core=(); extras=(); packages=()
}

parse_options() {
    while (( $# )); do
        case "$1" in
            --minimal) minimal=1 ;;
            --dry-run) dry_run=1 ;;
            --llvm) want_llvm=1 ;;
            --llvm-version)
                (( $# >= 2 )) || fail '--llvm-version requires a major version.'
                [[ "$2" =~ ^[1-9][0-9]{0,2}$ ]] || fail 'LLVM major must be a positive integer.'
                llvm_requested="$2"; want_llvm=1; shift ;;
            --arm64) arm64=1 ;;
            --arm) arm=1 ;;
            --qemu) qemu=1 ;;
            --headers) headers=1 ;;
            --docs) docs=1 ;;
            -h|--help) usage; exit 0 ;;
            *) fail "Unknown argument: $1 (use --help)." ;;
        esac
        shift
    done
}

host_environment() {
    # Do not accidentally use an initialized Yocto SDK compiler or pkg-config.
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export LC_ALL=C LANG=C
    unset CC CXX LD AR AS NM STRIP OBJCOPY OBJDUMP CROSS_COMPILE ARCH
    unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR
    unset PKG_CONFIG_SYSROOT_DIR LD_LIBRARY_PATH LD_PRELOAD PYTHONPATH PYTHONHOME
    [[ -r /etc/os-release ]] || fail 'Missing /etc/os-release.'
    # shellcheck disable=SC1091
    source /etc/os-release
    local min_os
    case "${ID:-}" in
        ubuntu) min_os=22.04 ;;
        debian) min_os=11 ;;
        *) fail 'This installer supports Ubuntu and Debian only.' ;;
    esac
    dpkg --compare-versions "${VERSION_ID:-0}" ge "$min_os" ||
        fail "Host too old for this installer: ${PRETTY_NAME:-unknown}."
    command -v apt-get >/dev/null || fail 'apt-get not found.'
    host_arch=$(dpkg --print-architecture)
    kernel_release=$(uname -r)
    printf 'Host: %s (%s)\nRunning kernel: %s\n' "${PRETTY_NAME:-$ID}" "$host_arch" "$kernel_release"
}

build_plan() {
    # Common upstream kernel-build dependencies and basic clean-host utilities.
    core=(
        build-essential binutils bc bison flex git pkg-config
        libssl-dev libelf-dev libncurses-dev zlib1g-dev openssl
        perl python3 cpio rsync kmod gawk file patch
        ca-certificates curl wget coreutils diffutils findutils
        gzip bzip2 xz-utils zstd lz4 tar util-linux procps
    )
    if (( ! minimal )); then
        extras+=(
            ccache gdb gdb-multiarch strace ltrace valgrind trace-cmd sysstat
            sparse coccinelle git-email b4 quilt diffstat patchutils
            ripgrep universal-ctags cscope global tmux
            fakeroot dpkg-dev debhelper python3-dev python3-venv
            libdw-dev libunwind-dev libslang2-dev libcap-dev libnuma-dev
            libaudit-dev libtraceevent-dev libtracefs-dev libbpf-dev
            libzstd-dev liblzma-dev libperl-dev bpftrace
            device-tree-compiler u-boot-tools
        )
    fi
    if (( arm64 )); then
        core+=(gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu)
    fi
    if (( arm )); then
        core+=(gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf)
    fi
    if (( arm64 || arm )); then
        core+=(device-tree-compiler u-boot-tools)
    fi
    if (( qemu )); then
        core+=(qemu-utils)
        case "$host_arch" in
            amd64|i386) core+=(qemu-system-x86) ;;
            arm64|armhf|armel) core+=(qemu-system-arm) ;;
            riscv64) core+=(qemu-system-misc) ;;
            *) fail "--qemu has no native mapping for $host_arch; install your emulator explicitly." ;;
        esac
        if (( arm64 || arm )); then core+=(qemu-system-arm); fi
    fi
    if (( docs )); then
        extras+=(python3-sphinx python3-sphinx-rtd-theme python3-yaml
                 python3-docutils graphviz imagemagick)
    fi
}

print_plan() {
    printf '\nCore / explicitly selected packages:\n'; printf '  %s\n' "${core[@]}"
    if (( ${#extras[@]} )); then
        printf '\nSupplementary packages (report any unavailable packages):\n'
        printf '  %s\n' "${extras[@]}"
    fi
    printf '\nAlso resolve pahole (or dwarves) from APT for BTF support.\n'
    if (( ! minimal )); then
        if [[ "$ID" == ubuntu ]]; then
            printf 'Profiling: linux-tools-common + linux-tools-%s, if available.\n' "$kernel_release"
        else
            printf 'Profiling: linux-perf, if available.\n'
        fi
    fi
    if (( want_llvm )); then
        printf 'LLVM: %s; install versioned tools, leave compiler defaults unchanged.\n' "${llvm_requested:-newest complete APT suite >=17}"
    fi
    if (( headers )); then printf 'Headers: linux-headers-%s only, if available.\n' "$kernel_release"; fi
}

# Inspect actual candidates, not just package-name existence in an old index.
has_candidate() {
    local result
    result=$(apt-cache policy "$1" 2>/dev/null) || return 1
    awk '$1 == "Candidate:" && $2 != "(none)" {ok=1} END {exit !ok}' <<< "$result"
}

append_unique() {
    local p existing
    for p in "$@"; do
        for existing in "${packages[@]}"; do
            [[ "$existing" == "$p" ]] && continue 2
        done
        packages+=("$p")
    done
}

optional_package() {
    if has_candidate "$1"; then append_unique "$1"
    else warn "No APT candidate for supplementary package $1; skipped."
    fi
}

resolve_llvm() {
    local version package ok
    local -a versions=() suite=()
    if [[ -n "$llvm_requested" ]]; then
        versions=("$llvm_requested")
    else
        mapfile -t versions < <(apt-cache pkgnames | sed -n 's/^clang-\([0-9][0-9]*\)$/\1/p' | sort -rnu)
    fi
    for version in "${versions[@]}"; do
        if [[ -z "$llvm_requested" ]] && (( version < 17 )); then continue; fi
        suite=("clang-$version" "lld-$version" "llvm-$version" "libclang-$version-dev")
        ok=1
        for package in "${suite[@]}"; do has_candidate "$package" || ok=0; done
        if (( ok )); then
            llvm_major="$version"
            append_unique "${suite[@]}"
            printf '\nSelected LLVM %s. Use LLVM=-%s in every make invocation.\n' "$version" "$version"
            return 0
        fi
    done
    warn "No complete requested LLVM suite in enabled repositories. GCC setup continues; LLVM was not installed."
}

resolve_packages() {
    local package
    for package in "${core[@]}"; do
        has_candidate "$package" || fail "No APT candidate for required package $package. Check your distro repositories; none were added."
        append_unique "$package"
    done
    if has_candidate pahole; then append_unique pahole
    elif has_candidate dwarves; then append_unique dwarves
    else warn 'Neither pahole nor dwarves is available. BTF-enabled builds need suitable pahole.'
    fi
    for package in "${extras[@]}"; do optional_package "$package"; done
    if (( ! minimal )); then
        if [[ "$ID" == ubuntu ]]; then
            optional_package linux-tools-common
            if has_candidate "linux-tools-$kernel_release"; then
                append_unique "linux-tools-$kernel_release"
            else
                warn "No linux-tools-$kernel_release in APT. The Ubuntu perf wrapper may not work; use matching tools/perf sources. No unrelated kernel/tools meta-package was selected."
            fi
        else
            optional_package linux-perf
        fi
    fi
    if (( headers )); then
        if has_candidate "linux-headers-$kernel_release"; then
            append_unique "linux-headers-$kernel_release"
        elif [[ -f "/lib/modules/$kernel_release/build/Makefile" ]]; then
            printf 'An existing build/header tree is present for %s; it was not changed.\n' "$kernel_release"
        else
            warn "No matching linux-headers-$kernel_release package or build tree. Headers for a different kernel will not substitute."
        fi
    fi
    if (( want_llvm )); then resolve_llvm; fi
}

verify_tools() {
    local rc=0
    printf '\nTool checks (reference baseline, NOT a build of your kernel tree):\n'
    /usr/bin/python3 -I - "$minimal" "$llvm_major" "$arm64" "$arm" "$qemu" "$headers" "$kernel_release" "$docs" <<'PY' || rc=$?
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

minimal, llvm, arm64, arm, qemu, headers, release, docs = sys.argv[1:]
failed = False
advisory = False

def run(argv, timeout=20):
    return subprocess.run(argv, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, timeout=timeout).stdout

def problem(message, required=False):
    global failed, advisory
    print(('FAIL: ' if required else 'WARNING: ') + message)
    if required:
        failed = True
    else:
        advisory = True

def check(label, argv, minimum=None, required=True):
    try:
        output = run(argv)
        first = output.splitlines()[0] if output.splitlines() else ''
        match = re.search(r'\d+(?:\.\d+)+', first)
        if minimum and not match:
            raise ValueError('could not read version from ' + first)
        version = match.group() if match else first
        print(f'{label:20} {version}')
        if minimum:
            found = tuple(int(p) for p in version.split('.'))
            width = max(len(found), len(minimum))
            if found + (0,) * (width - len(found)) < minimum + (0,) * (width - len(minimum)):
                problem(f'{label} below reference minimum {".".join(map(str, minimum))}; '
                        'check Documentation/process/changes.rst in your kernel tree.', required)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        problem(f'{label}: {exc}', required)

for label, argv, minimum in [
    ('GCC', ['gcc', '-dumpfullversion', '-dumpversion'], (8, 1)),
    ('GNU make', ['make', '--version'], (4, 0)),
    ('GNU binutils', ['ld', '--version'], (2, 30)),
    ('Bash', ['bash', '--version'], (4, 2)),
    ('Flex', ['flex', '--version'], (2, 5, 35)),
    ('Bison', ['bison', '--version'], (2, 0)),
    ('bc', ['bc', '--version'], (1, 6, 95)),
    ('GNU tar', ['tar', '--version'], (1, 28)),
    ('Python', ['python3', '--version'], (3, 9)),
    ('Git', ['git', '--version'], None),
    ('OpenSSL', ['openssl', 'version'], (1, 0, 0)),
]:
    check(label, argv, minimum)

# Current kernel docs require >=1.26 for some newer BTF/kfunc features.
# Older trees/configs can need less. Never disable BTF to hide an old tool.
check('pahole / BTF', ['pahole', '--version'], (1, 26), required=False)
check('GNU awk', ['gawk', '--version'], (5, 1), required=False)

try:
    run(['perl', '-MGetopt::Long', '-MGetopt::Std', '-MFile::Basename', '-MFile::Find',
         '-e', 'print "OK\\n";'])
    print('Perl build modules   OK')
except (OSError, subprocess.SubprocessError) as exc:
    problem(f'Perl build modules: {exc}', required=True)

if llvm:
    check('Clang ' + llvm, ['clang-' + llvm, '--version'], (17, 0, 1), required=False)
    check('LLD ' + llvm, ['ld.lld-' + llvm, '--version'], (17, 0, 1), required=False)
    check('LLVM ' + llvm, ['llvm-ar-' + llvm, '--version'], required=False)

cross = []
if arm64 == '1':
    cross.append('aarch64-linux-gnu-')
if arm == '1':
    cross.append('arm-linux-gnueabihf-')
for prefix in cross:
    check(prefix + 'gcc', [prefix + 'gcc', '-dumpfullversion', '-dumpversion'], (8, 1))
    check(prefix + 'ld', [prefix + 'ld', '--version'], (2, 30))

if minimal == '0':
    for label, argv in [
        ('GDB', ['gdb', '--version']),
        ('Sparse', ['sparse', '--version']),
        ('Coccinelle', ['spatch', '--version']),
        ('perf', ['perf', '--version']),
    ]:
        check(label, argv, required=False)
if minimal == '0' or cross:
    check('Device-tree compiler', ['dtc', '--version'], required=False)
    check('mkimage', ['mkimage', '-V'], required=False)
if docs == '1':
    check('Sphinx', ['sphinx-build', '--version'], (3, 4, 3), required=False)
if qemu == '1':
    machines = {
        'x86_64': 'qemu-system-x86_64', 'i386': 'qemu-system-i386',
        'i686': 'qemu-system-i386', 'aarch64': 'qemu-system-aarch64',
        'armv7l': 'qemu-system-arm', 'riscv64': 'qemu-system-riscv64',
    }
    import platform
    programs = {machines.get(platform.machine(), '')}
    if cross:
        programs.add('qemu-system-aarch64' if arm64 == '1' else 'qemu-system-arm')
    for prog in sorted(programs - {''}):
        check(prog, [prog, '--version'], required=False)

# Compile only tiny user-space probes, as the normal user, in a temporary dir.
# No kernel source, kernel config, module, VM, or tracing operation is executed.
try:
    flags = shlex.split(run(['pkg-config', '--cflags', '--libs', 'libelf', 'openssl', 'ncursesw']))
    with tempfile.TemporaryDirectory(prefix='kernel-dev-check-') as tmp:
        root = pathlib.Path(tmp)
        source = root / 'host-probe.c'
        source.write_text('#include <libelf.h>\n#include <openssl/crypto.h>\n'
                          '#include <ncurses.h>\n'
                          'int main(void) { (void)elf_version(EV_CURRENT); '
                          '(void)OpenSSL_version_num(); return endwin(); }\n')
        run(['gcc', '-Wall', '-Werror', str(source), '-o', str(root / 'host-probe'), *flags], 60)
        print('Host compile/link    OK: GCC + libelf + OpenSSL + ncurses (binary not run)')
        cross_source = root / 'cross-probe.c'
        cross_source.write_text('void kernel_dev_probe(void) {}\n')
        for prefix in cross:
            run([prefix + 'gcc', '-c', str(cross_source), '-o', str(root / (prefix + '.o'))], 60)
            print(f'Cross compile        OK: {prefix}gcc (object not run)')
except (OSError, ValueError, subprocess.SubprocessError) as exc:
    details = getattr(exc, 'stdout', None) or str(exc)
    problem('compile/link check: ' + details[:4000], required=True)

if headers == '1':
    tree = pathlib.Path('/lib/modules') / release / 'build'
    if (tree / 'Makefile').is_file():
        print('Running-kernel tree  ' + str(tree.resolve()))
        print('                     Not an out-of-tree module build verification.')
    else:
        problem('Running-kernel headers/build tree still missing: ' + str(tree))

sys.exit(1 if failed else 2 if advisory else 0)
PY
    case "$rc" in
        0) ;;
        2) warn 'Basic setup has tool/version advisories; see the checks above.' ;;
        *) fail 'Core tool or compile/link verification failed; see the checks above.' ;;
    esac
}

print_next_steps() {
    printf '\nHost resources (filesystem containing your current directory):\n'
    free -h
    df -h -- "$PWD"
    printf '\nRead-only host diagnostics:\n'
    local path value
    for path in /proc/sys/kernel/perf_event_paranoid /proc/sys/kernel/kptr_restrict; do
        if [[ -r "$path" ]]; then
            value=$(cat "$path")
            printf '  %s = %s\n' "${path##*/}" "$value"
        fi
    done
    if [[ -e /dev/kvm ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            echo '  /dev/kvm is accessible to this user; no VM was started.'
        else
            echo '  /dev/kvm exists but is not accessible to this user. No group changes made.'
        fi
    else
        echo '  /dev/kvm is absent. QEMU can use software emulation; no VM was started.'
    fi
    cat <<'EOF'

The script did not clone kernel sources or build/install a kernel.
From a trusted kernel checkout, inspect its own requirements before building:

  less Documentation/process/changes.rst
  ./scripts/ver_linux
  make help

Kernel-specific tools already in the source tree include checkpatch.pl,
get_maintainer.pl, KUnit and kselftest. They are not separate APT installs.
Subsystem selftests, distribution packaging and special configurations may
require more dependencies than this general development setup.

Perf/tracing access depends on the running kernel and host security policy.
Secure Boot, AppArmor, sysctls, CPU scheduling and build parallelism were not
changed. No tracing sessions or module loads were attempted.
EOF
    if [[ -n "$llvm_major" ]]; then
        printf '\nSelected versioned LLVM tools: use LLVM=-%s consistently, for example:\n' "$llvm_major"
        printf '  make LLVM=-%s menuconfig\n' "$llvm_major"
        printf '  make LLVM=-%s rustavailable  # diagnostics; Rust itself was not installed\n' "$llvm_major"
    fi
    if (( arm64 )); then
        printf '\nARM64 build variables: ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-\n'
    fi
    if (( arm )); then
        printf '\n32-bit ARM build variables: ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-\n'
    fi
    if (( docs )); then
        echo 'Documentation packages installed where available; your kernel tree may require additional Sphinx extensions.'
    fi
    cat <<'EOF'

Rust kernel work needs a tree-compatible rustc, rust-src, bindgen and libclang.
Consult Documentation/rust/quick-start.rst and use make ... rustavailable.
Older trees can require exact versions; do not blindly replace a working
user Rust toolchain with the distro default.
EOF
}

main() {
    reset_options
    parse_options "$@"
    host_environment
    build_plan
    print_plan
    if (( dry_run )); then
        cat <<'EOF'

DRY RUN: would refresh APT, resolve package candidates, install available
packages, print versions and compile tiny temporary user-space probes.
No changes made. Fresh package availability and dependency resolution were
not tested. Rust, kernel source and the running kernel are not installed.
EOF
        return 0
    fi
    (( EUID != 0 )) || fail 'Run as your normal user, WITHOUT sudo. The script elevates only APT.'
    command -v sudo >/dev/null || fail 'Install sudo and grant your user access first.'
    sudo -v
    local -a apt_options=(-o DPkg::Lock::Timeout=120 -o Acquire::Retries=3)
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" \
        -o APT::Update::Error-Mode=any update
    resolve_packages
    printf '\nResolved install set (%s packages):\n' "${#packages[@]}"
    printf '  %s\n' "${packages[@]}"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" \
        install -y --no-install-recommends --no-remove "${packages[@]}"
    verify_tools
    print_next_steps
    if (( warnings )); then
        printf '\nInstalled with %s advisory group(s). Resolve the warnings relevant to your kernel tree.\n' "$warnings"
        return 2
    fi
    printf '\nInstallation and basic checks passed. A kernel build has NOT been validated.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi