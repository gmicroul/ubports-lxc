#!/usr/bin/env bash
# Legacy Fedora 42 launcher. Keep this file for old .desktop entries, but run the generic manager.
set -u
LOG_DIR="/home/phablet/.cache/ubports-lxc/logs"
SCRIPT="/home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh"
mkdir -p "$LOG_DIR"
log="$LOG_DIR/fedora42-launcher.log"
rm -f "$log"
{
  sudo -n "$SCRIPT" start -n fedora42 -d fedora -r 42 2>&1
} | tee "$log"
