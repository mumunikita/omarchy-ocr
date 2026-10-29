#!/bin/bash
# Start the OCR daemon when Obsidian opens, stop it when the last Obsidian
# window closes. Listens to Hyprland's event socket (socket2), so there is no
# polling: the watcher itself costs a few MB and does nothing most of the time.

set -uo pipefail

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
  echo "start: $SERVICE"
  systemctl --user start --no-block "$SERVICE" 2>/dev/null || true
}

stop_daemon() {
  echo "stop: $SERVICE"
  systemctl --user stop "$SERVICE" 2>/dev/null || true
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

  if (( ${#TRACKED[@]} > 0 )); then
    start_daemon
  else
    stop_daemon
  fi
}

while true; do
  if ! ensure_sock; then
    sleep 2
    continue
  fi

  sync_windows

  while IFS= read -r line; do
    case $line in
      openwindow\>\>*)
        IFS=, read -r addr _ class _ <<< "${line#openwindow>>}"
        if is_target "$class"; then
          (( ${#TRACKED[@]} == 0 )) && start_daemon
          TRACKED["$addr"]=1
        fi
        ;;
      closewindow\>\>*)
        addr=${line#closewindow>>}
        if [[ -n ${TRACKED[$addr]:-} ]]; then
          unset 'TRACKED[$addr]'
          (( ${#TRACKED[@]} == 0 )) && stop_daemon
        fi
        ;;
    esac
  done < <(socat -U - UNIX-CONNECT:"$SOCK" 2>/dev/null)

  # Hyprland restarted or the socket died: reconnect shortly.
  sleep 2
done
