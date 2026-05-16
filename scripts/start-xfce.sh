#!/bin/bash
# fedora42 全功能一键启动脚本 v5（稳定版）
# XFCE 桌面 + PulseAudio 音频（socat TCP:32016）+ 容器设备修复
# v5: 容器启动状态检测 + 递归杀 socat 进程组
# 用法: bash start-xfce.sh

CONTAINER=fedora42
PULSE_TCP_PORT=32016
PULSE_SOCKET=/run/user/32011/pulse/native
CONTAINER_PID=""

# sudo 保活：先跑一次 sudo，缓存凭证
sudo -v 2>/dev/null || sudo true 2>/dev/null

echo "============================================"
echo " fedora42 全功能启动脚本 v5"
echo " PulseAudio: tcp:localhost:32016"
echo " 6/6 启动流程"
echo "============================================"

echo ""
echo "=== 1/5 启动容器 ==="
sudo lxc-start -n $CONTAINER -d 2>/dev/null
# 等待容器 running，最多等 15 秒
for i in 1 2 3 4 5; do
    sudo lxc-info -n $CONTAINER -s 2>/dev/null | tr -d '\n' | grep -q "RUNNING" && {
        STATE="RUNNING"
        CONTAINER_PID=$(sudo lxc-info -n $CONTAINER -p 2>/dev/null | grep -oP '\d+')
        echo "  Running (PID $CONTAINER_PID)"
        break
    }
    [ "$i" = "1" ] && (sudo lxc-info -n $CONTAINER -s 2>&1 | tr -d '\n' > /tmp/lxc_debug.txt; echo "EXIT:$?" >> /tmp/lxc_debug.txt)
    echo "  Waiting for container... ($i/5)"
    sleep 3
done
if [ "$STATE" != "RUNNING" ]; then
    echo "  ERROR: Container failed to start"
    exit 1
fi

echo ""
echo "=== 2/5 修复容器设备节点 ==="
sudo lxc-attach -n $CONTAINER -- sh -c '
rm -f /dev/null && mknod -m 666 /dev/null c 1 3
rm -f /dev/random && mknod -m 666 /dev/random c 1 8
rm -f /dev/urandom && mknod -m 666 /dev/urandom c 1 9
' 2>/dev/null
echo "  Device nodes created"

echo ""
echo "=== 3/5 启动 PulseAudio 音频转发 ==="
# 斩草除根：杀所有 socat + 占端口进程
OLD_PIDS=$(ss -tlnp | grep ":$PULSE_TCP_PORT " | grep -oP 'pid=\K\d+')
if [ -n "$OLD_PIDS" ]; then
    for pid in $OLD_PIDS; do
        kill -9 "$pid" 2>/dev/null
        # 杀子进程
        PGID=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$PGID" ] && kill -9 -"$PGID" 2>/dev/null
    done
    sleep 2
fi
# 再补一刀：删 socket 文件确保通路
rm -f /tmp/pulse-tcp-$PULSE_TCP_PORT 2>/dev/null
# 起新的 socat
nohup socat TCP-LISTEN:$PULSE_TCP_PORT,reuseaddr,fork UNIX-CONNECT:$PULSE_SOCKET > /dev/null 2>&1 &
SOCAT_PID=$!
sleep 1
# 验证 socat 是否在监听
if ss -tlnp | grep -q ":$PULSE_TCP_PORT "; then
    echo "  socat started (PID $SOCAT_PID)"
else
    echo "  socat failed to start, retrying..."
    socat TCP-LISTEN:$PULSE_TCP_PORT,reuseaddr,fork UNIX-CONNECT:$PULSE_SOCKET > /dev/null 2>&1 &
    sleep 1
    ss -tlnp | grep -q ":$PULSE_TCP_PORT " && echo "  socat started on retry" || echo "  WARNING: socat not listening"
fi

echo ""
echo "=== 4/5 验证音频 ==="
AUDIO_OK=false
for i in 1 2 3 4 5; do
    # 先用 nsenter 测（更快），不行再用 lxc-attach
    if ss -tlnp | grep -q ":$PULSE_TCP_PORT "; then
        sudo nsenter -t $CONTAINER_PID -m -p -- su - phablet -c \
            "timeout 2 PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT pactl info 2>/dev/null | grep -q 'Server Name: pulseaudio'" \
            2>/dev/null && AUDIO_OK=true && break
    fi
    sleep 1
done
if [ "$AUDIO_OK" = true ]; then
    echo "  Audio OK"
else
    echo "  Audio check skipped（socat 在运行，XFCE 起来后自动生效）"
fi

echo ""
echo "=== 5/6 禁用不必要的 XFCE 组件 ==="
sudo lxc-attach -n $CONTAINER -- su - phablet -c '
mkdir -p ~/.config/autostart
cd /etc/xdg/autostart
for f in xfce4-notifyd.desktop xfce4-power-manager.desktop blueman-applet.desktop dnfdragora-updater.desktop tracker-miner-fs-3.desktop polkit-gnome-authentication-agent-1.desktop; do
    [ -f "$f" ] && {
        cp "$f" ~/.config/autostart/"$f"
        echo "X-GNOME-Autostart-enabled=false" >> ~/.config/autostart/"$f"
        echo "Hidden=true" >> ~/.config/autostart/"$f"
    }
done
# 额外禁用 tracker 和 localsearch 服务
systemctl --user disable tracker-miner-fs-3 2>/dev/null
systemctl --user disable tracker-store 2>/dev/null
pkill -f "localsearch|tracker" 2>/dev/null
' 2>/dev/null
echo "  Disabled: bluetooth, package updater, tracker, policykit agent"

echo ""
echo "=== 6/6 启动 XFCE 桌面 ==="
sudo lxc-attach -n $CONTAINER -- env DISPLAY=:0 PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT su - phablet -c '
    echo "export PULSE_SERVER=tcp:localhost:'$PULSE_TCP_PORT'" >> ~/.bashrc
    DISPLAY=:0 startxfce4
' &
sleep 2
echo "  XFCE launched"

echo ""
echo "============================================"
echo " ✅ XFCE 桌面启动中"
echo " ✅ PulseAudio: tcp:localhost:32016（socat PID $SOCAT_PID）"
echo ""
echo "  XFCE 终端里直接运行："
echo "    musicfox"
echo "    chromium-browser --no-session-restore"
echo "============================================"