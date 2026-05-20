# Ubuntu Touch 通用 LXC 桌面容器方案

在 Ubuntu Touch 26.04 / OnePlus 6T 上，用一个通用脚本创建、安装、启动和自检 LXC 桌面容器。

统一入口：

```bash
/home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh
```

目标很简单：不再只围绕 fedora42。现在 Fedora、Ubuntu、Debian 都走同一条链路，自动生成 config、hook、XFCE 配置、音频转发、桌面图标和自检逻辑。

当前支持：

- Fedora 42 + XFCE
- Ubuntu noble + XFCE
- Debian trixie/bookworm + XFCE
- Lomiri 内嵌 X11/XFCE 桌面
- PulseAudio 通过 socat TCP:32016 转发
- 自动生成 LXC config
- 自动生成容器 hook
- 自动创建容器内 phablet 用户 uid=32011
- 自动部署 XFCE 2x 缩放配置
- 自动安装 Lomiri 应用抽屉图标
- 图标启动使用 systemd transient unit 托管 Xephyr/XFCE，重启手机后可直接点图标进入桌面
- stop 清理桌面会话、Xephyr、音频转发和容器
- doctor 自检

---

## 一次性 bootstrap：以后直接用 lxc-create

先执行一次：

```bash
cd /home/phablet/ubports-lxc
sudo scripts/ut-lxc-desktop.sh bootstrap
```

bootstrap 会安装：

- `/usr/local/bin/lxc-create` wrapper
- `/etc/sudoers.d/ubports-lxc-desktop`

以后直接用系统习惯的 `lxc-create`：

```bash
sudo lxc-create -n ubuntu-noble -t download -- -d ubuntu -r noble -a arm64
```

创建完成后 wrapper 会自动对 Fedora/Ubuntu/Debian download 容器执行：

```bash
scripts/ut-lxc-desktop.sh configure -n <容器名> -d <发行版> -r <版本>
```

也就是自动写入 UT 兼容 LXC config、hook 和设备节点。之后如果要装桌面，执行：

```bash
sudo scripts/ut-lxc-desktop.sh install -n ubuntu-noble -d ubuntu -r noble
sudo scripts/ut-lxc-desktop.sh desktop-file -n ubuntu-noble -d ubuntu -r noble
```

如果你想 `lxc-create` 后直接连 XFCE 也装好，用 wrapper 自带开关：

```bash
sudo lxc-create --ut-install -n ubuntu-noble -t download -- -d ubuntu -r noble -a arm64
```

---

## 兼容旧流程：一条命令创建并安装桌面

### Fedora 42

```bash
cd /home/phablet/ubports-lxc
sudo scripts/ut-lxc-desktop.sh all -n fedora42 -d fedora -r 42
```

### Ubuntu Noble

```bash
cd /home/phablet/ubports-lxc
sudo scripts/ut-lxc-desktop.sh all -n ubuntu-noble -d ubuntu -r noble
```

### Debian Trixie

```bash
cd /home/phablet/ubports-lxc
sudo scripts/ut-lxc-desktop.sh all -n debian-trixie -d debian -r trixie
```

执行 `all` 会自动做：

1. `lxc-create` 创建容器
2. 写入 UT 兼容 LXC config
3. 写入容器启动 hook
4. 安装桌面包和工具
5. 创建容器内 `phablet` 用户
6. 部署 XFCE 手机缩放配置
7. 禁用不适合手机容器的 XFCE 后台服务
8. 写入音频环境变量和 Chromium 配置
9. 安装 sudoers 免密规则
10. 安装 Lomiri 桌面图标

---

## 启动/停止容器桌面

推荐使用应用抽屉图标启动。桌面图标会用 `sudo -n` 调起通用管理器，避免点图标时被 sudo 认证卡住。

已验证：手机重启后，直接点击下面两个图标都能进入桌面：

```text
fedora42 桌面
ubuntu24 桌面
```

图标启动链路现在走稳定模式：

1. wrapper 设置 `UT_LXC_FORCE_NEW_XEPHYR=1`，每次启动前重建 Xephyr 窗口，避免复用坏掉的旧 socket。
2. Xephyr 通过 `systemd-run --unit=ut-lxc-xephyr-<容器名>` 托管。
3. 容器内 XFCE 通过 `systemd-run --unit=ut-lxc-xfce-<容器名>` 托管。
4. `.desktop` 使用 `Terminal=false`，图标启动器退出后不会带走桌面进程。

命令行启动：

```bash
sudo /home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh start -n fedora42 -u phablet --uid 32011 --port 32016 --display-mode xephyr --display :20
```

Ubuntu 容器示例：

