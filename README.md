# Ubuntu Touch + Fedora 42 XFCE 桌面嵌入方案

> 在 **Ubuntu Touch 26.04 (OnePlus 6T)** 上，通过 LXC 容器运行 Fedora 42，
> 将 XFCE 桌面嵌入到 Lomiri 桌面窗口中，支持音频输出到手机扬声器。
>
> 最终效果：桌面有一个 "Fedora 42 桌面" 图标，点击即进入 XFCE。

---

## 目录

- [从零开始部署](#从零开始部署)
- [容器配置说明](#容器配置说明)
- [一键启动脚本](#一键启动脚本)
- [常见问题](#常见问题)

---

## 从零开始部署

### 前提条件

- Ubuntu Touch 26.04 (arm64)
- 已 root 或拥有 sudo 权限
- 手机已连接 Wi-Fi

---

### 第 1 步：克隆仓库

**宿主办行：**

```bash
cd ~
git clone https://github.com/gmicroul/ubports-lxc.git
cd ubports-lxc
```

---

### 第 2 步：检查 LXC 环境

**宿主办行：**

Ubuntu Touch 默认安装了 LXC 但配置有限制，需要先确认 LXC 可用：

```bash
# 测试 lxc 能否正常工作
sudo lxc-checkconfig 2>/dev/null | head -20
sudo lxc-info -n test -- daemon 2>/dev/null || echo "LXC daemon OK"
```

如果 `lxc-create` 报 `Permission denied` 或 AppArmor 错误，按以下修复：

**2a. 确认 /etc/lxc/default.conf 内容：**

```bash
cat /etc/lxc/default.conf
```

如果缺少 namespace 或 apparmor 配置，写入标准配置：

```bash
sudo tee /etc/lxc/default.conf << "EOF"
lxc.apparmor.profile = unconfined
lxc.cgroup.devices.deny = a
lxc.autodev = 0
lxc.namespace.keep = net user
EOF
```

**2b. 创建必要设备节点：**

```bash
sudo mknod -m 666 /dev/loop-control c 10 237 2>/dev/null
sudo mknod -m 666 /dev/net/tun c 10 200 2>/dev/null
```

**2c. 确认 cgroup 已挂载：**

```bash
mount | grep cgroup | head -3
```

如果 cgroup2 没有挂载，手动挂载：

```bash
sudo mkdir -p /sys/fs/cgroup
sudo mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
```

---

### 第 3 步：创建 LXC 容器

**宿主办行：**

```bash
# 下载并创建 Fedora 42 容器
sudo lxc-create -n fedora42 -t download -- -d fedora -r 42 -a arm64
```

等待下载完成（约 5-10 分钟）。

---

### 第 3 步：应用容器配置

**宿主办行：**

```bash
# 复制容器配置（含 GPU、X11、PulseAudio 挂载）
sudo cp config/fedora42-real.conf /var/lib/lxc/fedora42/config
sudo chown root:root /var/lib/lxc/fedora42/config

# 复制 X11 socket 转发 hook 脚本
sudo cp config/fedora42-wayland-hook.sh /var/lib/lxc/fedora42-wayland-hook.sh
sudo chmod +x /var/lib/lxc/fedora42-wayland-hook.sh
```

---

### 第 4 步：安装 AUFS 内核模块

**宿主办行：**（解决 OverlayFS 兼容问题）

```bash
mkdir -p /var/lib/lxc/fedora42/aufs
mknod /dev/aufs c 10 255 2>/dev/null
```

> 如果 `lxc-start` 报 `failed to mount`，可去掉容器配置中的 `lxc.rootfs.options` 行，
> 或将 `overlay` 改为 `dir` 模式。

---

### 第 5 步：创建 XFCE 桌面

**宿主办行（进入容器）：**

```bash
sudo lxc-start -n fedora42 -d
sudo lxc-attach -n fedora42
```

**容器内执行：**

```bash
# 安装 XFCE 桌面
dnf install -y --nogpgcheck @xfce-desktop

# 安装 Chromium 浏览器和音频组件
dnf install -y --nogpgcheck chromium pulseaudio-libs pulseaudio-utils alsa-plugins-pulseaudio

# 创建 phablet 用户（与宿主的 UID 32011 对应）
groupadd -g 32011 phablet
useradd -u 32011 -g 32011 -m -d /home/phablet -s /bin/bash phablet
usermod -aG video,render phablet

# 安装启动脚本
cp /ubuntu/start-xfce.sh /home/phablet/ 2>/dev/null || true

# 容器内 Chromium 配置：禁用 session 启动
chmod 0755 /home/phablet
su - phablet -c "mkdir -p ~/.config/chromium"
su - phablet -c 'cat > ~/.config/chromium/chrome-flags.conf << "EOF"
PULSE_SERVER=tcp:localhost:32016
EOF'

exit
```

---

### 第 6 步：配置 Chromium 桌面菜单音频

**宿主办行：**

```bash
sudo lxc-attach -n fedora42 -- sh -c 'cat > /usr/share/applications/chromium-browser.desktop << "DESKTOP"
[Desktop Entry]
Version=1.0
Name=Chromium Web Browser
GenericName=Web Browser
Comment=Access the Internet
Exec=env PULSE_SERVER=tcp:localhost:32016 /usr/bin/chromium-browser %U
StartupNotify=true
Terminal=false
Icon=chromium-browser
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;

Desktop Actions=new-window;new-private-window;
Actions=new-window;
Desktop Action new-window;
Name=New Window
Exec=env PULSE_SERVER=tcp:localhost:32016 chromium-browser

Actions=new-private-window;
Desktop Action new-private-window;
Name=New Incognito Window
Exec=env PULSE_SERVER=tcp:localhost:32016 chromium-browser --incognito
DESKTOP'
```

---

### 第 7 步：配置 sudo 免密码

**宿主办行：**

```bash
sudo visudo -f /etc/sudoers.d/fedora-desktop
```

在打开的编辑器中输入以下内容并保存：

```
phablet ALL=(ALL) NOPASSWD: /usr/bin/lxc-start, /usr/bin/lxc-info, /usr/bin/lxc-attach, /usr/bin/nsenter, /usr/bin/kill, /usr/bin/socat, /bin/bash /home/phablet/start-xfce.sh
```

---

### 第 8 步：安装桌面图标

**宿主办行：**

```bash
cp ~/ubports-lxc/config/fedora42-desktop.desktop ~/.local/share/applications/
```

---

### 第 9 步：安装 ALSA 音频转发配置

**宿主办行：**

```bash
# 复制 asoundrc（ALSA → PulseAudio TCP 管道）
cp ~/ubports-lxc/config/.asoundrc ~/
```

---

### 第 10 步：重启手机

重启后，在 Lomiri 桌面底部上划 → 应用抽屉 → 找到 **Fedora 42 桌面** 图标 → 点击即可进入 XFCE。

---

## 文件说明

| 文件 | 路径 | 作用 |
|------|------|------|
| `start-xfce.sh` | `scripts/` | 一键启动脚本（容器检测 → 设备修复 → 音频转发 → XFCE 启动） |
| `start-fedora-desktop.sh` | `config/` | UT 桌面图标调用的包装脚本 |
| `fedora42-desktop.desktop` | `config/` | UT 桌面图标定义文件 |
| `fedora_logo.png` | `config/` | 桌面图标用 Fedora 标志 |
| `fedora42-real.conf` | `config/` | 容器完整配置（GPU、X11、音频、sysfs） |
| `fedora42-wayland-hook.sh` | `config/` | 容器启动自动复制 X11 socket 的 hook |
| `.asoundrc` | `config/` | ALSA → PulseAudio TCP 转发配置 |

---

## 一键启动脚本说明

`scripts/start-xfce.sh` 执行流程：

| # | 步骤 | 说明 |
|---|------|------|
| 1 | 启动容器 | 等待容器达到 RUNNING 状态（最多 15 秒） |
| 2 | 修复设备 | 重建容器内 /dev/null、/dev/random、/dev/urandom |
| 3 | 音频转发 | 启动 PulseAudio socat（TCP:32016），自动清除僵尸进程 |
| 4 | 验证音频 | 检测音频通路是否正常 |
| 5 | 禁用组件 | 关闭 xfce4-notifyd、xfce4-power-manager、蓝牙、包更新、tracker、PolicyKit |
| 6 | 启动 XFCE | 在已有 X server 上启动 startxfce4 |

---

## 容器配置模版

`config/fedora42-lxc.conf` — 最小可用配置
`config/fedora42-real.conf` — 实际使用的完整配置（推荐）

关键配置项：

- `lxc.apparmor.profile = unconfined` — 绕过 AppArmor 限制
- `lxc.mount.auto = cgroup:mixed proc:mixed sys:mixed` — 只读挂载内核文件系统
- `lxc.namespace.keep = net user` — 保留独立网络命名空间（容器有自己的 wlan0）
- `lxc.mount.entry = /dev/dri/card0 ...` — GPU 直通
- `lxc.mount.entry = /tmp/.X11-unix/X0 ...` — X11 socket 共享
- `lxc.mount.entry = /sys/devices/system/cpu ...` — CPU 频率读取（Chromium 需要）

---

## 常见问题

### 1. 重启后首次点击桌面图标没声音？

第二次运行即可。容器刚启动时 socat 还未完全连通 PulseAudio socket，
第二次运行自动重启 socat，音频恢复。

### 2. 桌面图标点了一下，终端闪一下就消失？

**原因：** sudo 需要密码，终端非交互模式被拒绝。
**解决：** 确认 `/etc/sudoers.d/fedora-desktop` 已按第 7 步配置。

### 3. 容器启动报 "failed to mount" 错误？

**原因：** UT 内核 4.9 不支持 OverlayFS 或 AUFS。
**解决：** 将容器配置中的 `lxc.rootfs.options` 改为 `dir` 存储后端，或参考第 2c 步手动挂载 cgroup2。

### 4. lxc-create 报 "Permission denied" 或 AppArmor 错误？

**原因：** UT 的 LXC 默认配置限制严格。
**解决：** 按第 2 步配置 `/etc/lxc/default.conf`，设置 `apparmor.profile = unconfined` 和 `namespace.keep = net user`。

### 5. "Failed to set process to user" 错误？

**原因：** LXC 在独立 user namespace 中运行，宿主办无法访问容器内进程。
**解决：** 这是正常行为，不影响容器运行。使用 `lxc-attach` 代替 `nsenter` 进入容器。

### 6. Chromium 启动报 "profile locked"？

```bash
sudo lxc-attach -n fedora42 -- su - phablet -c 'rm -f ~/.config/chromium/Singleton*'
```

或每次启动时用 `--no-session-restore` 参数。

### 5. 音频报 "Connection refused"？

检查宿主 PulseAudio socket 和 socat：

```bash
ls -la /run/user/32011/pulse/native
ss -tlnp | grep 32016
```

如果 socat 僵尸，杀进程组重启：

```bash
pkill -9 -f "socat.*32016"
socat TCP-LISTEN:32016,reuseaddr,fork UNIX-CONNECT:/run/user/32011/pulse/native &
```

### 6. 如何退出 XFCE？

在 XFCE 面板点击退出菜单，或直接杀掉 XFCE 进程：

```bash
sudo lxc-attach -n fedora42 -- pkill -f "xfce4-session|xfce4-panel"
```

XFCE 窗口关闭后，下次点击桌面图标会重新启动。

### 7. XFCE 窗口太小 / 字体模糊？

启动脚本已配置 192 DPI（2x 缩放），适合 1080×2340 屏幕。
如需调整，手动修改容器内的缩放配置文件：

```bash
# 查看当前缩放配置
sudo lxc-attach -n fedora42 -- cat /home/phablet/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml

# 手动调整 DPI 和缩放因子
sudo lxc-attach -n fedora42 -- su - phablet -c "cat > ~/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml << 'XML'
<?xml version=\"1.1\" encoding=\"UTF-8\"?>
<channel name=\"xsettings\" version=\"1.0\">
  <property name=\"Net\" type=\"empty\">
    <property name=\"ThemeName\" type=\"string\" value=\"Adwaita\"/>
    <property name=\"IconThemeName\" type=\"string\" value=\"Adwaita\"/>
  </property>
  <property name=\"Xft\" type=\"empty\">
    <property name=\"DPI\" type=\"int\" value=\"192\"/>
    <property name=\"Hinting\" type=\"int\" value=\"1\"/>
    <property name=\"HintStyle\" type=\"string\" value=\"hintslight\"/>
    <property name=\"RGBA\" type=\"string\" value=\"rgb\"/>
  </property>
  <property name=\"Gtk\" type=\"empty\">
    <property name=\"WindowScalingFactor\" type=\"int\" value=\"2\"/>
    <property name=\"FontName\" type=\"string\" value=\"Sans 14\"/>
    <property name=\"MonospaceFontName\" type=\"string\" value=\"Monospace 12\"/>
    <property name=\"IconSizes\" type=\"string\" value=\"gtk-menu=32,gtk-button=32,gtk-large-toolbar=48\"/>
  </property>
</channel>
XML"

# 重启 XFCE 生效
sudo lxc-attach -n fedora42 -- su - phablet -c 'DISPLAY=:0 xfce4-panel -r 2>/dev/null'
```

DPI 值参考（1080×2340 屏幕）：
- **192** = 2x 缩放（推荐，字体够大）
- **144** = 1.5x 缩放（偏小）
- **96** = 原生 1x（手机屏太小，不推荐）

---

> 本仓库地址：https://github.com/gmicroul/ubports-lxc