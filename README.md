# systemmon —— OpenWrt 本机 / 局域网设备状态监控

一个自包含的 OpenWrt 监控插件：在路由器上以 Web 服务形式（默认 **7752** 端口）发布仪表盘，
展示本机 CPU / 内存 / 温度、PON 光模块温度与收发光功率，以及局域网内其它设备的在线状态。

* 纯 Shell（busybox ash）+ 静态页面，无编译产物，`PKGARCH:=all`
* 同一份源码既能打成 **.ipk**（opkg / OpenWrt 23.05、24.10 及各衍生版），也能打成 **.apk**（apk-tools 3 / OpenWrt 主线、snapshot）
* 没有常驻采集进程：指标按请求即时采集，设备探测结果按 `device_interval` 缓存，空闲时几乎零开销
* 页面无任何外部依赖（不引用 CDN），断网也能正常打开
* 默认中文，跟随系统深色/浅色模式

## 功能

| 模块 | 数据来源 |
| --- | --- |
| CPU 占用 / 各核心 / 负载 | `/proc/stat`、`/proc/loadavg`（两次采样做差） |
| 内存 / 交换 | `/proc/meminfo` |
| SoC 温度 | `/sys/class/thermal/thermal_zone*/temp`，退化为 `hwmon` |
| PON 温度、Rx/Tx 光功率 | `ponctl --device ponX status --json`（固件自带 `airoha-ponctl`）；无 ponctl 时可退回 `ethtool -m` / `hwmon` / 自定义命令 |
| 网口速率 | `/proc/net/dev` |
| 局域网设备 | 扫描 br-* 网段（并发 ping）+ ARP 表 + DHCP 租约，确认后加入监控；ICMP 或 TCP 端口探测 |
| 远程节点 | 插件 / SSH / Telnet 三种方式接入其它设备，在同一页面查看它的全部指标 |

## 安装

### 1. 已编译进固件（推荐）

把 `luci-app-systemmon` 放进 OpenWrt 源码的 `package/` 下，并在 `.config` 里启用：

```
CONFIG_PACKAGE_systemmon=y
CONFIG_PACKAGE_luci-app-systemmon=y
```

本仓库已经接入 `Scripts/Packages.sh` 与 `Config/AIROHA-TCBOOT.txt`，正常 CI 编译出的固件里会直接带上，
LuCI 菜单在 **状态 → 设备监控**，也可以直接访问 `http://路由器IP:7752/`。

也可以把本仓库直接当作 feed 使用（仓库根目录就是 `luci-app-systemmon/`）：

```
# feeds.conf.default
src-git systemmon https://github.com/wangqing911022/luci-app-systemmon.git
```

```sh
./scripts/feeds update systemmon
./scripts/feeds install -a -p systemmon
```
### 2. 安装 .apk（apk-tools 3 的固件，即 OpenWrt 主线 / snapshot 及衍生版）

用 GitHub Actions 里的 `BUILD-PKG` 工作流构建（apk 一档使用 snapshot SDK，
因为官方 24.10 SDK 仍是 opkg，只能出 ipk）：

```sh
scp systemmon-1.3.0-r1.apk luci-app-systemmon-1.3.0-r1.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
apk add --allow-untrusted /tmp/systemmon-1.3.0-r1.apk /tmp/luci-app-systemmon-1.3.0-r1.apk
```

如果设备上带 `apk mkpkg`，也可以直接在路由器上打包：

```sh
sh Tools/mkpkg-on-device.sh /tmp
```

### 3. 安装 .ipk（opkg 系固件，含 23.05、24.10 及 ImmortalWrt）

Windows 本机无需工具链即可打包：

```powershell
powershell -ExecutionPolicy Bypass -File Tools/build-ipk.ps1
# 产物：dist/systemmon_1.3.0-1_all.ipk
#       dist/luci-app-systemmon_1.3.0-1_all.ipk
```

```sh
opkg install systemmon_1.3.0-1_all.ipk luci-app-systemmon_1.3.0-1_all.ipk
```

安装后服务会自动启用并启动；手动操作：

