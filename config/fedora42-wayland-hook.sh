#!/bin/bash
# LXC 容器 hook：复制宿主 X11 + Wayland + PulseAudio 到容器 rootfs

CONTAINER_NAME=fedora42
ROOTFS=/var/lib/lxc/${CONTAINER_NAME}/rootfs

HOST_X11=/tmp/.X11-unix
HOST_WAYLAND=/run/user/32011/wayland-0
HOST_LOCK=/run/user/32011/wayland-0.lock
HOST_PULSE_DIR=/run/user/32011/pulse
HOST_DBUS_SOCK=/run/dbus/system_bus_socket

case "$1" in
  pre-start)
    # === X11 socket ===
    mkdir -p ${ROOTFS}/tmp/.X11-unix
    cp -a ${HOST_X11}/X0 ${ROOTFS}/tmp/.X11-unix/X0
    chmod 777 ${ROOTFS}/tmp/.X11-unix/X0 2>/dev/null || true

    # === Wayland socket（备用）===
    rm -f ${ROOTFS}/run/user/32011/wayland-0
    rm -f ${ROOTFS}/run/user/32011/wayland-0.lock
    mkdir -p ${ROOTFS}/run/user/32011
    cp -a ${HOST_WAYLAND} ${ROOTFS}/run/user/32011/wayland-0 2>/dev/null || true
    cp -a ${HOST_LOCK} ${ROOTFS}/run/user/32011/wayland-0.lock 2>/dev/null || true
    chmod 777 ${ROOTFS}/run/user/32011/wayland-0 2>/dev/null || true
    chmod 777 ${ROOTFS}/run/user/32011/wayland-0.lock 2>/dev/null || true

    # === PulseAudio socket ===
    rm -rf ${ROOTFS}/run/user/32011/pulse
    mkdir -p ${ROOTFS}/run/user/32011
    cp -a ${HOST_PULSE_DIR} ${ROOTFS}/run/user/32011/pulse
    chmod -R 777 ${ROOTFS}/run/user/32011/pulse 2>/dev/null || true
    chown -R 32011:32011 ${ROOTFS}/run/user/32011/pulse 2>/dev/null || true

    # === D-Bus system socket ===
    mkdir -p ${ROOTFS}/run/dbus
    cp -a ${HOST_DBUS_SOCK} ${ROOTFS}/run/dbus/system_bus_socket 2>/dev/null || true
    chmod 777 ${ROOTFS}/run/dbus/system_bus_socket 2>/dev/null || true

    echo "X11, Wayland, PulseAudio, D-Bus sockets copied to container"
    ;;
  post-stop)
    rm -rf ${ROOTFS}/tmp/.X11-unix
    rm -f ${ROOTFS}/run/user/32011/wayland-0
    rm -f ${ROOTFS}/run/user/32011/wayland-0.lock
    rm -rf ${ROOTFS}/run/user/32011/pulse
    rm -f ${ROOTFS}/run/dbus/system_bus_socket
    echo "Sockets cleaned"
    ;;
esac
exit 0