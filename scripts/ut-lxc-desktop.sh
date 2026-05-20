#!/usr/bin/env bash
# Universal Ubuntu Touch LXC desktop manager v3
# Supports Fedora/Ubuntu/Debian containers on UT 26.04 by generating LXC config,
# installing desktop packages, relaying PulseAudio, and launching XFCE over X11.

set -u

VERSION="v3"
DEFAULT_CONTAINER="fedora42"
DEFAULT_DISTRO="fedora"
DEFAULT_RELEASE="42"
DEFAULT_ARCH="arm64"
DEFAULT_USER="phablet"
DEFAULT_UID="32011"
DEFAULT_DESKTOP="xfce"
DEFAULT_PORT="32016"
DEFAULT_DISPLAY=":0"
NESTED_DISPLAY=":20"
NESTED_GEOMETRY="${UT_LXC_NESTED_GEOMETRY:-1280x720}"
NESTED_DPI="${UT_LXC_NESTED_DPI:-168}"
NESTED_FULLSCREEN="${UT_LXC_NESTED_FULLSCREEN:-1}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="/home/phablet/.cache/ubports-lxc"
LOG_DIR="$CACHE_DIR/logs"

CONTAINER="${UT_LXC_CONTAINER:-$DEFAULT_CONTAINER}"
DISTRO="${UT_LXC_DISTRO:-$DEFAULT_DISTRO}"
RELEASE="${UT_LXC_RELEASE:-$DEFAULT_RELEASE}"
ARCH="${UT_LXC_ARCH:-$DEFAULT_ARCH}"
DESKTOP="${UT_LXC_DESKTOP:-$DEFAULT_DESKTOP}"
CONTAINER_USER="${UT_LXC_USER:-$DEFAULT_USER}"
CONTAINER_UID="${UT_LXC_UID:-$DEFAULT_UID}"
PULSE_TCP_PORT="${UT_LXC_PULSE_PORT:-$DEFAULT_PORT}"
DISPLAY_NUM="${UT_LXC_DISPLAY:-$DEFAULT_DISPLAY}"
DISPLAY_MODE="${UT_LXC_DISPLAY_MODE:-direct}"
if [ "$DISPLAY_MODE" = "xephyr" ] && [ "$DISPLAY_NUM" = "$DEFAULT_DISPLAY" ]; then DISPLAY_NUM="$NESTED_DISPLAY"; fi
ROOTFS_BASE="/var/lib/lxc"

usage() {
    cat <<EOF
Ubuntu Touch LXC Desktop Manager $VERSION

Usage:
  $0 COMMAND [options]

Commands:
  create        Create a new LXC container with download template
  configure     Generate/install generic UT-compatible LXC config and hook
  install       Install desktop packages and user setup inside container
  repair        Repair /dev nodes and finish interrupted package configuration
  sudoers       Install NOPASSWD sudoers rule for this manager
  bootstrap     Install lxc-create wrapper so future containers are auto-configured
  start         Start container, relay audio, launch desktop
  stop          Stop desktop session, Xephyr window, audio relay, and container
  doctor        Check host/container/display/audio state
  desktop-file  Install Lomiri app drawer entry for this container
  all           create + configure + install + sudoers + desktop-file

Options:
  -n, --name NAME        Container name (default: $DEFAULT_CONTAINER)
  -d, --distro DISTRO    fedora|ubuntu|debian (default: $DEFAULT_DISTRO)
  -r, --release RELEASE  Release, e.g. 42, noble, trixie (default: $DEFAULT_RELEASE)
  -a, --arch ARCH        arm64/aarch64 (default: $DEFAULT_ARCH)
  -u, --user USER        Desktop user inside container (default: $DEFAULT_USER)
  --uid UID              Desktop user uid/gid (default: $DEFAULT_UID)
  --desktop NAME         xfce currently supported (default: xfce)
  --port PORT            PulseAudio relay TCP port (default: $DEFAULT_PORT)
  --display DISPLAY      X11 display (default: $DEFAULT_DISPLAY)
  --display-mode MODE    direct|xephyr (default: direct)
  --nested               Shortcut for --display-mode xephyr
  --nested-size WxH      Xephyr screen size (default: $NESTED_GEOMETRY)
  --nested-dpi DPI       Xephyr DPI (default: $NESTED_DPI)
  --nested-fullscreen 0|1 Xephyr fullscreen hint (default: $NESTED_FULLSCREEN)
  -h, --help             Show this help
EOF
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_root_for() {
    case "$1" in
        create|configure|install|repair|sudoers|bootstrap|start|stop|all) [ "$(id -u)" = "0" ] || fail "'$1' needs root. Run: sudo $0 $1 ..." ;;
    esac
}

run_root() {
    if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi
}

container_rootfs() { printf '%s/%s/rootfs' "$ROOTFS_BASE" "$CONTAINER"; }
container_config() { printf '%s/%s/config' "$ROOTFS_BASE" "$CONTAINER"; }
hook_path() { printf '%s/%s/ut-desktop-hook.sh' "$ROOTFS_BASE" "$CONTAINER"; }
pidfile() { printf '/tmp/ut-lxc-pulse-%s-%s.pid' "$CONTAINER" "$PULSE_TCP_PORT"; }
xephyr_pidfile() { printf '/tmp/ut-lxc-xephyr-%s.pid' "$CONTAINER"; }

normalize_arch() { [ "$ARCH" = "aarch64" ] && ARCH="arm64"; }

