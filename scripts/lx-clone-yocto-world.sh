#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${HOME}/src/yocto-distros"
APPLY=0
UPDATE=0
SHALLOW=0
ONLY=""
LIST=0

usage() {
    echo "Usage: $0 [--list] [--only id,id] [--root DIR] [--apply] [--update] [--shallow]"
}
fail() { echo "ERROR: $*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --only|--root)
            [[ $# -ge 2 && -n $2 && $2 != -* ]] || fail "$1 requires a value."
            case "$1" in --only) ONLY=$2 ;; --root) ROOT=$2 ;; esac
            shift 2 ;;
        --list) LIST=1; shift ;;
        --apply) APPLY=1; shift ;;
        --update) UPDATE=1; shift ;;
        --shallow) SHALLOW=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
CATALOG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/data/yocto-repositories.txt"
# Validate the entire selection before creating directories or cloning anything.
if [[ -n $ONLY ]]; then
    [[ $ONLY != ,* && $ONLY != *, && $ONLY != *,,* ]] || fail 'Empty ID in --only.'
    IFS=',' read -r -a requested <<< "$ONLY"
    for id in "${requested[@]}"; do
        awk -F'|' -v id="$id" '$1 == id { found=1 } END { exit !found }' "$CATALOG" ||
            fail "Unknown ID: $id (use --list)."
    done
fi
selected() { [[ -z $ONLY || ",$ONLY," == *",$1,"* ]]; }
printf '%-22s %-10s %s\n' ID TYPE DESCRIPTION
while IFS='|' read -r id typ desc _; do
    if selected "$id"; then printf '%-22s %-10s %s\n' "$id" "$typ" "$desc"; fi
done < "$CATALOG"
((LIST)) && exit 0
if ((!APPLY)); then
    printf '\nPLAN ONLY. Destination: %s\nUse --apply to clone.\n' "$ROOT"
    exit 0
fi
command -v git >/dev/null || fail 'git required'
mkdir -p -- "$ROOT"
clone_args=(clone --recurse-submodules)
if ((SHALLOW)); then clone_args+=(--depth 1 --shallow-submodules); fi
while IFS='|' read -r id _ _ url _; do
    selected "$id" || continue
    dst="$ROOT/$id"
    if [[ -d "$dst/.git" || -f "$dst/.git" ]]; then
        echo "EXISTS $id"
        if ((UPDATE)); then
            if [[ -n $(git -C "$dst" status --porcelain) ]]; then
                echo "SKIP dirty: $id"
            else
                git -C "$dst" fetch --all --prune
                git -C "$dst" pull --ff-only
                git -C "$dst" submodule update --init --recursive
            fi
        fi
    elif [[ -e "$dst" ]]; then
        echo "SKIP path exists: $dst" >&2
    else
        echo "CLONE $id"
        git "${clone_args[@]}" -- "$url" "$dst"
    fi
done < "$CATALOG"
echo
echo "Cloned catalog into: $ROOT"
echo "Manifest repos are cloned as manifests only; use each vendor's documented repo init/sync for a release."
echo "PetaLinux itself is a proprietary AMD/Xilinx SDK; this clones its public Yocto manifests/layers, not the SDK."
echo "These projects span different Yocto releases. Do not combine layers without checking compatibility."
