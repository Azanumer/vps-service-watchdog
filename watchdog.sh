#!/usr/bin/env bash
# vps-service-watchdog — keep your systemd services alive.
#
# Checks every service listed in the config file, restarts any that are
# down, and alerts you when a service will not stay up. Restart attempts
# are capped per hour so a broken service cannot spin in a restart loop.
#
# Usage:
#   watchdog.sh [--config FILE] [--state-dir DIR] [--log FILE]
#               [--to EMAIL] [--check-only] [--interval SECONDS]
#
#   --config FILE      Service list (default: /etc/service-watchdog/services.conf)
#   --state-dir DIR    Where restart counters live (default: /var/lib/service-watchdog)
#   --log FILE         Log file (default: /var/log/service-watchdog.log)
#   --to EMAIL         Mail restart/failure alerts to this address (uses `mail`)
#   --check-only       Report what is down without restarting anything
#   --interval SECONDS Run forever, checking every N seconds (default: run once)
#   --help             Show this help
#
# Config format — one service per line, `#` comments allowed:
#   nginx
#   php8.2-fpm
#   mysql:5            # at most 5 restarts per hour for this service
#
# Exit codes: 0 = all healthy (or all restarts succeeded),
#             1 = at least one service is still down,
#             2 = configuration / environment error.
set -u

CONFIG="/etc/service-watchdog/services.conf"
STATE_DIR="/var/lib/service-watchdog"
LOG_FILE="/var/log/service-watchdog.log"
MAIL_TO=""
CHECK_ONLY=0
INTERVAL=0
DEFAULT_MAX_RESTARTS=3

usage() {
    sed -n '2,27p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)    CONFIG="$2"; shift 2 ;;
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --log)       LOG_FILE="$2"; shift 2 ;;
        --to)        MAIL_TO="$2"; shift 2 ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --interval)  INTERVAL="$2"; shift 2 ;;
        --help|-h)   usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 2 ;;
    esac
done

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found — this script needs systemd." >&2
    exit 2
fi
if [[ ! -r "$CONFIG" ]]; then
    echo "Config file not readable: $CONFIG" >&2
    echo "Create it (see services.conf.example) or pass --config." >&2
    exit 2
fi
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "Cannot create state dir: $STATE_DIR" >&2
    exit 2
fi
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "Cannot write log file: $LOG_FILE" >&2
    exit 2
fi

log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}

alert() {
    local subject="$1"; shift
    log "ALERT" "$subject — $*"
    if [[ -n "$MAIL_TO" ]] && command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$*" | mail -s "[watchdog] $subject" "$MAIL_TO" 2>/dev/null || true
    fi
}

# Count restarts of $1 in the last hour, from its state file.
restarts_this_hour() {
    local service="$1"
    local state_file="$STATE_DIR/${service}.restarts"
    local now cutoff count=0
    now=$(date +%s)
    cutoff=$(( now - 3600 ))
    [[ -f "$state_file" ]] || { echo 0; return 0; }
    # Drop entries older than one hour, keep the rest.
    local tmp
    tmp=$(mktemp)
    while read -r ts; do
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        if (( ts >= cutoff )); then
            echo "$ts" >> "$tmp"
            count=$(( count + 1 ))
        fi
    done < "$state_file"
    mv "$tmp" "$state_file"
    echo "$count"
}

record_restart() {
    date +%s >> "$STATE_DIR/${1}.restarts"
}

# Check one service. Returns 0 if healthy (or restarted OK), 1 if still down.
check_service() {
    local service="$1" max_restarts="$2"
    local status

    if systemctl is-active --quiet "$service"; then
        return 0
    fi
    # is-active prints the state (inactive/failed/…) even when it exits non-zero.
    status=$(systemctl is-active "$service" 2>/dev/null)
    status=${status:-unknown}

    if (( CHECK_ONLY )); then
        log "WARN" "$service is $status (check-only, not restarting)"
        return 1
    fi

    local count
    count=$(restarts_this_hour "$service")
    if (( count >= max_restarts )); then
        alert "$service is DOWN" "Status: $status. Already restarted $count time(s) this hour (cap $max_restarts) — not restarting again. Fix it manually."
        return 1
    fi

    log "WARN" "$service is $status — restarting (attempt $(( count + 1 ))/$max_restarts this hour)"
    record_restart "$service"

    if systemctl restart "$service" 2>>"$LOG_FILE"; then
        sleep 2
        if systemctl is-active --quiet "$service"; then
            log "OK" "$service restarted successfully"
            alert "$service restarted" "Service $service was $status and is running again after a watchdog restart."
            return 0
        fi
    fi

    local after_status
    after_status=$(systemctl is-active "$service" 2>/dev/null)
    after_status=${after_status:-unknown}
    alert "$service restart FAILED" "Status after restart attempt: $after_status. Check: systemctl status $service / journalctl -u $service"
    return 1
}

# Parse the config into "service:max" pairs, skipping blanks and comments.
read_services() {
    local line service max
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                       # strip comment
        line="${line#"${line%%[![:space:]]*}"}"   # trim leading space
        line="${line%"${line##*[![:space:]]}"}"   # trim trailing space
        [[ -z "$line" ]] && continue
        if [[ "$line" == *:* ]]; then
            service="${line%%:*}"
            max="${line##*:}"
            [[ "$max" =~ ^[0-9]+$ ]] || max="$DEFAULT_MAX_RESTARTS"
        else
            service="$line"
            max="$DEFAULT_MAX_RESTARTS"
        fi
        printf '%s:%s\n' "$service" "$max"
    done < "$CONFIG"
}

run_once() {
    local failed=0 entry service max
    while IFS=: read -r service max; do
        [[ -n "$service" ]] || continue
        if ! check_service "$service" "$max"; then
            failed=1
        fi
    done < <(read_services)
    return "$failed"
}

# Single-instance lock so overlapping cron runs cannot restart twice.
exec 9>"$STATE_DIR/watchdog.lock"
if ! flock -n 9; then
    log "WARN" "Another watchdog run is already active — exiting"
    exit 0
fi

if (( INTERVAL > 0 )); then
    log "INFO" "Watchdog started in loop mode (every ${INTERVAL}s, config: $CONFIG)"
    while true; do
        run_once || true
        sleep "$INTERVAL"
    done
else
    run_once
    exit $?
fi
