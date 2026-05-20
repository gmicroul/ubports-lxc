#!/usr/bin/env bash
# Legacy Fedora 42 CLI entry. The implementation lives in ut-lxc-desktop.sh.
exec sudo -n /home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh start -n fedora42 -d fedora -r 42 "$@"
