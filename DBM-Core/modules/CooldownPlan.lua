-- Cooldown rotation for a boss: the raid leader pastes a plan (one row per use, timed from the pull) and
-- sends it; in the fight every client shows the plan on a timeline strip and a personal card, warns the player whose use is next,
-- and says when a use won't be ready (dead, offline, still on cooldown). Each client works out the buff
-- length and cooldown of its own CDs from its talents, glyphs and set pieces (CooldownData.lua) and reports
-- them; a CD the data doesn't know is measured the first time it's used.
-- Plan rows: time, player, cooldown, [duration], [target], [notes], split by tabs, commas or 2+ spaces.
-- A last row repeating the first row's player and cooldown, with "loop" in its notes, makes the plan repeat
-- from there; without one the plan is the whole fight, which is what Generate writes.

local _, private = ...
local CP = {}
local data, trinkets = private.cooldownData, private.cooldownTrinkets

local PREFIX = "DBMCD"
local CHECKAHEAD = 5	-- seconds before a use that its readiness is checked

local defaultByName, roleByName, raidByName, trinketByName, smashOnlyByName, notSelfByName = {}, {}, {}, {}, {}, {}	-- by localized cast name, filled at load

-- [cast spell] = {dur, cd, power} for what this player has, given has.knows(cast), has.talent(first rank
-- spell) -> rank, has.glyph(spell), has.pieces(items) -> equipped count, has.defense() and
-- has.mainTreeHas(talent spell): is that talent in the tree with most points. Flat mods add,
-- percent mods then scale, the order the server applies spell mods in. power is % damage reduction.
function CP.Compute(has)
	local out = {}
	for cast, c in pairs(data) do
		if has.knows(cast) and (not c.needs or has.talent(c.needs) > 0) and (not c.needsGlyph or has.glyph(c.needsGlyph))
			and not (c.notInTreeOf and has.mainTreeHas and has.mainTreeHas(c.notInTreeOf)) then
			local flat, pct = {dur = 0, cd = 0, power = 0}, {dur = 0, cd = 0, power = 0}
			for _, m in ipairs(c.mods) do
				local on
				if m.talent then
					on = has.talent(m.talent) == m.rank
				elseif m.glyph then
					on = has.glyph(m.glyph)
				else
					for _, set in ipairs(m.sets) do
						if has.pieces(set.items) >= set.pieces then on = true end
					end
				end
				if on then
					if m.flat then flat[m.field] = flat[m.field] + m.flat else pct[m.field] = pct[m.field] + m.pct end
				end
			end
			local power = (c.power + flat.power) * (1 + pct.power / 100)
			if c.perDefense then -- Icebound Fortitude: more with defense, at least the glyph's amount
				power = power + math.max(0, (has.defense and has.defense() or 400) - 400) * c.perDefense
				if has.glyph(c.floorGlyph) then power = math.max(power, c.floor) end
			end
			out[cast] = {
				dur = (c.dur + flat.dur) * (1 + pct.dur / 100),
				cd = (c.cd + flat.cd) * (1 + pct.cd / 100),
				power = math.floor(power + 0.5),
			}
		end
	end
	return out
end

local function trim(s) return s:match("^%s*(.-)%s*$") end

