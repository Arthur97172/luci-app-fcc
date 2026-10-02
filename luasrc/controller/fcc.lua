-- luci-app-fcc — LuCI controller.
--
-- Three pages, one JSON API:
--
--   Web Console      /admin/services/fcc/console   interactive terminal
--   Configuration    /admin/services/fcc/config    settings + runtime lifecycle
--   Basic Info       /admin/services/fcc/info      runtime monitor
--
-- Every API action follows the same shape: validate every parameter with
-- luci.fcc.util, run one backend script with an explicit argv, and relay the
-- result. Nothing is ever handed to a shell as a concatenated string
-- (DESIGN_SPEC.md section 30).

module("luci.controller.fcc", package.seeall)

local http   = require "luci.http"
local util   = require "luci.fcc.util"
local paths  = require "luci.fcc.paths"
local agents = require "luci.fcc.agents"

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------
function index()
	if not util.file_exists("/etc/config/fcc") then
		return
	end

	-- firstchild() forwards the menu entry to whichever child the signed-in user
	-- may actually reach, so the parent node needs no template of its own.
	entry({"admin", "services", "fcc"}, firstchild(), _("FCC"), 60)
	entry({"admin", "services", "fcc", "console"}, template("fcc/console"), _("Web Console"), 10)
	entry({"admin", "services", "fcc", "config"}, template("fcc/config"), _("Configuration"), 20)
	entry({"admin", "services", "fcc", "info"}, template("fcc/info"), _("Basic Information"), 30)

	-- JSON API. One leaf per action so the intent is greppable and each can be
	-- refused individually.
	local api = { "admin", "services", "fcc", "api" }
	local actions = {
		status = "act_status", status_refresh = "act_status_refresh",
		agents = "act_agents", agent_versions = "act_agent_versions",
		agent_install = "act_agent_install", agent_remove = "act_agent_remove",
		sessions = "act_sessions", session_create = "act_session_create",
		session_output = "act_session_output", session_input = "act_session_input",
		session_resize = "act_session_resize", session_capture = "act_session_capture",
		session_close = "act_session_close", session_cleanup = "act_session_cleanup",
		server = "act_server",
		install_runtime = "act_install_runtime",
		uninstall_runtime = "act_uninstall_runtime",
		job = "act_job",
		doctor = "act_doctor",
		update_check = "act_update_check",
		update_runtime = "act_update_runtime",
		config_get = "act_config_get",
		config_set = "act_config_set",
		log = "act_log",
	}
	for name, fn in pairs(actions) do
		local e = entry({ "admin", "services", "fcc", "api", name }, call(fn))
		-- leaf = true tells the dispatcher this node is a terminal endpoint: it
		-- is never listed in a menu and never treated as a parent.
		e.leaf = true
	end
end

-- ---------------------------------------------------------------------------
-- Response helpers
-- ---------------------------------------------------------------------------
local function json_out(text)
	http.prepare_content("application/json")
	http.write(text or "{}")
end

local function fail(msg)
	pcall(function() http.status(400, "Bad Request") end)
	json_out('{"error":' .. util.json_encode(tostring(msg)) .. '}')
end

local function ok(extra)
	local body = '{"ok":true'
	if type(extra) == "string" and extra ~= "" then
		body = body .. "," .. extra
	end
	return body .. "}"
end

local function is_post()
	return (http.getenv("REQUEST_METHOD") or "GET") == "POST"
end

--- Reject anything that is not a POST, so a cross-site <img> or a link cannot
--  trigger a state change.
local function require_post()
	if is_post() then return true end
	fail("this action requires POST")
	return false
end

--- Run a backend script and relay its stdout verbatim.
local function relay(script, args)
	local path = paths.script(script)
	if not path or not util.file_exists(path) then
		return fail("backend script not found: " .. tostring(script))
	end
	local out = util.exec_argv(path, args)
	if out == "" then out = "{}" end
	json_out(out)
end

--- Run a backend script, returning its output instead of relaying it.
--- Read the last `n` lines of a file, using whichever tail this system has.
local function tail(path, n)
	local bin = util.which("tail")
	if not bin then return "" end
	return util.exec_argv(bin, { "-n", tostring(n), path })
end

local function run(script, args)
	local path = paths.script(script)
	if not path or not util.file_exists(path) then return "", 127 end
	return util.exec_argv(path, args)
end

-- ---------------------------------------------------------------------------
-- Status / monitor
-- ---------------------------------------------------------------------------
function act_status()
	relay("status")
