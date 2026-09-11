#!/usr/bin/env bash
# Yocto build-host setup for Ubuntu / Debian. Run as your normal user.
# Baseline: Yocto 6.0 (Wrynose), not a promise of compatibility with every BSP.
# Reference: https://docs.yoctoproject.org/6.0/ref-manual/system-requirements.html
# Menuconfig: https://docs.yoctoproject.org/kernel-dev/common.html
# Does NOT clone sources, run BitBake, modify local.conf, change /bin/sh,
# install Yoctui/Rust, disable AppArmor, add repositories, or install a server.
set -Eeuo pipefail
trap 'printf "\nERROR: step failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR

usage() {
    cat <<'EOF'
Usage: bash install-yocto-prereqs.sh [--minimal] [--dry-run]

Default: required Yocto 6.0 host packages plus common kernel, SDK, terminal,
         filesystem, and QEMU display development utilities.
--minimal: omit the supplementary developer packages.
--dry-run: print the plan without sudo, downloads, or system changes.

Ubuntu 22.04+ / Debian 11+. Host support also depends on your Yocto branch.
On Ubuntu 22.04 / Debian 11 a user-owned Python venv supplies websockets,
following Yocto's guidance for the optional upstream shared-state service.
The script prints its activation command; it cannot modify your parent shell.

Exit 0: installed and basic checks passed (not a verified Yocto build).
Exit 1: installation / tool verification failed.
Exit 2: installed, but the unprivileged namespace diagnostic failed.
EOF
}

minimal=0
dry_run=0
for arg in "$@"; do
    case "$arg" in
        --minimal) minimal=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
    esac
done

# Do not pick up SDK/Poky tools or a custom Python from an initialized shell.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
[[ -r /etc/os-release ]] || { echo 'Missing /etc/os-release.' >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
    ubuntu) minimum_os=22.04 ;;
    debian) minimum_os=11 ;;
    *) echo 'This installer supports Ubuntu and Debian only.' >&2; exit 1 ;;
esac
if ! dpkg --compare-versions "${VERSION_ID:-0}" ge "$minimum_os"; then
    echo "Host is too old for this installer: ${PRETTY_NAME:-unknown}." >&2
    echo 'Use your Yocto branch documentation and a matching buildtools setup.' >&2
    exit 1
fi

# Official Wrynose headless host package list.
packages=(
    build-essential chrpath cpio debianutils diffstat file gawk gcc git
    iputils-ping libacl1 libcrypt-dev locales python3 python3-git
    python3-jinja2 python3-pexpect python3-pip python3-subunit socat
    texinfo unzip wget xz-utils zstd
)
# Explicit essentials for minimal installations and the checks below.
packages+=(
    ca-certificates coreutils diffutils findutils gzip bzip2 tar patch perl
    python3-venv util-linux procps
)

needs_venv=0
case "$ID:${VERSION_ID:-}" in
    ubuntu:22.04|debian:11) needs_venv=1 ;;
    *) packages+=(python3-websockets) ;;
esac

if (( ! minimal )); then
    # Supplementary tools, NOT all mandatory dependencies of every build.
    # libncurses-dev is the modern ncurses/terminfo development package.
    packages+=(
        autoconf automake libtool libtool-bin pkg-config cmake ninja-build
        bison flex libncurses-dev libssl-dev libelf-dev
        libglib2.0-dev libarchive-dev device-tree-compiler
        lz4 rsync curl openssh-client tmux xterm iproute2
        libegl1 libgl1-mesa-dev libgl1-mesa-dri libsdl2-dev
        dosfstools mtools parted e2fsprogs
    )
fi

printf 'Host: %s (%s)\n' "${PRETTY_NAME:-$ID}" "$(uname -m)"
printf '\nPackages to install:\n'
printf '  %s\n' "${packages[@]}"
if (( needs_venv )); then
    echo 'Also: install websockets into ~/.local/share/yocto/host-tools-venv.'
fi
if (( dry_run )); then
    echo
    echo 'Dry run: would refresh APT, install packages, enable en_US.UTF-8,'
    echo 'and check tool versions, Python modules, and unprivileged namespaces.'
    echo 'No changes made. Package availability has not been checked.'
    exit 0
fi

if (( EUID == 0 )); then
    echo 'Run this script as your normal build user, WITHOUT sudo.' >&2
    echo 'It invokes sudo only for package installation and locale generation.' >&2
    exit 1
fi
command -v sudo >/dev/null || { echo 'Install sudo and grant your user access first.' >&2; exit 1; }
sudo -v

