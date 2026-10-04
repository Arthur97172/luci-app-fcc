# luci-app-fcc

[简体中文](README.md) | **English**

Manage [FCC (Free Claude Code)](https://github.com/Alishahryar1/free-claude-code)
and its coding agents from the LuCI web interface on OpenWrt / ImmortalWrt.

Three pages, one package:

| Page | What it does |
| --- | --- |
| **Web Console** | A real interactive terminal for Claude Code, Codex, Pi, OpenCode, Cline, Hermes, DeepSeek Harness, Grok Build, Muse Code and Aider — one tmux session per agent, in the browser. |
| **Configuration** | FCC server settings (address, port, log level), the runtime install path, start/stop/restart, and a link to the FCC Admin page. |
| **Basic Information** | Version, status, PID, uptime, RSS memory, system memory and storage, and FCC update checks. |

`luci-app-fcc` is a **control layer only**. It ships Lua, JavaScript and POSIX
shell. It does **not** contain Python, Node.js, `uv`, the FCC runtime or any
coding agent — those are installed separately, on demand, under `/opt/fcc`.

---

## Install

OpenWrt 24.10:

```sh
opkg install luci-app-fcc_*.ipk
```

OpenWrt 25.12:

```sh
apk add --allow-untrusted luci-app-fcc*.apk
```

The `.ipk` and the `.apk` are produced by CI from the corresponding OpenWrt SDK.
They are genuinely different package formats — an `.ipk` renamed to `.apk` is
not a package and will not install.

Then open:

```
LuCI → Services → FCC
```

All three pages work immediately, before anything else is installed.

The interface follows LuCI's language. English is the source language; the
compiled Simplified Chinese catalogue is built into this same package, so there
is no `luci-i18n-fcc-zh-cn` to install alongside it. LuCI loads it on its own
whenever the interface language is Chinese.

---

## First run

**1. Install the FCC runtime.** On the *Basic Information* page, choose
**Install FCC Runtime**. You do not need to SSH in and run FCC's installer by
hand — the page fetches the official installer over HTTPS, records its SHA-256,
and runs it. Python, `uv` and the runtime itself are installed under the
configured install path (`/opt/fcc` by default), never into this package.

**2. Configure.** On the *Configuration* page, set the address and port, then
**Open FCC Admin** to add provider credentials. API keys are entered in FCC's
own admin UI and are never stored in UCI — this package has nowhere to put them.

> **Keep the address at `127.0.0.1`** unless you deliberately need to reach the
> FCC Admin page from another device on your LAN. The FCC server's own default
> is `0.0.0.0`; this package overrides it and will not accept a bind address
> that is not a literal IP.

**3. Use an agent.** On the *Web Console* page, pick an agent and press
**Start**. Each agent gets its own session, named `fcc-<agent>-NNN`.

**4. Update.** *Basic Information* → **Check Update** → **Update FCC**. The
update is a sequence, not a single call: it checks free space, warns about open
console sessions, saves the current state, stops the server, reinstalls, verifies
the binary, restarts, and then confirms the server is actually answering before
reporting success.

If any step fails, the previous runtime is put back. The old runtime tree is
*renamed* aside before the update rather than copied — on one filesystem that is
instant and costs no extra space — so restoring it needs no download and no
second copy. Your `data/` is copied, since a successful update has to find it
still in place. After a rollback the log says either `Previous FCC version
restored` or, if the restored server will not start, `FCC Server remains
stopped. Please inspect logs.` LuCI itself is untouched either way.

---

## Requirements

Installed automatically as dependencies:

```
luci-base  luci-compat  curl  ca-bundle  tmux
```

`tmux` is not optional: it is the terminal backend the Web Console drives.

`tar` is deliberately *not* among them. Nothing here shells out to tar — the
runtime installer is fetched as a shell script and run, and backups are
directory renames — and busybox already provides `/bin/tar` on every image.
Depending on the GNU `tar` package would also make this package unselectable on
25.12, where upstream's tar carries a variant gate (`TAR_XZ` on, `xz-utils` off
by default) that the metadata generator copies onto every dependent.

