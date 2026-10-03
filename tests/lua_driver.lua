-- luci-app-fcc — exercises the Lua modules outside LuCI.
--
-- The modules under luasrc/ are written for the LuCI runtime: they `require
-- "nixio.fs"`, expect a global `uci` cursor and a JSON decoder. None of that
-- exists on a development host, so this driver installs the smallest stubs that
-- let the *pure* logic run: the validators, the JSON writer, the base64 codec
-- and the agent-registry parser.
--
-- It prints one line per check and always exits 0, so tests/test_lua.sh can
-- report every failure through the shared harness rather than only the first.
--
--   ok <name>
--   fail <name>|<detail>

local ROOT = assert(os.getenv("FCC_TEST_ROOT"), "FCC_TEST_ROOT is not set")

-- ---------------------------------------------------------------------------
-- Module resolution
--
-- At install time luasrc/ maps onto /usr/lib/lua/luci/, so luasrc/fcc/util.lua
-- is the module luci.fcc.util. Reproduce that mapping with a searcher rather
-- than restructuring the tree for the test.
-- ---------------------------------------------------------------------------
table.insert(package.loaders, 1, function(name)
	local short = name:match("^luci%.fcc%.([a-z_]+)$")
	if not short then return nil end
	local path = ROOT .. "/luasrc/fcc/" .. short .. ".lua"
	local fh = io.open(path, "r")
	if not fh then return nil end
	local src = fh:read("*a")
	fh:close()
	return assert(loadstring(src, "@" .. path))
end)

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------
local function path_exists(p)
	local fh = io.open(p, "r")
	if fh then fh:close() return true end
	return os.rename(p, p) ~= nil -- true for directories as well as files
end

package.preload["nixio.fs"] = function()
	return { access = function(p) return path_exists(p) or nil end }
end

-- No JSON decoder on a stock host. Leaving luci.jsonc/luci.json unloaded is
-- itself a case worth covering: json_decode() must return nil rather than
-- raising, because the controller treats nil as "could not parse".
package.preload["luci.jsonc"] = nil
package.preload["luci.json"] = nil

local util  = require "luci.fcc.util"
local paths = require "luci.fcc.paths"
local agents = require "luci.fcc.agents"

-- ---------------------------------------------------------------------------
-- Tiny assertion harness
-- ---------------------------------------------------------------------------
local passed, failed = 0, 0

local function check(name, cond, detail)
	if cond then
		passed = passed + 1
		print("ok " .. name)
	else
		failed = failed + 1
		print("fail " .. name .. "|" .. tostring(detail or "assertion failed"))
	end
end

local function eq(name, got, want)
	check(name, got == want, "want [" .. tostring(want) .. "], got [" .. tostring(got) .. "]")
end

-- ---------------------------------------------------------------------------
-- shell_quote
-- ---------------------------------------------------------------------------
eq("shell_quote/plain",      util.shell_quote("abc"), "'abc'")
eq("shell_quote/empty",      util.shell_quote(""), "''")
eq("shell_quote/nil",        util.shell_quote(nil), "''")
eq("shell_quote/space",      util.shell_quote("a b"), "'a b'")
-- The only character that cannot survive inside single quotes.
eq("shell_quote/quote",      util.shell_quote("a'b"), "'a'\\''b'")
eq("shell_quote/injection",  util.shell_quote("; rm -rf /"), "'; rm -rf /'")
eq("shell_quote/dollar",     util.shell_quote("$(id)"), "'$(id)'")

-- ---------------------------------------------------------------------------
-- valid_agent
-- ---------------------------------------------------------------------------
check("valid_agent/accepts_lowercase", util.valid_agent("claude") == "claude")
check("valid_agent/accepts_digits",    util.valid_agent("dsh2") == "dsh2")
check("valid_agent/rejects_upper",     util.valid_agent("Claude") == nil)
check("valid_agent/rejects_dash",      util.valid_agent("a-b") == nil)
check("valid_agent/rejects_empty",     util.valid_agent("") == nil)
check("valid_agent/rejects_nil",       util.valid_agent(nil) == nil)
check("valid_agent/rejects_long",      util.valid_agent(string.rep("a", 17)) == nil)
check("valid_agent/rejects_space",     util.valid_agent("a b") == nil)
check("valid_agent/rejects_slash",     util.valid_agent("../etc") == nil)
check("valid_agent/rejects_number",    util.valid_agent(42) == nil)