parse_args() {
    COMMAND="${1:-}"
    [ -n "$COMMAND" ] || { usage; exit 1; }
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--name) CONTAINER="$2"; shift 2 ;;
            -d|--distro) DISTRO="$2"; shift 2 ;;
            -r|--release) RELEASE="$2"; shift 2 ;;
            -a|--arch) ARCH="$2"; shift 2 ;;
            -u|--user) CONTAINER_USER="$2"; shift 2 ;;
            --uid) CONTAINER_UID="$2"; shift 2 ;;
            --desktop) DESKTOP="$2"; shift 2 ;;
            --port) PULSE_TCP_PORT="$2"; shift 2 ;;
            --display) DISPLAY_NUM="$2"; shift 2 ;;
            --display-mode) DISPLAY_MODE="$2"; [ "$DISPLAY_MODE" = "xephyr" ] && [ "$DISPLAY_NUM" = "$DEFAULT_DISPLAY" ] && DISPLAY_NUM="$NESTED_DISPLAY"; shift 2 ;;
            --nested) DISPLAY_MODE="xephyr"; [ "$DISPLAY_NUM" = "$DEFAULT_DISPLAY" ] && DISPLAY_NUM="$NESTED_DISPLAY"; shift ;;
            --nested-size) NESTED_GEOMETRY="$2"; shift 2 ;;
            --nested-dpi) NESTED_DPI="$2"; shift 2 ;;
            --nested-fullscreen) NESTED_FULLSCREEN="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) fail "Unknown option: $1" ;;
        esac
    done
    normalize_arch
}

lxc_running() { lxc-info -n "$CONTAINER" -s 2>/dev/null | tr -d '\n' | grep -q RUNNING; }

wait_running() {
    local i
    for i in 1 2 3 4 5; do
        if run_root lxc-info -n "$CONTAINER" -s 2>/dev/null | tr -d '\n' | grep -q RUNNING; then return 0; fi
        sleep 3
    done
    return 1
}

get_container_pid() { run_root lxc-info -n "$CONTAINER" -p 2>/dev/null | grep -oE '[0-9]+' | head -1; }

cmd_create() {
    need_root_for create
    have lxc-create || fail "lxc-create not found"
    if [ -d "$ROOTFS_BASE/$CONTAINER" ]; then log "Container exists: $CONTAINER"; return 0; fi
    log "Creating container: name=$CONTAINER distro=$DISTRO release=$RELEASE arch=$ARCH"
    lxc-create -n "$CONTAINER" -t download -- -d "$DISTRO" -r "$RELEASE" -a "$ARCH"
}

write_hook() {
    local hook
    hook="$(hook_path)"
    mkdir -p "$(dirname "$hook")"
    cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
set -u
CONTAINER_NAME="${LXC_NAME:-__CONTAINER__}"
ROOTFS="/var/lib/lxc/${CONTAINER_NAME}/rootfs"
UT_UID="__UID__"
HOST_X11="/tmp/.X11-unix"
HOST_WAYLAND="/run/user/${UT_UID}/wayland-0"
HOST_WAYLAND_LOCK="/run/user/${UT_UID}/wayland-0.lock"
# Do not expose the host system bus into containers.
# Exposing /run/dbus/system_bus_socket lets desktop applets inside the container
# talk to host NetworkManager/UPower/logind and can break WiFi on Ubuntu Touch.
make_dev_nodes() {
  mkdir -p "${ROOTFS}/dev"
  rm -f "${ROOTFS}/dev/null" "${ROOTFS}/dev/zero" "${ROOTFS}/dev/random" "${ROOTFS}/dev/urandom"
  mknod -m 666 "${ROOTFS}/dev/null" c 1 3 2>/dev/null || true
  mknod -m 666 "${ROOTFS}/dev/zero" c 1 5 2>/dev/null || true
  mknod -m 666 "${ROOTFS}/dev/random" c 1 8 2>/dev/null || true
  mknod -m 666 "${ROOTFS}/dev/urandom" c 1 9 2>/dev/null || true
  chmod 666 "${ROOTFS}/dev/null" "${ROOTFS}/dev/zero" "${ROOTFS}/dev/random" "${ROOTFS}/dev/urandom" 2>/dev/null || true
}
case "${1:-}" in
  pre-start)
    mkdir -p "${ROOTFS}/tmp/.X11-unix"
    if [ -S "${HOST_X11}/X0" ] || [ -e "${HOST_X11}/X0" ]; then
      rm -f "${ROOTFS}/tmp/.X11-unix/X0"
      cp -a "${HOST_X11}/X0" "${ROOTFS}/tmp/.X11-unix/X0" 2>/dev/null || true
      chmod 777 "${ROOTFS}/tmp/.X11-unix/X0" 2>/dev/null || true
    fi
    mkdir -p "${ROOTFS}/run/user/${UT_UID}"
    rm -f "${ROOTFS}/run/user/${UT_UID}/wayland-0" "${ROOTFS}/run/user/${UT_UID}/wayland-0.lock"
    [ -e "${HOST_WAYLAND}" ] && cp -a "${HOST_WAYLAND}" "${ROOTFS}/run/user/${UT_UID}/wayland-0" 2>/dev/null || true
    [ -e "${HOST_WAYLAND_LOCK}" ] && cp -a "${HOST_WAYLAND_LOCK}" "${ROOTFS}/run/user/${UT_UID}/wayland-0.lock" 2>/dev/null || true
    chmod 777 "${ROOTFS}/run/user/${UT_UID}" "${ROOTFS}/run/user/${UT_UID}/wayland-0" "${ROOTFS}/run/user/${UT_UID}/wayland-0.lock" 2>/dev/null || true
    rm -f "${ROOTFS}/run/dbus/system_bus_socket"
    make_dev_nodes
    ;;
  post-stop)
    rm -rf "${ROOTFS}/tmp/.X11-unix"
    rm -f "${ROOTFS}/run/user/${UT_UID}/wayland-0" "${ROOTFS}/run/user/${UT_UID}/wayland-0.lock"
    rm -f "${ROOTFS}/run/dbus/system_bus_socket"
    ;;
esac
exit 0
HOOK
    sed -i "s/__CONTAINER__/$CONTAINER/g; s/__UID__/$CONTAINER_UID/g" "$hook"
    chmod 755 "$hook"
}

