#!/usr/bin/env bash
#
# linux-lvm-snapshot-backup
#
# WHAT IT DOES
#   Takes a crash-consistent LVM (COW) snapshot of a given logical volume,
#   mounts it read-only, backs up its contents with either `tar` or `rsync`
#   to a destination you specify, then unmounts and removes the snapshot.
#   Every step is logged; on failure or interrupt the snapshot/mount are
#   cleaned up on a best-effort basis so you don't leak snapshot space.
#
# WHAT IT ASSUMES
#   - You run it as root (or via sudo) on the host that owns the volume
#     group: `lvcreate`/`lvremove`/`mount` need real block-device access.
#   - LVM2 userspace tools (lvs, vgs, lvcreate, lvremove) are installed.
#     This is the standard toolset on RHEL and SLES; package names differ
#     (lvm2 on both) but the binaries and output format are the same.
#   - The source LV is a *classic* (non-thin) LV with a COW-capable VG that
#     has enough free extents for the snapshot's "size" (the space that
#     absorbs writes to the origin while the snapshot exists). For thin
#     LVs, `lvcreate --snapshot` does not take --size the same way; this
#     script does not special-case thin pools and will fail the pre-flight
#     free-space check accordingly. Adjust the lvcreate invocation for
#     thin-provisioned setups.
#   - The snapshot gives you crash consistency (like a power-cut), not
#     application consistency. If the LV holds a live database, quiesce or
#     flush it yourself (e.g. `mysql> FLUSH TABLES WITH READ LOCK`, or an
#     application-specific freeze hook) before invoking this script, or
#     accept crash-consistent semantics.
#   - Nothing else is already mounted at --mount-point, and the mount
#     point is a directory this script may create/remove.
#   - For a remote rsync destination (user@host:/path), SSH key-based auth
#     to that host is already configured (in ~/.ssh or an ssh-agent) --
#     this script does not accept or store passwords.
#
# HOW TO RUN IT
#   # Preview what would happen, no changes made:
#   sudo ./linux-lvm-snapshot-backup --vg vg_data --lv lv_app \
#        --dest /backups/lv_app-$(date +%F).tar.gz --dry-run
#
#   # Real run, tar to a local file:
#   sudo ./linux-lvm-snapshot-backup --vg vg_data --lv lv_app \
#        --snapshot-size 15G --dest /backups/lv_app-$(date +%F).tar.gz
#
#   # Real run, rsync to a remote host, keep the snapshot afterwards:
#   sudo ./linux-lvm-snapshot-backup --vg vg_data --lv lv_app \
#        --method rsync --dest backup01:/srv/backups/lv_app/ --keep-snapshot
#
#   # Machine-readable report on stdout, logs stay on stderr:
#   sudo ./linux-lvm-snapshot-backup --vg vg_data --lv lv_app \
#        --dest /backups/lv_app.tar.gz --json > report.json
#
#   See --help for the full flag list and defaults.
#
# REFERENCE IMPLEMENTATION NOTICE
#   NOT TESTED against live Linux (RHEL / SUSE). It was written to those
#   distributions' documented LVM2/tar/rsync/mount behavior and reviewed
#   for shell correctness, but has not been run against a real volume
#   group. Validate with --dry-run first, then on a disposable/test LV,
#   before pointing it at anything you care about.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=$(basename "$0")

# --- exit codes -------------------------------------------------------------
EXIT_OK=0
EXIT_USAGE=2
EXIT_MISSING_DEPS=3
EXIT_PRECHECK=4
EXIT_SNAPSHOT=5
EXIT_MOUNT=6
EXIT_BACKUP=7
EXIT_CLEANUP=8

# --- defaults (overridable by flags or env vars) -----------------------------
VG_NAME="${LVM_BACKUP_VG:-}"
LV_NAME="${LVM_BACKUP_LV:-}"
SNAP_NAME="${LVM_BACKUP_SNAP_NAME:-}"            # default computed after parsing
SNAP_SIZE="${LVM_BACKUP_SNAP_SIZE:-10%ORIGIN}"
MOUNT_DIR="${LVM_BACKUP_MOUNT_DIR:-}"            # default: mktemp -d
MOUNT_OPTS="${LVM_BACKUP_MOUNT_OPTS:-}"          # default computed from fstype
BACKUP_DEST="${LVM_BACKUP_DEST:-}"
BACKUP_METHOD="${LVM_BACKUP_METHOD:-tar}"        # tar | rsync
FS_TYPE=""                                       # auto-detected unless given
KEEP_SNAPSHOT=false
DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
DO_CHECKSUM=false
LOCK_DIR="${LVM_BACKUP_LOCK_DIR:-/run/lock}"
EXCLUDES=()
RSYNC_EXTRA_ARGS=()

