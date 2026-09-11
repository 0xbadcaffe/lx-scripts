#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/src/yocto-distros"
ID=""
MACHINE=""
DISTRO_NAME=""
PROJECT=""
BUILD_DIR=""
BRANCH=""
MANIFEST=""
SYNC=0
APPLY=0
LIST=0
JOBS=8

usage() {
cat <<'EOF'
Usage:
  init-yocto-world.sh --list
  init-yocto-world.sh --id NAME [options]

Default: validate and print the initialization command.
Use --sync to repo-init/repo-sync manifest workspaces.
Use --apply to enter an initialized interactive child shell.

Options:
  --id NAME
  --root DIR
  --machine MACHINE
  --distro DISTRO
  --project PROJECT
  --build-dir DIR
  --branch BRANCH
  --manifest FILE
  --sync
  --apply
  -j, --jobs N
  -h, --help

Exit codes:
  2 missing prerequisite
  3 missing/incomplete source
  4 manifest cloned but full workspace not synced
  5 external vendor SDK/package required
  6 layer-only repository; no standalone init
  7 missing/invalid argument
EOF
}

while (($#)); do
  case "$1" in
    --list) LIST=1; shift ;;
    --id) ID="${2:?}"; shift 2 ;;
    --root) ROOT="${2:?}"; shift 2 ;;
    --machine) MACHINE="${2:?}"; shift 2 ;;
    --distro) DISTRO_NAME="${2:?}"; shift 2 ;;
    --project) PROJECT="${2:?}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
    --branch) BRANCH="${2:?}"; shift 2 ;;
    --manifest) MANIFEST="${2:?}"; shift 2 ;;
    --sync) SYNC=1; shift ;;
    --apply) APPLY=1; shift ;;
    -j|--jobs) JOBS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 7 ;;
  esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --jobs" >&2; exit 7; }

CATALOG=$(cat <<'EOF'
poky|standalone|Yocto Project reference distribution
openbmc|standalone|OpenBMC
yoe|standalone|Yoe Distro
openstlinux|manifest|ST OpenSTLinux
openstlinux-layer|layer|ST OpenSTLinux layer
petalinux-manifest|sdk|AMD/Xilinx PetaLinux public manifests
petalinux-layer|layer|AMD/Xilinx PetaLinux layer
xilinx|layer|AMD/Xilinx BSP layers
xilinx-tools|layer|AMD/Xilinx tools layer
nxp-imx|manifest|NXP i.MX BSP
nxp-meta-imx|layer|NXP i.MX layer
ti-arago|vendor|TI Arago layer
ti-sdk|vendor|TI Processor SDK layer
ti-meta|layer|TI BSP layer
kontron-smarc|standalone|Kontron SMARC workspace
kontron-smarc-layer|layer|Kontron SMARC layer
enclustra-amd|layer|Enclustra AMD/Xilinx layer
enclustra-socfpga|layer|Enclustra Intel SoC FPGA layer
enclustra-mpfs|layer|Enclustra PolarFire layer
analog-adi|layer|Analog Devices meta-adi layer
analog-lnxdsp|manifest|Analog Devices SC5xx workspace
renesas-rz|layer|Renesas RZ layer
variscite|manifest|Variscite BSP
raspberrypi|layer|Raspberry Pi BSP layer
beagleboard|layer|BeagleBoard BSP layer
meta-openembedded|layer|OpenEmbedded community layers
meta-arm|layer|Arm layers
meta-virtualization|layer|Virtualization layer
meta-security|layer|Security layers
meta-clang|layer|Clang/LLVM layer
meta-qt6|layer|Qt6 layer
EOF
)

if ((LIST)); then
  printf '%-23s %-11s %s\n' ID TYPE DESCRIPTION
  while IFS='|' read -r a b c; do printf '%-23s %-11s %s\n' "$a" "$b" "$c"; done <<<"$CATALOG"
  exit 0
fi

