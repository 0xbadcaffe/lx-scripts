#!/usr/bin/env bash
# Debian QEMU contributor/development workstation bootstrap.
# Default is PLAN ONLY. Use --apply for changes.
set -Eeuo pipefail

APPLY=0
MINIMAL=0
RUNTIME=0
CROSS=0
DOCS=0
RUST=0
LIST=0
REFRESH=0

usage() {
cat <<'EOF'
Usage: install-qemu-dev-debian.sh [options]

Default: full QEMU C development/contributor dependencies, plan only.

Options:
  --apply       Install packages
  --refresh     apt-get update before installation
  --minimal     Core QEMU build dependencies only
  --runtime     Also install distro QEMU system/user emulators, firmware and tools
  --cross       Add common cross compilers for firmware/tests
  --docs        Add QEMU documentation build dependencies
  --rust        Add Debian Rust/bindgen development packages when available
  --list        Show selected package catalog and exit
  -h,--help     Show help

Examples:
  ./install-qemu-dev-debian.sh --list
  ./install-qemu-dev-debian.sh
  ./install-qemu-dev-debian.sh --runtime --cross --docs
  ./install-qemu-dev-debian.sh --runtime --cross --docs --rust --apply --refresh
EOF
}

while (($#)); do
 case "$1" in
  --apply) APPLY=1; shift;;
  --refresh) REFRESH=1; shift;;
  --minimal) MINIMAL=1; shift;;
  --runtime) RUNTIME=1; shift;;
  --cross) CROSS=1; shift;;
  --docs) DOCS=1; shift;;
  --rust) RUST=1; shift;;
  --list) LIST=1; shift;;
  -h|--help) usage; exit 0;;
  *) echo "Unknown option: $1" >&2; exit 1;;
 esac
done

[[ -r /etc/os-release ]] || { echo "Missing /etc/os-release" >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == debian ]] || { echo "This installer targets Debian." >&2; exit 1; }

required=(
 build-essential gcc g++ make git ca-certificates curl wget
 python3 python3-venv python3-pip
 meson ninja-build pkg-config
 bison flex bc
 libglib2.0-dev libpixman-1-dev zlib1g-dev
 libfdt-dev libslirp-dev liburing-dev
 libcap-ng-dev libattr1-dev libaio-dev
 libseccomp-dev libcapstone-dev
 libgnutls28-dev libgcrypt20-dev
 libssh-dev libnfs-dev
 libusb-1.0-0-dev libusbredirparser-dev
 libspice-protocol-dev
 libepoxy-dev libdrm-dev
 libgbm-dev libvirglrenderer-dev
 libvdeplug-dev
 libfuse3-dev
 libzstd-dev liblz4-dev
 libsnappy-dev libbz2-dev liblzo2-dev
 libcurl4-gnutls-dev
 libiscsi-dev
 libpmem-dev
 libudev-dev
 libsdl2-dev libgtk-3-dev
 libpulse-dev libpipewire-0.3-dev
 libjpeg-dev libpng-dev
 libncurses-dev
)

contrib=(
 clang llvm lld
 gdb gdb-multiarch
 valgrind strace ltrace
 sparse coccinelle
 clang-format
 shellcheck
 codespell
 gcovr lcov
 python3-pytest python3-yaml python3-tomli
 python3-sphinx python3-sphinx-rtd-theme
 libvirt-clients virt-manager
 bridge-utils iproute2 socat netcat-openbsd
 jq ripgrep universal-ctags
 ccache
 device-tree-compiler
)

runtime_pkgs=(
 qemu-system
 qemu-user
 qemu-user-static
 qemu-utils
 qemu-block-extra
 qemu-system-gui
 qemu-system-modules-opengl
 qemu-system-modules-spice
 ovmf seabios ipxe-qemu
 swtpm
)

cross_pkgs=(
 gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
 gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf
 gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu
 gcc-powerpc64le-linux-gnu binutils-powerpc64le-linux-gnu
 gcc-s390x-linux-gnu binutils-s390x-linux-gnu
)

docs_pkgs=(
 texinfo graphviz doxygen
 python3-sphinx python3-sphinx-rtd-theme
)

rust_pkgs=(
 rustc cargo bindgen
)

packages=("${required[@]}")
((MINIMAL)) || packages+=("${contrib[@]}")
((RUNTIME)) && packages+=("${runtime_pkgs[@]}")
((CROSS)) && packages+=("${cross_pkgs[@]}")
((DOCS)) && packages+=("${docs_pkgs[@]}")
((RUST)) && packages+=("${rust_pkgs[@]}")

# De-duplicate.
mapfile -t packages < <(printf '%s\n' "${packages[@]}" | awk '!seen[$0]++')

# Separate packages available in enabled APT repositories from optional misses.
available=()
missing=()
for pkg in "${packages[@]}"; do
 if apt-cache show "$pkg" >/dev/null 2>&1; then available+=("$pkg"); else missing+=("$pkg"); fi
done

echo "Host: ${PRETTY_NAME:-Debian} ($(uname -m))"
echo
echo "Selected available packages (${#available[@]}):"
printf '  %s\n' "${available[@]}"
if ((${#missing[@]})); then
 echo
 echo "Unavailable in currently enabled APT repositories (${#missing[@]}):"
 printf '  %s\n' "${missing[@]}"
 echo "These are optional unless they are part of your chosen QEMU configure feature set."
fi

if ((LIST)); then exit 0; fi

echo
echo "Filesystem before:"
df -h / /var /tmp "$HOME" 2>/dev/null | awk 'NR==1 || !seen[$1]++'

echo
echo "APT simulation:"
if ((${#available[@]})); then
 apt-get -s install --no-install-recommends "${available[@]}" | \
   grep -E '^(Inst |Remv |[0-9]+ upgraded|Need to get|After this operation)' || true
fi

if ((!APPLY)); then
 echo
 echo "PLAN ONLY: no packages installed."
 echo "Run with --apply; add --refresh to update APT indexes first."
 exit 0
fi

((EUID != 0)) || { echo "Run as your normal user, not sudo." >&2; exit 1; }
command -v sudo >/dev/null || { echo "sudo required." >&2; exit 1; }
sudo -v
((REFRESH)) && sudo apt-get update
sudo apt-get install -y --no-install-recommends "${available[@]}"

echo
echo "Verification:"
for cmd in gcc make git python3 meson ninja pkg-config bison flex; do
 printf '%-15s ' "$cmd"
 command -v "$cmd" >/dev/null && "$cmd" --version 2>/dev/null | head -1 || echo MISSING
done

cat <<'EOF'

Recommended QEMU contributor checkout/build:

  git clone https://gitlab.com/qemu-project/qemu.git
  cd qemu
  mkdir build
  cd build
  ../configure
  make -j"$(nproc)"

Useful contributor checks depend on the QEMU revision; inspect:

  make help
  ../configure --help
  ../scripts/checkpatch.pl --help

For the distro's exact QEMU build dependencies, Debian also supports:

  sudo apt build-dep qemu

but this requires deb-src entries to be enabled.

KVM access is intentionally not modified. Check it with:

  test -r /dev/kvm -a -w /dev/kvm && echo "KVM usable" || echo "KVM unavailable/not permitted"

No user was added to groups and no virtualization/security policy was changed.
EOF

echo
echo "Filesystem after:"
df -h / /var /tmp "$HOME" 2>/dev/null | awk 'NR==1 || !seen[$1]++'
