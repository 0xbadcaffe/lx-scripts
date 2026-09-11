#!/usr/bin/env bash
# Generic Debian bootstrap for Git + GitHub.
# Run as your normal user, not with sudo.
set -Eeuo pipefail

GITHUB_USER=""
GIT_NAME=""
CLONE_DIR="${HOME}/src/github"
GIT_EMAIL=""
PROTOCOL="ssh"
CREATE_SSH_KEY=1
DRY_RUN=0
UPDATE_EXISTING=1
INCLUDE_ARCHIVED=1
INCLUDE_FORKS=1

usage() {
    cat <<'EOF'
Usage:
  ./setup-git-github-debian.sh [options]

Options:
  --name NAME            Set git user.name.
  --email EMAIL           Set git user.email.
  --github-user USER      GitHub account whose repositories will be cloned.
  --clone-dir DIR         Clone repositories here (default: ~/src/github).
  --https                Clone using HTTPS instead of SSH.
  --no-ssh-key           Do not create/upload an SSH key.
  --no-update-existing   Do not pull existing repositories.
  --skip-archived        Skip archived repositories.
  --skip-forks           Skip forked repositories.
  --dry-run              Print planned actions only.
  -h, --help             Show this help.

Examples:
  ./setup-git-github-debian.sh
  ./setup-git-github-debian.sh \
      --name "Roy Cohen" \
      --email "roy@0xbadcaffe.dev" \
      --github-user 0xbadcaffe
  ./setup-git-github-debian.sh --clone-dir ~/projects
  ./setup-git-github-debian.sh --dry-run
EOF
}

while (($#)); do
    case "$1" in
        --name) GIT_NAME="${2:?--name requires a value}"; shift 2 ;;
        --email) GIT_EMAIL="${2:?--email requires a value}"; shift 2 ;;
        --github-user) GITHUB_USER="${2:?--github-user requires a value}"; shift 2 ;;
        --clone-dir) CLONE_DIR="${2:?--clone-dir requires a value}"; shift 2 ;;
        --https) PROTOCOL="https"; shift ;;
        --no-ssh-key) CREATE_SSH_KEY=0; shift ;;
        --no-update-existing) UPDATE_EXISTING=0; shift ;;
        --skip-archived) INCLUDE_ARCHIVED=0; shift ;;
        --skip-forks) INCLUDE_FORKS=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ ${EUID} -eq 0 ]]; then
    echo "Run this script as your normal user, not with sudo." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Cannot identify Linux distribution." >&2
    exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "debian" ]]; then
    echo "This script targets Debian. Detected: ${PRETTY_NAME:-unknown}" >&2
    exit 1
fi