# --- state tracked for cleanup ------------------------------------------------
SNAP_CREATED=false
SNAP_DEVICE=""
IS_MOUNTED=false
MOUNT_DIR_CREATED_BY_US=false
LOCK_FD=""
LOCK_FILE=""
START_EPOCH=""
CLEANUP_WARNINGS=()

# =============================================================================
# logging -- human-readable status goes to stderr so stdout can carry --json
# =============================================================================
_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log_info()  { printf '[%s] INFO  %s\n'  "$(_ts)" "$*" >&2; }
log_warn()  { printf '[%s] WARN  %s\n'  "$(_ts)" "$*" >&2; }
log_error() { printf '[%s] ERROR %s\n'  "$(_ts)" "$*" >&2; }
log_debug() { $VERBOSE && printf '[%s] DEBUG %s\n' "$(_ts)" "$*" >&2; return 0; }

die() {
    local code="$1"; shift
    log_error "$*"
    exit "$code"
}

# =============================================================================
# usage / argument parsing
# =============================================================================
usage() {
    cat <<EOF
$SCRIPT_NAME - take an LVM snapshot, back it up, tear it down safely

USAGE
  $SCRIPT_NAME --vg VG --lv LV --dest DEST [options]

REQUIRED
  --vg NAME              Volume group containing the source LV
  --lv NAME              Logical volume to snapshot and back up
  --dest PATH            Backup destination. For --method tar: a file path
                          (e.g. /backups/app.tar.gz). For --method rsync: a
                          local dir or remote spec (user@host:/path/).

OPTIONS
  --snapshot-name NAME   Name for the snapshot LV (default: <lv>_snap_<ts>)
  --snapshot-size SIZE   Size passed to 'lvcreate --size' (default: 10%ORIGIN)
  --mount-point PATH     Where to mount the snapshot (default: mktemp -d)
  --mount-options OPTS   Override auto-computed mount options
  --fs-type TYPE         Filesystem type hint (default: auto-detect)
  --method tar|rsync     Backup method (default: tar)
  --exclude PATTERN      Exclude pattern; may be given multiple times
  --rsync-arg ARG        Extra raw arg passed through to rsync; may repeat
  --keep-snapshot        Do not remove the snapshot after a successful backup
  --checksum             Compute a sha256 of the backup archive (tar method)
  --lock-dir PATH        Directory for the per-LV run lock (default: /run/lock)
  --json                 Emit a machine-readable JSON report on stdout
  --dry-run              Print what would be done; skip all mutating commands
  --verbose              Verbose (debug) logging on stderr
  -h, --help             Show this help and exit

ENVIRONMENT
  LVM_BACKUP_VG, LVM_BACKUP_LV, LVM_BACKUP_DEST, LVM_BACKUP_SNAP_NAME,
  LVM_BACKUP_SNAP_SIZE, LVM_BACKUP_MOUNT_DIR, LVM_BACKUP_MOUNT_OPTS,
  LVM_BACKUP_METHOD, LVM_BACKUP_LOCK_DIR
  provide defaults for the matching flags above; flags always win.

EXIT CODES
  0 ok  2 usage  3 missing deps  4 precheck failed  5 snapshot failed
  6 mount failed  7 backup failed  8 backup ok but cleanup had a problem

EXAMPLES
  $SCRIPT_NAME --vg vg_data --lv lv_app --dest /backups/lv_app.tar.gz --dry-run
  $SCRIPT_NAME --vg vg_data --lv lv_app --method rsync --dest host:/bk/ --json
EOF
}

