#!/usr/bin/env bash
# Debian 13 (trixie) development workstation setup, 2026 edition.
# PREVIEW ONLY by default. --apply is required for all system changes.
# Package catalog: one package per line below; comment out entries as needed.
# Dependencies are resolved as one APT transaction, NOT one apt call per package.
# No repositories are added, no WM is auto-started, no apt autoremove/clean/-f.
# References:
# https://www.debian.org/releases/trixie/
# https://manpages.debian.org/trixie/apt/apt-get.8.en.html
# https://manpages.debian.org/trixie/dpkg-dev/deb-control.5.en.html
# https://packages.debian.org/trixie/i3-wm
# https://packages.debian.org/trixie/sway
# https://packages.debian.org/trixie/labwc
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
unset APT_CONFIG PYTHONPATH PYTHONHOME || true
if [[ ! -x /usr/bin/python3 ]]; then
    printf 'This script needs existing /usr/bin/python3. Nothing was installed.\n' >&2
    printf 'Install python3 explicitly first, then run the preview again.\n' >&2
    exit 1
fi
exec /usr/bin/python3 -I - "$@" <<'LX_PYTHON'
# Package catalogs: one package per line; comment out a whole line to omit it.
GROUPS = {
    "base": ("Everyday terminal, search, monitoring and Git tools", """
ca-certificates     # System certificate bundle
curl                # HTTP client
wget                # Download client
git                 # Version control
git-email           # Email-based patch workflow
gh                  # GitHub CLI (no login is performed)
tig                 # Terminal Git browser
vim                 # Vi editor
neovim              # Extensible terminal editor
nano                # Small terminal editor
less                # Pager
man-db              # Manual pages
manpages-dev        # C and system API manual pages
bash-completion     # Shell completion
plocate             # Indexed filename search (may enable its update timer)
fastfetch           # System information display; replaces neofetch in this selection
htop                # Interactive process monitor
btop                # Resource monitor; replaces bashtop in this selection
ncdu                # Disk usage browser
duf                 # Filesystem usage display
ripgrep             # Fast text search (rg)
fd-find             # File search (Debian command: fdfind)
fzf                 # Fuzzy selector
bat                 # Syntax-aware pager (Debian command: batcat)
jq                  # JSON processor
tree                # Directory tree display
tmux                # Terminal multiplexer
rsync               # File synchronization
openssh-client      # SSH client only; no SSH server requested
unzip               # ZIP extraction
zip                 # ZIP creation
xz-utils            # XZ compression
zstd                # Zstandard compression
file                # File type detection
procps              # ps, free, top and related utilities
util-linux          # lscpu, lsblk, findmnt and more
pciutils            # PCI inventory
usbutils            # USB inventory
cpuinfo             # CPU information utilities
boxes               # Text boxes
"""),
    "dev": ("C/C++, build systems, code navigation and packaging", """
build-essential     # GCC, G++, Make and Debian build essentials
pkg-config          # Library discovery
cmake               # CMake build system
ninja-build         # Ninja executor
meson               # Meson build system
autoconf            # Configure script generation
automake            # Makefile generation
libtool             # Portable library build tools
libtool-bin         # libtool executable
ccache              # Compiler cache
flex                # Lexer generator
bison               # Parser generator
gperf               # Perfect hash generator
patch               # Apply patches
patchutils          # Inspect/filter patches
quilt               # Patch stacks
diffstat            # Patch statistics
bear                # Compilation database generation
universal-ctags     # Source tags
cscope              # C source navigation
global              # GNU GLOBAL source navigation
libssl-dev          # OpenSSL headers
libelf-dev          # ELF headers
libncurses-dev      # Terminal UI development
libzstd-dev         # Zstd headers
zlib1g-dev          # Zlib headers
liblzma-dev         # LZMA headers
libbz2-dev          # Bzip2 headers
libffi-dev          # FFI headers
libreadline-dev     # Readline headers
libsqlite3-dev      # SQLite headers
libxml2-dev         # XML headers
libxslt1-dev        # XSLT headers
libcurl4-openssl-dev # libcurl headers
fakeroot            # Packaging without running the build as root
dpkg-dev            # Debian packaging tools
debhelper           # Debian packaging helpers
"""),
    "debug": ("Debugging, LLVM, tracing, static analysis and coverage", """
gdb                 # GNU debugger
gdb-multiarch       # Multi-architecture GDB
strace              # System call tracing
ltrace              # Library call tracing
valgrind            # Memory and CPU analysis
linux-perf          # Debian perf tools; permissions are not changed
trace-cmd           # ftrace frontend
bpftrace            # eBPF tracing; kernel/policy support still required
clang               # Distro Clang
clangd              # C/C++ language server
clang-format        # C/C++ formatter
clang-tidy          # Clang static analysis
clang-tools         # Additional Clang tools
llvm                # Distro LLVM tools
lld                 # LLVM linker
lldb                # LLVM debugger
cppcheck            # C/C++ static analysis
sparse              # Kernel-oriented static analysis
coccinelle          # Semantic patches
shellcheck          # Shell static analysis
shfmt               # Shell formatter
lcov                # Coverage reporting
gcovr               # GCC coverage reporting
heaptrack           # Heap profiling
hyperfine           # Command benchmarking
"""),
    "python": ("Python development without modifying system Python with pip", """
python3             # Distro Python
python3-dev         # Python headers
python3-venv        # Virtual environments
python3-pip         # Use inside a venv; this script never runs pip
pipx                # Isolated CLI environments
python3-pytest      # Tests
python3-pytest-cov  # Test coverage
python3-coverage    # Coverage measurement
python3-mypy        # Type checks
black               # Formatter
ruff                # Lint/format tool, where packaged
ipython3            # Interactive shell
python3-build       # Python package builds
python3-wheel       # Wheel support
python3-serial      # Serial-port APIs
"""),
    "rust": ("Distro Rust; leaves existing rustup toolchains and PATH unchanged", """
rustc               # Distro Rust compiler
cargo               # Distro Cargo
rustfmt             # Rust formatter
rust-clippy         # Rust lints
rust-src            # Distro standard-library source
rust-analyzer       # Language server, if the configured repository provides it
"""),
    "go": ("Go development", """
golang-go           # Go compiler and tools
gopls               # Go language server
"""),
    "node": ("JavaScript/TypeScript ecosystem base; no global npm installs", """
nodejs              # Distro Node.js
npm                 # Distro npm
"""),
    "java": ("Java development", """
default-jdk         # Distro default JDK
maven               # Java build tooling
gradle              # Distro Gradle; projects may need their own wrapper version
"""),
    "lua": ("Lua development", """
lua5.4              # Lua interpreter
liblua5.4-dev       # Lua development headers
luarocks            # Lua package manager; nothing downloaded with it by this script
"""),
    "ruby": ("Ruby development", """
ruby                # Ruby interpreter
ruby-dev            # Ruby headers
bundler             # Ruby dependency manager
"""),
    "php": ("PHP CLI development; no web server", """
php-cli             # PHP CLI
php-dev             # PHP extension development
composer            # PHP dependency manager
"""),
    "serial": ("Serial console development; dialout membership is separate opt-in", """
minicom             # Serial terminal
picocom             # Small serial terminal
tio                 # Serial console
socat               # Stream/socket relay
lrzsz               # X/Y/ZMODEM transfer
"""),
    "embedded": ("Hardware interfaces and embedded Linux development", """
openocd             # Debug server; not started by this script
dfu-util            # DFU flashing utility; no device is flashed
device-tree-compiler # dtc and device-tree utilities
u-boot-tools        # Boot image tools
i2c-tools           # I2C diagnostics; no bus scanning is performed
gpiod               # GPIO userspace tools; no GPIO is changed
can-utils           # SocketCAN tools
libusb-1.0-0-dev    # USB library headers
libgpiod-dev        # GPIO library headers
libi2c-dev          # I2C headers
libudev-dev         # udev development headers
"""),
    "arm64": ("ARM64 Linux cross-compiler", """
gcc-aarch64-linux-gnu # AArch64 GCC
g++-aarch64-linux-gnu # AArch64 G++
binutils-aarch64-linux-gnu # AArch64 binutils
"""),
    "arm32": ("ARM hard-float Linux cross-compiler", """
gcc-arm-linux-gnueabihf # ARM hard-float GCC
g++-arm-linux-gnueabihf # ARM hard-float G++
binutils-arm-linux-gnueabihf # ARM hard-float binutils
"""),
    "baremetal": ("ARM bare-metal tools; C++ newlib can be large", """
gcc-arm-none-eabi    # ARM bare-metal GCC
binutils-arm-none-eabi # ARM bare-metal binutils
libnewlib-arm-none-eabi # Bare-metal C library
libstdc++-arm-none-eabi-newlib # Bare-metal C++ library
"""),
    "kernel": ("Kernel build/patch prerequisites; does not install a kernel", """
build-essential     # Native compiler and Make
bc                  # Kernel build calculations
bison               # Parser generator
flex                # Lexer generator
libssl-dev          # Certificate/signing headers
libelf-dev          # ELF development headers
libncurses-dev      # menuconfig
pahole              # BTF generation
cpio                # Initramfs archive tools
kmod                # Module utilities; nothing is loaded
rsync               # Kernel packaging helper
perl                # Kernel scripts
python3             # Kernel scripts
b4                  # Patch-series workflow
git-email           # Email patches
sparse              # Static analysis
coccinelle          # Semantic checks
libcap-dev          # Tool development headers
libunwind-dev       # Unwinding headers
libdw-dev           # DWARF headers
libslang2-dev       # perf TUI headers
libtraceevent-dev   # perf/trace tooling headers
"""),
    "dkms": ("DKMS only; distro hooks MAY compile already-registered modules", """
dkms                # Module build framework; no kernel/driver is selected here
"""),
    "yocto": ("Broad Yocto build-host package set; branch support still matters", """
build-essential     # Native toolchain
chrpath             # RPATH editing
cpio                # Archive handling
debianutils         # Host utilities
diffstat            # Diff summaries
file                # File identification
gawk                # GNU awk
git                 # Source retrieval
iputils-ping        # Network diagnostics
libacl1             # ACL runtime
libcrypt-dev        # crypt development headers
locales             # Locale definitions; no desktop-language change
python3             # BitBake interpreter
python3-git         # GitPython
python3-jinja2      # Templates
python3-pexpect     # Interactive process automation
python3-pip         # Package tooling (not invoked)
python3-subunit     # Test result protocol
python3-venv        # Isolated Python environments
python3-websockets  # Host module; version is distro-provided
socat               # Stream helper
texinfo             # Documentation tools
unzip               # Archives
wget                # Fetching
xz-utils            # Archives
zstd                # Archives
"""),
    "ffmpeg": ("FFmpeg source-build headers/tools; features are not auto-enabled", """
build-essential     # Native compiler
pkg-config          # Library detection
nasm                # Optimized x86 assembly (x86 hosts only)
yasm                # Legacy assembly support (x86 hosts only)
libaom-dev          # AOM AV1
libdav1d-dev        # dav1d AV1
libvpx-dev          # VP8/VP9
libsvtav1-dev       # SVT-AV1, where available
libopus-dev         # Opus
libvorbis-dev       # Vorbis
libmp3lame-dev      # LAME MP3
libspeex-dev        # Speex
libsoxr-dev         # Resampling
libass-dev          # Subtitles
libfreetype-dev     # Fonts
libfontconfig-dev   # Font configuration
libfribidi-dev      # Bidirectional text
libharfbuzz-dev     # Text shaping
libwebp-dev         # WebP
libopenjp2-7-dev    # JPEG2000
libsdl2-dev         # Playback UI
libasound2-dev      # ALSA
libpulse-dev        # PulseAudio headers; no sound-server replacement
libv4l-dev          # Video capture
libgnutls28-dev     # TLS
zlib1g-dev          # Compression
libbz2-dev          # Compression
liblzma-dev         # Compression
"""),
    "ffmpeg-gpl": ("Optional GPL external codecs; review resulting build license", """
libx264-dev         # x264; FFmpeg use normally needs --enable-gpl
libx265-dev         # x265; FFmpeg use normally needs --enable-gpl
libxvidcore-dev     # Xvid
libvidstab-dev      # Stabilization
librubberband-dev   # Audio time stretching
"""),
    "network": ("Network inspection clients; no scanning or capture is started", """
iproute2            # ip, ss and traffic tools
ethtool             # NIC diagnostics
iputils-ping        # ping
traceroute          # Route diagnostics
mtr-tiny            # Route/latency diagnostic
dnsutils            # DNS utilities
tcpdump             # Packet capture, not run automatically
tshark              # CLI packet analyzer; capture permissions are not granted
iperf3              # Throughput tool; server not requested
netcat-openbsd      # Netcat
nmap                # Network discovery, not run automatically
"""),
    "containers": ("Podman/rootless-container tools; no Docker group grants", """
podman              # Container engine
buildah             # Container image builds
skopeo              # Image inspection/copy
uidmap              # User namespace mapping helpers
slirp4netns         # User-mode networking
fuse-overlayfs      # Rootless overlay support
passt               # User-mode networking alternative
"""),
    "qemu": ("System and user-mode emulation; no VM is started", """
qemu-system-x86     # x86 emulation
qemu-system-arm     # ARM/AArch64 emulation
qemu-utils          # Image tools
qemu-user           # User-mode emulation
ovmf                # UEFI firmware for x86 guests
"""),
    "editors": ("Optional graphical editors and extra terminal environments", """
gedit               # Graphical text editor
geany               # Lightweight IDE
meld                # Graphical diff
emacs-gtk           # Graphical Emacs
kate                # KDE editor
kitty               # GPU terminal
alacritty           # GPU terminal
xfce4-terminal      # Lightweight terminal
"""),
    "database": ("Database clients and headers, not database servers", """
sqlite3             # SQLite CLI
libsqlite3-dev      # SQLite development
postgresql-client   # PostgreSQL client
libpq-dev           # PostgreSQL headers
mariadb-client      # MariaDB client
libmariadb-dev      # MariaDB headers
redis-tools         # Redis clients
"""),
    "gui-dev": ("Optional GTK/Qt/Wayland/X11 development headers", """
libgtk-3-dev        # GTK3
libgtk-4-dev        # GTK4
qt6-base-dev        # Qt6
qt6-tools-dev       # Qt6 tools
qt6-declarative-dev # Qt6 QML
libwayland-dev      # Wayland headers
wayland-protocols   # Protocol descriptions
libx11-dev          # Xlib
libxcb1-dev         # XCB
libxkbcommon-dev    # Keyboard mapping
libgl1-mesa-dev     # OpenGL headers
libvulkan-dev       # Vulkan headers; no driver installation guarantee
"""),
    "docs": ("Documentation and diagram tools; no full TeX distribution", """
texinfo             # Info/HTML documentation
doxygen             # API documentation
graphviz            # Graph layouts
python3-sphinx      # Sphinx HTML builds
python3-sphinx-rtd-theme # Sphinx theme
pandoc              # Document conversion
"""),
    "fun": ("Optional terminal aesthetics", """
figlet              # Text banners
toilet              # Text banners
cmatrix             # Matrix animation
cowsay              # Text art
lolcat              # Colored output
"""),
}

