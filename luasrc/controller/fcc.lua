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
	-- There is deliberately no check for /etc/config/fcc here. The menu used to
	-- hide itself when that conffile was missing, and a package manager's failed
	-- upgrade can leave it missing while the package counts as installed — which
	-- turned a recoverable state into an app with no menu entry and no way to
	-- reach the page that would write the file back. The handlers already fall
	-- back to the shipped defaults when it is absent (act_config_get), and saving
	-- from the Configuration page recreates it, so the menu must not depend on it.
	--
	-- firstchild() forwards the menu entry to whichever child the signed-in user
	-- may actually reach, so the parent node needs no template of its own.
	entry({"admin", "services", "fcc"}, firstchild(), _("FCC"), 60)
	entry({"admin", "services", "fcc", "console"}, template("fcc/console"), _("Web Console"), 10)
	entry({"admin", "services", "fcc", "config"}, template("fcc/config"), _("Configuration"), 20)
	entry({"admin", "services", "fcc", "info"}, template("fcc/info"), _("Basic Information"), 30)

	-- One console session in a browser window of its own, opened from the Web
	-- Console's toolbar. It is a page, not an API action, and it is routed by
	-- hand for the same reason the admin proxy below is: leaf = true, and no
	-- title so the menu does not list it. Its template carries no header or
	-- footer, so the terminal gets the whole window rather than LuCI's
	-- navigation around it.
	entry({"admin", "services", "fcc", "popout"}, call("act_popout")).leaf = true

	-- JSON API. One leaf per action so the intent is greppable and each can be
	-- refused individually.
	local api = { "admin", "services", "fcc", "api" }
	local actions = {
		status = "act_status", status_refresh = "act_status_refresh",
		agents = "act_agents", agent_versions = "act_agent_versions",
		sessions = "act_sessions", session_create = "act_session_create",
		session_output = "act_session_output", session_input = "act_session_input",
		session_resize = "act_session_resize", session_capture = "act_session_capture",
		session_close = "act_session_close", session_cleanup = "act_session_cleanup",
		session_close_all = "act_session_close_all",
		session_close_later = "act_session_close_later",
		server = "act_server",
		install_runtime = "act_install_runtime",
		reinstall_runtime = "act_reinstall_runtime",
		uninstall_runtime = "act_uninstall_runtime",
		job = "act_job",
		doctor = "act_doctor",
		update_check = "act_update_check",
		update_runtime = "act_update_runtime",
		config_get = "act_config_get",
		config_set = "act_config_set",
		log = "act_log",
		remote_get = "act_remote_get",
		remote_set = "act_remote_set",
		remote_mode = "act_remote_mode",
		remote_keygen = "act_remote_keygen",
		remote_trust = "act_remote_trust",
		remote_forget = "act_remote_forget",
		remote_test = "act_remote_test",
		remote_control = "act_remote_control",
		remote_running = "act_remote_running",
	}
	for name, fn in pairs(actions) do
		local e = entry({ "admin", "services", "fcc", "api", name }, call(fn))
		-- leaf = true tells the dispatcher this node is a terminal endpoint: it
		-- is never listed in a menu and never treated as a parent.
		e.leaf = true
	end

	-- The FCC Admin UI, served through LuCI.
	--
	-- It gets a route of its own rather than an action under /api because it is
	-- not an API: the browser loads the whole single-page application from here,
	-- its assets included, and the paths below this node are the SPA's own.
	-- leaf = true is what makes that work — the dispatcher turns it into a
	-- wildcard, so every path underneath reaches this one action, which forwards
	-- it upstream unchanged.
	--
	-- The node is inside the admin tree, so the route is behind LuCI's
	-- authentication and its ACLs. That is the point of proxying rather than
	-- listening on a second port: the FCC admin API is not authenticated at all,
	-- so anything that reaches it directly reaches all of it. Section 104.22.
	-- No title, so the menu leaves it out: the dispatcher lists a child only
	-- when it has one.
	entry({ "admin", "services", "fcc", "adminproxy" }, call("act_admin_proxy")).leaf = true
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

