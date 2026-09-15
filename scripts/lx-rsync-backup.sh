#!/usr/bin/env bash
# Bash + rsync snapshots + msmtp reports. Cron runs this script with --run.
# Linux/GNU tools; no Python, jq, pip, MTA daemon, or automatic deletion.
# Documentation: https://marlam.de/msmtp/msmtp.html
#               https://manpages.debian.org/trixie/rsync/rsync.1.en.html
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: rsync-backup-bash.sh ACTION [--config FILE]

  --init              Create private configuration examples; never overwrite.
  --init-destination  Mark an EMPTY backup directory on the mounted disk.
  --check             Check tools, configuration, sources and mounted disk.
  --dry-run           Preview rsync changes; no backup writes or email.
  --run               Create a snapshot and email its result (use from cron).
  --test-mail         Send a test report; no backup or mount required.
  --retry-mail        Retry up to 10 queued reports; no backup required.
  --help              Show help.

Default config: ~/.config/rsync-backup/backup.conf (respects XDG_CONFIG_HOME).
Run as your normal user, not with sudo. Configuration is trusted Bash code.
Destination: local disk or already-mounted NAS; no direct SSH destination.
No pruning or --delete. --run also retries older pending reports.

Exit: 0 success; 2 configuration/preflight/error; 3 mail pending after success;
      24 vanished source files (incomplete); 75 overlapping run skipped;
      129/130/143 interrupted; otherwise the rsync/timeout exit status.
