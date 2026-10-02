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

--- Start a long-running command detached from this request.
--
-- Installing or updating the FCC runtime downloads and builds for minutes —
-- far longer than an HTTP request may live. The work is therefore started in
-- the background with its output appended to a log file, and the UI polls the
-- log and the install lock. Both the child's stdout/stderr and the wrapper
-- shell's are redirected, so io.popen() does not block waiting on the pipe.
--
-- @return pid (number) on success, nil on failure
function spawn_detached(cmd, args, logfile)
	local parts = { shell_quote(cmd) }
	for _, a in ipairs(args or {}) do
		parts[#parts + 1] = shell_quote(a)
	end
	local log = shell_quote(logfile or "/dev/null")
	local line = "nohup " .. table.concat(parts, " ") ..
		" >> " .. log .. " 2>&1 < /dev/null & echo $!"
	local fh = io.popen(line)
	if not fh then return nil end
	local pid = tonumber((fh:read("*a") or ""):match("%d+"))
	fh:close()
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