--- Could this text be a JSON document from a backend script?
---
--- Deliberately structural rather than a parse: this has to answer the same
--- way on a LuCI that has luci.jsonc, one that has luci.json, and one with
--- neither. The shape is fixed — the document opens with an object (or
--- array), closes the same way, and carries no control character except the
--- newline that separates the lines of a pretty-printed one. That last rule
--- is what matters: a raw carriage return or tab inside a string is exactly
--- what makes JSON.parse() throw on the whole body, and the page can then only
--- say "Malformed response from the router" without naming the script that
--- caused it. Section 104.20.
local function looks_like_json(text)
	if type(text) ~= "string" then return false end
	local t = text:match("^%s*(.-)%s*$")
	if t == "" then return false end
	local first, last = t:sub(1, 1), t:sub(-1)
	if (first ~= "{" and first ~= "[") or (last ~= "}" and last ~= "]") then
		return false
	end
	if t:find("[%z\1-\9\11-\31]") then return false end
	return true
end

--- Run a backend script and relay its stdout verbatim.
---
--- Verbatim, but never unparsable: a script that answers with something other
--- than JSON is reported as such, with the beginning of what it said, instead
--- of being forwarded to a page that can only call it malformed.
local function relay(script, args)
	local path = paths.script(script)
	if not path or not util.file_exists(path) then
		return fail("backend script not found: " .. tostring(script))
	end
	local out = util.exec_argv(path, args)
	if out == "" then out = "{}" end
	if not looks_like_json(out) then
		return fail("the backend script " .. tostring(script) .. ".sh answered with something that is not JSON: "
			.. util.trim(out):sub(1, 300))
	end
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

--- The one source of a UCI cursor for every handler on this page.
--
-- It is a function rather than a `local c = uci` for the reason section 104.20
-- records: a bare `uci` is nil under every LuCI this package runs on. Keeping
-- the call in one place also means a handler added later cannot copy the old
-- line and fail the same way.
local function cfg_cursor()
	return paths.uci_cursor()
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

--- The pre-install report, for the whole registry unless one agent is named.
---
--- The checks are about a set of agents, not about the device: a box with no
--- C++ runtime for the Node the npm three need is blocked for an install of
--- every agent and not blocked for an install of Claude Code. The page's agent
--- dropdown narrows the install, so the report has to be asked about the same
--- set — otherwise the panel says the install is blocked while the job, which
--- asks the shell the identical question about the id it was given, runs it.
--- Nothing is named by default, which is the whole registry, exactly as before
--- the dropdown existed.
function act_doctor()
	local argv = { "--json" }
	local want = http.formvalue("agent")
	if want and want ~= "" then
		local id = util.valid_agent(want)
		if not id or not agents.exists(id) then return fail("unknown agent") end
		argv = { "--json", "--agents", id }
	end
	relay("doctor", argv)
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
--
-- A report, not a control: the agent list lives on Basic Information, and the
-- only thing that acts on it is the version re-detect. Per-agent install and
-- remove were the two actions behind the Configuration page's agent table, and
-- they went with it (section 104.25) — an install now takes the whole registry,
-- and the shell's `agent.sh install|remove <id>` is still there for the command
-- line.
-- ---------------------------------------------------------------------------
function act_agents()
	relay("agent", { "list" })
end

function act_agent_versions()
	if not require_post() then return end
	relay("agent", { "versions", "--refresh" })
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
local function append_job_line(logpath, text)
	local fh = io.open(logpath, "a")
	if not fh then return end
	fh:write(text, "\n")
	fh:close()
end

