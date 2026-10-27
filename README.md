# luci-app-fcc

**简体中文** | [English](README.en.md)

在 OpenWrt / ImmortalWrt 的 LuCI 网页界面里管理
[FCC（Free Claude Code）](https://github.com/Alishahryar1/free-claude-code)
及其编程 Agent。

一个软件包，三个页面：

| 页面 | 作用 |
| --- | --- |
| **Web 终端** | Claude Code、Codex、Pi、OpenCode、Cline、Hermes、DeepSeek Harness、Grok Build、Muse Code、Aider 的真正交互式终端——每个 Agent 一个 tmux 会话，直接在浏览器里用。 |
| **配置** | 服务器设置（地址、端口、日志级别）、安装与备份路径、Agent 选择、安装/卸载/彻底卸载、更新、启动/停止/重启、诊断报告、FCC Admin 入口（运行信息每 2 秒刷新，后台标签页暂停），以及通过 SSH 控制局域网内另一台机器。 |
| **基本信息** | 版本、状态、PID、运行时长、RSS 内存、CPU 与硬件平台、系统内存与存储。 |

`luci-app-fcc` **只是控制层**：只包含 Lua、JavaScript 和 POSIX shell，**不包含** Python、
Node.js、`uv`、FCC 运行时或任何编程 Agent——它们按需单独安装在 `/opt/fcc` 下。

![Web 控制台：在 LuCI 界面里运行的 Claude Code 会话](screenshot.png)

---

## 安装

OpenWrt 24.10：

```sh
opkg install luci-app-fcc_*.ipk
opkg install luci-i18n-fcc-zh-cn_*.ipk   # 中文界面需额外安装
```

OpenWrt 25.12：

```sh
apk add --allow-untrusted luci-app-fcc-*.apk
apk add --allow-untrusted luci-i18n-fcc-zh-cn-*.apk   # 中文界面需额外安装
```

`.ipk` 与 `.apk` 是两种不同的包格式，由 CI 用对应版本的 SDK 构建——把 `.ipk` 改名成
`.apk` 得到的不是安装包，装不上。

然后打开 `LuCI → 服务 → FCC智能体`。三个页面装完即可使用。

英文界面随 `luci-app-fcc` 一起安装；简体中文目录在单独的 `luci-i18n-fcc-zh-cn` 包里，
LuCI 界面语言为中文时会自动加载，无需配置、无需重启。两个包互相独立，可分别升级和卸载。

### 从源码编译

要把本包裁剪进固件或自行调整时，把它放进 OpenWrt 构建树，和其他包一起编译：

```sh
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a
git clone https://github.com/Arthur97172/luci-app-fcc.git package/luci-app-fcc
make menuconfig   # LuCI → Applications → luci-app-fcc
make package/luci-app-fcc/compile V=s
```

产物在 `bin/packages/<架构>/` 下。同一份源码在 24.10 的构建树里得到 `.ipk`，在 25.12
的构建树里得到 `.apk`；`VERSION` 与 `PKG_RELEASE` 决定包名中的版本号。

---

## 首次使用

**1. 安装 FCC 运行时。** 在*配置*页面选择 Agent，点 **安装**。页面通过 HTTPS 拉取官方
安装器、记录其 SHA-256 后执行；Python、`uv` 和运行时本身都装在配置的安装路径下（默认
`/opt/fcc`），不进入本软件包。

* 下拉框默认是 **全部智能体**（整个注册表）：下载极慢，约占 8 GB 存储。建议只选需要的
  Agent——只选一个时只装它（缺运行时就一并装好），其他已安装的 Agent 原样保留。运行时
  已存在而仍选 **全部智能体** 时，页面会先确认，再移除运行时并全部重装：上游不会重装
  已存在的 Agent，这是替换损坏安装的唯一方式。
* **安装路径所在的文件系统至少要有 2 GB 可用，推荐 4 GB。** 不够时本包在下载前就拒绝，
  并写明还差多少。运行时实测峰值约 741 MB；更新期间新旧两套并存、`uv` 缓存会增长，这些
  都要吃掉余量。回滚副本放在 **备份路径**（默认 `/tmp/fcc`，内存盘，不占闪存），运行
  结束即删除。
* 安装器只在 `/dev/tty` 上提问，没有任何开关可以绕过。本包把它放进 `tmux` 会话，按所选的
  Agent 逐条作答，并把整个画面写进 `<安装路径>/logs/installer.out`——安装失败时先看这里。
* **进度条不是估计值**：运行期间逐渐趋近 95% 后停住，锁被释放（任务真正结束）才到 100%。
* **日志是追加写入的**，页面只显示最后一个 `===== fcc job start … =====` 之后的内容。
  更早的记录直接读 `<安装路径>/logs/fcc-runtime.log`（安装）或 `fcc-update.log`（更新）；
  安装路径不可写时退到 `/tmp/fcc-logs/`。
* 任务运行中再点安装或更新会被拒绝（`another install/update is already running`）；被强行
  打断留下的锁最长一小时后失效。

**2. 配置。** 设置地址和端口，点 **Open FCC Admin** 添加服务商凭据。API 密钥只在 FCC 自己
的管理界面里填写，从不写入 UCI。安装路径与备份路径随时可改；改安装路径不会移动已有运行时。

> 除非确需从其他设备访问 FCC Admin，请把地址保持为 `127.0.0.1`。本包会覆盖 FCC 默认的
> `0.0.0.0`，并且不接受非字面 IP 的绑定地址。

**3. 使用 Agent。** 在 *Web 终端* 页面选择 Agent 并按 **Start**，每个 Agent 的会话命名为
`fcc-<agent>-NNN`。

**4. 更新。** *配置* → **FCC 运行时** → **Check for updates** → **Update FCC**。检查只在
点按钮时执行，打开或切回标签页不会联网；**彻底卸载**之后的 **Clear record** 同时清掉版本表
和任务记录（进度条与日志），回到"尚未检查"并禁用 **Update FCC**。更新是一串步骤：检查剩余空间、提示仍打开的终端、
保存状态、停止服务器、重新安装、校验二进制、重启，最后确认服务器在响应才报告成功。

任何一步失败都会把之前的运行时放回去。旧运行时目录是被*改名*挪到一边的（同一文件系统上
瞬间完成、不占额外空间），`data/` 是复制的。回滚后日志写 `Previous FCC version restored`，
或 `FCC Server remains stopped. Please inspect logs.`。LuCI 本身不受影响。

---

## 局域网控制

*配置* → **FCC 服务器** 有一个 `[本机] [局域网]` 开关。切到 `[局域网]` 后，同一区域的
**启动**、**停止**、**重启**、**Open FCC Admin** 作用于另一台机器上的 FCC 服务器——一次
一台，Windows、Linux、macOS、OpenWrt 都可以。

1. 填好 **IP 地址** 和 **用户名**，点 **生成并配置密钥**。路由器在 `/etc/fcc/ssh/` 下生成
   Ed25519 密钥并显示公钥，把它加进远程账号的 authorized_keys——页面会按所选平台写出具体
   路径：Linux 是 `/home/<账号>/.ssh/authorized_keys`（root 为 `/root/.ssh/authorized_keys`），
   macOS 是 `/Users/<账号>/.ssh/authorized_keys`（还需在“系统设置 → 通用 → 共享”里打开
   **远程登录**），OpenWrt 的 Dropbear 读 `/etc/dropbear/authorized_keys`，Windows 管理员账户用
   `C:\ProgramData\ssh\administrators_authorized_keys`、标准账户用
   `C:\Users\<账号>\.ssh\authorized_keys`。本包不保存也不询问密码：连接只提供这把密钥
   （`PreferredAuthentications=publickey`、`BatchMode=yes`、`IdentitiesOnly=yes`）。
2. 点 **测试连接**。第一次显示远程主机密钥指纹并要求确认，确认后写入 UCI，此后每次连接都
   要求完全一致；指纹变了就拒绝并报告实际读到的值。
3. 这时四个按钮才可用。发送的命令由 *高级设置* 里的 **远程平台** 决定，Linux 和 OpenWrt
   都是先问那台机器有没有服务，没有就用它自己的启动器：

   - **Linux**：`systemctl cat <服务名>.service` 能读到单元就 `systemctl <op>`；读不到
     ——上游 `uv tool install` 装出来的机器就是这样——就改用启动器：`fcc-server` 在后台
     启动，输出追加到 `~/.fcc/server.log`，停止时按进程列表找到它。
   - **OpenWrt**：有 `/etc/init.d/<服务名>` 就用它，没有就同样用启动器。
   - **macOS**：一律用启动器（上游安装不注册 launchd 任务）。
   - **Windows**：发送一行 PowerShell，先问那台机器有没有同名服务：有就跑
     `Start-Service`/`Stop-Service`/`Restart-Service`；没有服务——`install.ps1` 装完就是
     这样——就改用上游安装自带的服务器，用 `fcc-server` 在后台隐藏启动、按进程列表停止，
     因为那个安装脚本不注册 Windows 服务。

   服务名只接受字母、数字和 `.` `-` `_`。

启动器那条路需要那台机器上有 `pgrep`（Linux、macOS、OpenWrt 默认都有），因为“起没起来”、
“停没停掉”要问进程列表。失败时页面说的是具体的那一种：那台机器上没装 FCC Server 就提示先
安装；启动了但没起来，就把 `~/.fcc/server.log` 的位置写出来；没有 `pgrep` 就直说，而不是
把按钮的行为说得比实际多。**网页控制台**不受影响：它的局域网模式直接询问那台机器自己的
shell——Linux 和 macOS 是 `sh`，Windows 是 PowerShell，都先把安装脚本写入的目录加进
`PATH`——能列出并可启动它的智能体；运行状态先问服务管理器，没有对应单元或服务时改看
进程列表，所以手工启动的服务器不会被报成“已停止”。

服务器在运行时，局域网面板显示和 `[本机]` 一样的六行：运行中、版本、进程 ID、已运行时长、
内存 (RSS)、监听于。装了本包的机器由它自己的 `status.sh` 回答；只装了上游运行时的机器
（Linux、macOS、OpenWrt 上都没有 `status.sh`）改问它自己的进程列表和启动器：PID、内存和
运行时长取自该进程，监听地址取自 `ss`、`lsof` 或 `netstat` 里它的监听套接字，版本来自
`fcc-server --version`（上游说明该用法安全）。哪一项读不到就显示 `—`，不会编造。

**只接受私有 IPv4 地址**（`10/8`、`172.16/12`、`192.168/16`、`169.254/16`）；主机名一律
拒绝，因为一个名字可能解析成公网地址。

远程 FCC Admin 也只对回环地址开放，所以 **Open FCC Admin** 不会直接打开
`http://<远程IP>:8082`：LuCI 代理先建立 SSH 本地转发
`ssh -N -L 127.0.0.1:18082:127.0.0.1:<Admin 端口>`，再把请求交给隧道这一端——远程看到的是
回环对端，浏览器访问仍经过 LuCI 登录。隧道在第一次打开 Admin 时建立，离开局域网模式时关闭。
这要求那台机器的 sshd 允许**本地**转发（`AllowTcpForwarding`，默认 `yes`；只开本地用
`local`）。Linux 机器上这件事由按钮自己完成，不用手工改配置：**启动** 先在那里写入
`/etc/ssh/sshd_config.d/00-fcc-local-forwarding.conf`（内容只有一行
`AllowTcpForwarding local`），再用 `sshd -t` 校验、通过后重载 sshd，然后才启动服务器；
**停止** 删掉这个文件再重载；**重启** 先删后写。文件名排在其它 `sshd_config.d/*.conf`
之前，而 sshd 采用它读到的**第一个**值，所以即便那里早有一份 `AllowTcpForwarding no`，
这个文件也能生效，那份文件本身保持原样。写入 `/etc/ssh` 需要 root：账户是 root 就直接写，
否则用 `sudo -n`；两者都不行时按钮照常启停服务器，只把这一步的结果作为一句提醒显示出来
——无权修改、同名文件不是本包写的、`sshd -t` 拒绝了这份配置（已回滚）、重载失败，各有
各的说法，都不算启动或停止失败。macOS 和 OpenWrt 的 sshd 不读这个目录，这两类机器上
不做任何改动。

转发被关成 `no` 又没法从这里改时，打开 Admin 会得到 502，页面直接说明是那台机器的 sshd
拒绝了转发并指出要改的设置，而不是只报一句 `Connection reset by peer`。

连接需要**路由器上**有 OpenSSH 客户端（远程机器上的不算）。Dropbear 也提供 `/usr/bin/ssh`，
但不支持这里用到的选项，页面会直接说明。缺少时按提示安装：

```sh
opkg install openssh-client-utils     # 24.10 及更早
apk add openssh-client-utils          # 25.12 及以后
```

*高级设置* 里可以改 SSH 端口、远程平台、Admin 端口和服务名，查看每个按钮实际发送的命令，
以及查看或忘记已固定的主机指纹。改 IP 或 SSH 端口会自动忘记指纹。

---

## 依赖

作为依赖自动安装：

```
luci-base  luci-compat  curl  ca-bundle  tmux
```

`tmux` 不是可选项：它是 Web 终端所驱动的终端后端。

* **`tar`** 刻意不在依赖里，但 busybox tar 不够用：`uv` 用
  `tar xf … --no-same-owner --strip-components 1` 解包，busybox 两个选项都不支持。诊断报告
  会**真的解一次归档**来判定。不能直接列成依赖，是因为 25.12 上的变体门控（`TAR_XZ` 开、
  `xz-utils` 关）会让本包无法被选中——改为在安装前自动补齐。
* **`bash`**：Claude Code、OpenCode、Hermes、Grok Build、Muse Code 的安装脚本需要它。未被
  选中时诊断只给 WARN，选中时给 FAIL 并附安装命令；安装前预检会自动装上。
* **`cline`** 装不了：Cline 只发布 glibc 构建，没有 musl 版本，而 OpenWrt 是 musl。它会被
  从选中的集合里去掉并说明原因；若它是唯一要装的 Agent，安装以 `AGENT_UNSUPPORTED` 拒绝。
  上游的 musl 构建请求见 [cline/cline#15271](https://github.com/cline/cline/issues/15271)。
* **`git`** 只有 Hermes 需要，而且必须是 `git-http`（HTTPS 传输在它里面，`git` 随它一起装）。
* **`luci-compat`** 提供 Lua 调度器与模板引擎（`luci-lua-runtime`）；没有它包照样装得干净，
  页面却永远打不开。
* FCC 运行时自己的要求（Python 3.14、FastAPI、Uvicorn）由它自己负责——安装本包不会把一个
  语言运行时拖到只想看看状态页的路由器上。

### 安装前自动补齐的包

*配置* → **诊断** → **运行检查** 列出每项检查的值、要求和结果。按下 **安装** 或 **更新**
时，如果所有未通过的检查都能由装包解决，安装程序会先补包、重新检查，全部通过后才下载
运行时；有装包解决不了的项（空间、DNS、HTTPS、没有可用的 Node 构建）则直接拒绝并给出
完整报告。

| 检查 | 包 | 什么时候需要 |
| --- | --- | --- |
| tar | `tar` | GNU tar，支持 `--strip-components` 和 `--no-same-owner` |
| tmux | `tmux` | 终端与安装器，始终需要 |
| bash | `bash` | Claude Code、OpenCode、Hermes、Grok Build、Muse Code |
| fold | `coreutils-fold` | Codex 的安装脚本 |
| sleep | `coreutils-sleep` | Pi 的安装脚本（它的 sleep 要接受小数秒） |
| git | `git-http` | Hermes 安装器克隆代码仓库（含 `git`） |
| Node 的 C++ 运行库 | `libstdcpp6`，必要时 `libgcc1` | Pi、DeepSeek Harness 和 Hermes 取回的 musl Node |
| curl | `curl` | 下载安装器与运行时 |

包名在 24.10 与 25.12 上相同；命令按机器上的包管理器生成（`opkg install` / `apk add`），
第一次失败时先更新索引再重试一次。诊断面板旁的 **清空检查日志** 只清页面内容，不动磁盘；
*基本信息* 的 **清空日志** 同理。

---

## Web 终端

终端是真正的终端，不是日志查看器。每个会话是路由器上的一个 `tmux` 会话，浏览器通过 LuCI
后端与它通信。

**传输是 HTTP 字节流，不是 WebSocket**：WebSocket 需要常驻的 Node.js 或 Python 服务器，
而本包不得引入语言运行时、也不得在 FCC 服务器之外运行常驻守护进程；`uhttpd` 本身也没有
WebSocket 支持。所以后端以**绝对偏移量**暴露输出，浏览器长轮询，重连精确地从断点继续；
回滚缓冲从头部裁剪时基准偏移量同步前进，裁剪前后一个绝对偏移量的含义不变。按键以 base64
上传，后端解码后以十六进制交给 `tmux send-keys -H`——交给 tmux 的从不是攻击者可控的文本。

代价是输入回声要走一次长轮询往返：服务端每 0.2 秒看一次会话的输出文件，轮询间隔上限定为
25 秒。BusyBox 的 `sleep` 只认整秒，所以快节拍借的是 coreutils 的 `timeout`；没有它的机器
退回一秒一跳（旧行为），控制台依旧可用，只是敲键回声会慢到一秒。对交互式编程 Agent 基本
无感，对全屏 TUI 重绘则有感。

会话也可以离开 LuCI：工具栏的 **在浏览器中打开** 把当前会话放进独立窗口，**关闭窗口就会
结束该会话**（刷新不会，重连会取消延迟关闭）；**结束全部会话** 只结束 `fcc-*` 命名空间；
**清理已结束的会话** 只回收进程已退出的会话及其遗留文件。

---

## 仓库结构

```
Makefile                  显式的 Package/ 定义（不用 luci.mk）
VERSION                   上游版本（发布号在 Makefile 的 PKG_RELEASE）
luasrc/controller/fcc.lua LuCI 调度器与 JSON API
luasrc/fcc/               util.lua、agents.lua、paths.lua、adminproxy.lua
luasrc/view/fcc/          三个页面与独立窗口
htdocs/luci-static/…/fcc/ 浏览器端 JavaScript 与 xterm.js
root/etc/init.d/fcc       FCC 服务器的 procd 服务
root/usr/libexec/fcc/     shell 后端
root/usr/share/luci-app-fcc/agents.conf   Agent 注册表
po/                       翻译目录
scripts/                  gen-po.sh、package-check.sh、smoke.sh、test.sh、version.sh
tests/                    检查套件
```

`luasrc/` 映射到 `/usr/lib/lua/luci/`，所以 `luasrc/fcc/util.lua` 就是模块
`luci.fcc.util`；Makefile 里的安装清单与之不一致时，`tests/test_packaging.sh` 会失败。

### 添加一个 Agent

在 `root/usr/share/luci-app-fcc/agents.conf` 里加一行：

```
id|友好名称|启动器|默认是否安装|约需空间MB|最低内存MB|探测命令
```

探测命令是读取版本的*底层* CLI，绝不能是 `fcc-*` 启动器（那些会启动 Agent）；底层 CLI
未知或运行不安全时留空（`hermes --version` 会挂起）。真实状态始终动态探测，这个文件只是
提示。

---

## 开发

一切都在普通 Linux 机器上运行，不需要 OpenWrt 源码树、交叉编译器或 root：

```sh
sh scripts/test.sh            # package-check + 全部套件
sh scripts/test.sh -q         # 只显示摘要
sh scripts/test.sh lua shell  # 指定套件
sh scripts/package-check.sh   # 单独跑静态包检查
sh scripts/gen-po.sh          # 重新生成 po/templates/fcc.pot
sh scripts/gen-po.sh --check  # 模板过期则失败
```

| 套件 | 覆盖内容 |
| --- | --- |
| `shell` | shebang、POSIX 可移植性、局部变量前缀约定 |
| `lua` | 模块逻辑，以及共享规则的 Lua↔shell 一致性 |
| `runtime` | 后端行为：路径规范化、id 文法、JSON、缓存、`/proc`、终端偏移量 |
| `packaging` | 安装清单与源码树、依赖、i18n 接线 |
| `i18n` | 模板 ↔ 目录一致性、po2lmo 的丢弃规则、LuCI 语言代码 |
| `security` | 无提交的凭据、无 WAN 绑定、变更类操作仅 POST、ACL 范围、无 WebSocket 服务器 |

`scripts/smoke.sh` 刻意不在 `test.sh` 里：它需要 Docker 和发行版 rootfs，由 CI 作为独立任务
运行——解开官方 rootfs、在真正的 procd 下启动、用该发行版自己的包管理器（24.10 用 `opkg`，
25.12 用 `apk`）安装构建出的包，再执行 `/etc/init.d/fcc status`。

shell 后端在 `set -u` 下运行，而 POSIX `sh` 只有一个被所有函数共享的全局作用域，所以每个
局部变量都带按函数区分的前缀（`_ug_v`、`_ou_off`），由 `tests/test_shell.sh` 强制执行。

### 发布

`VERSION`（上游版本，也是 *基本信息* 显示的版本）与 Makefile 里的 `PKG_RELEASE`（发布号）
合成软件包的版本，这一个字符串同时用作文件名、tag 和 Release 名；`scripts/version.sh` 是
唯一合成它的地方，不需要手动打 tag。推送到 `main` 会跑静态检查，用 24.10 和 25.12 的
x86_64 SDK 各构建一次并各跑一次安装冒烟测试，全部通过才发布，tag 由 workflow 创建。要发
下一版，改 `PKG_RELEASE` 就够了；同一个版本再次发布是替换而不是新增，PR 永远不触发发布。

产物只有本软件包：`luci-app-fcc_<version>-r<release>_all.ipk`、
`luci-app-fcc-<version>-r<release>.apk` 和 `SHA256SUMS`。软件包是 `PKGARCH:=all`（纯 Lua、
JavaScript 和 shell），x86_64 SDK 产出的文件在 ARM、MIPS 和 x86 上同样可装。运行时按需
联网安装，所以 Release 里没有预构建的运行时压缩包。

---

## 已知限制

* **终端没有 WebSocket 传输**——见上文；这是"不引入额外运行时"和"不运行常驻守护进程"两条
  约束的结果，全屏 TUI 重绘明显比走 socket 慢。
* **`hermes` 没有版本探测**：`hermes --version` 不会结束，界面把版本报告为未知，而不是让
  状态刷新卡住。
* **Agent 版本是探测得来的**：以 5 秒超时从底层 CLI 读取并缓存 60 秒；CLI 改了输出格式的
  Agent 会显示一个陌生的字符串。
* **终端和安装器都需要 `tmux`**：缺少时终端报告依赖缺失、安装在开始前就被拒绝。
* **五个 Agent 需要 `bash`**：安装前会自动补齐，只有补不上时安装才在下载前被拒绝。
* **Cline 在 OpenWrt 上装不了**：只有 glibc 构建，诊断标为 WARN，安装时自动跳过。
* **安装整个注册表是全有或全无**：一个 Agent 装不上就全部回滚；此时用下拉框逐个安装。
* **更新必须先写完新运行时才能丢弃旧的**：剩余空间预检按一份运行时计算，而不是零。

---

## 许可证

GPL-3.0。见 [LICENSE](LICENSE)。