# Never run dist-upgrade, remove packages, or add third-party repositories.
apt_options=(-o DPkg::Lock::Timeout=120 -o Acquire::Retries=3)
sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" \
    -o APT::Update::Error-Mode=any update
sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" \
    install -y --no-install-recommends --no-remove "${packages[@]}"

# Enable the required locale without changing the user's desktop language.
if ! grep -Eq '^en_US\.UTF-8[[:space:]]+UTF-8[[:space:]]*$' /etc/locale.gen; then
    printf '\nen_US.UTF-8 UTF-8\n' | sudo tee -a /etc/locale.gen >/dev/null
fi
if ! locale -a | grep -Ei '^en_US\.(utf8|UTF-8)$' >/dev/null; then
    sudo locale-gen
fi
locale -a | grep -Ei '^en_US\.(utf8|UTF-8)$' >/dev/null
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# These distributions ship a websockets version too old for the optional
# Wrynose upstream sstate service. Never use sudo pip or break system Python.
venv=''
if (( needs_venv )); then
    venv="$HOME/.local/share/yocto/host-tools-venv"
    if [[ -L "$venv" ]]; then
        echo "Refusing a symlinked venv: $venv" >&2; exit 1
    elif [[ -e "$venv" ]]; then
        if [[ ! -f "$venv/pyvenv.cfg" || ! -x "$venv/bin/python" ]] ||
           ! grep -Eq '^include-system-site-packages = true$' "$venv/pyvenv.cfg"; then
            echo "Existing path is not the expected system-site-packages venv: $venv" >&2
            exit 1
        fi
    else
        /usr/bin/python3 -m venv --system-site-packages "$venv"
    fi
    PIP_REQUIRE_VIRTUALENV=true "$venv/bin/python" -I -m pip \
        --disable-pip-version-check install --upgrade websockets
fi
check_python=${venv:+$venv/bin/python}
check_python=${check_python:-/usr/bin/python3}

printf '\nChecking host tools against the Yocto 6.0 minimum versions...\n'
"$check_python" -I - <<'PY'
import importlib
import re
import subprocess
import sys

checks = [
    ('Git', ['git', '--version'], (1, 8, 3, 1)),
    ('tar', ['tar', '--version'], (1, 28)),
    ('GNU make', ['make', '--version'], (4, 0)),
    ('GCC', ['gcc', '-dumpfullversion', '-dumpversion'], (10, 1)),
]
failed = False
for name, argv, minimum in checks:
    try:
        output = subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT, timeout=10)
        match = re.search(r'\d+(?:\.\d+)+', output.splitlines()[0])
        if match is None:
            raise ValueError('could not parse version')
        version = tuple(map(int, match.group().split('.')))
        ok = version + (0,) * (4 - len(version)) >= minimum + (0,) * (4 - len(minimum))
        print(f'{name:12} {match.group():12} {"OK" if ok else "TOO OLD"}')
        failed |= not ok
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f'{name:12} FAILED: {exc}')
        failed = True
ok = sys.version_info >= (3, 9)
print(f'{"Python":12} {sys.version.split()[0]:12} {"OK" if ok else "TOO OLD"}')
failed |= not ok
for module in ('git', 'jinja2', 'pexpect', 'subunit', 'websockets'):
    try:
        importlib.import_module(module)
        print(f'Python module {module}: OK')
    except ImportError as exc:
        print(f'Python module {module}: FAILED: {exc}')
        failed = True
if failed:
    print('Use the buildtools/buildtools-extended setup for your Yocto branch if needed.')
    sys.exit(1)
PY

printf '\nHost resources (the filesystem shown is the current directory):\n'
free -h
df -h -- "$PWD"
printf '\nPackages and locale installed. Before your next build, run:\n\n'
printf 'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8\n'
if [[ -n "$venv" ]]; then
    printf 'source %q\n' "$venv/bin/activate"
fi
echo '# Then source your Poky/OpenBMC/vendor setup script as usual.'

printf '\nChecking unprivileged user + network namespaces...\n'
if ! ns_error=$(unshare --user --map-root-user --net true 2>&1); then
    printf 'WARNING: namespace diagnostic failed:\n%s\n' "$ns_error" >&2
    echo 'This can indicate a kernel, AppArmor, or container policy restriction.' >&2
    echo 'Check your actual BitBake invocation; this generic probe is not its exact security context.' >&2
    echo 'No security policy was changed. Package installation succeeded.' >&2
    exit 2
fi
echo 'Namespace diagnostic: OK.'
echo 'Basic host checks passed. No Yocto build was started or validated.'