local function write_job_marker(logpath, label)
	append_job_line(logpath, util.job_marker_line(label))
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
		-- the person sees, and the ways it can happen — the script is not
		-- installed, it is not executable, no shell could be forked, the shell
		-- complained while starting the job — are fixed differently.
		return fail("could not start the job" .. (why and (": " .. why) or ""))
	end

	if pid == 0 then
		-- Started, but the wrapper shell did not name a pid. See
		-- util.spawn_detached() for why that is not a failure. The line below is
		-- the evidence that is left behind: the next person to read this log
		-- sees that the run began, and that the pid was never known, rather than
		-- having to infer either from a marker with nothing after it.
		--
		-- It is written after the fork, so it can land among the job's own first
		-- lines. That is safe: it is not a marker, so current_run()'s slice is
		-- unaffected, and one short line under O_APPEND does not interleave.
		append_job_line(log, util.job_note_line(
			"job started, but the wrapper shell reported no process id"))
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
--- Install the runtime and the agents the page asked for.
--
-- The page used to send a ticked subset (section 3.6.5) and this relayed it.
-- It no longer sends one: the agent table is gone from the page (section
-- 104.25), and with nothing chosen an install takes the whole registry, so one
-- install makes every agent usable. The set is named by flag rather than listed
-- here, so the registry stays the only place it is written down.
--
-- What the page can send is one agent id, and that is not the table coming
-- back — there is one value and no set to reconcile. It exists because the
-- whole-registry install is all-or-nothing in a way that is easy to miss:
-- upstream stops at the first agent it cannot install and rolls the entire run
-- back (§79), so a device where one agent cannot be installed is a device where
-- no agent can, and the only way out is to ask for them one at a time.
--
-- The cost of the whole set is real and is not hidden: a device that cannot
-- hold it fails the install's own precheck, which names the check that failed
-- and stops before downloading anything. That is a better answer than silently
-- installing a subset nobody chose.
--
-- The id is checked against the registry here as well as in the shell. The
-- shell refuses an unknown id on its own — the job stops with
-- AGENT_SELECTION_REJECTED — but that reaches the page as a run that failed a
-- moment after it started; this one arrives as the answer to the click.
function act_install_runtime()
	if not require_post() then return end
	local argv = { "install", "runtime", "--all-agents" }
	local want = http.formvalue("agent")
	if want and want ~= "" then
		local id = util.valid_agent(want)
		if not id or not agents.exists(id) then return fail("unknown agent") end
		argv = { "install", "runtime", "--agents", id }
	end
	start_job(argv, "fcc-runtime.log", "install")
end

--- Remove the runtime and install it again with every agent.
--
-- Distinct from act_install_runtime, and the difference is not cosmetic: the
-- upstream installer reconciles the agent set and never reinstalls an agent
-- that is already present, so only removing the runtime makes the agents get
-- installed again. See cmd_reinstall() in install.sh.
function act_reinstall_runtime()
	if not require_post() then return end
	start_job({ "install", "reinstall" }, "fcc-runtime.log", "install")
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

--- Stop the FCC server on the LAN target, if there is one to stop.
---
--- Best effort by design: the remote answer cannot make this router's own
--- server refuse to start. What it does decide is what the page is told — the
--- switch promises that only one server runs, and "the other side was stopped"
--- is a claim only the remote can support.
local function stop_remote_server()
	local out = run("remote", { "control", "stop" })
	local d = util.json_decode(util.trim(out or ""))
	return type(d) == "table" and d.ok == true
end

--- Run one lifecycle verb on this router's FCC server.
---
--- This is the "This router" half of the one-server rule. Starting here means
--- the LAN server is stopped first and the control target is written as this
--- router, so a caller that reached the action without the switch cannot leave
--- the page pointing at the LAN while this server runs.
function act_server()
	if not require_post() then return end
	local op = http.formvalue("op")
	if not op or not SERVER_OPS[op] then return fail("invalid operation") end

	local remote_stopped = false
	if op == "start" or op == "restart" or op == "reload" then
		remote_stopped = stop_remote_server()
		local c = cfg_cursor()
		if c then
			c:set("fcc", "main", "control_target", "local")
			c:commit("fcc")
		end
	end

	local out, code = util.exec_argv("/etc/init.d/fcc", { op })
	json_out('{"ok":' .. (code == 0 and "true" or "false") ..
		',"op":' .. util.json_encode(op) ..
		',"remote_stopped":' .. (remote_stopped and "true" or "false") ..
		',"output":' .. util.json_encode(util.trim(out or "")) .. '}')