# Shared X11/Wayland tools belong to EACH selected WM for safe removal tracking.
X11 = """
xserver-xorg        # X server and default drivers
xinit               # startx (no .xinitrc overwrite)
xauth               # X authorization
x11-xserver-utils   # xrandr and X server utilities
dbus-user-session   # User D-Bus
xterm               # Fallback X terminal
fonts-dejavu-core   # Readable terminal font
fonts-firacode      # Development font
xdg-utils           # Desktop integration
"""
WAYLAND = """
xwayland            # X applications under Wayland
foot                # Wayland terminal
wl-clipboard        # Wayland clipboard
grim                # Wayland screenshot tool
slurp               # Region selection
waybar              # Panel (not auto-configured)
mako-notifier       # Notifications
wmenu               # Launcher
swaybg              # Wallpaper helper
swayidle            # Idle helper (policy not configured)
swaylock            # Screen locker (auto-lock not configured)
xdg-desktop-portal-wlr # wlroots portal backend
xdg-desktop-portal-gtk # GTK file chooser portal
xdg-utils           # Desktop integration
dbus-user-session   # User D-Bus
fonts-dejavu-core   # Terminal font
fonts-firacode      # Development font
"""
WMS = {
    "i3": ("X11 tiling; keyboard-first", X11 + """
i3-wm               # i3 window manager
i3status            # Status bar
i3lock              # Screen locker; policy not configured
suckless-tools      # dmenu
rofi                # Launcher
dunst               # Notifications
dex                 # XDG autostart helper
"""),
    "awesome": ("X11 dynamic tiling; Lua configuration", X11 + """
awesome             # AwesomeWM
rofi                # Launcher
"""),
    "fluxbox": ("X11 lightweight stacking", X11 + """
fluxbox             # Fluxbox
"""),
    "openbox": ("X11 lightweight stacking", X11 + """
openbox             # Openbox
obconf              # Configuration UI, when available
tint2               # Panel
rofi                # Launcher
dunst               # Notifications
"""),
    "spectrwm": ("X11 dynamic tiling", X11 + """
spectrwm            # Spectrwm
suckless-tools      # dmenu
"""),
    "bspwm": ("X11 binary-space tiling; needs a configured sxhkd session", X11 + """
bspwm               # bspwm
sxhkd               # Hotkey daemon
rofi                # Launcher
dunst               # Notifications
"""),
    "dwm": ("X11 minimal tiling; customization is normally compiled", X11 + """
dwm                 # Distro dwm build
suckless-tools      # dmenu and related tools
"""),
    "xmonad": ("X11 Haskell-configured tiling; a larger dependency set", X11 + """
xmonad              # XMonad
libghc-xmonad-contrib-dev # Extensions
xmobar              # Status bar
"""),
    "sway": ("Wayland tiling, i3-style", WAYLAND + """
sway                # Sway compositor
"""),
    "labwc": ("Wayland stacking, Openbox-style", WAYLAND + """
labwc               # Labwc compositor
"""),
}
DEFAULT_GROUPS = ("base", "dev", "debug", "python", "serial")
# Heavy cross compilers, DKMS hooks, GPL codec libs, GUI libraries and WMs stay opt-in.
ALL_DEV = ("base", "dev", "debug", "python", "rust", "go", "node", "java", "lua",
           "ruby", "php", "serial", "embedded", "kernel", "yocto", "ffmpeg",
           "network", "containers", "database", "docs")
