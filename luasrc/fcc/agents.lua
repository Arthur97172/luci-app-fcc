-- luci-app-fcc — the agent registry, read from the single source of truth.
--
-- root/usr/share/luci-app-fcc/agents.conf is shared by the shell backend, the
-- Lua UI and the tests. Nothing here hardcodes an agent list: adding an agent
-- is a one-line change to that file (DESIGN_SPEC.md section 12).
--
-- Format: id|Friendly Name|launcher|default_install|approx_size_mb|min_ram_mb|probe

module("luci.fcc.agents", package.seeall)

local util  = require "luci.fcc.util"
local paths = require "luci.fcc.paths"

--- Parse the registry.
-- @return array of { id, name, launcher, default, size_mb, min_ram_mb, probe }
function load()
	local raw = util.read_file(paths.AGENTS_CONF)
	local list = {}
	if not raw then return list end
	for line in raw:gmatch("[^\n]+") do
		if not line:match("^%s*#") and not line:match("^%s*$") then
			local f = {}
			for part in (line .. "|"):gmatch("([^|]*)|") do
				f[#f + 1] = util.trim(part)
			end
			if f[1] and f[1] ~= "" and f[1]:match("^[a-z0-9]+$") then
				list[#list + 1] = {
					id         = f[1],
					name       = f[2] or f[1],
					launcher   = f[3] or ("fcc-" .. f[1]),
					default    = (f[4] == "1"),
					size_mb    = tonumber(f[5]) or 0,
					min_ram_mb = tonumber(f[6]) or 0,
					probe      = f[7] or "",
				}
			end
		end
	end
	return list
end

--- Look one agent up by id.
function get(id)
	if not util.valid_agent(id) then return nil end
	for _, a in ipairs(load()) do
		if a.id == id then return a end
	end
	return nil
end

--- Ids of the agents the upstream installer installs by default.
function default_ids()
	local ids = {}
	for _, a in ipairs(load()) do
		if a.default then ids[#ids + 1] = a.id end
	end
	return ids
end

--- Is this id in the registry?
function exists(id)
	return get(id) ~= nil
end