-- ---------------------------------------------------------------------------
-- valid_session  (fcc-<agent>-<NNN>)
-- ---------------------------------------------------------------------------
check("valid_session/accepts",         util.valid_session("fcc-claude-001") == "fcc-claude-001")
check("valid_session/accepts_999",     util.valid_session("fcc-dsh-999") == "fcc-dsh-999")
check("valid_session/rejects_2digits", util.valid_session("fcc-claude-01") == nil)
check("valid_session/rejects_4digits", util.valid_session("fcc-claude-0001") == nil)
check("valid_session/rejects_prefix",  util.valid_session("claude-001") == nil)
check("valid_session/rejects_empty_agent", util.valid_session("fcc--001") == nil)
check("valid_session/rejects_injection", util.valid_session("fcc-claude-001; rm -rf /") == nil)
check("valid_session/rejects_dash_agent", util.valid_session("fcc-a-b-001") == nil)
check("valid_session/rejects_nil",     util.valid_session(nil) == nil)

-- ---------------------------------------------------------------------------
-- valid_int
-- ---------------------------------------------------------------------------
check("valid_int/in_range",   util.valid_int("80", 20, 500) == 80)
check("valid_int/at_min",     util.valid_int(20, 20, 500) == 20)
check("valid_int/at_max",     util.valid_int(500, 20, 500) == 500)
check("valid_int/below",      util.valid_int(19, 20, 500) == nil)
check("valid_int/above",      util.valid_int(501, 20, 500) == nil)
check("valid_int/not_number", util.valid_int("80x", 20, 500) == nil)
check("valid_int/float",      util.valid_int("80.5", 20, 500) == nil)
check("valid_int/no_bounds",  util.valid_int("7") == 7)

-- ---------------------------------------------------------------------------
-- valid_install_path — must agree with fcc_canon_base() in common.sh.
-- tests/test_lua.sh cross-checks the two implementations.
-- ---------------------------------------------------------------------------
check("valid_install_path/opt",       util.valid_install_path("/opt") == "/opt")
check("valid_install_path/mnt",       util.valid_install_path("/mnt/sda1") == "/mnt/sda1")
check("valid_install_path/trailing",  util.valid_install_path("/mnt/sda1/") == "/mnt/sda1")
check("valid_install_path/dupeslash", util.valid_install_path("/mnt//sda1") == "/mnt/sda1")
check("valid_install_path/trim",      util.valid_install_path("  /opt  ") == "/opt")
check("valid_install_path/rejects_root",     util.valid_install_path("/") == nil)
check("valid_install_path/rejects_etc",      util.valid_install_path("/etc") == nil)
check("valid_install_path/rejects_etc_sub",  util.valid_install_path("/etc/fcc") == nil)
check("valid_install_path/rejects_usr",      util.valid_install_path("/usr/lib") == nil)
check("valid_install_path/rejects_tmp",      util.valid_install_path("/tmp/fcc") == nil)
check("valid_install_path/rejects_relative", util.valid_install_path("opt/fcc") == nil)
check("valid_install_path/rejects_traversal",util.valid_install_path("/opt/../../etc") == nil)
check("valid_install_path/rejects_empty",    util.valid_install_path("") == nil)
check("valid_install_path/rejects_semicolon",util.valid_install_path("/opt;id") == nil)
check("valid_install_path/rejects_backtick", util.valid_install_path("/opt`id`") == nil)
check("valid_install_path/rejects_dollar",   util.valid_install_path("/opt/$(id)") == nil)
check("valid_install_path/rejects_space",    util.valid_install_path("/op t") == nil)
check("valid_install_path/rejects_glob",     util.valid_install_path("/opt/*") == nil)
check("valid_install_path/rejects_nil",      util.valid_install_path(nil) == nil)
check("valid_install_path/rejects_long",     util.valid_install_path("/" .. string.rep("a", 300)) == nil)