end

-- ---------------------------------------------------------------------------
-- FCC server on another machine
--
-- The Configuration page's FCC Server section has one control target: this
-- router, or one other machine on the LAN. Everything about the remote side —
-- the SSH key, the pinned host key, the command presets and the Admin tunnel —
-- lives in remote.sh; these handlers validate the form values, store them in
-- UCI and relay the script's JSON. No credential is ever stored here.
-- ---------------------------------------------------------------------------

--- The stored remote configuration, plus what remote.sh makes of it now.
function act_remote_get()
	relay("remote", { "status" })
end

--- Save the remote target and connection settings.
--
-- A changed address or SSH port is a different host as far as trust is
-- concerned, so the pinned fingerprint and known_hosts entry are discarded and
-- the tunnel is stopped. Anything else only invalidates the tunnel.
function act_remote_set()
	if not require_post() then return end
	local c = cfg_cursor()
	if not c then return fail("configuration is unavailable") end

	-- An empty address or account is a legitimate half-configured state: the
	-- page shows the fields, and the buttons stay disabled until both are set.
	-- A non-empty value must pass the same grammar remote.sh enforces.
	local host = util.trim(http.formvalue("host") or "")
	if host ~= "" then
		host = util.valid_remote_host(host)
		if not host then return fail("invalid remote address") end
	end

	local user = util.trim(http.formvalue("user") or "")
	if user ~= "" then
		user = util.valid_remote_user(user)
		if not user then return fail("invalid remote user") end
	end

	local sport = util.valid_int(http.formvalue("ssh_port") or "22", 1, 65535)
	if not sport then return fail("invalid SSH port") end

	local aport = util.valid_int(http.formvalue("admin_port") or "8082", 1, 65535)
	if not aport then return fail("invalid Admin port") end

	local platform = util.valid_remote_platform(http.formvalue("platform") or "linux")
	if not platform then return fail("invalid platform") end

	local service = util.valid_remote_service(http.formvalue("service") or "fcc")
	if not service then return fail("invalid service name") end

	local old_host  = c:get("fcc", "main", "remote_host") or ""
	local old_user  = c:get("fcc", "main", "remote_user") or ""
	local old_sport = tostring(c:get("fcc", "main", "remote_ssh_port") or "22")
	local old_aport = tostring(c:get("fcc", "main", "remote_admin_port") or "8082")

	local host_changed = (old_host ~= host) or (old_sport ~= tostring(sport))
	local changed = host_changed
		or (old_user ~= user)
		or (old_aport ~= tostring(aport))

	c:set("fcc", "main", "remote_host", host)
	c:set("fcc", "main", "remote_user", user)
	c:set("fcc", "main", "remote_ssh_port", tostring(sport))
	c:set("fcc", "main", "remote_admin_port", tostring(aport))
	c:set("fcc", "main", "remote_platform", platform)
	c:set("fcc", "main", "remote_service", service)
	if host_changed then
		-- The pinned key belonged to the old endpoint.
		c:set("fcc", "main", "remote_fingerprint", "")
	end
	c:commit("fcc")

	-- The script reads UCI, so this runs after the commit. Not being able to
	-- stop a tunnel is not a reason to fail the save: the next request that
	-- needs one either reuses the live tunnel or starts a new one.
	if host_changed then
		run("remote", { "forget" })
	elseif changed then
		run("remote", { "tunnel-stop" })
	end

	json_out('{"ok":true,"changed":' .. (changed and "true" or "false") ..
		',"trust_reset":' .. (host_changed and "true" or "false") .. '}')
end

