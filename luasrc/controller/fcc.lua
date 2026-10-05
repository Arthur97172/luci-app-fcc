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
		agent_defaults = "act_agent_defaults",
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

--- Which agents to preselect at install (DESIGN_SPEC.md section 3.6.5).
--
-- The caller passes the budgets it already has from the status call rather than
-- this reading /proc and df again: the page has just fetched both, and two
-- sources for "how much memory is there" would eventually disagree. The policy
-- itself lives in luci.fcc.agents so it is testable on its own.
function act_agent_defaults()
	local ram  = util.valid_int(http.formvalue("ram_mb") or "", 0, 4194304)
	local free = util.valid_int(http.formvalue("free_mb") or "", 0, 16777216)
	json_out('{"ids":' .. util.json_encode(agents.default_ids(ram, free)) .. '}')
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
--- The directory a job's log goes in, created if it is not there yet.
--
-- The install path is not always writable — /opt may be absent, or sit on a
-- read-only overlay — and a job whose log cannot be opened dies before it
-- starts, because the shell applies the redirection before the exec. The
-- backend falls back to /tmp/fcc-logs and act_job() reads from there as well,
-- so the same fallback is applied here and the two cannot disagree about where
-- a job's output went.
local function job_log_dir()
	local mkdir = util.which("mkdir")
	local dir = paths.logs_dir()
	if mkdir then
		local _, code = util.exec_argv(mkdir, { "-p", dir })
		if code == 0 then return dir end
	end
	dir = "/tmp/fcc-logs"
	if mkdir then util.exec_argv(mkdir, { "-p", dir }) end
	return dir
end

--- Append the marker for a run that is about to start.
--
-- Written *before* the fork, deliberately. The child begins writing to the same
-- file the moment it is spawned and shares nothing with this process, so a marker
-- appended after spawn_detached() returned can land in the middle of the run's
-- own output — and the slice in act_job(), which keeps what follows the last
-- marker, would then discard the beginning of the very run the marker was written
-- for. Before the fork there is no race, because nothing else has the file open
-- yet.
--
-- The cost is a marker left behind by a job that then failed to start, which
-- reads as a run that produced nothing. That is what happened, and the reason is
-- on the page beside it.
local function write_job_marker(logpath, label)
	local fh = io.open(logpath, "a")
	if not fh then return end
	fh:write(util.job_marker_line(label), "\n")
	fh:close()
end

function start_job(argv, logname, lockname)
	local script = paths.script(argv[1])
	if not script or not util.file_exists(script) then
		return fail("backend script not found: " .. tostring(argv[1]))
	end
	local rest = {}
	for i = 2, #argv do rest[#rest + 1] = argv[i] end

	-- Refuse here when the job's own lock is already held.
	--
	-- The backend refuses as well — fcc_lock_acquire() is a mkdir and the loser
	-- of that race dies with "another install/update is already running" — but
	-- only after a shell has been forked, and the sentence reaches the page only
	-- by way of the job's log. A second click during a running install is an
	-- ordinary thing to do, and this is the same sentence, delivered before
	-- anything is started. The page and the log then agree.
	--
	-- It also removes the case the page handled worst. Two jobs racing for one
	-- lock means the loser's shell exits at once, and a job that exits before its
	-- pid is read back is reported as "could not start the job: the shell
	-- reported no process id" — a sentence about the wrapper, for a situation
	-- that only ever meant "something else is already running".
	--
	-- Only this job's own lock is checked. The backend also refuses an install
	-- while an update is running and vice versa (install.sh and update.sh each
	-- test the other's lock); that rule lives in one place, and the refusal it
	-- produces goes to the log like any other.
	if util.job_running(lockname) then
		return fail("another install/update is already running")
	end

	local log = job_log_dir() .. "/" .. logname
	write_job_marker(log, table.concat(argv, " "))

	local pid, why = util.spawn_detached(script, rest, log)
	if not pid then
		-- The reason, not just the verdict. This message is the whole of what
		-- the person sees, and the four ways it can happen — not installed, not
		-- executable, no shell, no pid — are fixed differently.
		return fail("could not start the job" .. (why and (": " .. why) or ""))
	end
	json_out('{"ok":true,"started":true,"pid":' .. pid ..
		',"lock":' .. util.json_encode(lockname) ..
		',"log":' .. util.json_encode(logname) .. '}')
end

--- Report whether a background job is still running, plus the tail of its log.
--
-- The tail is the current run's, not the file's: the job's log is appended to
-- across runs, so the window can otherwise open on the previous run's failure.
-- See util.current_run() for why cutting at the last marker is enough.
function act_job()
	local lockname = http.formvalue("lock") or "install"
	if not lockname:match("^[a-z]+$") then return fail("invalid lock name") end

	local running = util.job_running(lockname)

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
		-- The last element is the empty string gmatch produces after a trailing
		-- newline, not a line of the log. Dropping it keeps a run that has
		-- written nothing yet from reporting one blank line of output.
		if lines[#lines] == "" then lines[#lines] = nil end
		lines = util.current_run(lines)
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
	--
	-- The field being absent and the field being empty mean different things
	-- (section 3.6.5): absent is "no opinion, use the defaults", empty is "the
	-- user unchecked every agent". Collapsing the two would quietly install
	-- agents onto a device whose owner asked for none.
	local raw = http.formvalue("agents")
	local argv = { "install", "runtime" }
	if raw ~= nil then
		local list = {}
		for part in raw:gmatch("[^,]+") do
			local id = util.valid_agent(util.trim(part))
			if not id or not agents.exists(id) then return fail("unknown agent: " .. part) end
			list[#list + 1] = id
		end
		if #list > 0 then
			argv[#argv + 1] = "--agents"
			argv[#argv + 1] = table.concat(list, ",")
		else
			argv[#argv + 1] = "--no-agents"
		end
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
	-- Section 47's lock, not the install one: the update holds fcc-update.lock
	-- for its whole run, so this is the name the page polls to know it is still
	-- working.
	start_job({ "update", "runtime" }, "fcc-update.log", "update")
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

	-- Section 50: a wildcard bind is the one case that needs an explicit
	-- LAN-only rule, because the server then answers on every interface. A bind
	-- to a specific address needs none — the server listens on that interface
	-- only — so a rule left over from a previous wildcard bind is removed
	-- rather than allowed to sit there granting access nothing asked for.
	-- Nothing here ever writes a wan-zone rule.
	local wildcard = (bind == "0.0.0.0" or bind == "::")
	local fw = "unchanged"
	local fwscript = paths.script("firewall")
	if fwscript and util.file_exists(fwscript) then
		local args
		if wildcard then
			args = { "ensure", tostring(port) }
		else
			args = { "remove" }
		end
		local _, code = util.exec_argv(fwscript, args)
		if wildcard then
			fw = (code == 0) and "lan-allow" or "failed"
		else
			fw = "removed"
		end
	end

	json_out('{"ok":true,"restarted":true,"path_changed":' ..
		(path_changed and "true" or "false") ..
		',"firewall":' .. util.json_encode(fw) ..
		',"fcc_root":' .. util.json_encode(paths.fcc_root()) .. '}')
end
