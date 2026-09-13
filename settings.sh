#!/usr/bin/env bash
# Source this file from Bash: source /path/to/lx-scripts/settings.sh
# Layout: settings.sh and scripts/ are in the same directory.

# Use a POSIX-compatible test before any Bash-specific syntax.
if [ -z "${BASH_VERSION:-}" ]; then
    printf 'ERROR: settings.sh must be sourced from Bash.\n' >&2
    return 1 2>/dev/null || exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'ERROR: Use "source ./settings.sh", not "./settings.sh".\n' >&2
    exit 1
fi

_lx_settings_setup() {
    local source_file="${BASH_SOURCE[0]}"
    local source_dir root scripts file rest entry new_path
    local count=0

    # Locate this file without depending on the current working directory.
    case "$source_file" in
        */*) source_dir="${source_file%/*}" ;;
        *)   source_dir="." ;;
    esac

    if ! root="$(CDPATH= builtin cd -- "$source_dir" && builtin pwd -P)"; then
        printf 'ERROR: Cannot determine the lx-scripts directory.\n' >&2
        return 1
    fi

    scripts="${root%/}/scripts"
    if [[ ! -d "$scripts" || ! -r "$scripts" || ! -x "$scripts" ]]; then
        printf 'ERROR: Scripts directory is missing or inaccessible: %s\n' "$scripts" >&2
        return 1
    fi

    if [[ "$scripts" == *:* ]]; then
        printf 'ERROR: A PATH directory cannot contain a colon: %s\n' "$scripts" >&2
        return 1
    fi

    # Make every .sh file directly inside scripts/ executable.
    # Grant owner read/execute permission without changing other permissions.
    for file in "$scripts"/*.sh; do
        [[ -f "$file" ]] || continue

        if [[ ! -r "$file" || ! -x "$file" ]]; then
            if ! command -p chmod u+rx -- "$file"; then
                printf 'ERROR: Cannot make executable: %s\n' "$file" >&2
                printf 'Check file ownership and filesystem permissions.\n' >&2
                return 1
            fi
        fi

        if [[ ! -r "$file" || ! -x "$file" ]]; then
            printf 'ERROR: Script is still unreadable or non-executable: %s\n' "$file" >&2
            printf 'Check permissions, ACLs, and filesystem mount options.\n' >&2
            return 1
        fi
        count=$((count + 1))
    done

    if (( count == 0 )); then
        printf 'ERROR: No .sh files found in %s\n' "$scripts" >&2
        return 1
    fi

    # Put scripts/ first. Remove old copies, empty entries, and ./ entries.
    # Preserve the order of all other PATH entries.
    new_path="$scripts"
    rest="${PATH:-}:"
    while [[ "$rest" == *:* ]]; do
        entry="${rest%%:*}"
        rest="${rest#*:}"
        [[ -z "$entry" || "$entry" =~ ^\./*$ ]] && continue
        [[ "${entry%/}" == "$scripts" ]] && continue
        new_path+=":${entry}"
    done

    export LX_SCRIPT_LOC="$root"
    export LX_SCRIPTS_DIR="$scripts"
    export PATH="$new_path"
    hash -r

    printf 'LX Scripts environment set to %s\n' "$LX_SCRIPT_LOC"
    printf 'Added to PATH: %s\n' "$LX_SCRIPTS_DIR"
    printf 'Ready: %d executable .sh scripts\n' "$count"
}

# Keep temporary variables local and remove the helper function afterward.
if _lx_settings_setup; then
    unset -f _lx_settings_setup
    return 0
else
    unset -f _lx_settings_setup
    return 1
fi