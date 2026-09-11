#!/usr/bin/env bash
# OpenPGP identity setup for Linux. Bash + GnuPG; no Python runtime required.
# Defaults to a preview. --apply creates a certification key plus signing and
# encryption subkeys. Passphrases go directly to GnuPG's Pinentry, never here.
# References: https://www.gnupg.org/documentation/manuals/gnupg/OpenPGP-Key-Management.html
#             https://docs.github.com/en/authentication/managing-commit-signature-verification/telling-git-about-your-signing-key
set -Eeuo pipefail
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'Execute this script; do not source it.\n' >&2
    return 2
fi
umask 077

NAME=''
EMAIL=''
ALGORITHM=ed25519
EXPIRES=2y
OUTPUT_ROOT="${HOME:?HOME must be set}/.local/share/openpgp"
GPG_HOME="${GNUPGHOME:-$HOME/.gnupg}"
APPLY=0
INSTALL_DEPS=0
GIT_SIGNING=0
ALLOW_EXISTING_EMAIL=0
WORK=''
FINGERPRINT=''
SIGN_FPR=''
ENCR_FPR=''
STAGE='argument validation'

usage() {
    cat <<'EOF'
Usage: create-gpg-key.sh [options]

Default: print a plan only. No key, directory, agent, or package is created.
Run as your normal user, not with sudo. Key creation requires a real terminal.

  --name NAME               OpenPGP display name; prompted with --apply if absent
  --email EMAIL             OpenPGP email; prompted with --apply if absent
  --algorithm ed25519       Ed25519 cert/sign + Curve25519 encryption (default)
  --algorithm rsa4096       RSA-4096 cert/sign/encryption for legacy requirements
  --expires TIME            Positive Nd/Nw/Nm/Ny, future YYYY-MM-DD, or never
                            Default: 2y, applied to primary key and both subkeys
  --output-dir DIR          Export root; default: ~/.local/share/openpgp
  --install-deps            With --apply, install Debian/Ubuntu prerequisites
  --git-signing             With --apply, enable global OpenPGP commit/tag signing
                            Does NOT change Git author name/email
  --allow-existing-email    Explicitly allow another key for an existing mailbox
                            Default is to refuse duplicate identities
  --apply                   Create the key after interactive CREATE confirmation
  --dry-run                 Explicit preview; mutually exclusive with --apply
  -h, --help                Show this help

Examples:
  ./create-gpg-key.sh --name "Roy Cohen" --email "roy@0xbadcaffe.dev"
  ./create-gpg-key.sh --apply --install-deps
  ./create-gpg-key.sh --name "Roy Cohen" --email "roy@0xbadcaffe.dev" \
      --git-signing --apply

Requirements: Linux, Bash 4.4+, GnuPG 2.2+, gpgconf, gpg-connect-agent,
Pinentry, util-linux flock, GNU coreutils, awk, grep. Git only for --git-signing.
GNUPGHOME is honored. --git-signing requires the normal ~/.gnupg keyring.
No keys are uploaded, no private keys exported, no shell/agent config rewritten.
Exit 0: preview or success; 1: operational error; 2: invalid input/precondition;
3: duplicate email; 130/143: interruption. Partial keys are NEVER deleted.
EOF
}

