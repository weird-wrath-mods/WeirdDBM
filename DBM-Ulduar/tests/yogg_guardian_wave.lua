-- Replays logged Yogg-Saron phase 1 pulls through the real YoggSaron.lua and checks that the
-- "Guardian" bar is on each scheduled spawn. Run: luajit DBM-Ulduar/tests/yogg_guardian_wave.lua
--
-- The server side (boss_yoggsaron.cpp, Spell.dbc) is explained next to guardianWave() in the mod.
-- What this guards: the mod anchors on the pull yell, which reaches the client with a different
-- latency than the combat log. Wave 2's tick lands within ~0.1s of one of Sara's cast starts on
-- every pull, so if that offset decides the stall the bar is ~4s off from wave 2 on and never
-- recovers (23 Sep 2026 raid). Every pull is therefore replayed across a range of yell offsets.
--
-- Times are seconds from the pull, anchored on Sara's first cast, which the script puts at
-- exactly pull+15. Player-triggered cloud spawns (:1120) are in the data on purpose: they must
-- neither get a bar nor pull the chain off.

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local MOD = dir .. "/../YoggSaron.lua"
local TOL = 0.25--log timestamps and event ordering; the server's own update tick is ~0.1s

local datasets = {
	["21 Sep"] = {clouds = 8, pulls = {
		{casts = {15.0, 19.91, 24.83, 29.74, 34.66, 39.57, 44.49, 54.31, 59.24, 64.23, 69.16, 74.11, 78.97, 83.88, 88.79, 93.69, 98.6, 103.53, 108.45, 113.36, 118.29, 123.27, 128.21, 133.15, 138.05, 143.06},
		 spawns = {10.15, 33.95, 53.62, 73.35, 88.09, 102.81, 112.85, 113.67, 122.88, 123.68, 132.93, 137.57, 139.85, 141.95, 142.97, 147.57}},
		{casts = {15.0, 19.94, 24.83, 34.66, 39.58, 44.56, 54.38, 59.29, 64.21, 74.01, 78.96, 83.95, 88.86, 93.77, 98.79, 103.7, 108.69, 113.59, 118.51, 123.43, 128.46, 133.36, 138.28},
		 spawns = {10.06, 33.94, 53.67, 73.32, 88.05, 102.89, 112.91, 122.92, 132.93, 143.01, 143.01}},
		{casts = {15.0, 19.93, 24.84, 29.75, 34.67, 39.66, 44.57, 49.47, 54.39, 59.29, 64.21, 74.07, 78.97, 83.88, 88.88, 93.8, 98.8, 103.81, 108.8, 113.81, 118.81, 123.83, 128.82},
		 spawns = {9.91, 33.88, 53.63, 73.26, 88.08, 89.27, 102.79, 112.97, 122.82, 132.83}},
		{casts = {15.0, 19.99, 29.82, 34.82, 39.73, 44.65, 49.54, 54.44, 59.36, 64.27, 69.17, 74.09, 79.09, 88.92, 93.91, 98.88, 103.74, 108.75, 113.74, 118.65, 123.59, 128.56},
		 spawns = {9.98, 34.02, 53.76, 73.38, 88.2, 103.03, 113.04, 123.11, 133.07}},
	}},
	["23 Sep"] = {clouds = 3, pulls = {
		{casts = {15.000, 19.973, 34.778, 39.756, 44.665, 49.663, 54.578, 59.600, 64.582, 69.493, 74.392, 79.296, 84.208, 89.218, 94.124, 99.106, 104.021, 108.938, 113.849, 118.766},
		 spawns = {10.113, 33.936, 46.049, 53.779, 73.588, 75.908, 88.421, 89.824, 103.123, 113.138, 123.179}},
		{casts = {15.000, 19.912, 29.741, 34.715, 39.632, 44.541, 49.440, 54.356, 59.260, 64.250, 69.217, 74.183, 79.091, 84.013, 89.002, 93.922, 98.820, 103.714, 108.630, 113.544, 118.452, 123.446, 128.369, 133.274},
		 spawns = {9.887, 33.813, 53.544, 73.213, 88.100, 102.919, 112.958, 122.959, 133.082}},
		{casts = {15.000, 19.916, 34.647, 39.649, 44.541, 49.453, 54.447, 59.345, 64.275, 69.190, 74.176, 79.096, 84.008, 89.000, 93.919, 98.812, 103.733, 108.633, 113.564, 118.469, 123.379, 128.305, 133.298},
		 spawns = {9.991, 33.833, 53.549, 73.279, 88.105, 102.938, 112.935, 122.979, 133.005}},
		{casts = {15.000, 19.915, 24.911, 34.733, 39.655, 44.606, 49.660, 54.471, 59.374, 64.398, 74.220, 79.204, 84.123, 89.030, 93.936, 98.842, 103.760, 108.753, 113.682, 118.642, 123.627, 128.550, 133.458},
		 spawns = {9.895, 33.824, 53.575, 73.409, 88.119, 102.963, 113.066, 123.129, 133.162}},
		{casts = {15.000, 19.928, 24.841, 34.743, 39.660, 44.592, 49.592, 54.592, 59.485, 64.391, 69.338, 74.205, 79.130, 84.123, 89.027, 93.958, 98.946, 103.866, 108.858, 113.751, 118.691, 123.601, 128.605, 133.591},
		 spawns = {9.864, 33.929, 53.594, 73.423, 88.129, 102.956, 112.977, 122.977, 132.983}},
	}},
}