require_arg() {
    # $1 = flag name (for the error message), $2 = value that follows it
    if [[ -z "${2:-}" || "$2" == --* ]]; then
        die "$EXIT_USAGE" "missing value for $1 (see --help)"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vg)              require_arg "$1" "${2:-}"; VG_NAME="$2"; shift 2 ;;
        --vg=*)             VG_NAME="${1#*=}"; shift ;;
        --lv)              require_arg "$1" "${2:-}"; LV_NAME="$2"; shift 2 ;;
        --lv=*)             LV_NAME="${1#*=}"; shift ;;
        --dest)            require_arg "$1" "${2:-}"; BACKUP_DEST="$2"; shift 2 ;;
        --dest=*)           BACKUP_DEST="${1#*=}"; shift ;;
        --snapshot-name)   require_arg "$1" "${2:-}"; SNAP_NAME="$2"; shift 2 ;;
        --snapshot-name=*)  SNAP_NAME="${1#*=}"; shift ;;
        --snapshot-size)   require_arg "$1" "${2:-}"; SNAP_SIZE="$2"; shift 2 ;;
        --snapshot-size=*)  SNAP_SIZE="${1#*=}"; shift ;;
        --mount-point)     require_arg "$1" "${2:-}"; MOUNT_DIR="$2"; shift 2 ;;
        --mount-point=*)    MOUNT_DIR="${1#*=}"; shift ;;
        --mount-options)   require_arg "$1" "${2:-}"; MOUNT_OPTS="$2"; shift 2 ;;
        --mount-options=*)  MOUNT_OPTS="${1#*=}"; shift ;;
        --fs-type)         require_arg "$1" "${2:-}"; FS_TYPE="$2"; shift 2 ;;
        --fs-type=*)        FS_TYPE="${1#*=}"; shift ;;
        --method)          require_arg "$1" "${2:-}"; BACKUP_METHOD="$2"; shift 2 ;;
        --method=*)         BACKUP_METHOD="${1#*=}"; shift ;;
        --exclude)         require_arg "$1" "${2:-}"; EXCLUDES+=("$2"); shift 2 ;;
        --exclude=*)        EXCLUDES+=("${1#*=}"); shift ;;
        --rsync-arg)       require_arg "$1" "${2:-}"; RSYNC_EXTRA_ARGS+=("$2"); shift 2 ;;
        --rsync-arg=*)      RSYNC_EXTRA_ARGS+=("${1#*=}"); shift ;;
        --lock-dir)        require_arg "$1" "${2:-}"; LOCK_DIR="$2"; shift 2 ;;
        --lock-dir=*)       LOCK_DIR="${1#*=}"; shift ;;
        --keep-snapshot)   KEEP_SNAPSHOT=true; shift ;;
        --checksum)        DO_CHECKSUM=true; shift ;;
        --json)            JSON_OUTPUT=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --verbose)         VERBOSE=true; shift ;;
        -h|--help)         usage; exit "$EXIT_OK" ;;
        --)                shift; break ;;
        -*)                die "$EXIT_USAGE" "unknown option: $1 (see --help)" ;;
        *)                 die "$EXIT_USAGE" "unexpected positional argument: $1 (this script takes flags only, see --help)" ;;
    esac
done

[[ -n "$VG_NAME" ]]     || die "$EXIT_USAGE" "--vg is required (see --help)"
[[ -n "$LV_NAME" ]]     || die "$EXIT_USAGE" "--lv is required (see --help)"
[[ -n "$BACKUP_DEST" ]] || die "$EXIT_USAGE" "--dest is required (see --help)"
case "$BACKUP_METHOD" in
    tar|rsync) ;;
    *) die "$EXIT_USAGE" "--method must be 'tar' or 'rsync', got: $BACKUP_METHOD" ;;
esac

[[ -n "$SNAP_NAME" ]] || SNAP_NAME="${LV_NAME}_snap_$(date +%Y%m%d%H%M%S)"
[[ -n "$MOUNT_DIR" ]] || MOUNT_DIR="" # created via mktemp -d later, once we know dry-run/root state

# =============================================================================
# dependency checks
#
# Design note: in --dry-run we still WANT the script to walk through its
# planned steps so you can sanity-check flags before touching a real
# system. A dry run therefore treats a missing privileged tool (lvcreate,
# lvremove, mount, umount) as a warning, not a fatal error, and skips the
# live LVM lookups that would need it. A real run always fails hard and
# lists every missing tool at once, rather than dying one command at a
# time.
# =============================================================================
SKIP_LIVE_CHECKS=false