# These small x86-specific tools are supplemental and resolved against host APT.
X86_EXTRAS = {"base": "cpu-checker # virtualization diagnostic\ncpuid # x86 CPUID dump"}

# Implementation uses only Python's standard library and Debian's existing APT.
import argparse
import datetime as dt
import atexit
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys

STATE_DIR = Path('/var/lib/lx-post-install')
STATE_FILE = STATE_DIR / 'state.json'
LOCK_FILE = STATE_DIR / 'operation.lock'
PKG_RE = re.compile(r'^[a-z0-9][a-z0-9+.-]*(?::[a-z0-9][a-z0-9-]*)?$')
STATE_LIMIT = 2 * 1024 * 1024
ENV = {k: v for k, v in os.environ.items() if k not in ('APT_CONFIG', 'PYTHONPATH', 'PYTHONHOME')}
ENV.update(PATH='/usr/sbin:/usr/bin:/sbin:/bin', LC_ALL='C', LANG='C')
# These packages must never be removed by this convenience tool.
PROTECTED = {'apt', 'dpkg', 'sudo', 'bash', 'dash', 'coreutils', 'libc6', 'systemd',
             'systemd-sysv', 'init', 'login', 'passwd', 'udev', 'python3',
             'python3-minimal', 'openssh-server', 'gdm3', 'lightdm', 'sddm'}
ACTIVE_COMMANDS = {'i3-wm': 'i3', 'awesome': 'awesome', 'fluxbox': 'fluxbox',
                   'openbox': 'openbox', 'spectrwm': 'spectrwm', 'bspwm': 'bspwm',
                   'dwm': 'dwm', 'xmonad': 'xmonad', 'sway': 'sway', 'labwc': 'labwc',
                   'xterm': 'xterm', 'foot': 'foot', 'kitty': 'kitty',
                   'alacritty': 'alacritty', 'xfce4-terminal': 'xfce4-terminal'}

class SetupError(Exception):
    pass

def say(message=''):
    # Avoid interpreting control characters from metadata, paths or error output.
    print(''.join(c if c in '\n\t' or ord(c) >= 32 and ord(c) != 127 else '?' for c in str(message)), flush=True)

def run(argv, *, check=True, timeout=180):
    try:
        p = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, env=ENV, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise SetupError(f'Cannot run {shlex.join(argv)}: {e}') from e
    if check and p.returncode:
        raise SetupError(f'{shlex.join(argv)} failed ({p.returncode}):\n{p.stdout}\n{p.stderr}')
    return p