-- Minimal DBM: a fake clock, a scheduler, and timers that record where their bar ends.
-- Anything else the mod touches is a no-op proxy.
local now = 0
GetTime = function() return now end
local P; P = setmetatable({}, {__index = function() return function() return P end end, __call = function() return P end})
local noop = {__index = function() return function() return P end end}
local keyname = {__index = function(_, k) return k end}
local bars, sched = {}, {}
local mod = setmetatable({vb = {}, Options = {}}, noop)
function mod:NewTimer(_, name)
	return setmetatable({
		Start = function(_, d) if d then bars[name] = now + d end end,
		AddTime = function(_, d) if bars[name] then bars[name] = bars[name] + d end end,
		Stop = function() bars[name] = nil end,
	}, noop)
end
function mod:Schedule(d, f, ...) sched[#sched + 1] = {t = now + d, f = f, a = {...}} end
function mod:Unschedule(f) for i = #sched, 1, -1 do if sched[i].f == f then table.remove(sched, i) end end end
function mod:SetStage(s) self.vb.phase = s end
function mod:GetLocalizedStrings() return setmetatable({}, keyname) end
DBM = setmetatable({NewMod = function() return mod end}, noop)
DBM_COMMON_L = setmetatable({}, keyname)
DBM_CORE_L = DBM_COMMON_L
table.wipe = table.wipe or function(t) for k in pairs(t) do t[k] = nil end end
dofile(MOD)

local function advance(t)
	while true do
		table.sort(sched, function(a, b) return a.t < b.t end)
		local s = sched[1]
		if not s or s.t > t then break end
		table.remove(sched, 1)
		now = s.t
		s.f(unpack(s.a))
	end
	now = t
end

local castArgs = setmetatable({spellId = 63138, sourceName = "Sara"}, {__index = function() return function() return false end end})

-- Returns the bar error at each spawn, bar end minus spawn time. offset shifts the combat log
-- against the yell that starts combat.
local function replay(pull, offset)
	local events = {}
	for _, t in ipairs(pull.casts) do events[#events + 1] = {t = t + offset} end
	for _, t in ipairs(pull.spawns) do events[#events + 1] = {t = t + offset, spawn = true} end
	table.sort(events, function(a, b) return a.t < b.t end)
	now, sched, bars, mod.vb = 0, {}, {}, {}
	mod:OnCombatStart()
	local errs = {}
	for _, e in ipairs(events) do
		advance(e.t)
		if e.spawn then
			errs[#errs + 1] = bars.NextGuardian and bars.NextGuardian - e.t or math.huge
			mod:SPELL_SUMMON({spellId = 62979})
		else
			mod:SPELL_CAST_START(castArgs)
		end
	end
	return errs
end

local checked = 0
for name, set in pairs(datasets) do
	for _, offset in ipairs({-0.5, -0.3, -0.1, 0, 0.1, 0.3, 0.5, 1, 2}) do
		local clouds = 0
		for i, pull in ipairs(set.pulls) do
			local errs = replay(pull, offset)
			-- Wave 1's bar runs from the yell, so it carries the offset; everything after must not.
			for w = 2, #errs do
				if math.abs(errs[w]) > TOL then
					-- A cloud spawn gets no bar of its own and must leave the chain alone, so the bar
					-- it saw is still pointing at a later scheduled wave.
					assert(errs[w] > TOL, ("%s pull %d offset %+.1f: bar ran out %.2fs before spawn %d")
						:format(name, i, offset, -errs[w], w))
					clouds = clouds + 1
				end
				checked = checked + 1
			end
		end
		assert(clouds == set.clouds, ("%s offset %+.1f: %d spawns off the bar, expected %d cloud spawns")
			:format(name, offset, clouds, set.clouds))
	end
end
print(("yogg_guardian_wave: ok (%d spawns checked against the real mod across 9 yell offsets)"):format(checked))