`luci-compat` is the other load-bearing one, and less obviously so. OpenWrt
24.10 and 25.12 moved LuCI's core to ucode: `luci-base` no longer ships
`/usr/lib/lua/luci` at all. The Lua dispatcher and template engine that this
package's controller and views run on now live in `luci-lua-runtime`, which
`luci-compat` depends on — so listing `luci-compat` is what brings them in.
Without it the package still installs cleanly and the pages are simply never
reachable, which is why the install smoke test asserts that
`/usr/lib/lua/luci/dispatcher.lua` is present after an install.

The FCC runtime has its own requirements — currently Python 3.14 (upstream pins
`requires-python == 3.14.7`), FastAPI and Uvicorn. Those are the runtime's
business, not this package's: installing `luci-app-fcc` must not pull a language
runtime onto a router that only wanted to look at the status page. That is also
why the runtime is installed on demand rather than shipped here.

---

## How the Web Console works

The console is a genuine terminal, not a log viewer. Each session is a `tmux`
session on the router; the browser talks to it through the LuCI backend.

**The transport is an HTTP byte stream, not a WebSocket.** This is a deliberate
departure and it is worth stating plainly:

* A WebSocket would need a long-running Node.js or Python server. Both are
  forbidden here — the package must not add a language runtime, and it must not
  run a persistent daemon beyond the FCC server itself.
* `uhttpd`, the web server LuCI runs on, has no WebSocket support to fall back
  on.

So the backend exposes the session's output as a byte stream with **absolute
offsets**, and the browser long-polls it. Each response carries the bytes after
the offset the client already has, so a reconnect resumes exactly where it
stopped instead of replaying the screen. Scrollback is capped and trimmed from
the front; the base offset advances by exactly the number of bytes dropped, so
an absolute offset means the same thing before and after a trim.

Keystrokes travel the other way as base64, are decoded to bytes by the backend
and re-encoded as hex for `tmux send-keys -H` — the value handed to tmux is
never attacker-controlled text.

The practical cost of not using a WebSocket: input latency is one long-poll
round trip rather than immediate, and the poll interval is capped at 25 seconds
server-side. For an interactive coding agent on a router that is not
noticeable; for a full-screen TUI redraw it can be. See *Known limitations*.

---

## Repository layout

```
Makefile                  explicit Package/ definitions (no luci.mk)
VERSION                   the upstream version (the release number is PKG_RELEASE)
luasrc/controller/fcc.lua the LuCI dispatcher and the JSON API
luasrc/fcc/               util.lua, agents.lua, paths.lua
luasrc/view/fcc/          the three pages
htdocs/luci-static/…/fcc/ browser JavaScript and xterm.js
root/etc/init.d/fcc       procd service for the FCC server
root/usr/libexec/fcc/     the shell backend
root/usr/share/luci-app-fcc/agents.conf   the agent registry
po/                       translation catalogues
scripts/                  gen-po.sh, package-check.sh, smoke.sh, test.sh, version.sh
tests/                    the check suite
```

`luasrc/` maps onto `/usr/lib/lua/luci/`, so `luasrc/fcc/util.lua` is the module
`luci.fcc.util`. The install manifest in the Makefile mirrors that, and
`tests/test_packaging.sh` fails if the two ever disagree.

### Adding an agent

Add one line to `root/usr/share/luci-app-fcc/agents.conf`:

```
id|Friendly Name|launcher|default_install|approx_size_mb|min_ram_mb|probe
```

The `probe` column is the *underlying* CLI used to read a version, and must
never be an `fcc-*` launcher — those start the agent. Leave it empty when the
underlying CLI is unknown or unsafe to run (`hermes --version` hangs, so
`hermes` has no probe). Real state is always detected dynamically; the file is a
hint.

---

## Development

Everything runs on a normal Linux machine. No OpenWrt tree, no cross-compiler,
no root:

```sh
sh scripts/test.sh          # package-check + every suite
sh scripts/test.sh -q       # summaries only
sh scripts/test.sh lua shell  # named suites
sh scripts/package-check.sh # the static package check on its own
sh scripts/gen-po.sh        # regenerate po/templates/fcc.pot
sh scripts/gen-po.sh --check # fail if the template is stale
```

