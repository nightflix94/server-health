#!/usr/bin/env bash

set -Eeuo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--dry-run]" >&2
  exit 2
fi

: "${ALERT_COOLDOWN_SECONDS:=1800}"
: "${CPU_THRESHOLD_PERCENT:=90}"
: "${MEMORY_THRESHOLD_PERCENT:=90}"
: "${DISK_THRESHOLD_PERCENT:=85}"
: "${DISK_PATH:=/}"
: "${CURL_TIMEOUT_SECONDS:=15}"

STATE_DIR="${STATE_DIR:-${STATE_DIRECTORY:-/var/lib/server-health}}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

require_uint() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "$name must be a non-negative integer" >&2
    exit 1
  }
}

require_percent() {
  local name="$1" value="$2"
  require_uint "$name" "$value"
  (( value >= 1 && value <= 100 )) || {
    echo "$name must be between 1 and 100" >&2
    exit 1
  }
}

for command_name in awk curl date df hostname mkdir mv ps sleep; do
  require_command "$command_name"
done

require_uint ALERT_COOLDOWN_SECONDS "$ALERT_COOLDOWN_SECONDS"
require_uint CURL_TIMEOUT_SECONDS "$CURL_TIMEOUT_SECONDS"
require_percent CPU_THRESHOLD_PERCENT "$CPU_THRESHOLD_PERCENT"
require_percent MEMORY_THRESHOLD_PERCENT "$MEMORY_THRESHOLD_PERCENT"
require_percent DISK_THRESHOLD_PERCENT "$DISK_THRESHOLD_PERCENT"

if (( DRY_RUN == 0 )); then
  : "${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN in /etc/server-health.env}"
  : "${TELEGRAM_CHAT_ID:?Set TELEGRAM_CHAT_ID in /etc/server-health.env}"
fi

read_cpu_counters() {
  awk '/^cpu / {
    total = 0
    # guest and guest_nice are already included in user and nice, so stop at
    # steal to avoid counting guest CPU time twice.
    for (i = 2; i <= 9 && i <= NF; i++) total += $i
    idle = $5 + $6
    printf "%.0f %.0f\n", total, idle
    exit
  }' /proc/stat
}

format_kib() {
  awk -v kib="$1" 'BEGIN {
    if (kib >= 1048576) printf "%.1f GiB", kib / 1048576
    else printf "%.0f MiB", kib / 1024
  }'
}

format_uptime() {
  local total_seconds days hours minutes
  total_seconds="$(awk '{printf "%d", $1}' /proc/uptime)"
  days=$((total_seconds / 86400))
  hours=$(((total_seconds % 86400) / 3600))
  minutes=$(((total_seconds % 3600) / 60))

  if (( days > 0 )); then
    printf '%dd %dh %dm' "$days" "$hours" "$minutes"
  elif (( hours > 0 )); then
    printf '%dh %dm' "$hours" "$minutes"
  else
    printf '%dm' "$minutes"
  fi
}

service_for_pid() {
  local pid="$1"

  [[ -r "/proc/$pid/cgroup" ]] || return
  awk -F: '
    {
      count = split($NF, path, "/")
      for (i = count; i >= 1; i--) {
        if (path[i] ~ /\.service$/) {
          print path[i]
          exit
        }
      }
    }
  ' "/proc/$pid/cgroup" 2>/dev/null
}

format_top_cpu_processes() {
  local pid cpu command service found=0

  while read -r pid cpu command; do
    [[ -n "${pid:-}" ]] || continue
    service="$(service_for_pid "$pid" || true)"
    [[ -n "$service" ]] || service="no systemd service"
    printf '• %s%% %s — %s (PID %s)\n' "$cpu" "$command" "$service" "$pid"
    found=1
  done < <(ps -eo pid=,pcpu=,comm= --sort=-pcpu | awk 'NR <= 5')

  (( found == 1 )) || printf 'Process information unavailable\n'
}

read_state() {
  local name="$1" fallback="$2" value
  if [[ -r "$STATE_DIR/$name" ]]; then
    value="$(<"$STATE_DIR/$name")"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s' "$value"
      return
    fi
  fi
  printf '%s' "$fallback"
}

write_state() {
  local name="$1" value="$2" temporary
  (( DRY_RUN == 1 )) && return
  temporary="$STATE_DIR/.${name}.$$"
  printf '%s\n' "$value" >"$temporary"
  mv -f "$temporary" "$STATE_DIR/$name"
}

