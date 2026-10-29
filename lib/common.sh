#!/bin/bash
# Shared configuration and schedule helpers for omarchy-ocr.
# Sourced by omarchy-capture-formula and the lifecycle watcher.

ocr_conf_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-ocr"
}

ocr_mode() {
  local mode="${OMARCHY_OCR_MODE:-}"
  if [[ -z $mode ]]; then
    mode=$(cat "$(ocr_conf_dir)/mode" 2>/dev/null || true)
  fi
  printf '%s\n' "${mode:-obsidian}"
}

ocr_schedule() {
  local value="${OMARCHY_OCR_SCHEDULE:-}"
  if [[ -z $value ]]; then
    value=$(cat "$(ocr_conf_dir)/schedule" 2>/dev/null || true)
  fi
  printf '%s\n' "$value"
}

ocr_days() {
  local value="${OMARCHY_OCR_SCHEDULE_DAYS:-}"
  if [[ -z $value ]]; then
    value=$(cat "$(ocr_conf_dir)/days" 2>/dev/null || true)
  fi
  printf '%s\n' "${value:-1-7}"
}

ocr_minutes() {
  local value=$1 h m
  [[ $value =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=${BASH_REMATCH[1]}
  m=${BASH_REMATCH[2]}
  (( 10#$h <= 23 && 10#$m <= 59 )) || return 1
  printf '%s\n' $((10#$h * 60 + 10#$m))
}

ocr_now_minutes() {
  local now="${OCR_NOW:-$(date +%H:%M)}" minutes
  if minutes=$(ocr_minutes "$now"); then
    printf '%s\n' "$minutes"
  else
    ocr_minutes "$(date +%H:%M)"
  fi
}

ocr_day_in_spec() {
  local today=$1 spec part start end
  local -a parts

  [[ $today =~ ^[1-7]$ ]] || return 0
  today=$((10#$today))

  spec=$(ocr_days)
  # A malformed days spec means "all days" rather than "never".
  ocr_valid_days "$spec" || return 0
  IFS=, read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    part=${part// /}
    [[ -z $part ]] && continue
    if [[ $part == *-* ]]; then
      start=${part%-*}
      end=${part#*-}
      if (( today >= 10#$start && today <= 10#$end )); then
        return 0
      fi
    elif (( today == 10#$part )); then
      return 0
    fi
  done
  return 1
}

ocr_in_days() {
  ocr_day_in_spec "${OCR_TODAY:-$(date +%u)}"
}

ocr_in_schedule() {
  local schedule start end start_m end_m now

  schedule=$(ocr_schedule)
  [[ -z $schedule ]] && return 0

  start=${schedule%-*}
  end=${schedule#*-}
  start_m=$(ocr_minutes "$start") || return 0
  end_m=$(ocr_minutes "$end") || return 0
  now=$(ocr_now_minutes) || return 0

  if (( start_m <= end_m )); then
    (( now >= start_m && now < end_m ))
  else
    # Overnight window, e.g. 22:00-06:00.
    (( now >= start_m || now < end_m ))
  fi
}

ocr_within_window() {
  local schedule start end start_m end_m now today

  schedule=$(ocr_schedule)
  if [[ -n $schedule ]]; then
    start=${schedule%-*}
    end=${schedule#*-}
    if start_m=$(ocr_minutes "$start") \
       && end_m=$(ocr_minutes "$end") \
       && now=$(ocr_now_minutes); then
      today=${OCR_TODAY:-$(date +%u)}
      [[ $today =~ ^[1-7]$ ]] || today=$(date +%u)
      today=$((10#$today))
      # The after-midnight part of an overnight window belongs to the day
      # the window started, e.g. Friday 23:00-06:00 includes Saturday 02:00.
      if (( start_m > end_m && now < end_m )); then
        today=$(( (today + 5) % 7 + 1 ))
      fi
      ocr_day_in_spec "$today" || return 1
    else
      ocr_in_days || return 1
    fi
  else
    ocr_in_days || return 1
  fi

  ocr_in_schedule
}

ocr_valid_schedule() {
  local schedule=$1 start end
  [[ -z $schedule ]] && return 0
  [[ $schedule =~ ^[0-9]{1,2}:[0-9]{2}-[0-9]{1,2}:[0-9]{2}$ ]] || return 1
  start=${schedule%-*}
  end=${schedule#*-}
  ocr_minutes "$start" >/dev/null && ocr_minutes "$end" >/dev/null
}

ocr_valid_days() {
  local spec=$1 part start end
  local -a parts
  [[ -z $spec ]] && return 0
  [[ $spec =~ ^[1-7](-[1-7])?(,[1-7](-[1-7])?)*$ ]] || return 1
  IFS=, read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    if [[ $part == *-* ]]; then
      start=${part%-*}
      end=${part#*-}
      (( 10#$start <= 10#$end )) || return 1
    fi
  done
}
