# luci-app-fcc

**简体中文** | [English](README.en.md)

在 OpenWrt / ImmortalWrt 的 LuCI 网页界面里管理
[FCC（Free Claude Code）](https://github.com/Alishahryar1/free-claude-code)
及其编程 Agent。

一个软件包，三个页面：

| 页面 | 作用 |
| --- | --- |
| **Web 终端** | Claude Code、Codex、Pi、OpenCode、Cline、Hermes、DeepSeek Harness、Grok Build、Muse Code、Aider 的真正交互式终端——每个 Agent 一个 tmux 会话，直接在浏览器里用。 |
| **配置** | FCC 服务器设置（地址、端口、日志级别）、运行时安装路径、启动/停止/重启，以及 FCC Admin 页面入口。 |
| **基本信息** | 版本、状态、PID、运行时长、RSS 内存、系统内存与存储，以及 FCC 更新检查。 |

`luci-app-fcc` **只是控制层**。它只包含 Lua、JavaScript 和 POSIX shell，
**不包含** Python、Node.js、`uv`、FCC 运行时或任何编程 Agent——这些都按需单独安装在
`/opt/fcc` 下。

---

## 安装

OpenWrt 24.10：

```sh
opkg install luci-app-fcc_*.ipk
```

OpenWrt 25.12：

```sh
apk add --allow-untrusted luci-app-fcc*.apk
```

`.ipk` 与 `.apk` 由 CI 用对应版本的 OpenWrt SDK 构建。它们是两种完全不同的包格式——
把 `.ipk` 改名成 `.apk` 得到的不是安装包，装不上。

然后打开：

```
LuCI → 服务 → FCC
```

三个页面装完即可使用，无需先安装别的东西。

界面语言跟随 LuCI。英文是源语言；简体中文的编译目录直接打包在本包内，没有单独的
`luci-i18n-fcc-zh-cn` 需要安装。LuCI 界面语言为中文时会自动加载它。

---

## 首次使用

**1. 安装 FCC 运行时。** 在*基本信息*页面点击 **Install FCC Runtime**。
不需要 SSH 进去手动跑 FCC 的安装脚本——页面会通过 HTTPS 拉取官方安装器、记录其
SHA-256 并执行。Python、`uv` 和运行时本身都装在配置的安装路径下（默认 `/opt/fcc`），
绝不进入本软件包。

**2. 配置。** 在*配置*页面设置地址和端口，然后点 **Open FCC Admin** 添加服务商凭据。
API 密钥在 FCC 自己的管理界面里填写，从不写入 UCI——本软件包根本没有存放它们的地方。

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

## 依赖

作为依赖自动安装：

```
luci-base  luci-compat  curl  ca-bundle  tmux
```

`tmux` 不是可选项：它是 Web 终端所驱动的终端后端。

`tar` 是刻意*不*在其中的。本包没有任何地方调用 tar——运行时安装器是以 shell 脚本形式
获取并执行的，备份用的是目录改名——而且每个镜像上的 busybox 都已经提供 `/bin/tar`。
依赖 GNU `tar` 包还会让本包在 25.12 上无法被选中：上游的 tar 带有一个变体门控
（`TAR_XZ` 默认开、`xz-utils` 默认关），元数据生成器会把它复制到每一个依赖者身上。

`luci-compat` 是另一个关键依赖，而且不那么显眼。OpenWrt 24.10 和 25.12 把 LuCI 核心
迁到了 ucode：`luci-base` 已经完全不包含 `/usr/lib/lua/luci`。本包的控制器和视图所
运行的 Lua 调度器与模板引擎现在位于 `luci-lua-runtime`，而 `luci-compat` 依赖它——
所以列出 `luci-compat` 才是把它们拉进来的原因。没有它，包依然装得干干净净，页面却
永远打不开；这正是安装冒烟测试要断言 `/usr/lib/lua/luci/dispatcher.lua` 存在的原因。

FCC 运行时有自己的要求——目前是 Python 3.14（上游锁定 `requires-python == 3.14.7`）、
FastAPI 和 Uvicorn。那是运行时自己的事，不是本包的：安装 `luci-app-fcc` 不能把一个
语言运行时拖到一台只想看看状态页的路由器上。这也是运行时按需安装而非随包分发的原因。

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

---

## 仓库结构

```
Makefile                  显式的 Package/ 定义（不用 luci.mk）
VERSION                   软件包版本的唯一来源
luasrc/controller/fcc.lua LuCI 调度器与 JSON API
luasrc/fcc/               util.lua、agents.lua、paths.lua
luasrc/view/fcc/          三个页面
htdocs/luci-static/…/fcc/ 浏览器端 JavaScript 与 xterm.js
root/etc/init.d/fcc       FCC 服务器的 procd 服务
root/usr/libexec/fcc/     shell 后端
root/usr/share/luci-app-fcc/agents.conf   Agent 注册表
po/                       翻译目录
scripts/                  gen-po.sh、package-check.sh、smoke.sh、test.sh
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

版本只有一个来源：`VERSION`。Makefile 用它给软件包打版本，*基本信息*页面显示它，
Release 的 tag 也必须与它一致。

```sh
# tag 就是 VERSION 前面加个 v，所以直接读出来，不要手敲
version="$(tr -d ' \t\r\n' < VERSION)"
git tag "v$version"
git push origin "v$version"
```

推一个 `v*` tag 会先跑静态检查，再在四个架构上构建并各跑一次安装冒烟测试，
全部通过后才发布。发布的第一步就是拿 tag 和 `VERSION` 比对：对不上立即失败，
不会出现名为 v0.2.0、包却叫 0.1.0 的 Release。标题同样取自 `VERSION` 而非 tag，
两者无法各自漂移。

资产只有本软件包——`luci-app-fcc_<version>-r1_all.ipk`、`luci-app-fcc-<version>-r1.apk`
和 `SHA256SUMS`。四个架构构建的是同一个文件（`PKGARCH:=all`），收到后是逐一
比对而不是合并，两个 SDK 对同一个包给出不同结果会直接失败。FCC 运行时是按需
联网安装的，所以 Release 里没有预构建的运行时压缩包。

---

## 已知限制

* **终端没有 WebSocket 传输。** 上文已解释；这是"不引入额外运行时"和"不运行常驻
  守护进程"两条约束的结果，不是疏漏。全屏 TUI 重绘明显比走 socket 慢。
* **`hermes` 没有版本探测。** `hermes --version` 不会结束，所以注册表把它的探测命令
  留空，界面把版本报告为未知，而不是让状态刷新卡住。
* **Agent 版本是探测得来的，不保证准确。** 版本以 5 秒超时从底层 CLI 读取并缓存
  60 秒。CLI 改了输出格式的 Agent 会显示一个陌生的字符串。
* **终端需要 `tmux`。** 没有它另外两个页面照常工作；终端会报告缺少依赖，
  而不是静默失败。
* **回滚的更新在运行期间会占用第二份运行时大小的磁盘。** 回滚靠把旧运行时改名挪到
  一边而不是复制，在同一个文件系统上是免费的——但新运行时仍必须先写完才能丢弃旧的，
  所以剩余空间预检必须覆盖一份运行时而不是零。它检查的正是这个。

---

## 许可证

GPL-3.0。见 [LICENSE](LICENSE)。
