#!/bin/bash
# 在 Ubuntu Touch Lomiri 上启动 fedora42 容器的 XFCE 桌面
# 用法: bash /home/phablet/start-ut-xfce.sh

CONTAINER=fedora42
echo "============================================"
echo "  Ubuntu Touch + Fedora 42 XFCE 启动脚本"
echo "============================================"

# 步骤1：启动容器
echo "[1/4] 启动容器 ${CONTAINER}..."
sudo lxc-start -n $CONTAINER -d 2>/dev/null
sleep 3

# 获取容器 PID
PID=$(sudo lxc-info -n $CONTAINER -p 2>/dev/null | grep -oP '\d+')
echo "        容器运行中 (PID: $PID)"

# 步骤2：修复设备节点
echo "[2/4] 修复容器内设备节点..."
sudo nsenter -t $PID -m -p -- sh -c '
rm -f /dev/null /dev/zero /dev/random /dev/urandom
mknod -m 666 /dev/null c 1 3
mknod -m 666 /dev/zero c 1 5
mknod -m 666 /dev/random c 1 8
mknod -m 666 /dev/urandom c 1 9
chmod 777 /run/user/32011 2>/dev/null || true
chmod 777 /tmp/.X11-unix/X0 2>/dev/null || true
' 2>/dev/null

# 步骤3：启动 system dbus
echo "[3/4] 启动系统 D-Bus 服务..."
sudo nsenter -t $PID -m -p -- dbus-daemon --system --fork 2>/dev/null

# 步骤4：启动 XFCE 桌面
echo "[4/4] 启动 XFCE 桌面..."
echo "        窗口应出现在 Lomiri 桌面上"
sudo nsenter -t $PID -m -p -- su - phablet -c '
# 修复 /dev/null（su 可能重置）
rm -f /dev/null 2>/dev/null
mknod -m 666 /dev/null c 1 3 2>/dev/null

# 加载 pulseaudio（声音）
PULSE_SERVER=unix:/run/user/32011/pulse/native
export PULSE_SERVER

# 启动 XFCE
DISPLAY=:0 startxfce4
' 2>&1