#!/usr/bin/env bash
# Compatibility wrapper. Old restore script used port 32015 and is retired.
# Use the generic manager and the stable PulseAudio relay on 32016.
exec /home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh start -n fedora42 -d fedora -r 42 "$@"