function CP.Parse(text)
	local rows, errors = {}, {}
	local n = 0
	for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
		n = n + 1
		local line = raw:gsub("\r", "")
		local sep = line:find("\t") and "\t" or line:find(",") and "," or "  +"
		local f = {}
		for field in (line:gsub(sep, "\1") .. "\1"):gmatch("([^\1]*)\1") do f[#f + 1] = trim(field) end
		local t = tonumber(f[1])
		if t then
			if (f[2] or "") == "" or (f[3] or "") == "" then
				errors[#errors + 1] = ("line %d: needs time, player, cooldown"):format(n)
			else
				rows[#rows + 1] = {
					time = t, player = f[2], spell = f[3], dur = tonumber(f[4]),
					target = f[5] ~= "" and f[5] or nil, note = f[6] ~= "" and f[6] or nil,
				}
			end
		end -- anything else is a header, a comment or blank
	end
	table.sort(rows, function(a, b) return a.time < b.time end)
	local first, last = rows[1], rows[#rows]
	local period
	if #rows > 1 and last.player == first.player and last.spell == first.spell and last.time > first.time
		and last.note and last.note:lower():find("loop") then
		period = last.time - first.time
		rows[#rows] = nil
	end
	return {rows = rows, period = period}, errors
end

-- [player][spell] = {dur = s, cd = s, readyAt = GetTime()} as reported by each player;
-- [player][spell] = GetTime() of their last use seen in the combat log
local reported, lastUsed = {}, {}
CP.reported, CP.lastUsed = reported, lastUsed

function CP.Info(player, spell)
	local r = reported[player] and reported[player][spell]
	local d = defaultByName[spell]
	return (r and r.dur) or (d and d[1]), (r and r.cd) or (d and d[2])
end

local function rowDuration(row)
	return row.dur or CP.Info(row.player, row.spell) or 0
end

-- what's wrong with a plan given what players reported: CDs reused too soon, uncovered time, durations
-- that don't match the player's real one
function CP.Check(plan)
	local issues, rows, period = {}, plan.rows, plan.period
	local uses = {}
	for _, row in ipairs(rows) do
		local key = row.player .. "\0" .. row.spell
		uses[key] = uses[key] or {}
		table.insert(uses[key], row)
	end
	for _, list in pairs(uses) do
		local _, cd = CP.Info(list[1].player, list[1].spell)
		if cd then
			for i, row in ipairs(list) do
				local nextTime = list[i + 1] and list[i + 1].time or (period and list[1].time + period)
				if nextTime and nextTime - row.time < cd then
					issues[#issues + 1] = ("%s's %s at %gs is used again at %gs, back at %gs (%gs cooldown)"):format(row.player, row.spell, row.time, nextTime, row.time + cd, cd)
				end
			end
		end
	end
	for _, row in ipairs(rows) do
		local dur = CP.Info(row.player, row.spell)
		local r = reported[row.player] and reported[row.player][row.spell]
		if row.dur and r and r.dur and math.abs(r.dur - row.dur) > 0.5 then
			issues[#issues + 1] = ("%s's %s lasts %gs, plan says %gs"):format(row.player, row.spell, r.dur, row.dur)
		elseif not row.dur and not dur then
			issues[#issues + 1] = ("%s's %s: no duration known, add one to the row"):format(row.player, row.spell)
		end
	end
	if #rows > 0 then
		local stop = period and rows[1].time + period or rows[#rows].time + rowDuration(rows[#rows])
		local covered = rows[1].time
		for _, row in ipairs(rows) do
			if row.time > covered + 0.5 then
				issues[#issues + 1] = ("nothing up from %gs to %gs"):format(covered, row.time)
			end
			covered = math.max(covered, row.time + rowDuration(row))
		end
		if covered < stop - 0.5 then
			issues[#issues + 1] = ("nothing up from %gs to %gs"):format(covered, stop)
		end
	end
	return issues
end

-- Algalon's fight, in seconds from the end of the roleplay (boss_algalon_the_observer.cpp, JustEngagedWith
-- and UpdateAI): Phase Punch every 15.5s from 15.5, Cosmic Smash cast every 25.5s from 26 and landing 4s
-- later, Big Bang every 90.5s from 90. Big Bang's DelayEventsToMax(11s, GROUP_COMBAT) moves any punch or
-- smash due within 11s of it to exactly 11s after it, and their cadence carries on from there.
local PUNCH, SMASH, BANG, BANG_HOLD, SMASH_LANDS = 15.5, 25.5, 90.5, 11, 4
local FIGHT = 360	-- Ascend to the Heavens
local STACKS = 4	-- a tank takes 4 punches, then the other taunts
local SWAP_DELAY = 4	-- ...this long after the 4th, leaving time to taunt again on a miss before the 5th
local SWAP_LEAD = 1	-- the incoming tank's big cooldown goes up this long before they taunt; a "Tank swap" row is that press
local SMASH_CLEAR = 4	-- a swap with a smash landing from the press to this long after the taunt waits up to this much longer,
local RETRY_ROOM = 9	-- but always leaving this long before the next punch: a taunt's 8s cooldown and a second to retry a miss
-- no new cooldown on the outgoing tank this close to their swap, or after it: even the shortest would be mostly wasted
local SWAP_QUIET = 4

local punches, smashCasts = {}, {}
do
	local nextPunch, nextSmash, nextBang = 15.5, 26, 90
	while true do
		local t = math.min(nextPunch, nextSmash, nextBang)
		if t >= FIGHT then break end
		if t == nextBang then
			if nextPunch < t + BANG_HOLD then nextPunch = t + BANG_HOLD end
			if nextSmash < t + BANG_HOLD then nextSmash = t + BANG_HOLD end
			nextBang = t + BANG
		elseif t == nextPunch then
			punches[#punches + 1] = t
			nextPunch = t + PUNCH
		else
			smashCasts[#smashCasts + 1] = t
			nextSmash = t + SMASH
		end
	end
end
CP.punches = punches

-- a swap SWAP_DELAY after the i-th punch, held when a smash lands around it
local function swapAfter(i)
	local t = punches[i] + SWAP_DELAY
	local room = (punches[i + 1] or FIGHT) - RETRY_ROOM - t
	for _, c in ipairs(smashCasts) do
		local lands = c + SMASH_LANDS
		if lands > t - SWAP_LEAD and lands <= t + SMASH_CLEAR then return t + math.max(0, math.min(SMASH_CLEAR, room)) end
	end
	return t
end

-- expected swaps after fight time from: after every 4th punch, or, given the stacks the tank with the boss
-- has now, after the punch that takes them to 4 (after a death the cadence from the pull is gone)
function CP.SwapTimes(from, stop, stacks)
	local out, i = {}, nil
	if stacks then
		if stacks >= STACKS then out[1] = from end
		local n = 0	-- punches so far
		while punches[n + 1] and punches[n + 1] <= from do n = n + 1 end
		i = n + math.max(STACKS - stacks, 0) + (stacks >= STACKS and STACKS or 0)
	else
		i = STACKS
	end
	while punches[i] and swapAfter(i) < stop do
		if swapAfter(i) > from or stacks then out[#out + 1] = swapAfter(i) end
		i = i + STACKS
	end
	return out
end

-- when each Cosmic Smash lands
function CP.SmashTimes(from, stop)
	local out = {}
	for _, c in ipairs(smashCasts) do
		local t = c + SMASH_LANDS
		if t >= from and t < stop then out[#out + 1] = t end
	end
	return out
end

local function round(t) return math.floor(t * 2 + 0.5) / 2 end

-- a raid-wide cooldown goes up this long before the smash lands: mid-buff for the 6s ones, so a press up to 3s
-- off still covers it. Divine Guardian also covers the tank, so it only goes that early where the tank isn't
-- already covered, and otherwise as early as it can without overlapping that cover, but never later than RAID_LEAD_MIN.
local RAID_LEAD, RAID_LEAD_MIN = 3, 1
local PLAYER_GAP = 10	-- least time between two planned presses by one player: time to read the card and press. Free on the usual roster; 12s costs a thinner roster a smash
local GAP_OK = 1	-- a hole this short before a planned cooldown isn't worth spending another on

-- A plan for the rest of the fight from fight time opts.from, as rows like CP.Parse's.
-- opts.pool: {player, spell, dur, cd, readyAt (fight time), role = "big"|"self"|"ext", raid} per cooldown;
-- opts.tanks: the two tanks, opts.tank: which of them has the boss at opts.from (default 1);
-- opts.covered: [tank] = fight time their current cooldown runs to (default from);
-- opts.used: [pool index] = fight times it was already used (so it isn't planned again too soon);
-- opts.swaps: expected swap times (default CP.SwapTimes); opts.stop (default FIGHT);
-- opts.weaker: the tank to fill first, so the shared externals go to them before the stronger tank.
-- In order: each tank's big cooldown at the pull and at each swap-in; raid-wide cooldowns on Cosmic
-- Smash; the rest of each tank's time filled with real cooldowns, the tank's own before shared ones, unused
-- longest first; then trinkets, too weak to count as cover, into their owner's holes and next to their owner's
-- weakest cooldowns. Returns rows, problems, score.
local function build(opts, rng)
	local from, stop = opts.from or 0, opts.stop or FIGHT
	local swaps = opts.swaps or CP.SwapTimes(from, stop)
	local tanks, tank = opts.tanks, opts.tank or 1
	local covered = opts.covered or {}
	local pool = opts.pool
	local rows, problems, uncovered, holes = {}, {}, 0, {}
	local bigMissed, smashMissed = 0, 0
	local uses = {}	-- [i] = fight times planned or used
	local trinketByPool, bigByPool = {}, {}
	for _, c in ipairs(pool) do
		if c.trinket then trinketByPool[c.player .. "\0" .. c.spell] = true end
		if c.role == "big" then bigByPool[c.player .. "\0" .. c.spell] = true end
	end
	for i in ipairs(pool) do
		uses[i] = {}
		for _, t in ipairs(opts.used and opts.used[i] or {}) do uses[i][#uses[i] + 1] = t end
	end

	local gap = opts.playerGap or PLAYER_GAP
	local function free(i, t)
		local c = pool[i]
		if (c.readyAt or 0) > t then return false end
		for _, u in ipairs(uses[i]) do
			if math.abs(t - u) < c.cd then return false end
		end
		-- nobody gets two presses closer than gap (a trinket goes up with a cooldown, so it doesn't count)
		if gap > 0 and not c.trinket then
			for j, o in ipairs(pool) do
				if j ~= i and o.player == c.player and not o.trinket then
					for _, u in ipairs(uses[j]) do
						if math.abs(t - u) < gap then return false end
					end
				end
			end
		end
		return true
	end
	-- the first time from t on that i is free (nil past stop)
	local function nextFree(i, t)
		t = math.max(t, pool[i].readyAt or 0)
		for _ = 1, #uses[i] + 1 do
			local moved
			for _, u in ipairs(uses[i]) do
				if math.abs(t - u) < pool[i].cd then t, moved = u + pool[i].cd, true end
			end
			if not moved then return t < stop and t or nil end
		end
	end
	local fixed = {}	-- [who] = {{from, to}} already covered
	local function use(i, t, who, note)
		local c = pool[i]
		if c.smashOnly then who = nil end -- the raid's, not the tank's
		rows[#rows + 1] = {time = round(t), player = c.player, spell = c.spell, dur = c.dur, target = who, note = note, power = c.power}
		table.insert(uses[i], t)
		if who then
			fixed[who] = fixed[who] or {}
			table.insert(fixed[who], {t, t + c.dur})
		end
	end
	local function usable(c, who)
		if c.role == "ext" then return not (c.notSelf and c.player == who) end -- Hand of Sacrifice can't go on its caster
		return c.player == who
	end

	-- who has the boss when
	local starts = {from}
	for _, t in ipairs(swaps) do starts[#starts + 1] = t end
	local function holder(s) return tanks[(tank + s - 2) % #tanks + 1] end
	local function holderAt(t)
		local s = 1
		while starts[s + 1] and starts[s + 1] <= t do s = s + 1 end
		return holder(s)
	end
	-- a trinket is only worth pressing if at least half of it lands while its owner has the boss
	local function worthIt(c, t)
		local held = 0
		for x = t, t + c.dur - 0.5, 0.5 do
			if holderAt(x) == c.player then held = held + 0.5 end
		end
		return held >= c.dur / 2
	end

	-- 0: uses carried over as they are from the plan being repaired (CP.Replan's opts.keep)
	local keptSwap, keptRaid = {}, {}
	for _, r in ipairs(opts.keep or {}) do
		for i, c in ipairs(pool) do
			if c.player == r.player and c.spell == r.spell then
				use(i, r.time, r.target, r.note)
				if c.role == "big" then keptSwap[#keptSwap + 1] = r end -- the pull's or a swap's
				if c.raid then keptRaid[#keptRaid + 1] = {r.time, r.time + c.dur} end
				break
			end
		end
	end

	-- 1: the pull and every swap-in get the incoming tank's big cooldown, else the longest one ready
	for s, at in ipairs(starts) do
		local press = s > 1 and at - SWAP_LEAD or at
		local kept = false
		for _, r in ipairs(keptSwap) do
			if r.target == holder(s) and math.abs(r.time - press) <= 1 then kept = true end
		end
		if not kept and (s > 1 or (from == 0 and (covered[holder(s)] or 0) <= 0)) then
			local who, pick = holder(s)
			for i, c in ipairs(pool) do
				if c.role == "big" and c.player == who and free(i, press) then pick = i break end
			end
			if not pick then
				for i, c in ipairs(pool) do
					if usable(c, who) and not c.raid and free(i, press) and (not pick or c.dur > pool[pick].dur) then pick = i end
				end
				problems[#problems + 1] = ("%s has no big cooldown ready at %s"):format(who, s > 1 and ("the swap at " .. round(at) .. "s") or "the pull")
				bigMissed = bigMissed + 1
			end
			if pick then use(pick, press, who, s > 1 and "Tank swap" or nil) end
		end
	end
	-- 2: raid-wide cooldowns on Cosmic Smash, whichever has waited longest; fire-only ones (Aura Mastery) first,
	-- since they do nothing for the tank, and Divine Guardian (which also covers the tank) only where none is free
	for _, hit in ipairs(CP.SmashTimes(from + RAID_LEAD_MIN, stop)) do
		local latest, pick = hit - RAID_LEAD_MIN
		for _, k in ipairs(keptRaid) do
			if k[1] <= hit and k[2] > hit then latest = -math.huge end -- already has one
		end
		local pickKey
		for i, c in ipairs(pool) do
			if c.raid and free(i, latest) then
				local k = rng and rng() or nextFree(i, 0) or 0 -- a variation tries them in any order
				if not pick or (not pool[pick].smashOnly and c.smashOnly) or (not c.smashOnly == not pool[pick].smashOnly and k < pickKey) then
					pick, pickKey = i, k
				end
			end
		end
		if not pick and latest > -math.huge then smashMissed = smashMissed + 1 end
		if pick then
			local who, at = holderAt(hit), math.max(hit - RAID_LEAD, from)
			if not pool[pick].smashOnly then
				local moved = true
				while moved do -- past every bit of cover the tank already has in the early seconds
					moved = false
					for _, f in ipairs(fixed[who] or {}) do
						if f[1] < latest and f[2] > at and at < latest then at, moved = math.min(latest, f[2]), true end
					end
				end
			end
			while at < latest and not free(pick, at) do at = at + 0.5 end
			use(pick, at, who, "Cosmic Smash")
		end
	end
	-- 3: the rest of each tank's time, the weaker tank's stints first
	local order = {}
	for s in ipairs(starts) do if holder(s) == opts.weaker then order[#order + 1] = s end end
	for s in ipairs(starts) do if holder(s) ~= opts.weaker then order[#order + 1] = s end end
	for _, s in ipairs(order) do
		local segStart = starts[s]
		local who, swapAt = holder(s), starts[s + 1]
		local segEnd = math.min(swapAt or stop, stop)
		local c = math.max(segStart, covered[who] or segStart)
		while c < segEnd do
			local inFixed, nextFixed
			for _, f in ipairs(fixed[who] or {}) do
				if f[1] <= c + 0.01 and f[2] > c then inFixed = math.max(inFixed or 0, f[2]) end
				if f[1] > c and (not nextFixed or f[1] < nextFixed) then nextFixed = f[1] end
			end
			if inFixed then
				c = inFixed
			elseif nextFixed and nextFixed - c <= GAP_OK then
				c = nextFixed
			elseif swapAt and c >= swapAt - SWAP_QUIET then
				local last = holes[#holes]
				if last and last[1] == who and last[3] == c then last[3] = segEnd else holes[#holes + 1] = {who, c, segEnd} end
				break
			else
				local pick, pickIdle, pickRank, soonest
				for i, cd in ipairs(pool) do
					if cd.role ~= "big" and not cd.smashOnly and not cd.trinket and usable(cd, who) then
						if free(i, c) then
							local last = -math.huge
							for _, u in ipairs(uses[i]) do if u < c and u > last then last = u end end
							local idle = rng and rng() or c - last -- a variation tries them in any order
							-- raid-wide ones are kept for smashes unless nothing else is up; then the tank's own before
							-- shared ones, which the other tank could have used
							local rank = cd.raid and 2 or cd.role == "ext" and 1 or 0
							if rng and rng() < 0.3 then rank = 0 end -- a variation sometimes spends what it'd normally save
							if not pick or rank < pickRank or (rank == pickRank
								and (idle > pickIdle or (idle == pickIdle and cd.dur > pool[pick].dur))) then
								pick, pickIdle, pickRank = i, idle, rank
							end
						else
							local t = nextFree(i, c)
							if t and (not soonest or t < soonest) then soonest = t end
						end
					end
				end
				if pick then
					use(pick, c, who)
					c = c + pool[pick].dur
				else
					-- at least half a second on: the soonest free time ignores the player gap, so it can land on c itself
					local til = math.max(c + 0.5, math.min(soonest or segEnd, nextFixed or segEnd, swapAt or segEnd))
					local last = holes[#holes]
					if last and last[1] == who and last[3] == c then last[3] = til else holes[#holes + 1] = {who, c, til} end
					c = til
				end
			end
		end
	end
	-- 4: trinkets (weak, ~10%) aren't cover on their own: first into their owner's holes, longest first, since
	-- something beats nothing, then up with their owner's weakest cooldowns
	table.sort(holes, function(a, b) return a[3] - a[2] > b[3] - b[2] end)
	for i, c in ipairs(pool) do
		if c.trinket then
			for _, h in ipairs(holes) do
				if h[1] == c.player and free(i, h[2]) and worthIt(c, h[2]) then use(i, h[2], c.player) end
			end
		end
	end
	local trinketOnly = 0
	table.sort(holes, function(a, b) return a[2] < b[2] end)
	for _, h in ipairs(holes) do
		local c = h[2]
		for _, r in ipairs(rows) do -- what a trinket covers of the hole
			if r.target == h[1] and trinketByPool[r.player .. "\0" .. r.spell] and r.time <= c and r.time + r.dur > c then
				local to = math.min(h[3], r.time + r.dur)
				trinketOnly = trinketOnly + to - c
				c = to
			end
		end
		if c < h[3] then
			problems[#problems + 1] = ("nothing up on %s from %gs to %gs"):format(h[1], round(c), round(h[3]))
			uncovered = uncovered + h[3] - c
		end
	end
	for i, c in ipairs(pool) do
		if c.trinket then
			local windows = {}
			for _, r in ipairs(rows) do
				if r.target == c.player and r.player .. r.spell ~= c.player .. c.spell and r.time >= from and not bigByPool[r.player .. "\0" .. r.spell] then
					windows[#windows + 1] = r -- a big cooldown needs no support
				end
			end
			table.sort(windows, function(a, b)
				if (a.power or 0) ~= (b.power or 0) then return (a.power or 0) < (b.power or 0) end
				return a.time < b.time
			end)
			for _, w in ipairs(windows) do
				if free(i, w.time) and worthIt(c, w.time) then use(i, w.time, c.player, "with " .. w.spell) end
			end
		end
	end
	table.sort(rows, function(a, b) return a.time < b.time end)
	-- worst first: a swap without its big cooldown, tank time with nothing up, tank time with only a trinket,
	-- a smash without a raid cooldown
	return rows, problems, {bigMissed, round(uncovered), round(trinketOnly), smashMissed}
end

local TRIES = 40	-- variations tried on top of the plain build, keeping the best
local function better(a, b)
	for i = 1, #a do
		if a[i] ~= b[i] then return a[i] < b[i] end
	end
	return false
end

-- The plain build and TRIES variations of it; the best by build's score wins, the plainest of equals.
-- Seeded, so a roster always gives the same plan.
function CP.Generate(opts, tries)
	local seed = 12345
	local function rng()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local best, bestProblems, bestScore
	for try = 0, tries or TRIES do
		local rows, problems, score = build(opts, try > 0 and rng or nil)
		if not best or better(score, bestScore) then best, bestProblems, bestScore = rows, problems, score end
	end
	return best, bestProblems, bestScore
end

local MATCH = 6	-- a cast this close to its planned time is that planned use, and one this late is a no-show (the shortest cooldowns last 6s)
local LOCK = 3	-- uses due this soon stay as planned: their owners are already being warned
local NOSHOW_WAIT = 10	-- a planned use that didn't happen isn't counted on again for this long
local KEEP = 40	-- a re-plan leaves uses this soon as they are when they can still happen (the timeline strip's span)

-- the planned row a cast {player, spell, time} fulfils, if any (rows already fulfilled carry .done)
function CP.Match(rows, use)
	for i, r in ipairs(rows) do
		if not r.done and r.player == use.player and r.spell == use.spell and math.abs(r.time - use.time) <= MATCH then
			return i
		end
	end
end

-- The plan again from fight time opts.now, after what really happened. opts.rows: the plan so far;
-- opts.uses: every tracked cast so far {player, spell, time, dur, target}; opts.pool, opts.tanks and
-- opts.tank (who has the boss now) and opts.swaps as for Generate; opts.dead[player]; opts.missed[player.."\0"..spell] =
-- fight time a planned use didn't happen. Rows already past or due within LOCK stay; so do rows due within
-- KEEP whose owner (and target) is alive and whose cooldown will be ready, so the next uses healers see don't
-- shuffle, except the tanks' own cooldowns. The holes between them and everything later is generated again
-- from what will really be ready.
function CP.Replan(opts)
	local now, dead, missed = opts.now, opts.dead or {}, opts.missed or {}
	local keep, covered, last = {}, {}, {}
	local function used(player, spell, t, target, dur)
		local key = player .. "\0" .. spell
		if not last[key] or t > last[key] then last[key] = t end
		if target and dur then covered[target] = math.max(covered[target] or 0, t + dur) end
	end
	for _, u in ipairs(opts.uses) do used(u.player, u.spell, u.time, u.target, u.dur) end
	for _, r in ipairs(opts.rows) do
		if r.time < now then
			keep[#keep + 1] = r
		elseif r.time < now + LOCK and not dead[r.player] then
			keep[#keep + 1] = r
			used(r.player, r.spell, r.time, r.target, r.dur)
		end
	end
	local pool = {}
	for _, c in ipairs(opts.pool) do
		if not dead[c.player] then
			local key = c.player .. "\0" .. c.spell
			local readyAt = c.readyAt or 0
			if last[key] then readyAt = math.max(readyAt, last[key] + c.cd) end
			if missed[key] then readyAt = math.max(readyAt, missed[key] + NOSHOW_WAIT) end
			pool[#pool + 1] = {player = c.player, spell = c.spell, dur = c.dur, cd = c.cd, power = c.power, role = c.role, raid = c.raid, trinket = c.trinket, smashOnly = c.smashOnly, notSelf = c.notSelf, readyAt = readyAt}
		end
	end
	local from, tank = now + LOCK, opts.tank or 1
	local swaps = {}
	for _, t in ipairs(opts.swaps or CP.SwapTimes(now, opts.stop or FIGHT)) do
		if t <= from then tank = tank % #opts.tanks + 1 else swaps[#swaps + 1] = t end -- a swap inside the lock
	end
	local readyAt = {}
	for _, c in ipairs(pool) do readyAt[c.player .. "\0" .. c.spell] = c.readyAt end
	local carry = {}
	for _, r in ipairs(opts.rows) do
		local ready = readyAt[r.player .. "\0" .. r.spell]
		if r.time >= from and r.time < now + KEEP and ready and ready <= r.time and not dead[r.target or ""] then
			local ok = r.note ~= "Tank swap"
			-- a tank's own cooldowns stay free to move: the tank who lost cover is the one asked to adjust
			if ok and r.player == r.target then
				for _, t in ipairs(opts.tanks) do if t == r.player then ok = false end end
			end
			for _, t in ipairs(swaps) do
				if math.abs(t - SWAP_LEAD - r.time) <= 1 then ok = true end -- still the swap it was planned for
			end
			if ok then carry[#carry + 1] = r end
		end
	end
	local tanks, holder = {}, opts.tanks[tank]
	for _, t in ipairs(opts.tanks) do
		if not dead[t] then tanks[#tanks + 1] = t end
		if t == holder and not dead[t] then tank = #tanks end
	end
	if dead[holder] then tank = 1 end -- the other tank has it now
	local rows, problems = CP.Generate({pool = pool, tanks = tanks, tank = tank, covered = covered, from = from, stop = opts.stop, swaps = swaps, keep = carry, weaker = opts.weaker})
	for _, r in ipairs(keep) do rows[#rows + 1] = r end
	table.sort(rows, function(a, b) return a.time < b.time end)
	return rows, problems
end

-- rows as plan text the editor and CP.Parse take
function CP.Format(rows, problems)
	local out = {"Time\tPlayer\tCooldown\tDuration\tTarget\tNotes"}
	for _, r in ipairs(rows) do
		out[#out + 1] = ("%g\t%s\t%s\t%g\t%s\t%s"):format(r.time, r.player, r.spell, r.dur, r.target or "", r.note or "")
	end
	for _, p in ipairs(problems or {}) do out[#out + 1] = "-- " .. p end
	return table.concat(out, "\n")
end

-- the first use of a row at or after fight time t, and which loop it's in
function CP.NextUse(row, period, t)
	if not period or t <= row.time then return row.time, 0 end
	local k = math.ceil((t - row.time) / period)
	return row.time + k * period, k
end

-- why a use due at GetTime() due won't happen, or nil
function CP.NotReady(player, spell, due)
	local unit = DBM:GetRaidUnitId(player)
	if unit and UnitIsDeadOrGhost(unit) then return "dead" end
	if unit and not UnitIsConnected(unit) then return "offline" end
	local used = lastUsed[player] and lastUsed[player][spell]
	local _, cd = CP.Info(player, spell)
	local r = reported[player] and reported[player][spell]
	local readyAt = math.max(used and cd and used + cd or 0, r and r.readyAt or 0)
	if readyAt > due + 1 then
		return ("on cooldown for %ds more"):format(readyAt - due)
	end
end

-- player's side of the plan at fight time t: the next use (next, nextIn) and the one after it (later, laterIn),
-- skipping any already cast (a raid cooldown is fire and forget: the card moves on the moment it's pressed).
-- go: a use of mine that's due and not cast yet, until MATCH seconds late, when it counts as missed
function CP.Card(rows, period, player, t)
	local card = {}
	for _, r in ipairs(rows) do
		if r.player == player and not r.done and not card.go then
			local due = CP.NextUse(r, period, t - MATCH)
			if due <= t and due >= t - MATCH then card.go = r end
		end
		if r.player == player and not r.done then
			local due = CP.NextUse(r, period, t)
			if due >= t and r ~= card.go then
				if not card.next or due < card.nextIn + t then
					card.later, card.laterIn = card.next, card.nextIn
					card.next, card.nextIn = r, due - t
				elseif not card.later or due < card.laterIn + t then
					card.later, card.laterIn = r, due - t
				end
			end
		end
	end
	return card
end

-- the weaker of two tanks by maximum health, or nil when they're within STRONGER_BY of each other
local STRONGER_BY = 1000
function CP.Weaker(tanks, maxHealth)
	local a, b = maxHealth[tanks[1]], maxHealth[tanks[2]]
	if not a or not b or math.abs(a - b) < STRONGER_BY then return nil end
	return a < b and tanks[1] or tanks[2]
end

-- who the plan has on the boss at fight time t: the last swap's tank, else the first row's target
function CP.Holder(rows, t)
	local who
	for _, r in ipairs(rows) do
		who = who or r.target
		if r.note == "Tank swap" and r.time + SWAP_LEAD <= t then who = r.target end
	end
	return who
end

-- The timeline strip from fight time t for span seconds: one tank lane showing whoever has the boss (the
-- incoming tank's cover from their press, the outgoing tank's cut off there), a tag naming the tank at each
-- handover, a raid lane with raid-wide cooldowns, Cosmic Smash impacts and swaps (taunts). A hole is just
-- empty lane.
-- {lanes = {{name = "Tank", blocks = {{from, to, row}}, tags = {{time, name}}}, {name = "Raid", blocks}},
--  smashes, swaps}
function CP.Strip(rows, period, t, span, isRaid)
	local stop = t + span
	local tank, raid = {name = "Tank", blocks = {}, tags = {}}, {name = "Raid", blocks = {}}
	local strip = {lanes = {tank, raid}, smashes = CP.SmashTimes(t, stop), swaps = {}}
	local uses = {}	-- every use in view, by target
	local taunts = {}
	for _, r in ipairs(rows) do
		local dur = r.dur or CP.Info(r.player, r.spell) or 0
		local due = CP.NextUse(r, period, t - dur)
		while due < stop and due + dur > t do
			if r.target then
				uses[r.target] = uses[r.target] or {}
				table.insert(uses[r.target], {from = due, to = due + dur, row = r})
			end
			if isRaid(r.spell) then table.insert(raid.blocks, {from = math.max(due, t), to = math.min(due + dur, stop), row = r}) end
			if r.note == "Tank swap" then taunts[#taunts + 1] = due + SWAP_LEAD end
			if not period then break end
			due = due + period
		end
	end
	table.sort(taunts)
	-- who has the boss when: from t, then from each taunt in view
	local edges = {t}
	for _, w in ipairs(taunts) do
		if w > t and w < stop then edges[#edges + 1] = w strip.swaps[#strip.swaps + 1] = w end
	end
	edges[#edges + 1] = stop
	for i = 1, #edges - 1 do
		local a, b = edges[i], edges[i + 1]
		local who = CP.Holder(rows, a)
		tank.tags[#tank.tags + 1] = {time = a, name = who}
		local mine = uses[who] or {}
		table.sort(mine, function(x, y) return x.from < y.from end)
		-- the next tank's lane starts at their first press before the taunt
		local nextStart = b
		if i < #edges - 1 then
			for _, u in ipairs(uses[CP.Holder(rows, b)] or {}) do
				if u.from < b and u.to > b and u.from >= b - SWAP_LEAD - 0.01 then nextStart = math.min(nextStart, u.from) end
			end
		end
		local laneFrom = a
		if i > 1 then
			for _, u in ipairs(mine) do
				if u.from < a and u.to > a and u.from >= a - SWAP_LEAD - 0.01 then laneFrom = math.min(laneFrom, u.from) end
			end
		end
		for _, u in ipairs(mine) do
			local from, to = math.max(u.from, laneFrom, t), math.min(u.to, nextStart, stop)
			if to > from then tank.blocks[#tank.blocks + 1] = {from = from, to = to, row = u.row} end
		end
	end
	return strip
end

DBM.CooldownPlan = CP

if not CreateFrame then return end -- loaded by tests

DBM_CooldownPlans = DBM_CooldownPlans or {}
local saved
local playerName = UnitName("player")
local tracked = {}

local function send(msg)
	local channel = GetNumRaidMembers() > 0 and "RAID" or GetNumPartyMembers() > 0 and "PARTY"
	if channel then SendAddonMessage(PREFIX, msg, channel) end
end

-- seconds until one of my cooldowns is ready, 0 if it is
local function readyIn(spell)
	local start, duration = GetSpellCooldown(spell)
	for slot = 13, 14 do
		local link = GetInventoryItemLink("player", slot)
		if link and GetItemSpell(link) == spell then start, duration = GetInventoryItemCooldown("player", slot) end
	end
	return start and duration and duration > 1.5 and math.max(0, start + duration - GetTime()) or 0
end

local function sendOne(spell, r)
	send(("C\t%s\t%s\t%s\t%d\t%s"):format(spell, r.dur or "", r.cd or "", readyIn(spell), r.power or ""))
end

local function sendMine()
	for spell, r in pairs(saved.mine[playerName] or {}) do sendOne(spell, r) end
end

-- my cooldowns from talents, glyphs and gear; [name] = true for the ones CooldownData knows
local computed = {}
local function computeMine()
	local talentRank, mainTab, mainPoints, inMain = {}, nil, -1, {}
	for tab = 1, GetNumTalentTabs() do
		local _, _, points = GetTalentTabInfo(tab)
		if (points or 0) > mainPoints then mainTab, mainPoints = tab, points or 0 end
	end
	for tab = 1, GetNumTalentTabs() do
		for i = 1, GetNumTalents(tab) do
			local name, _, _, _, rank = GetTalentInfo(tab, i)
			if name then
				talentRank[name] = rank
				if tab == mainTab then inMain[name] = true end
			end
		end
	end
	local glyphs = {}
	for socket = 1, 6 do
		local enabled, _, spellId = GetGlyphSocketInfo(socket)
		if enabled and spellId then glyphs[GetSpellInfo(spellId) or spellId] = true end
	end
	local worn = {}
	for slot = 1, 19 do
		local link = GetInventoryItemLink("player", slot)
		local id = link and tonumber(link:match("item:(%d+)"))
		if id then worn[id] = true end
	end
	local mine = CP.Compute({
		knows = function(cast)
			if trinkets[cast] then return worn[trinkets[cast]] end
			local name = GetSpellInfo(cast)
			return name and GetSpellInfo(name) ~= nil
		end,
		talent = function(spell) return talentRank[GetSpellInfo(spell)] or 0 end,
		mainTreeHas = function(spell) return inMain[GetSpellInfo(spell)] end,
		glyph = function(spell) return glyphs[GetSpellInfo(spell)] end,
		pieces = function(items)
			local n = 0
			for _, id in ipairs(items) do if worn[id] then n = n + 1 end end
			return n
		end,
		defense = function()
			local base, modifier = UnitDefense("player")
			return base + modifier + GetCombatRatingBonus(CR_DEFENSE_SKILL)
		end,
	})
	local was = saved.mine[playerName]
	for name in pairs(was) do if defaultByName[name] then was[name] = nil end end -- dropped talents or gear
	wipe(computed)
	for cast, v in pairs(mine) do
		local name = GetSpellInfo(cast)
		computed[name] = true
		was[name] = v
	end
	sendMine()
end

local function track(text)
	for _, row in ipairs((CP.Parse(text)).rows) do tracked[row.spell] = true end
end

-- for a cooldown CooldownData doesn't know (another trinket, say), measured on first use
local function learn(spell, field, value)
	if computed[spell] then return end
	local mine = saved.mine[playerName]
	mine[spell] = mine[spell] or {}
	if mine[spell][field] and math.abs(mine[spell][field] - value) < 0.5 then return end
	mine[spell][field] = value
	sendOne(spell, mine[spell])
end

local function learnDuration(spell, unit)
	for i = 1, 40 do
		local name, _, _, _, _, duration, _, caster = UnitAura(unit, i)
		if not name then return end
		if name == spell and caster == "player" and duration and duration > 0 then
			return learn(spell, "dur", duration)
		end
	end
end

local function learnCooldown(spell)
	local _, duration = GetSpellCooldown(spell)
	if not (duration and duration > 1.5) then
		for slot = 13, 14 do
			local link = GetInventoryItemLink("player", slot)
			if link and GetItemSpell(link) == spell then
				_, duration = GetInventoryItemCooldown("player", slot)
			end
		end
	end
	if duration and duration > 1.5 then learn(spell, "cd", duration) end
end

-- everyone in the group with what they reported, and the two tanks: the raid's main tanks, else the
-- players with a big cooldown. readyAt is seconds after origin (the pull, or now for a plan made now).
-- the tank with less maximum health gets first pick of the shared externals
local function weakerTank(tanks)
	local hp = {}
	for _, name in ipairs(tanks) do
		local unit = DBM:GetRaidUnitId(name)
		if unit then hp[name] = UnitHealthMax(unit) end
	end
	return CP.Weaker(tanks, hp)
end

local function roster(origin)
	local units = {"player"}
	for i = 1, GetNumRaidMembers() do units[#units + 1] = "raid" .. i end
	if #units == 1 then for i = 1, GetNumPartyMembers() do units[#units + 1] = "party" .. i end end
	local pool, tanks, bigs, seen = {}, {}, {}, {}
	local now = GetTime()
	for _, unit in ipairs(units) do
		local name = UnitName(unit)
		if name and not seen[name] then
			seen[name] = true
			if GetPartyAssignment("MAINTANK", unit) then tanks[#tanks + 1] = name end
			for spell, r in pairs(reported[name] or {}) do
				local role = roleByName[spell]
				if role and r.dur and r.cd then
					pool[#pool + 1] = {player = name, spell = spell, dur = r.dur, cd = r.cd, power = r.power or defaultByName[spell][3],
						role = role, raid = raidByName[spell], trinket = trinketByName[spell], smashOnly = smashOnlyByName[spell], notSelf = notSelfByName[spell], readyAt = math.max(0, (r.readyAt or now) - origin)}
					if role == "big" and not bigs[name] then bigs[name] = true bigs[#bigs + 1] = name end
				end
			end
		end
	end
	if #tanks < 2 then tanks = bigs end
	table.sort(pool, function(a, b) return a.player .. a.spell < b.player .. b.spell end) -- same plan on every client
	return pool, tanks
end

-- fight
local active, pullTime, done = nil, 0, {}
local ticker = CreateFrame("Frame")
ticker:Hide()

-- what happened this pull, kept for the re-plan: casts in fight time, deaths, no-shows, Phase Punch's tank
local fight = {uses = {}, dead = {}, missed = {}}
local replanSoon
local card, showCard, strip, showStrip, stop

-- the two tanks a plan is for: whoever has its first row, and whoever has its first swap
local function planTanks(rows)
	local first, second
	for _, r in ipairs(rows) do
		first = first or r.target
		if r.note == "Tank swap" and r.target ~= first then second = r.target break end
	end
	return first and second and {first, second}
end

local elapsed = 0
ticker:SetScript("OnUpdate", function(_, e)
	elapsed = elapsed + e
	if elapsed < 0.2 then return end
	elapsed = 0
	if not DBM.Options.CooldownPlanEnabled then
		stop()
		return
	end
	local now = GetTime()
	local t = now - pullTime
	if active.live then
		for name in pairs(fight.dead) do -- battle rez or soulstone: back in the plan
			local unit = DBM:GetRaidUnitId(name)
			if unit and not UnitIsDeadOrGhost(unit) then
				fight.dead[name] = nil
				replanSoon()
			end
		end
	end
	for _, row in ipairs(active.rows) do
		local due = CP.NextUse(row, active.period, t)
		local left, key = due - t, row.player .. "\0" .. row.spell .. "\0" .. due
		if left <= CHECKAHEAD and not done["check" .. key] then
			done["check" .. key] = true
			local why = CP.NotReady(row.player, row.spell, now + left)
			if why then
				RaidNotice_AddMessage(RaidWarningFrame, ("%s's %s: %s"):format(row.player, row.spell, why), ChatTypeInfo["RAID_WARNING"])
			end
		end
		if active.live and left < -MATCH and not row.done and not row.missed and not fight.dead[row.player] then
			row.missed = true
			fight.missed[row.player .. "\0" .. row.spell] = row.time
			replanSoon()
		end
	end
	showCard(active.rows, active.period, t)
	showStrip(active.rows, active.period, t, planTanks(active.rows) ~= nil)
end)

function stop()
	ticker:Hide()
	if card then card:Hide() end
	if strip then strip:Hide() end
	active = nil
end

local function clock(t) return ("%d:%02d"):format(t / 60, t % 60) end

-- a re-planned future from fight time from on: the strip and card redraw from it, and I'm told about my moves
local function applyRows(future, from)
	local t = GetTime() - pullTime
	local mine = {}
	for _, r in ipairs(active.rows) do
		if r.player == playerName and r.time >= t then mine[r.spell .. "\0" .. r.time] = r end
	end
	local rows, cast = {}, {}
	for _, r in ipairs(active.rows) do
		if r.time < from then rows[#rows + 1] = r end
		if r.done then cast[r.player .. "\0" .. r.spell .. "\0" .. r.time] = true end
	end
	for _, r in ipairs(future) do
		r.done = r.done or cast[r.player .. "\0" .. r.spell .. "\0" .. r.time]
		rows[#rows + 1] = r
	end
	table.sort(rows, function(a, b) return a.time < b.time end)
	active.rows = rows
	local moved = {}
	for _, r in ipairs(future) do
		if r.player == playerName and r.time - t < 60 then
			if mine[r.spell .. "\0" .. r.time] then mine[r.spell .. "\0" .. r.time] = nil else moved[r.spell] = r.time end
		end
	end
	local justUsed = lastUsed[playerName] or {}
	for _, r in pairs(mine) do
		-- a slot dropped because I already used it early needs no telling
		if r.time - t < 60 and not moved[r.spell] and not (justUsed[r.spell] and GetTime() - justUsed[r.spell] < 10) then
			RaidNotice_AddMessage(RaidWarningFrame, ("Hold your %s, not needed at %s"):format(r.spell, clock(r.time)), ChatTypeInfo["RAID_WARNING"])
		end
	end
	for spell, at in pairs(moved) do
		RaidNotice_AddMessage(RaidWarningFrame, ("Your %s is now at %s"):format(spell, clock(at)), ChatTypeInfo["RAID_WARNING"])
	end
end

local sendSeq = 0
local function replan()
	if not active or not active.live then return end
	local t = GetTime() - pullTime
	local tanks = planTanks(active.rows)
	if not tanks then return end
	local tank = fight.holder == tanks[2] and 2 or fight.holder == tanks[1] and 1 or #CP.SwapTimes(0, t) % 2 + 1
	local rows = CP.Replan({
		rows = active.rows, uses = fight.uses, pool = (roster(pullTime)), tanks = tanks, tank = tank, weaker = weakerTank(tanks),
		now = t, dead = fight.dead, missed = fight.missed,
		swaps = fight.holder and CP.SwapTimes(t, FIGHT, fight.stacks) or nil,
	})
	local future = {}
	for _, r in ipairs(rows) do
		if r.time >= t then future[#future + 1] = r end
	end
	applyRows(future, t)
	sendSeq = sendSeq + 1
	for i, r in ipairs(future) do
		send(("U\t%d\t%g\t%d\t%d\t%g\t%s\t%s\t%g\t%s\t%s"):format(sendSeq, t, #future, i, r.time, r.player, r.spell, r.dur, r.target or "", r.note or ""))
	end
	if #future == 0 then send(("U\t%d\t%g\t0\t0"):format(sendSeq, t)) end
end
function replanSoon()
	DBM:Unschedule(replan)
	DBM:Schedule(0.3, replan)
end

DBM:RegisterCallback("DBM_Pull", function(_, mod, delay)
	local text = saved and mod and saved.plans[tostring(mod.id):lower()]
	if not text or not DBM.Options.CooldownPlanEnabled then return end
	stop()
	active = CP.Parse(text)
	if #active.rows == 0 then active = nil return end
	active.from = saved.planFrom[tostring(mod.id):lower()]
	-- the plan's sender re-plans when cooldowns go off plan; a looping plan has no fight to re-plan
	active.live = active.from == playerName and not active.period and planTanks(active.rows) ~= nil
	-- plan time 0 is when Algalon starts fighting: 26s of roleplay on the lockout's first pull, 8.5s after
	-- that (JustEngagedWith's introDelay); before the first pull there's no lockout timer yet (as DBM-Ulduar's Algalon checks)
	local intro = 0
	if mod.id == "Algalon" then
		local minutes = tonumber((select(3, GetWorldStateUIInfo(1)) or ""):match("%d+")) or 0
		intro = minutes == 0 and 26 or 8.5
	end
	pullTime = GetTime() - (delay or 0) + intro
	wipe(done)
	fight = {uses = {}, dead = {}, missed = {}}
	ticker:Show()
end)
-- who a use of mine is on and why it's there
local function reason(r)
	local why = r.note == "Cosmic Smash" and " for Cosmic Smash" or r.note and (" (" .. r.note .. ")") or ""
	if smashOnlyByName[r.spell] then why = why .. " on Fire Resistance Aura" end
	return (r.target and r.target ~= playerName and (" on " .. r.target) or "") .. why
end

-- what a use needs said on the card: the aura for Aura Mastery, the target for an external, else nothing
local function sub(r)
	if smashOnlyByName[r.spell] then return "Fire Res" end
	if roleByName[r.spell] == "ext" and not raidByName[r.spell] and r.target and r.target ~= playerName then return "on " .. r.target end
	return ""
end
local function countdown(left) return left < 60 and tostring(math.ceil(left)) or clock(left) end

-- personal card: a big countdown to my next press with the spell beside it, and the press after that on one
-- line; right-click hides it
function showCard(rows, period, t, prepull)
	local c = CP.Card(rows, period, playerName, t)
	if not c.go and not c.next then
		if card then card:Hide() end
		return
	end
	if not card then
		card = CreateFrame("Frame", "DBMCooldownPlanCard", UIParent)
		card:SetWidth(210) -- fixed: room for a long spell name beside the countdown and "Hand of Sacrifice on Dracohouston"
		card:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16, insets = {left = 4, right = 4, top = 4, bottom = 4},
		})
		card:SetBackdropColor(0, 0, 0, 0.75)
		card:SetMovable(true)
		card:EnableMouse(true)
		card:RegisterForDrag("LeftButton")
		card:SetScript("OnDragStart", card.StartMoving)
		card:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
			local p, _, rp, x, y = self:GetPoint()
			saved.cardPos = {p, rp, x, y}
		end)
		card:SetScript("OnMouseUp", function(self, button) if button == "RightButton" then self:Hide() end end)
		local pos = saved.cardPos
		if pos then card:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else card:SetPoint("CENTER", 320, -160) end
		card.num = card:CreateFontString(nil, "ARTWORK", "NumberFontNormalHuge")
		card.num:SetWidth(54)
		card.num:SetJustifyH("CENTER")
		-- two matching rows, times in the left column and spells beside them; no widths, so nothing wraps:
		-- the longest pieces measured in Friz (Icebound Fortitude at 14 is 124px of the 130 beside the countdown)
		local friz = STANDARD_TEXT_FONT
		card.spell = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
		card.spell:SetFont(friz, 14)
		card.spell:SetPoint("TOPLEFT", card.num, "TOPRIGHT", 6, -2)
		card.sub = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		card.sub:SetFont(friz, 12)
		card.sub:SetTextColor(0.63, 0.63, 0.63)
		card.sub:SetPoint("TOPLEFT", card.spell, "BOTTOMLEFT", 0, -1)
		card.rule = card:CreateTexture(nil, "ARTWORK")
		card.rule:SetTexture(1, 1, 1, 0.15)
		card.rule:SetHeight(1)
		card.afterTime = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		card.afterTime:SetFont(friz, 13)
		card.afterTime:SetTextColor(0.69, 0.69, 0.69)
		card.afterTime:SetWidth(54)
		card.afterTime:SetJustifyH("CENTER")
		card.afterTime:SetPoint("TOPLEFT", card.rule, "BOTTOMLEFT", -4, -5)
		card.after = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		card.after:SetFont(friz, 13)
		card.after:SetTextColor(0.69, 0.69, 0.69)
		card.after:SetPoint("TOPLEFT", card.afterTime, "TOPRIGHT", 6, 0)
	end
	card.num:ClearAllPoints()
	card.num:SetPoint("TOPLEFT", 6, -10)
	local r = c.go or c.next
	local font = card.num:GetFont()
	card.num:SetFont(font, c.go and not prepull and 20 or 30, "OUTLINE") -- "NOW" is 73px at 30, too wide for the column
	if c.go and not prepull then
		card.num:SetText("NOW")
		card.num:SetTextColor(1, 0.19, 0.19)
	elseif prepull then
		card.num:SetText(clock(r.time))
		card.num:SetTextColor(0.75, 0.75, 0.75)
	else
		card.num:SetText(countdown(c.nextIn))
		if c.nextIn <= 10 then card.num:SetTextColor(1, 0.82, 0) else card.num:SetTextColor(0.75, 0.75, 0.75) end
	end
	card.spell:SetText(r.spell)
	card.sub:SetText(sub(r))
	-- the press after that: the next one when the big line is NOW, else the one after the next
	local after, afterIn = c.go and c.next or c.later, c.go and c.nextIn or c.laterIn
	card.rule:ClearAllPoints()
	card.rule:SetPoint("TOPLEFT", card.num, "BOTTOMLEFT", 4, -6)
	card.rule:SetPoint("RIGHT", -10, 0)
	if after then -- time and spell only: the target shows once it moves up to the big row
		card.afterTime:SetText(prepull and clock(after.time) or countdown(afterIn))
		card.after:SetText(after.spell)
		card.rule:Show()
	else
		card.afterTime:SetText("")
		card.after:SetText("")
		card.rule:Hide()
	end
	card:SetHeight(10 + card.num:GetHeight() + (after and 6 + 1 + 5 + card.after:GetHeight() or 0) + 12)
	card:Show()
end

-- timeline strip: the next STRIP_SPAN seconds of the plan, on until /dbm cd strip turns it off
local STRIP_SPAN, STRIP_W, LABEL_W, LANE_H, TAG_H = 40, 420, 90, 18, 12
local LANES_TOP = 20 + TAG_H	-- smash labels, then the tank tags, then the lanes
-- one colour per cooldown, by cast spell; no yellows (the swap marks) or gold (the outline on my own uses)
local STRIP_COLORS = {
	[48792] = {0.18, 0.44, 0.71}, -- Icebound Fortitude
	[498] = {0.66, 0.20, 0.62},   -- Divine Protection
	[871] = {0.49, 0.60, 0.16},   -- Shield Wall
	[61336] = {0.63, 0.32, 0.18}, -- Survival Instincts
	[55233] = {0.69, 0.23, 0.18}, -- Vampiric Blood
	[51271] = {0.29, 0.25, 0.71}, -- Unbreakable Armor
	[12975] = {0.54, 0.43, 0.23}, -- Last Stand
	[22812] = {0.18, 0.55, 0.34}, -- Barkskin
	[6940] = {0.76, 0.33, 0.50},  -- Hand of Sacrifice
	[1038] = {0.24, 0.60, 0.24},  -- Hand of Salvation
	[64205] = {0.11, 0.54, 0.54}, -- Divine Sacrifice
	[48788] = {0.69, 0.49, 0.38}, -- Lay on Hands
	[33206] = {0.79, 0.44, 0.12}, -- Pain Suppression
	[47788] = {0.23, 0.56, 0.79}, -- Guardian Spirit
	[31821] = {0.49, 0.25, 0.71}, -- Aura Mastery
	[64763] = {0.42, 0.42, 0.42}, -- Heart of Iron
}
local colorByName = {}
local function stripPart(list, kind)
	list.used = list.used + 1
	local p = list[list.used]
	if not p then
		if kind == "line" then
			p = strip:CreateTexture(nil, "OVERLAY")
		else
			p = CreateFrame("Frame", nil, strip)
			p:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2})
			p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			p.text:SetPoint("LEFT", 3, 0)
			p.text:SetPoint("RIGHT", -2, 0)
			p.text:SetJustifyH("LEFT")
		end
		list[list.used] = p
	end
	p:Show()
	return p
end
function showStrip(rows, period, t, hasTanks)
	if not DBM.Options.CooldownPlanStrip or not hasTanks then
		if strip then strip:Hide() end
		return
	end
	if not strip then
		strip = CreateFrame("Frame", "DBMCooldownPlanStrip", UIParent)
		strip:SetSize(LABEL_W + STRIP_W + 16, 2 * LANE_H + TAG_H + 52) -- smash labels above, tank tags, two lanes, swap labels below
		strip:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16, insets = {left = 4, right = 4, top = 4, bottom = 4},
		})
		strip:SetBackdropColor(0, 0, 0, 0.75)
		strip:SetMovable(true)
		strip:EnableMouse(true)
		strip:RegisterForDrag("LeftButton")
		strip:SetScript("OnDragStart", strip.StartMoving)
		strip:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
			local p, _, rp, x, y = self:GetPoint()
			saved.stripPos = {p, rp, x, y}
		end)
		local pos = saved.stripPos
		if pos then strip:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else strip:SetPoint("TOP", 0, -120) end
		strip.names, strip.blocks, strip.lines, strip.marks = {}, {used = 0}, {used = 0}, {used = 0}
		for i = 1, 2 do
			strip.names[i] = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			strip.names[i]:SetPoint("TOPLEFT", 10, -LANES_TOP - (i - 1) * LANE_H - 3)
		end
	end
	local s = CP.Strip(rows, period, t, STRIP_SPAN, function(spell) return raidByName[spell] end)
	for _, list in ipairs({strip.blocks, strip.lines, strip.marks}) do
		for i = 1, list.used do list[i]:Hide() end
		list.used = 0
	end
	local x0 = LABEL_W + 8
	local function x(time) return x0 + (time - t) / STRIP_SPAN * STRIP_W end
	local function block(lane, from, to, color, a, text, mine)
		local p = stripPart(strip.blocks)
		p:ClearAllPoints()
		p:SetPoint("TOPLEFT", x(from), -LANES_TOP - (lane - 1) * LANE_H - 1)
		p:SetSize(math.max(1, x(to) - x(from)), LANE_H - 2)
		p:SetBackdropColor(color[1], color[2], color[3], a)
		p:SetBackdropBorderColor(1, 0.82, 0, mine and 1 or 0)
		p.text:SetText(text or "")
		p.text:SetTextColor(1, 1, 1)
	end
	local function label(anchor, point, relPoint, dx, w, text, r, g, b)
		local m = stripPart(strip.marks)
		m:ClearAllPoints()
		m:SetPoint(point, anchor, relPoint, dx, 0)
		m:SetSize(w, 12)
		m:SetBackdropColor(0, 0, 0, 0)
		m:SetBackdropBorderColor(0, 0, 0, 0)
		m.text:SetText(text)
		m.text:SetTextColor(r, g, b)
		return m
	end
	local function line(time, r, g, b, text, below)
		local l = stripPart(strip.lines, "line")
		l:ClearAllPoints()
		l:SetPoint("TOPLEFT", x(time), -20)
		l:SetSize(2, TAG_H + 2 * LANE_H + 4)
		l:SetTexture(r, g, b, 0.9)
		if text then
			if below then label(l, "TOPLEFT", "BOTTOMLEFT", -20, 44, text, r, g, b) else label(l, "BOTTOMLEFT", "TOPLEFT", -20, 44, text, r, g, b) end
		end
	end
	for i, lane in ipairs(s.lanes) do
		strip.names[i]:SetText(lane.name)
		for _, b in ipairs(lane.blocks) do
			local r = b.row
			local short = r.spell .. ((lane.name == "Raid" or r.player ~= r.target) and (" (" .. r.player .. ")") or "")
			block(i, b.from, b.to, colorByName[r.spell] or {0.45, 0.45, 0.5}, 0.9, short, r.player == playerName)
		end
	end
	-- whose lane it is: a tag in the tank's class colour at each handover
	for _, tag in ipairs(s.lanes[1].tags) do
		local unit = DBM:GetRaidUnitId(tag.name)
		local cc = unit and RAID_CLASS_COLORS[select(2, UnitClass(unit)) or ""] or {r = 0.6, g = 0.6, b = 0.7}
		local p = stripPart(strip.blocks)
		p:ClearAllPoints()
		p:SetPoint("TOPLEFT", x(tag.time) + 2, -20)
		p:SetSize(70, TAG_H - 1)
		p:SetBackdropColor(cc.r, cc.g, cc.b, 0.9)
		p:SetBackdropBorderColor(0, 0, 0, 0)
		p.text:SetText(tag.name)
		local light = cc.r * 0.3 + cc.g * 0.59 + cc.b * 0.11 > 0.6
		p.text:SetTextColor(light and 0 or 1, light and 0 or 1, light and 0 or 1)
	end
	for _, h in ipairs(s.smashes) do line(h, 1, 0.55, 0.23, "Smash") end
	for _, w in ipairs(s.swaps) do line(w, 1, 0.82, 0, "Swap", true) end
	line(t, 1, 1, 1)
	strip:Show()
end

-- what I'm down for in a plan, so nobody learns it from the first warning sign
local function tellMine(id)
	local text = saved.plans[id]
	if not text or not DBM.Options.CooldownPlanEnabled then return end
	local list = {}
	local plan = CP.Parse(text)
	for _, r in ipairs(plan.rows) do
		if r.player == playerName then list[#list + 1] = clock(r.time) .. " " .. r.spell .. reason(r) end
	end
	if not active then showCard(plan.rows, plan.period, 0, true) end
	if #list > 0 then
		DBM:AddMsg(("Your cooldowns on %s (%d):"):format(id, #list))
		for _, line in ipairs(list) do DBM:AddMsg("  " .. line) end
	end
end
CP.tellMine = tellMine

DBM:RegisterCallback("DBM_TimerStart", function(_, _, _, _, _, timerType)
	if timerType == "pull" and saved and saved.lastPlan then tellMine(saved.lastPlan) end
end)
DBM:RegisterCallback("DBM_Kill", stop)
DBM:RegisterCallback("DBM_Wipe", stop)

-- comms: P = plan line, Q = ask everyone for their CDs, C = one CD's duration and cooldown,
-- U = the plan's sender re-planned the rest of the fight, W = a hole it couldn't fill
local incoming, update = {}, nil
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
for _, e in ipairs({"PLAYER_ENTERING_WORLD", "PLAYER_TALENT_UPDATE", "GLYPH_ADDED", "GLYPH_REMOVED", "GLYPH_UPDATED", "UNIT_INVENTORY_CHANGED"}) do
	events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_TALENT_UPDATE" or event:match("^GLYPH_") or (event == "UNIT_INVENTORY_CHANGED" and ... == "player") then
		DBM:Unschedule(computeMine)
		DBM:Schedule(1, computeMine)
	elseif event == "ADDON_LOADED" then
		if ... ~= "DBM-Core" then return end
		saved = DBM_CooldownPlans
		saved.plans, saved.mine, saved.planFrom = saved.plans or {}, saved.mine or {}, saved.planFrom or {}
		saved.mine[playerName] = saved.mine[playerName] or {}
		reported[playerName] = saved.mine[playerName]
		for cast, c in pairs(data) do
			local name = GetSpellInfo(cast)
			if name then
				defaultByName[name], tracked[name], colorByName[name] = {c.dur, c.cd, c.power}, true, STRIP_COLORS[cast]
				roleByName[name], raidByName[name], trinketByName[name], smashOnlyByName[name], notSelfByName[name] = c.role, c.raid, c.trinket, c.smashOnly, c.notSelf
			end
		end
		for _, text in pairs(saved.plans) do track(text) end
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, msg, _, sender = ...
		if prefix ~= PREFIX or sender == playerName or not saved then return end
		local kind = msg:sub(1, 1)
		if kind == "C" then
			local _, spell, dur, cd, wait, power = strsplit("\t", msg)
			reported[sender] = reported[sender] or {}
			reported[sender][spell] = {dur = tonumber(dur), cd = tonumber(cd), power = tonumber(power), readyAt = GetTime() + (tonumber(wait) or 0)}
		elseif kind == "Q" then
			sendMine()
		elseif kind == "U" and active and sender == active.from then
			local _, seq, from, count, i, time, player, spell, dur, target, note = strsplit("\t", msg)
			seq, count = tonumber(seq), tonumber(count)
			if not update or update.seq < seq then update = {seq = seq, from = tonumber(from), rows = {}, got = 0} end
			if update.seq ~= seq then return end
			if count > 0 and not update.rows[tonumber(i)] then
				update.got = update.got + 1
				update.rows[tonumber(i)] = {time = tonumber(time), player = player, spell = spell, dur = tonumber(dur),
					target = target ~= "" and target or nil, note = note ~= "" and note or nil}
			end
			if update.got == count then
				applyRows(update.rows, update.from)
				update.got = -1 -- applied
			end
		elseif kind == "P" and DBM:GetRaidRank(sender) > 0 then
			local id, count, i, line = msg:match("^P\t([^\t]+)\t(%d+)\t(%d+)\t(.*)$")
			if not id then return end
			local inc = incoming[sender]
			if not inc or inc.id ~= id then inc = {id = id, lines = {}, got = 0} incoming[sender] = inc end
			if not inc.lines[tonumber(i)] then inc.got = inc.got + 1 end
			inc.lines[tonumber(i)] = line
			if inc.got == tonumber(count) then
				incoming[sender] = nil
				local text = table.concat(inc.lines, "\n")
				saved.plans[id] = text
				saved.planFrom[id] = sender
				saved.lastPlan = id
				track(text)
				DBM:AddMsg(("Cooldown plan for %s received from %s."):format(id, sender))
				tellMine(id)
			end
		end
	else
		local _, sub, sourceGUID, sourceName, _, destGUID, destName, _, spellId, spell = ...
		if active and not active.live and sub == "SPELL_CAST_SUCCESS" and sourceName == playerName and tracked[spell] then
			local i = CP.Match(active.rows, {player = sourceName, spell = spell, time = GetTime() - pullTime})
			if i then active.rows[i].done = true end
		end
		if active and spellId == 64412 and (sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_APPLIED_DOSE") then
			-- Phase Punch is on whoever has the boss; its stacks say when they'll hand over
			fight.holder, fight.stacks = destName, sub == "SPELL_AURA_APPLIED" and 1 or select(13, ...)
		end
		if active and active.live then
			if sub == "UNIT_DIED" and destName then
				for _, r in ipairs(active.rows) do
					if (r.player == destName or r.target == destName) and r.time > GetTime() - pullTime then
						fight.dead[destName] = true
						replanSoon()
						break
					end
				end
			elseif sub == "SPELL_CAST_SUCCESS" and tracked[spell] and sourceName then
				local use = {player = sourceName, spell = spell, time = GetTime() - pullTime, dur = (CP.Info(sourceName, spell))}
				-- Divine Sacrifice has no target: it covers whoever has the boss
				use.target = not smashOnlyByName[spell] and (roleByName[spell] == "ext" and (destName or fight.holder) or sourceName) or nil
				fight.uses[#fight.uses + 1] = use
				local i = CP.Match(active.rows, use)
				if i then
					active.rows[i].done = true
				else
					local tanks, matters = planTanks(active.rows), false
					for _, r in ipairs(active.rows) do
						if r.player == sourceName and r.spell == spell then matters = true end
					end
					if matters or (tanks and (use.target == tanks[1] or use.target == tanks[2])) then replanSoon() end
				end
			end
		end
		if not tracked[spell] or not sourceName then return end
		if sub == "SPELL_CAST_SUCCESS" or sub == "SPELL_AURA_APPLIED" then
			local now = GetTime()
			lastUsed[sourceName] = lastUsed[sourceName] or {}
			local used = lastUsed[sourceName][spell]
			if not used or now - used > 3 then lastUsed[sourceName][spell] = now end
			if sourceGUID == UnitGUID("player") then
				if sub == "SPELL_AURA_APPLIED" then
					local unit = destGUID == sourceGUID and "player" or DBM:GetRaidUnitId(destName)
					if unit then learnDuration(spell, unit) end
				else
					DBM:Schedule(0.5, learnCooldown, spell)
				end
			end
		end
	end
end)

-- editor
local frame, editBox, editing


local function report(id)
	local plan, errors = CP.Parse(editBox:GetText())
	for _, e in ipairs(errors) do DBM:AddMsg(e) end
	local issues = CP.Check(plan)
	DBM:AddMsg(("Cooldown plan %s: %d uses%s, %s."):format(id, #plan.rows, plan.period and (", loops every " .. plan.period .. "s") or "", #issues == 0 and "no problems" or (#issues .. " problems")))
	for _, issue in ipairs(issues) do DBM:AddMsg("  " .. issue) end
	if not plan.period then
		local smashes, covered = CP.SmashTimes(0, FIGHT), 0
		for _, hit in ipairs(smashes) do
			for _, r in ipairs(plan.rows) do
				if raidByName[r.spell] and r.time <= hit and r.time + (r.dur or CP.Info(r.player, r.spell) or 0) > hit then
					covered = covered + 1
					break
				end
			end
		end
		DBM:AddMsg(("  Cosmic Smash: %d of %d have a raid cooldown up when they land."):format(covered, #smashes))
	end
end

local function generate()
	local pool, tanks = roster(GetTime())
	tanks = {tanks[1], tanks[2]}
	if #tanks < 2 then
		DBM:AddMsg("Generate needs two tanks: set Main Tank on them in the raid frame, or have them in the group with DBM.")
		return
	end
	local rows, problems = CP.Generate({pool = pool, tanks = tanks, weaker = weakerTank(tanks)})
	editBox:SetText(CP.Format(rows, problems))
	report(editing)
	for _, p in ipairs(problems) do DBM:AddMsg("  " .. p) end
end

local function button(text, x, onClick)
	local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	b:SetSize(80, 22)
	b:SetPoint("BOTTOM", x, 16)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
end

local function createEditor()
	frame = CreateFrame("Frame", "DBMCooldownPlanEditor", UIParent)
	frame:SetFrameStrata("DIALOG")
	frame:SetSize(560, 380)
	frame:SetPoint("CENTER")
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = {left = 11, right = 12, top = 12, bottom = 11},
	})
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame.title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	frame.title:SetPoint("TOP", 0, -18)
	local scroll = CreateFrame("ScrollFrame", "DBMCooldownPlanScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 22, -40)
	scroll:SetPoint("BOTTOMRIGHT", -42, 48)
	editBox = CreateFrame("EditBox", nil, scroll)
	editBox:SetMultiLine(true)
	editBox:SetAutoFocus(false)
	editBox:SetFontObject(ChatFontNormal)
	editBox:SetWidth(490)
	editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
	editBox:SetScript("OnTextChanged", function(self) ScrollingEdit_OnTextChanged(self, scroll) end)
	editBox:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
	editBox:SetScript("OnUpdate", function(self, e) ScrollingEdit_OnUpdate(self, e, scroll) end)
	scroll:SetScrollChild(editBox)
	scroll:EnableMouse(true)
	scroll:SetScript("OnMouseDown", function() editBox:SetFocus() end)
	button("Generate", -180, generate)
	button("Check", -90, function() report(editing) end)
	button("Save", 0, function()
		saved.plans[editing] = editBox:GetText()
		track(saved.plans[editing])
		report(editing)
	end)
	button("Send", 90, function()
		if DBM:GetRaidRank() == 0 then
			DBM:AddMsg("Only the leader or an assistant can send a plan.")
			return
		end
		local text = editBox:GetText()
		saved.plans[editing] = text
		saved.planFrom[editing] = playerName
		saved.lastPlan = editing
		track(text)
		tellMine(editing)
		local lines = {}
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			if line:match("%S") then lines[#lines + 1] = line:sub(1, 200) end
		end
		for i, line in ipairs(lines) do send(("P\t%s\t%d\t%d\t%s"):format(editing, #lines, i, line)) end
		send("Q")
		DBM:AddMsg("Cooldown plan sent; checking against everyone's cooldowns in 3s.")
		DBM:Schedule(3, report, editing)
	end)
	button(CLOSE, 180, function() frame:Hide() end)
	tinsert(UISpecialFrames, "DBMCooldownPlanEditor")
end

-- /dbm cd <boss>: edit that boss's plan (default the last one edited); /dbm cd mine: my cooldowns in the
-- last plan; /dbm cd off|on: stop or resume showing plans
function DBM:CooldownPlanCommand(arg)
	arg = trim(arg or ""):lower()
	if arg == "mine" then
		if saved.lastPlan then tellMine(saved.lastPlan) end
		return
	end
	editing = arg ~= "" and arg or saved.lastEdited or "algalon"
	saved.lastEdited = editing
	if not frame then createEditor() end
	frame.title:SetText("Cooldown plan: " .. editing .. "   (time, player, cooldown, duration, target, notes)")
	editBox:SetText(saved.plans[editing] or "")
	frame:Show()
	if UnitInRaid("player") or GetNumPartyMembers() > 0 then send("Q") end
end
