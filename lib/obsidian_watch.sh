#!/bin/bash
# Lifecycle watcher for the OCR daemon.
#
# Modes (from ~/.config/omarchy-ocr/mode or OMARCHY_OCR_MODE):
#   obsidian  run while at least one Obsidian window is open
#   schedule  run inside the configured time window (and days)
#   always    run always (the installer enables the daemon directly)
#
# In obsidian mode an optional schedule file additionally restricts the hours.
# The watcher listens to Hyprland events and re-checks the clock every 30 s.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SERVICE="${OMARCHY_OCR_SERVICE:-omarchy-ocr.service}"
PATTERN="${OMARCHY_OCR_WATCH_PATTERN:-obsidian}"

SOCK=""
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] \
  && SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

# Hyprland restarts change the instance signature, so re-resolve the socket
# whenever the current path is gone.
ensure_sock() {
  [[ -S $SOCK ]] && return 0
  local candidate
  candidate=$(ls -1t "$XDG_RUNTIME_DIR"/hypr/*/.socket2.sock 2>/dev/null | head -1)
  [[ -n $candidate ]] && SOCK=$candidate
  [[ -S $SOCK ]]
}

declare -A TRACKED=()

is_target() {
  [[ ${1,,} == *"${PATTERN,,}"* ]]
}

start_daemon() {
  systemctl --user -q is-active "$SERVICE" 2>/dev/null && return 0
  echo "start: $SERVICE (mode=$(ocr_mode))"
  systemctl --user start --no-block "$SERVICE" 2>/dev/null || true
}

stop_daemon() {
  systemctl --user -q is-active "$SERVICE" 2>/dev/null || return 0
  echo "stop: $SERVICE"
  systemctl --user stop "$SERVICE" 2>/dev/null || true
}

should_run() {
  case $(ocr_mode) in
    always) return 0 ;;
    schedule) ocr_within_window ;;
    obsidian) (( ${#TRACKED[@]} > 0 )) && ocr_within_window ;;
    *) return 1 ;;
  esac
}

apply_state() {
  if should_run; then
    start_daemon
  else
    stop_daemon
  fi
}

# Rebuild the window set from scratch (covers startup and Hyprland restarts).
sync_windows() {
  local addr class
  TRACKED=()
  while IFS=$'\t' read -r addr class; do
    [[ -z $addr ]] && continue
    is_target "$class" && TRACKED["${addr#0x}"]=1
  done < <(hyprctl clients -j 2>/dev/null \
    | jq -r '.[] | "\(.address)\t\(.class)"' 2>/dev/null)
}

if ! ocr_valid_schedule "$(ocr_schedule)"; then
  echo "warning: invalid schedule '$(ocr_schedule)', treating as no restriction" >&2
fi
if ! ocr_valid_days "$(ocr_days)"; then
  echo "warning: invalid days '$(ocr_days)', treating as all days" >&2
fi

while true; do
  if ! ensure_sock; then
    TRACKED=()
    apply_state
    sleep 30
    continue
  fi

  sync_windows
  apply_state

  # Hyprland emits many unrelated events, so a plain `read -t 30` would have
  # its timeout reset constantly. Wake every 5 s and re-check the clock on a
  # fixed 30 s cadence instead.
  last_check=$SECONDS
  while true; do
    if IFS= read -r -t 5 line; then
      case $line in
        openwindow\>\>*)
          IFS=, read -r addr _ class _ <<< "${line#openwindow>>}"
          addr=${addr#0x}
          if is_target "$class"; then
            TRACKED["$addr"]=1
            apply_state
          fi
          ;;
        closewindow\>\>*)
          addr=${line#closewindow>>}
          addr=${addr#0x}
          if [[ -n ${TRACKED[$addr]:-} ]]; then
            unset 'TRACKED[$addr]'
            apply_state
          fi
          ;;
      esac
    else
      rc=$?
      # >128 means read timed out; otherwise the socket closed.
      (( rc > 128 )) || break
    fi

    if (( SECONDS - last_check >= 30 )); then
      apply_state
      last_check=$SECONDS
    fi
  done < <(socat -U - UNIX-CONNECT:"$SOCK" 2>/dev/null)

  # Hyprland restarted or the socket died: reconnect shortly.
  sleep 2
done