```sh
/etc/init.d/systemmon enable
/etc/init.d/systemmon restart
```

### 4. 通用安装包（任何 OpenWrt，无需 opkg/apk）

适合 apk 系固件、没有 LuCI 的精简固件、或不想等 CI 的场景。纯文件拷贝，不注册包管理器。

```powershell
# PC 上生成（产物在 dist/systemmon-1.3.0-manual.tar.gz）
powershell -ExecutionPolicy Bypass -File Tools/build-manual.ps1
```

```sh
scp dist/systemmon-1.3.0-manual.tar.gz root@目标IP:/tmp/
ssh root@目标IP
cd /tmp && tar -xzf systemmon-1.3.0-manual.tar.gz
sh systemmon-1.3.0/install.sh
```

安装脚本会自动停止旧实例、复制文件、设置权限、`enable` 并启动，最后自检并打印访问地址。
已存在的 `/etc/config/systemmon` 会被保留。

卸载（`--purge` 连配置一起删）：

```sh
sh systemmon-1.3.0/uninstall.sh
```

## 装到别的路由器时要注意

* **架构无关**：包内全是脚本和静态文件（`PKGARCH:=all`），aarch64 / mips / x86_64 通用。
* **几乎无依赖**：只需要 busybox + `uhttpd`（缺失时 init 脚本自动退回 `busybox httpd`），
  不需要 jq / python / lua。内存占用只有请求时的那点进程开销。
* **PON 数据**：只有带 `airoha-ponctl` 的 Airoha 设备能直接读到光功率。其它设备/PON stick 会在
  `状态 → 设备监控` 里显示“未检测到”，可在设置里指定 `sfp_iface`（用 `ethtool -m` 读 SFP DDM）
  或 `pon_command`（自定义命令输出 key=value）。先看 `/cgi-bin/diag` 确认真实数据源。
* **端口**：默认 7752，冲突时改 `/etc/config/systemmon` 的 `port` 后 `restart`。
* **安全**：默认无登录。跨网段/访客网络建议设 `allow_cidr` 或 `auth_user`。

## 配置


配置文件 `/etc/config/systemmon`，也可以直接在网页右上角“设置”里改。

```uci
config systemmon 'main'
	option enabled '1'
	option bind '0.0.0.0'
	option port '7752'
	option refresh '3'            # 页面刷新间隔（秒）
	option device_interval '30'   # 每台设备多久轮询一次（分批探测，开销平滑）
	option ping_timeout '1'       # 单设备探测超时（秒）
	option max_devices '32'
	option scan_interval '120'    # 扫描结果缓存（秒）
	option scan_max '512'         # 单次最多扫描地址数
	option scan_subnet ''         # 留空自动取所有 br-* 网段，也可写 192.168.1.0/24,10.0.0.0/24
	option discover_leases '1'    # 发现时合并 DHCP 租约的名称/MAC
	option discover_arp '1'       # 发现时合并 ARP 表（找出不响应 ICMP 的设备）
	option allow_cidr ''          # 例：192.168.1.0/24，留空不限制
	option auth_user ''           # 留空不启用登录
	option auth_password ''
	list ignore '192.168.1.50'    # 发现列表中忽略的地址（网页里可随时取消）

config device
	option name 'NAS'
	option address '192.168.1.10'
	option type 'ping'            # ping | tcp
	# option port '80'            # type=tcp 时使用

config pon 'pon'
	option enabled '1'
	option device ''              # 留空自动识别（ponctl list 的第一个设备）
	option sfp_iface ''           # 无 ponctl 时，用 ethtool -m 读该网口
	option command ''             # 自定义采集命令，优先级最高

config node
	option name '客厅路由'
	option type 'plugin'          # plugin | ssh | telnet
	option url 'http://192.168.1.2:7752'   # type=plugin 时使用
	# option host '192.168.1.160'          # type=ssh/telnet 时使用
	# option port '22'                     # 默认 ssh 22 / telnet 23
	option user ''                # ssh/telnet 账号，或 plugin 的 Basic 认证用户
	option password ''
	option enabled '1'
```