--- Switch the FCC Server section between this router and the LAN.
---
--- The switch chooses which single FCC Server runs, so it stops the other one
--- as well:
---
---   * to the LAN — this router's server is stopped, so the machine the page is
---     now pointing at is the only one left running;
---   * to this router — the LAN server is stopped first (remote.sh allows a
---     stop whatever the stored target says, which is what makes this one
---     request), then the tunnel, which the Admin proxy uses only in LAN mode.
---
--- Neither direction starts anything: the button for that is on the panel the
--- switch just opened, and a start is a decision about a running service, not
--- a side effect of changing a dropdown.
function act_remote_mode()
	if not require_post() then return end
	local c = cfg_cursor()
	if not c then return fail("configuration is unavailable") end
	local mode = http.formvalue("mode")
	if mode ~= "local" and mode ~= "lan" then return fail("invalid control target") end

	local remote_stopped = false
	if mode == "local" then
		remote_stopped = stop_remote_server()
	end
	c:set("fcc", "main", "control_target", mode)
	c:commit("fcc")

	local local_stopped = false
	if mode == "lan" then
		local _, code = util.exec_argv("/etc/init.d/fcc", { "stop" })
		local_stopped = (code == 0)
	end
	run("remote", { "tunnel-stop" })

	json_out('{"ok":true,"mode":' .. util.json_encode(mode) ..
		',"local_stopped":' .. (local_stopped and "true" or "false") ..
		',"remote_stopped":' .. (remote_stopped and "true" or "false") .. '}')
end

--- Create the router's key pair, or return the existing public half.
function act_remote_keygen()
	if not require_post() then return end
	relay("remote", { "keygen" })
end

--- Pin the host key the user confirmed.
--
-- The fingerprint is what the page showed after the first scan. remote.sh scans
-- again and refuses when the key changed in between — the fingerprint is
-- stored only after the script says it matched, so a page that trusts a host
-- that has changed cannot pin the new key by accident.
function act_remote_trust()
	if not require_post() then return end
	local fp = util.valid_fingerprint(http.formvalue("fingerprint") or "")
	if not fp then return fail("invalid fingerprint") end

	local out, _ = run("remote", { "trust", fp })
	-- The output is relayed whatever it says; it is consumed here as well so a
	-- successful trust can be recorded in UCI.
	local ok = false
	local d = util.json_decode((out or ""):match("^[^\n]*") or "")
	if type(d) == "table" and d.ok == true then
		local stored = util.valid_fingerprint(d.fingerprint)
		if stored then
			local c = cfg_cursor()
			if not c then return fail("configuration is unavailable") end
			c:set("fcc", "main", "remote_fingerprint", stored)
			c:commit("fcc")
			ok = true
		end
	end
	if not ok and util.trim(out or "") == "" then
		return fail("could not trust the remote host key")
	end
	json_out(util.trim(out or "") ~= "" and util.trim(out) or "{}")
end

--- Forget the pinned host key and stop the tunnel.
function act_remote_forget()
	if not require_post() then return end
	local c = cfg_cursor()
	if c then
		c:set("fcc", "main", "remote_fingerprint", "")
		c:commit("fcc")
	end
	relay("remote", { "forget" })
end

--- Try the SSH connection. With no pinned host key this scans the remote and
--  answers needs_trust plus the fingerprint, which the page confirms.
function act_remote_test()
	if not require_post() then return end
	relay("remote", { "test" })
end

local REMOTE_OPS = { start = true, stop = true, restart = true }

function act_remote_control()
	if not require_post() then return end
	local op = http.formvalue("op")
	if not op or not REMOTE_OPS[op] then return fail("invalid operation") end
	-- The LAN is the other half of the one-server rule: a start or a restart
	-- there stops this router's server first. A stop has nothing on this side
	-- to take down and is relayed as it is.
	if op ~= "stop" then
		util.exec_argv("/etc/init.d/fcc", { "stop" })
	end
	relay("remote", { "control", op })
end