[[ -n "$ID" ]] || { echo "ERROR: --id required; use --list." >&2; exit 7; }
line="$(awk -F'|' -v id="$ID" '$1==id{print;exit}' <<<"$CATALOG")"
[[ -n "$line" ]] || { echo "ERROR: unknown ID '$ID'." >&2; exit 7; }
IFS='|' read -r _ TYPE DESC <<<"$line"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing prerequisite '$1'." >&2; exit 2; }; }
need_common() { for x in bash git python3 file; do need_cmd "$x"; done; }
need_src() {
  [[ -d "$1" ]] || { echo "ERROR: no source code found for '$ID'."; echo "Expected: $1"; echo "$2"; exit 3; }
}
need_file() {
  [[ -f "$1" ]] || { echo "ERROR: incomplete source tree for '$ID'."; echo "Missing: $1"; echo "$2"; exit 3; }
}
need_arg() {
  [[ -n "$1" ]] || { echo "ERROR: $2 required for '$ID'." >&2; echo "$3" >&2; exit 7; }
}
layer_error() {
  echo "ERROR: '$ID' is a layer, not a standalone build environment." >&2
  echo "Use it from: $1" >&2
  exit 6
}
sdk_error() {
  echo "ERROR: '$ID' requires vendor content outside the public Git repository." >&2
  printf '%s\n' "$1" >&2
  exit 5
}
q(){ printf '%q' "$1"; }

launch() {
  local wd="$1" cmd="$2"
  echo "Workspace: $wd"
  echo "Init command:"
  echo "  $cmd"
  if ((!APPLY)); then
    echo "CHECK PASSED. Nothing sourced. Add --apply to enter an initialized shell."
    exit 0
  fi
  echo "Entering initialized child shell. Type 'exit' to return."
  exec bash --noprofile --norc -c "cd $(q "$wd"); set -e; $cmd; exec bash -i"
}

sync_repo() {
  local url="$1" ws="$2" default_manifest="${3:-}"
  need_cmd repo
  if [[ ! -d "$ws/.repo" ]]; then
    if ((!SYNC)); then
      echo "ERROR: manifest repository exists but full source code is not synced." >&2
      echo "Expected workspace: $ws" >&2
      echo "Re-run with --sync." >&2
      exit 4
    fi
    mkdir -p "$ws"
    args=(repo init -u "$url")
    [[ -n "$BRANCH" ]] && args+=(-b "$BRANCH")
    if [[ -n "$MANIFEST" ]]; then args+=(-m "$MANIFEST")
    elif [[ -n "$default_manifest" ]]; then args+=(-m "$default_manifest")
    fi
    (cd "$ws" && "${args[@]}")
  fi
  ((SYNC)) && (cd "$ws" && repo sync -j"$JOBS")
}

need_common