```bash
sudo /home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh start -n ubuntu24 -d ubuntu -r noble -u phablet --uid 32011 --port 32016 --display-mode xephyr --display :21
```

`--nested` 等价于 `--display-mode xephyr`，默认使用容器显示号 `:20`。如果同时保留多个容器桌面，建议显式指定不同 display，例如 fedora42 用 `:20`，ubuntu24 用 `:21`。

停止并清理桌面：

```bash
sudo /home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh stop -n fedora42 -u phablet --uid 32011 --port 32016 --display-mode xephyr --display :20
```

`stop` 会清理：

- `ut-lxc-xfce-<容器名>.service`
- `ut-lxc-xephyr-<容器名>.service`
- 容器内 `xfce4-session` / `xfwm4` / `xfdesktop` / `xfce4-panel` / `xfsettingsd`
- PulseAudio socat relay
- Xephyr socket/lock
- LXC 容器本身

日志位置：

```text
/tmp/ut-lxc-<容器名>-launcher-32011.log
/tmp/ut-lxc-<容器名>-xfce-host.log
/tmp/ut-lxc-<容器名>-xfce-in-container.log
/tmp/ut-lxc-xephyr-<容器名>.log
```

旧日志路径 `/home/phablet/.cache/ubports-lxc/logs/<容器名>-xfce.log` 仍可能存在，但图标启动/host launcher 的主日志现在优先看 `/tmp/ut-lxc-*`。

---

## 自检

```bash
/home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh doctor -n fedora42
```

doctor 会检查：

- 容器目录是否存在
- LXC config 是否存在
- hook 是否可执行
- 容器是否 RUNNING
- `/tmp/.X11-unix/X0` 是否存在
- `/run/user/32011/pulse/native` 是否存在
- TCP:32016 是否监听
- 容器内 `phablet` 用户是否存在
- 容器内 `/dev/null`、`/dev/zero` 是否正常
- 容器内 `xfce4-session` / `startxfce4` 是否在跑
- 容器内 `pactl info` 是否能连到 PulseAudio

---

## 通用脚本命令

```bash
scripts/ut-lxc-desktop.sh COMMAND [options]
```

命令：

```text
create        创建 LXC 容器
configure     生成/安装 UT 兼容 LXC config 和 hook
install       在容器内安装桌面、用户、音频、配置
repair        修复 /dev 节点并补完中断配置
sudoers       安装 NOPASSWD sudoers 规则
bootstrap     安装 lxc-create wrapper，以后 lxc-create 后自动 configure
start         启动容器、启动音频转发、启动 Xephyr/XFCE
stop          停止 XFCE、Xephyr、音频转发和容器
doctor        检查宿主/容器/显示/音频状态
desktop-file  安装 Lomiri 应用抽屉图标
all           create + configure + install + sudoers + desktop-file
```

常用参数：

```text
-n, --name NAME        容器名，例如 fedora42、ubuntu-noble
-d, --distro DISTRO    fedora|ubuntu|debian
-r, --release RELEASE  发行版版本，例如 42、noble、trixie
-a, --arch ARCH        arm64/aarch64
-u, --user USER        容器内桌面用户，默认 phablet
--uid UID              容器内桌面用户 uid/gid，默认 32011
--desktop NAME         当前支持 xfce
--port PORT            PulseAudio 转发端口，默认 32016
--display DISPLAY      X11 display，direct 默认 :0，xephyr 默认 :20
--display-mode MODE    direct|xephyr
--nested               等价于 --display-mode xephyr
--nested-size WxH      Xephyr 窗口尺寸，默认 1280x720
--nested-dpi DPI       Xephyr DPI，默认 168
--nested-fullscreen 0|1 是否 fullscreen，默认 1
```

---

## 兼容旧 Fedora 42 入口

旧文件还保留，但只是 wrapper：

```text
scripts/start-xfce.sh
scripts/restore-xfce.sh
config/start-fedora-desktop.sh
```

它们都会转调：

```bash
/home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh start -n fedora42 -d fedora -r 42
```

旧的 `restore-xfce.sh` 里使用 TCP:32015 的方案已废弃。现在统一使用 TCP:32016，避免和 PulseAudio TCP module 形成环路。

---

## 架构