--- Ask the LAN machine whether its FCC server is running.
---
--- Read-only, and deliberately not part of the batched status call: it is one
--- SSH round trip, and a page opened on the local side must not wait for a
--- host it is not using. The page asks after the LAN panel is the one shown,
--- so a reload still reports what is actually running over there.
function act_remote_running()
	relay("remote", { "running" })
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

--- End every session this console owns. The backend answers with how many it
--  closed; sessions outside the fcc-* namespace are not its to touch.
function act_session_close_all()
	if not require_post() then return end
	relay("session", { "close-all" })
end

--- Arm a close for when the standalone window goes away.
--
-- Not an immediate close: a reload unloads the page too, and the session has to
-- survive that. The backend closes it after `grace` seconds unless the page has
-- re-attached (capture bumps a generation counter); see cmd_close_later() in
-- session.sh for how the two requests are told apart.
function act_session_close_later()
	if not require_post() then return end
	local name = util.valid_session(http.formvalue("name"))
	if not name then return fail("invalid session") end
	local grace = util.valid_int(http.formvalue("grace") or "8", 0, 120) or 8
	local _, code = run("session", { "close-later", name, tostring(grace) })
	if code ~= 0 then return fail("session not found") end
	json_out(ok())
end

--- The standalone window: one session, no LuCI chrome.
--
-- The name is validated before it reaches the template, and the template only
-- writes it into text and a JS string literal — valid_session() admits nothing
-- but fcc-<agent>-NNN, so there is nothing to escape into.
function act_popout()
	local name = util.valid_session(http.formvalue("session"))
	if not name then
		pcall(function() http.status(400, "Bad Request") end)
		http.prepare_content("text/plain")
		http.write("unknown session\n")
		return
	end
	local tpl = require "luci.template"
	tpl.render("fcc/popout", { session = name })
end

-- ---------------------------------------------------------------------------
-- FCC Admin reverse proxy
-- ---------------------------------------------------------------------------
--- Serve the FCC Admin UI and its API through LuCI.
--
-- The module is required here rather than at the top of this file on purpose:
-- it pulls in luci.httpclient, and a controller that cannot load is a page that
-- does not render at all. Everything else on this page keeps working when the
-- proxy's dependency is missing, and the route is the only thing that fails.
--
-- require_post() is deliberately not applied. The proxy relays whatever method
-- it was given, including the POSTs the admin API makes, and it does not decide
-- what may be posted — the FCC server does. What protects it is LuCI's own
-- authentication, which every request to this path has already passed.
function act_admin_proxy()
	local ok_mod, proxy = pcall(require, "luci.fcc.adminproxy")
	if not ok_mod or type(proxy) ~= "table" then
		pcall(function() http.status(500, "Internal Server Error") end)
		http.prepare_content("text/plain")
		http.write("the FCC Admin proxy is unavailable: " .. tostring(proxy) .. "\n")
		return
	end
	proxy.serve()
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
local LOG_LEVELS = { debug = true, info = true, warning = true, error = true, critical = true }

