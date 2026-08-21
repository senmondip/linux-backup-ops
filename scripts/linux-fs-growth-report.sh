The script is written, tested end-to-end (help, sample, report table/JSON, prune, and all error paths including bad flags, missing state, SSH failure, and the CRIT exit code), and lives at `/apps/JOBS/linux-fs-growth-report`.

```bash
#!/usr/bin/env bash
#
# linux-fs-growth-report — Filesystem growth reporter for Linux (RHEL / SUSE)
#
# WHAT IT DOES
#   Takes point-in-time filesystem usage samples (via `df -PT`, locally or
#   over SSH) and appends them to a flat CSV history file. On a later run it
#   reads that history, fits a simple linear trend (least-squares regression
#   of "used space" over time) per host+mount, and reports current usage plus
#   a forecast of days-until-full. Intended to be driven by cron/systemd
#   timers: sample frequently (e.g. hourly/daily), report on demand.
#
# WHAT IT ASSUMES
#   - GNU coreutils `df` supporting `df -PT` (POSIX output + filesystem type
#     column). Present on stock RHEL 7/8/9 and SUSE (SLES) 12/15.
#   - Mount points do not contain spaces or commas. A mount path with an
#     embedded space will misparse `df -PT` output (this is a `df` limitation,
#     not specific to this script).
#   - `awk` is available and behaves as a POSIX/mawk/gawk-compatible awk
#     (no gawk-only extensions are used, for portability).
#   - The state file is single-writer-ish; `flock` is used when available to
#     serialize concurrent --sample runs, but is not a hard requirement.
#   - For --host sampling, passwordless SSH (key-based auth, agent, or
#     ssh_config Host aliases) is already set up. This script never accepts,
#     stores, or prompts for a password — if SSH needs one, it fails loudly.
#   - No hostnames, credentials, or filesystem paths are baked in. Everything
#     that identifies a target system or storage location comes from flags or
#     environment variables (LINUX_FS_GROWTH_STATE_DIR, LINUX_FS_GROWTH_HOST_LABEL).
#
# HOW TO RUN IT
#   # Take a local sample (put this on a cron/systemd timer, e.g. hourly):
#   ./linux-fs-growth-report --sample
#
#   # Take a sample of a remote host over SSH (key-based auth required):
#   ./linux-fs-growth-report --sample --host db01.example.internal
#
#   # After a few samples have accumulated, generate a report:
#   ./linux-fs-growth-report --report
#   ./linux-fs-growth-report --report --json
#
#   # Prune history older than 180 days:
#   ./linux-fs-growth-report --prune --retention-days 180
#
#   # Everything respects a custom state directory instead of the default:
#   LINUX_FS_GROWTH_STATE_DIR=/data/fsgrowth ./linux-fs-growth-report --sample
#
#   Full flag reference: ./linux-fs-growth-report --help
#
# REFERENCE IMPLEMENTATION NOTICE
#   This script was written and smoke-tested (--help/--sample/--report/--json/
#   --prune, syntax and argument-parsing paths) on a generic Linux box with
#   GNU coreutils and mawk. It has NOT been TESTED against live Linux
#   (RHEL / SUSE) systems. Before relying on it in production, validate `df -PT`
#   output formatting and SSH sampling on an actual RHEL and SUSE host.
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME=$(basename "$0")

# ---------------------------------------------------------------------------
# Defaults (all overridable via flags; state dir also via env var so nothing
# customer/host-specific is hardcoded in the script itself).
# ---------------------------------------------------------------------------
STATE_DIR="${LINUX_FS_GROWTH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/linux-fs-growth-report}"
HOST=""
declare -a SSH_OPTS=()
EXCLUDE_TYPE_RE='^(tmpfs|devtmpfs|proc|sysfs|cgroup2?|overlay|squashfs|autofs|mqueue|debugfs|tracefs|securityfs|pstore|bpf|configfs|fusectl|devpts|rpc_pipefs|binfmt_misc|hugetlbfs|efivarfs)$'
INCLUDE_MOUNT_RE=""
WARN_PERCENT=85
CRIT_PERCENT=95
FORECAST_DAYS=30
MIN_SAMPLES=2
RETENTION_DAYS=90
JSON_OUTPUT=0
QUIET=0
ACTION=""

# ---------------------------------------------------------------------------
# Logging helpers — all diagnostics go to stderr, report output goes to stdout.
# ---------------------------------------------------------------------------
log_info()  { [[ "$QUIET" -eq 1 ]] || printf '[INFO]  %s\n' "$*" >&2; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

die() {
    log_error "$*"
    exit 3
}

die_usage() {
    log_error "$*"
    printf 'Run "%s --help" for usage.\n' "$SCRIPT_NAME" >&2
    exit 1
}

usage() {
    cat <<EOF
$SCRIPT_NAME — track and forecast per-filesystem growth from periodic samples

USAGE
    $SCRIPT_NAME --sample [options]
    $SCRIPT_NAME --report [options]
    $SCRIPT_NAME --prune  [options]

ACTIONS (exactly one required)
    --sample                Take a usage sample now and append it to the state file.
    --report                Generate a growth report from stored samples.
    --prune                 Delete samples older than --retention-days and exit.

TARGET SELECTION
    --host HOST             Sample a remote host over SSH instead of the local
                             machine. Requires passwordless (key-based) SSH access
                             already configured — this script never handles passwords.
    --ssh-opt OPT           Extra option passed to ssh (repeatable), e.g.
                             --ssh-opt -p2222 --ssh-opt -oConnectTimeout=5

STORAGE
    --state-dir DIR         Directory holding the sample history CSV.
                             Default: \$LINUX_FS_GROWTH_STATE_DIR, or
                             ${XDG_STATE_HOME:-\$HOME/.local/state}/linux-fs-growth-report

FILTERING (applies to --sample)
    --exclude-type REGEX    Extended regex of filesystem types to skip.
                             Default: $EXCLUDE_TYPE_RE
    --include-mount REGEX   Only sample mount points matching this extended regex.
                             Default: all (after --exclude-type filtering).

REPORTING (applies to --report)
    --warn-percent N        Usage %% at/above which a filesystem is WARN (default: $WARN_PERCENT)
    --crit-percent N        Usage %% at/above which a filesystem is CRIT (default: $CRIT_PERCENT)
    --forecast-days N       Also flag WARN if projected to fill within N days (default: $FORECAST_DAYS)
    --min-samples N         Minimum samples required before forecasting a trend (default: $MIN_SAMPLES)
    --json                  Emit the report as JSON instead of a table.

PRUNING (applies to --prune)
    --retention-days N      Delete samples older than N days (default: $RETENTION_DAYS)

GENERAL
    --quiet                 Suppress informational logging (errors still print).
    -h, --help              Show this help and exit.

EXIT CODES
    0  success
    1  usage/argument error
    2  a required tool or credential is missing
    3  runtime error (I/O, SSH, malformed state, etc.)
    4  --report succeeded but at least one filesystem is CRIT

EXAMPLES
    $SCRIPT_NAME --sample
    $SCRIPT_NAME --sample --host db01.internal --ssh-opt -oConnectTimeout=5
    $SCRIPT_NAME --report --warn-percent 80 --crit-percent 90
    $SCRIPT_NAME --report --json
    $SCRIPT_NAME --prune --retention-days 180
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing — explicit long options only, no positional guesswork.
# ---------------------------------------------------------------------------
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

require_arg() {
    # $1 = flag name, $2 = value (may be unset/empty)
    if [[ -z "${2:-}" ]]; then
        die_usage "$1 requires a value"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sample) ACTION="sample"; shift ;;
        --report) ACTION="report"; shift ;;
        --prune) ACTION="prune"; shift ;;
        --host) require_arg "--host" "${2:-}"; HOST="$2"; shift 2 ;;
        --ssh-opt) require_arg "--ssh-opt" "${2:-}"; SSH_OPTS+=("$2"); shift 2 ;;
        --state-dir) require_arg "--state-dir" "${2:-}"; STATE_DIR="$2"; shift 2 ;;
        --exclude-type) require_arg "--exclude-type" "${2:-}"; EXCLUDE_TYPE_RE="$2"; shift 2 ;;
        --include-mount) require_arg "--include-mount" "${2:-}"; INCLUDE_MOUNT_RE="$2"; shift 2 ;;
        --warn-percent) require_arg "--warn-percent" "${2:-}"; WARN_PERCENT="$2"; shift 2 ;;
        --crit-percent) require_arg "--crit-percent" "${2:-}"; CRIT_PERCENT="$2"; shift 2 ;;
        --forecast-days) require_arg "--forecast-days" "${2:-}"; FORECAST_DAYS="$2"; shift 2 ;;
        --min-samples) require_arg "--min-samples" "${2:-}"; MIN_SAMPLES="$2"; shift 2 ;;
        --retention-days) require_arg "--retention-days" "${2:-}"; RETENTION_DAYS="$2"; shift 2 ;;
        --json) JSON_OUTPUT=1; shift ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die_usage "Unknown option: $1" ;;
        *) die_usage "Unexpected positional argument: $1 (this tool takes flags only)" ;;
    esac
done

[[ -n "$ACTION" ]] || die_usage "One of --sample, --report, or --prune is required"

for name_val in "WARN_PERCENT:$WARN_PERCENT" "CRIT_PERCENT:$CRIT_PERCENT" \
                "FORECAST_DAYS:$FORECAST_DAYS" "MIN_SAMPLES:$MIN_SAMPLES" \
                "RETENTION_DAYS:$RETENTION_DAYS"; do
    val="${name_val#*:}"
    is_uint "$val" || die_usage "${name_val%%:*} must be a non-negative integer, got: $val"
done
[[ "$WARN_PERCENT" -le 100 ]] || die_usage "--warn-percent must be <= 100"
[[ "$CRIT_PERCENT" -le 100 ]] || die_usage "--crit-percent must be <= 100"
[[ "$CRIT_PERCENT" -ge "$WARN_PERCENT" ]] || die_usage "--crit-percent must be >= --warn-percent"

# ---------------------------------------------------------------------------
# Tool checks — fail clearly instead of letting a missing tool blow up mid-run.
# ---------------------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { log_error "Required tool not found in PATH: $1"; exit 2; }
}

require_cmd awk
require_cmd date
require_cmd mkdir
require_cmd mv
require_cmd cat

STATE_FILE="$STATE_DIR/samples.csv"
LOCK_FILE="$STATE_DIR/.samples.lock"
CSV_HEADER="host,ts,fs,type,mount,size_kb,used_kb,avail_kb,use_pct"

HAVE_FLOCK=0
command -v flock >/dev/null 2>&1 && HAVE_FLOCK=1
[[ "$HAVE_FLOCK" -eq 1 ]] || log_warn "flock not found — concurrent --sample runs are not serialized"

# Serialize a write to STATE_FILE: append_locked <<< "$data"
append_locked() {
    local data
    data="$(cat)"
    [[ -n "$data" ]] || return 0
    if [[ "$HAVE_FLOCK" -eq 1 ]]; then
        (
            flock -w 15 200 || die "Could not acquire lock on $LOCK_FILE within 15s"
            printf '%s\n' "$data" >> "$STATE_FILE"
        ) 200>"$LOCK_FILE"
    else
        printf '%s\n' "$data" >> "$STATE_FILE"
    fi
}

# Replace STATE_FILE contents atomically and under lock: replace_locked <newfile>
replace_locked() {
    local newfile="$1"
    if [[ "$HAVE_FLOCK" -eq 1 ]]; then
        (
            flock -w 15 200 || die "Could not acquire lock on $LOCK_FILE within 15s"
            mv -f "$newfile" "$STATE_FILE"
        ) 200>"$LOCK_FILE"
    else
        mv -f "$newfile" "$STATE_FILE"
    fi
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR" 2>/dev/null || die "Cannot create state directory: $STATE_DIR"
    [[ -w "$STATE_DIR" ]] || die "State directory is not writable: $STATE_DIR"
}

# ---------------------------------------------------------------------------
# --sample: capture current usage (local or remote) and append to history.
# ---------------------------------------------------------------------------
cmd_sample() {
    ensure_state_dir

    local host_label df_output ts
    if [[ -n "$HOST" ]]; then
        require_cmd ssh
        host_label="$HOST"
        log_info "Sampling $HOST via ssh ..."
        if ! df_output="$(ssh "${SSH_OPTS[@]}" "$HOST" df -PT 2>&1)"; then
            die "ssh/df against '$HOST' failed (check SSH key auth, connectivity, and that 'df' exists remotely):
$df_output"
        fi
    else
        require_cmd df
        host_label="${LINUX_FS_GROWTH_HOST_LABEL:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)}"
        log_info "Sampling local host ($host_label) ..."
        if ! df_output="$(df -PT 2>&1)"; then
            die "'df -PT' failed locally:
$df_output"
        fi
    fi

    ts="$(date +%s)"

    # Parse df -PT output:
    #   Filesystem Type 1024-blocks Used Available Capacity Mounted-on
    # Header line is skipped. Capacity's trailing '%' is stripped.
    local rows
    rows="$(printf '%s\n' "$df_output" | awk -v ts="$ts" -v host="$host_label" \
        -v exre="$EXCLUDE_TYPE_RE" -v incre="$INCLUDE_MOUNT_RE" '
        NR==1 { next }
        NF < 7 { next }
        {
            fs=$1; type=$2; size=$3+0; used=$4+0; avail=$5+0
            pct=$6; gsub(/%/,"",pct); pct=pct+0
            mount=$7
            for (i=8;i<=NF;i++) mount = mount " " $i   # tolerate rare embedded-space mounts
            if (exre != "" && type ~ exre) next
            if (incre != "" && mount !~ incre) next
            printf "%s,%s,%s,%s,%s,%d,%d,%d,%d\n", host, ts, fs, type, mount, size, used, avail, pct
        }')"

    if [[ -z "$rows" ]]; then
        log_warn "No filesystems matched after filtering — nothing sampled"
        return 0
    fi

    if [[ ! -s "$STATE_FILE" ]]; then
        printf '%s\n' "$CSV_HEADER" | append_locked
    fi
    printf '%s\n' "$rows" | append_locked

    local count
    count="$(printf '%s\n' "$rows" | grep -c '.')"
    log_info "Recorded $count filesystem sample(s) for $host_label at $(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
}

# ---------------------------------------------------------------------------
# --report: fit a linear trend per host+mount and forecast days-to-full.
# ---------------------------------------------------------------------------
human_kb() {
    # Render a KB integer as human-readable size (best effort, no hard dep).
    local kb="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --from-unit=1024 "$kb" 2>/dev/null || printf '%sK' "$kb"
    else
        awk -v kb="$kb" 'BEGIN{
            v=kb*1024; u[0]="B";u[1]="K";u[2]="M";u[3]="G";u[4]="T";i=0
            while (v>=1024 && i<4) { v/=1024; i++ }
            printf "%.1f%s", v, u[i]
        }'
    fi
}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

cmd_report() {
    [[ -s "$STATE_FILE" ]] || die "No sample history found at $STATE_FILE — run --sample first (and let it collect at least $MIN_SAMPLES samples over time)"

    # One row per host+mount: last-known stats + least-squares growth slope.
    # Slope is fit on used_kb vs. ts(seconds), then converted to KB/day.
    local trend
    trend="$(awk -F',' '
        NR==1 { next }
        NF < 9 { next }
        {
            key = $1 SUBSEP $5
            t = $2 + 0; u = $7 + 0
            n[key]++
            sumT[key]+=t; sumU[key]+=u; sumTU[key]+=t*u; sumTT[key]+=t*t
            if (!(key in lastTs) || t >= lastTs[key]) {
                lastTs[key]=t
                lHost[key]=$1; lFs[key]=$3; lType[key]=$4; lMount[key]=$5
                lSize[key]=$6+0; lUsed[key]=$7+0; lAvail[key]=$8+0; lPct[key]=$9+0
            }
        }
        END {
            for (k in n) {
                N=n[k]
                slope="NA"
                if (N>=2) {
                    denom = N*sumTT[k]-sumT[k]*sumT[k]
                    if (denom != 0) {
                        s = (N*sumTU[k]-sumT[k]*sumU[k]) / denom
                        slope = s * 86400
                    }
                }
                printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%d\n", \
                    lHost[k], lMount[k], lFs[k], lType[k], lSize[k], lUsed[k], lAvail[k], lPct[k], slope, N
            }
        }
    ' "$STATE_FILE" | sort -t$'\t' -k8,8nr)"

    if [[ -z "$trend" ]]; then
        die "State file exists but contains no usable rows: $STATE_FILE"
    fi

    local any_crit=0
    local -a json_items=()

    if [[ "$JSON_OUTPUT" -eq 0 ]]; then
        printf '%-24s %-28s %-8s %6s %6s %6s %14s %16s %s\n' \
            "HOST" "MOUNT" "TYPE" "SIZE" "USED" "USE%" "GROWTH/DAY" "DAYS-TO-FULL" "STATUS"
    fi

    while IFS=$'\t' read -r host mount fs type size used avail pct slope nsamples; do
        [[ -n "${host:-}" ]] || continue

        local growth_disp days_disp status remaining
        if [[ "$slope" == "NA" || "$nsamples" -lt "$MIN_SAMPLES" ]]; then
            growth_disp="n/a"
            days_disp="n/a (need $MIN_SAMPLES+ samples)"
        else
            growth_disp="$(awk -v s="$slope" 'BEGIN{printf "%.1f MB/day", s/1024}')"
            remaining=$(( size - used ))
            if awk -v s="$slope" 'BEGIN{exit !(s>0)}'; then
                days_disp="$(awk -v r="$remaining" -v s="$slope" 'BEGIN{printf "%.0f days", r/s}')"
            else
                days_disp="n/a (not growing)"
            fi
        fi

        status="OK"
        if [[ "$pct" -ge "$CRIT_PERCENT" ]]; then
            status="CRIT"
        elif [[ "$pct" -ge "$WARN_PERCENT" ]]; then
            status="WARN"
        elif [[ "$days_disp" == *" days" ]]; then
            local days_num="${days_disp% days}"
            if awk -v d="$days_num" -v f="$FORECAST_DAYS" 'BEGIN{exit !(d>=0 && d<=f)}'; then
                status="WARN"
            fi
        fi
        [[ "$status" == "CRIT" ]] && any_crit=1

        if [[ "$JSON_OUTPUT" -eq 0 ]]; then
            printf '%-24s %-28s %-8s %6s %6s %5s%% %14s %16s %s\n' \
                "$host" "$mount" "$type" "$(human_kb "$size")" "$(human_kb "$used")" \
                "$pct" "$growth_disp" "$days_disp" "$status"
        else
            local jhost jmount jfs jtype
            jhost="$(printf '%s' "$host" | json_escape)"
            jmount="$(printf '%s' "$mount" | json_escape)"
            jfs="$(printf '%s' "$fs" | json_escape)"
            jtype="$(printf '%s' "$type" | json_escape)"
            local jslope jdays
            [[ "$slope" == "NA" ]] && jslope=null || jslope="$slope"
            if [[ "$days_disp" == *" days" ]]; then jdays="${days_disp% days}"; else jdays=null; fi
            json_items+=("$(printf '{"host":"%s","mount":"%s","fs":"%s","type":"%s","size_kb":%d,"used_kb":%d,"avail_kb":%d,"use_pct":%d,"growth_kb_per_day":%s,"days_to_full":%s,"samples":%d,"status":"%s"}' \
                "$jhost" "$jmount" "$jfs" "$jtype" "$size" "$used" "$avail" "$pct" "$jslope" "$jdays" "$nsamples" "$status")")
        fi
    done <<< "$trend"

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        local IFS=,
        printf '{"generated_at":%d,"warn_percent":%d,"crit_percent":%d,"forecast_days":%d,"filesystems":[%s]}\n' \
            "$(date +%s)" "$WARN_PERCENT" "$CRIT_PERCENT" "$FORECAST_DAYS" "${json_items[*]}"
    fi

    [[ "$any_crit" -eq 0 ]] || return 4
    return 0
}

# ---------------------------------------------------------------------------
# --prune: drop samples older than --retention-days.
# ---------------------------------------------------------------------------
cmd_prune() {
    [[ -s "$STATE_FILE" ]] || die "No sample history found at $STATE_FILE — nothing to prune"

    local cutoff tmpfile before_count after_count
    cutoff=$(( $(date +%s) - RETENTION_DAYS * 86400 ))
    tmpfile="$(mktemp "$STATE_DIR/.samples.prune.XXXXXX")"

    awk -F',' -v cutoff="$cutoff" 'NR==1 || ($2+0) >= cutoff' "$STATE_FILE" > "$tmpfile"

    before_count=$(( $(wc -l < "$STATE_FILE") - 1 ))
    after_count=$(( $(wc -l < "$tmpfile") - 1 ))
    replace_locked "$tmpfile"

    log_info "Pruned samples older than $RETENTION_DAYS days: $before_count -> $after_count rows"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$ACTION" in
    sample) cmd_sample ;;
    report) cmd_report; exit $? ;;
    prune)  cmd_prune ;;
esac
```
