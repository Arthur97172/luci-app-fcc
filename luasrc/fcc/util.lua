-- luci-app-fcc — shared Lua helpers.
--
-- Everything the controller does that touches the system goes through here, so
-- the validation and quoting rules live in exactly one place
-- (DESIGN_SPEC.md section 30).
--
-- Two rules this module exists to enforce:
--   1. Never build a shell command by concatenating untrusted input. Arguments
--      are quoted with shell_quote() and passed as separate argv words.
--   2. Never trust a value that came from the browser. Every id, session name,
--      integer and path is re-validated here even when the caller already
--      checked it.

module("luci.fcc.util", package.seeall)

local fs = require "nixio.fs"

-- ---------------------------------------------------------------------------
-- Process execution
-- ---------------------------------------------------------------------------

--- Quote one word for POSIX sh.
-- Wraps in single quotes and escapes embedded single quotes as '\''.
function shell_quote(s)
	s = tostring(s or "")
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Run a command with an explicit argv list.
-- @param cmd   absolute path of the executable
-- @param args  table (array) of arguments, or nil
-- @return stdout, exit-code
function exec_argv(cmd, args)
	local parts = { shell_quote(cmd) }
	for _, a in ipairs(args or {}) do
		parts[#parts + 1] = shell_quote(a)
	end
	local fh = io.popen(table.concat(parts, " ") .. " 2>/dev/null")
	if not fh then return "", 127 end
	local out = fh:read("*a") or ""
	local ok, _, code = fh:close()
	-- io.popen:close() returns true/nil plus "exit"/"signal" and the code.
	if ok == true then
		code = 0
	elseif ok == nil then
		code = 1
	end
	if type(code) ~= "number" then code = 1 end
	return out, code
end

--- Run a command and return only its trimmed first line.
function exec_line(cmd, args)
	local out = exec_argv(cmd, args)
	out = out:gsub("%s+$", "")
	return (out:match("^[^\n]*") or "")
end

--- Run a command, discarding its output.
function exec_silent(cmd, args)
	exec_argv(cmd, args)
end

--- Could this command be started at all?
--
-- This has to be answered before the fork. A shell that cannot exec the command
-- still sets `$!`, and the process it names is normally still there at the
-- moment it is read — so asking /proc afterwards is a race the child wins, and
-- a job that never ran is indistinguishable from one that started. The
-- filesystem is the only party that knows in advance.
--
-- An absolute path is checked where it is; a bare name is looked up the way the
-- shell would look it up. Whether the file is *executable* is still the exec's
-- answer to give — this rejects the case that would otherwise fail silently,
-- not every case that can fail.
local function runnable(cmd)
	if type(cmd) ~= "string" or cmd == "" then return false end
	if cmd:find("/", 1, true) then
		return fs.access(cmd) ~= nil
	end
	return which(cmd) ~= nil
end

--- Start a long-running command detached from this request.
--
-- Installing or updating the FCC runtime downloads and builds for minutes —
-- far longer than an HTTP request may live. The work is therefore started in
-- the background with its output appended to a log file, and the UI polls the
-- log and the install lock. The child's stdout/stderr and the wrapper shell's
-- are both redirected, so io.popen() does not block waiting on the pipe.
--
-- Two details here are load-bearing, and getting either wrong fails silently:
--
--   * busybox has no `nohup`. OpenWrt's /bin/sh is busybox ash and the applet
--     is not built into it, so `nohup cmd &` dies with "nohup: not found" —
--     and because the redirections are applied before the failed exec, that
--     message is written to the *log file* rather than to stderr. The job
--     never ran and nothing the caller could see said so. `setsid` is present
--     on every OpenWrt image and is the better tool regardless: the child
--     leaves this request's session, so it survives the CGI process being
--     reaped.
--   * `$!` is set as soon as the shell forks, so on its own it is not evidence
--     that the exec succeeded. That gap is closed before the fork, by
--     runnable(), because it is the only question here that can be answered
--     without racing the child.
--
-- There is deliberately no liveness check after the fork. One was tried: the
-- pid was confirmed against /proc before being reported. It answers the wrong
-- question, and it answers it as a coin toss. "Did the job start?" and "is the
-- job still running?" are different, and a job that starts and fails at once —
-- which is exactly what an install does when the compatibility gate blocks it —
-- is reported as "could not start the job". Measured in the OpenWrt smoke
-- container, `agent.sh install claude` exits in under a second when the gate
-- blocks it, so the check loses that race about as often as it wins it, and
-- when it loses it the reason, which the job has already written to its own
-- log, is replaced by an error that says nothing.
--
-- Whether the job ran, and why it stopped, is the job's own answer to give:
-- the lock it holds and the log it writes. The caller gets a pid as soon as
-- the process exists, which is what it asked for.
--
-- When it cannot be started at all, the *reason* is returned alongside the nil
-- rather than left to be inferred. "could not start the job" is true of four
-- different situations — the script is not installed, it is not executable, the
-- shell cannot be forked, the shell forked but said nothing — and each has a
-- different fix. The message a person reads is the only part of this that
-- reaches them.
--
-- @return pid (number) on success; nil plus a reason string on failure
function spawn_detached(cmd, args, logfile)
	if type(cmd) ~= "string" or cmd == "" then
		return nil, "no command was given"
	end
	if not runnable(cmd) then
		return nil, cmd .. " is missing or not executable"
	end

	local parts = { shell_quote(cmd) }
	for _, a in ipairs(args or {}) do
		parts[#parts + 1] = shell_quote(a)
	end
	local log = shell_quote(logfile or "/dev/null")
	local job = table.concat(parts, " ") .. " >> " .. log .. " 2>&1 < /dev/null"

	local setsid = which("setsid")
	if setsid then job = shell_quote(setsid) .. " " .. job end

	-- The pid is asked for by name, and the wrapper shell's own diagnostics are
	-- folded into the same pipe.
	--
	-- `echo $!` on its own was the previous form, and it is what made this
	-- function's failure impossible to act on: everything the *wrapper* shell
	-- says — a redirection it could not make, a `setsid` that turned out not to
	-- be executable, a fork refused by the process limit — goes to fd 2, which
	-- the CGI discards, while only the pid came back on fd 1. So "the shell
	-- reported no process id" arrived with no evidence attached, and the reader
	-- could not tell which of the four situations they were in. With 2>&1 the
	-- shell's complaint is captured and quoted in the reason.
	--
	-- The sentinel exists because that output is no longer guaranteed to be only
	-- a number: `out:match("%d+")` would happily return the line number out of
	-- "sh: line 1: ...". Matching a marker this function itself wrote cannot pick
	-- up a digit that came from anywhere else.
	local fh = io.popen("{ " .. job .. " & echo \"FCCPID $!\"; } 2>&1")
	if not fh then
		-- popen failed before any shell existed: out of memory, or the process
		-- table is full. Distinct from every failure below, and the only one
		-- where nothing was written to the log.
		return nil, "the shell could not be started"
	end
	local out = fh:read("*a") or ""
	fh:close()

	local pid = tonumber(out:match("FCCPID%s+(%d+)"))
	if not pid then
		local said = out:gsub("%s+$", "")
		return nil, "the shell reported no process id" ..
			(said ~= "" and (": " .. said) or "")
	end
	return pid
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

function read_file(path)
	if not path or not fs.access(path) then return nil end
	local fh = io.open(path, "r")
	if not fh then return nil end
	local data = fh:read("*a")
	fh:close()
	return data
end

function file_exists(path)
	return path ~= nil and fs.access(path) ~= nil
end

--- Seconds since a path was last modified, or nil when it is not there.
--
-- A job lock is a directory, and a directory's mtime is what says how long it has
-- been there — which is the whole of job_running() below.
function path_age(path)
	local st = fs.stat(path, "mtime")
	if type(st) ~= "number" then return nil end
	return os.time() - st
end

--- Can this path be written to? Mirrors the shell's `[ -w "$p" ]`.
function writable(path)
	local ok = fs.access(path, "w")
	return ok ~= nil and ok ~= false
end

-- ---------------------------------------------------------------------------
-- Background jobs
--
-- Installing or updating the runtime takes minutes, so the controller starts the
-- work detached and then observes it from outside: the lock the job holds and the
-- log it writes. Both belong to the shell — fcc_lock_acquire() and fcc_log() in
-- common.sh — and the rules for *reading* them live here, beside
-- valid_install_path() and for the same two reasons: so the controller stays a
-- thin translation of a request into a script call, and so the rules can be
-- tested without a web server or a router.
-- ---------------------------------------------------------------------------

--- How long a job lock may sit there before it is treated as left over by a job
--  that died rather than held by one that is running.
--
-- Mirrors FCC_LOCK_STALE_SECS in common.sh, which is where the number is
-- actually enforced: fcc_lock_acquire() reclaims a lock older than this before
-- deciding it cannot have one. The copy exists so the controller answers "is a
-- job running?" the way the shell answers "may I start one?". A controller that
-- believed a shorter window would refuse to start a job the shell would happily
-- have reclaimed; one that believed a longer window would report a dead job as
-- running and leave the page's progress bar climbing for an hour after the job
-- was killed.
--
-- tests/test_lua.sh reads the shell's value out of common.sh and asserts the two
-- are equal, because two numbers that must agree, written down twice, stop
-- agreeing.
--
-- The override is the shell's, and it is honoured here for the same reason: the
-- two numbers have to be the same number, and an override that reached only one
-- of them would be a way to make them differ. A value that is not a number at all
-- is ignored rather than propagated.
FCC_LOCK_STALE_SECS = tonumber(os.getenv("FCC_LOCK_STALE_SECS") or "") or 3600

--- Where the backend puts job locks.
--
-- Mirrors fcc_lock_dir() in common.sh: the same two candidates, in the same
-- order, decided the same way — /var/lock is used only when it is both there and
-- writable, and /tmp is the fallback. The writability half is not decoration: on
-- an image where /var/lock exists but is not writable the shell locks under /tmp,
-- and a controller that stopped at "does it exist" would then poll a path nothing
-- writes.
--
-- Getting this wrong fails quietly rather than loudly. It does not break the job,
-- which locks wherever the shell's copy of the rule says; it makes the page watch
-- the wrong file, so a job that is running looks finished and one that finished
-- looks like it is still going.
function lock_dir()
	if file_exists("/var/lock") and writable("/var/lock") then return "/var/lock" end
	return "/tmp"
end

--- The lock a job of this name holds. The name is the shell's (`install`,
--  `update`), and sharing it is what makes this the same path.
function lock_path(name)
	return lock_dir() .. "/fcc-" .. name .. ".lock"
end

--- Is a job holding this lock right now?
--
-- "The lock directory exists" is not that question. fcc_lock_acquire() creates it
-- with mkdir and fcc_lock_release() removes it, so a job that was killed — by a
-- reboot, by the OOM killer, by the user — leaves its lock behind, and the naive
-- test goes on calling that job "still running" until someone removes the
-- directory by hand. The shell treats a lock older than FCC_LOCK_STALE_SECS as
-- abandoned and reclaims it; asking the same question here is what makes the
-- page's idea of "running" and the backend's idea of "may I start" one idea.
--
-- A lock whose age cannot be read counts as live. The backend would refuse to
-- start a job against it in any case, and calling a dead job live is the failure
-- that corrects itself a moment later, when the lock is reclaimed.
function job_running(name)
	local path = lock_path(name)
	if not file_exists(path) then return false end
	local age = path_age(path)
	if age == nil then return true end
	return age <= FCC_LOCK_STALE_SECS
end

--- The line that separates one run of a job from the next in its log.
--
-- Job logs are appended to and never truncated, deliberately: the log is the only
-- record of what a failed install did, and it is what a person reads afterwards.
-- The cost is that the file is the concatenation of every run of that job since
-- it was created, and the page — which polls act_job() during a run and shows
-- what it reads there — would be handed the tail of the previous run followed by
-- the head of this one. After a retry the panel opens on the *old* failure, and
-- nothing in the text says that the lines above the new ones belong to a run that
-- has already ended. That is a log that appears to contradict itself.
--
-- So every run begins with a line only this package writes. The page reports what
-- follows the last one; act_log() reports the file as it is, markers and all,
-- which is where the history goes for anyone who wants it.
JOB_MARKER = "===== fcc job start "

--- The marker line for a run that is about to start.
function job_marker_line(label)
	return JOB_MARKER .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. ": " .. label .. " ====="
end

--- The part of a log tail that belongs to the most recent run.
--
-- Tailing a fixed number of lines and then cutting at the last marker is enough
-- in both directions, which is worth spelling out because "tail more, just in
-- case" is the obvious move and is not needed:
--
--   * A run that has written that many lines or more fills the window on its own,
--     so the marker is behind the window and nothing is cut.
--   * A run that has written fewer leaves the marker inside the window, because
--     the window reaches back further than this run has written.
--
-- With no marker at all — a log written before this existed, or by something that
-- is not this controller — the window comes back as it always did.
function current_run(lines)
	local start = 0
	for i = #lines, 1, -1 do
		if tostring(lines[i]):sub(1, #JOB_MARKER) == JOB_MARKER then start = i break end
	end
	if start == 0 then return lines end
	local out = {}
	for i = start + 1, #lines do out[#out + 1] = lines[i] end
	return out
end

--- Resolve an executable to an absolute path, checking the standard OpenWrt
--  applet directories. Returns nil when it is not installed.
function which(name)
	if type(name) ~= "string" or not name:match("^[A-Za-z0-9_.-]+$") then return nil end
	for _, dir in ipairs({ "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin" }) do
		local p = dir .. "/" .. name
		if fs.access(p) then return p end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Validation. Each returns the value on success or nil on failure.
-- ---------------------------------------------------------------------------

--- Agent id: lowercase alphanumerics, 1..16 chars.
function valid_agent(id)
	if type(id) ~= "string" then return nil end
	if #id < 1 or #id > 16 then return nil end
	if not id:match("^[a-z0-9]+$") then return nil end
	return id
end

--- Session name: fcc-<agent>-<3 digits>. The agent part is NOT checked against
--  the registry here (that needs the shell); the grammar is enough to make the
--  value safe to hand to tmux.
function valid_session(name)
	if type(name) ~= "string" then return nil end
	if not name:match("^fcc%-[a-z0-9]+%-%d%d%d$") then return nil end
	return name
end

--- Integer within an inclusive range.
function valid_int(v, min, max)
	local n = tonumber(v)
	if not n or n ~= math.floor(n) then return nil end
	if min and n < min then return nil end
	if max and n > max then return nil end
	return n
end

-- There is deliberately no hex validator here. Keystrokes arrive as base64,
-- are decoded to bytes and re-encoded by bytes_to_hex(), so the value handed to
-- `tmux send-keys -H` is never attacker-controlled text. A validator for a
-- value that is only ever produced by our own encoder would be dead code.

--- Install base path. Mirrors fcc_canon_base() in common.sh: absolute, no shell
--  metacharacters, no traversal, and never inside a system directory. The shell
--  re-checks this; here it is so the UI can reject bad input before saving it
--  into UCI.
function valid_install_path(p)
	if type(p) ~= "string" then return nil end
	p = p:gsub("^%s+", ""):gsub("%s+$", "")
	if p == "" or #p > 255 then return nil end
	if not p:match("^/") then return nil end
	if p:match("[%s'\"`%$;&|<>%(%){}%*!%?~]") then return nil end
	p = p:gsub("//+", "/"):gsub("/$", "")
	if p == "" then return nil end
	if p:match("%.%./") or p:match("%.%.$") or p:match("^%.%.") then return nil end
	local system = {
		["/"] = true, ["/proc"] = true, ["/sys"] = true, ["/dev"] = true,
		["/tmp"] = true, ["/var"] = true, ["/etc"] = true, ["/usr"] = true,
		["/bin"] = true, ["/sbin"] = true, ["/lib"] = true, ["/lib64"] = true,
		["/rom"] = true, ["/overlay"] = true, ["/root"] = true,
	}
	if system[p] then return nil end
	for dir in pairs(system) do
		if dir ~= "/" and p:match("^" .. dir:gsub("%-", "%%-") .. "/") then return nil end
	end
	return p
end

--- Bind address: IPv4/IPv6 literal only. Never a hostname, so a typo cannot
--  silently expose the port on a name that resolves to a WAN address.
function valid_bind(b)
	if type(b) ~= "string" then return nil end
	if not b:match("^[0-9a-fA-F:%.]+$") then return nil end
	if #b < 2 or #b > 45 then return nil end
	return b
end

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------

--- Escape a Lua string for embedding in a JSON document.
function json_escape(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub("\"", "\\\"")
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	s = s:gsub("[%z\1-\31]", function(c)
		return string.format("\\u%04x", c:byte())
	end)
	return s
end

--- Encode a Lua value as JSON. Tables with a contiguous 1..n array part encode
--  as arrays, everything else as objects.
function json_encode(v)
	local t = type(v)
	if v == nil then return "null" end
	if t == "boolean" then return v and "true" or "false" end
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if v == math.floor(v) then return string.format("%d", v) end
		return string.format("%.14g", v)
	end
	if t == "string" then return "\"" .. json_escape(v) .. "\"" end
	if t == "table" then
		local is_array = true
		local n = 0
		for k in pairs(v) do
			if type(k) ~= "number" then is_array = false break end
			n = n + 1
		end
		if is_array and n == #v then
			local out = {}
			for i = 1, #v do out[i] = json_encode(v[i]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local out = {}
		for k, val in pairs(v) do
			out[#out + 1] = "\"" .. json_escape(tostring(k)) .. "\":" .. json_encode(val)
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return "null"
end

--- Decode JSON. Uses whichever decoder this LuCI ships; returns nil when the
--  text cannot be parsed. Callers must handle nil.
function json_decode(text)
	if type(text) ~= "string" or text == "" then return nil end
	local ok, jsonc = pcall(require, "luci.jsonc")
	if ok and jsonc and jsonc.parse then
		local res = jsonc.parse(text)
		if res ~= nil then return res end
	end
	local ok2, json = pcall(require, "luci.json")
	if ok2 and json and json.decode then
		local res = json.decode(text)
		if res ~= nil then return res end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Misc
-- ---------------------------------------------------------------------------

--- Trim leading/trailing whitespace.
function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Base64
--
-- Terminal output is a byte stream: it contains ESC sequences, cursor moves and
-- partial UTF-8 sequences. Sending that inside a JSON string would corrupt it
-- (the browser decodes responseText as UTF-8). So every terminal payload is
-- base64-encoded and the browser hands xterm.js a Uint8Array.
-- ---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function base64_encode(data)
	if type(data) ~= "string" then return "" end
	local out = {}
	local n = #data
	for i = 1, n, 3 do
		local a = data:byte(i) or 0
		local b = data:byte(i + 1)
		local c = data:byte(i + 2)
		local v = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1 = math.floor(v / 262144) % 64 + 1
		local c2 = math.floor(v / 4096) % 64 + 1
		local c3 = math.floor(v / 64) % 64 + 1
		local c4 = v % 64 + 1
		out[#out + 1] = B64:sub(c1, c1)
		out[#out + 1] = B64:sub(c2, c2)
		out[#out + 1] = b and B64:sub(c3, c3) or "="
		out[#out + 1] = c and B64:sub(c4, c4) or "="
	end
	return table.concat(out)
end

local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

--- Decode base64 to a byte string. Returns nil on malformed input.
function base64_decode(s)
	if type(s) ~= "string" then return nil end
	if #s > 1048576 then return nil end          -- 1 MB of input is plenty
	if s:find("[^A-Za-z0-9+/=\n\r]") then return nil end
	s = s:gsub("[^A-Za-z0-9+/=]", "")
	local out, buf, bits = {}, 0, 0
	for i = 1, #s do
		local ch = s:sub(i, i)
		if ch == "=" then break end
		local v = B64_INDEX[ch]
		if not v then return nil end
		buf = buf * 64 + v
		bits = bits + 6
		if bits >= 8 then
			bits = bits - 8
			out[#out + 1] = string.char(math.floor(buf / (2 ^ bits)) % 256)
			buf = buf % (2 ^ bits)
		end
	end
	return table.concat(out)
end

--- Encode a byte string as space-separated lowercase hex, for `tmux send-keys -H`.
function bytes_to_hex(data)
	local out = {}
	for i = 1, #data do
		out[#out + 1] = string.format("%02x", data:byte(i))
	end
	return table.concat(out, " ")
end
