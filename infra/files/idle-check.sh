#!/bin/bash
# Runs every minute on the main server (mc-idle-check.timer).
# Puts the server to sleep (save, back up, power off) when nobody has been online for
# IDLE_MINUTES, or when Minecraft has been unresponsive for 30 minutes (so a crash
# can't keep the VM, and the bill, running forever).
set -uo pipefail
source /opt/mc/host.env   # IDLE_MINUTES, BACKUP_BUCKET

now=$(date +%s)
idle_file=/run/mc-idle-since       # /run is cleared on every boot
fail_file=/run/mc-unresponsive-since

sleep_now() {
  logger -t mc-idle "$1 - stopping Minecraft, backing up, powering off"
  systemctl stop minecraft
  /opt/mc/backup.sh || logger -t mc-idle "backup failed"
  shutdown -h now
}

since() { # seconds since the timestamp in file $1 (creating it now if missing)
  [[ -f $1 ]] || echo "$now" > "$1"
  echo $(( now - $(cat "$1") ))
}

if out=$(docker exec mc rcon-cli list 2>/dev/null) && [[ $out =~ There\ are\ ([0-9]+) ]]; then
  rm -f "$fail_file"
  players=${BASH_REMATCH[1]}
  if (( players > 0 )); then
    rm -f "$idle_file"
  elif (( $(since "$idle_file") >= IDLE_MINUTES * 60 )); then
    sleep_now "no players for $IDLE_MINUTES minutes"
  fi
else
  rm -f "$idle_file"
  if (( $(since "$fail_file") >= 30 * 60 )); then
    sleep_now "Minecraft unresponsive for 30 minutes"
  fi
fi
