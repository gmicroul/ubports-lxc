#!/bin/bash
# Ubuntu Touch 重启后一键恢复 fedora42 XFCE 桌面
# 用法: bash /home/phablet/ubports-lxc/scripts/restore-xfce.sh

set -e

echo "============================================"
echo "  Ubuntu Touch + Fedora 42 XFCE 恢复脚本"
echo "============================================"

# 步骤1：复制 hook 脚本和 config
echo "[1/6] 部署 hook 脚本和容器配置..."
sudo cp /home/phablet/ubports-lxc/config/fedora42-wayland-hook.sh /var/lib/lxc/fedora42-wayland-hook.sh
sudo chmod +x /var/lib/lxc/fedora42-wayland-hook.sh
sudo cp /home/phablet/ubports-lxc/config/fedora42-real.conf /var/lib/lxc/fedora42/config
sudo chown root:root /var/lib/lxc/fedora42/config

# 步骤2：启动容器
echo "[2/6] 启动容器 fedora42..."
sudo lxc-start -n fedora42 -d 2>/dev/null || sudo lxc-start -n fedora42 -d
sleep 4

PID=$(sudo lxc-info -n fedora42 -p 2>/dev/null | grep -oP '\d+')
echo "      容器 PID: $PID"

# 步骤3：修复设备节点
echo "[3/6] 修复容器内设备节点..."
sudo nsenter -t $PID -m -p -- sh -c '
rm -f /dev/null /dev/zero /dev/random /dev/urandom
mknod -m 666 /dev/null c 1 3
mknod -m 666 /dev/zero c 1 5
mknod -m 666 /dev/random c 1 8
mknod -m 666 /dev/urandom c 1 9
chmod 777 /run/user/32011 2>/dev/null || true
chmod 777 /tmp/.X11-unix/X0 2>/dev/null || true
' 2>/dev/null

# 步骤4：复制 X11 socket 到容器
echo "[4/6] 复制 X11 socket 到容器..."
sudo nsenter -t $PID -m -p -- sh -c '
mkdir -p /tmp/.X11-unix
mount --bind /proc/1/root/tmp/.X11-unix/X0 /tmp/.X11-unix/X0 2>/dev/null || true
' 2>/dev/null

# 步骤5：启动 system dbus
echo "[5/6] 启动系统 D-Bus 服务..."
sudo nsenter -t $PID -m -p -- dbus-daemon --system --fork 2>/dev/null

# 步骤6：配置 PulseAudio TCP 转发
echo "[6/6] 配置 PulseAudio TCP 转发..."
socat TCP-LISTEN:32015,reuseaddr,fork UNIX-CONNECT:/run/user/32011/pulse/native &
echo "      PulseAudio 转发在 TCP:32015"

echo ""
echo "============================================"
echo "  准备就绪！启动 XFCE 桌面："
echo "    sudo lxc-attach -n fedora42 -- su - phablet -c 'DISPLAY=:0 startxfce4'"
echo "============================================"