run() {
    if ((DRY_RUN)); then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

if [[ -z "${GIT_NAME}" ]]; then
    if ((DRY_RUN)); then
        GIT_NAME="<YOUR NAME>"
        echo "[dry-run] would ask for Git name"
    else
        default_name="$(git config --global --get user.name 2>/dev/null || true)"
        read -r -p "Git name${default_name:+ [$default_name]}: " entered
        GIT_NAME="${entered:-$default_name}"
        while [[ -z "${GIT_NAME}" ]]; do
            read -r -p "Git name: " GIT_NAME
        done
    fi
fi

if [[ -z "${GITHUB_USER}" ]]; then
    if ((DRY_RUN)); then
        GITHUB_USER="<GITHUB USER>"
        echo "[dry-run] would ask for GitHub username"
    else
        default_gh=""
        if command -v gh >/dev/null 2>&1; then
            default_gh="$(gh api user --jq '.login' 2>/dev/null || true)"
        fi
        read -r -p "GitHub username${default_gh:+ [$default_gh]}: " entered
        GITHUB_USER="${entered:-$default_gh}"
        while [[ -z "${GITHUB_USER}" ]]; do
            read -r -p "GitHub username: " GITHUB_USER
        done
    fi
fi

echo "GitHub account : ${GITHUB_USER}"
echo "Git name       : ${GIT_NAME}"
echo "Clone root     : ${CLONE_DIR}"
echo "Protocol       : ${PROTOCOL}"
echo

packages=(git git-lfs gh openssh-client ca-certificates curl jq)

echo "==> Installing prerequisites"
if ((DRY_RUN)); then
    echo "[dry-run] sudo apt-get update"
    printf '[dry-run] sudo apt-get install -y --no-install-recommends'
    printf ' %q' "${packages[@]}"
    printf '\n'
else
    command -v sudo >/dev/null 2>&1 || { echo "sudo is required." >&2; exit 1; }
    sudo -v
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${packages[@]}"
fi

echo
echo "==> Configuring Git"
if [[ -z "${GIT_EMAIL}" ]]; then
    if ((DRY_RUN)); then
        GIT_EMAIL="<YOUR_GITHUB_EMAIL>"
        echo "[dry-run] would ask for Git/GitHub email"
    else
        current_email="$(git config --global --get user.email 2>/dev/null || true)"
        if [[ -n "${current_email}" ]]; then
            read -r -p "Git email [${current_email}]: " entered
            GIT_EMAIL="${entered:-$current_email}"
        else
            while [[ -z "${GIT_EMAIL}" ]]; do
                read -r -p "Git/GitHub email: " GIT_EMAIL
            done
        fi
    fi
fi

run git config --global user.name "${GIT_NAME}"
run git config --global user.email "${GIT_EMAIL}"
run git config --global init.defaultBranch main
run git config --global pull.ff only
run git config --global fetch.prune true
run git config --global rebase.autoStash true
run git config --global core.autocrlf input
run git config --global color.ui auto
run git config --global rerere.enabled true
run git lfs install

SSH_KEY="${HOME}/.ssh/id_ed25519_github"

if [[ "${PROTOCOL}" == "ssh" && ${CREATE_SSH_KEY} -eq 1 ]]; then
    echo
    echo "==> Preparing SSH key"
    run mkdir -p "${HOME}/.ssh"
    if (( ! DRY_RUN )); then chmod 700 "${HOME}/.ssh"; fi

    if [[ ! -f "${SSH_KEY}" && ! -f "${SSH_KEY}.pub" ]]; then
        run ssh-keygen -t ed25519 -a 100 -C "${GIT_EMAIL}" -f "${SSH_KEY}"
    else
        echo "Using existing key: ${SSH_KEY}"
    fi

    SSH_CONFIG="${HOME}/.ssh/config"
    if ((DRY_RUN)); then
        echo "[dry-run] ensure github.com entry exists in ${SSH_CONFIG}"
    elif ! grep -Eq '^[[:space:]]*Host[[:space:]]+github\.com([[:space:]]|$)' "${SSH_CONFIG}" 2>/dev/null; then
        cat >> "${SSH_CONFIG}" <<'EOF'

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
EOF
        chmod 600 "${SSH_CONFIG}"
    fi

    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        if ((DRY_RUN)); then
            echo "[dry-run] start ssh-agent"
        else
            eval "$(ssh-agent -s)" >/dev/null
        fi
    fi
    run ssh-add "${SSH_KEY}"
fi

echo
echo "==> Checking GitHub CLI authentication"
if ((DRY_RUN)); then
    echo "[dry-run] gh auth status -h github.com"
    echo "[dry-run] if needed: gh auth login -h github.com -p ${PROTOCOL}"
else
    if ! gh auth status -h github.com >/dev/null 2>&1; then
        echo "GitHub authentication is required."
        gh auth login -h github.com -p "${PROTOCOL}"
    fi

    authenticated_user="$(gh api user --jq '.login')"
    if [[ "${authenticated_user,,}" != "${GITHUB_USER,,}" ]]; then
        echo "Authenticated as '${authenticated_user}', expected '${GITHUB_USER}'." >&2
        echo "Use 'gh auth switch' or re-login with the correct account." >&2
        exit 1
    fi

    if [[ "${PROTOCOL}" == "ssh" && ${CREATE_SSH_KEY} -eq 1 ]]; then
        pubkey="$(cat "${SSH_KEY}.pub")"
        key_material="$(awk '{print $2}' <<<"${pubkey}")"
        if ! gh ssh-key list 2>/dev/null | grep -Fq "${key_material}"; then
            key_title="$(hostname)-$(date +%Y-%m-%d)"
            gh ssh-key add "${SSH_KEY}.pub" --title "${key_title}"
        else
            echo "SSH key is already registered on GitHub."
        fi
    fi

    gh config set git_protocol "${PROTOCOL}" -h github.com
    gh auth setup-git
fi

echo
echo "==> Synchronizing repositories"
run mkdir -p "${CLONE_DIR}"

if ((DRY_RUN)); then
    echo "[dry-run] enumerate all repositories owned by ${GITHUB_USER}"
    echo "[dry-run] clone missing repositories into ${CLONE_DIR}"
    ((UPDATE_EXISTING)) && echo "[dry-run] pull clean existing repositories with --ff-only"
    exit 0
fi

tmp_json="$(mktemp)"
trap 'rm -f "${tmp_json}"' EXIT

gh repo list "${GITHUB_USER}" \
    --limit 1000 \
    --json name,nameWithOwner,sshUrl,url,isArchived,isFork \
    > "${tmp_json}"

repo_count="$(jq 'length' "${tmp_json}")"
echo "Found ${repo_count} repositories."

cloned=0
updated=0
skipped=0
failed=0

while IFS=$'\t' read -r name full_name ssh_url https_url archived fork; do
    [[ -n "${name}" ]] || continue

    if [[ "${archived}" == "true" && ${INCLUDE_ARCHIVED} -eq 0 ]]; then
        echo "SKIP archived: ${full_name}"
        ((skipped+=1))
        continue
    fi
    if [[ "${fork}" == "true" && ${INCLUDE_FORKS} -eq 0 ]]; then
        echo "SKIP fork: ${full_name}"
        ((skipped+=1))
        continue
    fi

    destination="${CLONE_DIR}/${name}"
    [[ "${PROTOCOL}" == "ssh" ]] && clone_url="${ssh_url}" || clone_url="${https_url}"

    if [[ ! -e "${destination}" ]]; then
        echo "CLONE ${full_name}"
        if git clone --recurse-submodules "${clone_url}" "${destination}"; then
            ((cloned+=1))
        else
            echo "FAILED clone: ${full_name}" >&2
            ((failed+=1))
        fi
        continue
    fi

    if [[ ! -d "${destination}/.git" ]]; then
        echo "SKIP ${destination}: exists but is not a Git repository." >&2
        ((skipped+=1))
        continue
    fi

    if (( ! UPDATE_EXISTING )); then
        echo "EXISTS ${full_name}"
        ((skipped+=1))
        continue
    fi

    if [[ -n "$(git -C "${destination}" status --porcelain)" ]]; then
        echo "SKIP dirty repository: ${full_name}"
        ((skipped+=1))
        continue
    fi

    echo "UPDATE ${full_name}"
    if git -C "${destination}" fetch --all --prune &&
       git -C "${destination}" pull --ff-only &&
       git -C "${destination}" submodule update --init --recursive; then
        ((updated+=1))
    else
        echo "FAILED update: ${full_name}" >&2
        ((failed+=1))
    fi
done < <(
    jq -r '.[] | [
        .name,
        .nameWithOwner,
        .sshUrl,
        .url,
        (.isArchived|tostring),
        (.isFork|tostring)
    ] | @tsv' "${tmp_json}"
)

echo
echo "=============================================="
echo " Git/GitHub setup complete"
echo "=============================================="
echo "GitHub user : ${GITHUB_USER}"
echo "Git identity: ${GIT_NAME} <${GIT_EMAIL}>"
echo "Clone root  : ${CLONE_DIR}"
echo "Protocol    : ${PROTOCOL}"
printf 'Cloned      : %d\n' "${cloned}"
printf 'Updated     : %d\n' "${updated}"
printf 'Skipped     : %d\n' "${skipped}"
printf 'Failed      : %d\n' "${failed}"

echo
git config --global --get-regexp '^(user\.|init\.defaultBranch|pull\.ff|fetch\.prune|rerere\.)' || true
echo
gh auth status -h github.com || true

(( failed == 0 )) || exit 2