def csv_values(items):
    return list(dict.fromkeys(x.strip() for item in (items or []) for x in item.split(',') if x.strip()))

def package_lines(text):
    for line in text.splitlines():
        package, _, description = line.partition('#')
        package = package.strip()
        if not package:
            continue
        if not PKG_RE.fullmatch(package):
            raise SetupError(f'Invalid package in editable catalog: {package!r}')
        yield package, description.strip()

def arguments(argv):
    p = argparse.ArgumentParser(
        prog='lx-post-install-debian.sh',
        description='Debian 13 developer setup. PREVIEW ONLY unless --apply is present.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''Examples:
  %(prog)s --list
  %(prog)s --all-dev --wm i3,awesome,fluxbox          # preview, no downloads
  %(prog)s --profiles base,dev,debug,serial --wm i3 --apply --refresh
  %(prog)s --wm fluxbox --uninstall                  # preview tracked removals
  %(prog)s --wm fluxbox --uninstall --apply          # remove after confirmation

No autoremove, purge, apt -f, distro upgrade, desktop switch or repository setup
is run implicitly. Normal application/daemon package-maintainer hooks still run
during an explicitly approved APT transaction. See the accompanying README.''')
    p.add_argument('--profiles', action='append', metavar='NAME,NAME', help='Selected groups; replaces defaults. Use none for no group.')
    p.add_argument('--all-dev', action='store_true', help='Select the documented broad development preset, not every optional group')
    p.add_argument('--minimal', action='store_true', help='Select base only')
    p.add_argument('--wm', action='append', metavar='NAME,NAME', help='Optional WMs/compositors; all selects every catalog WM')
    p.add_argument('--exclude', action='append', metavar='PKG,PKG', help='Exclude direct package requests (APT dependencies may still require them)')
    p.add_argument('--keep', action='append', metavar='PKG,PKG', help='Never remove these packages in this invocation')
    op = p.add_mutually_exclusive_group()
    op.add_argument('--install', action='store_true', help='Plan installation (default); still needs --apply to change anything')
    op.add_argument('--uninstall', action='store_true', help='Plan removal of script-introduced packages only')
    p.add_argument('--apply', action='store_true', help='Permit actual package and explicitly requested group changes')
    p.add_argument('--yes', action='store_true', help='With --apply, skip this script\'s typed confirmation')
    p.add_argument('--dry-run', '--plan', action='store_true', dest='dry_run', help='Explicit read-only preview; conflicts with --apply')
    p.add_argument('--refresh', action='store_true', help='With --apply, run apt-get update before planning; no refresh in preview')
    p.add_argument('--upgrade-selected', action='store_true', help='Permit selected installed packages to upgrade; default leaves them unchanged')
    p.add_argument('--purge', action='store_true', help='With --uninstall, purge package-managed config; never user dotfiles')
    p.add_argument('--dialout', action='store_true', help='With --apply, add the normal invoking user to dialout')
    p.add_argument('--strict', action='store_true', help='Fail rather than skip packages without an APT candidate')
    p.add_argument('--reserve-gib', type=float, default=1.0, help='Conservative extra free-space reserve (default 1 GiB, minimum 0.5)')
    p.add_argument('--list', action='store_true', help='Show packages with descriptions for all or selected groups/WMs; exit')
    p.add_argument('--list-groups', action='store_true', help='Show group names and preset membership; exit')
    p.add_argument('--list-wms', action='store_true', help='Show available window-manager selections; exit')
    p.add_argument('--show-apt', action='store_true', help='Also print the full apt-get simulation output')
    p.add_argument('--report', metavar='FILE.json', help='Explicitly write the plan/report to a new file (never overwrite)')
    a = p.parse_args(argv)
    if sum(bool(x) for x in (a.profiles, a.all_dev, a.minimal)) > 1:
        p.error('Choose only one of --profiles, --all-dev or --minimal.')
    if a.apply and a.dry_run:
        p.error('--apply and --dry-run/--plan conflict.')
    if a.yes and not a.apply:
        p.error('--yes requires --apply.')
    if a.purge and not a.uninstall:
        p.error('--purge requires --uninstall.')
    if a.uninstall and (a.upgrade_selected or a.dialout or a.refresh):
        p.error('--uninstall cannot combine with --upgrade-selected, --dialout or --refresh.')
    if not 0.5 <= a.reserve_gib <= 1024:
        p.error('--reserve-gib must be between 0.5 and 1024.')
    if a.uninstall and not any((a.profiles, a.wm, a.all_dev, a.minimal)):
        p.error('Uninstall requires explicit --profiles or --wm selection.')
    if a.apply and any((a.list, a.list_groups, a.list_wms)):
        p.error('List commands are read-only; do not combine with --apply.')
    return a

def selection(a, arch):
    if a.profiles:
        groups = csv_values(a.profiles)
        if groups == ['none']:
            groups = []
    elif a.all_dev:
        groups = list(ALL_DEV)
    elif a.minimal:
        groups = ['base']
    elif a.wm or a.dialout:
        groups = []
    else:
        groups = list(DEFAULT_GROUPS)
    wms = csv_values(a.wm)
    if wms == ['all']:
        wms = list(WMS)
    unknown = [g for g in groups if g not in GROUPS] + [w for w in wms if w not in WMS]
    if unknown:
        raise SetupError('Unknown group/WM: ' + ', '.join(unknown))
    excluded = set(csv_values(a.exclude))
    kept = set(csv_values(a.keep))
    for pkg in excluded | kept:
        if not PKG_RE.fullmatch(pkg):
            raise SetupError(f'Invalid package name: {pkg!r}')
    chosen = {}
    for group, raw in [(g, GROUPS[g][1]) for g in groups] + [('wm:' + w, WMS[w][1]) for w in wms]:
        if arch in ('amd64', 'i386'):
            raw += '\n' + X86_EXTRAS.get(group, '')
        for pkg, desc in package_lines(raw):
            if pkg in ('nasm', 'yasm') and arch not in ('amd64', 'i386'):
                continue
            if pkg in excluded:
                continue
            entry = chosen.setdefault(pkg, {'groups': [], 'description': desc})
            if group not in entry['groups']:
                entry['groups'].append(group)
    return groups, wms, chosen, kept

def show_lists(a, groups, wms, arch):
    if a.list_groups:
        for name, (description, _) in GROUPS.items():
            tag = 'default' if name in DEFAULT_GROUPS else 'all-dev' if name in ALL_DEV else 'opt-in'
            say(f'{name:13} [{tag:7}] {description}')
    if a.list_wms:
        for name, (description, _) in WMS.items():
            say(f'{name:13} {description}')
    if a.list:
        if not any((a.profiles, a.wm, a.all_dev, a.minimal)):
            groups, wms = list(GROUPS), list(WMS)
        for name, catalog in [(g, GROUPS[g]) for g in groups] + [('wm:' + w, WMS[w]) for w in wms]:
            description, raw = catalog
            if arch in ('amd64', 'i386'):
                raw += '\n' + X86_EXTRAS.get(name, '')
            say(f'\n[{name}] {description}')
            for pkg, desc in package_lines(raw):
                say(f'  {pkg:34} {desc}')
        say('\nCatalog only; availability is checked against your APT cache during a plan.')

def host_info():
    info = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            info[k] = v.strip('"\'')
    if info.get('ID') != 'debian' or info.get('VERSION_ID', '').split('.')[0] != '13':
        raise SetupError('This script targets Debian 13 (trixie). No distribution changes were made.')
    for cmd in ('apt-get', 'apt-cache', 'dpkg-query', 'dpkg', 'ps'):
        if not shutil.which(cmd, path=ENV['PATH']):
            raise SetupError(f'Required existing host tool is missing: {cmd}. Nothing installed automatically.')
    return info, run(['dpkg', '--print-architecture']).stdout.strip()

APT_READ_OPTIONS = ['-o', 'Dir::Cache::pkgcache=', '-o', 'Dir::Cache::srcpkgcache=']

def candidates(packages):
    result = {}
    if not packages:
        return result
    p = run(['apt-cache', *APT_READ_OPTIONS, 'policy', *sorted(packages)])
    current = None
    for line in p.stdout.splitlines():
        if line and not line[0].isspace() and line.endswith(':'):
            current = line[:-1]
        elif current and line.strip().startswith('Candidate:'):
            value = line.split(':', 1)[1].strip()
            result[current] = None if value == '(none)' else value
    return result

def installed():
    fmt = '${binary:Package}\t${Version}\t${Installed-Size}\t${db:Status-Status}\t${Essential}\t${Protected}\t${Priority}\n'
    result = {}
    for line in run(['dpkg-query', '-W', '-f=' + fmt]).stdout.splitlines():
        fields = line.split('\t')
        if len(fields) != 7 or fields[3] != 'installed':
            continue
        name, version, size, _, essential, protected, priority = fields
        if not PKG_RE.fullmatch(name):
            continue
        result[name] = {'version': version, 'size': int(size or 0) * 1024,
                        'protected': essential == 'yes' or protected == 'yes' or priority == 'required'}
    return result

def lookup(table, name, arch):
    if name in table:
        return name
    if ':' not in name:
        for candidate in (name + ':' + arch, name + ':all'):
            if candidate in table:
                return candidate
    return None

def protect(name, rec):
    base = name.split(':')[0]
    return rec.get('protected', False) or base in PROTECTED or base.startswith(('linux-image-', 'grub-', 'shim-', 'initramfs-tools'))

def validate_state(data):
    if not isinstance(data, dict) or data.get('schema') != 1 or not isinstance(data.get('packages'), dict):
        raise SetupError('Invalid tracking file; refusing to infer package ownership.')
    if len(data['packages']) > 10000:
        raise SetupError('Tracking file contains too many entries.')
    for pkg, record in data['packages'].items():
        if not PKG_RE.fullmatch(pkg) or not isinstance(record, dict) or not isinstance(record.get('groups'), list):
            raise SetupError('Malformed tracked package.')
        if not record['groups'] or any(not isinstance(g, str) or not (g in GROUPS or g.startswith('wm:') and g[3:] in WMS) for g in record['groups']):
            raise SetupError('Malformed tracked groups.')
    return data

def read_state():
    for path in (STATE_DIR, STATE_FILE):
        if path.is_symlink():
            raise SetupError(f'Refusing symlinked tracking path: {path}')
        if path.exists():
            st = path.stat()
            if st.st_uid != 0 or st.st_mode & 0o022:
                raise SetupError(f'Tracking path must be root-owned and not group/world-writable: {path}')
    if not STATE_FILE.exists():
        return {'schema': 1, 'packages': {}}
    if not STATE_FILE.is_file() or STATE_FILE.stat().st_size > STATE_LIMIT:
        raise SetupError('Invalid or oversized tracking file.')
    try:
        return validate_state(json.loads(STATE_FILE.read_text()))
    except (OSError, ValueError) as e:
        raise SetupError(f'Cannot read tracking file: {e}') from e

# Root helper has a fixed destination. No user-provided path or command is evaluated.
STATE_WRITE = r'''
import json, os, pathlib, stat, sys, tempfile
base = pathlib.Path('/var/lib/lx-post-install')
payload = sys.stdin.buffer.read(2 * 1024 * 1024 + 1)
if len(payload) > 2 * 1024 * 1024: raise SystemExit('State too large')
data = json.loads(payload)
if data.get('schema') != 1 or not isinstance(data.get('packages'), dict): raise SystemExit('Invalid state')
if base.is_symlink(): raise SystemExit('Unsafe state directory')
created = not base.exists()
base.mkdir(mode=0o755, exist_ok=True)
if created: os.chmod(base, 0o755)
st = base.stat()
if st.st_uid != 0 or st.st_mode & 0o022: raise SystemExit('Unsafe state directory ownership/mode')
target = base / 'state.json'
if target.is_symlink(): raise SystemExit('Unsafe state file')
fd, tmp = tempfile.mkstemp(prefix='.state-', dir=base)
try:
    os.fchmod(fd, 0o644)
    with os.fdopen(fd, 'wb') as f:
        f.write(payload); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, target)
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
'''

# A root-owned flock prevents two instances from corrupting shared ownership.
# This is separate from APT's own lock. Preview never creates either state path.
LOCK_PREP = r'''
import os, pathlib, stat
base = pathlib.Path('/var/lib/lx-post-install')
if base.is_symlink(): raise SystemExit('Unsafe tracking directory')
created = not base.exists()
base.mkdir(mode=0o755, exist_ok=True)
if created: os.chmod(base, 0o755)
st = base.stat()
if st.st_uid != 0 or st.st_mode & 0o022: raise SystemExit('Unsafe tracking directory mode')
p = base / 'operation.lock'
fd = os.open(p, os.O_CREAT | os.O_RDONLY | os.O_NOFOLLOW, 0o644)
st = os.fstat(fd)
if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
    raise SystemExit('Unsafe lock file')
