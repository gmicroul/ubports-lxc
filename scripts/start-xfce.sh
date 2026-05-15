#!/bin/bash
# fedora42 全功能一键启动脚本
# XFCE 桌面 + PulseAudio 音频 + 容器设备修复
# 用法: bash start-xfce.sh

CONTAINER=fedora42
PULSE_TCP_PORT=32015
PULSE_SOCKET=/run/user/32011/pulse/native
CONTAINER_PID=$(sudo lxc-info -n $CONTAINER -p 2>/dev/null | grep -oP '\d+')

echo "============================================"
echo " fedora42 全功能启动脚本"
echo "============================================"

echo ""
echo "=== 1/6 启动容器 ==="
sudo lxc-start -n $CONTAINER -d 2>/dev/null
sleep 3
CONTAINER_PID=$(sudo lxc-info -n $CONTAINER -p 2>/dev/null | grep -oP '\d+')
echo "  PID: $CONTAINER_PID"

echo ""
echo "=== 2/6 修复容器设备节点 ==="
sudo nsenter -t $CONTAINER_PID -m -p -- sh -c '
mknod -m 666 /dev/null c 1 3 2>/dev/null
mknod -m 666 /dev/random c 1 8 2>/dev/null
mknod -m 666 /dev/urandom c 1 9 2>/dev/null
' 2>/dev/null
echo "  Device nodes created"

echo ""
echo "=== 3/6 启动 PulseAudio 音频转发 ==="
if ! ss -tlnp 2>/dev/null | grep -q ":$PULSE_TCP_PORT "; then
    nohup socat TCP-LISTEN:$PULSE_TCP_PORT,reuseaddr,fork UNIX-CONNECT:$PULSE_SOCKET > /dev/null 2>&1 &
    echo "  PulseAudio socat on port $PULSE_TCP_PORT"
else
    echo "  PulseAudio socat already running"
fi

# 确保 PulseAudio TCP 模块已加载（允许匿名客户端）
pactl list modules short 2>/dev/null | grep -q "module-native-protocol-tcp" || \
    pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 >/dev/null 2>&1

sleep 1

echo ""
echo "=== 4/6 验证音频 ==="
sudo nsenter -t $CONTAINER_PID -m -p -- sh -c '
su - phablet -c "
    PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT pactl info 2>/dev/null | grep -q \"pulseaudio\" && echo \"  Audio OK\" || echo \"  Audio check failed\"
"
' 2>/dev/null

echo ""
echo "=== 5/6 复制关键文件到容器 ==="
sudo nsenter -t $CONTAINER_PID -m -p -- sh -c '
cp /home/phablet/.asoundrc /run/user/32011/.asoundrc 2>/dev/null || true
' 2>/dev/null

echo ""
echo "=== 6/6 启动 XFCE 桌面 ==="
sudo nsenter -t $CONTAINER_PID -m -p -- sh -c '
mkdir -p /run/user/32011 2>/dev/null
chown phablet:phablet /run/user/32011 2>/dev/null || true
su - phablet -c "
    rm -f /dev/null && mknod -m 666 /dev/null c 1 3
    grep -q \"PULSE_SERVER\" ~/.bashrc 2>/dev/null || echo \"export PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT\" >> ~/.bashrc
    export PULSE_SERVER=tcp:localhost:$PULSE_TCP_PORT
    DISPLAY=:0 startxfce4
" &
' 2>/dev/null

echo ""
echo "============================================"
echo " ✅ XFCE 桌面启动中"
echo " ✅ PulseAudio: tcp:localhost:32015"
echo ""
echo " 在 XFCE 终端里直接运行应用即可："
echo "   musicfox"
echo "   chromium-browser --no-session-restore"
echo "============================================"