case "$ID" in
  poky)
    src="$ROOT/poky"; need_src "$src" "Clone poky first."
    need_file "$src/oe-init-build-env" "Not a complete Poky checkout."
    build="${BUILD_DIR:-$ROOT/build-poky}"
    launch "$src" "source $(q "$src/oe-init-build-env") $(q "$build")"
    ;;
  openbmc)
    src="$ROOT/openbmc"; need_src "$src" "Clone openbmc first."
    need_file "$src/setup" "OpenBMC setup script missing."
    need_arg "$MACHINE" "--machine" "Example: --machine romulus"
    build="${BUILD_DIR:-$ROOT/build-openbmc-$MACHINE}"
    launch "$src" "source $(q "$src/setup") $(q "$MACHINE") $(q "$build")"
    ;;
  yoe)
    need_cmd docker
    src="$ROOT/yoe"; need_src "$src" "Clone yoe first."
    need_file "$src/envsetup.sh" "Yoe envsetup.sh missing."
    need_arg "$PROJECT" "--project" "Example: --project rpi4-64"
    launch "$src" "source ./envsetup.sh $(q "$PROJECT"); yoe_setup"
    ;;
  openstlinux)
    need_cmd repo
    need_src "$ROOT/openstlinux" "Clone the ST oe-manifest first."
    ws="$ROOT/workspaces/openstlinux"
    sync_repo "https://github.com/STMicroelectronics/oe-manifest.git" "$ws"
    need_file "$ws/layers/meta-st/scripts/envsetup.sh" "OpenSTLinux source sync is incomplete."
    need_arg "$MACHINE" "--machine" "Example: --machine stm32mp25-disco"
    distro="${DISTRO_NAME:-openstlinux-weston}"
    launch "$ws" "export MACHINE=$(q "$MACHINE") DISTRO=$(q "$distro"); source layers/meta-st/scripts/envsetup.sh"
    ;;
  nxp-imx)
    need_cmd repo
    need_src "$ROOT/nxp-imx" "Clone imx-manifest first."
    ws="$ROOT/workspaces/nxp-imx"
    if ((SYNC)) && [[ ! -d "$ws/.repo" ]]; then
      need_arg "$BRANCH" "--branch" "Example: --branch imx-linux-wrynose"
      need_arg "$MANIFEST" "--manifest" "Use the exact release XML from NXP."
    fi
    sync_repo "https://github.com/nxp-imx/imx-manifest.git" "$ws"
    need_file "$ws/imx-setup-release.sh" "NXP source sync is incomplete."
    need_arg "$MACHINE" "--machine" "Example: --machine imx95evk"
    need_arg "$DISTRO_NAME" "--distro" "Example: --distro fsl-imx-xwayland"
    build="${BUILD_DIR:-build-$MACHINE}"
    launch "$ws" "export MACHINE=$(q "$MACHINE") DISTRO=$(q "$DISTRO_NAME"); source ./imx-setup-release.sh -b $(q "$build")"
    ;;
  analog-lnxdsp)
    need_cmd repo
    need_src "$ROOT/analog-lnxdsp" "Clone lnxdsp-repo-manifest first."
    ws="$ROOT/workspaces/analog-lnxdsp"
    [[ -n "$MANIFEST" ]] || MANIFEST="main.xml"
    sync_repo "https://github.com/analogdevicesinc/lnxdsp-repo-manifest.git" "$ws" "main.xml"
    need_file "$ws/setup-environment" "ADI source sync is incomplete."
    need_arg "$MACHINE" "--machine" "Example: --machine adsp-sc598-som-ezkit"
    launch "$ws" "source ./setup-environment -m $(q "$MACHINE")"
    ;;
  variscite)
    need_cmd repo
    need_src "$ROOT/variscite" "Clone variscite-bsp-platform first."
    ws="$ROOT/workspaces/variscite"
    if ((SYNC)) && [[ ! -d "$ws/.repo" ]]; then
      need_arg "$BRANCH" "--branch" "Use the exact Variscite release branch."
    fi
    sync_repo "https://github.com/varigit/variscite-bsp-platform.git" "$ws"
    need_file "$ws/setup-environment" "Variscite source sync is incomplete."
    need_arg "$MACHINE" "--machine" "Use a machine from the selected release."
    need_arg "$DISTRO_NAME" "--distro" "Use the distro from the selected release docs."
    build="${BUILD_DIR:-build-$MACHINE}"
    launch "$ws" "export MACHINE=$(q "$MACHINE") DISTRO=$(q "$DISTRO_NAME"); source ./setup-environment $(q "$build")"
    ;;
  kontron-smarc)
    src="$ROOT/kontron-smarc"; need_src "$src" "Clone kontron-smarc first."
    if [[ -f "$src/oe-init-build-env" ]]; then
      build="${BUILD_DIR:-$ROOT/build-kontron-smarc}"
      launch "$src" "source ./oe-init-build-env $(q "$build")"
    elif [[ -f "$src/setup-environment" ]]; then
      build="${BUILD_DIR:-build}"
      launch "$src" "source ./setup-environment $(q "$build")"
    elif [[ -f "$src/envsetup.sh" ]]; then
      launch "$src" "source ./envsetup.sh"
    else
      echo "ERROR: source exists but no recognized Kontron init script was found." >&2
      echo "Read the README for this checked-out release." >&2
      exit 3
    fi
    ;;
  petalinux-manifest)
    sdk_error "PetaLinux itself is a vendor SDK/installer and is not reproduced by the public GitHub manifests/layers.
Download the matching release from:
https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/embedded-software/petalinux-sdk.html"
    ;;
  ti-arago|ti-sdk)
    sdk_error "The cloned TI repositories are integration layers, not a complete Processor SDK Linux workspace.
Use the matching TI Processor SDK Linux release:
https://www.ti.com/tool/PROCESSOR-SDK-LINUX"
    ;;
  openstlinux-layer) layer_error "openstlinux" ;;
  nxp-meta-imx) layer_error "nxp-imx" ;;
  petalinux-layer|xilinx|xilinx-tools) layer_error "an AMD/Xilinx Yocto workspace or installed PetaLinux SDK" ;;
  ti-meta) layer_error "a TI Processor SDK / Arago workspace" ;;
  kontron-smarc-layer) layer_error "kontron-smarc" ;;
  enclustra-amd) layer_error "a compatible AMD/Xilinx Yocto workspace" ;;
  enclustra-socfpga) layer_error "a compatible Intel SoC FPGA Yocto workspace" ;;
  enclustra-mpfs) layer_error "a compatible PolarFire SoC Yocto workspace" ;;
  analog-adi) layer_error "a compatible Poky/OE workspace; use analog-lnxdsp for SC5xx" ;;
  renesas-rz) layer_error "a compatible Renesas RZ release workspace" ;;
  raspberrypi|beagleboard|meta-openembedded|meta-arm|meta-virtualization|meta-security|meta-clang|meta-qt6)
    layer_error "Poky or another compatible OpenEmbedded workspace"
    ;;
esac