send_telegram() {
  local message="$1"
  if (( DRY_RUN == 1 )); then
    printf '%s\n' "$message"
    return
  fi

  # Pass the token through curl's standard input so it is not exposed in the
  # curl process command line.
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
    curl --config - \
      --fail \
      --silent \
      --show-error \
      --max-time "$CURL_TIMEOUT_SECONDS" \
      --retry 2 \
      --request POST \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$message" \
      >/dev/null
}

if (( DRY_RUN == 0 )); then
  mkdir -p "$STATE_DIR"
fi

read -r cpu_total_before cpu_idle_before < <(read_cpu_counters)
sleep 1
read -r cpu_total_after cpu_idle_after < <(read_cpu_counters)

cpu_percent="$(awk \
  -v total_before="$cpu_total_before" \
  -v idle_before="$cpu_idle_before" \
  -v total_after="$cpu_total_after" \
  -v idle_after="$cpu_idle_after" \
  'BEGIN {
    total_delta = total_after - total_before
    idle_delta = idle_after - idle_before
    if (total_delta <= 0) print "0.0"
    else printf "%.1f", 100 * (total_delta - idle_delta) / total_delta
  }')"

load_average="$(awk '{print $1 " " $2 " " $3}' /proc/loadavg)"

read -r memory_total_kib memory_available_kib < <(
  awk '
    /^MemTotal:/ { total = $2 }
    /^MemAvailable:/ { available = $2 }
    END { print total, available }
  ' /proc/meminfo
)
memory_used_kib=$((memory_total_kib - memory_available_kib))
memory_percent="$(awk -v used="$memory_used_kib" -v total="$memory_total_kib" \
  'BEGIN { printf "%.1f", 100 * used / total }')"

read -r disk_total_kib disk_used_kib disk_available_kib disk_percent < <(
  df -Pk "$DISK_PATH" | awk 'NR == 2 {
    gsub(/%/, "", $5)
    print $2, $3, $4, $5
  }'
)

[[ -n "${disk_percent:-}" ]] || {
  echo "Could not read disk usage for $DISK_PATH" >&2
  exit 1
}

if host_name="$(hostname -f 2>/dev/null)" && [[ -n "$host_name" ]]; then
  :
else
  host_name="$(hostname)"
fi

now_epoch="$(date +%s)"
observed_at="$(date -Iseconds)"
uptime_text="$(format_uptime)"
memory_used_text="$(format_kib "$memory_used_kib")"
memory_total_text="$(format_kib "$memory_total_kib")"
disk_used_text="$(format_kib "$disk_used_kib")"
disk_total_text="$(format_kib "$disk_total_kib")"

alert_reasons=()
cpu_alerting=0
if awk -v actual="$cpu_percent" -v limit="$CPU_THRESHOLD_PERCENT" \
  'BEGIN { exit !(actual >= limit) }'; then
  alert_reasons+=("🔥 CPU ${cpu_percent}% >= ${CPU_THRESHOLD_PERCENT}%")
  cpu_alerting=1
fi
awk -v actual="$memory_percent" -v limit="$MEMORY_THRESHOLD_PERCENT" \
  'BEGIN { exit !(actual >= limit) }' && alert_reasons+=("🧠 RAM ${memory_percent}% >= ${MEMORY_THRESHOLD_PERCENT}%")
(( disk_percent >= DISK_THRESHOLD_PERCENT )) && \
  alert_reasons+=("💾 Disk ${disk_percent}% >= ${DISK_THRESHOLD_PERCENT}%")

metrics="Host: $host_name
Time: $observed_at
CPU: ${cpu_percent}%
Load (1/5/15m): $load_average
RAM: $memory_used_text / $memory_total_text (${memory_percent}%)
Disk $DISK_PATH: $disk_used_text / $disk_total_text (${disk_percent}%)
Uptime: $uptime_text"

last_alert="$(read_state last_alert 0)"
was_alerting="$(read_state was_alerting 0)"

if (( DRY_RUN == 1 )); then
  last_alert=0
  was_alerting=0
fi

if (( ${#alert_reasons[@]} > 0 )); then
  if (( was_alerting == 0 || now_epoch - last_alert >= ALERT_COOLDOWN_SECONDS )); then
    reason_text="$(printf '%s; ' "${alert_reasons[@]}")"
    reason_text="${reason_text%; }"
    cpu_details=""
    if (( cpu_alerting == 1 )); then
      cpu_details="

Top CPU consumers (snapshot):
$(format_top_cpu_processes)"
    fi
    send_telegram "🚨 SERVER ALERT
$reason_text$cpu_details

$metrics"
    write_state last_alert "$now_epoch"
    write_state was_alerting 1
  fi
elif (( was_alerting == 1 )); then
  send_telegram "✅ SERVER RECOVERED
All monitored values are below their thresholds.

$metrics"
  write_state was_alerting 0
fi