改完执行 `/etc/init.d/systemmon restart` 使端口/监听地址生效；其它选项每次请求都会重新读取。

## 局域网设备：发现 → 确认 → 监控

设备卡片有两个页签：

- **已监控**：真正在被探测的设备，每行有“删除”
- **发现**：扫描到的在线设备，可单台“添加 / 忽略”，或一次“添加全部 N 台”

扫描做了什么：

1. 对 `br-*` 网段（或 `scan_subnet`）并发 ping（64 并发、1 秒超时），`/24` 约 4 秒
2. 合并 `/proc/net/arp`，把屏蔽 ICMP 但 ARP 可达的设备也列出来
3. 用 `/tmp/dhcp.leases` 补上名称与 MAC

结果按 `scan_interval` 缓存，重复打开“发现”页签不会反复扫描；点“重新扫描”强制刷新。
扫描带锁，多个页面同时打开也只会跑一次。

被“忽略”的地址写入 `systemmon.main.ignore`，仍会灰显在列表底部，可随时“取消忽略”。
“已监控”列表只包含确认过的设备，不会再把租约/ARP 里的设备自动混进来。

添加到监控默认用 Ping；目标若禁 ICMP，可在“添加设备”里改用 TCP 端口。

## 远程节点（三种接入方式）

“设置 → 远程节点”里可以按三种方式添加其它设备，页面顶部会出现切换条：`本机` / `客厅路由` …

### 1. 插件（默认，指标最全）

对方也装本插件，填 `http://IP:7752`。数据由**浏览器直接请求节点**（`/cgi-bin/status`、`/cgi-bin/devices`）：

- 打开页面的电脑/手机必须能访问该节点；两台路由器之间不要求互通
- 节点需运行 **1.3.0 及以上**（更早的版本没有 CORS 响应头）
- 节点开了 Basic 认证时，填用户名密码即可
- 能拿到设备列表，但列表是只读的

### 2. SSH（对方不装插件）

填 IP、端口（默认 22）、账号密码。由**本机**登录对方执行一条只读采集命令，取 `/proc/stat`、
`/proc/meminfo`、`thermal_zone`、`ponctl`（若有）。要求：

- 监控端需要 **openssh-client**（`apk add openssh-client`）。dropbear 自带的 `ssh` 无法免交互输密码
- 对方是 busybox/Linux shell 即可；老版本 dropbear 只支持 `ssh-rsa` 时会自动降级重试
- 采集约 2 秒，结果缓存 45 秒
- 没有设备列表（只读指标）

### 3. Telnet（对方不装插件）

填 IP、端口（默认 23）、账号密码。由本机通过 `nc` 建立连接、脚本化登录后执行同样的采集命令。要求：

- 监控端有 `nc`
- 对方登录后是 shell（busybox 亦可）
- 采集约 8 秒，结果缓存 45 秒；登录后会自动 `stty -echo` 避免回显干扰
- 光功率读取：目标若有 `opticaltst` 会自动解析（SFF-8472 原始值换算）；有 `ponctl` 则优先用 ponctl
- 目标有 `/proc/cpuusage`（直接给每核占用）和 `/proc/tempsensor`（板温）时优先采用，不再做两次采样

### 通用说明

- 切换节点后整套指标（CPU、内存、温度、PON）都换成该节点的数据，与本机同一层级
- 节点离线时顶部按钮圆点变灰，页面显示具体原因
- 重复添加同一地址返回 409
- SSH/Telnet 的账号密码保存在 `/etc/config/systemmon` 里（明文），配置文件权限与 root 登录等价

## PON 数据源

按以下顺序尝试，命中即止：

1. `systemmon.pon.command` 自定义命令
2. `ponctl --device <设备> status --json`
3. `ethtool -m <sfp_iface>`
4. `/sys/class/hwmon` 中名字含 `sfp` / `optic` / `pon` 的传感器

自定义命令需要输出 `key=value` 行，可用键：

