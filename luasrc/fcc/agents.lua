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

--- Ids to preselect when installing the runtime.
--
-- Section 3.6.5: the default selection has to account for RAM, flash and how
-- large each agent is, because a low-resource router cannot carry the whole
-- set. The registry's own `default` flag says which agents upstream installs;
-- this narrows that set to what the device can actually hold.
--
-- It narrows it to exactly one. The answer here is a recommendation, and a
-- recommendation is a starting point rather than a shopping list: pre-ticking
-- several agents spends the device's free space on agents the user never asked
-- for, and the agents at the back of the list are the ones a tight device can
-- least afford. So this returns the first agent in registry order that upstream
-- installs by default and that the device can hold — Claude Code on any device
-- that can run it, and the next agent down only when it cannot.
--
-- The two budgets are optional and independent, and neither narrows the answer
-- to nothing on its own: with no budget at all the first default agent is still
-- the answer, because "unknown device" is not "no room".
--
-- Order matters: the registry order is the priority order, so the result is
-- deterministic and does not depend on which budget was supplied.
function default_ids(ram_mb, free_mb)
	local ram  = tonumber(ram_mb)
	local free = tonumber(free_mb)
	for _, a in ipairs(load()) do
		if a.default then
			-- A 0 in the registry means "not known", not "needs nothing", so it
			-- is never what excludes an agent.
			local fits_ram = (ram == nil) or (a.min_ram_mb == 0) or (a.min_ram_mb <= ram)
			local fits_disk = (free == nil) or (a.size_mb <= free)
			if fits_ram and fits_disk then
				return { a.id }
			end
		end
	end
	-- Nothing fits, and that is a real answer: an empty list, not the full set.
	return {}
end

--- Is this id in the registry?
function exists(id)
	return get(id) ~= nil
end