-- ---------------------------------------------------------------------------
-- valid_bind — literals only, never a hostname
-- ---------------------------------------------------------------------------
check("valid_bind/loopback",  util.valid_bind("127.0.0.1") == "127.0.0.1")
check("valid_bind/any4",      util.valid_bind("0.0.0.0") == "0.0.0.0")
check("valid_bind/ipv6",      util.valid_bind("::1") == "::1")
check("valid_bind/rejects_hostname", util.valid_bind("localhost") == nil)
check("valid_bind/rejects_empty",    util.valid_bind("") == nil)
check("valid_bind/rejects_short",    util.valid_bind("1") == nil)
check("valid_bind/rejects_injection",util.valid_bind("127.0.0.1;id") == nil)
check("valid_bind/rejects_nil",      util.valid_bind(nil) == nil)

-- ---------------------------------------------------------------------------
-- json_escape / json_encode
-- ---------------------------------------------------------------------------
eq("json_escape/quote",  util.json_escape('a"b'), 'a\\"b')
eq("json_escape/bslash", util.json_escape("a\\b"), "a\\\\b")
eq("json_escape/newline",util.json_escape("a\nb"), "a\\nb")
eq("json_escape/tab",    util.json_escape("a\tb"), "a\\tb")
eq("json_escape/ctrl",   util.json_escape("a\1b"), "a\\u0001b")

eq("json_encode/nil",    util.json_encode(nil), "null")
eq("json_encode/true",   util.json_encode(true), "true")
eq("json_encode/false",  util.json_encode(false), "false")
eq("json_encode/int",    util.json_encode(42), "42")
eq("json_encode/neg",    util.json_encode(-7), "-7")
eq("json_encode/string", util.json_encode("hi"), '"hi"')
eq("json_encode/array",  util.json_encode({ 1, 2, 3 }), "[1,2,3]")
eq("json_encode/empty_array", util.json_encode({}), "[]")
eq("json_encode/nan",    util.json_encode(0 / 0), "null")
eq("json_encode/inf",    util.json_encode(math.huge), "null")
eq("json_encode/nested", util.json_encode({ { "a" }, { "b" } }), '[["a"],["b"]]')

-- A JSON document that is only ever built by concatenation must escape the
-- characters that would otherwise break out of the string context.
eq("json_encode/injection", util.json_encode('a", "evil": "1'),
	'"a\\", \\"evil\\": \\"1"')

-- ---------------------------------------------------------------------------
-- json_decode must degrade, not raise
-- ---------------------------------------------------------------------------
check("json_decode/no_decoder_returns_nil", util.json_decode('{"a":1}') == nil)
check("json_decode/empty",                  util.json_decode("") == nil)
check("json_decode/nil",                    util.json_decode(nil) == nil)

-- ---------------------------------------------------------------------------
-- trim
-- ---------------------------------------------------------------------------
eq("trim/both",  util.trim("  x  "), "x")
eq("trim/none",  util.trim("x"), "x")
eq("trim/nil",   util.trim(nil), "")
eq("trim/tabs",  util.trim("\t x \n"), "x")

-- ---------------------------------------------------------------------------
-- base64 — terminal payloads are arbitrary bytes, including NUL and 0xFF
-- ---------------------------------------------------------------------------
eq("base64/empty",    util.base64_encode(""), "")
eq("base64/f",        util.base64_encode("f"), "Zg==")
eq("base64/fo",       util.base64_encode("fo"), "Zm8=")
eq("base64/foo",      util.base64_encode("foo"), "Zm9v")
eq("base64/foob",     util.base64_encode("foob"), "Zm9vYg==")
eq("base64/fooba",    util.base64_encode("fooba"), "Zm9vYmE=")
eq("base64/foobar",   util.base64_encode("foobar"), "Zm9vYmFy")
eq("base64/nil",      util.base64_encode(nil), "")