cmd_configure() {
    need_root_for configure
    [ -d "$ROOTFS_BASE/$CONTAINER/rootfs" ] || fail "Container rootfs not found: $ROOTFS_BASE/$CONTAINER/rootfs. Run create first."
    write_hook
    local cfg
    cfg="$(container_config)"
    cat > "$cfg" <<EOF
# Generic Ubuntu Touch LXC desktop config
# Generated by ubports-lxc/scripts/ut-lxc-desktop.sh $VERSION

lxc.rootfs.path = /var/lib/lxc/$CONTAINER/rootfs
lxc.uts.name = $CONTAINER
lxc.log.level = 3
lxc.log.file = /tmp/$CONTAINER.log
lxc.net.0.type = none
lxc.namespace.keep = net user
lxc.tty.dir = lxc
lxc.tty.max = 4
lxc.pty.max = 1024
lxc.idmap = u 0 0 65536
lxc.idmap = g 0 0 65536
lxc.apparmor.profile = unconfined
lxc.cap.drop = mac_admin mac_override net_admin net_raw
lxc.autodev = 0
lxc.cgroup2.devices.deny = a
# GPU/display devices on Ubuntu Touch / Snapdragon 845:
# - 226:* = DRM/KMS display nodes (/dev/dri/*)
# - 237:* = KGSL Adreno GPU node (/dev/kgsl-3d0)
lxc.cgroup2.devices.allow = c 226:* rwm
lxc.cgroup2.devices.allow = c 237:* rwm
lxc.hook.pre-start = $(hook_path) pre-start
lxc.hook.post-stop = $(hook_path) post-stop
lxc.mount.entry = proc proc proc nodev,noexec,nosuid 0 0
lxc.mount.entry = sys sys sysfs nodev,noexec,nosuid 0 0
lxc.mount.entry = tmpfs dev tmpfs nosuid,mode=0755 0 0
lxc.mount.entry = /dev/null dev/null none bind,create=file 0 0
lxc.mount.entry = /dev/zero dev/zero none bind,create=file 0 0
lxc.mount.entry = /dev/random dev/random none bind,create=file 0 0
lxc.mount.entry = /dev/urandom dev/urandom none bind,create=file 0 0
lxc.mount.entry = dev/pts dev/pts devpts gid=5,mode=620,create=dir 0 0
lxc.mount.entry = dev/shm dev/shm tmpfs nosuid,nodev,create=dir 0 0
lxc.mount.entry = dev/mqueue dev/mqueue mqueue nodev,nosuid,noexec,create=dir 0 0
lxc.mount.entry = /dev/dri dev/dri none bind,create=dir,optional 0 0
lxc.mount.entry = /dev/kgsl-3d0 dev/kgsl-3d0 none bind,create=file,optional 0 0
lxc.mount.entry = /dev/input dev/input none bind,create=dir,optional 0 0
lxc.mount.entry = /sys/devices/system/cpu sys/devices/system/cpu none bind,ro,create=dir,optional 0 0
lxc.mount.entry = /sys/class/drm sys/class/drm none bind,ro,create=dir,optional 0 0
lxc.mount.entry = /sys/dev/char sys/dev/char none bind,ro,create=dir,optional 0 0
lxc.mount.entry = /sys/devices/platform/soc/ae00000.qcom,mdss_mdp sys/devices/platform/soc/ae00000.qcom,mdss_mdp none bind,ro,create=dir,optional 0 0
lxc.mount.entry = /sys/devices/platform/soc/5000000.qcom,kgsl-3d0 sys/devices/platform/soc/5000000.qcom,kgsl-3d0 none bind,ro,create=dir,optional 0 0
lxc.mount.entry = /sys/kernel/gpu sys/kernel/gpu none bind,ro,create=dir,optional 0 0
lxc.mount.entry = $REPO_DIR ubuntu none bind,ro,create=dir,optional 0 0
EOF
    log "Installed config: $cfg"
    log "Installed hook: $(hook_path)"
    fix_dev_nodes_rootfs
}

fix_dev_nodes_rootfs() {
    local rootfs
    rootfs="$(container_rootfs)"
    [ -d "$rootfs/dev" ] || run_root mkdir -p "$rootfs/dev"
    run_root rm -f "$rootfs/dev/null" "$rootfs/dev/zero" "$rootfs/dev/random" "$rootfs/dev/urandom"
    run_root mknod -m 666 "$rootfs/dev/null" c 1 3 2>/dev/null || true
    run_root mknod -m 666 "$rootfs/dev/zero" c 1 5 2>/dev/null || true
    run_root mknod -m 666 "$rootfs/dev/random" c 1 8 2>/dev/null || true
    run_root mknod -m 666 "$rootfs/dev/urandom" c 1 9 2>/dev/null || true
    run_root chmod 666 "$rootfs/dev/null" "$rootfs/dev/zero" "$rootfs/dev/random" "$rootfs/dev/urandom" 2>/dev/null || true
}

fix_dev_nodes() {
    fix_dev_nodes_rootfs
    run_root lxc-attach -n "$CONTAINER" -- sh -lc '
rm -f /dev/null /dev/zero /dev/random /dev/urandom
mknod -m 666 /dev/null c 1 3
mknod -m 666 /dev/zero c 1 5
mknod -m 666 /dev/random c 1 8
mknod -m 666 /dev/urandom c 1 9
chmod 666 /dev/null /dev/zero /dev/random /dev/urandom
chmod 666 /dev/dri/card0 /dev/dri/renderD128 /dev/dri/controlD64 /dev/kgsl-3d0 2>/dev/null || true
' 2>/dev/null || true
    local pid
    pid="$(get_container_pid)"
    if [ -n "$pid" ]; then
        run_root nsenter -t "$pid" -m -p -- sh -c '
rm -f /dev/null /dev/zero /dev/random /dev/urandom
mknod -m 666 /dev/null c 1 3
mknod -m 666 /dev/zero c 1 5
mknod -m 666 /dev/random c 1 8
mknod -m 666 /dev/urandom c 1 9
chmod 666 /dev/null /dev/zero /dev/random /dev/urandom
chmod 666 /dev/dri/card0 /dev/dri/renderD128 /dev/dri/controlD64 /dev/kgsl-3d0 2>/dev/null || true
' 2>/dev/null || true
    fi
}