fail() { printf 'ERROR: %s\n' "$2" >&2; exit "$1"; }
value_arg() {
    [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail 2 "$1 requires a value."
}
no_controls() { [[ $1 != *[[:cntrl:]]* ]]; }
validate_name() {
    local v=$1
    [[ ${#v} -ge 1 && ${#v} -le 200 && $v == *[![:space:]]* ]] ||
        fail 2 'Name must be nonempty and at most 200 characters.'
    no_controls "$v" || fail 2 'Name contains a control character.'
    [[ $v != -* && $v != *'<'* && $v != *'>'* && $v != *'('* && $v != *')'* &&
       $v != ' '* && $v != *' ' ]] ||
        fail 2 'Use a plain name without angle brackets, parentheses or edge spaces.'
}
validate_email() {
    local v=$1
    # Deliberately a plain ASCII mailbox, not an exhaustive RFC email parser.
    # This is input validation, not proof that the address exists or is verified.
    local pattern='^[A-Za-z0-9._%+!-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
    [[ ${#v} -le 254 && $v =~ $pattern && $v != *'..'* ]] ||
        fail 2 'Email must be a plain ASCII mailbox such as name@example.com.'
}
validate_expiry() {
    local parsed
    if [[ $EXPIRES == never ]]; then
        return 0
    elif [[ $EXPIRES =~ ^[1-9][0-9]{0,4}[dwmy]$ ]]; then
        return 0
    elif [[ $EXPIRES =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        parsed=$(date -u -d "$EXPIRES" +%F 2>/dev/null) || fail 2 'Invalid expiry date.'
        [[ $parsed == "$EXPIRES" && $EXPIRES > $(date -u +%F) ]] ||
            fail 2 'The expiry date must be in the future (UTC).'
    else
        fail 2 'Expiry must be positive Nd/Nw/Nm/Ny, a future YYYY-MM-DD, or never.'
    fi
}
validate_path() {
    [[ $1 == /* && $1 != / && ${#1} -le 4096 ]] ||
        fail 2 'Key/export directories must be absolute paths other than /.'
    no_controls "$1" || fail 2 'Directory path contains a control character.'
}

DRY_RUN=0
while (($#)); do
    case "$1" in
        --name) value_arg "$@"; NAME=$2; shift 2 ;;
        --email) value_arg "$@"; EMAIL=$2; shift 2 ;;
        --algorithm) value_arg "$@"; ALGORITHM=$2; shift 2 ;;
        --expires) value_arg "$@"; EXPIRES=$2; shift 2 ;;
        --output-dir) value_arg "$@"; OUTPUT_ROOT=$2; shift 2 ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        --git-signing) GIT_SIGNING=1; shift ;;
        --allow-existing-email) ALLOW_EXISTING_EMAIL=1; shift ;;
        --apply) APPLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail 2 "Unknown option: $1. Use --help." ;;
    esac
done
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
    fail 2 'Bash 4.4 or newer is required.'
[[ $(uname -s) == Linux ]] || fail 2 'This script targets Linux.'
(( !(APPLY && DRY_RUN) )) || fail 2 'Use --apply or --dry-run, not both.'
[[ $ALGORITHM == ed25519 || $ALGORITHM == rsa4096 ]] ||
    fail 2 '--algorithm must be ed25519 or rsa4096.'
[[ -z $NAME ]] || validate_name "$NAME"
[[ -z $EMAIL ]] || validate_email "$EMAIL"
validate_expiry
validate_path "$GPG_HOME"
validate_path "$OUTPUT_ROOT"

PRIMARY_ALGO=$ALGORITHM
SIGN_ALGO=$ALGORITHM
ENCR_ALGO=cv25519
[[ $ALGORITHM != rsa4096 ]] || ENCR_ALGO=rsa4096
printf 'Name:             %s\nEmail:            %s\n' "${NAME:-[prompt on --apply]}" "${EMAIL:-[prompt on --apply]}"
printf 'Primary key:      %s / certify\nSigning subkey:   %s / sign\nEncryption subkey: %s / encrypt\n' \
    "$PRIMARY_ALGO" "$SIGN_ALGO" "$ENCR_ALGO"
printf 'Expiry:           %s\nKeyring:          %s\nPublic exports:   %s/<fingerprint>/\n' \
    "$EXPIRES" "$GPG_HOME" "$OUTPUT_ROOT"
printf 'Install packages: %s\nGlobal Git signing: %s\n' "$INSTALL_DEPS" "$GIT_SIGNING"
if (( ! APPLY )); then
    printf '\nPREVIEW ONLY. Nothing created, installed, uploaded or configured.\n'
    printf 'Use --apply to continue in an interactive terminal.\n'
    exit 0
fi

((EUID != 0)) || fail 2 'Run as your normal user, WITHOUT sudo.'
[[ -t 0 && -t 1 ]] || fail 2 'Key creation requires an interactive terminal for confirmation and Pinentry.'
for cmd in awk grep date stat realpath dirname mkdir mktemp rm cmp flock; do
    command -v "$cmd" >/dev/null || fail 2 "Missing required command: $cmd"
done

if ((INSTALL_DEPS)); then
    [[ -r /etc/os-release ]] || fail 2 'Cannot identify package manager.'
    # Read in a subshell: os-release defines NAME, which must NOT overwrite
    # the supplied OpenPGP display name.
    # shellcheck disable=SC1091
    os_id=$(source /etc/os-release; printf '%s' "${ID:-}")
    case "$os_id" in
        debian|ubuntu) ;;
        *) fail 2 '--install-deps supports Debian/Ubuntu only. Install GnuPG and Pinentry with your distribution package manager.' ;;
    esac
    command -v sudo >/dev/null || fail 2 'sudo is required for package installation.'
    printf '\nInstall gnupg, pinentry-curses, ca-certificates and util-linux from APT? [y/N]: '
    read -r answer
    [[ $answer == y || $answer == Y ]] || fail 2 'Installation cancelled; no key created.'
    pkgs=(gnupg pinentry-curses ca-certificates util-linux)
    (( ! GIT_SIGNING )) || pkgs+=(git)
    opts=(-o DPkg::Lock::Timeout=120 -o Acquire::Retries=3)
    sudo -v
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" \
        -o APT::Update::Error-Mode=any update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" \
        install -y --no-install-recommends --no-remove "${pkgs[@]}"
fi
for cmd in gpg gpgconf gpg-connect-agent; do
    command -v "$cmd" >/dev/null || fail 2 "Missing $cmd. Install gnupg and pinentry-curses first, or use --install-deps."
done
if ! command -v pinentry >/dev/null && ! command -v pinentry-curses >/dev/null &&
   ! command -v pinentry-tty >/dev/null; then
    fail 2 'Pinentry is missing. Install pinentry-curses (Debian/Ubuntu).'
fi
if ((GIT_SIGNING)); then
    command -v git >/dev/null || fail 2 'Git is required for --git-signing.'
    [[ $(realpath -m -- "$GPG_HOME") == $(realpath -m -- "$HOME/.gnupg") ]] ||
        fail 2 '--git-signing requires ~/.gnupg; a custom GNUPGHOME must be managed explicitly per project.'
fi
GPG_BIN=$(command -v gpg)
ver=$("$GPG_BIN" --no-options --version)
first=${ver%%$'\n'*}
if [[ $first =~ ([0-9]+)\.([0-9]+) ]]; then
    ((10#${BASH_REMATCH[1]} > 2 || (10#${BASH_REMATCH[1]} == 2 && 10#${BASH_REMATCH[2]} >= 2))) ||
        fail 2 'GnuPG 2.2 or newer is required.'
else
    fail 2 'Could not identify GnuPG version.'
fi

if [[ -z $NAME ]]; then read -r -p 'Name for the public key: ' NAME; fi
if [[ -z $EMAIL ]]; then read -r -p 'Email for the public key: ' EMAIL; fi
validate_name "$NAME"
validate_email "$EMAIL"
KEY_UID="$NAME <$EMAIL>"
printf '\nPublic identity: %s\n' "$KEY_UID"
printf 'Sharing your public key also shares this name/email. No upload is automatic.\n'
printf 'Choose a strong, unique, NONEMPTY passphrase in the GnuPG Pinentry dialog.\n'
printf 'This script never reads, passes, records or verifies your passphrase.\n'
printf 'All three private keys remain on this machine; this is NOT offline-master setup.\n'
[[ $EXPIRES != never ]] || printf 'WARNING: you explicitly selected a key with no expiry.\n'
if ((GIT_SIGNING)); then
    printf '\nAlso change global Git gpg.format, gpg.openpgp.program, user.signingkey,\n'
    printf 'commit.gpgsign and tag.gpgSign. Author name/email remain unchanged.\n'
fi
printf '\nType CREATE to generate the key: '
read -r answer
[[ $answer == CREATE ]] || fail 2 'Cancelled; no key created.'

private_directory() {
    local dir=$1 probe=$1 mode
    # Refuse symlinks in the chosen directory chain; do not silently chmod old paths.
    while [[ $probe != / ]]; do
        [[ ! -L $probe ]] || fail 2 "Refusing symlink in directory path: $probe"
        probe=$(dirname -- "$probe")
    done
    if [[ -e $dir ]]; then
        [[ -d $dir && -O $dir ]] || fail 2 "Directory must be owned by you: $dir"
        mode=$(stat -c %a -- "$dir")
        (( (8#$mode & 077) == 0 )) || fail 2 "Directory must be private (chmod 700 after reviewing it): $dir"
    else
        mkdir -p -m 700 -- "$dir"
    fi
}
private_directory "$GPG_HOME"
private_directory "$OUTPUT_ROOT"
GPG_HOME=$(realpath -e -- "$GPG_HOME")
OUTPUT_ROOT=$(realpath -e -- "$OUTPUT_ROOT")
export GNUPGHOME="$GPG_HOME"
export GPG_TTY
GPG_TTY=$(tty)

# Lock only other instances of THIS script, not unrelated GnuPG operations.
LOCK="$GPG_HOME/.create-gpg-key.lock"
if [[ -e $LOCK || -L $LOCK ]]; then
    [[ -f $LOCK && ! -L $LOCK && -O $LOCK ]] || fail 2 'Unsafe setup lock file.'
fi
exec 9>>"$LOCK"
flock -n 9 || fail 2 'Another create-gpg-key.sh process is running for this keyring.'
WORK=$(mktemp -d "$GPG_HOME/.create-openpgp.XXXXXXXX")
cleanup() {
    local rc=$?
    trap - EXIT
    if ((rc != 0)); then
        printf '\nStopped during: %s (exit %d).\n' "$STAGE" "$rc" >&2
        if [[ -z $FINGERPRINT && -f $WORK/primary.status ]]; then
            FINGERPRINT=$(awk '$1=="[GNUPG:]" && $2=="KEY_CREATED" {print $4; exit}' "$WORK/primary.status")
        fi
        if [[ -n $FINGERPRINT ]]; then
            printf 'A key may already exist: %s\nDo not blindly generate a replacement. Inspect it first:\n' "$FINGERPRINT" >&2
            printf '  GNUPGHOME=%q gpg --list-secret-keys --with-subkey-fingerprint %q\n' "$GPG_HOME" "$FINGERPRINT" >&2
            printf 'No generated key has been deleted. See the partial-creation section in the guide.\n' >&2
        fi
    fi
    if [[ -n $WORK && $WORK == "$GPG_HOME"/.create-openpgp.* && -d $WORK && ! -L $WORK ]]; then
        rm -rf -- "$WORK"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Ignore gpg.conf for reproducible key creation. Existing agent/Pinentry settings
# are left alone. Disable automatic key retrieval for every local operation.
GPG=("$GPG_BIN" --no-options --homedir "$GPG_HOME" --pinentry-mode ask
     --no-auto-key-retrieve --auto-key-locate clear)
STAGE='checking for an existing identity'
"${GPG[@]}" --batch --with-colons --list-keys >"$WORK/keys.before"
duplicate=$(awk -F: -v mailbox="<$EMAIL>" '
    $1=="pub" {f=""}
    $1=="fpr" && f=="" {f=$10}
    $1=="uid" && index(tolower($10),tolower(mailbox)) {if (!seen[f]++) print f}
' "$WORK/keys.before")
if [[ -n $duplicate ]]; then
    printf 'Existing key(s) with this email:\n%s\n' "$duplicate" >&2
    ((ALLOW_EXISTING_EMAIL)) || fail 3 'Refusing another key for this email. Reuse it, or explicitly choose --allow-existing-email for a separate identity/rotation.'
    printf 'Explicit duplicate-email override enabled: a DISTINCT key will be created.\n'
fi
if [[ $ALGORITHM == ed25519 ]]; then
    curves=$("${GPG[@]}" --batch --with-colons --list-config curve)
    [[ $curves == *ed25519* && $curves == *cv25519* ]] ||
        fail 2 'Ed25519/Curve25519 are unavailable in this GnuPG build; inspect its policy or select rsa4096.'
fi
# Refresh the agent terminal for SSH/console use without replacing config files.
gpg-connect-agent updatestartuptty /bye >/dev/null

STAGE='generating primary certification key'
printf '\nGenerating primary certification key; use Pinentry for the passphrase.\n'
"${GPG[@]}" --status-fd 3 --quick-generate-key "$KEY_UID" "$PRIMARY_ALGO" cert "$EXPIRES" \
    3>"$WORK/primary.status"
FINGERPRINT=$(awk '$1=="[GNUPG:]" && $2=="KEY_CREATED" && ($3=="P" || $3=="B") {print $4; exit}' "$WORK/primary.status")
[[ $FINGERPRINT =~ ^[0-9A-F]{40}$ || $FINGERPRINT =~ ^[0-9A-F]{64}$ ]] ||
    fail 1 'Generation did not return an unambiguous primary fingerprint. Inspect your keyring before retrying.'
printf 'Primary fingerprint: %s\n' "$FINGERPRINT"

STAGE='generating signing subkey'
"${GPG[@]}" --status-fd 3 --quick-add-key "$FINGERPRINT" "$SIGN_ALGO" sign "$EXPIRES" \
    3>"$WORK/sign.status"
SIGN_FPR=$(awk '$1=="[GNUPG:]" && $2=="KEY_CREATED" && $3=="S" {print $4; exit}' "$WORK/sign.status")
[[ $SIGN_FPR =~ ^[0-9A-F]{40}$ || $SIGN_FPR =~ ^[0-9A-F]{64}$ ]] || fail 1 'Signing subkey creation did not return a fingerprint.'
STAGE='generating encryption subkey'
"${GPG[@]}" --status-fd 3 --quick-add-key "$FINGERPRINT" "$ENCR_ALGO" encr "$EXPIRES" \
    3>"$WORK/encr.status"
ENCR_FPR=$(awk '$1=="[GNUPG:]" && $2=="KEY_CREATED" && $3=="S" {print $4; exit}' "$WORK/encr.status")
[[ $ENCR_FPR =~ ^[0-9A-F]{40}$ || $ENCR_FPR =~ ^[0-9A-F]{64}$ ]] || fail 1 'Encryption subkey creation did not return a fingerprint.'

STAGE='checking revocation certificate'
REVOCATION="$GPG_HOME/openpgp-revocs.d/$FINGERPRINT.rev"
[[ -f $REVOCATION && ! -L $REVOCATION && -s $REVOCATION ]] ||
    fail 1 'Automatic revocation certificate was not found. Generate one with gpg --gen-revoke and keep it private.'

STAGE='local signature and encryption self-test'
printf '\nTesting a detached signature and encryption/decryption locally...\n'
printf 'Local OpenPGP setup self-test.\nPrimary fingerprint: %s\n' "$FINGERPRINT" >"$WORK/message.txt"
"${GPG[@]}" --local-user "$SIGN_FPR!" --digest-algo SHA256 --armor \
    --output "$WORK/message.txt.asc" --detach-sign "$WORK/message.txt"
"${GPG[@]}" --batch --status-fd 3 --verify "$WORK/message.txt.asc" "$WORK/message.txt" \
    3>"$WORK/verify.status"
awk -v f="$SIGN_FPR" '$1=="[GNUPG:]" && $2=="VALIDSIG" && $3==f {ok=1} END {exit !ok}' "$WORK/verify.status" ||
    fail 1 'The signature did not verify against the expected signing subkey.'
"${GPG[@]}" --batch --recipient "$ENCR_FPR!" --output "$WORK/message.txt.gpg" --encrypt "$WORK/message.txt"
"${GPG[@]}" --output "$WORK/restored.txt" --decrypt "$WORK/message.txt.gpg"
cmp -s "$WORK/message.txt" "$WORK/restored.txt" || fail 1 'Decrypted self-test content differs.'

STAGE='exporting public key'
EXPORT_DIR="$OUTPUT_ROOT/$FINGERPRINT"
mkdir -m 700 -- "$EXPORT_DIR" # fail instead of replacing any existing directory
PUBLIC_KEY="$EXPORT_DIR/public-key.asc"
"${GPG[@]}" --armor --output "$PUBLIC_KEY" --export "$FINGERPRINT"
[[ -s $PUBLIC_KEY ]] && grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$PUBLIC_KEY" ||
    fail 1 'No valid armored public export was produced.'
printf '%s\n' "$FINGERPRINT" >"$EXPORT_DIR/fingerprint.txt"
cat >"$EXPORT_DIR/INFO.txt" <<EOF
OpenPGP identity: $KEY_UID
Primary fingerprint: $FINGERPRINT
Signing subkey: $SIGN_FPR
Encryption subkey: $ENCR_FPR
Expiry request: $EXPIRES
Keyring: $GPG_HOME
Public key: $PUBLIC_KEY
Private revocation certificate (DO NOT PUBLISH): $REVOCATION

Only public-key.asc and fingerprint.txt are intended for sharing.
No private key backup was created. Make and test an offline encrypted backup.
The primary and both subkey secrets remain on this machine.
Local signature verification and encrypt/decrypt self-tests passed.
No GitHub upload, keyserver publication or email verification was performed.
EOF

if ((GIT_SIGNING)); then
    STAGE='configuring global Git signing'
    # Back up only the affected settings, not unrelated credential-bearing config.
    SETTINGS_BACKUP="$GPG_HOME/git-signing-before-$FINGERPRINT.txt"
    (
        set -o noclobber
        {
            printf '# Previous GLOBAL values; absent is recorded explicitly.\n'
            for key in gpg.format gpg.openpgp.program user.signingkey commit.gpgsign tag.gpgSign; do
                printf '\n[%s]\n' "$key"
                if old=$(git config --global --get-all "$key"); then
                    printf '%s\n' "$old"
                else
                    rc=$?
                    ((rc == 1)) || exit "$rc"
                    printf '[absent]\n'
                fi
            done
        } >"$SETTINGS_BACKUP"
    )
    git config --global --replace-all gpg.format openpgp
    git config --global --replace-all gpg.openpgp.program "$GPG_BIN"
    git config --global --replace-all user.signingkey "$SIGN_FPR!"
    git config --global --replace-all commit.gpgsign true
    git config --global --replace-all tag.gpgSign true
    printf '\nGlobal commit/tag signing configured. Prior values: %s\n' "$SETTINGS_BACKUP"
    printf 'Git author name/email were NOT changed. Per-repository settings can override these globals.\n'
fi

STAGE='complete'
printf '\nSUCCESS: certification key + signing/encryption subkeys created.\n'
"${GPG[@]}" --list-secret-keys --keyid-format long --with-subkey-fingerprint "$FINGERPRINT"
printf '\nSHARE:   %s\nCHECK:   %s\nPRIVATE: %s\n' "$PUBLIC_KEY" "$FINGERPRINT" "$REVOCATION"
printf '\nKeep the private keyring and revocation certificate private. Never upload them.\n'
printf 'Back up privately before relying on this identity; key loss can make encrypted files unrecoverable.\n'
printf '\nIn each terminal used for GPG/Git, run (this script cannot change its parent shell):\n'
printf '  export GPG_TTY=$(tty)\n  gpg-connect-agent updatestartuptty /bye\n'
printf '\nPublic export and self-tests are local only; nobody else automatically trusts this identity.\n'