check_dependencies() {
    local -a required=(lvs vgs lvcreate lvremove mount umount awk date mktemp flock)
    if [[ "$BACKUP_METHOD" == tar ]]; then
        required+=(tar)
    else
        required+=(rsync)
    fi
    $DO_CHECKSUM && required+=(sha256sum)
    command -v blkid >/dev/null 2>&1 || log_debug "blkid not found; filesystem type auto-detection will fall back to 'auto'"

    local -a missing=()
    local tool
    for tool in "${required[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        if $DRY_RUN; then
            log_warn "missing tool(s) in dry-run, continuing with planning only: ${missing[*]}"
            SKIP_LIVE_CHECKS=true
        else
            log_error "required tool(s) not found on PATH: ${missing[*]}"
            die "$EXIT_MISSING_DEPS" "install the missing package(s) (lvm2, tar/rsync, util-linux) and retry"
        fi
    fi
}

check_privileges() {
    if [[ "$(id -u)" -ne 0 ]]; then
        if $DRY_RUN; then
            log_warn "not running as root; a real run needs root/sudo for lvcreate/mount/lvremove"
        else
            die "$EXIT_PRECHECK" "this must run as root (or via sudo) to create/mount/remove LVM snapshots"
        fi
    fi
}

# =============================================================================
# preflight: confirm the VG/LV exist and there's room for the snapshot
# =============================================================================
preflight_lvm() {
    if $SKIP_LIVE_CHECKS; then
        log_warn "skipping VG/LV/free-space validation (tool missing in dry-run)"
        return 0
    fi

    if ! vgs --noheadings -o vg_name "$VG_NAME" >/dev/null 2>&1; then
        die "$EXIT_PRECHECK" "volume group not found: $VG_NAME"
    fi
    if ! lvs --noheadings -o lv_name "${VG_NAME}/${LV_NAME}" >/dev/null 2>&1; then
        die "$EXIT_PRECHECK" "logical volume not found: ${VG_NAME}/${LV_NAME}"
    fi
    if lvs --noheadings -o lv_name "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
        die "$EXIT_PRECHECK" "an LV named '${SNAP_NAME}' already exists in ${VG_NAME}; pick a different --snapshot-name"
    fi

    local free_extents
    free_extents=$(vgs --noheadings -o vg_free_count "$VG_NAME" 2>/dev/null | awk '{print $1}')
    if [[ -z "$free_extents" || "$free_extents" -eq 0 ]]; then
        die "$EXIT_PRECHECK" "volume group $VG_NAME reports no free extents; cannot create a snapshot (need free space for $SNAP_SIZE)"
    fi
    log_debug "VG $VG_NAME has $free_extents free extents"
}

