#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${HOME}/src/yocto-distros"; APPLY=0; UPDATE=0; SHALLOW=0; ONLY=""
usage(){ echo "Usage: $0 [--list] [--only id,id] [--root DIR] [--apply] [--update] [--shallow]"; }
LIST=0
while (($#)); do case "$1" in
 --list) LIST=1; shift;; --only) ONLY="$2"; shift 2;; --root) ROOT="$2"; shift 2;;
 --apply) APPLY=1; shift;; --update) UPDATE=1; shift;; --shallow) SHALLOW=1; shift;;
 -h|--help) usage; exit 0;; *) echo "Unknown: $1" >&2; exit 1;; esac; done
CATALOG=$(cat <<'EOF'
poky|distro|Yocto Project reference distribution|https://git.yoctoproject.org/poky
openbmc|distro|OpenBMC|https://github.com/openbmc/openbmc.git
yoe|distro|Yoe Embedded Linux|https://github.com/YoeDistro/yoe-distro.git
openstlinux|manifest|ST OpenSTLinux manifest|https://github.com/STMicroelectronics/oe-manifest.git
openstlinux-layer|layer|ST OpenSTLinux distro layer|https://github.com/STMicroelectronics/meta-st-openstlinux.git
petalinux-manifest|manifest|AMD/Xilinx Yocto manifests|https://github.com/Xilinx/yocto-manifests.git
petalinux-layer|layer|AMD/Xilinx PetaLinux distro layer|https://github.com/Xilinx/meta-petalinux.git
xilinx|layer|AMD/Xilinx BSP layers|https://github.com/Xilinx/meta-xilinx.git
xilinx-tools|layer|AMD/Xilinx tools layer|https://github.com/Xilinx/meta-xilinx-tools.git
nxp-imx|manifest|NXP i.MX BSP manifest|https://github.com/nxp-imx/imx-manifest.git
nxp-meta-imx|layer|NXP i.MX BSP layer|https://github.com/nxp-imx/meta-imx.git
ti-arago|layer|TI Arago distribution|https://github.com/TexasInstruments/meta-arago.git
ti-sdk|layer|TI Processor SDK layer|https://github.com/TexasInstruments/meta-tisdk.git
ti-meta|layer|TI BSP layer|https://git.yoctoproject.org/meta-ti
kontron-smarc|distro|Kontron SMARC SAM67 workspace|https://github.com/kontron/yocto-smarc-sam67.git
kontron-smarc-layer|layer|Kontron SMARC SAM67 layer|https://github.com/kontron/meta-smarc-sam67.git
enclustra-amd|layer|Enclustra AMD/Zynq BSP|https://github.com/enclustra/meta-enclustra-amd.git
enclustra-socfpga|layer|Enclustra Intel SoC FPGA BSP|https://github.com/enclustra/meta-enclustra-socfpga.git
enclustra-mpfs|layer|Enclustra PolarFire SoC BSP|https://github.com/enclustra/meta-enclustra-mpfs.git
analog-adi|layer|Analog Devices BSP layers|https://github.com/analogdevicesinc/meta-adi.git
analog-lnxdsp|manifest|Analog Devices SC5xx manifest|https://github.com/analogdevicesinc/lnxdsp-repo-manifest.git
renesas-rz|layer|Renesas RZ BSP|https://github.com/renesas-rz/meta-renesas.git
variscite|manifest|Variscite BSP manifest|https://github.com/varigit/variscite-bsp-platform.git
raspberrypi|layer|Raspberry Pi BSP|https://github.com/agherzan/meta-raspberrypi.git
beagleboard|layer|BeagleBoard BSP|https://github.com/beagleboard/meta-beagleboard.git
meta-openembedded|layer|OpenEmbedded community layers|https://github.com/openembedded/meta-openembedded.git
meta-arm|layer|Arm Yocto/OE layers|https://git.yoctoproject.org/meta-arm
meta-virtualization|layer|Virtualization/container layer|https://git.yoctoproject.org/meta-virtualization
meta-security|layer|Security layers|https://git.yoctoproject.org/meta-security
meta-clang|layer|Clang/LLVM layer|https://github.com/kraj/meta-clang.git
meta-qt6|layer|Qt 6 layer|https://code.qt.io/yocto/meta-qt6.git
EOF
)
selected(){ [[ -z "$ONLY" ]] && return 0; [[ ",$ONLY," == *",$1,"* ]]; }
printf "%-22s %-10s %s\n" ID TYPE DESCRIPTION
while IFS='|' read -r id typ desc url; do selected "$id" && printf "%-22s %-10s %s\n" "$id" "$typ" "$desc"; done <<<"$CATALOG"
((LIST)) && exit 0
if ((!APPLY)); then echo; echo "PLAN ONLY. Destination: $ROOT"; echo "Use --apply to clone."; exit 0; fi
command -v git >/dev/null || { echo "git required" >&2; exit 1; }; mkdir -p "$ROOT"
while IFS='|' read -r id typ desc url; do
 selected "$id" || continue; dst="$ROOT/$id"
 if [[ -d "$dst/.git" ]]; then
   echo "EXISTS $id"
   if ((UPDATE)); then
     if [[ -n "$(git -C "$dst" status --porcelain)" ]]; then echo "SKIP dirty: $id"
     else git -C "$dst" fetch --all --prune; git -C "$dst" pull --ff-only || true; git -C "$dst" submodule update --init --recursive || true; fi
   fi
 elif [[ -e "$dst" ]]; then echo "SKIP path exists: $dst" >&2
 else
   echo "CLONE $id"
   args=(clone --recurse-submodules); ((SHALLOW)) && args+=(--depth 1 --shallow-submodules)
   git "${args[@]}" "$url" "$dst"
 fi
done <<<"$CATALOG"
echo
echo "Cloned catalog into: $ROOT"
echo "Manifest repos are cloned as manifests only; use each vendor's documented repo init/sync for a release."
echo "PetaLinux itself is a proprietary AMD/Xilinx SDK; this clones its public Yocto manifests/layers, not the SDK."
echo "These projects span different Yocto releases. Do not combine layers without checking compatibility."