```text
direct 模式：

容器应用
  ↓
DISPLAY=:0 / X11 socket
  ↓
/tmp/.X11-unix/X0 copied by hook
  ↓
Lomiri/XWayland/X server

xephyr / nested 模式：

容器 XFCE 整个桌面
  ↓
DISPLAY=:20 / X20 socket
  ↓
ut-lxc-xfce-<容器名>.service
  ↓
宿主 Xephyr 窗口
  ↓
ut-lxc-xephyr-<容器名>.service
  ↓
Lomiri 里的单个窗口

容器应用音频
  ↓
PULSE_SERVER=tcp:127.0.0.1:32016
  ↓
socat TCP-LISTEN:32016
  ↓
/run/user/32011/pulse/native
  ↓
Ubuntu Touch PulseAudio
  ↓
手机扬声器
```

容器使用：

```text
lxc.namespace.keep = net user
```

所以容器内的 `localhost` 是容器自己的 loopback。socat 监听宿主 `0.0.0.0:32016`，容器才能连到宿主转发通道。

---

## 生成的 LXC config 包含什么

`configure` 会写入：

```text
/var/lib/lxc/<容器名>/config
/var/lib/lxc/<容器名>/ut-desktop-hook.sh
```

关键配置：

```text
lxc.apparmor.profile = unconfined
lxc.autodev = 0
lxc.namespace.keep = net user
lxc.cgroup2.devices.deny = a
lxc.mount.entry = /dev/null dev/null none bind,create=file 0 0
lxc.mount.entry = /dev/zero dev/zero none bind,create=file 0 0
lxc.mount.entry = /dev/random dev/random none bind,create=file 0 0
lxc.mount.entry = /dev/urandom dev/urandom none bind,create=file 0 0
lxc.mount.entry = /dev/dri dev/dri none bind,create=dir,optional 0 0
lxc.mount.entry = /dev/input dev/input none bind,create=dir,optional 0 0
lxc.mount.entry = /sys/devices/system/cpu sys/devices/system/cpu none bind,ro,create=dir,optional 0 0
```

hook 负责：

- 复制 X11 socket 到容器 rootfs
- 复制 Wayland socket 作为备用
- 复制 system D-Bus socket
- 创建 /dev/null、/dev/zero、/dev/random、/dev/urandom

---

## sudoers

桌面图标启动用 `sudo -n`，所以要先安装免密规则：

```bash
sudo scripts/ut-lxc-desktop.sh sudoers
```

当前规则只放行这个管理器和 lxc-create wrapper。

---

## 常见问题

### 点图标没反应

先看日志，不要盲猜：

```bash
less /tmp/ut-lxc-<容器名>-launcher-32011.log
less /tmp/ut-lxc-<容器名>-xfce-host.log
less /tmp/ut-lxc-<容器名>-xfce-in-container.log
journalctl -u ut-lxc-xephyr-<容器名>.service -u ut-lxc-xfce-<容器名>.service --no-pager -n 120
```

再跑：

```bash
sudo /home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh doctor -n <容器名> --display-mode xephyr --display :20
```

如果旧进程残留，先 stop 再点图标：

```bash
sudo /home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh stop -n <容器名> --display-mode xephyr --display :20
```

### 没声音

检查：

```bash
ss -tlnp | grep 32016
/home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh doctor -n <容器名>
```

如果 socat 僵死，脚本会先杀旧 socat 进程组，再起新的。

### 容器启动失败

看 LXC 日志：

```bash
less /tmp/<容器名>.log
```

### XFCE 字太小

默认已经部署 2x 缩放配置：

```text
configs/xfce/xsettings.xml
configs/xfce/xfwm4.xml
```

如果是旧容器，重新执行：

```bash
sudo /home/phablet/ubports-lxc/scripts/ut-lxc-desktop.sh install -n <容器名> -d <fedora|ubuntu|debian> -r <release>
```

---

## 文件说明

```text
scripts/ut-lxc-desktop.sh        通用容器桌面管理器，负责 create/configure/install/start/stop/doctor
scripts/start-xfce.sh            fedora42 兼容 wrapper
scripts/restore-xfce.sh          fedora42 兼容 wrapper，旧 32015 方案已废弃
scripts/lxc-ut-fix.sh            旧 UT LXC 修复脚本，保留参考
config/start-fedora-desktop.sh   旧 fedora42 桌面图标 wrapper
config/fedora42-desktop.desktop  旧 fedora42 desktop 文件
configs/xfce/xsettings.xml       XFCE 2x 缩放配置
configs/xfce/xfwm4.xml           XFWM4 手机窗口配置
```

---

## 结论

现在项目主线是：

```text
一次 bootstrap + 以后直接用 lxc-create + 自动 configure + 图标 systemd 托管启动
```

如果你加 `--ut-install`，还能在创建时顺手把桌面也装上。桌面启动主线是 Xephyr/XFCE 都交给 systemd transient unit 托管，实测手机重启后直接点击 fedora42/ubuntu24 图标可进入桌面。