EOF
}
fail() { printf 'ERROR: %s\n' "$*" >&2; NOTE=$*; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }
ACTION=''
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/rsync-backup/backup.conf"
while (($#)); do
    case "$1" in
        --config)
            (($# >= 2)) && [[ -n "$2" ]] || fail '--config needs a path'
            CONFIG=$2; shift 2 ;;
        --init|--init-destination|--check|--dry-run|--run|--test-mail|--retry-mail)
            [[ -z "$ACTION" ]] || fail 'Choose one action'
            ACTION=$1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$ACTION" ]] || { usage; exit 0; }
((EUID != 0)) || fail 'Run without sudo, as the user whose files you back up'
[[ ! -L "$CONFIG" ]] || fail "Refusing symlinked config: $CONFIG"
CONFIG=$(realpath -m -- "$CONFIG")

# These files contain trusted configuration and possibly SMTP credentials.
private_file() {
    local mode
    [[ -f "$1" && ! -L "$1" && -O "$1" ]] || fail "Not an owned regular file: $1"
    mode=$(stat -c %a -- "$1")
    (( (8#$mode & 077) == 0 )) || fail "File must be private: chmod 600 '$1'"
}
private_dir() {
    local mode
    [[ ! -L "$1" ]] || fail "Refusing a symlinked private directory: $1"
    mkdir -p -- "$1"
    [[ -d "$1" && -O "$1" ]] || fail "Directory is not owned by this user: $1"
    mode=$(stat -c %a -- "$1")
    (( (8#$mode & 077) == 0 )) || fail "Directory must be private: chmod 700 '$1'"
}

if [[ "$ACTION" == --init ]]; then
    config_dir=$(dirname -- "$CONFIG")
    mail_config="${XDG_CONFIG_HOME:-$HOME/.config}/msmtp/config"
    private_dir "$config_dir"
    [[ ! -e "$CONFIG" && ! -L "$CONFIG" ]] || fail "Will not overwrite $CONFIG"
    token=$(cat /proc/sys/kernel/random/uuid)
    (
        set -o noclobber
        {
            printf '# Trusted Bash configuration. Never source a config from another user.\n'
            printf 'JOB_NAME="home"\nSOURCES=("$HOME")\n'
            printf 'BACKUP_MOUNT="/mnt/backup"\n'
            printf 'BACKUP_ROOT="/mnt/backup/%s-home"\n' "$(id -un)"
            printf 'DESTINATION_ID=%q\n' "$token"
            printf 'MIN_FREE_GIB=5\nMAX_RUNTIME="12h"\n'
            printf '\n# Patterns are relative to each transferred path; no shell expansion.\n'
            printf 'EXCLUDES=(".cache/" ".local/share/Trash/")\n'
            printf '\nMAIL_FROM="you@example.com"\nMAIL_TO="you@example.com"\n'
            printf 'MSMTP_ACCOUNT="backup"\nMSMTP_CONFIG=%q\n' "$mail_config"
        } > "$CONFIG"
    )
    private_dir "$(dirname -- "$mail_config")"
    if [[ ! -e "$mail_config" && ! -L "$mail_config" ]]; then
        (set -o noclobber; cat > "$mail_config" <<'EOF'
# Private file: chmod 600. Edit for your mail provider.
# This is a plaintext SMTP/app password, not an encrypted credential store.
defaults
auth on
tls on
tls_starttls on
tls_certcheck on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
timeout 30

account backup
host smtp.example.com
port 587
from you@example.com
user you@example.com
password "REPLACE_WITH_APP_PASSWORD_OR_SMTP_TOKEN"

# For implicit TLS on port 465, change port to 465 and tls_starttls to off.
# Do not disable tls_certcheck. A passwordeval helper is also supported by msmtp,
# but it must work noninteractively in cron; exclude its secret files yourself.
EOF
        )
    else
        printf 'Kept existing mail configuration: %s\nAdd an account named backup there.\n' "$mail_config"
    fi
    printf 'Created: %s\nEdit it and: %s\nThen run --test-mail and --init-destination.\n' "$CONFIG" "$mail_config"
    exit 0
fi

private_file "$CONFIG"
# shellcheck source=/dev/null
source "$CONFIG"
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
: "${JOB_NAME:?Missing JOB_NAME}" "${BACKUP_MOUNT:?Missing BACKUP_MOUNT}"
: "${BACKUP_ROOT:?Missing BACKUP_ROOT}" "${DESTINATION_ID:?Missing DESTINATION_ID}"
: "${MAIL_FROM:?Missing MAIL_FROM}" "${MAIL_TO:?Missing MAIL_TO}"
: "${MSMTP_CONFIG:?Missing MSMTP_CONFIG}"
MSMTP_ACCOUNT=${MSMTP_ACCOUNT:-backup}
MIN_FREE_GIB=${MIN_FREE_GIB:-5}
MAX_RUNTIME=${MAX_RUNTIME:-12h}
declare -p SOURCES 2>/dev/null | grep -q 'declare -a ' || fail 'SOURCES must be a Bash indexed array'
((${#SOURCES[@]} > 0)) || fail 'SOURCES is empty'
declare -p EXCLUDES >/dev/null 2>&1 || EXCLUDES=()
[[ "$JOB_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || fail 'Invalid JOB_NAME'
[[ "$DESTINATION_ID" =~ ^[A-Za-z0-9_-]{8,100}$ ]] || fail 'Invalid DESTINATION_ID'
[[ "$MSMTP_ACCOUNT" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'Invalid mail account name'
[[ "$MIN_FREE_GIB" =~ ^(0|[1-9][0-9]{0,5})$ ]] || fail 'Invalid MIN_FREE_GIB'
[[ "$MAX_RUNTIME" =~ ^[1-9][0-9]{0,5}[smh]$ ]] || fail 'MAX_RUNTIME needs e.g. 30m or 12h'
for address in "$MAIL_FROM" "$MAIL_TO"; do
    [[ "$address" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || fail 'Use one plain email address, no display name'
    [[ "$address" != you@example.com ]] || fail 'Set MAIL_FROM and MAIL_TO in backup.conf'
done
for path in "$BACKUP_MOUNT" "$BACKUP_ROOT" "$MSMTP_CONFIG" "${SOURCES[@]}"; do
    [[ "$path" == /* && "$path" != *[$'\r\n\t']* ]] || fail "Use absolute paths without CR/LF/TAB: $path"
done
[[ ! -L "$BACKUP_ROOT" && ! -L "$MSMTP_CONFIG" ]] || fail "Refusing symlinked destination or mail config"
BACKUP_MOUNT=$(realpath -m -- "$BACKUP_MOUNT")
BACKUP_ROOT=$(realpath -m -- "$BACKUP_ROOT")
MSMTP_CONFIG=$(realpath -m -- "$MSMTP_CONFIG")
STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/rsync-backup-bash"
[[ "$STATE_BASE" == /* ]] || fail 'XDG_STATE_HOME must be absolute'
STATE_BASE=$(realpath -m -- "$STATE_BASE")
STATE="$STATE_BASE/$(printf '%s' "$BACKUP_ROOT" | sha256sum | cut -c 1-24)"
[[ "$STATE_BASE/" != "$BACKUP_MOUNT/"* ]] || fail 'Mail/log state must not be on the backup disk'
[[ "$BACKUP_MOUNT" != / && "$BACKUP_ROOT" == "$BACKUP_MOUNT/"* ]] || fail 'BACKUP_ROOT must be below a non-root BACKUP_MOUNT'

check_mount() {
    mountpoint -q -- "$BACKUP_MOUNT" || fail "Backup disk is NOT mounted at $BACKUP_MOUNT; refusing fallback writes"
}
check_destination() {
    check_mount
    [[ -d "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" && -w "$BACKUP_ROOT" ]] || fail 'Destination missing/unwritable; run --init-destination'
    [[ -f "$BACKUP_ROOT/.backup-id" && ! -L "$BACKUP_ROOT/.backup-id" ]] || fail 'Destination marker missing; refusing writes'
    [[ $(cat -- "$BACKUP_ROOT/.backup-id") == "$DESTINATION_ID" ]] || fail 'Destination marker does not match; wrong backup disk/directory'
    [[ -d "$BACKUP_ROOT/snapshots" && ! -L "$BACKUP_ROOT/snapshots" ]] || fail 'Invalid snapshots directory'
}
check_sources() {
    local s canonical
    for s in "${SOURCES[@]}"; do
        [[ -d "$s" && ! -L "$s" && -r "$s" && -x "$s" ]] || fail "Source missing/unreadable or symlinked (use its real path): $s"
        canonical=$(realpath -e -- "$s")
        [[ "$canonical" != / ]] || fail 'This file-backup script does not support / as a source'
        [[ "$BACKUP_ROOT/" != "$canonical/"* && "$canonical/" != "$BACKUP_ROOT/"* ]] || fail 'Source and backup destination must not contain each other'
    done
}
check_mail() { need msmtp; private_file "$MSMTP_CONFIG"; }
free_bytes() { df -B1 --output=avail -- "$BACKUP_ROOT" | awk 'NR==2 {print $1}'; }
PREVIOUS=''
previous_snapshot() {
    local candidate name
    if [[ -L "$BACKUP_ROOT/latest" ]]; then
        candidate=$(realpath -e -- "$BACKUP_ROOT/latest") || fail 'latest is dangling'
        name=${candidate##*/}
        [[ "$candidate" == "$BACKUP_ROOT/snapshots/$name" && "$name" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ && -d "$candidate" ]] || fail 'latest points outside the completed snapshots'
        PREVIOUS=$name
    elif [[ -e "$BACKUP_ROOT/latest" ]]; then
        fail 'latest exists but is not a symlink'
    fi
}
# Escape literal paths before embedding them in rsync exclude patterns.
pattern_escape() {
    local v=$1
    v=${v//\\/\\\\}; v=${v//\*/\\*}; v=${v//\?/\\?}; v=${v//\[/\\[}
    printf '%s' "$v"
}
RSYNC_ARGS=()
make_rsync_args() {
    local p
    RSYNC_ARGS=(-aHAX --numeric-ids --relative --one-file-system --stats --human-readable)
    for p in "${EXCLUDES[@]}"; do RSYNC_ARGS+=("--exclude=$p"); done
    # Keep transient backup state and SMTP secrets out of home backups.
    RSYNC_ARGS+=("--exclude=$(pattern_escape "$STATE_BASE")/***")
    RSYNC_ARGS+=("--exclude=$(pattern_escape "$CONFIG")")
    RSYNC_ARGS+=("--exclude=$(pattern_escape "$MSMTP_CONFIG")")
    [[ -z "$PREVIOUS" ]] || RSYNC_ARGS+=("--link-dest=../$PREVIOUS")
}

if [[ "$ACTION" == --init-destination ]]; then
    need mountpoint; check_mount; check_sources
    if [[ -e "$BACKUP_ROOT/.backup-id" ]]; then
        check_destination; printf 'Destination already initialized.\n'; exit 0
    fi
    [[ ! -L "$BACKUP_ROOT" ]] || fail 'Refusing symlinked destination'
    private_dir "$BACKUP_ROOT"
    [[ -z $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail 'Refusing a nonempty unmanaged destination'
    # Keep cwd on the mounted filesystem for subsequent relative operations.
    cd -- "$BACKUP_ROOT"
    (set -o noclobber; printf '%s\n' "$DESTINATION_ID" > .backup-id)
    mkdir -- snapshots
    printf 'Initialized: %s\n' "$BACKUP_ROOT"
    exit 0
fi
if [[ "$ACTION" == --check || "$ACTION" == --dry-run ]]; then
    for c in rsync msmtp mountpoint flock timeout base64; do need "$c"; done
    check_mail; check_sources; check_destination; previous_snapshot
    printf 'Local checks passed; SMTP and actual backup have NOT been tested.\n'
    df -h -- "$BACKUP_ROOT"
    if [[ "$ACTION" == --dry-run ]]; then
        make_rsync_args
        cd -- "$BACKUP_ROOT"
        rsync "${RSYNC_ARGS[@]}" --dry-run --itemize-changes -- "${SOURCES[@]}" "snapshots/.preview-$$/"
    fi
    exit 0
fi

# Set up a local report location before inspecting the backup disk: a missing
# disk can therefore still produce an email. Invalid config cannot do so.
for c in flock timeout base64 date tail; do need "$c"; done
private_dir "$STATE_BASE"; private_dir "$STATE"; private_dir "$STATE/logs"; private_dir "$STATE/outbox"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
LOG="$STATE/logs/$RUN_ID.log"
: > "$LOG"
START=$(date +%s)
START_TEXT=$(date -Is)
HOST=$(hostname | tr -cd 'A-Za-z0-9.-')
STATUS=FAILED
NOTE='The run did not complete.'
RESULT='not started'
SNAPSHOT='none'
FREE_BEFORE='unknown'
CHILD=''
RETRY_LIMIT=10

send_report_file() {
    # A successful return means SMTP acceptance, not proof of inbox delivery.
    local mode
    [[ -f "$1" && ! -L "$1" && -O "$1" ]] || return 1
    [[ -f "$MSMTP_CONFIG" && ! -L "$MSMTP_CONFIG" && -O "$MSMTP_CONFIG" ]] || return 1
    mode=$(stat -c %a -- "$MSMTP_CONFIG") || return 1
    (( (8#$mode & 077) == 0 )) || return 1
    timeout --signal=TERM --kill-after=5s 60s msmtp \
        --file="$MSMTP_CONFIG" --account="$MSMTP_ACCOUNT" \
        --tls=on --tls-certcheck=on --timeout=30 \
        --from="$MAIL_FROM" --read-recipients < "$1"
}
retry_pending() {
    local f rc=0 count=0
    exec 8> "$STATE/mail.lock"
    flock -n 8 || { printf 'Another mail sender is active; pending reports retained.\n' >&2; return 3; }
    shopt -s nullglob
    for f in "$STATE/outbox/"*.eml; do
        [[ "$f" != "${1:-}" ]] || continue
        ((count < RETRY_LIMIT)) || break
        count=$((count + 1))
        if send_report_file "$f" >> "$LOG" 2>&1; then
            rm -- "$f"
        else
            printf 'Mail pending: %s (details in %s)\n' "$f" "$LOG" >&2
            rc=3
            break
        fi
    done
    flock -u 8; exec 8>&-
    return "$rc"
}
finish() {
    local rc=$1 report tmp duration free_after
    trap - EXIT ERR
    trap '' HUP INT TERM
    set +e
    # GNU timeout forwards TERM to the transfer group and applies its kill-after.
    if [[ -n "$CHILD" ]]; then
        kill -TERM "$CHILD" 2>/dev/null
        wait "$CHILD" 2>/dev/null
    fi
    if [[ "$STATUS" == FAILED && "$rc" == 0 ]]; then rc=2; fi
    duration=$(( $(date +%s) - START ))
    free_after=unknown
    if mountpoint -q -- "$BACKUP_MOUNT" && [[ -d "$BACKUP_ROOT" ]]; then
        free_after=$(free_bytes 2>/dev/null) || free_after=unknown
    fi
    printf '\n%s: %s\n' "$STATUS" "$NOTE" >> "$LOG"
    printf '%s: %s\nLog: %s\n' "$STATUS" "$NOTE" "$LOG"
    report="$STATE/outbox/$RUN_ID.eml"
    tmp="$STATE/outbox/.$RUN_ID.tmp"
    {
        printf 'From: %s\nTo: %s\n' "$MAIL_FROM" "$MAIL_TO"
        printf 'Subject: [backup %s] %s / %s\n' "$STATUS" "$HOST" "$JOB_NAME"
        printf 'Date: %s\n' "$(date -R)"
        printf 'Message-ID: <%s.%s@%s>\n' "$RUN_ID" "$JOB_NAME" "${HOST:-localhost}"
        printf 'Auto-Submitted: auto-generated\nMIME-Version: 1.0\n'
        printf 'Content-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n'
        {
            printf 'Status: %s\nNote: %s\nHost: %s\nJob: %s\n' "$STATUS" "$NOTE" "$HOST" "$JOB_NAME"
            printf 'Started: %s\nFinished: %s\nDuration: %s seconds\n' "$START_TEXT" "$(date -Is)" "$duration"
            printf 'Process exit: %s\nrsync/timeout result: %s\nSnapshot: %s\n' "$rc" "$RESULT" "$SNAPSHOT"
            printf 'Destination: %s\nFree bytes before/after: %s / %s\nSources:\n' "$BACKUP_ROOT" "$FREE_BEFORE" "$free_after"
            printf '  %s\n' "${SOURCES[@]}"
            printf '\nLog: %s\nLast log lines (bounded to 12 KiB):\n' "$LOG"
            tail -n 60 -- "$LOG" | tail -c 12288
        } | base64 -w 76
    } > "$tmp"
    if [[ $? == 0 ]] && mv -- "$tmp" "$report"; then
        # Try this run first, then retry older reports. On failure retain .eml.
        exec 8> "$STATE/mail.lock"
        if flock -n 8; then
            if send_report_file "$report" >> "$LOG" 2>&1; then
                rm -- "$report"
                printf 'Report accepted by SMTP.\n'
            else
                printf 'ERROR: report queued at %s; see %s\n' "$report" "$LOG" >&2
                ((rc != 0)) || rc=3
            fi
            flock -u 8
        else
            printf 'Report queued: mail sender busy.\n' >&2
            ((rc != 0)) || rc=3
        fi
        exec 8>&-
        if [[ "$ACTION" == --run ]]; then
            retry_pending "$report" || { ((rc != 0)) || rc=3; }
        fi
    else
        printf 'ERROR: could not save report; check local disk space.\n' >&2
        ((rc != 0)) || rc=3
    fi
    exit "$rc"
}
if [[ "$ACTION" == --retry-mail ]]; then
    check_mail; retry_pending; exit 0
fi
trap 'finish "$?"' EXIT
trap 'STATUS=INTERRUPTED; NOTE="Received SIGHUP"; exit 129' HUP
trap 'STATUS=INTERRUPTED; NOTE="Received SIGINT"; exit 130' INT
trap 'STATUS=INTERRUPTED; NOTE="Received SIGTERM"; exit 143' TERM
# Capture failures in the emailed log without exposing command arguments/secrets.
trap 'rc=$?; printf "Unexpected command failure at line %s (exit %s)\n" "$LINENO" "$rc" >> "$LOG"; exit "$rc"' ERR

if [[ "$ACTION" == --test-mail ]]; then
    check_mail
    STATUS=TEST; NOTE='Test email only. No backup was performed.'; exit 0
fi
need rsync; need mountpoint; need nice
# Lock is local: two runs for this destination cannot update latest concurrently.
exec 9> "$STATE/backup.lock"
if ! flock -n 9; then
    STATUS=SKIPPED; NOTE='Another backup for this destination is running.'; exit 75
fi
# Keep all diagnostics, including missing sources/disks, in the report.
exec 3>&2
exec 2>> "$LOG"
check_mail; check_sources; check_destination; previous_snapshot
FREE_BEFORE=$(free_bytes)
[[ "$FREE_BEFORE" =~ ^[0-9]+$ ]] || fail 'Could not read destination free space'
((FREE_BEFORE >= MIN_FREE_GIB * 1024 * 1024 * 1024)) || fail "Less than $MIN_FREE_GIB GiB free; no files deleted"
make_rsync_args
cd -- "$BACKUP_ROOT"
SNAPSHOT="$BACKUP_ROOT/snapshots/.incomplete-$RUN_ID"
mkdir -- "snapshots/.incomplete-$RUN_ID"
printf 'Started: %s\nSources:\n' "$START_TEXT" >> "$LOG"
printf '  %s\n' "${SOURCES[@]}" >> "$LOG"
# No per-file progress log: retain stats/errors rather than every copied name.
timeout --signal=TERM --kill-after=15s "$MAX_RUNTIME" \
    nice -n 10 rsync "${RSYNC_ARGS[@]}" -- "${SOURCES[@]}" \
    "snapshots/.incomplete-$RUN_ID/" >> "$LOG" 2>&1 &
CHILD=$!
if wait "$CHILD"; then RESULT=0; else RESULT=$?; fi
CHILD=''
exec 2>&3 3>&-
if ((RESULT == 0)); then
    check_destination
    mv -- "snapshots/.incomplete-$RUN_ID" "snapshots/$RUN_ID"
    SNAPSHOT="$BACKUP_ROOT/snapshots/$RUN_ID"
    ln -s -- "snapshots/$RUN_ID" ".latest-$RUN_ID"
    mv -Tf -- ".latest-$RUN_ID" latest
    STATUS=SUCCESS; NOTE='Snapshot complete; latest updated.'
    exit 0
elif ((RESULT == 24)); then
    STATUS=WARNING; NOTE='Source files vanished during transfer. Incomplete snapshot retained; latest unchanged.'
else
    STATUS=FAILED; NOTE="rsync/timeout exited $RESULT. Incomplete snapshot retained; latest unchanged."
fi
exit "$RESULT"