pkg_install_cmd() {
    case "$DISTRO" in
        fedora)
            printf 'dnf install -y --nogpgcheck @xfce-desktop chromium pulseaudio-libs pulseaudio-utils alsa-plugins-pulseaudio dbus-x11 xterm mesa-dri-drivers mesa-libEGL mesa-libGL mesa-vulkan-drivers mesa-va-drivers libdrm glx-utils mesa-demos kmscube'
            ;;
        ubuntu|debian)
            printf 'export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends xfce4 xfce4-terminal dbus-x11 pulseaudio-utils alsa-utils libasound2-plugins xterm libgl1 libgl1-mesa-dri libegl1 libgles2 libdrm2 mesa-utils mesa-utils-extra kmscube'
            ;;
        *) fail "Unsupported distro for install: $DISTRO. Supported: fedora, ubuntu, debian" ;;
    esac
}

repair_packages() {
    case "$DISTRO" in
        ubuntu|debian)
            run_root lxc-attach -n "$CONTAINER" -- sh -lc '
export DEBIAN_FRONTEND=noninteractive
apt-get -f install -y --no-install-recommends || true
dpkg --configure -a || true
apt-get purge -y snapd chromium-browser 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
' || true
            ;;
    esac
}

cmd_install() {
    need_root_for install
    [ "$DESKTOP" = "xfce" ] || fail "Only xfce is currently supported"
    if ! lxc_running; then
        fix_dev_nodes_rootfs
        lxc-start -n "$CONTAINER" -d 2>/dev/null || lxc-start -n "$CONTAINER" -d
        wait_running || fail "Container did not reach RUNNING"
    fi
    fix_dev_nodes
    log "Installing XFCE packages inside $CONTAINER ($DISTRO)"
    lxc-attach -n "$CONTAINER" -- sh -lc "$(pkg_install_cmd)"
    repair_packages
    log "Creating/updating user $CONTAINER_USER uid=$CONTAINER_UID"
    lxc-attach -n "$CONTAINER" -- sh -lc "
set -e
if ! getent group $CONTAINER_USER >/dev/null; then groupadd -g $CONTAINER_UID $CONTAINER_USER; fi
if ! id $CONTAINER_USER >/dev/null 2>&1; then useradd -u $CONTAINER_UID -g $CONTAINER_UID -m -d /home/$CONTAINER_USER -s /bin/bash $CONTAINER_USER; fi
usermod -aG video,render,audio $CONTAINER_USER 2>/dev/null || true
chmod 0755 /home/$CONTAINER_USER
mkdir -p /home/$CONTAINER_USER/.config/xfce4/xfconf/xfce-perchannel-xml /home/$CONTAINER_USER/.config/autostart /home/$CONTAINER_USER/.config/chromium
chown -R $CONTAINER_UID:$CONTAINER_UID /home/$CONTAINER_USER/.config
"
    install_xfce_config
    disable_xfce_services
    setup_audio_env
    patch_chromium_desktop
    log "Container desktop install complete: $CONTAINER"
}

cmd_repair() {
    need_root_for repair
    [ -d "$ROOTFS_BASE/$CONTAINER" ] || fail "Container not found: $CONTAINER"
    fix_dev_nodes_rootfs
    if ! lxc_running; then
        lxc-start -n "$CONTAINER" -d 2>/dev/null || true
        wait_running || fail "Container did not reach RUNNING"
    fi
    fix_dev_nodes
    repair_packages
    log "Repair complete: $CONTAINER"
}

install_xfce_config() {
    local src_xsettings="$REPO_DIR/configs/xfce/xsettings.xml"
    local src_xfwm4="$REPO_DIR/configs/xfce/xfwm4.xml"
    [ -f "$src_xsettings" ] || return 0
    run_root lxc-attach -n "$CONTAINER" -- sh -lc "mkdir -p /home/$CONTAINER_USER/.config/xfce4/xfconf/xfce-perchannel-xml"
    run_root cp "$src_xsettings" "$(container_rootfs)/home/$CONTAINER_USER/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
    [ -f "$src_xfwm4" ] && run_root cp "$src_xfwm4" "$(container_rootfs)/home/$CONTAINER_USER/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
    run_root chown -R "$CONTAINER_UID:$CONTAINER_UID" "$(container_rootfs)/home/$CONTAINER_USER/.config/xfce4"
}

disable_xfce_services() {
    run_root lxc-attach -n "$CONTAINER" -- sh -lc '
set +e
for svc in NetworkManager NetworkManager-dispatcher NetworkManager-wait-online wpa_supplicant iwd ModemManager; do
    systemctl disable --now "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
pkill -9 -f "NetworkManager|wpa_supplicant|iwd|nm-applet|nm-tray|nm-connection-editor|ModemManager" 2>/dev/null || true
' 2>/dev/null || true
    run_root lxc-attach -n "$CONTAINER" -- su - "$CONTAINER_USER" -c '
mkdir -p ~/.config/autostart
for dir in /etc/xdg/autostart /usr/share/xdg/autostart; do
  cd "$dir" 2>/dev/null || continue
  for f in xfce4-notifyd.desktop xfce4-power-manager.desktop blueman-applet.desktop dnfdragora-updater.desktop tracker-miner-fs-3.desktop tracker-store.desktop localsearch-3.desktop polkit-gnome-authentication-agent-1.desktop polkit-kde-authentication-agent-1.desktop light-locker.desktop nm-applet.desktop nm-connection-editor.desktop nm-tray.desktop NetworkManager-applet.desktop gnome-keyring-pkcs11.desktop gnome-keyring-secrets.desktop gnome-keyring-ssh.desktop; do
      [ -f "$f" ] || continue
      cp "$f" ~/.config/autostart/"$f"
      grep -q "^Hidden=true" ~/.config/autostart/"$f" || echo "Hidden=true" >> ~/.config/autostart/"$f"
  done
done
# Also create blocker desktop files for common network applets even when packages use distro-specific paths.
for f in nm-applet.desktop nm-connection-editor.desktop nm-tray.desktop NetworkManager-applet.desktop; do
  printf "[Desktop Entry]\nType=Application\nName=Disabled %s\nHidden=true\n" "$f" > ~/.config/autostart/"$f"
done
systemctl --user disable tracker-miner-fs-3 tracker-store localsearch-3 2>/dev/null || true
pkill -9 -f "localsearch|tracker|nm-applet|nm-tray|polkit.*authentication" 2>/dev/null || true
' 2>/dev/null || true
}