The suites are:

| Suite | Covers |
| --- | --- |
| `shell` | shebangs, POSIX portability, the prefixed-local contract |
| `lua` | module logic, plus Lua↔shell parity for shared rules |
| `runtime` | the backend's behaviour: path canonicalisation, id grammars, JSON, cache, `/proc`, terminal offsets |
| `packaging` | the install manifest against the tree, dependencies, the i18n wiring |
| `i18n` | template ↔ catalogue parity, po2lmo's drop rule, LuCI language codes |
| `security` | no committed credentials, no WAN bind, POST-only mutations, ACL scope, no WebSocket server |

`scripts/smoke.sh` is deliberately not part of `test.sh`: it needs Docker and a
release root filesystem, so CI runs it as its own job. It unpacks the official
rootfs for the release, boots it under a real procd, installs the built package
with that release's own package manager — `opkg` on 24.10, `apk` on 25.12 — and
then runs `/etc/init.d/fcc status` inside it. That is the check sections 90 and
91 ask for, and it is the only one that no amount of reading files can answer.

The shell backend follows one rule that is easy to trip over: POSIX `sh` has a
single global scope shared by every function, and the scripts run under
`set -u`. A helper that assigns a bare `_name` therefore clobbers its caller's
variable. Every local is prefixed with a per-function tag (`_ug_v`, `_ou_off`),
and `tests/test_shell.sh` enforces it.

### Releases

The version is composed from two files: `VERSION` is the upstream version (the
Makefile reads it for `PKG_VERSION`, the *Basic Information* page displays it)
and `PKG_RELEASE` in the Makefile is the release number. Together they are the
package's version, which is what the built file is named after —
`luci-app-fcc_0.1.1-r2_all.ipk`. The release and its tag have to agree with that
whole string, and `scripts/version.sh` is the one place that composes it:

```sh
# Do not retype the version: the rule for composing it lives in version.sh.
git tag "$(sh scripts/version.sh --tag)"
git push origin "$(sh scripts/version.sh --tag)"
```

The release number is part of the version because it is part of the package: a
rebuild under the same `VERSION` takes a new `PKG_RELEASE`, so `0.1.1-r1` and
`0.1.1-r2` are different packages and have to be different tags. A tag naming
only the first half would put two different packages under one name.

Pushing a `v*` tag runs the static checks, then builds and install-smoke-tests
all four architectures, and only publishes once every one of them passes. The
first step of the release is the comparison against that whole version: a
mismatch fails immediately rather than publishing a release named v0.1.2-r1
carrying packages called 0.1.1-r2. The title comes from the version files too,
not from the tag, so the two cannot drift apart.

The assets are this package alone — `luci-app-fcc_<version>-r<release>_all.ipk`,
`luci-app-fcc-<version>-r<release>.apk` and `SHA256SUMS`. All four architectures
build the same file (`PKGARCH:=all`), and the copies are compared rather than
merged: two SDKs disagreeing about the same package fails the release. The FCC
runtime is installed on demand over the network, so there is no prebuilt runtime
tarball in the release.

---

## Known limitations

* **No WebSocket transport for the console.** Explained above; it is a
  consequence of the no-extra-runtime and no-persistent-daemon constraints, not
  an oversight. A full-screen TUI redraw is visibly slower than it would be over
  a socket.
* **`hermes` has no version probe.** `hermes --version` does not terminate, so
  the registry leaves its probe empty and the UI reports the version as unknown
  rather than hanging the status refresh.
* **Agent versions are probed, not guaranteed.** A version is read from the
  underlying CLI with a 5-second timeout and cached for 60 seconds. An agent
  whose CLI changes its output format will show an unfamiliar string.
* **The console needs `tmux`.** Without it the other two pages still work; the
  console reports the missing dependency instead of failing silently.
* **A rolled-back update costs a second runtime's worth of disk while it runs.**
  Rollback works by renaming the previous runtime aside rather than copying it,
  which is free on one filesystem — but the new runtime still has to be written
  before the old one is discarded, so the free-space preflight has to cover one
  runtime, not zero. That is what it checks.

---

## License

GPL-3.0. See [LICENSE](LICENSE).
