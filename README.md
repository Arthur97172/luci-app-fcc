# luci-app-fcc

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
apk add ./luci-app-fcc*.apk
```

The `.ipk` and the `.apk` are produced by CI from the corresponding OpenWrt SDK.
They are genuinely different package formats — an `.ipk` renamed to `.apk` is
not a package and will not install.

Then open:

```
LuCI → Services → FCC
```

All three pages work immediately, before anything else is installed.

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

**4. Update.** *Basic Information* → **Check Update** → **Update FCC**.

---

## Requirements

Installed automatically as dependencies:

```
luci-base  luci-compat  curl  ca-bundle  tar  tmux
```

`tmux` is not optional: it is the terminal backend the Web Console drives.

The FCC runtime has its own requirements (currently Python ≥ 3.14, FastAPI,
Uvicorn). Those are the runtime's business, not this package's — installing
`luci-app-fcc` must not pull a language runtime onto a router that only wanted
to look at the status page.

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
VERSION                   single source of the package version
luasrc/controller/fcc.lua the LuCI dispatcher and the JSON API
luasrc/fcc/               util.lua, agents.lua, paths.lua
luasrc/view/fcc/          the three pages
htdocs/luci-static/…/fcc/ browser JavaScript and xterm.js
root/etc/init.d/fcc       procd service for the FCC server
root/usr/libexec/fcc/     the shell backend
root/usr/share/luci-app-fcc/agents.conf   the agent registry
po/                       translation catalogues
scripts/                  gen-po.sh, package-check.sh, test.sh
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

The shell backend follows one rule that is easy to trip over: POSIX `sh` has a
single global scope shared by every function, and the scripts run under
`set -u`. A helper that assigns a bare `_name` therefore clobbers its caller's
variable. Every local is prefixed with a per-function tag (`_ug_v`, `_ou_off`),
and `tests/test_shell.sh` enforces it.

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

---

## License

GPL-3.0. See [LICENSE](LICENSE).