setup_audio_env() {
    run_root lxc-attach -n "$CONTAINER" -- su - "$CONTAINER_USER" -c "
mkdir -p ~/.config
printf 'pcm.!default { type pulse }\nctl.!default { type pulse }\n' > ~/.asoundrc
grep -qxF 'export PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT' ~/.bashrc 2>/dev/null || echo 'export PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT' >> ~/.bashrc
mkdir -p ~/.config/chromium
printf 'PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT\n' > ~/.config/chromium/chrome-flags.conf
" 2>/dev/null || true
}

patch_chromium_desktop() {
    run_root lxc-attach -n "$CONTAINER" -- sh -lc "
for f in /usr/share/applications/chromium-browser.desktop /usr/share/applications/chromium.desktop; do
  [ -f \"\$f\" ] || continue
  cp \"\$f\" \"\$f.ut-lxc.bak\" 2>/dev/null || true
  sed -i 's#^Exec=\([^e].*chromium.*\)#Exec=env PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT \1#' \"\$f\" 2>/dev/null || true
done
" 2>/dev/null || true
}

kill_socat_relay() {
    local pf old pid pgid
    pf="$(pidfile)"
    if [ -f "$pf" ]; then
        old="$(cat "$pf" 2>/dev/null || true)"
        if [ -n "$old" ]; then
            pgid="$(ps -o pgid= -p "$old" 2>/dev/null | tr -d ' ' || true)"
            [ -n "$pgid" ] && kill -9 -"$pgid" 2>/dev/null || true
            kill -9 "$old" 2>/dev/null || true
        fi
        rm -f "$pf"
    fi
    if have ss; then
        for pid in $(ss -tlnp 2>/dev/null | grep ":$PULSE_TCP_PORT " | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
            pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
            [ -n "$pgid" ] && kill -9 -"$pgid" 2>/dev/null || true
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
    sleep 1
}

start_socat_relay() {
    mkdir -p "$CACHE_DIR"
    local sock="/run/user/$CONTAINER_UID/pulse/native"
    [ -S "$sock" ] || warn "PulseAudio socket not found yet: $sock"
    kill_socat_relay
    sudo -u "$CONTAINER_USER" socat TCP-LISTEN:"$PULSE_TCP_PORT",reuseaddr,fork UNIX-CONNECT:"$sock" >/dev/null 2>&1 &
    echo $! > "$(pidfile)"
    sleep 1
    if ss -tlnp 2>/dev/null | grep -q ":$PULSE_TCP_PORT "; then log "PulseAudio relay listening: tcp:0.0.0.0:$PULSE_TCP_PORT -> $sock"; else warn "PulseAudio relay not listening on $PULSE_TCP_PORT"; fi
}

stop_xephyr() {
    local pf pid display_id
    pf="$(xephyr_pidfile)"
    display_id="${DISPLAY_NUM#:}"
    if [ -f "$pf" ]; then
        pid="$(cat "$pf" 2>/dev/null || true)"
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
        rm -f "$pf"
    fi
    pkill -9 -f "Xephyr $DISPLAY_NUM" 2>/dev/null || true
    rm -f "/tmp/.X${display_id}-lock" "/tmp/.X11-unix/X${display_id}" 2>/dev/null || true
}

start_xephyr() {
    have Xephyr || fail "Xephyr not found. Install with: sudo apt-get install xserver-xephyr"
    local fullscreen_arg="" display_id pid
    display_id="${DISPLAY_NUM#:}"
    pid="$(pgrep -f "Xephyr $DISPLAY_NUM" | head -1 || true)"
    if [ -n "$pid" ] && [ -S "/tmp/.X11-unix/X${display_id}" ]; then
        if [ "${UT_LXC_FORCE_NEW_XEPHYR:-0}" = "1" ]; then
            log "Restarting stale/requested Xephyr nested display on $DISPLAY_NUM pid=$pid"
            stop_xephyr
        else
            echo "$pid" > "$(xephyr_pidfile)"
            log "Xephyr nested display already running on $DISPLAY_NUM pid=$pid"
            return 0
        fi
    else
        stop_xephyr
    fi
    [ "$NESTED_FULLSCREEN" = "1" ] && fullscreen_arg="-fullscreen"
    # Start via a root-owned transient systemd unit instead of as a child of the
    # launcher process. Lomiri may reap/kill short-lived .desktop children after
    # the icon handler exits; systemd-run keeps Xephyr alive like manual shell
    # launches do.
    systemctl stop "ut-lxc-xephyr-$CONTAINER.service" >/dev/null 2>&1 || true
    systemd-run --unit="ut-lxc-xephyr-$CONTAINER" --description="UT LXC Xephyr $CONTAINER $DISPLAY_NUM" \
      --property=Type=simple --property=Restart=no \
      --setenv=DISPLAY=:0 --setenv=XDG_RUNTIME_DIR="/run/user/$CONTAINER_UID" \
      --uid=phablet --collect \
      /usr/bin/Xephyr "$DISPLAY_NUM" -screen "$NESTED_GEOMETRY" $fullscreen_arg -resizeable -ac -br -dpi "$NESTED_DPI" -retro \
      >/tmp/ut-lxc-xephyr-$CONTAINER.log 2>&1 || \
      setsid sudo -u phablet env DISPLAY=:0 XDG_RUNTIME_DIR="/run/user/$CONTAINER_UID" Xephyr "$DISPLAY_NUM" -screen "$NESTED_GEOMETRY" $fullscreen_arg -resizeable -ac -br -dpi "$NESTED_DPI" -retro </dev/null >/tmp/ut-lxc-xephyr-$CONTAINER.log 2>&1 &
    sleep 4
    pid="$(pgrep -f "Xephyr $DISPLAY_NUM" | head -1 || true)"
    [ -n "$pid" ] && echo "$pid" > "$(xephyr_pidfile)"
    [ -S "/tmp/.X11-unix/X${display_id}" ] || warn "Xephyr socket not ready: /tmp/.X11-unix/X${display_id}. Log: /tmp/ut-lxc-xephyr-$CONTAINER.log"
    log "Xephyr nested display listening on $DISPLAY_NUM size=$NESTED_GEOMETRY dpi=$NESTED_DPI fullscreen=$NESTED_FULLSCREEN pid=${pid:-unknown}"
}

cmd_start() {
    need_root_for start
    mkdir -p "$LOG_DIR"
    chown phablet:phablet "$CACHE_DIR" "$LOG_DIR" 2>/dev/null || true
    chmod 775 "$CACHE_DIR" "$LOG_DIR" 2>/dev/null || true
    have lxc-start || fail "lxc-start not found"
    if ! run_root lxc-info -n "$CONTAINER" >/dev/null 2>&1; then fail "Container not found: $CONTAINER"; fi
    log "Starting container: $CONTAINER"
    run_root lxc-start -n "$CONTAINER" -d 2>/dev/null || true
    wait_running || fail "Container did not reach RUNNING. Check /tmp/$CONTAINER.log"
    fix_dev_nodes
    if [ "$DISPLAY_MODE" = "xephyr" ]; then
        start_xephyr
        DISPLAY_FOR_CONTAINER="$DISPLAY_NUM"
    else
        DISPLAY_FOR_CONTAINER="$DISPLAY_NUM"
    fi
    start_socat_relay
    setup_audio_env
    disable_xfce_services
    local xfce_log="$LOG_DIR/$CONTAINER-xfce.log"
    if run_root lxc-attach -n "$CONTAINER" -- sh -lc "pgrep -u '$CONTAINER_USER' -x xfce4-session >/dev/null 2>&1" 2>/dev/null; then
        log "XFCE already running in $CONTAINER on DISPLAY=$DISPLAY_FOR_CONTAINER"
        run_root lxc-attach -n "$CONTAINER" -- su - "$CONTAINER_USER" -c "
export DISPLAY=$DISPLAY_FOR_CONTAINER
export GDK_SCALE=1
export GDK_DPI_SCALE=1
export QT_SCALE_FACTOR=1
if ! pgrep -u '$CONTAINER_USER' -x xfwm4 >/dev/null 2>&1; then xfwm4 --replace --sm-client-disable >/tmp/xfwm4-recover.log 2>&1 & fi
if ! pgrep -u '$CONTAINER_USER' -x xfsettingsd >/dev/null 2>&1; then xfsettingsd --replace >/tmp/xfsettingsd-recover.log 2>&1 & fi
" >/dev/null 2>&1 || true
        return 0
    fi
    log "Launching XFCE in $CONTAINER on DISPLAY=$DISPLAY_FOR_CONTAINER"
    rm -f "$xfce_log"
    install -o phablet -g phablet -m 664 /dev/null "$xfce_log" 2>/dev/null || { : > "$xfce_log"; chown phablet:phablet "$xfce_log" 2>/dev/null || true; chmod 664 "$xfce_log" 2>/dev/null || true; }
    run_root lxc-attach -n "$CONTAINER" -- sh -lc "pkill -9 -u '$CONTAINER_USER' -f 'xfce4-session|startxfce4|xfwm4|xfdesktop|xfsettingsd|xfce4-panel|plank|dock|xfconfd' 2>/dev/null || true" 2>/dev/null || true
    rm -f "$xfce_log"
    touch "$xfce_log"
    chown phablet:phablet "$xfce_log" 2>/dev/null || true
    chmod 664 "$xfce_log" 2>/dev/null || true
    systemctl stop "ut-lxc-xfce-$CONTAINER.service" >/dev/null 2>&1 || true
    local unit_log="/tmp/ut-lxc-$CONTAINER-xfce-host.log"
    rm -f "$unit_log" 2>/dev/null || true
    touch "$unit_log" 2>/dev/null || unit_log="/dev/null"
    cat > "/tmp/ut-lxc-xfce-$CONTAINER.sh" <<EOF_XFCE_LAUNCH
#!/usr/bin/env bash
set +e
exec >/tmp/ut-lxc-$CONTAINER-xfce-host.log 2>&1
echo "host xfce launcher: \$(date) container=$CONTAINER display=$DISPLAY_FOR_CONTAINER"
exec /usr/bin/lxc-attach -n "$CONTAINER" -- /bin/su - "$CONTAINER_USER" -c '
set +e
LOG=/tmp/ut-lxc-$CONTAINER-xfce-in-container.log
exec >>"\$LOG" 2>&1
echo "container xfce launcher: \$(date) display=$DISPLAY_FOR_CONTAINER"
export DISPLAY=$DISPLAY_FOR_CONTAINER
export PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT
export GDK_SCALE=1
export GDK_DPI_SCALE=1
export QT_SCALE_FACTOR=1
unset DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR=/run/user/$CONTAINER_UID
mkdir -p ~/.cache/sessions ~/.config/xfce4/xfconf/xfce-perchannel-xml /run/user/$CONTAINER_UID 2>/dev/null || true
rm -rf ~/.cache/sessions/xfce4* ~/.config/xfce4/sessions 2>/dev/null || true
if command -v dbus-launch >/dev/null 2>&1; then
  eval \$(dbus-launch --sh-syntax)
  echo "DBUS_SESSION_BUS_ADDRESS=\$DBUS_SESSION_BUS_ADDRESS"
else
  echo "WARN dbus-launch missing; continuing"
fi
xfconf-query -c xsettings -p /Xft/DPI -s 168 2>/dev/null || true
xfconf-query -c xsettings -p /Gtk/FontName -s "Sans 16" 2>/dev/null || true
xfconf-query -c xsettings -p /Gtk/MonospaceFontName -s "Monospace 15" 2>/dev/null || true
xfconf-query -c xsettings -p /Gtk/WindowScalingFactor -s 1 2>/dev/null || true
xfconf-query -c xfwm4 -p /general/title_font -s "Sans Bold 15" 2>/dev/null || true
xfconf-query -c xfwm4 -p /general/border_width -s 4 2>/dev/null || true
xfconf-query -c xfwm4 -p /general/workspace_count -s 1 2>/dev/null || true
startxfce4 &
xfce_pid=\$!
sleep 7
pgrep -u "$CONTAINER_USER" -x xfsettingsd >/dev/null 2>&1 || xfsettingsd --replace >>"\$LOG" 2>&1 &
pgrep -u "$CONTAINER_USER" -x xfwm4 >/dev/null 2>&1 || xfwm4 --replace --sm-client-disable >>"\$LOG" 2>&1 &
pgrep -u "$CONTAINER_USER" -x xfdesktop >/dev/null 2>&1 || xfdesktop >>"\$LOG" 2>&1 &
pgrep -u "$CONTAINER_USER" -x xfce4-panel >/dev/null 2>&1 || xfce4-panel --disable-wm-check >>"\$LOG" 2>&1 &
sleep 3
ps -ef | grep -E "[x]fce4-session|[x]fce4-panel|[x]fwm4|[x]fdesktop|[x]fsettingsd|[d]bus-daemon" || true
wait \$xfce_pid
'
EOF_XFCE_LAUNCH
    chmod 755 "/tmp/ut-lxc-xfce-$CONTAINER.sh"
    systemd-run --unit="ut-lxc-xfce-$CONTAINER" --description="UT LXC XFCE $CONTAINER $DISPLAY_FOR_CONTAINER" \
      --property=Type=simple --property=Restart=no --collect \
      /tmp/ut-lxc-xfce-$CONTAINER.sh >/dev/null 2>&1 || \
      setsid /tmp/ut-lxc-xfce-$CONTAINER.sh >/dev/null 2>&1 &
    log "XFCE launch requested. Host log: $unit_log Container log: /tmp/ut-lxc-$CONTAINER-xfce-in-container.log"
}

cmd_stop() {
    need_root_for stop
    log "Stopping UT LXC desktop: container=$CONTAINER display=$DISPLAY_NUM port=$PULSE_TCP_PORT"
    systemctl stop "ut-lxc-xfce-$CONTAINER.service" >/dev/null 2>&1 || true
    if run_root lxc-info -n "$CONTAINER" -s 2>/dev/null | tr -d '\n' | grep -q RUNNING; then
        timeout 8 lxc-attach -n "$CONTAINER" -- sh -lc "pkill -9 -u '$CONTAINER_USER' -f 'xfce4-session|startxfce4|xfwm4|xfdesktop|xfsettingsd|xfce4-panel|xfconfd|plank|dock' 2>/dev/null || true" 2>/dev/null || true
    fi
    systemctl stop "ut-lxc-xephyr-$CONTAINER.service" >/dev/null 2>&1 || true
    stop_xephyr
    kill_socat_relay
    if run_root lxc-info -n "$CONTAINER" -s 2>/dev/null | tr -d '\n' | grep -q RUNNING; then
        timeout 12 lxc-stop -n "$CONTAINER" -k >/dev/null 2>&1 || timeout 12 lxc-stop -n "$CONTAINER" >/dev/null 2>&1 || true
    fi
    rm -f "/tmp/ut-lxc-xfce-$CONTAINER.sh" "/tmp/ut-lxc-$CONTAINER-xfce-host.log" "/tmp/ut-lxc-$CONTAINER-xfce-in-container.log" 2>/dev/null || true
    log "Stopped UT LXC desktop: $CONTAINER"
}

cmd_doctor() {
    local ok=0 pid
    log "UT LXC desktop doctor: container=$CONTAINER user=$CONTAINER_USER uid=$CONTAINER_UID port=$PULSE_TCP_PORT"
    run_root test -d "$ROOTFS_BASE/$CONTAINER" && log "OK container dir exists" || { warn "container dir missing"; ok=1; }
    run_root test -f "$(container_config)" && log "OK config exists: $(container_config)" || { warn "config missing"; ok=1; }
    run_root test -x "$(hook_path)" && log "OK hook executable: $(hook_path)" || warn "hook missing/not executable"
    if run_root lxc-info -n "$CONTAINER" -s 2>/dev/null | tr -d '\n' | grep -q RUNNING; then log "OK container RUNNING"; pid="$(get_container_pid)"; log "OK container PID: ${pid:-unknown}"; else warn "container not RUNNING"; ok=1; fi
    [ -e /tmp/.X11-unix/X0 ] && log "OK host X11 socket exists" || { warn "host X11 socket missing: /tmp/.X11-unix/X0"; ok=1; }
    [ -S "/run/user/$CONTAINER_UID/pulse/native" ] && log "OK host PulseAudio socket exists" || warn "host PulseAudio socket missing"
    if [ "$DISPLAY_MODE" = "xephyr" ]; then
        if pgrep -f "Xephyr $DISPLAY_NUM" >/dev/null 2>&1 && [ -S "/tmp/.X11-unix/X${DISPLAY_NUM#:}" ]; then
            log "OK Xephyr nested display running: $DISPLAY_NUM"
        else
            warn "Xephyr nested display not running: $DISPLAY_NUM"
            ok=1
        fi
    fi
    if ss -tlnp 2>/dev/null | grep -q ":$PULSE_TCP_PORT "; then log "OK port $PULSE_TCP_PORT listening"; else warn "port $PULSE_TCP_PORT not listening"; fi
    if run_root lxc-attach -n "$CONTAINER" -- id "$CONTAINER_USER" >/dev/null 2>&1; then log "OK container user exists"; else warn "container user missing"; ok=1; fi
    if run_root lxc-attach -n "$CONTAINER" -- sh -lc '[ -c /dev/null ] && [ -c /dev/zero ]' >/dev/null 2>&1; then log "OK device nodes"; else warn "device nodes broken"; ok=1; fi
    if run_root lxc-attach -n "$CONTAINER" -- sh -lc 'ps -ef | grep -q "[x]fce4-session\|[s]tartxfce4"'; then log "OK XFCE session running"; else warn "XFCE session not running"; ok=1; fi
    local pa_ok=1
    local pa_try
    for pa_try in 1 2 3 4 5; do
        if run_root lxc-attach -n "$CONTAINER" -- env PULSE_SERVER="tcp:127.0.0.1:$PULSE_TCP_PORT" timeout 5 pactl info >/dev/null 2>&1; then
            pa_ok=0
            break
        fi
        sleep 1
    done
    if [ "$pa_ok" = "0" ]; then log "OK PulseAudio from container"; else warn "PulseAudio check failed/skipped"; ok=1; fi
    return "$ok"
}

cmd_sudoers() {
    need_root_for sudoers
    local sudoers="/etc/sudoers.d/ubports-lxc-desktop"
    cat > "$sudoers" <<EOF
phablet ALL=(root) NOPASSWD: $REPO_DIR/scripts/ut-lxc-desktop.sh, $REPO_DIR/scripts/ut-lxc-desktop.sh *, /usr/bin/lxc-create, /usr/local/bin/lxc-create, /usr/bin/lxc-create.real
EOF
    chmod 440 "$sudoers"
    if command -v visudo >/dev/null 2>&1; then
        visudo -cf "$sudoers" >/dev/null || fail "sudoers validation failed: $sudoers"
    fi
    log "Installed sudoers: $sudoers"
}

cmd_bootstrap() {
    need_root_for bootstrap
    cmd_sudoers
    local wrapper="/usr/local/bin/lxc-create"
    local original="/usr/bin/lxc-create"
    [ -x "$original" ] || fail "Original lxc-create not found: $original"
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -u
ORIGINAL="$original"
MANAGER="$REPO_DIR/scripts/ut-lxc-desktop.sh"
name=""
distro=""
release=""
arch="arm64"
ut_install=0
next_is_template_args=0
args=("")
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    --ut-install|--ut-desktop) ut_install=1; shift ;;
    -n|--name) name="\${2:-}"; args+=("\$1" "\${2:-}"); shift 2 ;;
    -t|--template) args+=("\$1" "\${2:-}"); shift 2 ;;
    --) next_is_template_args=1; args+=("\$1"); shift ;;
    -d|--dist) if [ "\$next_is_template_args" = 1 ]; then distro="\${2:-}"; fi; args+=("\$1" "\${2:-}"); shift 2 ;;
    -r|--release) if [ "\$next_is_template_args" = 1 ]; then release="\${2:-}"; fi; args+=("\$1" "\${2:-}"); shift 2 ;;
    -a|--arch) if [ "\$next_is_template_args" = 1 ]; then arch="\${2:-}"; fi; args+=("\$1" "\${2:-}"); shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