os.fchmod(fd, 0o644)
os.close(fd)
'''

def acquire_apply_lock():
    if change_command(['sudo', '/usr/bin/python3', '-I', '-c', LOCK_PREP]):
        raise SetupError('Cannot prepare ownership lock.')
    fd = os.open(LOCK_FILE, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if st.st_uid != 0 or st.st_mode & 0o022 or not stat.S_ISREG(st.st_mode):
            raise SetupError('Unsafe lock ownership or mode.')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, SetupError) as e:
        os.close(fd)
        raise SetupError('Another installer is active, or ownership lock is unsafe.') from e
    atexit.register(os.close, fd)


def write_state(data):
    validate_state(data)
    payload = json.dumps(data, indent=2, sort_keys=True) + '\n'
    p = subprocess.run(['sudo', '/usr/bin/python3', '-I', '-c', STATE_WRITE], input=payload,
                       text=True, env=ENV)
    if p.returncode:
        raise SetupError('Package transaction finished, but ownership-state write failed. Inspect APT logs before removal.')

def operation_args(a, requested):
    options = [*APT_READ_OPTIONS, '-o', 'APT::Get::AutomaticRemove=false',
               '-o', 'APT::Install-Recommends=false', '-o', 'APT::Install-Suggests=false']
    if a.uninstall:
        return options + ['purge' if a.purge else 'remove', *requested]
    return options + ['--no-remove', 'install', *requested]

def simulate(a, requested):
    if not requested:
        return [], ''
    p = run(['apt-get', '--simulate', *operation_args(a, requested)])
    operations = []
    for line in p.stdout.splitlines():
        if line.startswith('Inst '):
            match = re.match(r'^Inst (\S+)(?: \[([^\]]+)\])? \((\S+)', line)
            if not match or not PKG_RE.fullmatch(match[1]):
                raise SetupError(f'Unrecognized APT installation record: {line}')
            operations.append({'op': 'install', 'name': match[1], 'version': match[3]})
        elif line.startswith(('Remv ', 'Purg ')):
            match = re.match(r'^(?:Remv|Purg) (\S+)', line)
            if not match or not PKG_RE.fullmatch(match[1]):
                raise SetupError(f'Unrecognized APT removal record: {line}')
            operations.append({'op': 'remove', 'name': match[1]})
        elif line.startswith('Conf '):
            # Normal Conf records are paired with Inst; an unrelated pending Conf
            # indicates a broken/interrupted prior transaction, handled below.
            continue
    new_names = {op['name'] for op in operations if op['op'] == 'install'}
    for line in p.stdout.splitlines():
        if line.startswith('Conf ') and line.split()[1] not in new_names:
            raise SetupError('APT would configure an unrelated pending package. Repair that transaction separately.')
    if a.uninstall and any(op['op'] == 'install' for op in operations):
        raise SetupError('Uninstall would install/upgrade another package. Refusing this unexpected plan.')
    if not a.uninstall and any(op['op'] == 'remove' for op in operations):
        raise SetupError('Install would remove packages. No removal is allowed on install.')
    return operations, p.stdout + p.stderr

def control_records(text):
    for paragraph in re.split(r'\n\s*\n', text.strip()):
        record = {}
        for line in paragraph.splitlines():
            if line and not line[0].isspace() and ': ' in line:
                key, value = line.split(': ', 1)
                record[key] = value
        if record:
            yield record

def sizes(operations, before, arch):
    metadata = {}
    installs = [op for op in operations if op['op'] == 'install']
    # Batch calls to avoid starting apt-cache once per dependency.
    for i in range(0, len(installs), 80):
        specs = [op['name'] + '=' + op['version'] for op in installs[i:i + 80]]
        p = run(['apt-cache', *APT_READ_OPTIONS, 'show', *specs])
        for rec in control_records(p.stdout):
            key = (rec.get('Package'), rec.get('Version'), rec.get('Architecture'))
            metadata[key] = {**metadata.get(key, {}), **rec}
    delta, archive_budget, unpack_budget = 0, 0, 0
    for op in operations:
        old_name = lookup(before, op['name'], arch)
        old_size = before[old_name]['size'] if old_name else 0
        if op['op'] == 'remove':
            if not old_name:
                raise SetupError(f'Cannot size removal for {op["name"]}.')
            op['old_size'] = old_size
            op['new_size'] = 0
            delta -= old_size
            continue
        base, _, qualified = op['name'].partition(':')
        possible = [metadata.get((base, op['version'], a)) for a in (qualified or arch, 'all')]
        rec = next((r for r in possible if r is not None), None)
        if not rec or 'Installed-Size' not in rec or 'Size' not in rec:
            raise SetupError(f'Missing size metadata for {op["name"]}={op["version"]}. Refresh APT explicitly, then retry.')
        new_size = int(rec['Installed-Size']) * 1024
        deb_size = int(rec['Size'])
        if new_size < 0 or deb_size < 0:
            raise SetupError('Negative package size in APT metadata.')
        op.update(old_size=old_size, new_size=new_size, archive_size=deb_size)
        delta += new_size - old_size
        archive_budget += deb_size
        unpack_budget += new_size
    return {'installed_delta': delta, 'archive_budget': archive_budget, 'unpack_budget': unpack_budget}

def filesystem(path):
    original = Path(path)
    p = original
    while not p.exists() and p != p.parent:
        p = p.parent
    v = os.statvfs(p)
    mount = str(p.resolve())
    try:
        mount = run(['findmnt', '-n', '-o', 'TARGET', '-T', str(p)], timeout=10).stdout.strip() or mount
    except SetupError:
        pass
    return {'path': str(original), 'mount': mount, 'device': p.stat().st_dev,
            'free': v.f_bavail * v.f_frsize, 'total': v.f_blocks * v.f_frsize,
            'free_inodes': v.f_favail, 'total_inodes': v.f_files}

def fs_snapshot():
    return [filesystem(p) for p in ('/', '/usr', '/var', '/var/cache/apt/archives', '/boot', '/tmp', Path.home())]

def human(n, signed=False):
    prefix = '-' if n < 0 else '+' if signed and n > 0 else ''
    x = abs(n)
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if x < 1024 or unit == 'TiB':
            return f'{prefix}{x:.2f} {unit}'
        x /= 1024

def disk_projection(snap, amounts, uninstall=False, reserve=1024**3):
    payload_devices = {row['device'] for row in snap[:3]}
    cache_device = snap[3]['device']
    unified = len(payload_devices) == 1
    result = []
    for row in snap:
        dev = row['device']
        estimate = None
        if unified:
            payload = amounts['installed_delta'] if dev in payload_devices else 0
            cache = amounts['archive_budget'] if dev == cache_device and not uninstall else 0
            estimate = row['free'] - payload - cache
        elif dev not in payload_devices:
            cache = amounts['archive_budget'] if dev == cache_device and not uninstall else 0
            estimate = row['free'] - cache
        # Full new payload (not just delta) is a conservative staging budget.
        need = 0
        if not uninstall and amounts['unpack_budget']:
            need += amounts['unpack_budget'] if dev in payload_devices else 0
            need += amounts['archive_budget'] if dev == cache_device else 0
            if dev in payload_devices or dev == cache_device:
                need += max(reserve, amounts['unpack_budget'] // 5)
        result.append({**row, 'estimated_after': estimate, 'conservative_need': need,
                       'space_ok': row['free'] >= need,
                       'inode_warning': row['total_inodes'] > 0 and row['free_inodes'] < 10000})
    return result, unified

def render_disk(rows, unified, a, amounts):
    say('\nSPACE REPORT (estimates, not a completed installation)')
    say(f'  Installed package size change: {human(amounts["installed_delta"], True)}')
    say(f'  Download/archive budget:       {human(amounts["archive_budget"])} (before existing-cache reuse)')
    say(f'  Full new unpacked payload:     {human(amounts["unpack_budget"])}')
    say('  Forecast assumes downloaded archives are retained; this is conservative.')
    say(f'\n  {"Path":29} {"Free BEFORE":>14} {"Est. free AFTER*":>19} {"Staging budget**":>18}')
    for r in rows:
        after = 'unknown (split FS)' if r['estimated_after'] is None else human(r['estimated_after'])
        say(f'  {r["path"][:29]:29} {human(r["free"]):>14} {after:>19} {human(r["conservative_need"]):>18}')
    say('\n  * Metadata estimate: Installed-Size plus an archive-size budget, not a guarantee.')
    say('    Mounts sharing the same filesystem show the same budget; do NOT add the rows.')
    if not unified:
        say('    Separate /, /usr or /var detected: per-filesystem payload allocation is unknown.')
        say('    Each payload filesystem is conservatively checked against the full unpack budget.')
    say('  ** Includes full new payload + archive budget where applicable + reserve.')
    say('  Not modeled: quotas, compression/reflinks, maintainer scripts, DKMS output,')
    say('  language caches, source/build trees, user data, or concurrent filesystem activity.')
    say('  Ordinary post-install package hooks can create files outside this estimate.')
    if any(not r['space_ok'] for r in rows):
        say('  WARNING: at least one filesystem is below the conservative free-space budget.')
    if any(r['inode_warning'] for r in rows):
        say('  WARNING: low reported inode availability on at least one filesystem.')


def install_requests(a, chosen, before, arch):
    policy = candidates(chosen)
    pending, missing, existing = {}, [], []
    for pkg in sorted(chosen):
        old = lookup(before, pkg, arch)
        if old and not a.upgrade_selected:
            existing.append(pkg)
            continue
        key = lookup(policy, pkg, arch)
        version = policy.get(key) if key else None
        if not version:
            if old:
                existing.append(pkg)
            else:
                missing.append(pkg)
            continue
        if old:
            comparison = run(['dpkg', '--compare-versions', version, 'gt', before[old]['version']], check=False)
            if comparison.returncode:
                existing.append(pkg)
                continue
        pending[pkg] = version
    if missing:
        say('\nNO APT CANDIDATE (not installed or silently substituted):\n  ' + '\n  '.join(missing))
        if a.strict or not pending and len(missing) == len(chosen):
            raise SetupError('No usable candidates for the requested selection (or --strict). Run apt-get update explicitly and check repositories.')
    return [name + '=' + version for name, version in pending.items()], pending, missing, existing


def removal_requests(a, groups, wms, chosen, state, before, arch, kept):
    selected_groups = set(groups) | {'wm:' + w for w in wms}
    requested = []
    reasons = []
    new_state = json.loads(json.dumps(state))
    for name, rec in sorted(state['packages'].items()):
        base = name.split(':')[0]
        if base not in chosen or name in kept or base in kept:
            continue
        overlap = set(rec['groups']) & selected_groups
        if not overlap:
            continue
        remaining = set(rec['groups']) - selected_groups
        if remaining:
            new_state['packages'][name]['groups'] = sorted(remaining)
            reasons.append(f'{name}: retained for {", ".join(sorted(remaining))}')
            continue
        actual = lookup(before, name, arch)
        if not actual:
            new_state['packages'].pop(name)
        elif protect(actual, before[actual]):
            reasons.append(f'{name}: protected system package retained')
        else:
            requested.append(actual)
    tracked_bases = {p.split(':')[0] for p in state['packages']}
    preexisting = [p for p in chosen if lookup(before, p, arch) and p not in tracked_bases]
    say(f'\nRemoval scope: {len(requested)} script-introduced direct package(s).')
    say(f'Preserving {len(preexisting)} installed package(s) not owned by this script.')
    for reason in reasons:
        say('  ' + reason)
    return sorted(set(requested)), new_state


def check_removal(ops, requested, before, arch):
    allowed = set(requested)
    for op in ops:
        actual = lookup(before, op['name'], arch)
        if op['op'] != 'remove' or actual not in allowed or protect(op['name'], before.get(actual, {})):
            raise SetupError(f'APT wants to remove/change a package outside the approved tracked selection: {op["name"]}. Refusing.')
    commands = set(run(['ps', '-e', '-o', 'comm=']).stdout.split())
    active = [pkg for pkg in requested if ACTIVE_COMMANDS.get(pkg.split(':')[0]) in commands]
    return active


def confirm(a, verb):
    if a.yes:
        return
    try:
        with open('/dev/tty', 'r+') as tty:
            tty.write(f'\nType {verb} to apply this plan, or anything else to cancel: ')
            tty.flush()
            answer = tty.readline().strip()
    except OSError as e:
        raise SetupError('Interactive confirmation requires a terminal. Use --apply --yes only after reviewing a preview.') from e
    if answer != verb:
        raise SetupError('Cancelled. No package transaction was run.')


def change_command(argv, *, input_text=None):
    label = 'root-owned installer-state helper' if '-c' in argv and '/usr/bin/python3' in argv else shlex.join(argv)
    say('\nExecuting: ' + label)
    p = subprocess.run(argv, text=True, input=input_text, env=ENV)
    return p.returncode


def report_new(path, report):
    if path:
        # Explicit user request only. O_EXCL refuses overwrites and symlink targets.
        with open(path, 'x', encoding='utf-8') as stream:
            json.dump(report, stream, indent=2, sort_keys=True)
            stream.write('\n')
        say(f'Report written: {path}')


def session_advice(wms):
    if not wms:
        return
    say('\nWINDOW-MANAGER SESSIONS')
    say('Choose an installed session at your existing display-manager login screen.')
    say('No display manager, default target, .xinitrc, keymap or current session was replaced.')
    for wm in wms:
        if wm == 'i3':
            say('  i3 from a local text TTY: startx /usr/bin/i3 -- :1')
        elif wm in ('sway', 'labwc'):
            say(f'  {wm} from a local text TTY: {wm}')
    say('WMs are alternatives, not simultaneously started. Wayland needs working graphics/seat access.')
    say('bspwm/sxhkd, panels, autostart and automatic locking may need personal configuration.')


def main(argv=None):
    a = arguments(sys.argv[1:] if argv is None else argv)
    if a.report and (Path(a.report).exists() or Path(a.report).is_symlink()):
        raise SetupError('Report destination already exists; choose a new path. Nothing changed.')
    info, arch = host_info()
    groups, wms, chosen, kept = selection(a, arch)
    if any((a.list, a.list_groups, a.list_wms)):
        show_lists(a, groups, wms, arch)
        return 0
    say(f'Debian developer setup | {info.get("PRETTY_NAME", "Debian 13")} | {arch}')
    say('Mode: ' + ('APPLY (confirmation required unless --yes)' if a.apply else 'PREVIEW ONLY: no APT update/download/install/remove or group changes'))
    say('Profiles: ' + (', '.join(groups) or 'none'))
    say('Window managers: ' + (', '.join(wms) or 'none'))
    say('APT Recommends/Suggests: off. Missing candidates: ' + ('fail' if a.strict else 'report and skip'))
    if a.apply:
        if os.getuid() == 0:
            raise SetupError('Run as your normal user WITHOUT sudo. The script invokes sudo only for approved system changes.')
        if not shutil.which('sudo', path=ENV['PATH']):
            raise SetupError('sudo is required for --apply. No changes made.')
        acquire_apply_lock()
    if a.refresh:
        if a.apply:
            say('Explicit --refresh: updating package indexes before calculating the plan.')
            rc = change_command(['sudo', 'apt-get', '-o', 'DPkg::Lock::Timeout=120',
                                 '-o', 'Acquire::Retries=3', '-o', 'APT::Update::Error-Mode=any', 'update'])
            if rc:
                raise SetupError('APT update failed; no package installation attempted.')
        else:
            say('--refresh not executed in preview. Estimates use your existing local APT indexes.')
    else:
        say('Using current local APT indexes; preview does not refresh them or require network.')
    before = installed()
    state = read_state()
    pending = {}
    missing = []
    next_state = state
    if a.uninstall:
        requested, next_state = removal_requests(a, groups, wms, chosen, state, before, arch, kept)
    else:
        requested, pending, missing, existing = install_requests(a, chosen, before, arch)
        say(f'\nDirect selection: {len(chosen)} packages; {len(existing)} already installed / unchanged.')
    ops, apt_output = simulate(a, requested)
    active = check_removal(ops, requested, before, arch) if a.uninstall else []
    amounts = sizes(ops, before, arch)
    snaps = fs_snapshot()
    projection, unified = disk_projection(snaps, amounts, a.uninstall, int(a.reserve_gib * 1024**3))
    say(f'\nAPT transaction, including dependencies: {len(ops)} package changes')
    for op in ops:
        suffix = '=' + op['version'] if op['op'] == 'install' else ''
        say(f'  {op["op"]:7} {op["name"]}{suffix}')
    if a.show_apt:
        say('\nFULL APT SIMULATION\n' + apt_output)
    if active:
        say('WARNING: running WM/terminal selected for removal: ' + ', '.join(active))
    render_disk(projection, unified, a, amounts)
    user = pwd.getpwuid(os.getuid()).pw_name
    if a.dialout:
        if user == 'root':
            say('\nDialout: apply must be run by the intended normal user, not root.')
        else:
            say(f'\nDialout: would add {user!r} with usermod -a -G dialout {user!r}.')
            say('This grants serial-device access; log out/in afterward. No chmod 666 on devices.')
    report = {'schema': 1, 'mode': 'uninstall' if a.uninstall else 'install',
              'host': info, 'architecture': arch, 'profiles': groups, 'wms': wms,
              'skipped_missing': missing, 'operations': ops, 'size_estimates': amounts,
              'filesystems': projection, 'applied': False,
              'estimate_limits': 'Installed-Size and archive upper budget; quotas/hooks/build outputs not predicted.'}
    if not a.apply:
        report_new(a.report, report)
        say('\nPREVIEW FINISHED. Free AFTER is a forecast, not a measured result. Nothing installed.')
        say('Use the same selection with --apply to perform the transaction; --refresh refreshes indexes first.')
        session_advice(wms)
        return 0
    if active:
        raise SetupError('Log out of the selected WM/terminal first; remove from a text TTY or another session. No automatic session termination.')
    if ops and not a.uninstall and any(not r['space_ok'] for r in projection):
        raise SetupError('Insufficient conservative free-space budget. Free space or select fewer groups.')
    if ops and any(r['inode_warning'] for r in projection):
        raise SetupError('Low inode availability: review the filesystem before applying.')
    confirm(a, 'REMOVE' if a.uninstall else 'INSTALL')
    # The package state may have changed while the user read the plan. Abort
    # rather than approving a different operation without a fresh preview.
    if installed() != before or read_state() != state:
        raise SetupError('Package/ownership state changed after planning. Re-run for a fresh plan.')
    ops_again, _ = simulate(a, requested)
    normalized = lambda records: [{k: op[k] for k in ('op', 'name', 'version') if k in op} for op in records]
    if normalized(ops_again) != normalized(ops):
        raise SetupError('APT resolution changed. Re-run and review the new plan.')
    # Preflight the state directory before any package changes.
    write_state(state)
    rc = 0
    if requested:
        cmd = ['sudo', 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get',
               '-o', 'DPkg::Lock::Timeout=120', '-o', 'Acquire::Retries=3',
               '-o', 'Dpkg::Options::=--force-confdef', '-o', 'Dpkg::Options::=--force-confold', '-y',
               *operation_args(a, requested)]
        try:
            rc = change_command(cmd)
        except KeyboardInterrupt:
            rc = 130
            say('Interrupted transaction: recording any completed direct installations.')
    after = installed()
    updated = json.loads(json.dumps(next_state))
    if a.uninstall:
        for name in requested:
            if lookup(after, name, arch) is None:
                updated['packages'].pop(name, None)
    else:
        for pkg, entry in chosen.items():
            actual = lookup(after, pkg, arch)
            old = lookup(before, pkg, arch)
            if not actual:
                continue
            record = updated['packages'].get(actual)
            # Claim only requested packages newly installed by this run, not
            # pre-existing packages or automatically selected dependencies.
            if record is None and old is None and pkg in pending:
                record = {'groups': [], 'introduced_utc': dt.datetime.now(dt.timezone.utc).isoformat()}
                updated['packages'][actual] = record
            if record is not None:
                record['groups'] = sorted(set(record['groups']) | set(entry['groups']))
    write_state(updated)
    if rc == 0 and a.dialout:
        if run(['getent', 'group', 'dialout'], check=False).returncode:
            raise SetupError('Packages completed, but dialout group is absent; no group was invented.')
        rc = change_command(['sudo', 'usermod', '-a', '-G', 'dialout', user])
    observed = fs_snapshot()
    say('\nOBSERVED FILESYSTEM SPACE AFTER APPLY')
    say(f'{"Path":29} {"Free before":>15} {"Free after":>15} {"Free change":>15}')
    for old, new in zip(snaps, observed):
        say(f'{new["path"][:29]:29} {human(old["free"]):>15} {human(new["free"]):>15} {human(new["free"] - old["free"], True):>15}')
    say('Observed change also includes concurrent activity and package-maintainer hooks.')
    say('Dependencies and user config were retained. No autoremove/apt -f/clean was run.')
    report.update(applied=True, apt_exit_code=rc, observed_after=observed)
    report_new(a.report, report)
    if rc:
        raise SetupError(f'APT or group change exited {rc}; partial direct installations were recorded. Review the log; no automatic repair attempted.')
    if a.dialout:
        say(f'Dialout membership updated for {user}. Log out and back in. It is NOT revoked by package uninstallation.')
    session_advice(wms)
    if missing:
        say(f'NOTE: {len(missing)} package(s) lacked candidates and were not installed: ' + ', '.join(missing))
    say('\nlx_post_install complete. No source build, firmware flash or kernel installation was requested.')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (SetupError, OSError, ValueError, KeyError) as exc:
        say(f'\nERROR: {exc}')
        sys.exit(1)
    except KeyboardInterrupt:
        say('\nInterrupted. Review APT/dpkg state if a transaction had started.')
        sys.exit(130)

LX_PYTHON