function act_config_get()
	-- The cursor comes from luci.fcc.paths, never from a bare `uci`.
	--
	-- `local c = uci` here read a global that does not exist, so `c` was nil,
	-- `g()` fell through to its default every time, and this page displayed the
	-- defaults as though they were the saved configuration — which is why a
	-- saved bind address never appeared in the form. It failed quietly, which
	-- is the worse half: the setter below failed loudly and the pair looked
	-- like one broken page instead of one broken global. Section 104.20.
	local c = cfg_cursor()
	local function g(opt, default)
		local v = c and c:get("fcc", "main", opt)
		if v == nil or v == "" then return default end
		return v
	end
	local cfg = {
		enabled       = g("enabled", "1"),
		install_path  = g("install_path", "/opt"),
		-- The effective path, not the raw setting: an install falls back to the
		-- next candidate when this one does not validate, and the form should
		-- show the directory the copies would actually be written to.
		backup_path   = paths.backup_dir(),
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
	-- Same cursor, same source as act_config_get above: a bare `uci` is nil
	-- under every LuCI this package runs on, so this line used to be the whole
	-- of "Save & Apply" — every submit answered "configuration is
	-- unavailable" and no setting on the page could be stored at all,
	-- including the bind address that "Open FCC Admin" depends on. §104.20.
	local c = cfg_cursor()
	if not c then return fail("configuration is unavailable") end

	local newpath = util.valid_install_path(http.formvalue("install_path") or "")
	if not newpath then return fail("invalid install path") end

	-- Where an install sets its rollback copy aside. Unlike the install path it
	-- may live under /tmp: the copy is deleted as soon as the install ends, and
	-- on OpenWrt /tmp is tmpfs, which keeps it off the flash. Left alone when the
	-- field is absent, so a page cached from before this setting existed can
	-- still save the settings it does show.
	local bp_raw = http.formvalue("backup_path")
	local newbackup
	if bp_raw ~= nil then
		newbackup = util.valid_backup_path(bp_raw)
		if not newbackup then return fail("invalid backup path") end
	end

	local port = util.valid_int(http.formvalue("port") or "8082", 1, 65535)
	if not port then return fail("invalid port") end

	local bind = util.valid_bind(http.formvalue("bind") or "")
	if not bind then return fail("invalid bind address") end

	local level = http.formvalue("log_level") or "info"
	if not LOG_LEVELS[level] then return fail("invalid log level") end

	local enabled    = (http.formvalue("enabled") == "1") and "1" or "0"
	local auto_start = (http.formvalue("auto_start") == "1") and "1" or "0"

	-- Save and Save & Apply are the same form posted through one handler; the
	-- difference is this flag. With apply=0 the values are stored and nothing
	-- else moves: a running server keeps the settings it started with, which
	-- is the only way to stage a port or bind change without dropping the
	-- agent sessions that are attached. Absent means apply, so a page cached
	-- from before this button existed still behaves as it did.
	local apply = (http.formvalue("apply") ~= "0")

	-- Changing the install path invalidates the runtime that lives there; the
	-- UI warns about this before submitting. We do not move anything.
	local oldpath = c:get("fcc", "main", "install_path")
	local path_changed = (oldpath ~= newpath)

	c:set("fcc", "main", "install_path", newpath)
	if newbackup then c:set("fcc", "main", "backup_path", newbackup) end
	c:set("fcc", "main", "port", tostring(port))
	c:set("fcc", "main", "bind", bind)
	c:set("fcc", "main", "log_level", level)
	c:set("fcc", "main", "enabled", enabled)
	c:set("fcc", "main", "auto_start", auto_start)
	c:commit("fcc")

	-- Apply the enable/disable and restart so a port/bind change takes effect.
	local fw = "unchanged"
	if apply then
		if enabled == "1" then
			util.exec_argv("/etc/init.d/fcc", { "enable" })
			util.exec_argv("/etc/init.d/fcc", { "restart" })
		else
			util.exec_argv("/etc/init.d/fcc", { "stop" })
			util.exec_argv("/etc/init.d/fcc", { "disable" })
		end

		-- Section 50: a wildcard bind is the one case that needs an explicit
		-- LAN-only rule, because the server then answers on every interface. A
		-- bind to a specific address needs none — the server listens on that
		-- interface only — so a rule left over from a previous wildcard bind is
		-- removed rather than allowed to sit there granting access nothing asked
		-- for. Nothing here ever writes a wan-zone rule.
		local wildcard = (bind == "0.0.0.0" or bind == "::")
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
	end

	json_out('{"ok":true,"applied":' .. (apply and "true" or "false") ..
		',"restarted":' .. (apply and "true" or "false") ..
		',"path_changed":' .. (path_changed and "true" or "false") ..
		',"firewall":' .. util.json_encode(fw) ..
		',"fcc_root":' .. util.json_encode(paths.fcc_root()) .. '}')
end
