# luci-app-fcc

**简体中文** | [English](README.en.md)

在 OpenWrt / ImmortalWrt 的 LuCI 网页界面里管理
[FCC（Free Claude Code）](https://github.com/Alishahryar1/free-claude-code)
及其编程 Agent。

一个软件包，三个页面：

| 页面 | 作用 |
| --- | --- |
| **Web 终端** | Claude Code、Codex、Pi、OpenCode、Cline、Hermes、DeepSeek Harness、Grok Build、Muse Code、Aider 的真正交互式终端——每个 Agent 一个 tmux 会话，直接在浏览器里用。 |
| **配置** | FCC 服务器设置（地址、端口、日志级别）、运行时安装路径与备份路径、Agent 选择框、安装/更新/卸载/彻底卸载、启动/停止/重启、诊断报告、FCC Admin 页面入口，以及通过 SSH 控制局域网内另一台机器上的 FCC 服务器。 |
| **基本信息** | 版本、状态、PID、运行时长、RSS 内存、CPU 与硬件平台、系统内存与存储，以及 FCC 更新检查。 |

`luci-app-fcc` **只是控制层**。它只包含 Lua、JavaScript 和 POSIX shell，
**不包含** Python、Node.js、`uv`、FCC 运行时或任何编程 Agent——这些都按需单独安装在
`/opt/fcc` 下。

![Web 控制台：在 LuCI 界面里运行的 Claude Code 会话](screenshot.png)

*Web 控制台——每个 Agent 一个 tmux 会话，直接在浏览器里操作。*

---

## 安装

OpenWrt 24.10：

```sh
opkg install luci-app-fcc_*.ipk
# 中文界面需额外安装翻译包
opkg install luci-i18n-fcc-zh-cn_*.ipk
```

OpenWrt 25.12：

```sh
apk add --allow-untrusted luci-app-fcc-*.apk
# 中文界面需额外安装翻译包
apk add --allow-untrusted luci-i18n-fcc-zh-cn-*.apk
```

`.ipk` 与 `.apk` 由 CI 用对应版本的 OpenWrt SDK 构建。它们是两种完全不同的包格式——
把 `.ipk` 改名成 `.apk` 得到的不是安装包，装不上。

然后打开：

```
LuCI → 服务 → FCC智能体
```

三个页面装完即可使用，无需先安装别的东西。

上面两组命令里的第二行是可选的。界面语言跟随 LuCI：英文是源语言，随 `luci-app-fcc`
一起安装；简体中文的编译目录在**单独的 `luci-i18n-fcc-zh-cn` 包**里，所以中文界面
要多装那一个包。装好之后 LuCI 界面语言为中文时会自动加载它，不需要任何配置，也不需要
重启服务。

两个包互相独立：可以只装英文界面，也可以后补中文；升级、卸载各管各的。只装
`luci-app-fcc` 时界面是英文，这不是故障。

---

## 首次使用

**1. 安装 FCC 运行时。** 在*配置*页面选择 Agent，然后点击 **安装**。
不需要 SSH 进去手动跑 FCC 的安装脚本——页面会通过 HTTPS 拉取官方安装器、记录其
SHA-256 并执行。Python、`uv` 和运行时本身都装在配置的安装路径下（默认 `/opt`，
运行时落在 `/opt/fcc`），绝不进入本软件包。

Agent 下拉框默认是 **全部智能体**，也就是整个注册表：下载极慢，约占 8 GB 存储。
建议只选需要的 Agent。只选一个时，只装这个 Agent（运行时还没装就一并装好），其他
已安装的 Agent 原样保留。如果运行时已经装好而仍选择 **全部智能体**，页面会先确认，
再移除运行时并把全部 Agent 重装一遍——上游会核对它找到的 Agent、不会重装已存在的
那些，所以只有先移除运行时才能替换损坏的安装。

**开始前先确认剩余空间：安装路径所在的文件系统至少要有 2 GB 可用，推荐至少 4 GB。**
空间不够时本包在下载任何东西之前就拒绝安装，并写明还差多少，而不是让它跑到一半再失败。
运行时自己（Python 3.14、`uv`、各 Agent）实测峰值约 741 MB，2 GB 是留出余量的取整值：
更新期间新旧两套运行时会同时存在，`uv` 缓存会随 Python 一起增长，失败的一次运行还
可能把回滚副本留在磁盘上——多装一个 Agent、装一个更大的新版本都会吃掉余量，而估低了
的代价是在设备上留下半个运行时。回滚副本放在*配置*页面的 **备份路径** 下，默认是
`/tmp/fcc`：OpenWrt 上 `/tmp` 是内存盘，这样副本就不占运行时所处的闪存；每次运行
结束它都会被删除，只有回滚无法完成时例外。推荐 4 GB，是为了给更大的 Agent 集合和
后续版本留出一倍余量，比事后手工清理省事得多。

安装器自己会问"要装哪些 Agent"，而这段对话只认 `/dev/tty`，没有任何开关或环境变量
可以绕过。所以本包不去猜它的答案：安装器被放进一个 `tmux` 会话里运行，本包按*配置*
页面里选中的 Agent（**全部智能体**，或下拉框里的一个）逐条回答它的提问，同时把
整个终端画面写进 `<安装路径>/logs/installer.out`。安装失败时，原因就在那份记录里
——这也是出问题时第一个该看的地方。

任务开始后*配置*页面会跟着它跑。有两点值得说明，因为都曾让人误判：

* **进度条不是估计值，是"还在跑"的意思。** 它在运行期间逐渐趋近 95% 就停在那里，
  只有任务真的结束（锁被释放）才走到 100%。所以停在 90% 上下不动，只说明任务还在
  跑；一条走到 100% 的进度条则一定意味着任务结束了——成功还是失败，结论在日志里。
* **日志是追加写入的，页面只显示当前这一次。** 每次任务开始时写一行
  `===== fcc job start <时间>: <命令> =====`，页面显示最后一行之后的内容。要看更早
  的记录，直接读路由器上的 `<安装路径>/logs/fcc-runtime.log`（安装）或
  `fcc-update.log`（更新）；安装路径不可写时会退到 `/tmp/fcc-logs/`。

一个任务在跑的时候再点一次安装或更新，会被直接拒绝，日志里写
`another install/update is already running`——与 shell 后端拿不到锁时写的是同一句。
被强行打断的任务（比如路由器在安装中途重启）会留下锁，最长一小时后自动失效，
不会把下一次安装挡在门外。

**2. 配置。** 在*配置*页面设置地址和端口，然后点 **Open FCC Admin** 添加服务商凭据。
API 密钥在 FCC 自己的管理界面里填写，从不写入 UCI——本软件包根本没有存放它们的地方。
同一页的 **安装路径** 和 **备份路径** 随时可以改；改安装路径不会移动已有的运行时。

> **除非你确实需要从局域网内其他设备访问 FCC Admin，否则请把地址保持为 `127.0.0.1`。**
> FCC 服务器自身的默认值是 `0.0.0.0`；本软件包会覆盖它，并且不接受非字面 IP 的绑定地址。

**3. 使用 Agent。** 在 *Web 终端*页面选择 Agent 并按 **Start**。
每个 Agent 拥有自己的会话，命名为 `fcc-<agent>-NNN`。

**4. 更新。** *基本信息* → **Check Update** → **Update FCC**。
更新是一串步骤而不是一次调用：检查剩余空间、提示仍打开的终端会话、保存当前状态、
停止服务器、重新安装、校验二进制、重启，最后确认服务器真的在响应才报告成功。

任何一步失败都会把之前的运行时放回去。更新前，旧的运行时目录是被*改名*挪到一边
而不是复制的——在同一个文件系统上这是瞬间完成且不占额外空间——所以恢复它既不需要
重新下载也不需要第二份拷贝。`data/` 是复制的，因为更新成功后必须仍能在原处找到它。
回滚后日志会写 `Previous FCC version restored`，或者，如果恢复后的服务器起不来，
写 `FCC Server remains stopped. Please inspect logs.`。两种情况下 LuCI 本身都不受影响。

---

## 局域网控制

*配置*页面的 **FCC 服务器** 区域里有一个 `[本机] [局域网]` 开关。默认是 `[本机]`，
界面与以前完全一致；切到 `[局域网]` 后，同一区域的四个按钮——**启动**、**停止**、
**重启**、**Open FCC Admin**——作用于另一台机器上的 FCC 服务器。一次只控制一台，
Windows、Linux、OpenWrt 都可以。

填好 **IP 地址** 和 **用户名** 后：

1. 点 **生成并配置密钥**。路由器在 `/etc/fcc/ssh/` 下生成一对 Ed25519 密钥并显示
   公钥，把它加到远程账号的 `~/.ssh/authorized_keys` 里。本包不保存也不询问密码：
   连接只提供这把密钥（`PreferredAuthentications=publickey`、`BatchMode=yes`、
   `IdentitiesOnly=yes`），所以认证失败是一个结果，而不是一个密码提示。
2. 点 **测试连接**。第一次会显示远程机器的主机密钥指纹并要求确认；确认后指纹写入
   UCI，此后每次连接都要求它完全一致。指纹变了就拒绝连接并报告实际读到的值——
   这正是应该停下来检查机器的时刻，而不是一条可以点掉的提示。
3. 这时四个按钮才可用。启动/停止/重启发送的命令由*高级设置*里的 **远程平台** 决定：
   Linux 用 `systemctl <op> <服务名>`，OpenWrt 用 `/etc/init.d/<服务名> <op>`，
   Windows 用 PowerShell 的 `Start-Service`/`Stop-Service`/`Restart-Service`。
   服务名只接受字母、数字和 `.` `-` `_`，所以 UCI 被手工改过也拼不出别的命令。

**只接受私有 IPv4 地址**（`10/8`、`172.16/12`、`192.168/16`、`169.254/16`）。
主机名一律拒绝：一个名字可能解析成公网地址，那就不是"桌上那台电脑"了。

远程的 FCC Admin 同样只对回环地址开放，所以 **Open FCC Admin** 不会直接打开
`http://<远程IP>:8082`。路由器的 LuCI 代理先建立一条 SSH 本地转发
`ssh -N -L 127.0.0.1:18082:127.0.0.1:<Admin 端口>`，再把请求交给隧道这一端：
远程服务器看到的对端是回环地址，而浏览器的访问仍然要经过 LuCI 的登录验证——
比它原本的回环检查更严。隧道在第一次打开 Admin 时建立，离开局域网模式时关闭。

连接需要路由器上有 OpenSSH 客户端（`openssh-client`）。没有它时密钥那一行会写明，
四个按钮保持禁用，而不是等到点击才超时。*高级设置* 里可以改 SSH 端口、远程平台、
Admin 端口和服务名，可以看到每个按钮实际发送的命令，也可以查看已固定的主机指纹或
点 **忘记** 把它清除。改 IP 或 SSH 端口会自动忘记指纹——新地址上的机器不该继承
旧机器得到的信任。

---

## 依赖

作为依赖自动安装：

```
luci-base  luci-compat  curl  ca-bundle  tmux
```

`tmux` 不是可选项：它是 Web 终端所驱动的终端后端。

`tar` 是刻意*不*在其中的，但那不等于系统里的 tar 一定够用。本包自己不调用 tar——
运行时安装器是以 shell 脚本形式获取并执行的，备份靠移动目录并复制 `data/`——可是*安装器*要调用：
`uv` 是用 `tar xf … --no-same-owner --strip-components 1` 解包它自己的发行版的，而
busybox tar 这两个选项都不支持。它会打印用法、以 1 退出，安装就在最后一个提问之后几秒
停住，页面上只剩安装器的一句 `uv installation failed with exit code 1`。所以*配置*
页面的诊断报告会**真的解一次归档**来判定，而不是读版本号：支持这两个选项的（GNU tar
或 libarchive 的 tar）报 OK，只有 busybox tar 时报 FAIL 并附上安装命令，因为下一次
更新必然要重新下载 `uv`，也就必然要用到它。

那为什么不干脆列成依赖？因为在 25.12 上那会让本包无法被选中：上游的 tar 带有一个变体
门控（`TAR_XZ` 默认开、`xz-utils` 默认关），元数据生成器会把它复制到每一个依赖者身上，
于是这个依赖在任何默认配置下都解析不出来。替代方案不是让你看完报告再自己去装：
**启动安装时，能由装包解决的缺项会被自动补上**，见下文。

`bash` 不在这份列表里，而且这是刻意的。上游安装器把十个 Agent 里的五个——Claude Code、
OpenCode、Hermes、Grok Build、Muse Code——交给各自的 bash 安装脚本，而 OpenWrt 镜像
只有 busybox ash，没有 bash。把它列成本包的依赖，等于让每一台只想看看状态页的路由器
都装上一个 shell；所以它只在被选中时才需要，由*配置*页面的诊断报告检查：选中的 Agent
里有需要 bash 的，报告给 FAIL 并附上安装命令；没有，则只给一条 WARN；安装前预检再把
缺的那个包装上。没有这些预检时，安装会在下载和构建之后才失败，日志里只有安装器的一句
`bash is required. Install it first, then rerun this installer.`

`cline` 是唯一一个装包也解决不了的：Cline 只发布 glibc 的 Linux 构建，没有 musl 版本，
而 OpenWrt 是 musl。它的 npm 包装上的可执行文件，ELF 解释器指向
`/lib64/ld-linux-x86-64.so.2`——这个文件在 OpenWrt 上并不存在，Node 执行它时只会得到
一句 `spawnSync … ENOENT`，安装就停在那里。所以在这类系统上，Cline 不会被交给安装器：
它从选中的集合里去掉并说明原因，安装器关于它的提问一律回答 no；如果它是唯一要装的 Agent，
安装直接以 `AGENT_UNSUPPORTED` 拒绝，而不是去撞那个必然的失败。诊断报告把它标为 WARN
"not available"，而不是报成缺少依赖；上游的 musl 构建请求见
[cline/cline#15271](https://github.com/cline/cline/issues/15271)。

`git` 只在安装 Hermes 时才是需要的：Hermes 的安装器用
`git clone --filter=blob:none https://github.com/NousResearch/hermes-agent.git` 取回自己的
源码，而 OpenWrt 把 HTTPS 传输拆在 `git-http` 包里——只装 `git` 的机器能运行 git，
克隆却在第一步失败。诊断因此检查两半：git 能跑，且它 `--exec-path` 下有
`git-remote-https`；缺哪一半都报 FAIL，并给出 `git-http`（它依赖 `git`，一条命令补齐）。
fresh 24.10.8 上两样都没有，安装器报的是 `✗ git is required. Install it with your system
package manager.`，整个安装就停在那儿。

`luci-compat` 是另一个关键依赖，而且不那么显眼。OpenWrt 24.10 和 25.12 把 LuCI 核心
迁到了 ucode：`luci-base` 已经完全不包含 `/usr/lib/lua/luci`。本包的控制器和视图所
运行的 Lua 调度器与模板引擎现在位于 `luci-lua-runtime`，而 `luci-compat` 依赖它——
所以列出 `luci-compat` 才是把它们拉进来的原因。没有它，包依然装得干干净净，页面却
永远打不开；这正是安装冒烟测试要断言 `/usr/lib/lua/luci/dispatcher.lua` 存在的原因。

FCC 运行时有自己的要求——目前是 Python 3.14（上游锁定 `requires-python == 3.14.7`）、
FastAPI 和 Uvicorn。那是运行时自己的事，不是本包的：安装 `luci-app-fcc` 不能把一个
语言运行时拖到一台只想看看状态页的路由器上。这也是运行时按需安装而非随包分发的原因。

### 安装前自动补齐的包

*配置*页面 → **诊断** → **运行检查** 会列出每一项检查的值、要求、结果和建议。点
**安装**或 **更新**时，如果没通过的检查**全部**都能由装
一个包解决，安装程序会先装这些包，然后重新检查一遍；报告全部通过后才开始下载运行时。
任何一项装包解决不了——剩余空间不足、DNS 解析失败、HTTPS 不通、CPU 架构没有可用的
Node——都不会去动系统，而是直接拒绝安装并给出完整报告。

可能被自动安装的包：

| 检查 | 包 | 什么时候需要 |
| --- | --- | --- |
| tar | `tar` | 支持 `--strip-components` 和 `--no-same-owner` 的 GNU tar |
| tmux | `tmux` | 终端与安装器，始终需要 |
| bash | `bash` | Claude Code、OpenCode、Hermes、Grok Build、Muse Code |
| fold | `coreutils-fold` | Codex 的安装脚本 |
| sleep | `coreutils-sleep` | Pi 的安装脚本（它的 sleep 要接受小数秒） |
| git | `git-http` | Hermes 的安装器克隆它的代码仓库（HTTPS 传输在 `git-http` 里） |
| Node 的 C++ 运行库 | `libstdcpp6`，必要时还有 `libgcc1` | Pi、DeepSeek Harness 取回的 musl Node，以及 Hermes 安装器自己取回的 Node |
| curl | `curl` | 下载安装器与运行时 |

包名在 24.10（opkg）和 25.12（apk）上相同。`libstdcpp6` 跟的是 SONAME 的主版本号
（`libstdc++.so.6`），不是包管理器的命名；GNU tar 和 coreutils 都装在 `/usr/libexec/`
下，再由 alternatives 接管 `/bin/tar`、`/bin/sleep` 和 `/usr/bin/fold`，所以装完真正
生效，不会被 BusyBox 的同名 applet 挡在前面。`git-http` 装的是
`/usr/lib/git-core/git-remote-https`，`git` 也在同一个包里被依赖进来。安装命令按机器上
的包管理器生成：25.12 用 `apk add`，24.10 用 `opkg install`，第一次失败时先更新软件源
索引再重试一次。

诊断面板旁边的 **清空日志** 只清空页面上的报告，磁盘上的日志文件一个都不会动。

---

## Web 终端是怎么工作的

终端是真正的终端，不是日志查看器。每个会话是路由器上的一个 `tmux` 会话；
浏览器通过 LuCI 后端与它通信。

**传输方式是 HTTP 字节流，不是 WebSocket。** 这是一个刻意的偏离，值得明说：

* WebSocket 需要一个长期运行的 Node.js 或 Python 服务器。两者在这里都被禁止——
  本包不得引入语言运行时，也不得在 FCC 服务器之外运行常驻守护进程。
* LuCI 所运行的 Web 服务器 `uhttpd` 没有 WebSocket 支持可以退而求其次。

所以后端把会话输出以**绝对偏移量**的字节流暴露出来，浏览器用长轮询读取。
每个响应只携带客户端已有偏移量之后的字节，因此重连会精确地从断点继续，
而不是重放整个屏幕。回滚缓冲区有上限，超出时从头部裁剪；基准偏移量恰好前进
被丢弃的字节数，所以裁剪前后一个绝对偏移量含义相同。

按键走另一个方向：以 base64 传输，由后端解码为字节，再编码成十六进制交给
`tmux send-keys -H`——交给 tmux 的值从不是攻击者可控的文本。

不用 WebSocket 的实际代价：输入延迟是一次长轮询往返而非即时，且服务端把轮询间隔
上限定为 25 秒。对路由器上的交互式编程 Agent 来说这察觉不到；对全屏 TUI 重绘则
可能有感。参见*已知限制*。

会话也可以离开 LuCI 页面。工具栏上的 **在浏览器中打开** 会把当前会话放进一个
独立窗口——没有菜单、没有标签栏，终端占满整个窗口；**关闭这个窗口就会结束该会话**，
而刷新它不会，因为重新连接的请求会取消那次延迟关闭。旁边的 **结束全部会话** 在确认
之后一次结束本控制台创建的所有会话（只限 `fcc-*` 命名空间；你自己手动开的 tmux
会话不受影响）；**清理已结束的会话** 只收掉进程已经退出、只剩空壳的会话和遗留文件，
正在运行的会话不会被碰。

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
`luci.fcc.util`。Makefile 里的安装清单与之对应，一旦两者不一致，
`tests/test_packaging.sh` 就会失败。

### 添加一个 Agent

在 `root/usr/share/luci-app-fcc/agents.conf` 里加一行：

```
id|友好名称|启动器|默认是否安装|约需空间MB|最低内存MB|探测命令
```

`probe`（探测命令）一列是用于读取版本的*底层* CLI，绝不能是 `fcc-*` 启动器——
那些会启动 Agent。当底层 CLI 未知或运行不安全时留空（`hermes --version` 会挂起，
所以 `hermes` 没有探测命令）。真实状态始终动态探测；这个文件只是提示。

---

## 开发

一切都在普通 Linux 机器上运行。不需要 OpenWrt 源码树、不需要交叉编译器、不需要 root：

```sh
sh scripts/test.sh          # package-check + 全部套件
sh scripts/test.sh -q       # 只显示摘要
sh scripts/test.sh lua shell  # 指定套件
sh scripts/package-check.sh # 单独跑静态包检查
sh scripts/gen-po.sh        # 重新生成 po/templates/fcc.pot
sh scripts/gen-po.sh --check # 模板过期则失败
```

套件如下：

| 套件 | 覆盖内容 |
| --- | --- |
| `shell` | shebang、POSIX 可移植性、局部变量前缀约定 |
| `lua` | 模块逻辑，以及共享规则的 Lua↔shell 一致性 |
| `runtime` | 后端行为：路径规范化、id 文法、JSON、缓存、`/proc`、终端偏移量 |
| `packaging` | 安装清单与源码树、依赖、i18n 接线 |
| `i18n` | 模板 ↔ 目录一致性、po2lmo 的丢弃规则、LuCI 语言代码 |
| `security` | 无提交的凭据、无 WAN 绑定、变更类操作仅 POST、ACL 范围、无 WebSocket 服务器 |

`scripts/smoke.sh` 刻意不属于 `test.sh`：它需要 Docker 和一个发行版根文件系统，
所以 CI 把它作为独立任务运行。它会解开发行版官方 rootfs、在真正的 procd 下启动它、
用该发行版自己的包管理器（24.10 用 `opkg`，25.12 用 `apk`）安装构建出的包，
然后在里面执行 `/etc/init.d/fcc status`。这正是第 90、91 节要求的检查，
也是唯一一个靠读文件无法回答的检查。

---

shell 后端遵循一条容易踩到的规则：POSIX `sh` 只有一个被所有函数共享的全局作用域，
而脚本在 `set -u` 下运行。一个赋值裸 `_name` 的辅助函数因此会覆盖调用者的变量。
每个局部变量都带一个按函数区分的前缀（`_ug_v`、`_ou_off`），
`tests/test_shell.sh` 会强制执行。

### 发布

版本由两个文件合成：`VERSION` 是上游版本（Makefile 用它做 `PKG_VERSION`，
*基本信息*页面显示它），Makefile 里的 `PKG_RELEASE` 是发布号。两者合起来才是
软件包的版本，而这一个字符串会被用三次——文件名、tag、Release 名。
发布 `luci-app-fcc_0.1.1-r2_all.ipk` 的 Release 就叫 `0.1.1-r2`，
tag 也是 `0.1.1-r2`。`scripts/version.sh` 是唯一合成它的地方：

```sh
sh scripts/version.sh    # 0.1.1-r2
```

不需要手动打 tag。推送到 `main` 会先跑静态检查，再分别用 24.10 和 25.12 的
x86_64 SDK 各构建一次，并在各自的官方 rootfs 里各跑一次安装冒烟测试，全部通过
才发布；tag 由 workflow 自己创建，取自与构建软件包时完全相同的那两个文件。
要发下一版，改 `PKG_RELEASE` 就够了。

发布号是名字的一部分，因为它是软件包的一部分：同一个 `VERSION` 下重新构建的包
要递增 `PKG_RELEASE`，所以 `0.1.1-r1` 和 `0.1.1-r2` 是两个不同的包，也就必须是
两个不同的 tag。只写前半段的名字会把两个不同的包放在同一个 tag 下面。

用同一个版本再次发布是**替换**而不是新增——发布前会先删掉该版本的 Release 和
tag——所以同一个版本重跑是幂等的，不会因为 tag 已存在而失败。PR 永远不会触发发布。

资产只有本软件包——`luci-app-fcc_<version>-r<release>_all.ipk`、
`luci-app-fcc-<version>-r<release>.apk` 和 `SHA256SUMS`。每个发行版构建一次：
软件包是 `PKGARCH:=all`（纯 Lua、JavaScript 和 shell），x86_64 SDK 产出的文件
在 ARM、MIPS 和 x86 上同样可装，再加一个 aarch64 构建只是把同一条依赖链再编译
一遍，所以矩阵里每个发行版只有一条。收到多个产物时仍是逐一比对而不是合并——
若某天把架构加回来，两个 SDK 对同一个包给出不同结果会直接失败。FCC 运行时是按需
联网安装的，所以 Release 里没有预构建的运行时压缩包。

---

## 已知限制

* **终端没有 WebSocket 传输。** 上文已解释；这是"不引入额外运行时"和"不运行常驻
  守护进程"两条约束的结果，不是疏漏。全屏 TUI 重绘明显比走 socket 慢。
* **`hermes` 没有版本探测。** `hermes --version` 不会结束，所以注册表把它的探测命令
  留空，界面把版本报告为未知，而不是让状态刷新卡住。
* **Agent 版本是探测得来的，不保证准确。** 版本以 5 秒超时从底层 CLI 读取并缓存
  60 秒。CLI 改了输出格式的 Agent 会显示一个陌生的字符串。
* **终端和运行时安装器都需要 `tmux`。** 没有它另外两个页面照常工作，但终端会报告
  缺少依赖而不是静默失败，安装也会在开始前就被拒绝。诊断报告把 tmux 标为 FAIL
  而不是 WARN：一个摆在必然失败前面的"警告"，只会教人忽略那唯一重要的一行。
* **五个 Agent 需要 `bash`。** 见*依赖*。安装前会自动把它装上；只有装不上时
  （没有网络、空间不足）安装才会在下载任何东西之前被拒绝，报告里写明缺的是什么。
* **Cline 在 OpenWrt 上装不了。** 它只发布 glibc 构建、没有 musl 版本，所以诊断页面把
  它标为 WARN "not available"，安装时自动跳过并说明原因，见*依赖*。其余九个 Agent
  不受影响。
* **安装整个注册表是"全有或全无"。** 上游在第一个装不上的 Agent 处停止并回滚整次
  运行，所以设备上只要有一个 Agent 装不了，**全部智能体**就一个也装不上；此时用
  下拉框一次选一个，才能把其余 Agent 装上。
* **更新必须先写完新运行时，才能丢弃旧的。** 回滚会把旧运行时挪到备份路径：备份路径
  与安装路径在同一文件系统时是瞬时的改名，默认的 `/tmp` 内存盘上则是一次拷贝。无论
  哪种，新运行时都必须先写完，所以剩余空间预检要覆盖一份运行时而不是零。它检查的
  正是这个。

---

## 许可证

GPL-3.0。见 [LICENSE](LICENSE)。