```
temp=45.2        # 模块温度 ℃
rx=-18.5         # 接收光功率 dBm
tx=2.1           # 发送光功率 dBm
state=O5         # 状态文本（O1-O7 会自动翻译）
mode=gpon
serial=ABCD1234
onu_id=1
```

例如 Airoha 平台可以自己解析后输出：

```uci
option command 'ponctl -d pon0 status --json | sed -n "s/.*\"rx_power_dbm\": *\([-0-9.]*\).*/rx=\1/p"'
```

打开 `http://路由器IP:7752/cgi-bin/diag` 可以看到 ponctl 是否存在、原始输出、温度传感器与 hwmon 列表，
便于确认数据的真实来源。若面板上 PON 显示“未检测到”，先看这个页面。

## HTTP 接口

| 路径 | 说明 |
| --- | --- |
| `/` | 仪表盘 |
| `/cgi-bin/status` | 本机指标 JSON |
| `/cgi-bin/devices` | 设备列表 JSON（带缓存） |
| `/cgi-bin/discover` | 局域网扫描结果 JSON（`?rescan=1` 强制重扫） |
| `/cgi-bin/config` | GET 读取配置；POST 修改（浏览器跨站请求会被拒绝） |
| `/cgi-bin/diag` | 采集环境自检（纯文本） |

所有接口共用同一套访问控制：`allow_cidr` 限制来源网段，`auth_user` 启用 HTTP Basic 认证。
`/cgi-bin/status` 与 `/cgi-bin/devices` 会返回 `Access-Control-Allow-Origin: *`，供远程节点跨源读取；
修改类请求用 Origin / Referer 做同源校验（uhttpd 不透传自定义请求头），第三方网页无法跨站提交。

## 安全提示

* 服务默认监听 `0.0.0.0:7752` 且**没有登录**。只在可信局域网使用时通常没问题；
  若网络里还有访客设备，建议设置 `allow_cidr`（如 `192.168.1.0/24`）或开启 Basic 认证。
* `status` / `devices` 允许跨源读取（远程节点要用），所以同网段内任何网页都能读到这些只读指标；
  开启 Basic 认证后，未带凭据的跨源请求会得到 401。
* `pon_command` 会以 root 执行，等同于 SSH 权限，不要填不可信内容。
* 页面通过 CGI 读取系统信息，不开放任意命令执行接口。

## 打包

| 目标 | 方法 |
| --- | --- |
| `.ipk` / `.apk`（官方格式） | GitHub Actions → `BUILD-PKG` 工作流（23.05 SDK 出 ipk，snapshot SDK 出 apk） |
| `.ipk`（本机无工具链） | `Tools/build-ipk.ps1` |
| `.apk`（设备上有 apk mkpkg） | `Tools/mkpkg-on-device.sh` |
| 编译进固件 | `CONFIG_PACKAGE_systemmon=y` |

`BUILD-PKG.yml` 里 ipk 一档的 SDK 地址写死为 `23.05.5`；apk 一档在运行时从
`downloads.openwrt.org/snapshots/targets/x86/64/` 解析最新的 SDK 文件名，无需手工维护。

## 目录结构

```
luci-app-systemmon/
├── Makefile                         # 两个子包：systemmon / luci-app-systemmon
├── files/                           # systemmon 的根文件系统
│   ├── etc/config/systemmon
│   ├── etc/init.d/systemmon         # procd 拉起独立 uhttpd 实例（缺 uhttpd 时用 busybox httpd）
│   ├── etc/uci-defaults/95-systemmon
│   └── usr/
│       ├── libexec/systemmon/       # common.sh system.sh pon.sh devices.sh
│       └── share/systemmon/www/     # index.html app.css app.js favicon.svg + cgi-bin/*
└── luci/                            # luci-app-systemmon：菜单项 + iframe 视图
Tools/
├── build-ipk.ps1                    # Windows 下直接生成 ipk
├── build-manual.ps1                 # 生成通用安装包 tar.gz（免包管理器）
├── install-any.sh                   # 通用安装脚本
├── uninstall-any.sh                 # 通用卸载脚本
└── mkpkg-on-device.sh               # 设备上用 apk mkpkg 生成 apk
```