"\$ORIGINAL" "\${args[@]}"
rc=\$?
[ \$rc -eq 0 ] || exit \$rc
[ -n "\$name" ] || exit 0
case "\$distro" in
  fedora|ubuntu|debian) ;;
  *) exit 0 ;;
esac
[ -n "\$release" ] || exit 0
"\$MANAGER" configure -n "\$name" -d "\$distro" -r "\$release" -a "\$arch"
if [ "\$ut_install" = "1" ]; then
  "\$MANAGER" install -n "\$name" -d "\$distro" -r "\$release" -a "\$arch"
  "\$MANAGER" desktop-file -n "\$name" -d "\$distro" -r "\$release" -a "\$arch"
fi
EOF
    chmod 755 "$wrapper"
    log "Installed lxc-create wrapper: $wrapper"
    log "Future shells usually prefer /usr/local/bin/lxc-create before /usr/bin/lxc-create"
    log "After this, plain lxc-create auto-runs configure for fedora|ubuntu|debian download containers."
    log "Add --ut-install before -- to also install XFCE and desktop-file after lxc-create."
}

cmd_desktop_file() {
    mkdir -p /home/phablet/.local/share/applications /home/phablet/.local/bin "$CACHE_DIR"
    local wrapper="/home/phablet/.local/bin/ut-lxc-desktop-$CONTAINER"
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -u
uid="\$(id -u 2>/dev/null || printf $CONTAINER_UID)"
log="/tmp/ut-lxc-$CONTAINER-launcher-\${uid}.log"
if [ -e "\$log" ] && [ ! -w "\$log" ]; then
  log="/tmp/ut-lxc-$CONTAINER-launcher-\${uid}-\$\$.log"
fi
rm -f "\$log" 2>/dev/null || true
: >"\$log" 2>/dev/null || log="/dev/null"
{
  printf '%s\n' "==== \$(date) $CONTAINER launcher ===="
  UT_LXC_FORCE_NEW_XEPHYR=1 sudo -n "$REPO_DIR/scripts/ut-lxc-desktop.sh" start -n "$CONTAINER" -u "$CONTAINER_USER" --uid "$CONTAINER_UID" --port "$PULSE_TCP_PORT" --display-mode "$DISPLAY_MODE" --display "$DISPLAY_NUM"
  rc=\$?
  printf '%s\n' "launcher rc=\$rc"
  exit "\$rc"
} >>"\$log" 2>&1
EOF
    chmod 755 "$wrapper"
    local desktop="/home/phablet/.local/share/applications/ut-lxc-$CONTAINER.desktop"
    local icon="$REPO_DIR/config/fedora_logo.png"
    cat > "$desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Terminal=false
Exec=$wrapper
Icon=$icon
Name=$CONTAINER 桌面
Name[en]=$CONTAINER Desktop
Name[zh_CN]=$CONTAINER 桌面
Comment=在 Lomiri 桌面内启动 $CONTAINER 容器 XFCE 桌面
EOF
    chown phablet:phablet "$wrapper" "$desktop" 2>/dev/null || true
    log "Installed launcher: $desktop"
    log "Launcher log: /tmp/ut-lxc-$CONTAINER-launcher-$(id -u).log"
}

cmd_all() { cmd_create; cmd_configure; cmd_install; cmd_sudoers; cmd_desktop_file; }

main() {
    parse_args "$@"
    case "$COMMAND" in
        create) cmd_create ;;
        configure) cmd_configure ;;
        install) cmd_install ;;
        repair) cmd_repair ;;
        sudoers) cmd_sudoers ;;
        bootstrap) cmd_bootstrap ;;
        start) cmd_start ;;
        stop) cmd_stop ;;
        doctor) cmd_doctor ;;
        desktop-file) cmd_desktop_file ;;
        all) cmd_all ;;
        help|-h|--help) usage ;;
        *) fail "Unknown command: $COMMAND" ;;
    esac
}
main "$@"
