# Ubuntu Touch (Lomiri) + Fedora 42 XFCE 桌面嵌入方案

> 在 Ubuntu Touch 26.04 (OnePlus 6T) 上，通过 LXC 容器运行 Fedora 42，将 XFCE 桌面嵌入到 Lomiri 桌面窗口中。

## 原理

```
Lomiri 桌面 (Mir)
  ├── XWayland (宿主)
  │     └── X11 socket (/tmp/.X11-unix/X0)
  │           └── LXC 容器 (fedora42)
  │                 ├── XFCE 面板 → Lomiri 窗口
  │                 ├── XFCE 桌面 → Lomiri 窗口
  │                 ├── 应用窗口 → Lomiri 窗口
  │                 └── ...
  ├── PulseAudio (/run/user/32011/pulse/native)
  │     └── LXC 容器声音
  ├── D-Bus system bus (/run/dbus/system_bus_socket)
  └── GPU (/dev/dri/card0, /dev/dri/renderD128)
```

## 文件结构

```
ubports-lxc/
├── README.md          # 本文件
├── config/
│   ├── fedora42-lxc.conf       # 容器配置模板
│   ├── fedora42-real.conf      # 实际使用的配置
│   └── fedora42-wayland-hook.sh  # LXC hook 脚本
├── scripts/
│   ├── start-ut-xfce.sh        # 一键启动 XFCE
│   └── lxc-ut-fix.sh           # 历史修复脚本
└── configs/
    └── xfce/
        ├── xsettings.xml        # XFCE 缩放/字体配置 (192 DPI)
        └── xfwm4.xml            # XFCE 窗口管理器配置
```

## 启动方法

```bash
# 1. 启动容器 (如果没在跑)
sudo lxc-start -n fedora42 -d

# 2. 一键启动 XFCE 桌面
bash ubports-lxc/scripts/start-ut-xfce.sh
```

## 部署步骤 (从零开始)

### 容器创建
```bash
sudo lxc-create -n fedora42 -t download -- -d fedora -r 42 -a arm64
```

### 容器配置
```bash
sudo cp ubports-lxc/config/fedora42-lxc.conf /var/lib/lxc/fedora42/config
sudo chown root:root /var/lib/lxc/fedora42/config
```

### Hook 脚本
```bash
sudo cp ubports-lxc/config/fedora42-wayland-hook.sh /var/lib/lxc/fedora42-wayland-hook.sh
sudo chmod +x /var/lib/lxc/fedora42-wayland-hook.sh
```

### 安装 XFCE
```bash
sudo lxc-attach -n fedora42
dnf install -y --nogpgcheck @xfce-desktop
```

### 创建 phablet 用户 (对应宿主 uid 32011)
```bash
groupadd -g 32011 phablet
useradd -u 32011 -g 32011 -m -d /home/phablet -s /bin/bash phablet
usermod -aG video,render phablet
```

### 导入缩放配置
```bash
cp ubports-lxc/configs/xfce/xsettings.xml ~phablet/.config/xfce4/xfconf/xfce-perchannel-xml/
cp ubports-lxc/configs/xfce/xfwm4.xml ~phablet/.config/xfce4/xfconf/xfce-perchannel-xml/
chown phablet:phablet ~phablet/.config/xfce4/xfconf/xfce-perchannel-xml/*.xml
```

## 已知问题

1. **GPU 加速**: 当前使用 llvmpipe 软件渲染 (OpenGL 4.5)。DRI3 硬件加速需要 mesa 原生 EGL 支持
2. **PulseAudio**: socket 复制后 peer credential 验证失败 (用户命名空间映射问题)
3. **每次重启容器**: hook 脚本会自动复制 X11/PulseAudio/D-Bus socket 到 rootfs，但容器内 /run 是 tmpfs，需要手动 nsenter 修复设备节点
4. **Lomiri Wayland socket**: lomiri-system-compositor 启动后 unlink 了 socket 文件，导致 connect() 返回 ENOENT；仅 socat 抽象 socket 可代理

## 缩放 (1080×2340 手机屏)

- DPI: 192 (2x)
- WindowScalingFactor: 2
- 字体: Sans 14, Monospace 12
- 图标: gtk-menu=32, gtk-button=32, gtk-large-toolbar=48