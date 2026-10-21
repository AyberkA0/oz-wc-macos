#!/bin/bash
# Oz WC trackpad setup.
#
#   apply    3-finger vertical swipe -> free for Oz (Mission Control / App Exposé move to 4 fingers)
#   restore  put back the values saved by `apply`
#   status   show the current values
#
# Mission Control stays reachable: 4-finger swipe up, F3, and Oz's 3-finger double tap.
set -euo pipefail

BACKUP="$HOME/.config/oz/trackpad-backup.txt"
DOMAINS=(com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad)

read_val() { defaults read "$1" "$2" 2>/dev/null || echo "unset"; }
read_host() { defaults -currentHost read NSGlobalDomain "$1" 2>/dev/null || echo "unset"; }

refresh() {
  local tool=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings
  [ -x "$tool" ] && "$tool" -u >/dev/null 2>&1 || true
  killall Dock >/dev/null 2>&1 || true
}

status() {
  for d in "${DOMAINS[@]}"; do
    echo "$d ThreeFingerVert=$(read_val "$d" TrackpadThreeFingerVertSwipeGesture) FourFingerVert=$(read_val "$d" TrackpadFourFingerVertSwipeGesture)"
  done
  echo "currentHost threeFingerVert=$(read_host com.apple.trackpad.threeFingerVertSwipeGesture) fourFingerVert=$(read_host com.apple.trackpad.fourFingerVertSwipeGesture)"
  echo "dock missionControlGesture=$(read_val com.apple.dock showMissionControlGestureEnabled) appExposeGesture=$(read_val com.apple.dock showAppExposeGestureEnabled)"
}

write_int() { # domain key value ("unset" deletes)
  if [ "$3" = "unset" ]; then defaults delete "$1" "$2" >/dev/null 2>&1 || true
  else defaults write "$1" "$2" -int "$3"; fi
}
write_host() {
  if [ "$2" = "unset" ]; then defaults -currentHost delete NSGlobalDomain "$1" >/dev/null 2>&1 || true
  else defaults -currentHost write NSGlobalDomain "$1" -int "$2"; fi
}

case "${1:-status}" in
  apply)
    mkdir -p "$(dirname "$BACKUP")"
    if [ ! -f "$BACKUP" ]; then
      {
        for d in "${DOMAINS[@]}"; do
          echo "$d TrackpadThreeFingerVertSwipeGesture $(read_val "$d" TrackpadThreeFingerVertSwipeGesture)"
          echo "$d TrackpadFourFingerVertSwipeGesture $(read_val "$d" TrackpadFourFingerVertSwipeGesture)"
        done
        echo "host com.apple.trackpad.threeFingerVertSwipeGesture $(read_host com.apple.trackpad.threeFingerVertSwipeGesture)"
        echo "host com.apple.trackpad.fourFingerVertSwipeGesture $(read_host com.apple.trackpad.fourFingerVertSwipeGesture)"
      } > "$BACKUP"
    fi
    for d in "${DOMAINS[@]}"; do
      defaults write "$d" TrackpadThreeFingerVertSwipeGesture -int 0
      defaults write "$d" TrackpadFourFingerVertSwipeGesture -int 2
    done
    defaults -currentHost write NSGlobalDomain com.apple.trackpad.threeFingerVertSwipeGesture -int 0
    defaults -currentHost write NSGlobalDomain com.apple.trackpad.fourFingerVertSwipeGesture -int 2
    defaults write com.apple.dock showMissionControlGestureEnabled -bool true
    defaults write com.apple.dock showAppExposeGestureEnabled -bool true
    refresh
    echo "applied: 3-finger vertical swipe is free; Mission Control = 4-finger swipe up / F3 / Oz 3-finger double tap"
    ;;
  restore)
    if [ -f "$BACKUP" ]; then
      while read -r domain key value; do
        if [ "$domain" = "host" ]; then write_host "$key" "$value"; else write_int "$domain" "$key" "$value"; fi
      done < "$BACKUP"
      rm -f "$BACKUP"
    else
      for d in "${DOMAINS[@]}"; do defaults write "$d" TrackpadThreeFingerVertSwipeGesture -int 2; done
      defaults -currentHost write NSGlobalDomain com.apple.trackpad.threeFingerVertSwipeGesture -int 2
    fi
    refresh
    echo "restored"
    ;;
  status) status ;;
  *) echo "usage: $0 apply|restore|status" >&2; exit 1 ;;
esac