end

function act_status_refresh()
	if not require_post() then return end
	relay("status", { "--refresh-versions" })
end

function act_doctor()
	relay("doctor", { "--json" })
end

function act_update_check()
	relay("update", { "check" })
end

--- Tail a log file. Only files directly inside the logs directory are
--  reachable, and the name is validated, so this cannot be used to read
--  /etc/shadow.
function act_log()
	local name = http.formvalue("name") or "fcc-runtime.log"
	if not name:match("^[A-Za-z0-9_.-]+$") or #name > 64 then
		return fail("invalid log name")
	end
	local want = util.valid_int(http.formvalue("lines") or "200", 1, 2000) or 200
	local dir = paths.logs_dir()
	local path = dir .. "/" .. name
	if not util.file_exists(path) then
		-- The backend falls back to /tmp when the install path is not writable.
		path = "/tmp/fcc-logs/" .. name
	end
	if not util.file_exists(path) then
		return json_out('{"name":' .. util.json_encode(name) .. ',"lines":[],"missing":true}')
	end
	local out = tail(path, want)
	local lines = {}
	for line in (out or ""):gmatch("[^\n]*") do
		lines[#lines + 1] = line
	end
	json_out('{"name":' .. util.json_encode(name) ..
		',"path":' .. util.json_encode(path) ..
		',"lines":' .. util.json_encode(lines) .. '}')
end

-- ---------------------------------------------------------------------------
-- Agents
-- ---------------------------------------------------------------------------
function act_agents()
	relay("agent", { "list" })
end

function act_agent_versions()
	if not require_post() then return end
	relay("agent", { "versions", "--refresh" })
end

function act_agent_install()
	if not require_post() then return end
	local id = util.valid_agent(http.formvalue("id"))
	if not id or not agents.exists(id) then return fail("unknown agent") end
	start_job({ "agent", "install", id }, "fcc-runtime.log", "install")
end

function act_agent_remove()
	if not require_post() then return end
	local id = util.valid_agent(http.formvalue("id"))
	if not id or not agents.exists(id) then return fail("unknown agent") end
	start_job({ "agent", "remove", id }, "fcc-runtime.log", "install")
end

-- ---------------------------------------------------------------------------
-- Long-running jobs
--
-- Install/update take minutes. The HTTP request only starts the work and
-- returns; the UI then polls act_job() for the lock state and the log tail.
-- ---------------------------------------------------------------------------
function start_job(argv, logname, lockname)
	local script = paths.script(argv[1])
	if not script or not util.file_exists(script) then
		return fail("backend script not found: " .. tostring(argv[1]))
	end
	local rest = {}
	for i = 2, #argv do rest[#rest + 1] = argv[i] end

	local log = paths.logs_dir() .. "/" .. logname
	-- Make sure the log directory exists before the detached child opens it.
	local mkdir = util.which("mkdir")
	if mkdir then util.exec_argv(mkdir, { "-p", paths.logs_dir() }) end

	local pid = util.spawn_detached(script, rest, log)
	if not pid then return fail("could not start the job") end
	json_out('{"ok":true,"started":true,"pid":' .. pid ..
		',"lock":' .. util.json_encode(lockname) ..
		',"log":' .. util.json_encode(logname) .. '}')
end

--- Report whether a background job is still running, plus the tail of its log.
function act_job()
	local lockname = http.formvalue("lock") or "install"
	if not lockname:match("^[a-z]+$") then return fail("invalid lock name") end

	local lockdir = "/var/lock"
	if not util.file_exists(lockdir) then lockdir = "/tmp" end
	local lockpath = lockdir .. "/fcc-" .. lockname .. ".lock"
	local running = util.file_exists(lockpath)

	local logname = http.formvalue("log") or "fcc-runtime.log"
	if not logname:match("^[A-Za-z0-9_.-]+$") then logname = "fcc-runtime.log" end
	local want = util.valid_int(http.formvalue("lines") or "40", 1, 500) or 40
	local logpath = paths.logs_dir() .. "/" .. logname
	if not util.file_exists(logpath) then
		logpath = "/tmp/fcc-logs/" .. logname
	end
	local lines = {}
	if util.file_exists(logpath) then
		local out = tail(logpath, want)
		for line in (out or ""):gmatch("[^\n]*") do
			lines[#lines + 1] = line
		end
	end

	json_out('{"running":' .. (running and "true" or "false") ..
		',"lock":' .. util.json_encode(lockname) ..
		',"log":' .. util.json_encode(logname) ..
		',"lines":' .. util.json_encode(lines) ..
		',"runtime_installed":' .. (paths.runtime_installed() and "true" or "false") .. '}')
end

-- ---------------------------------------------------------------------------
-- FCC runtime lifecycle
-- ---------------------------------------------------------------------------
function act_install_runtime()
	if not require_post() then return end
	-- `agents` is a comma-separated subset of the registry.
	local raw = http.formvalue("agents") or ""
	local list = {}
	for part in raw:gmatch("[^,]+") do
		local id = util.valid_agent(util.trim(part))
		if not id or not agents.exists(id) then return fail("unknown agent: " .. part) end
		list[#list + 1] = id
	end
	local argv = { "install", "runtime" }
	if #list > 0 then
		argv[#argv + 1] = "--agents"
		argv[#argv + 1] = table.concat(list, ",")
	end
	start_job(argv, "fcc-runtime.log", "install")
end

function act_uninstall_runtime()
	if not require_post() then return end
	local purge = (http.formvalue("purge") == "1")
	local argv = { "install", "uninstall" }
	if purge then argv[#argv + 1] = "--purge" end
	-- Removal is fast, but the agent set makes it a job too, for one code path.
	start_job(argv, "fcc-runtime.log", "install")
end

function act_update_runtime()
	if not require_post() then return end
	start_job({ "update", "runtime" }, "fcc-update.log", "install")
end

-- ---------------------------------------------------------------------------
-- FCC server service control
-- ---------------------------------------------------------------------------
local SERVER_OPS = {
	start = true, stop = true, restart = true,
	enable = true, disable = true, reload = true,
}

function act_server()
	if not require_post() then return end
	local op = http.formvalue("op")
	if not op or not SERVER_OPS[op] then return fail("invalid operation") end
	local out, code = util.exec_argv("/etc/init.d/fcc", { op })
	json_out('{"ok":' .. (code == 0 and "true" or "false") ..
		',"op":' .. util.json_encode(op) ..
		',"output":' .. util.json_encode(util.trim(out or "")) .. '}')
end

-- ---------------------------------------------------------------------------
-- Web Console sessions
-- ---------------------------------------------------------------------------
function act_sessions()
	relay("session", { "list" })
end

function act_session_create()
	if not require_post() then return end
	local id = util.valid_agent(http.formvalue("agent"))
	if not id or not agents.exists(id) then return fail("unknown agent") end
	local cols = util.valid_int(http.formvalue("cols") or "80", 20, 500) or 80
	local rows = util.valid_int(http.formvalue("rows") or "24", 5, 300) or 24
	local out, code = run("session", { "create", id, tostring(cols), tostring(rows) })
	if code ~= 0 then
		return fail(util.trim(out) ~= "" and util.trim(out) or "could not create the session")
	end
	json_out(out)
end

--- Poll for output after an absolute offset.
--
-- The backend replies with a one-line JSON header followed by the raw bytes.
-- The bytes are base64-encoded here because a JSON string cannot carry the
-- arbitrary byte sequences a terminal emits (see util.base64_encode).
function act_session_output()
	local name = util.valid_session(http.formvalue("name"))
	if not name then return fail("invalid session") end
	local offset = util.valid_int(http.formvalue("offset") or "0", 0, 2 ^ 40) or 0
	local wait = util.valid_int(http.formvalue("wait") or "0", 0, 25) or 0

	local out, code = run("session", { "output", name, tostring(offset), tostring(wait) })
	if code ~= 0 then return fail("session not found") end

	local nl = out:find("\n", 1, true)
	if not nl then return fail("malformed session output") end
	local header = out:sub(1, nl - 1)
	local body = out:sub(nl + 1)

	local h = util.json_decode(header)
	if type(h) ~= "table" then
		-- Fall back to a minimal header rather than dropping the payload.
		h = { name = name, offset = offset, reset = false, alive = true, eof = false }
	end
	h.data = util.base64_encode(body)
	json_out(util.json_encode(h))
end

function act_session_input()
	if not require_post() then return end
	local name = util.valid_session(http.formvalue("name"))
	if not name then return fail("invalid session") end
	-- The browser sends base64 bytes; tmux wants hex.
	local raw = util.base64_decode(http.formvalue("data") or "")
	if not raw then return fail("invalid input encoding") end
	if raw == "" then return json_out(ok()) end
	local hex = util.bytes_to_hex(raw)
	local out, code = run("session", { "input", name, hex })
	if code ~= 0 then return fail(util.trim(out) ~= "" and util.trim(out) or "session not found") end
	json_out(ok())
end

function act_session_resize()
	if not require_post() then return end
	local name = util.valid_session(http.formvalue("name"))
	if not name then return fail("invalid session") end
	local cols = util.valid_int(http.formvalue("cols"), 20, 500)
	local rows = util.valid_int(http.formvalue("rows"), 5, 300)
	if not cols or not rows then return fail("invalid size") end
	local _, code = run("session", { "resize", name, tostring(cols), tostring(rows) })
	if code ~= 0 then return fail("could not resize the session") end
	json_out(ok())
end

--- The visible screen with escape sequences, base64-encoded, so a reconnecting
--  browser can repaint faithfully.
function act_session_capture()
	local name = util.valid_session(http.formvalue("name"))
	if not name then return fail("invalid session") end
	local out, code = run("session", { "capture", name })
	if code ~= 0 then return fail("session not found") end
	json_out('{"name":' .. util.json_encode(name) ..
		',"data":' .. util.json_encode(util.base64_encode(out)) .. '}')
end

function act_session_close()
	if not require_post() then return end
	local name = util.valid_session(http.formvalue("name"))
	if not name then return fail("invalid session") end
	local _, code = run("session", { "close", name })
	json_out('{"ok":' .. (code == 0 and "true" or "false") .. '}')
end

function act_session_cleanup()
	if not require_post() then return end
	local _, code = run("session", { "cleanup" })
	json_out('{"ok":' .. (code == 0 and "true" or "false") .. '}')
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
local LOG_LEVELS = { debug = true, info = true, warning = true, error = true, critical = true }

function act_config_get()
	local c = uci
	local function g(opt, default)
		local v = c and c:get("fcc", "main", opt)
		if v == nil or v == "" then return default end
		return v
	end
	local cfg = {
		enabled       = g("enabled", "1"),
		install_path  = g("install_path", "/opt"),
		port          = tonumber(g("port", "8082")) or 8082,
		bind          = g("bind", "127.0.0.1"),
		auto_start    = g("auto_start", "1"),
		log_level     = g("log_level", "info"),
	}
	json_out('{"config":' .. util.json_encode(cfg) ..
		',"fcc_root":' .. util.json_encode(paths.fcc_root()) ..
		',"runtime_installed":' .. (paths.runtime_installed() and "true" or "false") ..
		',"luci_version":' .. util.json_encode(paths.luci_version()) .. '}')
end

function act_config_set()
	if not require_post() then return end
	local c = uci
	if not c then return fail("configuration is unavailable") end

	local newpath = util.valid_install_path(http.formvalue("install_path") or "")
	if not newpath then return fail("invalid install path") end

	local port = util.valid_int(http.formvalue("port") or "8082", 1, 65535)
	if not port then return fail("invalid port") end

	local bind = util.valid_bind(http.formvalue("bind") or "")
	if not bind then return fail("invalid bind address") end

	local level = http.formvalue("log_level") or "info"
	if not LOG_LEVELS[level] then return fail("invalid log level") end

	local enabled    = (http.formvalue("enabled") == "1") and "1" or "0"
	local auto_start = (http.formvalue("auto_start") == "1") and "1" or "0"

	-- Changing the install path invalidates the runtime that lives there; the
	-- UI warns about this before submitting. We do not move anything.
	local oldpath = c:get("fcc", "main", "install_path")
	local path_changed = (oldpath ~= newpath)

	c:set("fcc", "main", "install_path", newpath)
	c:set("fcc", "main", "port", tostring(port))
	c:set("fcc", "main", "bind", bind)
	c:set("fcc", "main", "log_level", level)
	c:set("fcc", "main", "enabled", enabled)
	c:set("fcc", "main", "auto_start", auto_start)
	c:commit("fcc")

	-- Apply the enable/disable and restart so a port/bind change takes effect.
	if enabled == "1" then
		util.exec_argv("/etc/init.d/fcc", { "enable" })
		util.exec_argv("/etc/init.d/fcc", { "restart" })
	else
		util.exec_argv("/etc/init.d/fcc", { "stop" })
		util.exec_argv("/etc/init.d/fcc", { "disable" })
	end

	json_out('{"ok":true,"restarted":true,"path_changed":' ..
		(path_changed and "true" or "false") ..
		',"fcc_root":' .. util.json_encode(paths.fcc_root()) .. '}')
end