# For a remote rsync destination (user@host:path), confirm SSH auth works
# up front instead of letting the eventual rsync hang/prompt for a password.
preflight_remote_dest() {
    [[ "$BACKUP_METHOD" == rsync ]] || return 0
    [[ "$BACKUP_DEST" == *:* && "$BACKUP_DEST" != /* ]] || return 0  # local path, nothing to check

    local host="${BACKUP_DEST%%:*}"
    if $SKIP_LIVE_CHECKS || ! command -v ssh >/dev/null 2>&1; then
        log_warn "ssh not available to pre-check connectivity to $host; rsync will surface any auth failure itself"
        return 0
    fi
    if $DRY_RUN; then
        log_info "[dry-run] would verify SSH key-based auth to $host before backing up"
        return 0
    fi
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" true 2>/dev/null; then
        die "$EXIT_PRECHECK" "cannot reach $host with key-based SSH auth; configure an SSH key/agent for this host before running (no password prompts are supported)"
    fi
}

# =============================================================================
# locking -- refuse to run two backups of the same LV concurrently
# =============================================================================
acquire_lock() {
    mkdir -p "$LOCK_DIR" 2>/dev/null || die "$EXIT_PRECHECK" "cannot create lock directory: $LOCK_DIR"
    LOCK_FILE="${LOCK_DIR}/linux-lvm-snapshot-backup.${VG_NAME}.${LV_NAME}.lock"
    exec {LOCK_FD}>"$LOCK_FILE" || die "$EXIT_PRECHECK" "cannot open lock file: $LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        die "$EXIT_PRECHECK" "another backup for ${VG_NAME}/${LV_NAME} is already running (lock: $LOCK_FILE)"
    fi
    log_debug "acquired lock $LOCK_FILE"
}

# =============================================================================
# cleanup -- runs on EXIT no matter how the script leaves; best-effort so one
# failure doesn't stop the rest of teardown, but every failure is reported.
# =============================================================================
cleanup() {
    local exit_code=$?

    if $IS_MOUNTED; then
        log_info "unmounting $MOUNT_DIR"
        if $DRY_RUN; then
            log_info "[dry-run] would run: umount $MOUNT_DIR"
        elif ! umount "$MOUNT_DIR" 2>/dev/null; then
            CLEANUP_WARNINGS+=("failed to unmount $MOUNT_DIR; a process may still have it open (check 'lsof +D $MOUNT_DIR')")
            log_warn "${CLEANUP_WARNINGS[-1]}"
        else
            IS_MOUNTED=false
        fi
    fi

    if $MOUNT_DIR_CREATED_BY_US && [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]] && ! $IS_MOUNTED; then
        rmdir "$MOUNT_DIR" 2>/dev/null || log_debug "left non-empty/unremovable mount dir: $MOUNT_DIR"
    fi

    if $SNAP_CREATED && ! $KEEP_SNAPSHOT; then
        log_info "removing snapshot ${VG_NAME}/${SNAP_NAME}"
        if $DRY_RUN; then
            log_info "[dry-run] would run: lvremove -f ${VG_NAME}/${SNAP_NAME}"
        elif ! lvremove -f "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
            CLEANUP_WARNINGS+=("failed to remove snapshot ${VG_NAME}/${SNAP_NAME}; remove it manually with: lvremove ${VG_NAME}/${SNAP_NAME}")
            log_warn "${CLEANUP_WARNINGS[-1]}"
        else
            SNAP_CREATED=false
        fi
    elif $SNAP_CREATED && $KEEP_SNAPSHOT; then
        log_info "leaving snapshot in place as requested: ${VG_NAME}/${SNAP_NAME}"
    fi

    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
    fi

    if (( ${#CLEANUP_WARNINGS[@]} > 0 )) && (( exit_code == 0 )); then
        exit_code=$EXIT_CLEANUP
    fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'die 130 "interrupted"' INT TERM

# =============================================================================
# step: create the snapshot
# =============================================================================
create_snapshot() {
    log_info "creating snapshot ${VG_NAME}/${SNAP_NAME} (size $SNAP_SIZE) of ${VG_NAME}/${LV_NAME}"
    if $DRY_RUN; then
        log_info "[dry-run] would run: lvcreate --snapshot --name $SNAP_NAME --size $SNAP_SIZE ${VG_NAME}/${LV_NAME}"
        SNAP_DEVICE="/dev/${VG_NAME}/${SNAP_NAME}"
        SNAP_CREATED=true
        return 0
    fi

    if ! lvcreate --snapshot --name "$SNAP_NAME" --size "$SNAP_SIZE" "${VG_NAME}/${LV_NAME}" >&2; then
        die "$EXIT_SNAPSHOT" "lvcreate failed; check VG free space and that ${VG_NAME}/${LV_NAME} isn't already snapshotted at its limit"
    fi
    SNAP_CREATED=true

    SNAP_DEVICE="/dev/${VG_NAME}/${SNAP_NAME}"
    # Device node creation via udev can lag lvcreate returning; give it a
    # short, bounded window rather than failing on a race.
    local waited=0
    while [[ ! -e "$SNAP_DEVICE" && $waited -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    [[ -e "$SNAP_DEVICE" ]] || die "$EXIT_SNAPSHOT" "lvcreate reported success but device node $SNAP_DEVICE never appeared"
    log_info "snapshot device ready: $SNAP_DEVICE"
}

# =============================================================================
# step: mount the snapshot read-only
# =============================================================================
mount_snapshot() {
    if [[ -z "$MOUNT_DIR" ]]; then
        MOUNT_DIR=$(mktemp -d "/tmp/${SCRIPT_NAME}.${LV_NAME}.XXXXXX")
        MOUNT_DIR_CREATED_BY_US=true
    elif [[ ! -d "$MOUNT_DIR" ]]; then
        mkdir -p "$MOUNT_DIR" || die "$EXIT_MOUNT" "cannot create mount point: $MOUNT_DIR"
        MOUNT_DIR_CREATED_BY_US=true
    fi

    if ! $DRY_RUN && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        die "$EXIT_MOUNT" "something is already mounted at $MOUNT_DIR; refusing to mount over it"
    fi

    if [[ -z "$FS_TYPE" ]] && ! $DRY_RUN && command -v blkid >/dev/null 2>&1; then
        FS_TYPE=$(blkid -o value -s TYPE "$SNAP_DEVICE" 2>/dev/null || true)
    fi

    if [[ -z "$MOUNT_OPTS" ]]; then
        # XFS refuses to mount two filesystems with the same UUID (origin +
        # snapshot) unless told to ignore the duplicate; other filesystems
        # don't need this.
        if [[ "$FS_TYPE" == "xfs" ]]; then
            MOUNT_OPTS="ro,nouuid"
        else
            MOUNT_OPTS="ro"
        fi
    fi

    log_info "mounting $SNAP_DEVICE at $MOUNT_DIR (options: $MOUNT_OPTS${FS_TYPE:+, fstype: $FS_TYPE})"
    if $DRY_RUN; then
        log_info "[dry-run] would run: mount ${FS_TYPE:+-t $FS_TYPE} -o $MOUNT_OPTS $SNAP_DEVICE $MOUNT_DIR"
        IS_MOUNTED=true
        return 0
    fi

    local -a mount_args=(-o "$MOUNT_OPTS")
    [[ -n "$FS_TYPE" ]] && mount_args=(-t "$FS_TYPE" "${mount_args[@]}")
    if ! mount "${mount_args[@]}" "$SNAP_DEVICE" "$MOUNT_DIR" >&2; then
        die "$EXIT_MOUNT" "mount failed for $SNAP_DEVICE at $MOUNT_DIR"
    fi
    IS_MOUNTED=true
}

# =============================================================================
# step: run the backup
# =============================================================================
BACKUP_BYTES=""
BACKUP_CHECKSUM=""

human_size() {
    # portable-ish byte->human formatting without depending on numfmt
    local bytes="$1" units=(B KiB MiB GiB TiB) i=0
    local val="$bytes"
    while (( val >= 1024 && i < 4 )); do
        val=$(( val / 1024 ))
        i=$((i + 1))
    done
    printf '%s%s' "$val" "${units[$i]}"
}

run_backup() {
    log_info "starting backup via $BACKUP_METHOD -> $BACKUP_DEST"

    if [[ "$BACKUP_METHOD" == tar ]]; then
        local dest_dir
        dest_dir=$(dirname -- "$BACKUP_DEST")
        if ! $DRY_RUN && [[ ! -d "$dest_dir" ]]; then
            die "$EXIT_BACKUP" "destination directory does not exist: $dest_dir"
        fi

        local -a tar_args=(-czf "$BACKUP_DEST" -C "$MOUNT_DIR")
        local ex
        for ex in "${EXCLUDES[@]:-}"; do
            [[ -n "$ex" ]] && tar_args+=(--exclude="$ex")
        done
        tar_args+=(.)

        if $DRY_RUN; then
            log_info "[dry-run] would run: tar ${tar_args[*]}"
        else
            if ! tar "${tar_args[@]}"; then
                die "$EXIT_BACKUP" "tar backup failed writing $BACKUP_DEST"
            fi
            BACKUP_BYTES=$(stat -c%s "$BACKUP_DEST" 2>/dev/null || echo "")
            if $DO_CHECKSUM; then
                BACKUP_CHECKSUM=$(sha256sum "$BACKUP_DEST" | awk '{print $1}')
            fi
        fi
    else
        local -a rsync_args=(-a --human-readable)
        local ex
        for ex in "${EXCLUDES[@]:-}"; do
            [[ -n "$ex" ]] && rsync_args+=(--exclude="$ex")
        done
        if (( ${#RSYNC_EXTRA_ARGS[@]} > 0 )); then
            rsync_args+=("${RSYNC_EXTRA_ARGS[@]}")
        fi
        $DRY_RUN && rsync_args+=(--dry-run --stats)

        local src="${MOUNT_DIR}/"
        if $DRY_RUN; then
            log_info "[dry-run] would run: rsync ${rsync_args[*]} $src $BACKUP_DEST"
        else
            if ! rsync "${rsync_args[@]}" "$src" "$BACKUP_DEST"; then
                die "$EXIT_BACKUP" "rsync backup failed writing to $BACKUP_DEST"
            fi
            if [[ "$BACKUP_DEST" != *:* || "$BACKUP_DEST" == /* ]] && [[ -e "$BACKUP_DEST" ]]; then
                BACKUP_BYTES=$(du -sb "$BACKUP_DEST" 2>/dev/null | awk '{print $1}')
            else
                log_debug "destination is remote; skipping local size measurement"
            fi
        fi
    fi

    log_info "backup step complete"
}

# =============================================================================
# report
# =============================================================================
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

print_report() {
    local end_epoch duration status
    end_epoch=$(date +%s)
    duration=$(( end_epoch - START_EPOCH ))
    status="ok"
    (( ${#CLEANUP_WARNINGS[@]} > 0 )) && status="ok_with_warnings"

    if $JSON_OUTPUT; then
        local warnings_json="[]"
        if (( ${#CLEANUP_WARNINGS[@]} > 0 )); then
            local w items=()
            for w in "${CLEANUP_WARNINGS[@]}"; do
                items+=("\"$(json_escape "$w")\"")
            done
            warnings_json="[$(IFS=,; echo "${items[*]}")]"
        fi
        printf '{\n'
        printf '  "status": "%s",\n' "$status"
        printf '  "dry_run": %s,\n' "$DRY_RUN"
        printf '  "vg": "%s",\n' "$(json_escape "$VG_NAME")"
        printf '  "lv": "%s",\n' "$(json_escape "$LV_NAME")"
        printf '  "snapshot_name": "%s",\n' "$(json_escape "$SNAP_NAME")"
        printf '  "snapshot_kept": %s,\n' "$KEEP_SNAPSHOT"
        printf '  "method": "%s",\n' "$(json_escape "$BACKUP_METHOD")"
        printf '  "destination": "%s",\n' "$(json_escape "$BACKUP_DEST")"
        printf '  "bytes": %s,\n' "${BACKUP_BYTES:-null}"
        if [[ -n "$BACKUP_CHECKSUM" ]]; then
            printf '  "sha256": "%s",\n' "$BACKUP_CHECKSUM"
        else
            printf '  "sha256": null,\n'
        fi
        printf '  "duration_seconds": %s,\n' "$duration"
        printf '  "warnings": %s\n' "$warnings_json"
        printf '}\n'
    else
        echo "----------------------------------------------------------------"
        echo "LVM snapshot backup report"
        echo "----------------------------------------------------------------"
        echo "Status:        $status$($DRY_RUN && echo ' (dry-run: no changes were made)')"
        echo "Source:        ${VG_NAME}/${LV_NAME}"
        echo "Snapshot:      ${VG_NAME}/${SNAP_NAME} ($([[ "$KEEP_SNAPSHOT" == true ]] && echo kept || echo removed))"
        echo "Method:        $BACKUP_METHOD"
        echo "Destination:   $BACKUP_DEST"
        if [[ -n "$BACKUP_BYTES" ]]; then
            echo "Size:          $(human_size "$BACKUP_BYTES") (${BACKUP_BYTES} bytes)"
        fi
        [[ -n "$BACKUP_CHECKSUM" ]] && echo "SHA256:        $BACKUP_CHECKSUM"
        echo "Duration:      ${duration}s"
        if (( ${#CLEANUP_WARNINGS[@]} > 0 )); then
            echo "Warnings:"
            local w
            for w in "${CLEANUP_WARNINGS[@]}"; do
                echo "  - $w"
            done
        fi
        echo "----------------------------------------------------------------"
    fi
}

# =============================================================================
# main
# =============================================================================
main() {
    START_EPOCH=$(date +%s)
    log_info "starting: ${VG_NAME}/${LV_NAME} -> $BACKUP_DEST (method=$BACKUP_METHOD, dry_run=$DRY_RUN)"

    check_dependencies
    check_privileges
    acquire_lock
    preflight_lvm
    preflight_remote_dest

    create_snapshot
    mount_snapshot
    run_backup

    log_info "backup finished successfully"
    print_report
}

main "$@"
