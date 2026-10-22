-- luci-app-fcc — where things live.
--
-- The install base comes from UCI (`fcc.main.install_path`) and is treated as a
-- *base* directory: the FCC root is <base>/fcc unless <base> already ends in
-- /fcc. This mirrors fcc_canon_base()/fcc_root() in
-- root/usr/libexec/fcc/common.sh, and the Lua and shell implementations are
-- deliberately kept in step — tests/test_lua.sh checks that they agree.

module("luci.fcc.paths", package.seeall)

local util = require "luci.fcc.util"

-- The FCC_* environment overrides mirror the ones the shell backend honours, so
-- a development tree can be exercised without installing into /usr.
LIBEXEC      = os.getenv("FCC_LIBEXEC")      or "/usr/libexec/fcc"
AGENTS_CONF  = os.getenv("FCC_AGENTS_CONF")  or "/usr/share/luci-app-fcc/agents.conf"
VERSION_FILE = os.getenv("FCC_VERSION_FILE") or "/usr/share/luci-app-fcc/VERSION"
DEFAULT_BASE = "/opt"
DEFAULT_BACKUP = "/tmp/fcc"
ASSET_DIR    = os.getenv("FCC_ASSET_DIR")    or "/www/luci-static/resources/fcc"

--- Cache-busting stamp for the static assets this package serves.
--
-- LuCI renders the page markup on every request, but a /luci-static/ file is
-- served with no Cache-Control, so a browser may reuse it under a heuristic
-- freshness lifetime. After an upgrade that pairs the new page with a script
-- from the previous package, and the pairing can break hard: r9 removed the
-- Delete backups button, and an r8 fcc-config.js still held in a browser
-- cache called addEventListener() on it, threw before loadConfig(), and left
-- every setting on the Configuration page empty while the page itself looked
-- healthy. The views append ?v=<stamp> to each asset, so an upgrade asks for
-- a URL the browser has never seen.
--
-- VERSION is written by the package's install rule, so its mtime moves on
-- every upgrade even when the version string does not. fcc.css is the
-- fallback for a dev tree where the version file is absent.
function asset_version()
	local t = util.mtime(VERSION_FILE) or util.mtime(ASSET_DIR .. "/fcc.css")
	return tostring(t or 0)
end

--- LuCI-FCC's own version.
function luci_version()
	local v = util.read_file(VERSION_FILE)
	if v then v = util.trim(v) end
	if not v or v == "" then return "0.0.0" end
	return v
end

--- A UCI cursor, built on demand and shared by every caller in this package.
--
-- This used to be a private helper whose comment said "LuCI normally provides a
-- global `uci` cursor; create one if this module is loaded outside a request".
-- That premise is false, and the controller believed it: nothing in luci-base
-- assigns a global `uci`. The one line that looks like it does —
-- `uci = require "luci.model.uci"` at the top of luci-lua-runtime's
-- dispatcher.lua — runs inside `module("luci.dispatcher", package.seeall)`, so
-- it writes to the *dispatcher's* table and not to _G. A controller reading a
-- bare `uci` therefore reads through to _G.uci, which is nil. Section 104.20.
--
-- Built here and cached on this module so that a request with several callers
-- still talks to one cursor, and exported so the controller has somewhere to
-- get it from rather than deriving its own.
-- A file-local upvalue, not a module field and deliberately not a global: the
-- whole bug being fixed here was code reading a `uci` that it assumed someone
-- else had set. This one is written before it is read, and only by the
-- function below.
local cached_cursor = nil

function uci_cursor()
	if cached_cursor then return cached_cursor end
	local ok, m = pcall(require, "luci.model.uci")
	if ok and m and m.cursor then
		cached_cursor = m.cursor()
		return cached_cursor
	end
	return nil
end

--- The configured install base, validated. Falls back to the default rather
--  than propagating a bad UCI value into a path we then exec from.
function install_base()
	local c = uci_cursor()
	local raw = (c and c:get("fcc", "main", "install_path")) or DEFAULT_BASE
	local ok = util.valid_install_path(raw)
	return ok or DEFAULT_BASE
end

--- The canonical FCC root, e.g. /opt/fcc.
function fcc_root()
	local base = install_base()
	if base:match("/fcc$") then return base end
	return base .. "/fcc"
end

function runtime_dir()  return fcc_root() .. "/runtime"  end
function bin_dir()      return fcc_root() .. "/bin"      end
function data_dir()     return fcc_root() .. "/data"     end
function cache_dir()    return fcc_root() .. "/cache"    end
function logs_dir()     return fcc_root() .. "/logs"     end
function sessions_dir() return fcc_root() .. "/sessions" end

--- Where an install sets its rollback copy aside. Mirrors fcc_dir_backup() in
--  common.sh: the configured path when it validates, the default otherwise,
--  and /tmp/fcc if even that is refused.
function backup_dir()
	local c = uci_cursor()
	local raw = (c and c:get("fcc", "main", "backup_path")) or DEFAULT_BACKUP
	local ok = util.valid_backup_path(raw)
	if ok then return ok end
	ok = util.valid_backup_path(DEFAULT_BACKUP)
	return ok or "/tmp/fcc"
end

--- Path of a backend script, e.g. script("status") -> /usr/libexec/fcc/status.sh
function script(name)
	if not name:match("^[a-z]+$") then return nil end
	return LIBEXEC .. "/" .. name .. ".sh"
end

--- Is the FCC runtime present? Checks the same locations as status.sh.
function server_binary()
	local candidates = {
		bin_dir() .. "/fcc-server",
		runtime_dir() .. "/bin/fcc-server",
		fcc_root() .. "/venv/bin/fcc-server",
	}
	for _, c in ipairs(candidates) do
		if util.file_exists(c) then return c end
	end
	local which = util.exec_line("/bin/sh", { "-c", "command -v fcc-server" })
	if which ~= "" then return which end
	return nil
end

function runtime_installed()
	return server_binary() ~= nil
end

--- Metadata written by install.sh at the end of a successful install.
function runtime_metadata()
	local raw = util.read_file(fcc_root() .. "/runtime.json")
	if not raw then return nil end
	return util.json_decode(raw)
end