local function roundtrip(s) return util.base64_decode(util.base64_encode(s)) == s end
check("base64/rt_ascii",   roundtrip("hello world"))
check("base64/rt_binary",  roundtrip(string.char(0, 1, 2, 127, 128, 255)))
check("base64/rt_allbytes", (function()
	local t = {}
	for i = 0, 255 do t[#t + 1] = string.char(i) end
	return roundtrip(table.concat(t))
end)())
check("base64/rt_esc",     roundtrip("\27[0m\27[1;32mok\27[0m"))
check("base64/rt_utf8partial", roundtrip("\228\189"))  -- truncated UTF-8

check("base64_decode/rejects_junk",   util.base64_decode("!!!!") == nil)
check("base64_decode/rejects_nil",    util.base64_decode(nil) == nil)
check("base64_decode/accepts_newline",util.base64_decode("Zm9v\nYmFy") == "foobar")

-- ---------------------------------------------------------------------------
-- bytes_to_hex — the exact form `tmux send-keys -H` wants
-- ---------------------------------------------------------------------------
eq("bytes_to_hex/empty", util.bytes_to_hex(""), "")
eq("bytes_to_hex/abc",   util.bytes_to_hex("abc"), "61 62 63")
eq("bytes_to_hex/nl",    util.bytes_to_hex("\r"), "0d")
eq("bytes_to_hex/ctrl-c",util.bytes_to_hex("\3"), "03")
eq("bytes_to_hex/padded",util.bytes_to_hex("\1\2"), "01 02")
eq("bytes_to_hex/high",  util.bytes_to_hex("\255"), "ff")

-- ---------------------------------------------------------------------------
-- spawn_detached
--
-- This carries the fix for "Install / reinstall" answering "could not start the
-- job". OpenWrt's busybox has no `nohup`, so the job never ran — but a shell
-- that cannot exec a command still sets `$!`, so the failure looked like a
-- success. The first attempt at a fix confirmed the pid against /proc, which
-- answered the opposite question ("is it still running?") and got it wrong in
-- the other direction: an install blocked by the compatibility gate exits in
-- under a second, so a job that started and stopped was reported as one that
-- never started, and the reason it wrote to its own log was thrown away.
--
-- The checks below are the three answers that are decidable: the command is
-- there before the fork, the pid names the program that was asked for, and a
-- job that exits at once is still reported as started.
-- ---------------------------------------------------------------------------

-- One field of /proc/<pid>/stat, counted after the command name. The name is
-- in parentheses and may itself contain spaces or parentheses, so the parse
-- starts at the last ')' rather than splitting the whole line.
local function proc_stat_field(pid, n)
	local fh = io.open("/proc/" .. pid .. "/stat", "r")
	if not fh then return nil end
	local rest = (fh:read("*l") or ""):match("%)%s*(.*)$")
	fh:close()
	if not rest then return nil end
	local i = 0
	for field in rest:gmatch("%S+") do
		i = i + 1
		if i == n then return field end
	end
	return nil
end

-- Retry a read until it answers, so an assertion is about the end state rather
-- than about how quickly the kernel reached it.
local function await(fn, tries)
	for _ = 1, (tries or 100) do
		local v = fn()
		if v then return v end
		os.execute("sleep 0.02")
	end
	return nil
end

-- The live case, and the one the UI depends on: the pid must name the program
-- that was asked for, not merely some process that happens to be running.
--
-- It does, and the number does not change — setsid() takes the session and then
-- execs in place. But both happen just after the fork, so reading /proc once
-- catches the process while it is still called `setsid`. That is a fact about
-- how fast Lua reads, not about the job, so the read is retried.
local _sd_log = os.tmpname()
local _sd_pid = util.spawn_detached("/bin/sleep", { "30" }, _sd_log)
check("spawn_detached/returns_a_pid", _sd_pid ~= nil, "got " .. tostring(_sd_pid))

local _sd_comm, _sd_session = nil, nil
if _sd_pid then
	_sd_comm = await(function()
		local c = io.open("/proc/" .. _sd_pid .. "/comm", "r")
		if not c then return nil end
		local s = (c:read("*l") or ""):gsub("%s+$", "")
		c:close()
		return (s ~= "" and s ~= "setsid") and s or nil
	end)
	-- Field 4 after the name: state ppid pgrp session. By the time the exec has
	-- happened setsid() has certainly been called, so this needs no retry.
	_sd_session = tonumber(proc_stat_field(_sd_pid, 4))
	os.execute("kill " .. _sd_pid .. " 2>/dev/null")
end
os.remove(_sd_log)

check("spawn_detached/pid_is_the_program", _sd_comm == "sleep", "got " .. tostring(_sd_comm))

-- The other half of what setsid buys, and the reason it replaced `nohup`: the
-- job is in a session of its own, so it survives the CGI process being reaped.
check("spawn_detached/job_is_in_its_own_session",
	_sd_pid ~= nil and _sd_session == _sd_pid,
	"session " .. tostring(_sd_session) .. " for pid " .. tostring(_sd_pid))

-- The regression that produced the user-visible error, and the reason the
-- /proc confirmation was removed: a job that starts and stops immediately is
-- still a job that started. `/bin/true` is the shortest such job there is, and
-- answering "could not start the job" for it would throw away the log it had
-- already written — which is where an install blocked by the compatibility gate
-- says what blocked it. Deterministic: `echo $!` prints a pid whether or not
-- the job is still there to be found afterwards.
check("spawn_detached/reports_a_job_that_exits_at_once",
	util.spawn_detached("/bin/true", {}, "/dev/null") ~= nil)

-- A command that is not there must be refused, and the answer must be the same
-- on every run. Before the pre-check this returned a pid five times out of
-- five, because the setsid process was still alive when /proc was read.
check("spawn_detached/refuses_a_path_that_is_not_there",
	util.spawn_detached("/nonexistent/fcc-not-here", {}, "/dev/null") == nil)
check("spawn_detached/refuses_a_name_that_is_not_on_path",
	util.spawn_detached("fcc-no-such-applet", {}, "/dev/null") == nil)
check("spawn_detached/refuses_an_empty_command",
	util.spawn_detached("", {}, "/dev/null") == nil)
check("spawn_detached/refuses_a_nil_command",
	util.spawn_detached(nil, {}, "/dev/null") == nil)

-- ---------------------------------------------------------------------------
-- paths
-- ---------------------------------------------------------------------------
check("paths/script_ok",    paths.script("status") == paths.LIBEXEC .. "/status.sh")
check("paths/script_agent", paths.script("agent") == paths.LIBEXEC .. "/agent.sh")
check("paths/script_rejects_digits", paths.script("status1") == nil)
check("paths/script_rejects_slash",  paths.script("../etc/passwd") == nil)
check("paths/script_rejects_space",  paths.script("sta tus") == nil)
check("paths/script_rejects_semicolon", paths.script("status;id") == nil)
check("paths/script_rejects_empty",  paths.script("") == nil)

check("paths/luci_version", paths.luci_version() == "0.1.0")

-- No UCI cursor on this host, so install_base() must fall back to the default
-- rather than returning nil.
check("paths/install_base_fallback", paths.install_base() == "/opt")
check("paths/fcc_root_default",      paths.fcc_root() == "/opt/fcc")
check("paths/sessions_dir",          paths.sessions_dir() == "/opt/fcc/sessions")

-- ---------------------------------------------------------------------------
-- agents — parsed from the real registry, the single source of truth
-- ---------------------------------------------------------------------------
local list = agents.load()
check("agents/count", #list == 10, "expected 10 agents, got " .. #list)

local ids = {}
for _, a in ipairs(list) do ids[#ids + 1] = a.id end
eq("agents/ids", table.concat(ids, ","),
	"claude,codex,pi,opencode,cline,hermes,dsh,grok,muse,aider")

local claude = agents.get("claude")
check("agents/get_claude", claude ~= nil)
eq("agents/claude_name",     claude.name, "Claude Code")
eq("agents/claude_launcher", claude.launcher, "fcc-claude")
eq("agents/claude_probe",    claude.probe, "claude")
check("agents/claude_default", claude.default == true)
eq("agents/claude_size",     claude.size_mb, 140)
eq("agents/claude_ram",      claude.min_ram_mb, 180)

-- hermes has no probe: `hermes --version` hangs, so version detection must not
-- try to run anything for it.
eq("agents/hermes_probe_empty", agents.get("hermes").probe, "")

-- DeepSeek Harness is fcc-dsh. "fcc-deepseek" does not exist upstream.
eq("agents/dsh_launcher", agents.get("dsh").launcher, "fcc-dsh")

-- Every launcher must be an fcc-* console script, and the probe must never be
-- one: an fcc-* name is a launcher that would START the agent.
local bad_launcher, bad_probe = nil, nil
for _, a in ipairs(list) do
	if not a.launcher:match("^fcc%-[a-z]+$") then bad_launcher = a.id end
	if a.probe ~= "" and a.probe:match("^fcc%-") then bad_probe = a.id end
end
check("agents/launchers_are_fcc_prefixed", bad_launcher == nil, bad_launcher)
check("agents/probes_never_are_launchers", bad_probe == nil, bad_probe)

eq("agents/default_ids", table.concat(agents.default_ids(), ","),
	"claude,codex,pi,opencode,hermes,dsh,grok,muse,aider")
check("agents/cline_not_default", agents.get("cline").default == false)

-- Section 3.6.5: the preselected set has to shrink to fit the device. Both
-- budgets are optional and independent, and the registry order is the priority
-- order, so the assertions below are about which agents survive, not just how
-- many.
eq("agents/default_ids_no_budgets", table.concat(agents.default_ids(nil, nil), ","),
	table.concat(agents.default_ids(), ","))
eq("agents/default_ids_generous", table.concat(agents.default_ids(99999, 99999), ","),
	"claude,codex,pi,opencode,hermes,dsh,grok,muse,aider")

-- A 150 MB ceiling drops claude (180), codex (160), opencode (160) and dsh (180).
eq("agents/default_ids_by_ram", table.concat(agents.default_ids(150, nil), ","),
	"pi,hermes,grok,muse,aider")

-- 300 MB of flash holds claude (140) and codex (120) and nothing else: every
-- later agent would push the running total over.
eq("agents/default_ids_by_disk", table.concat(agents.default_ids(nil, 300), ","),
	"claude,codex")

-- Both at once, which is the case that matters on a real router.
eq("agents/default_ids_by_both", table.concat(agents.default_ids(150, 300), ","),
	"pi,hermes,grok")

-- Nothing fits, and that is a real answer: an empty list, not the full set.
eq("agents/default_ids_starved", table.concat(agents.default_ids(0, 0), ","), "")

-- A budget that is not a number is treated as "unknown", never as zero.
eq("agents/default_ids_nan_is_unknown",
	table.concat(agents.default_ids("abc", nil), ","),
	table.concat(agents.default_ids(), ","))

-- Cline is not a default at any budget.
check("agents/default_ids_never_includes_non_defaults",
	not agents.default_ids(99999, 99999)[5] or
	table.concat(agents.default_ids(99999, 99999), ","):find("cline") == nil)

check("agents/exists_yes", agents.exists("codex"))
check("agents/exists_no",  not agents.exists("nosuchagent"))
check("agents/get_rejects_bad_id", agents.get("../../etc") == nil)
check("agents/get_rejects_nil",    agents.get(nil) == nil)

-- ---------------------------------------------------------------------------
-- Total first, then failures: tests/test_lua.sh checks that the total matches
-- the number of ok/fail lines it saw, which catches a check that silently never
-- ran (a raised error mid-file would otherwise look like a short, clean run).
print("RESULT " .. (passed + failed) .. " " .. failed)
os.exit(0)
