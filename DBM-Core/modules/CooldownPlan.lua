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

local defaultByName, roleByName, raidByName, trinketByName, smashOnlyByName, notSelfByName, healsByName = {}, {}, {}, {}, {}, {}, {}	-- by localized cast name, filled at load

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

-- a plan as CP.Format writes it: a tab-separated row per use; anything else (its header, a "--" problem) is skipped
function CP.Parse(text)
	local rows = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local f = {}
		for field in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
		local t = tonumber(f[1])
		if t and (f[2] or "") ~= "" and (f[3] or "") ~= "" then
			rows[#rows + 1] = {
				time = t, player = f[2], spell = f[3], dur = tonumber(f[4]),
				target = (f[5] or "") ~= "" and f[5] or nil, note = (f[6] or "") ~= "" and f[6] or nil,
			}
		end
	end
	table.sort(rows, function(a, b) return a.time < b.time end)
	return {rows = rows}
end

-- [player][spell] = {dur = s, cd = s, readyAt = GetTime()} as reported by each player;
-- [player][spell] = GetTime() of their last use seen in the combat log
local reported, lastUsed = {}, {}
local tankReported = {} -- [player] = their average item level when their own talents say tank (T)
CP.reported, CP.lastUsed = reported, lastUsed

function CP.Info(player, spell)
	local r = reported[player] and reported[player][spell]
	local d = defaultByName[spell]
	return (r and r.dur) or (d and d[1]), (r and r.cd) or (d and d[2])
end

-- Algalon's fight, in seconds from the end of the roleplay (boss_algalon_the_observer.cpp, JustEngagedWith
-- and UpdateAI): Phase Punch every 15.5s from 15.5, Cosmic Smash cast every 25.5s from 26 and landing 5s
-- later, Big Bang every 90.5s from 90. Big Bang's DelayEventsToMax(11s, GROUP_COMBAT) moves any punch or
-- smash due within 11s of it to exactly 11s after it, and their cadence carries on from there.
local PUNCH, SMASH, BANG, BANG_HOLD, SMASH_LANDS = 15.5, 25.5, 90.5, 11, 5
local FIGHT = 360	-- Ascend to the Heavens
local STACKS = 4	-- a tank takes 4 punches, then the other taunts
local SWAP_DELAY = 4	-- ...this long after the 4th, leaving time to taunt again on a miss before the 5th
local PULL_PRESS = 2.5	-- the first tank's big cooldown: up before the first Quantum Strike lands at 3.5 (Algalon reaches them ~2.3s after engaging, in the logs)
local SWAP_LEAD = 1	-- the incoming tank's big cooldown goes up this long before they taunt; a "Tank swap" row is that press
local SMASH_CLEAR = 4	-- a swap with a smash landing from the press to this long after the taunt waits up to this much longer,
local RETRY_ROOM = 9	-- but always leaving this long before the next punch: a taunt's 8s cooldown and a second to retry a miss
-- no new cooldown on the outgoing tank this close to their swap, or after it: even the shortest would be mostly wasted
local SWAP_QUIET = 4

local BANG_LANDS = 8	-- Big Bang's cast (its damage lands 7.98s after the cast starts, in the logs)
local punches, smashCasts, bangCasts = {}, {}, {}
do
	local nextPunch, nextSmash, nextBang = 15.5, 26, 90
	while true do
		local t = math.min(nextPunch, nextSmash, nextBang)
		if t >= FIGHT then break end
		if t == nextBang then
			bangCasts[#bangCasts + 1] = t
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

-- when each Cosmic Smash lands; the last cast, at 5:58.5, would land after Ascend ends the fight
function CP.SmashTimes(from, stop)
	local out = {}
	for _, c in ipairs(smashCasts) do
		local t = c + SMASH_LANDS
		if t >= from and t < stop and t < FIGHT then out[#out + 1] = t end
	end
	return out
end

-- Star kill zones {from, to, index, kills} overlapping from..stop, one per smash gap: 7s to 18.5s after a Cosmic
-- Smash lands (healers have topped the raid from it; the explosion stays 7s clear of the next smash). In a gap a Big
-- Bang lands in, the zone starts 5s after the landing if it still fits, else ends 3s before the landing: inside the
-- cast is fine (Big Bang only kills the unphased, whatever their health) and the dying star leaves a Black Hole for
-- it, and ending well before the landing pushes the kill early in the cast. A zone holding a summon opens at it,
-- since a kill before would be replaced at once. index counts gaps with room, from the pull. A gap whose star would only be killed a few seconds before it runs out on its own gets no zone
-- but a marker at that moment, {from = to = the run-out, expires = true}: let it go.
local SAFE_FROM, SAFE_TO, BANG_AFTER, BANG_BEFORE = 7, 18.5, 5, 3
-- a zone that ends before a Big Bang lands slides this much sooner, though it then starts 5s after the smash: the star
-- dies earlier in the cast, with more time to use its Black Hole
local BANG_SLIDE = 2
local STAR_FIRST, STAR_EVERY, STAR_LIFE = 16.5, 60, 100
local EXPIRES = "expires"
-- Stars to kill in each zone, by index. Stars refill to 4 every 60s and each runs out 100s after it spawns, so a kill
-- before a summon is replaced at once and one after it waits a minute. Laid out on the planner (Star kill planner
-- artifact) and searched for the fewest doubles: one kill a zone, using Big Bang gaps 1 and 2, the second right
-- after its summon. In gaps 4 and 11 the star is down to a few percent and runs out at 1:56.5 and 4:56.5, 9s or more
-- from a smash: EXPIRES. Gap 6's star would run out at 2:56.5, 4s before the second Big Bang starts casting: killed
-- instead, in a short zone ZONE_AT gives (from and to after the smash) that ends a second before then. Nothing in gap
-- 3; none past 5:05: a pull still in phase 1 there can't reach 20% before the 6:00 Ascend.
local STAR_KILLS = {1, 1, 1, EXPIRES, 1, 1, 1, 1, 1, 0, EXPIRES}
local ZONE_AT = {[6] = {9, 17}}
CP.STAR_SECOND = 8 -- a zone's second kill this long after its first: two explosions healers can take apart
function CP.SafeWindows(from, stop)
	local out, sm, n = {}, CP.SmashTimes(-1, stop + SMASH * 2), 0
	for i = 1, #sm - 1 do
		local a, b = sm[i] + SAFE_FROM, sm[i] + SAFE_TO
		local land = CP.BangTimes(sm[i], sm[i + 1])[1]
		if land then
			if math.max(a, land + BANG_AFTER) < b then
				a = math.max(a, land + BANG_AFTER)
			else
				a, b = a - BANG_SLIDE, math.min(b, land - BANG_BEFORE) - BANG_SLIDE
			end
		end
		if a < b then
			for k = 0, 9 do
				local summon = STAR_FIRST + STAR_EVERY * k
				if summon > a and summon < b then a = summon end
			end
			n = n + 1
			local kills = STAR_KILLS[n]
			if ZONE_AT[n] then a, b = sm[i] + ZONE_AT[n][1], sm[i] + ZONE_AT[n][2] end
			if kills == EXPIRES then
				for k = 0, 9 do
					local out_at = STAR_FIRST + STAR_EVERY * k + STAR_LIFE
					if out_at > sm[i] and out_at < sm[i + 1] and out_at > from and out_at < stop then
						out[#out + 1] = {from = out_at, to = out_at, index = n, kills = 0, expires = true}
					end
				end
			elseif kills and kills > 0 and b > from and a < stop then
				out[#out + 1] = {from = a, to = b, index = n, kills = kills}
			end
		end
	end
	return out
end

-- The mock fight has no stars: the plan's kills played on stars refilling to 4 every 60s from 16.5, the oldest
-- dying first and ties to the first bar, as the raid leader's picks would come out. Marks are the star bars'
-- (Algalon.lua's STAR_MARKS: square, moon, triangle, diamond).
local STAR_MARKS = {6, 5, 4, 3}
local MOCK_BURN = 12
-- Picks known before any star spawns: zones 1-4 kill the opening wave, all the same age, whose bars are its spawn
-- points (Algalon.lua's placeOpening): square (south-east), moon (north-east), triangle (north-west), diamond
CP.FIXED_STAR_PICKS = {[1] = {6}, [2] = {5}, [3] = {4}, [4] = {3}}
function CP.MockStarPicks()
	local picks, rows, ev = {}, {}, {}
	for i = 0, 6 do ev[#ev + 1] = {t = 16.5 + 60 * i} end
	for _, w in ipairs(CP.SafeWindows(0, 400)) do
		for k = 1, w.kills or 0 do ev[#ev + 1] = {t = w.from + CP.STAR_SECOND * (k - 1), w = w, k = k} end
	end
	-- a summon before a kill at the same moment, as a zone opening at a summon means
	table.sort(ev, function(a, b) if a.t ~= b.t then return a.t < b.t end return not a.w and b.w ~= nil end)
	local expiries = {}
	for _, w in ipairs(CP.SafeWindows(0, 400)) do if w.expires then expiries[#expiries + 1] = w end end
	for _, e in ipairs(ev) do
		for i = 1, 4 do
			if rows[i] and rows[i] + 100 <= e.t then
				for _, w in ipairs(expiries) do
					if math.abs(rows[i] + 100 - w.from) < 0.5 then
						picks[w.index] = {{mark = STAR_MARKS[i], born = rows[i], at = not CP.FIXED_STAR_PICKS[w.index] and math.max(w.from - 30, rows[i]) or nil}}
					end
				end
				rows[i] = nil
			end
		end
		if not e.w then
			for i = 1, 4 do rows[i] = rows[i] or e.t end
		else
			local pick
			for i = 1, 4 do if rows[i] and (not pick or rows[i] < rows[pick]) then pick = i end end
			if pick then
				-- the mock raid hits the star over the MOCK_BURN before its zone just hard enough that it would die
				-- by itself mid-zone, then leaves it: the natural death tick comes in and settles there
				local mid, born = (e.w.from + e.w.to) / 2, rows[pick]
				picks[e.w.index] = picks[e.w.index] or {}
				picks[e.w.index][e.k] = {mark = STAR_MARKS[pick], born = born, at = not CP.FIXED_STAR_PICKS[e.w.index] and math.max(e.w.from - 30, born) or nil,
					burnFrom = e.w.from - MOCK_BURN, burnRate = math.max(0, (born + 100 - mid) / MOCK_BURN)}
				rows[pick] = nil
			end
		end
	end
	return picks
end

-- A picked star's health % at plan time t: the star's own (CP.StarHP(mark), set by the boss mod while there are
-- stars), else the mock fight's: 1%/s from its spawn plus the mock raid's burn, and none before it spawns (a fixed
-- pick shows from the pull), as in a pull with no star to read yet
function CP.PickHP(p, t)
	local hp = CP.StarHP and CP.StarHP(p.mark)
	if hp or not p.born or t < p.born then return hp end
	return 100 - (t - p.born) - (p.burnRate or 0) * math.min(math.max(t - (p.burnFrom or t), 0), MOCK_BURN)
end

-- a pick's star has died: synced deaths mark it (Algalon.lua), the mock fight's die when their health runs out
local function pickGone(p, t)
	if p.gone then return true end
	if p.born and not (CP.StarHP and CP.StarHP(p.mark)) then return (CP.PickHP(p, t) or 1) <= 0 end
	return false
end

-- the zones and markers still to come at plan time t: one whose stars have all died is done, so it goes
function CP.LiveWindows(from, stop, t)
	local out = {}
	for _, w in ipairs(CP.SafeWindows(from, stop)) do
		local picks, left = CP.StarKillPicks[w.index] or {}, false
		for k = 1, math.max(w.kills, 1) do
			if not picks[k] or not pickGone(picks[k], t) then left = true end
		end
		if left then out[#out + 1] = w end
	end
	return out
end

-- when each Big Bang lands
function CP.BangTimes(from, stop)
	local out = {}
	for _, c in ipairs(bangCasts) do
		local t = c + BANG_LANDS
		if t >= from and t < stop then out[#out + 1] = t end
	end
	return out
end
CP.SMASH_CAST, CP.BANG_CAST = SMASH_LANDS, BANG_LANDS

local function round(t) return math.floor(t * 2 + 0.5) / 2 end

local PLAYER_GAP = 10	-- least time between two planned presses by one player: time to read the card and press
local GAP_OK = 1	-- a hole this short before a planned cooldown isn't worth spending another on
-- a variation tries each smash with a raid-wide cooldown on the tank this long before it lands (mid-buff for the 6s
-- Divine Sacrifice, so a press up to 3s off still covers it). 0.4 of smashes: over 49 sample rosters it took smashes
-- covered from 17 to 111 of 637 with tank time no worse; 0.7 started costing tank time
local SMASH_LEAD, SMASH_TRY = 3, 0.4

-- A plan for the rest of the fight from fight time opts.from, as rows like CP.Parse's.
-- opts.pool: {player, spell, dur, cd, readyAt (fight time), role = "big"|"self"|"ext", raid} per cooldown;
-- opts.tanks: the two tanks, opts.tank: which of them has the boss at opts.from (default 1);
-- opts.covered: [tank] = fight time their current cooldown runs to (default from);
-- opts.running: {tank, from, to} per cast still up at opts.from, which nothing new may overlap;
-- opts.used: [pool index] = fight times it was already used (so it isn't planned again too soon);
-- opts.swaps: expected swap times (default CP.SwapTimes); opts.stop (default FIGHT);
-- opts.weaker: the tank to fill first, so the shared externals go to them before the stronger tank.
-- In order: each tank's big cooldown at the pull and at each swap-in; the rest of each tank's time filled with
-- real cooldowns, the tank's own before shared ones, unused longest first; then trinkets, too weak to count as
-- cover, into their owner's holes and next to their owner's weakest cooldowns. Nothing is planned for Cosmic
-- Smash: the strip shows where each lands instead. Returns rows, problems, score.
-- A non-tank paladin's Hand of Sacrifice goes up under a bubble, which takes the damage it passes to them (immune
-- damage still counts toward the hand's cap, so it ends as it would). Divine Shield (all schools) where raid damage
-- lands while it's up, a Cosmic Smash or a planned star kill, so it covers the paladin from that too; else Hand of
-- Protection (physical, as Algalon's melee and Quantum Strike are), keeping Divine Shield for that. The planner
-- reserves one this way and the card names it the same way from the paladin's real cooldowns.
CP.BUBBLE_FULL, CP.BUBBLE_PHYS = "Divine Shield", "Hand of Protection" -- localized at load
-- Forbearance's group (spell_pal_immunities, cast on themselves): Divine Shield, Hand of Protection and Divine
-- Protection each keep all three off for 2 minutes. Avenging Wrath's marker (61987) does the same for 30s, unseen; it
-- isn't planned, it's pressed on a paladin's own schedule, so a cast re-plans what of theirs it locks (liveUse). Lay on
-- Hands only joins on themselves, which the plan never does; Hand of Sacrifice never does.
CP.SHIELD_GUARD, CP.WRATH, CP.LAY_ON_HANDS = "Divine Protection", "Avenging Wrath", "Lay on Hands" -- localized at load
-- Hand of Salvation sheds threat while it's up (glyphed or not): not the opening tank's first cooldown after their pull
-- one, while they're still building threat
CP.SALVATION = "Hand of Salvation" -- localized at load
local FORBEARANCE, WRATH_LOCK = 120, 30
local function forbearing(spell) return spell == CP.BUBBLE_FULL or spell == CP.BUBBLE_PHYS or spell == CP.SHIELD_GUARD end
local function raidDanger(a, b)
	if CP.SmashTimes(a, b)[1] then return true end
	for _, w in ipairs(CP.SafeWindows(a, b)) do
		if not w.expires and (w.kills or 0) > 0 then return true end
	end
	return false
end
-- Hand of Sacrifice ends once it has passed on its caster's health (spell_pal_hand_of_sacrifice_aura): in the raid's
-- logs it lasted 6-10s on a 25-man tank, not 12, and longer on a 10-man tank, who takes less. Booked flat, overlap
-- on the long side rather than a gap on the short one: benched 8, 9 and 10s, longer bookings only looked better
-- (and left gaps when hands ended early)
local function sacBooked(pool, small)
	local out
	for i, c in ipairs(pool) do
		if c.notSelf then
			out = out or {unpack(pool)}
			local copy = {}
			for k, v in pairs(c) do copy[k] = v end
			copy.dur = math.min(c.dur, small and 10 or 8)
			out[i] = copy
		end
	end
	return out or pool
end

-- which bubble for a hand at fight time t, given which are ready: CP.BUBBLE_FULL, CP.BUBBLE_PHYS or nil
function CP.BubbleFor(t, fullReady, physReady)
	local BUBBLE_DUR = 12
	if fullReady and (raidDanger(t, t + BUBBLE_DUR) or not physReady) then return CP.BUBBLE_FULL end
	if physReady then return CP.BUBBLE_PHYS end
end

-- A tank whose big cooldown can't be back for each of their swap-ins (Survival Instincts' 3 minutes, against a swap-in
-- every 2:12 or so) swaps on their own cooldown that's back within a minute and nearly as strong (Barkskin) instead:
-- it's there for every swap, and the big one is free to fill. A pool with the roles swapped where that holds (copies;
-- same order, so opts.used still lines up). swapIn: the shortest time between one tank's swap-ins.
local function swapRoles(pool, swapIn)
	local SWAP_SHORT_CD, SWAP_SHORT_GAP = 60, 5
	local bigOf = {}
	for _, c in ipairs(pool) do
		if c.role == "big" and (not bigOf[c.player] or (c.power or 0) > (bigOf[c.player].power or 0)) then bigOf[c.player] = c end
	end
	local short = {}
	for _, c in ipairs(pool) do
		local big = bigOf[c.player]
		if big and big.cd > swapIn and c.role == "self" and not c.trinket and not c.raid and c.cd <= SWAP_SHORT_CD
			and (c.power or 0) + SWAP_SHORT_GAP >= (big.power or 0) then short[c.player] = c end
	end
	if not next(short) then return pool end
	local out = {}
	for i, c in ipairs(pool) do
		local s = short[c.player]
		if s and (c == s or c.role == "big") then
			local copy = {}
			for k, v in pairs(c) do copy[k] = v end
			copy.role = c == s and "big" or "self"
			out[i] = copy
		else
			out[i] = c
		end
	end
	return out
end

local function build(opts, rng, smashRng)
	local from, stop = opts.from or 0, opts.stop or FIGHT
	local swaps = opts.swaps or CP.SwapTimes(from, stop)
	local tanks, tank = opts.tanks, opts.tank or 1
	local covered = opts.covered or {}
	local swapIn = math.huge
	for k = 3, #swaps do swapIn = math.min(swapIn, swaps[k] - swaps[k - 2]) end
	local pool = sacBooked(opts.swapShort and swapRoles(opts.pool, swapIn) or opts.pool, opts.small)
	local rows, problems, uncovered, holes = {}, {}, 0, {}
	local bigMissed = 0
	local uses = {}	-- [i] = fight times planned or used
	local trinketByPool, bigByPool, raidByPool = {}, {}, {}
	for _, c in ipairs(pool) do
		if c.trinket then trinketByPool[c.player .. "\0" .. c.spell] = true end
		if c.raid then raidByPool[c.player .. "\0" .. c.spell] = true end
		if c.role == "big" then bigByPool[c.player .. "\0" .. c.spell] = true end
	end
	for i in ipairs(pool) do
		uses[i] = {}
		for _, t in ipairs(opts.used and opts.used[i] or {}) do uses[i][#uses[i] + 1] = t end
	end

	local gap = opts.playerGap or PLAYER_GAP
	-- player's Forbearance group (forbearing) locked at t: another of it within 2 minutes either way (one at t would
	-- lock the later one too), or their Avenging Wrath in the 30s before. self: the pool index asked about, whose own
	-- cooldown is free()'s to check
	local function locked(player, t, self)
		for k, o in ipairs(pool) do
			if k ~= self and o.player == player and forbearing(o.spell) then
				for _, u in ipairs(uses[k]) do if math.abs(t - u) < FORBEARANCE then return true end end
			end
		end
		for _, u in ipairs(opts.wrath and opts.wrath[player] or {}) do
			if t >= u and t - u < WRATH_LOCK then return true end
		end
		for _, u in ipairs(opts.forbear and opts.forbear[player] or {}) do -- cast before a re-plan: CP.Replan
			if math.abs(t - u) < FORBEARANCE then return true end
		end
		return false
	end
	local function free(i, t)
		local c = pool[i]
		if (c.readyAt or 0) > t then return false end
		for _, u in ipairs(uses[i]) do
			if math.abs(t - u) < c.cd then return false end
		end
		if forbearing(c.spell) and locked(c.player, t, i) then return false end -- a paladin tank's Divine Protection
		-- two trinkets pressed together is a lot at once for a tank; up together, or back to back, is fine
		if c.trinket then
			for j, o in ipairs(pool) do
				if j ~= i and o.trinket and o.player == c.player then
					for _, u in ipairs(uses[j]) do
						if math.abs(t - u) < gap then return false end
					end
				end
			end
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
	for _, x in ipairs(opts.running or {}) do -- casts still up from before opts.from (CP.Replan)
		fixed[x[1]] = fixed[x[1]] or {}
		table.insert(fixed[x[1]], {x[2], x[3]})
	end
	local isTank = {}
	for _, n in ipairs(tanks) do isTank[n] = true end
	-- the bubble a non-tank's Hand of Sacrifice at t goes up under (its pool index), true when it needs none (a tank
	-- casting it), nil when neither is free: each its own cooldown, outside the caster's Forbearance lock
	local function bubble(i, t)
		local c = pool[i]
		if not c.notSelf or isTank[c.player] then return true end
		local full, phys
		for j, b in ipairs(pool) do
			if b.player == c.player and b.role == "bubble" then
				local ok = (b.readyAt or 0) <= t and not locked(c.player, t, j)
				for _, u in ipairs(uses[j]) do if math.abs(t - u) < b.cd then ok = false end end
				if ok and b.spell == CP.BUBBLE_FULL then full = j elseif ok then phys = j end
			end
		end
		local pick = CP.BubbleFor(t, full ~= nil, phys ~= nil)
		return pick == CP.BUBBLE_FULL and full or pick and phys or nil
	end
	local raidOn = {}	-- [who] = {{from, to}} of raid-wide cooldowns on them
	local function use(i, t, who, note)
		local c = pool[i]
		local b = bubble(i, t)
		if type(b) == "number" then table.insert(uses[b], t) end -- reserved: no row, the card names it
		if c.smashOnly then who = nil end -- the raid's, not the tank's
		rows[#rows + 1] = {time = round(t), player = c.player, spell = c.spell, dur = c.dur, target = who, note = note, power = c.power}
		table.insert(uses[i], t)
		if who and not c.trinket then -- a trinket isn't cover: it goes up beside cooldowns, never instead of them
			fixed[who] = fixed[who] or {}
			table.insert(fixed[who], {t, t + c.dur})
			if c.raid then raidOn[who] = raidOn[who] or {} table.insert(raidOn[who], {t, t + c.dur}) end
		end
	end
	-- a raid-wide cooldown right before or after another on the same tank: two Divine Sacrifices back to back read
	-- as one block on the strip
	local function besideRaid(who, a, b)
		for _, f in ipairs(raidOn[who] or {}) do
			if math.abs(f[2] - a) < 0.01 or math.abs(f[1] - b) < 0.01 then return true end
		end
		return false
	end
	-- does who already have cover somewhere in [a, b)
	local function covers(who, a, b)
		for _, f in ipairs(fixed[who] or {}) do
			if f[1] < b - 0.01 and f[2] > a + 0.01 then return true end
		end
		return false
	end
	local function usable(c, who)
		-- Hand of Sacrifice can't go on its caster; Lay on Hands on its caster puts Forbearance on them
		-- (spell_pal_lay_on_hands), locking a paladin tank's own Divine Protection
		if c.role == "ext" then return not ((c.notSelf or c.spell == CP.LAY_ON_HANDS) and c.player == who) end
		return c.player == who
	end

	-- who has the boss when
	local starts = {from == 0 and PULL_PRESS or from}
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
	local keptSwap = {}
	for _, r in ipairs(opts.keep or {}) do
		for i, c in ipairs(pool) do
			if c.player == r.player and c.spell == r.spell then
				-- not one Forbearance now forbids (the paladin bubbled or pressed Avenging Wrath since): it's planned afresh
				if bubble(i, r.time) == nil or forbearing(c.spell) and locked(c.player, r.time, i) then break end
				use(i, r.time, r.target, r.note)
				if c.role == "big" or r.note == "Tank swap" then keptSwap[#keptSwap + 1] = r end -- the pull's or a swap's, big or the fallback
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
				-- the longest one ready; one that heals as it goes up (Lay on Hands) only when nothing near as strong is: the
				-- tank coming in is at full health, and later in their stint its heal lands on damage
				local NEAR, heal = 5, nil
				for i, c in ipairs(pool) do
					if usable(c, who) and c.role ~= "bubble" and not c.raid and not c.trinket and free(i, press) and bubble(i, press) and not covers(who, press, press + c.dur) then
						if c.heals then
							if not heal or c.dur > pool[heal].dur then heal = i end
						elseif not pick or c.dur > pool[pick].dur then
							pick = i
						end
					end
				end
				if heal and (not pick or (pool[pick].power or 0) + NEAR < (pool[heal].power or 0)) then pick = heal end
				problems[#problems + 1] = ("%s has no big cooldown ready at %s"):format(who, s > 1 and ("the swap at " .. round(at) .. "s") or "the pull")
				bigMissed = bigMissed + 1
			end
			if pick then use(pick, press, who, s > 1 and "Tank swap" or nil) end
		end
	end
	-- 2: a variation puts some raid-wide cooldowns (Divine Sacrifice) on the tank with the boss SMASH_LEAD before a
	-- Cosmic Smash lands, where they fit: cover for the tank that also takes the raid through the smash. The score
	-- keeps that only where the tanks lose nothing by it.
	if smashRng then
		for _, hit in ipairs(CP.SmashTimes(from + SMASH_LEAD, stop)) do
			if smashRng() < SMASH_TRY then
				local who, at = holderAt(hit), hit - SMASH_LEAD
				for i, c in ipairs(pool) do
					if c.raid and not c.smashOnly and free(i, at) and not covers(who, at, at + c.dur) and not besideRaid(who, at, at + c.dur) then
						use(i, at, who)
						break
					end
				end
			end
		end
	end
	-- 3: the rest of each tank's time, the weaker tank's stints first. A big cooldown (2 minutes or more) goes up only
	-- where most of it lands on the tank with the boss: three quarters of it before the swap at least, so none is
	-- spent for a few seconds' cover. Over 1200 sample rosters it cost no bare tank time; shorter ones run on freely
	local BIG_CD, BIG_ON_HOLDER = 120, 0.75
	local order = {}
	for s in ipairs(starts) do if holder(s) == opts.weaker then order[#order + 1] = s end end
	for s in ipairs(starts) do if holder(s) ~= opts.weaker then order[#order + 1] = s end end
	for _, s in ipairs(order) do
		local segStart = starts[s]
		local who, swapAt = holder(s), starts[s + 1]
		local segEnd = math.min(swapAt or stop, stop)
		local c = math.max(segStart, covered[who] or segStart)
		local opening = from == 0 and s == 1 -- the pull's stint, its tank's first cooldown after the pull's still to come
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
					-- only what ends before the next planned cover: cooldowns on one tank never overlap
					-- a big one too (Barkskin as a bear's swap cooldown): its swaps are planned already, and free() keeps
					-- it clear of them
					if cd.role ~= "bubble" and not cd.smashOnly and not cd.trinket and usable(cd, who) and bubble(i, c) and c + cd.dur <= (nextFixed or math.huge) + 0.01
						and not (opening and cd.spell == CP.SALVATION)
						and not (cd.raid and besideRaid(who, c, c + cd.dur))
						and (not swapAt or cd.cd < BIG_CD or math.min(c + cd.dur, swapAt) - c >= BIG_ON_HOLDER * cd.dur - 0.01) then
						if free(i, c) then
							local last = -math.huge
							for _, u in ipairs(uses[i]) do if u < c and u > last then last = u end end
							local idle = rng and rng() or c - last -- a variation tries them in any order
							-- raid-wide ones (6s) only when nothing else is up, unless a Cosmic Smash lands inside them: then
							-- first, as they cover the raid too (over 49 sample rosters: smashes covered 55 to 78 of 637
							-- for 0.2s more bare tank time a fight); then the tank's own before shared ones, which the other
							-- tank could have used
							local rank = cd.raid and 2 or cd.role == "ext" and 1 or 0
							if cd.raid and CP.SmashTimes(c + 0.5, c + cd.dur - 0.5)[1] then rank = -1 end
							if rng and rng() < 0.3 then rank = 0 end -- a variation sometimes spends what it'd normally save
							-- one still running at the incoming tank's press overlaps it: only when nothing else fits
							if swapAt and c + cd.dur > swapAt - SWAP_LEAD + 0.01 then rank = rank + 3 end
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
					opening = false
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
	-- 4: trinkets (weak, ~10%) aren't cover on their own: first into their owner's holes, since something beats nothing,
	-- then up with their owner's weakest cooldowns. A trinket's uses are chosen together, for the most of its owner's bare
	-- time covered: each start a hole's or ending as a hole ends, and of the sets a cooldown apart the one covering most
	-- (a DP over the starts in order). Over 698 sample rosters it never covered less than each hole longest first, and
	-- covered more on a third of them
	for i, c in ipairs(pool) do
		if c.trinket then
			-- the owner's holes less what their other trinkets already cover, so a second one goes after bare time
			-- (starting as the first one ends, say) rather than onto the first
			local left = {}
			for _, h in ipairs(holes) do
				if h[1] == c.player then
					local parts = {{h[2], h[3]}}
					for j, o in ipairs(pool) do
						if j ~= i and o.trinket and o.player == c.player then
							for _, u in ipairs(uses[j]) do
								local cut = {}
								for _, p in ipairs(parts) do
									if u >= p[2] or u + o.dur <= p[1] then cut[#cut + 1] = p
									else
										if u > p[1] then cut[#cut + 1] = {p[1], u} end
										if u + o.dur < p[2] then cut[#cut + 1] = {u + o.dur, p[2]} end
									end
								end
								parts = cut
							end
						end
					end
					for _, p in ipairs(parts) do left[#left + 1] = p end
				end
			end
			local starts, seen = {}, {}
			for _, h in ipairs(left) do
				for _, s in ipairs({h[1], h[2] - c.dur}) do
					if not seen[s] and s >= from and s < stop and free(i, s) and worthIt(c, s) then
						seen[s] = true
						local cover = 0
						for _, g in ipairs(left) do cover = cover + math.max(0, math.min(g[2], s + c.dur) - math.max(g[1], s)) end
						if cover > 0 then starts[#starts + 1] = {s, cover} end
					end
				end
			end
			table.sort(starts, function(x, y) return x[1] < y[1] end)
			local best, take = {[0] = 0}, {}
			for k = 1, #starts do
				local p = 0 -- the last start a cooldown or more before this one
				for j = k - 1, 1, -1 do if starts[k][1] - starts[j][1] >= c.cd then p = j break end end
				local with = starts[k][2] + best[p]
				if with > best[k - 1] then best[k], take[k] = with, p else best[k], take[k] = best[k - 1], nil end
			end
			local k, picked = #starts, {}
			while k > 0 do
				if take[k] then picked[#picked + 1] = starts[k][1] k = take[k] else k = k - 1 end
			end
			for n = #picked, 1, -1 do use(i, picked[n], c.player) end
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
	-- counted from the finished plan, so trinkets paired late still shrink the holes they run into
	local trinketOnly = 0
	table.sort(holes, function(a, b) return a[2] < b[2] end)
	for _, h in ipairs(holes) do
		-- every trinket over the hole, wherever it starts in it: the parts they cover are trinket-only, the rest bare
		local spans = {}
		for _, r in ipairs(rows) do
			if r.target == h[1] and trinketByPool[r.player .. "\0" .. r.spell] then
				local a, b = math.max(h[2], r.time), math.min(h[3], r.time + r.dur)
				if b > a then spans[#spans + 1] = {a, b} end
			end
		end
		table.sort(spans, function(x, y) return x[1] < y[1] end)
		local c = h[2]
		local function bare(to)
			problems[#problems + 1] = ("nothing up on %s from %gs to %gs"):format(h[1], round(c), round(to))
			uncovered = uncovered + to - c
		end
		for _, sp in ipairs(spans) do
			if sp[1] > c then bare(sp[1]) c = sp[1] end
			if sp[2] > c then trinketOnly = trinketOnly + sp[2] - c c = sp[2] end
		end
		if c < h[3] then bare(h[3]) end
	end
	-- and the smashes landing with no raid-wide cooldown up: last, so it only decides between plans as good for the tanks
	local smashBare = 0
	for _, hit in ipairs(CP.SmashTimes(from, stop)) do
		local has = false
		for _, r in ipairs(rows) do
			if raidByPool[r.player .. "\0" .. r.spell] and r.time <= hit and hit < r.time + r.dur then has = true break end
		end
		if not has then smashBare = smashBare + 1 end
	end
	-- worst first: a swap without its big cooldown, tank time with nothing up, tank time with only a trinket,
	-- a smash with no raid-wide cooldown up (also counted into the tank time at CP.SMASH_COST when compared: better)
	return rows, problems, {bigMissed, round(uncovered), round(trinketOnly), smashBare}
end

local TRIES = 40	-- variations tried on top of the plain build, keeping the best
local SMASH_TRIES = 20	-- and variations that also try raid-wide cooldowns on smashes (step 2), on their own random numbers
-- a smash landing with no raid-wide cooldown up costs this many seconds of bare tank time when plans are compared:
-- a plan may give the tanks up to 3s more bare time to cover one more smash (the raid's call, over 698 sample rosters:
-- with the trinkets placed as above, still less bare tank time than before and a smash in ten more covered)
CP.SMASH_COST = 3
local function better(a, b)
	local w = CP.SMASH_COST
	local ka, kb = {a[1], a[2] + w * a[4], a[3], a[4]}, {b[1], b[2] + w * b[4], b[3], b[4]}
	for i = 1, #ka do
		if ka[i] ~= kb[i] then return ka[i] < kb[i] end
	end
	return false
end

-- The plain build and TRIES variations of it, then SMASH_TRIES that also try raid-wide cooldowns on smashes: those
-- draw their own random numbers, so the first TRIES are the same whatever they find and can only be bettered. The best
-- by build's score wins, the plainest of equals. Seeded, so a roster always gives the same plan.
local function seeded(seed)
	return function()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
end
local function generateOnce(opts, tries)
	local rng, smashRng, best, bestProblems, bestScore = seeded(12345), seeded(54321)
	local function try(r, s)
		local rows, problems, score = build(opts, r, s)
		if not best or better(score, bestScore) then best, bestProblems, bestScore = rows, problems, score end
	end
	for n = 0, tries or TRIES do try(n > 0 and rng or nil) end
	for _ = 1, tries and math.floor(tries / 2) or SMASH_TRIES do try(rng, smashRng) end
	return best, bestProblems, bestScore
end

-- opts.small (a 10-man): the plan is made both with and without a tank's short cooldown at their swaps (swapRoles:
-- Barkskin rather than Survival Instincts), and the one with less bare time wins (a bare smash counted in at
-- CP.SMASH_COST), then less trinket-only time. A swap
-- on Barkskin and one on an external are what's being weighed, so the swaps-without-a-big-cooldown count doesn't
-- decide. A 25-man swaps on the big one: if it's short of cooldowns, that's the raid's to fix.
function CP.Generate(opts, tries)
	if not opts.small then return generateOnce(opts, tries) end
	local with = setmetatable({swapShort = true}, {__index = opts})
	local a = {generateOnce(with, tries)}
	local b = {generateOnce(opts, tries)}
	local ca, cb = a[3][2] + CP.SMASH_COST * a[3][4], b[3][2] + CP.SMASH_COST * b[3][4]
	if ca ~= cb then return unpack(ca < cb and a or b) end
	return unpack(a[3][3] <= b[3][3] and a or b)
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
	local keep, covered, last, running = {}, {}, {}, {}
	local trinket = {}
	for _, c in ipairs(opts.pool) do if c.trinket then trinket[c.player .. "\0" .. c.spell] = true end end
	local function used(player, spell, t, target, dur)
		local key = player .. "\0" .. spell
		if not last[key] or t > last[key] then last[key] = t end
		if target and dur then covered[target] = math.max(covered[target] or 0, t + dur) end
		-- still up past the re-plan: real cover the new rows must not land on (a trinket isn't cover)
		if target and dur and t + dur > now + LOCK and not trinket[key] then running[#running + 1] = {target, t, t + dur} end
	end
	for _, u in ipairs(opts.uses) do used(u.player, u.spell, u.time, u.target, u.dur) end
	for _, r in ipairs(opts.rows) do
		if r.time < now then
			keep[#keep + 1] = r
			-- not pressed yet but not a no-show either (a late press still matches it): its cooldown is spoken for
			if not r.done and not r.missed and r.time > now - MATCH and not dead[r.player] then
				used(r.player, r.spell, r.time, r.target, r.dur)
			end
		elseif r.time < now + LOCK and not dead[r.player] then
			keep[#keep + 1] = r
			used(r.player, r.spell, r.time, r.target, r.dur)
		end
	end
	local pool = {}
	for _, c in ipairs(opts.pool) do
		if not dead[c.player] then
			local key = c.player .. "\0" .. c.spell
			local readyAt, back = c.readyAt or 0, opts.back and opts.back[key]
			-- its owner's word after the use beats use + cooldown: the server can cut one short
			if last[key] then readyAt = math.max(readyAt, back and back.at > last[key] and back.readyAt or last[key] + c.cd) end
			if missed[key] then readyAt = math.max(readyAt, missed[key] + NOSHOW_WAIT) end
			pool[#pool + 1] = {player = c.player, spell = c.spell, dur = c.dur, cd = c.cd, power = c.power, role = c.role, raid = c.raid, trinket = c.trinket, smashOnly = c.smashOnly, notSelf = c.notSelf, heals = c.heals, readyAt = readyAt}
		end
	end
	local from, tank = now + LOCK, opts.tank or 1
	local swaps = {}
	for _, t in ipairs(opts.swaps or CP.SwapTimes(now, opts.stop or FIGHT)) do
		if t <= from then tank = tank % #opts.tanks + 1 else swaps[#swaps + 1] = t end -- a swap inside the lock
	end
	local alive = 0
	for _, t in ipairs(opts.tanks) do if not dead[t] then alive = alive + 1 end end
	if alive < 2 then swaps = {} end -- one tank left keeps the boss: no one to swap with
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
	-- each paladin's Avenging Wrath casts (no bubble for 30s after one) and Forbearance group casts (none of the
	-- group for 2 minutes): what each lock needs beyond the cast cooldown's own readiness
	local wrath, forbear = {}, {}
	for _, u in ipairs(opts.uses) do
		local into = u.spell == CP.WRATH and wrath or forbearing(u.spell) and forbear
		if into then into[u.player] = into[u.player] or {} table.insert(into[u.player], u.time) end
	end
	local rows, problems = CP.Generate({pool = pool, tanks = tanks, tank = tank, covered = covered, running = running, from = from, stop = opts.stop, swaps = swaps, keep = carry, weaker = opts.weaker, small = opts.small, wrath = wrath, forbear = forbear})
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
function CP.Card(rows, player, t)
	local card = {}
	-- a swap's cooldown and its taunt (CP.Taunts) are one step: the taunt shows under the cooldown as "then Taunt"
	-- until the cooldown is cast, then takes the big line; once the taunt is due it takes it anyway, and the
	-- cooldown drops off. A taunt with no cooldown of mine before it (an external on my swap-in) stands alone
	local pairOf, paired = {}, {}
	for _, r in ipairs(rows) do
		if r.taunt and r.player == player then
			for _, c in ipairs(rows) do
				if c.player == player and c.note == "Tank swap" and math.abs(c.time + SWAP_LEAD - r.time) < 0.01 then
					pairOf[r], paired[c] = c, r
				end
			end
		end
	end
	-- two of mine pressed together (a trinket "with" a cooldown): one step too, the trinket under the cooldown as
	-- "then <trinket>" until the cooldown is cast (or its press is past), then on the big line
	local withOf, along = {}, {}
	for _, r in ipairs(rows) do
		if r.player == player and r.note and r.note:sub(1, 5) == "with " then
			for _, c in ipairs(rows) do
				if c.player == player and c ~= r and math.abs(c.time - r.time) < 0.01 and r.note == "with " .. c.spell then
					withOf[r], along[c] = c, r
				end
			end
		end
	end
	local function shown(r)
		if r.player ~= player or r.done then return false end
		if paired[r] and t >= paired[r].time then return false end
		if pairOf[r] and not pairOf[r].done and t < r.time then return false end
		if withOf[r] and not withOf[r].done and t < r.time + MATCH then return false end
		return true
	end
	for _, r in ipairs(rows) do
		if shown(r) then
			local due = r.time
			local now = due <= t and due >= t - MATCH
			if r.taunt and pairOf[r] and pairOf[r].done and t <= r.time + MATCH then now = true end
			if now and (not card.go or r.taunt) then card.go = r end
		end
	end
	for _, r in ipairs(rows) do
		if shown(r) and r ~= card.go then
			local due = r.time
			if due >= t then
				if not card.next or due < card.nextIn + t then
					card.later, card.laterIn = card.next, card.nextIn
					card.next, card.nextIn = r, due - t
				elseif not card.later or due < card.laterIn + t then
					card.later, card.laterIn = r, due - t
				end
			end
		end
	end
	local top = card.go or card.next
	card.thenTaunt = top and paired[top] and not paired[top].done or nil
	card.thenWith = top and along[top] and not along[top].done and along[top] or nil
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
-- the taunt that goes with each swap-in of player's (the big cooldown's press, then the taunt a second later),
-- for their card, which just says "Taunt"; cast is their class's taunt, to see it done
function CP.Taunts(rows, player, cast)
	local out = {}
	for _, r in ipairs(rows) do
		if r.note == "Tank swap" and r.target == player then
			out[#out + 1] = {time = r.time + SWAP_LEAD, player = player, spell = "Taunt", cast = cast, taunt = true}
		end
	end
	return out
end

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
-- handover (Divine Sacrifice on a tank shows there too), an AoE lane with the raid's damage to come: each
-- Cosmic Smash and Big Bang landing (smashes, bangs: landing times, from a cast back so a cast's ramp sliding
-- in is there), plus any raid-wide cooldown with no tank (a hand-written Aura Mastery), and swaps (taunts). A
-- hole is just empty lane. Blocks keep their real start and end past the view's edges: the strip clips them,
-- so one slides out under the now line instead of shrinking.
-- {lanes = {{name = "Tank", blocks = {{from, to, row}}, tags = {{time, name}}}, {name = "AoE", blocks}},
--  smashes, bangs, swaps, lastSwap = {time, from, to, number} (the latest swap at or before t)}
function CP.Strip(rows, t, span, isRaid)
	local stop = t + span
	local tank, aoe = {name = "Tank", blocks = {}, tags = {}}, {name = "AoE", blocks = {}}
	local strip = {lanes = {tank, aoe}, smashes = CP.SmashTimes(t - SMASH_LANDS, stop + SMASH_LANDS),
		bangs = CP.BangTimes(t - SMASH_LANDS, stop + BANG_LANDS), swaps = {}}
	local uses = {}	-- every use in view, by target
	local taunts = {}
	for _, r in ipairs(rows) do
		local dur = r.dur or CP.Info(r.player, r.spell) or 0
		local due = r.time
		if due < stop and due + dur > t then
			if r.target then
				uses[r.target] = uses[r.target] or {}
				table.insert(uses[r.target], {from = due, to = due + dur, row = r})
			elseif isRaid(r.spell) then
				table.insert(aoe.blocks, {from = due, to = due + dur, row = r})
			end
		end
		-- the taunts from a span back on, whether or not their cooldowns are still in view: the latest one says
		-- whose tag is current long after the press has run out
		if r.note == "Tank swap" and r.time < stop then taunts[#taunts + 1] = r.time + SWAP_LEAD end
	end
	table.sort(taunts)
	-- the swap that just happened, so its tag can finish sliding under the now line
	-- number: a swap's place in the whole plan, not among those in view (which drop off the left), so each tag
	-- keeps one frame and layer from sliding in to settling
	local function numberOf(w)
		local n = 0
		for _, r in ipairs(rows) do
			if r.note == "Tank swap" and r.time + SWAP_LEAD <= w + 0.01 then n = n + 1 end
		end
		return n
	end
	local number = {[1] = numberOf(t)}	-- by edge
	for _, w in ipairs(taunts) do
		if w <= t then strip.lastSwap = {time = w, from = CP.Holder(rows, w - 0.01), to = CP.Holder(rows, w), number = numberOf(w)} end
	end
	-- who has the boss when: from t, then from each taunt in view
	local edges = {t}
	for _, w in ipairs(taunts) do
		if w > t and w < stop then
			edges[#edges + 1] = w
			number[#edges] = numberOf(w)
			strip.swaps[#strip.swaps + 1] = w
		end
	end
	edges[#edges + 1] = stop
	for i = 1, #edges - 1 do
		local a, b = edges[i], edges[i + 1]
		local who = CP.Holder(rows, a)
		tank.tags[#tank.tags + 1] = {time = a, name = who, number = number[i]}
		local mine = uses[who] or {}
		table.sort(mine, function(x, y) return x.from < y.from end)
		-- the next tank's lane starts at their first press before the taunt
		local nextStart = math.huge
		if i < #edges - 1 then
			nextStart = b
			for _, u in ipairs(uses[CP.Holder(rows, b)] or {}) do
				if u.from < b and u.to > b and u.from >= b - SWAP_LEAD - 0.01 then nextStart = math.min(nextStart, u.from) end
			end
		end
		local laneFrom = -math.huge
		if i > 1 then
			laneFrom = a
			for _, u in ipairs(mine) do
				if u.from < a and u.to > a and u.from >= a - SWAP_LEAD - 0.01 then laneFrom = math.min(laneFrom, u.from) end
			end
		end
		for _, u in ipairs(mine) do
			local from, to = math.max(u.from, laneFrom), math.min(u.to, nextStart)
			if to > from and to > t and from < stop then tank.blocks[#tank.blocks + 1] = {from = from, to = to, row = u.row} end
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

-- what the plan did and why, the last LOG_MAX lines, in the saved variables (DBM_CooldownPlans.log) to read after a
-- reload or logout
-- the planner's log in the saved variables, for finding what it did and why; off unless /dbm cd log turns it on
local function plog(fmt, ...)
	local LOG_MAX = 2000 -- a fight's re-plans outlast the cooldown reports' lines (each ask is ~20) until a reload
	if not saved or not saved.logOn then return end
	local log = saved.log or {}
	saved.log = log
	log[#log + 1] = ("%s %.1f %s"):format(date("%H:%M:%S"), GetTime(), fmt:format(...))
	while #log > LOG_MAX do table.remove(log, 1) end
end

local function send(msg)
	local channel = GetNumRaidMembers() > 0 and "RAID" or GetNumPartyMembers() > 0 and "PARTY"
	if channel then SendAddonMessage(PREFIX, msg, channel) end
end

local MSG_MAX = 254 - #PREFIX	-- the server drops an addon message past 255 bytes: prefix, a tab, then the text

-- A plan's lines as L messages under one send id, or nil and the lines too long to send whole: as an L line,
-- or later as the U line a re-plan sends for that row (a cut line would leave everyone with a different plan).
-- The send id goes up with every send (tenths of a second of uptime), so a client can tell a resend from late lines.
local sentAs = {}	-- [plan id] = the send id it last went out under
local function planMessages(id, text, sendId)
	sendId = sendId or math.floor(GetTime() * 10)
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("%S") then lines[#lines + 1] = line end
	end
	local msgs, long = {}, {}
	for i, line in ipairs(lines) do
		msgs[i] = ("L\t%s\t%d\t%d\t%d\t%s"):format(id, sendId, #lines, i, line)
		local row = CP.Parse(line).rows[1]
		local u = row and ("U\t99999\t999.999\t999\t999\t%g\t%s\t%s\t%g\t%s\t%s"):format(row.time, row.player, row.spell, row.dur or 999, row.target or "", row.note or "")
		if #msgs[i] > MSG_MAX or (u and #u > MSG_MAX) then long[#long + 1] = line:sub(1, 40) end
	end
	if long[1] then return nil, long end
	sentAs[id] = sendId
	return msgs
end

-- the plan sent to the raid (the leader's), and kept as the last sent; long: its lines too long to send, when nothing went
function CP.SendPlan(id, text)
	local msgs, long = planMessages(id, text)
	CP.lastSent[id] = text
	for _, m in ipairs(msgs or {}) do send(m) end
	return msgs, long
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

-- my role from my own talents, as the boss mods see it (any mod carries IsTank)
local function iTank()
	local m = DBM.Mods and DBM.Mods[1]
	return m and m.IsTank and m:IsTank() and true or false
end

-- my average item level over the 17 gear slots (not shirt or tabard); a two-hander with nothing in the off hand
-- counts twice
local function myItemLevel()
	local sum = 0
	for slot = 1, 18 do
		local link = slot ~= 4 and GetInventoryItemLink("player", slot)
		if link then
			local _, _, _, ilvl, _, _, _, _, equipLoc = GetItemInfo(link)
			sum = sum + (ilvl or 0)
			if slot == 16 and equipLoc == "INVTYPE_2HWEAPON" and not GetInventoryItemLink("player", 17) then sum = sum + (ilvl or 0) end
		end
	end
	return math.floor(sum / 17)
end

-- M first: what follows is all of mine, so whatever I sent before and don't send again (a trinket taken off) is gone
local function sendMine()
	send("M")
	for spell, r in pairs(saved.mine[playerName] or {}) do sendOne(spell, r) end
	send(iTank() and ("T\t1\t%d"):format(myItemLevel()) or "T\t0")
end

-- my cooldowns from talents, glyphs and gear
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
	-- Hand of Sacrifice ends once it has passed on my maximum health (spell_pal_hand_of_sacrifice_aura): on a tank
	-- taking TANK_DTPS that's well under its 12s
	local was = saved.mine[playerName]
	wipe(was) -- dropped talents or gear go
	for cast, v in pairs(mine) do was[GetSpellInfo(cast)] = v end
	sendMine()
end

local function track(text)
	for _, row in ipairs((CP.Parse(text)).rows) do tracked[row.spell] = true end
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

-- a 10-man raid (normal or heroic): GetRaidDifficulty() is 1 or 3
local function smallRaid()
	return GetRaidDifficulty() % 2 == 1
end

local function roster(origin)
	local units = {"player"}
	for i = 1, GetNumRaidMembers() do units[#units + 1] = "raid" .. i end
	if #units == 1 then for i = 1, GetNumPartyMembers() do units[#units + 1] = "party" .. i end end
	local pool, tanks, assists, selfTanks, seen = {}, {}, {}, {}, {}
	local now = GetTime()
	for _, unit in ipairs(units) do
		local name = UnitName(unit)
		if name and not seen[name] then
			seen[name] = true
			-- the server keeps one Main Tank: the second tank is the Main Assist
			if GetPartyAssignment("MAINTANK", unit) then tanks[#tanks + 1] = name
			elseif GetPartyAssignment("MAINASSIST", unit) then assists[#assists + 1] = name end
			local ilvl = name == playerName and iTank() and myItemLevel() or name ~= playerName and tankReported[name]
			if ilvl then selfTanks[#selfTanks + 1] = {name = name, ilvl = ilvl, order = #selfTanks} end
			for spell, r in pairs(reported[name] or {}) do
				local role = roleByName[spell]
				if role and r.dur and r.cd then
					-- mine aren't reported (my own messages don't come back to me): when they're back, from my own cooldowns
					local readyAt = name == playerName and now + readyIn(spell) or r.readyAt or now
					pool[#pool + 1] = {player = name, spell = spell, dur = r.dur, cd = r.cd, power = r.power or defaultByName[spell][3],
						role = role, raid = raidByName[spell], trinket = trinketByName[spell], smashOnly = smashOnlyByName[spell], notSelf = notSelfByName[spell],
						heals = healsByName[spell], readyAt = math.max(0, readyAt - origin)}
				end
			end
		end
	end
	-- the Main Tank is tank 1 (the pull) and the Main Assist tank 2; a place left empty goes to those whose own talents
	-- say tank (T), the best geared first
	local flagged, fill = {}, {}
	for _, name in ipairs(tanks) do flagged[name] = true end
	for _, name in ipairs(assists) do flagged[name] = true end
	table.sort(selfTanks, function(a, b)
		if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
		return a.order < b.order
	end)
	for _, t in ipairs(selfTanks) do if not flagged[t.name] then fill[#fill + 1] = t.name end end
	local first, second = tanks[1] or table.remove(fill, 1), assists[1] or table.remove(fill, 1)
	tanks = {}
	for _, name in ipairs({first or false, second or false}) do if name then tanks[#tanks + 1] = name end end
	for _, name in ipairs(fill) do tanks[#tanks + 1] = name end
	table.sort(pool, function(a, b) return a.player .. a.spell < b.player .. b.spell end) -- same plan on every client
	local by = {}
	for _, c in ipairs(pool) do by[c.player] = (by[c.player] or 0) + 1 end
	local who = {}
	for name, n in pairs(by) do who[#who + 1] = name .. ":" .. n end
	plog("roster: %d cooldowns (%s); tanks %s", #pool, table.concat(who, " "), table.concat(tanks, ", "))
	return pool, tanks
end

-- fight
local active, pullTime, done = nil, 0, {}

-- the plan clock (what SmashTimes and SafeWindows count in) while a pull or the mock fight is on
function CP.FightTime()
	return active and GetTime() - pullTime
end

-- the boss mod sets the clock once the boss shows where the fight is (Algalon's first Quantum Strike: 3.5s)
function CP.SetFightTime(t)
	if active and not active.test then pullTime = GetTime() - t end
end
-- each tanking class's taunt (Spell IDs: server source for 62124 and 355, combat logs for 56222 and 6795)
local TAUNT = {DEATHKNIGHT = 56222, PALADIN = 62124, WARRIOR = 355, DRUID = 6795}
-- the plan's rows plus my taunts at my swap-ins, for the card; kept while the rows are, so a taunt stays done
local function cardRows(rows)
	if not active or active.rows ~= rows then return rows end
	if active.cardFor ~= rows then
		local name = GetSpellInfo(TAUNT[select(2, UnitClass("player"))] or 0)
		active.taunts = name and CP.Taunts(rows, playerName, name) or {}
		active.cardRows = {}
		for _, r in ipairs(rows) do active.cardRows[#active.cardRows + 1] = r end
		for _, r in ipairs(active.taunts) do active.cardRows[#active.cardRows + 1] = r end
		active.cardFor = rows
	end
	return active.cardRows
end
local TEST_CAST = 2.5	-- in a mock fight (CP.TestFight) each press lands this long after it's due, so NOW shows
local ticker = CreateFrame("Frame")
ticker:Hide()

-- what happened this pull, kept for the re-plan: casts in fight time, deaths, no-shows, Phase Punch's tank
local fight = {uses = {}, dead = {}, missed = {}}
local replanSoon
local card, showCard, strip, showStrip, drawStrip, stop

-- the boss whose plan is showing: its own options (Algalon's) say whether the card and the timeline show,
-- and whether they're locked in place. A boss without them shows both, movable.
local shownFor
local function modFor(id)
	for _, m in ipairs(DBM.Mods) do
		if tostring(m.id):lower() == id then return m end
	end
end
local function allowed(name) return not (shownFor and shownFor.Options[name] == false) end
-- a player's class colour: the mock fight's stand-in roster, else the raid's
local function classColor(name)
	local class = active and active.classes and active.classes[name]
	if not class then
		local unit = DBM:GetRaidUnitId(name)
		class = unit and select(2, UnitClass(unit))
	end
	return class and RAID_CLASS_COLORS[class]
end
local function applyLock()
	local free = not (shownFor and shownFor.Options.CooldownPlanLock)
	if card then card:EnableMouse(free) end
	if strip then strip:EnableMouse(free) end
end

-- the two tanks a plan is for: whoever has its first row, and whoever has its first swap
local function planTanks(rows)
	local first, second
	for _, r in ipairs(rows) do
		first = first or r.target
		if r.note == "Tank swap" and r.target ~= first then second = r.target break end
	end
	return first and second and {first, second}
end

-- The running plan's two tanks, found once from its rows and kept: a re-plan after a tank dies leaves only the other
-- tank's rows ahead, with no swap, and the fight (the strip, re-plans) still has two tanks
local function activeTanks()
	active.tanks = active.tanks or planTanks(active.rows)
	return active.tanks
end

local function clock(t) return ("%d:%02d"):format(t / 60, t % 60) end

-- a mock fight's scripted misuse, said in chat so it can be matched to what the card and timeline do
local function sayTest(text)
	if active and active.test then DBM:AddMsg(("Mock fight %s: %s"):format(clock(GetTime() - pullTime), text)) end
end

-- a tracked cast while the plan's sender re-plans (a real pull, or a mock fight standing in for one): one that
-- isn't its planned use and touches the plan (its owner has rows, or it's on a tank) re-plans the rest
local function liveUse(use, offSelf)
	fight.uses[#fight.uses + 1] = use
	local i = not offSelf and CP.Match(active.rows, use)
	if i then
		active.rows[i].done = true
		return
	end
	local tanks, matters = activeTanks(), false
	local tank = tanks and (use.player == tanks[1] or use.player == tanks[2])
	-- what of theirs Forbearance's group can lock: a planned one of the group (a tank's Divine Protection), or a
	-- non-tank's hand, which goes up under a bubble. One of the group locks it 2 minutes, Avenging Wrath 30s
	local lock = forbearing(use.spell) and FORBEARANCE or use.spell == CP.WRATH and WRATH_LOCK
	for _, r in ipairs(active.rows) do
		if r.player == use.player and r.spell == use.spell then matters = true end
		if lock and r.player == use.player and not r.done and (forbearing(r.spell) or notSelfByName[r.spell] and not tank)
			and r.time - use.time < lock and r.time > use.time + (lock == FORBEARANCE and MATCH or 0) then
			matters = true -- (a bubble's own hand is due within MATCH of it)
		end
	end
	if matters or (tanks and (use.target == tanks[1] or use.target == tanks[2])) then
		plog("off plan: %s %s at %.1f on %s", use.player, use.spell, use.time, tostring(use.target))
		replanSoon()
	end
end

-- a cast seen live, from the combat log or a raider's own word (P), once: the other report of it is dropped
local function castSeen(player, spell, destName, t, offSelf)
	local SEEN_TWICE = 3
	for _, u in ipairs(fight.uses) do
		if u.player == player and u.spell == spell and math.abs(u.time - t) <= SEEN_TWICE then return end
	end
	if spell == CP.WRATH then return liveUse({player = player, spell = spell, time = t}, true) end
	if not tracked[spell] then return end
	local use = {player = player, spell = spell, time = t, dur = (CP.Info(player, spell))}
	-- Divine Sacrifice has no target: it covers whoever has the boss
	use.target = not smashOnlyByName[spell] and not offSelf and (roleByName[spell] == "ext" and (destName or fight.holder) or player) or nil
	liveUse(use, offSelf)
end

local function liveDeath(name)
	-- a tank lost after the first swap is a wipe: the sent plan stands. Before it, the other tank takes the boss and
	-- the rest is planned on them, the one time in the fight that can be recovered from
	local tanks, t = activeTanks(), GetTime() - pullTime
	if tanks and (name == tanks[1] or name == tanks[2]) then
		for _, r in ipairs(active.rows) do
			if r.note == "Tank swap" then
				if t >= r.time + SWAP_LEAD then
					plog("%s died at %.1f, after the first swap: no re-plan", name, t)
					return
				end
				break
			end
		end
	end
	for _, r in ipairs(active.rows) do
		if (r.player == name or r.target == name) and r.time > GetTime() - pullTime then
			fight.dead[name] = true
			replanSoon()
			return
		end
	end
end

-- a raider says when a cooldown they used this fight is back (sooner than its full cooldown): re-plan it in
local function heardReady(name, spell, wait)
	if not (active and active.live) then return end
	local t = GetTime() - pullTime
	for _, u in ipairs(fight.uses) do
		if u.player == name and u.spell == spell then
			fight.back = fight.back or {}
			fight.back[name .. "\0" .. spell] = {at = t, readyAt = t + wait}
			local _, cd = CP.Info(name, spell)
			plog("%s's %s back at %.1f (used at %.1f, its full cooldown %s)", name, spell, t + wait, u.time, cd and ("%.1f"):format(u.time + cd) or "?")
			replanSoon()
			return
		end
	end
end

local elapsed = 0
local function step(e)
	if not active then ticker:Hide() return end
	elapsed = elapsed + e
	if elapsed < 0.2 then -- between the stepped work, the timeline still slides every frame
		if strip and strip:IsShown() and strip.s then drawStrip(GetTime() - pullTime) end
		if card and card:IsShown() and card.tick then card.tick(GetTime() - pullTime) end
		return
	end
	elapsed = 0
	if not DBM.Options.CooldownPlanEnabled then
		stop()
		return
	end
	local now = GetTime()
	local t = now - pullTime
	if active.aoeOnly then -- the raid's AoE and the swaps only: no plan, no card
		if t > FIGHT + 10 then stop() return end -- the kill or wipe should have stopped it
		if card then card:Hide() end
		showStrip(active.rows, t, true)
		return
	end
	if active.live then
		for name in pairs(fight.dead) do -- battle rez or soulstone: back in the plan
			local unit = DBM:GetRaidUnitId(name)
			if unit and not UnitIsDeadOrGhost(unit) then
				fight.dead[name] = nil
				replanSoon()
			end
		end
	end
	if active.test then -- a mock fight: everyone presses on time, give or take a reaction, but for its scripted misuse
		if t > FIGHT then stop() return end
		for _, row in ipairs(active.rows) do
			if not row.done and not row.missed and not active.skip[row] and not fight.dead[row.player] and t >= row.time + TEST_CAST then
				if active.live then
					liveUse({player = row.player, spell = row.spell, time = t, dur = row.dur, target = row.target})
				else
					row.done = true
				end
			end
		end
		while active.script[1] and t >= active.script[1].at do
			table.remove(active.script, 1).run()
			if not active then return end
		end
		for _, row in ipairs(active.taunts or {}) do
			if t >= row.time + TEST_CAST then row.done = true end
		end
	end
	for _, row in ipairs(active.rows) do
		local due = row.time
		local left, key = due - t, row.player .. "\0" .. row.spell .. "\0" .. due
		if left <= CHECKAHEAD and not done["check" .. key] and not active.test then
			done["check" .. key] = true
			local why = CP.NotReady(row.player, row.spell, now + left)
			if why then
				RaidNotice_AddMessage(RaidWarningFrame, ("%s's %s: %s"):format(row.player, row.spell, why), ChatTypeInfo["RAID_WARNING"])
			end
		end
		if active.live and left < -MATCH and not row.done and not row.missed and not fight.dead[row.player] then
			row.missed = true
			fight.missed[row.player .. "\0" .. row.spell] = row.time
			sayTest(("%s didn't press %s (due %s)"):format(row.player, row.spell, clock(row.time)))
			if not active.test then send(("N\t%g\t%s\t%s"):format(row.time, row.player, row.spell)) end
			replanSoon()
		end
	end
	-- a no-show leaves the plan: the re-plan has it again where it'll be, the timeline shows only what's to come
	for i = #active.rows, 1, -1 do
		if active.rows[i].missed then table.remove(active.rows, i) end
	end
	showCard(cardRows(active.rows), t)
	showStrip(active.rows, t, activeTanks() ~= nil)
end
-- an error here would come back every frame: say the first one and keep going, so a fault in one part (the
-- card, a re-plan) can't take the timeline down with it
local stepFailed
ticker:SetScript("OnUpdate", function(_, e)
	local ok, err = pcall(step, e)
	if not ok and not stepFailed then
		stepFailed = true
		geterrorhandler()(err)
	end
end)

function stop()
	ticker:Hide()
	if card then card:Hide() end
	if strip then strip:Hide() end
	active = nil
end

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
local update -- the re-plan being received (U messages); each pull starts over, as the sender's numbering may have
local function replan()
	if not active or not active.live then return end
	local t = GetTime() - pullTime
	local tanks = activeTanks()
	if not tanks then return end
	-- the tank order is the sent plan's for the whole fight, never re-planned: each swap's time and incoming tank, kept
	-- from the rows as they are before the first re-plan (a tank doesn't change hands mid-fight but by a wipe or the
	-- holder's own Phase Punch stacks)
	if not active.swaps then
		active.swaps = {}
		local list = {}
		for _, r in ipairs(active.rows) do
			if r.note == "Tank swap" then
				active.swaps[#active.swaps + 1] = {at = r.time + SWAP_LEAD, to = r.target}
				list[#list + 1] = ("%g>%s"):format(r.time + SWAP_LEAD, r.target or "?")
			end
		end
		plog("tanks %s, %s; swaps fixed at %s", tanks[1], tanks[2], table.concat(list, " "))
	end
	-- swaps are the sent plan's, whatever Phase Punch says between them: a late taunt still lands, or the tank's 5th
	-- stack drops their threat and forces it. Who has the boss now is the last of them past, else whoever opened
	local first = active.swaps[1]
	local holder, swaps = first and first.to == tanks[1] and tanks[2] or tanks[1], {}
	for _, w in ipairs(active.swaps) do
		if w.at <= t then holder = w.to else swaps[#swaps + 1] = w.at end
	end
	local tank = holder == tanks[2] and 2 or 1
	local rows = CP.Replan({
		rows = active.rows, uses = fight.uses, pool = active.pool or (roster(pullTime)), tanks = tanks, tank = tank, weaker = active.weaker or weakerTank(tanks),
		now = t, dead = fight.dead, missed = fight.missed, back = fight.back, small = smallRaid(), swaps = swaps,
	})
	local future, swapRows, ext = {}, {}, {}
	for _, r in ipairs(rows) do
		if r.time >= t then future[#future + 1] = r end
		if r.time >= t and r.note == "Tank swap" then swapRows[#swapRows + 1] = ("%g>%s"):format(r.time, r.target or "?") end
		-- the next minute's cooldowns from others: who each is on, to check against who has the boss then
		if r.time >= t and r.time < t + 60 and r.player ~= r.target then ext[#ext + 1] = ("%g %s %s>%s"):format(r.time, r.player, r.spell, r.target or "raid") end
	end
	plog("re-plan %.1f: %s has the boss, swaps %s; next minute %s", t, holder, table.concat(swapRows, " "), table.concat(ext, ", "))
	applyRows(future, t)
	if active.test then -- the stand-in raid isn't the real one: nothing to send
		sayTest(("re-planned, %d uses from here"):format(#future))
		return
	end
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

-- the pull being fought: its boss's plan runs from pullTime, and a plan for it that arrives during the pull starts then
local pulled -- {mod, id}
local function startPlan()
	local text, from = saved.plans[pulled.id], saved.planFrom[pulled.id]
	-- a plan kept from another raid (plans are saved, and outlast leaving it) isn't this one's: only my own, or one
	-- from this raid's lead or an assistant (as a plan is accepted at all), runs
	if text and from ~= playerName and DBM:GetRaidRank(from) == 0 then
		plog("start %s: plan from %s, not in this raid's lead", pulled.id, tostring(from))
		return
	end
	if not text or not DBM.Options.CooldownPlanEnabled then
		plog("start %s: %s", pulled.id, not text and "no plan" or "plans disabled")
		return
	end
	stop()
	active = CP.Parse(text)
	if #active.rows == 0 then active = nil return end
	active.from = saved.planFrom[pulled.id]
	shownFor = pulled.mod
	-- the plan's sender re-plans when cooldowns go off plan; a looping plan has no fight to re-plan
	active.live = active.from == playerName and activeTanks() ~= nil
	plog("start %s: %d rows from %s, live %s", pulled.id, #active.rows, tostring(active.from), tostring(active.live))
	wipe(done)
	fight = {uses = {}, dead = {}, missed = {}}
	update = nil
	ticker:Show()
end

-- The raid leader's plan for a boss whose module asks for one (CP.Prepare) is made for them: when the module loads,
-- and again on every pull from what everyone reports then, sent before the boss starts fighting. Whatever plan they
-- hold (one sent from the editor, or the last leader's) is made again over: the raid's plan is always made, not written.
local AUTO_WAIT = 2	-- for everyone's cooldowns (C) to come back after the ask (Q)
CP.lastSent = {}	-- [plan id] = the plan text last sent: the room's checks send only a changed one, the pull always
CP.lastInputs = {}	-- [plan id] = what the room's checks last made it from (CP.PlanInputs): the same again isn't made again
-- what a plan is made from, as text to compare: each cooldown and whether it's ready now (not its seconds left, which
-- tick down on every ask), the two tanks, the weaker of them and the raid's size
function CP.PlanInputs(pool, tanks, weaker, small)
	local out = {}
	for _, c in ipairs(pool) do
		out[#out + 1] = ("%s|%s|%s|%s|%s|%s"):format(c.player, c.spell, tostring(c.dur), tostring(c.cd), tostring(c.power),
			(c.readyAt or 0) > 0 and "wait" or "ready")
	end
	table.sort(out)
	return ("%s|%s|%s|%s\n"):format(tostring(tanks[1]), tostring(tanks[2]), tostring(weaker), tostring(small)) .. table.concat(out, "\n")
end
-- true: no plan is made or run; a boss that asks for one (CP.Prepare) gets the timeline's AoE lane on its pull, the
-- tank lane reading WIP. Known open issues with planning on: tanks not found by Main Assist, offline tanks report
-- nothing.
local AOE_ONLY = false
local autoFor = {}
local function ownsAuto(id)
	return autoFor[id] and DBM:GetRaidRank() == 2
end
-- what to say when the tanks found (roster) aren't two, else nil; only clients with the cooldown plan answer the ask,
-- so a tank on an older DBM reports nothing
function CP.TankWarning(id, tanks)
	if #tanks >= 2 then return end
	return ("Cooldown plan for %s needs two tanks, and %s. Set Main Tank and Main Assist in the raid frame, or a tank's own talents must say tank."):format(
		id, #tanks == 1 and ("only " .. tanks[1] .. " is one") or "none was found")
end

-- origin: the time cooldowns are counted ready from (plan time 0); quiet: nothing said when there aren't two tanks
-- (the boss module's CheckTanks says it nearer the boss)
local function autoPlan(id, origin, quiet)
	local pool, tanks = roster(origin)
	tanks = {tanks[1], tanks[2]}
	if #tanks < 2 then
		plog("no plan for %s: %d tank(s)", id, #tanks)
		if not quiet then DBM:AddMsg("No plan made. " .. CP.TankWarning(id, tanks)) end
		return
	end
	local text = CP.Format((CP.Generate({pool = pool, tanks = tanks, weaker = weakerTank(tanks), small = smallRaid()})))
	saved.plans[id], saved.planFrom[id], saved.auto[id] = text, playerName, true
	track(text)
	if CP.PlanChanged then CP.PlanChanged(id) end
	return text
end

-- The raid leader's early warning that the tanks aren't set up (a boss module calls it when the raid gets near: its
-- room, the boss moused over): asks everyone, then finds the tanks as the plan will. Never in combat, when it's too
-- late to matter. atOnce (reaching the room): it runs whatever the last check; otherwise (a mouseover, again and
-- again) not more than every 5s. Which tank is which, the prefight card tells each tank.
function CP.CheckTanks(mod, atOnce)
	local CHECK_EVERY = 5
	if AOE_ONLY or not saved or not DBM.Options.CooldownPlanEnabled or DBM:GetRaidRank() ~= 2 or GetNumRaidMembers() == 0
		or mod:IsInCombat() or (not atOnce and mod.tankCheckAt and GetTime() - mod.tankCheckAt < CHECK_EVERY) then
		return
	end
	mod.tankCheckAt = GetTime()
	send("Q")
	DBM:Schedule(AUTO_WAIT, function()
		local pool, tanks = roster(GetTime())
		local id = tostring(mod.id):lower()
		local text = CP.TankWarning(id, tanks)
		if text then
			RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
			DBM:AddMsg(text)
			return
		end
		-- before the pull everyone sees their part (CP.Prefight): the plan as it stands now, sent when it changed. Made
		-- again only when what it's made from has: nobody's cooldowns, the tanks and the raid as at the last check
		local made
		if ownsAuto(id) and not mod:IsInCombat() then
			local inputs = CP.PlanInputs(pool, {tanks[1], tanks[2]}, weakerTank({tanks[1], tanks[2]}), smallRaid())
			if inputs == CP.lastInputs[id] and saved.plans[id] then
				made = saved.plans[id]
			else
				made = autoPlan(id, GetTime(), true)
				CP.lastInputs[id] = made and inputs or nil
				plog("check %s: %s", id, made and "made again, the raid's cooldowns changed" or "no plan")
			end
		end
		if made and made ~= CP.lastSent[id] then
			CP.SendPlan(id, made)
			CP.tellMine(id, nil, true) -- mine don't come back to me
		elseif made then
			-- the same plan: everyone's card back up instead (back in the room after a wipe, respawned there, or closed)
			send("S\t" .. id)
			CP.tellMine(id, nil, atOnce and "room" or true) -- reaching the room: the order again
		end
	end)
end

function CP.Prepare(mod)
	local id = tostring(mod.id):lower()
	autoFor[id] = true
	if AOE_ONLY or not saved or not ownsAuto(id) then return end
	send("Q")
	DBM:Schedule(AUTO_WAIT, function()
		if ownsAuto(id) and autoPlan(id, GetTime(), true) then DBM:AddMsg(("Cooldown plan for %s made; it's made again and sent on each pull."):format(id)) end
	end)
end

DBM:RegisterCallback("DBM_Pull", function(_, mod, delay)
	if not saved or not mod then return end
	if active and active.test then stop() end
	-- plan time 0 is when Algalon starts fighting: 26s of roleplay on the lockout's first pull, 8.5s after
	-- that (JustEngagedWith's introDelay); before the first pull there's no lockout timer yet (as DBM-Ulduar's Algalon checks)
	local intro = 0
	if mod.id == "Algalon" then
		-- the first pull's despawn timer starts with it, at 60 (Algalon.lua's OnCombatStart); his first Quantum
		-- Strike sets the clock exactly, through CP.SetFightTime
		local minutes = tonumber((select(3, GetWorldStateUIInfo(1)) or ""):match("%d+")) or 0
		intro = (minutes == 0 or minutes >= 60) and 26 or 8.5
	end
	pullTime = GetTime() - (delay or 0) + intro
	local this = {mod = mod, id = tostring(mod.id):lower()}
	pulled = this
	plog("pull %s: intro %g, enabled %s, aoeOnly %s, prepared %s, rank %s, saved plan %s (auto %s)", this.id, intro,
		tostring(DBM.Options.CooldownPlanEnabled), tostring(AOE_ONLY), tostring(autoFor[this.id]), tostring(DBM:GetRaidRank()),
		tostring(saved.plans[this.id] ~= nil), tostring(saved.auto[this.id]))
	-- the timeline's AoE lane on its own: planning is off, or there's no plan (yet): one arriving takes over
	local function aoeOnly()
		if active or not autoFor[this.id] or not DBM.Options.CooldownPlanEnabled then return end
		active, shownFor = {rows = {}, aoeOnly = true}, mod
		wipe(done)
		fight = {uses = {}, dead = {}, missed = {}}
		ticker:Show()
	end
	if AOE_ONLY then
		stop()
		aoeOnly()
		return
	end
	startPlan()
	aoeOnly()
	if not ownsAuto(this.id) then plog("pull %s: not mine to plan, no ask", this.id) return end
	send("Q")
	plog("pull %s: asked (Q)", this.id)
	CP.lastInputs[this.id] = nil -- after the pull (cooldowns spent, a wipe), the room's next check makes one afresh
	DBM:Schedule(AUTO_WAIT, function()
		if pulled ~= this or not ownsAuto(this.id) then plog("pull %s: gone before the plan", this.id) return end
		local text = autoPlan(this.id, pullTime)
		if not text then return end
		local msgs, long = CP.SendPlan(this.id, text)
		plog("pull %s: plan made, %d lines sent%s", this.id, msgs and #msgs or 0, long and (", too long: " .. long[1]) or "")
		startPlan()
	end)
end)

-- /dbm cd replan, the leader's at-will re-plan from what everyone reports now (a tank back online, a swap in
-- the raid): in a pull this client runs live, the rest of the fight; in a pull without a plan, one timed from
-- the pull; outside a fight, the next pull's plan. Sent either way.
function CP.Remake(id)
	if AOE_ONLY then
		DBM:AddMsg("Cooldown plans are off for now (WIP): the timeline shows only the raid's AoE.")
		return
	end
	if DBM:GetRaidRank() ~= 2 then
		DBM:AddMsg("Only the raid leader can re-plan.")
		return
	end
	send("Q")
	DBM:AddMsg("Asking everyone for their cooldowns; re-planning in 2s.")
	DBM:Schedule(AUTO_WAIT, function()
		if active and active.live then
			replan()
			DBM:AddMsg("Re-planned the rest of the fight and sent it.")
			return
		end
		local inPull = pulled and pulled.mod:IsInCombat()
		if inPull then id = pulled.id end
		local text = autoPlan(id, inPull and pullTime or GetTime())
		if not text then return end
		CP.SendPlan(id, text)
		if inPull then startPlan() end
		DBM:AddMsg(("Cooldown plan for %s made again and sent."):format(id))
	end)
end
-- who a use of mine is on and why it's there
local function reason(r)
	local why = r.note == "Cosmic Smash" and " for Cosmic Smash" or r.note and (" (" .. r.note .. ")") or ""
	if smashOnlyByName[r.spell] then why = why .. " on Fire Resistance Aura" end
	return (r.target and r.target ~= playerName and (" on " .. r.target) or "") .. why
end

-- what a use needs said on the card: the aura for Aura Mastery, the target for an external, else nothing
local function sub(r)
	if smashOnlyByName[r.spell] then return "Fire Res" end
	if roleByName[r.spell] == "ext" and not raidByName[r.spell] and r.target and r.target ~= playerName then
		local cc = classColor(r.target)
		return "on " .. (cc and ("|cff%02x%02x%02x%s|r"):format(cc.r * 255, cc.g * 255, cc.b * 255, r.target) or r.target)
	end
	return ""
end
-- whole seconds, then tenths under 10 so the last seconds count down to 0.0, as the icon warnings do; rounded down,
-- so 10 goes to 9.9
local function countdown(left)
	if left >= 60 then return clock(left) end
	if left >= 10 then return tostring(math.floor(left)) end
	return ("%.1f"):format(math.floor(left * 10) / 10)
end

-- personal card: a big countdown to my next press with the spell beside it, and the press after that on one
-- line; right-click hides it
-- the bubble to press before my Hand of Sacrifice when I'm not tanking (CP.BubbleFor, from my real cooldowns and
-- Forbearance at its due time); false when it needs one and none can be up (the hand isn't safe: skip it, the
-- leader's re-plan moves it); nil when it needs none: tanking, done, or a bubble already up. rows: the plan shown,
-- which names its tanks when none is running yet (the card on receipt, before the pull)
local function bubbleFirst(r, rows)
	if r.player ~= playerName or r.done or not notSelfByName[r.spell] then return end
	for _, n in ipairs(active and activeTanks() or planTanks(rows) or {}) do if n == playerName then return end end
	if UnitBuff("player", CP.BUBBLE_FULL) or UnitBuff("player", CP.BUBBLE_PHYS) then return end
	local inSec = active and r.time - (GetTime() - pullTime) or r.time -- before the pull: from the pull
	local forbearance = select(7, UnitDebuff("player", GetSpellInfo(25771) or "Forbearance"))
	local marker = GetSpellInfo(61987) or "Avenging Wrath"
	local wrathMarker = select(7, UnitDebuff("player", marker)) or select(7, UnitBuff("player", marker))
	if wrathMarker and (not forbearance or wrathMarker > forbearance) then forbearance = wrathMarker end
	local function ready(name)
		local start, dur = GetSpellCooldown(name)
		if not start then return false end -- not known
		local left = start > 0 and start + dur - GetTime() or 0
		return math.max(left, forbearance and forbearance - GetTime() or 0) <= math.max(inSec, 0) + 0.5
	end
	return CP.BubbleFor(r.time, ready(CP.BUBBLE_FULL), ready(CP.BUBBLE_PHYS)) or false
end

-- each cooldown of mine in rows, once, in the order they're first pressed; a hand that goes up under a bubble, the
-- bubble on a line of its own under it (as the fight card names it, bubbleFirst)
local function plannedLines(rows)
	local order, subs = {}, {}
	for _, r in ipairs(rows) do
		if r.player == playerName then
			if not subs[r.spell] then order[#order + 1] = r.spell subs[r.spell] = {} end
			local b = bubbleFirst(r, rows)
			if b ~= nil then
				local text = b and ("under " .. b) or "no bubble ready"
				if not subs[r.spell][text] then subs[r.spell][text] = true table.insert(subs[r.spell], text) end
			end
		end
	end
	local lines = {}
	for _, spell in ipairs(order) do
		lines[#lines + 1] = spell
		for _, text in ipairs(subs[spell]) do lines[#lines + 1] = "|cffa1a1a1  " .. text .. "|r" end
	end
	return lines
end

-- withRole (the prefight card, CP.Prefight): instead of the countdowns, which tank I am (if I'm one) and every
-- cooldown I'm down for, so I have them ready
function showCard(rows, t, prepull, withRole)
	local c = CP.Card(rows, playerName, t)
	-- before the pull everyone with a use sees it, the option or not: it's how they learn their part
	if not (withRole or allowed("CooldownPlanCard")) or not c.go and not c.next then
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
		card:RegisterForDrag("LeftButton")
		card:SetScript("OnDragStart", card.StartMoving)
		card:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
			local p, _, rp, x, y = self:GetPoint()
			saved.cardPos = {p, rp, x, y}
		end)
		card:SetScript("OnMouseUp", function(self, button) if button == "RightButton" then self:Hide() end end)
		local pos = saved.cardPos
		if pos then card:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else card:SetPoint("CENTER", -202, -37) end -- left of centre, clear of DBM's info and range frames
		applyLock()
		card.num = card:CreateFontString(nil, "ARTWORK", "NumberFontNormalHuge")
		-- wide enough for "2:00" at 30 (a 54 cut it to "2..."; "1:59" fit, its 1 being narrow); the spell stays put
		-- beside it, and the widest times may reach a little into the gap before it
		card.num:SetWidth(66)
		card.num:SetJustifyH("CENTER")
		-- two matching rows, times in the left column and spells beside them; no widths, so nothing wraps:
		-- the longest pieces measured in Friz (Icebound Fortitude at 14 is 124px of the 130 beside the countdown)
		local friz = STANDARD_TEXT_FONT
		card.spell = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
		card.spell:SetFont(friz, 14)
		card.spell:SetPoint("TOPLEFT", card, "TOPLEFT", 66, -12)
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
		card.role = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		card.role:SetFont(friz, 13)
		card.role:SetTextColor(1, 0.82, 0)
		card.role:SetPoint("TOPLEFT", 12, -10)
		card.head = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		card.head:SetFont(friz, 11)
		card.head:SetTextColor(0.63, 0.63, 0.63)
		card.head:SetText("Planned CDs")
		card.headL, card.headR = card:CreateTexture(nil, "ARTWORK"), card:CreateTexture(nil, "ARTWORK")
		card.headL:SetTexture(1, 1, 1, 0.2)
		card.headL:SetHeight(1)
		card.headL:SetPoint("RIGHT", card.head, "LEFT", -6, 0)
		card.headR:SetTexture(1, 1, 1, 0.2)
		card.headR:SetHeight(1)
		card.headR:SetPoint("LEFT", card.head, "RIGHT", 6, 0)
		card.list = card:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		card.list:SetFont(friz, 13)
		card.list:SetJustifyH("LEFT")
		card.list:SetSpacing(3)
		-- tenths need every frame (step), not just the 0.2s update
		function card.tick(t)
			if card.nextAt and card.nextAt - t < 10 then card.num:SetText(countdown(math.max(0, card.nextAt - t))) end
			if card.afterAt and card.afterAt - t < 10 then card.afterTime:SetText(countdown(math.max(0, card.afterAt - t))) end
		end
	end
	for _, e in ipairs({card.num, card.spell, card.sub, card.afterTime, card.after}) do if withRole then e:Hide() else e:Show() end end
	for _, e in ipairs({card.role, card.head, card.headL, card.headR, card.list}) do if withRole then e:Show() else e:Hide() end end
	if withRole then
		card.nextAt, card.afterAt = nil, nil
		card.rule:Hide()
		local tanks = planTanks(rows)
		local role = tanks and (tanks[1] == playerName and "You are first tank" or tanks[2] == playerName and "You are second tank")
		card.role:SetText(role or "")
		local y = role and -30 or -10
		card.head:ClearAllPoints()
		card.head:SetPoint("TOP", card, "TOP", 0, y)
		local side = (210 - 24 - card.head:GetStringWidth() - 12) / 2
		card.headL:SetWidth(side)
		card.headR:SetWidth(side)
		card.list:ClearAllPoints()
		card.list:SetPoint("TOPLEFT", card, "TOPLEFT", 16, y - 16)
		card.list:SetText(table.concat(plannedLines(rows), "\n"))
		card:SetHeight(16 - y + card.list:GetHeight() + 10)
		card:Show()
		return
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
	local bubbleName = bubbleFirst(r, rows)
	local said = bubbleName and "then " .. r.spell or bubbleName == false and "no bubble: skip" or c.thenTaunt and "then Taunt"
		or c.thenWith and "then " .. c.thenWith.spell or sub(r)
	card.spell:SetText(bubbleName or r.spell)
	card.sub:SetText(said)
	-- what the card says, each time it changes, with the row behind it: to check a target against who has the boss then
	local key = ("%s\0%s\0%g"):format(bubbleName or r.spell, said, r.time)
	if card.said ~= key then
		card.said = key
		plog("card %.1f: %s / %s (row %g %s %s on %s)", t, bubbleName or r.spell, said:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), r.time, r.player, r.spell, tostring(r.target))
	end
	-- the press after that: the next one when the big line is NOW, else the one after the next
	local after, afterIn = c.go and c.next or c.later, c.go and c.nextIn or c.laterIn
	card.nextAt = not prepull and not c.go and t + c.nextIn or nil
	card.afterAt = not prepull and after and t + afterIn or nil
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
local STRIP_SPAN, STRIP_W, LABEL_W, LANE_H, TAG_H, PAD = 30, 390, 29, 24, 14, 5	-- 13 units a second
local NAME_X = 4	-- the lane names' left edge: about 4 units clear of the border, and the column ends about 2 past "Tank"
local SMASH_COLOR = {1, 0.55, 0.23}	-- Cosmic Smash: its ramp, landing line and name
local BANG_COLOR, BANG_LINE, BANG_TEXT = {0.59, 0.24, 0.75}, {0.75, 0.43, 1}, {0.84, 0.59, 1}	-- Big Bang: ramp, line, name
-- Star kill safe windows (CP.SafeWindows): stripes tinted and faded in game (textures\stripes is white, alpha
-- only), fading over SAFE_FADE at each end; the label rests SAFE_INSET in, clear of the fade
local SAFE_COLOR, SAFE_ALPHA, SAFE_FADE, SAFE_INSET = {0.25, 0.75, 0.37}, 0.3, 20, 16
-- the KILL stretched over a kill zone, over its stripes: a lighter green, faint, so the label in front reads first;
-- KILL_SIDE in from each end, KILL_EDGE from the lane's top and bottom
local KILL_COLOR, KILL_ALPHA, KILL_SIDE, KILL_EDGE = {0.63, 0.94, 0.71}, 0.22, 4, 2
-- a star's death in the AoE lane: where a star left alone runs out (a marker) and where a named one would die if
-- nobody touched it again. Either may show sooner than its place, as a warning that the star is going down early,
-- but never later: a zone's tick not past the zone's end, a marker not past its run-out. DEATH_EDGE from the lane's
-- top and bottom
local DEATH_COLOR, DEATH_EDGE = {1, 0.42, 0.29}, 2
-- the stars to kill in window w: the picked marks (synced from the raid leader, or the mock fight's), "?" until
-- a star is picked, which may be after it spawns; each with its health now, so the raid can time the kill. The zone
-- itself says KILL (textures\kill), so the label is only which star and how much is left.
CP.StarKillPicks = {}
-- CP.StarHP(mark): the health % of the star wearing a mark, set by the boss mod while there are stars
local function starKillText(w, t)
	local marks, picks = {}, CP.StarKillPicks[w.index] or {}
	for k = 1, math.max(w.kills, 1) do
		local p = picks[k]
		if p and t >= (p.at or 0) then
			local mark = ("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:0|t"):format(p.mark)
			local hp = CP.PickHP(p, t)
			marks[k] = hp and ("%s %d%%"):format(mark, math.max(0, hp) + 0.5) or mark
		else
			marks[k] = "?"
		end
	end
	if w.expires then return marks[1] end -- no KILL behind it: a star to leave alone
	-- two kills read in order, the raid healing back up between the explosions
	if w.kills == 2 then return ("%s, Heal, %s"):format(marks[1], marks[2]) end
	return marks[1]
end
local LANES_TOP = PAD + TAG_H + 1	-- one row for the tank tags, then the lanes
-- a band of the dark frame between the tag row, the two lanes and the ruler row, so no lane's bars run into the next
local LANE_GAP = 4
-- the ruler row under the AoE lane: seconds ahead of the now line, 0 to STRIP_SPAN every RULER_EVERY, each with a
-- faint line from the top border to the bottom one; under everything else, so nothing it would cover
local RULER_H, RULER_EVERY, RULER_ALPHA = 12, 5, 0.16
-- a lane's top below the first lane's
local function laneY(lane) return (lane - 1) * (LANE_H + LANE_GAP) end
local LANES_BOTTOM = LANES_TOP + LANE_GAP + laneY(2) + LANE_H	-- where the lines stop, above the ruler row
-- the tags reach the border's inner edge (where the lines start too) rather than leaving the top padding dark; the
-- AoE lane's ramps reach a unit into the gap under it
local BORDER_IN = 3
local TAG_LIFT, RAMP_DOWN = PAD - BORDER_IN, 1
-- a tag's colour, from the border down to the top of the Tank lane's blocks: those show about 1.4 units below their
-- anchor (the lanes' scroll frame; measured on screenshots), so a tag sized to the anchor left a 2px dark band
local TAG_BG = LANES_TOP + 1 - BORDER_IN + 1
local TAG_FONT = 12
-- short names, so a block's label fits it
local STRIP_SHORT = {
	[48792] = "Icebound", [498] = "Div Prot", [871] = "Shield Wall", [61336] = "Surv Inst", [55233] = "Vamp Blood",
	[51271] = "Unbr Armor", [12975] = "Last Stand", [22812] = "Barkskin", [6940] = "Hand of Sac", [1038] = "Hand of Salv",
	[64205] = "DSac", [48788] = "Lay on Hands", [33206] = "Pain Sup", [47788] = "Guard Spirit", [31821] = "AuraM",
	[64763] = "Heart of Iron", [60286] = "Def Code", [68443] = "Brawler's", [60054] = "Valor Medal", [59757] = "Monarch Crab",
	[65012] = "King Llane", [60258] = "Repulsion", [65011] = "Furnace",
}
local shortByName = {}
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
	-- the other trinkets share Heart of Iron's grey: a tank wears two at most, and grey reads as "trinket"
	[60286] = {0.42, 0.42, 0.42}, [68443] = {0.42, 0.42, 0.42}, [60054] = {0.42, 0.42, 0.42}, [59757] = {0.42, 0.42, 0.42},
	[65012] = {0.42, 0.42, 0.42}, [60258] = {0.42, 0.42, 0.42}, [65011] = {0.42, 0.42, 0.42},
}
local colorByName = {}
local function stripPart(list, kind)
	list.used = list.used + 1
	local p = list[list.used]
	if not p then
		if kind == "line" or kind == "swap" then
			p = (kind == "swap" and strip.swapLayer or strip.lineLayer):CreateTexture(nil, "OVERLAY")
		else
			p = CreateFrame("Frame", nil, kind == "low" and strip.laneLow or strip.laneHigh)
			p:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2})
			-- the label sits in a scroll frame the size of the part, so a long one is cut at the edge: a font
			-- string given a width would shorten itself with "..." instead
			p.clip = CreateFrame("ScrollFrame", nil, p)
			p.clip:SetPoint("TOPLEFT", 3, 0)
			p.clip:SetPoint("BOTTOMRIGHT", -1, 0)
			p.child = CreateFrame("Frame", nil, p.clip)
			p.child:SetSize(400, 30)
			p.clip:SetScrollChild(p.child)
			p.text = p.child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			p.text:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
			p.text:SetPoint("LEFT", p.child, "LEFT", 0, 0)
			p.text:SetJustifyH("LEFT")
		end
		list[list.used] = p
	end
	p:Show()
	return p
end
function showStrip(rows, t, hasTanks)
	if not allowed("CooldownPlanStrip") or not hasTanks then
		if strip then strip:Hide() end
		return
	end
	if not strip then
		strip = CreateFrame("Frame", "DBMCooldownPlanStrip", UIParent)
		strip:SetSize(LABEL_W + STRIP_W + 2 * PAD + 4, LANES_BOTTOM + LANE_GAP + RULER_H + PAD)
		strip:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			tile = true, tileSize = 16, insets = {left = 4, right = 4, top = 4, bottom = 4},
		})
		strip:SetBackdropColor(0, 0, 0, 0.75)
		strip:SetMovable(true)
		strip:RegisterForDrag("LeftButton")
		strip:SetScript("OnDragStart", strip.StartMoving)
		strip:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
			local p, _, rp, x, y = self:GetPoint()
			saved.stripPos = {p, rp, x, y}
		end)
		local pos = saved.stripPos
		if pos then strip:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else strip:SetPoint("TOP", 415, -358) end -- right of centre, Algalon's star bars under it
		applyLock()
		strip.names, strip.blocks, strip.lines, strip.swapLines = {}, {used = 0}, {used = 0}, {used = 0}
		for i = 1, 2 do
			strip.names[i] = strip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			strip.names[i]:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
			strip.names[i]:SetPoint("LEFT", strip, "TOPLEFT", NAME_X, -LANES_TOP - LANE_GAP - laneY(i) - LANE_H / 2)
		end
		-- the ruler: its lines on the strip itself, under the lanes and everything in them; its numbers in their row
		local x0 = LABEL_W + PAD + 2
		for k = 0, STRIP_SPAN, RULER_EVERY do
			local at = x0 + k * STRIP_W / STRIP_SPAN
			if k > 0 and k < STRIP_SPAN then
				local l = strip:CreateTexture(nil, "ARTWORK")
				l:SetTexture(1, 1, 1, RULER_ALPHA)
				l:SetPoint("TOPLEFT", at, -BORDER_IN)
				l:SetSize(1, LANES_BOTTOM + LANE_GAP + RULER_H + PAD - 2 * BORDER_IN)
			end
			local n = strip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			n:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
			n:SetTextColor(1, 1, 1, 0.6)
			n:SetText(k)
			-- 0 starts at the now line and the last ends at the strip's edge; the rest sit centred on their second
			local point = k == 0 and "LEFT" or k == STRIP_SPAN and "RIGHT" or "CENTER"
			n:SetPoint(point, strip, "TOPLEFT", at + (k == 0 and 3 or k == STRIP_SPAN and -2 or 0), -(LANES_BOTTOM + LANE_GAP + RULER_H / 2))
		end
		-- the lanes are clipped from the now line on, so a cooldown running out slides away under it whole,
		-- border and label, rather than shrinking to a stub; its blocks reach to about level +5, so the
		-- smash and swap lines go just above them, the tags above those
		strip.laneClip = CreateFrame("ScrollFrame", nil, strip)
		strip.laneClip:SetPoint("TOPLEFT", LABEL_W + PAD + 2, -LANES_TOP - LANE_GAP)
		strip.laneClip:SetSize(STRIP_W + 2, laneY(2) + LANE_H + RAMP_DOWN)
		strip.laneClip:SetFrameLevel(strip:GetFrameLevel() + 1)
		strip.laneRow = CreateFrame("Frame", nil, strip.laneClip)
		strip.laneRow:SetSize(STRIP_W + 2, laneY(2) + LANE_H + RAMP_DOWN)
		strip.laneClip:SetScrollChild(strip.laneRow)
		-- trinkets on their own layer under the other cooldowns (each block's subtree is three levels deep), so
		-- one overlapping a cooldown is always the one hidden, never drawn in whatever order the pool gives
		strip.laneLow = CreateFrame("Frame", nil, strip.laneRow)
		strip.laneLow:SetAllPoints()
		strip.laneHigh = CreateFrame("Frame", nil, strip.laneRow)
		strip.laneHigh:SetAllPoints()
		strip.laneHigh:SetFrameLevel(strip.laneLow:GetFrameLevel() + 4)
		strip.trinkets = {used = 0}
		strip.ramps = {used = 0}	-- {ramp texture, label} per Cosmic Smash or Big Bang in view
		strip.safes = {}	-- three stripe textures per Star kill safe window in view
		strip.lineLayer = CreateFrame("Frame", nil, strip)
		strip.lineLayer:SetAllPoints()
		strip.lineLayer:SetFrameLevel(strip.laneHigh:GetFrameLevel() + 4) -- above the cooldowns' subtrees
		-- swap lines over the tank tags (the tag row is a level above the lines), so one coming in cuts across
		-- the current tank's tag ahead of its own; still under the now line, a level higher
		strip.swapLayer = CreateFrame("Frame", nil, strip)
		strip.swapLayer:SetAllPoints()
		strip.swapLayer:SetFrameLevel(strip.lineLayer:GetFrameLevel() + 30)
	end
	-- worked out a second further than shown, so what slides in before the next update is already there
	strip.s = CP.Strip(rows, t, STRIP_SPAN + 1, function(spell) return raidByName[spell] end)
	if active and active.aoeOnly then
		local tank = strip.s.lanes[1]
		-- WIP across the whole view (and a little past, as it's redrawn between updates): the text alone, no bar
		tank.blocks = {{from = t - 1, to = t + STRIP_SPAN + 2, bare = true, row = {spell = "WIP", player = "", target = ""}}}
		-- the swaps without a plan: every 4th Phase Punch from the pull, tagged "Swap" with no tank's name
		tank.tags, strip.s.swaps, strip.s.lastSwap = {{time = t, name = "", number = 0}}, {}, nil
		for n, w in ipairs(CP.SwapTimes(0, t + STRIP_SPAN + 1)) do
			if w <= t then
				strip.s.lastSwap = {time = w, from = "", to = "", number = n} -- its tag slides away under the now line
			else
				tank.tags[#tank.tags + 1] = {time = w, name = "", number = n}
				strip.s.swaps[#strip.s.swaps + 1] = w
			end
		end
	end
	-- Star kill safe windows, while there are stars (the boss sets CP.StarKillSafe; the mock fight shows them
	-- too). None in a gap a Big Bang lands in, where a star dying explodes on a raid not yet phased
	strip.s.safes = (CP.StarKillSafe or active and active.test) and CP.LiveWindows(t - 1, t + STRIP_SPAN + 1, t) or {}
	drawStrip(t)
	strip:Show()
end

-- the timeline placed at fight time t, from what showStrip last worked out: cheap enough for every frame
-- Where a strip label starts, for a block left..right and a label w wide, with the lanes from nowX (the now line)
-- to stripRight. A cooldown's rests inset in and, sliding out under the now line, stays just past it until the
-- block's right edge catches it and pushes it off too (5 clear of the next label). A centered one (a star kill
-- window) sits mid-block whenever it fits: coming in it rides the block's start, then holds at the strip's right
-- edge, so it reads from the moment it shows; going out it holds at the now line the same way.
function CP.LabelAt(left, right, w, nowX, stripRight, inset, center)
	inset = inset or 3
	if not center then return math.max(left + inset, math.min(nowX + 3, right - 5 - w)) end
	local at = math.min((left + right - w) / 2, stripRight - 5 - w)
	at = math.min(math.max(at, nowX + 3), right - 5 - w)
	return math.max(at, left + inset)
end

function drawStrip(t)
	local s = strip.s
	local stop = t + STRIP_SPAN
	for _, list in ipairs({strip.blocks, strip.trinkets, strip.lines, strip.swapLines}) do
		for i = 1, list.used do list[i]:Hide() end
		list.used = 0
	end
	for i = 1, strip.ramps.used do strip.ramps[i].tex:Hide() strip.ramps[i].text:Hide() end
	strip.ramps.used = 0
	local x0 = LABEL_W + PAD + 2
	-- everything moves by one shift, in whole screen pixels: placed and rounded one by one, a bar and its label
	-- round at different moments and wobble against each other
	local ppu = strip:GetEffectiveScale() * (tonumber((GetCVar("gxResolution") or ""):match("%d+x(%d+)")) or 768) / 768
	local perSecond = STRIP_W / STRIP_SPAN * ppu	-- pixels
	local nowPx = math.floor(t * perSecond + 0.5)
	local function x(time) return x0 + (math.floor(time * perSecond + 0.5) - nowPx) / ppu end
	-- inset: where the label rests from the block's start (default 3); center: see CP.LabelAt
	local function block(lane, from, to, color, a, text, mine, low, textAlpha, inset, center)
		local p = low and stripPart(strip.trinkets, "low") or stripPart(strip.blocks)
		p:ClearAllPoints()
		p:SetPoint("TOPLEFT", strip.laneRow, "TOPLEFT", x(from) - x0, -laneY(lane) - 1)
		p:SetSize(math.max(1, x(to) - x(from)), LANE_H - 1)
		p.child:SetHeight(LANE_H - 1)
		p:SetBackdropColor(color[1], color[2], color[3], a)
		p:SetBackdropBorderColor(1, 0.82, 0, mine and 1 or 0)
		p.text:SetFont("Fonts\\ARIALN.TTF", 12, "OUTLINE") -- narrow, so a caster's name fits beside the spell
		p.text:SetText(text or "")
		p.text:SetTextColor(1, 1, 1, textAlpha or 1)
		local left, right = x(from), x(to) - 1
		local at = CP.LabelAt(left, right, p.text:GetStringWidth(), x0, x0 + STRIP_W, inset, center)
		-- the label's own clip starts at the now line: the lanes' clip doesn't reach into it
		local clipFrom = math.max(left + 3, x0)
		p.clip:ClearAllPoints()
		p.clip:SetPoint("TOPLEFT", clipFrom - left, 0)
		p.clip:SetPoint("BOTTOMRIGHT", -1, 0)
		if right - 1 - clipFrom < 1 then p.clip:Hide() else p.clip:Show() end
		p.text:ClearAllPoints()
		p.text:SetPoint("LEFT", p.child, "LEFT", at - clipFrom, 0)
	end
	local function line(time, r, g, b, swap)
		local l = swap and stripPart(strip.swapLines, "swap") or stripPart(strip.lines, "line")
		l:ClearAllPoints()
		l:SetPoint("TOPLEFT", x(time), -3) -- into the border, which covers its ends, like the now line
		l:SetSize(2, LANES_BOTTOM - 3)
		l:SetTexture(r, g, b, 0.6) -- see-through enough to read a label behind it
	end
	for i, lane in ipairs(s.lanes) do
		strip.names[i]:SetText(lane.name)
		for _, b in ipairs(lane.blocks) do
			local r = b.row
			-- who presses it, unless it's the tank's own; cut at the block's edge when it doesn't fit
			local label = shortByName[r.spell] or r.spell
			if r.player ~= r.target or raidByName[r.spell] then label = label .. " |cffe6e6e6\194\183 " .. r.player .. "|r" end
			block(i, b.from, b.to, colorByName[r.spell] or {0.45, 0.45, 0.5}, b.bare and 0 or 0.9, label, r.player == playerName, trinketByName[r.spell], b.bare and 0.2)
		end
	end
	-- the AoE lane: each Cosmic Smash and Big Bang cast filling in toward where it lands, its name after the line
	-- there; the ramp and name slide out under the now line like a cooldown does
	local function ramp(land, cast, color, textColor, name)
		local p = strip.ramps[strip.ramps.used + 1]
		if not p then
			p = {tex = strip.laneLow:CreateTexture(nil, "ARTWORK"), text = strip.laneLow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")}
			p.tex:SetTexture(1, 1, 1, 1)
			p.text:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
			strip.ramps[strip.ramps.used + 1] = p
		end
		strip.ramps.used = strip.ramps.used + 1
		local left, right = x(land - cast), x(land)
		p.tex:ClearAllPoints()
		p.tex:SetPoint("TOPLEFT", strip.laneRow, "TOPLEFT", left - x0, -laneY(2) - 1)
		p.tex:SetSize(math.max(1, right - left), LANE_H - 1 + RAMP_DOWN)
		p.tex:SetGradientAlpha("HORIZONTAL", color[1], color[2], color[3], 0, color[1], color[2], color[3], 0.85)
		p.tex:Show()
		p.text:SetText(name)
		p.text:SetTextColor(textColor[1], textColor[2], textColor[3])
		p.text:ClearAllPoints()
		p.text:SetPoint("LEFT", strip.laneRow, "TOPLEFT", right - x0 + 2, -laneY(2) - (LANE_H + RAMP_DOWN) / 2) -- centred in the ramp
		p.text:Show()
	end
	for _, h in ipairs(s.smashes) do
		ramp(h, CP.SMASH_CAST, SMASH_COLOR, SMASH_COLOR, "Smash")
		if h >= t and h < stop then line(h, SMASH_COLOR[1], SMASH_COLOR[2], SMASH_COLOR[3]) end
	end
	for _, h in ipairs(s.bangs) do
		ramp(h, CP.BANG_CAST, BANG_COLOR, BANG_TEXT, "Big Bang")
		if h >= t and h < stop then line(h, BANG_LINE[1], BANG_LINE[2], BANG_LINE[3]) end
	end
	-- Star kill safe: green stripes in the AoE lane fading in and out at both ends, under a bare block whose
	-- label rides the now line and slides out like a cooldown's
	for i, w in ipairs(s.safes) do
		local p = strip.safes[i]
		if not p then
			p = {}
			for k = 1, 3 do
				p[k] = strip.laneLow:CreateTexture(nil, "ARTWORK")
				p[k]:SetTexture("Interface\\AddOns\\DBM-Core\\textures\\stripes")
			end
			p.ticks = {}
			p.kill = strip.laneLow:CreateTexture(nil, "OVERLAY") -- over the stripes, under the label
			p.kill:SetTexture("Interface\\AddOns\\DBM-Core\\textures\\kill")
			p.kill:SetVertexColor(KILL_COLOR[1], KILL_COLOR[2], KILL_COLOR[3], KILL_ALPHA)
			strip.safes[i] = p
		end
		-- a star left to run out: a line at that moment and its name after it, no stripes
		if w.expires then
			-- in the AoE row only, unlike the smash and Big Bang lines across the strip; at the star's own death if
			-- damage has brought that sooner than its run-out
			p[2]:Hide() p[3]:Hide() p.kill:Hide()
			for _, tick in ipairs(p.ticks) do tick:Hide() end
			local pick = (CP.StarKillPicks[w.index] or {})[1]
			local hp = pick and t >= (pick.at or 0) and CP.PickHP(pick, t)
			local at = math.min(w.from, hp and hp > 0 and t + (CP.StarDeathIn and CP.StarDeathIn(pick.mark) or hp) or w.from)
			p[1]:ClearAllPoints()
			p[1]:SetPoint("TOPLEFT", strip.laneRow, "TOPLEFT", x(at) - x0 - 1, -laneY(2) - 1 - DEATH_EDGE)
			p[1]:SetSize(2, LANE_H - 1 - 2 * DEATH_EDGE)
			p[1]:SetTexture(DEATH_COLOR[1], DEATH_COLOR[2], DEATH_COLOR[3], 1)
			p[1]:SetTexCoord(0, 1, 0, 1)
			p[1]:SetGradientAlpha("HORIZONTAL", 1, 1, 1, 1, 1, 1, 1, 1)
			p[1]:Show()
			block(2, at, at + 10, SAFE_COLOR, 0, starKillText(w, t), false, nil, 1)
		else
		local left, width = x(w.from), x(w.to) - x(w.from)
		local fade = math.min(SAFE_FADE, width / 2)
		local edges = {0, fade, width - fade, width}
		local r, g, b = SAFE_COLOR[1], SAFE_COLOR[2], SAFE_COLOR[3]
		for k = 1, 3 do
			local tex, from, to = p[k], edges[k], edges[k + 1]
			tex:SetTexture("Interface\\AddOns\\DBM-Core\\textures\\stripes") -- a marker may have had it last
			tex:ClearAllPoints()
			tex:SetPoint("TOPLEFT", strip.laneRow, "TOPLEFT", left - x0 + from, -laneY(2) - 1)
			tex:SetSize(math.max(to - from, 0.01), LANE_H - 1)
			-- the 512x64 texture at 2 texels a unit from the window's start, so the stripes ride with it
			tex:SetTexCoord(from * 2 / 512, to * 2 / 512, 0, (LANE_H - 1) * 2 / 64)
			tex:SetGradientAlpha("HORIZONTAL", r, g, b, k == 1 and 0 or SAFE_ALPHA, r, g, b, k == 3 and 0 or SAFE_ALPHA)
			tex:Show()
		end
		p.kill:ClearAllPoints()
		p.kill:SetPoint("TOPLEFT", strip.laneRow, "TOPLEFT", left - x0 + KILL_SIDE, -laneY(2) - 1 - KILL_EDGE)
		p.kill:SetSize(math.max(width - 2 * KILL_SIDE, 0.01), LANE_H - 1 - 2 * KILL_EDGE)
		p.kill:Show()
		-- each named star's death if left alone from here: in the zone, or before it as a warning, never after it
		local picks, early = CP.StarKillPicks[w.index] or {}, nil
		for k = 1, math.max(w.kills, #p.ticks) do
			local pick, tick = picks[k], p.ticks[k]
			local hp = k <= w.kills and pick and t >= (pick.at or 0) and CP.PickHP(pick, t)
			-- the star's own death time when the boss mod has it (exact on its 1s Collapse ticks, so it holds still
			-- between them), else its health in seconds
			local dies = hp and hp > 0 and t + (CP.StarDeathIn and CP.StarDeathIn(pick.mark) or hp)
			if dies and dies <= w.to then
				if not tick then
					tick = strip.laneLow:CreateTexture(nil, "OVERLAY")
					tick:SetTexture(DEATH_COLOR[1], DEATH_COLOR[2], DEATH_COLOR[3], 1)
					p.ticks[k] = tick
				end
				tick:ClearAllPoints()
				tick:SetPoint("TOPLEFT", strip.laneRow, "TOPLEFT", x(dies) - x0 - 1, -laneY(2) - 1 - DEATH_EDGE)
				tick:SetSize(2, LANE_H - 1 - 2 * DEATH_EDGE)
				tick:Show()
				if dies < w.from then early = math.min(early or dies, dies) end
			elseif tick then
				tick:Hide()
			end
		end
		-- the label rides the zone, unless a star is going down before it: then it follows that tick, as a marker's
		if early then
			block(2, early, early + 10, SAFE_COLOR, 0, starKillText(w, t), false, nil, 1)
		else
			block(2, w.from, w.to, SAFE_COLOR, 0, starKillText(w, t), false, nil, 1, SAFE_INSET, true)
		end
		end
	end
	for i = #s.safes + 1, #strip.safes do
		for k = 1, 3 do strip.safes[i][k]:Hide() end
		strip.safes[i].kill:Hide()
		for _, tick in ipairs(strip.safes[i].ticks) do tick:Hide() end
	end
	for _, w in ipairs(s.swaps) do
		if w > t and w < stop then line(w, 1, 0.82, 0, true) end
	end
	-- whose lane it is, in three layers: the current tank's tag pinned at the now line; above it each swap's
	-- "Swap · Name" tag riding its swap line in, sliding over the current one; above both, the now line. Each
	-- tag is cut at the now line, so "Swap · " slides away under it, and once it's gone that tag is the pinned
	-- one. Nothing pops in or out.
	if not strip.tagRow then
		-- a plain frame, not a scroll frame: a tag's colour moving inside a scroll frame drew 2px past its own
		-- bottom, and snapped back when it stopped
		strip.tagRow = CreateFrame("Frame", nil, strip)
		strip.tagRow:SetPoint("TOPLEFT", x0, -PAD + TAG_LIFT)
		strip.tagRow:SetSize(STRIP_W + 2, TAG_BG)
		strip.tagRow:SetFrameLevel(strip.lineLayer:GetFrameLevel() + 1)
		strip.top = CreateFrame("Frame", nil, strip)
		strip.top:SetAllPoints()
		strip.top:SetFrameLevel(strip.tagRow:GetFrameLevel() + 30) -- over the tags (three levels a tag in view)
		-- into the border above and below, which covers its ends; wider than the lines it stands among, grown
		-- leftwards so the tags still go under it. Opaque grey, light in the middle and darker towards both ends,
		-- so it isn't a hard white bar: a gradient only runs between two ends, so it's three pieces
		local span = LANES_BOTTOM + LANE_GAP + RULER_H + PAD - 6 -- the whole strip, the ruler row too: 0 is at it
		local fade = span * 0.38
		local MID, TIP = 0.55, 0.25
		local function piece(from, height)
			local p = strip.top:CreateTexture(nil, "OVERLAY")
			p:SetTexture(1, 1, 1, 1)
			p:SetPoint("TOPLEFT", x0 - 1, -3 - from)
			p:SetSize(3, height)
			return p
		end
		piece(0, fade):SetGradientAlpha("VERTICAL", MID, MID, MID, 1, TIP, TIP, TIP, 1) -- bottom colour first
		piece(fade, span - 2 * fade):SetVertexColor(MID, MID, MID)
		piece(span - fade, fade):SetGradientAlpha("VERTICAL", TIP, TIP, TIP, 1, MID, MID, MID, 1)
		-- the border on its own frame, over everything in the strip
		strip.border = CreateFrame("Frame", nil, strip)
		strip.border:SetAllPoints()
		strip.border:SetBackdrop({edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16})
		strip.border:SetFrameLevel(strip.top:GetFrameLevel() + 1)
	end
	-- a frame per tag, by swap number (0: the tank at the pull), each layered over the one before: an incoming
	-- tag comes in over the current one, and settles as the same frame, never handing over to another. Layers
	-- count from the oldest tag in view, so a long fight's swap numbers never climb over the now line
	local base = s.lastSwap and math.max(0, s.lastSwap.number - 1) or 0
	-- limit: where a tag coming in over this one starts, so this one never shows past it on the right
	local function tag(number, name, px, swap, limit)
		if name == "" and not swap then return px end -- no tank to name
		local p = strip.tagFrames[number]
		if not p then
			p = CreateFrame("Frame", nil, strip.tagRow)
			p:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8"})
			-- the text in a scroll frame the size of the tag, which starts at the now line: the colour isn't in
			-- one, only the text, which draws true there
			p.clip = CreateFrame("ScrollFrame", nil, p)
			p.clip:SetAllPoints()
			p.child = CreateFrame("Frame", nil, p.clip)
			p.child:SetSize(400, TAG_BG)
			p.clip:SetScrollChild(p.child)
			p.text = p.child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			p.text:SetFont(STANDARD_TEXT_FONT, TAG_FONT, "OUTLINE")
			strip.tagFrames[number] = p
		end
		local cc = classColor(name) or {r = 0.6, g = 0.6, b = 0.7}
		p:SetBackdropColor(cc.r, cc.g, cc.b, 1)
		p.text:SetText(swap and (name ~= "" and "Swap \194\183 " .. name or "Swap") or name)
		p.text:SetTextColor(1, 1, 1) -- the outline keeps white readable on any class colour
		local w = p.text:GetStringWidth() + 6
		local left, right = math.max(px, 0), math.min(px + w, STRIP_W + 2, limit or math.huge) -- the now line and the strip's edge
		p:SetFrameLevel(strip.tagRow:GetFrameLevel() + 1 + 3 * (number - base))
		p:ClearAllPoints()
		p:SetPoint("TOPLEFT", left, 0)
		p:SetSize(math.max(1, right - left), TAG_BG)
		p.text:ClearAllPoints()
		p.text:SetPoint("LEFT", p.child, "TOPLEFT", px + 3 - left, -TAG_BG / 2) -- centred in the tag
		if right - left >= 1 then p:Show() end -- not yet in from the right
		return px + w
	end
	if not strip.prefix then -- how much of a tag is "Swap · ", to know when it has slid out of sight
		strip.prefix = strip.top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		strip.prefix:SetFont(STANDARD_TEXT_FONT, TAG_FONT, "OUTLINE")
		strip.prefix:Hide()
		strip.tagFrames = {}
	end
	-- where a swap's tag stops: its name as far past the now line as the pull's tag and the cooldowns' labels.
	-- "Swap · " measured on its own comes out wider than it sits in front of a name (the outline's padding), so
	-- measure it in place
	local function settledFor(name)
		strip.prefix:SetText("Swap \194\183 " .. name)
		local full = strip.prefix:GetStringWidth()
		strip.prefix:SetText(name)
		return -(full - strip.prefix:GetStringWidth())
	end
	for _, p in pairs(strip.tagFrames) do p:Hide() end
	-- the current tank's tag: the latest swap's, stopped where its "Swap · " has gone under the now line, or the
	-- pull's; while that swap's tag is still sliding in, the one it covers stays under it
	local last, first = s.lastSwap, s.lanes[1].tags[1]
	local coming = s.lanes[1].tags[2]
	local comingAt = coming and x(coming.time) - x0 + 2 -- the next swap's tag, sliding in over the current one
	if last then
		local settled = settledFor(last.to)
		local px = math.max(x(last.time) - x0 + 2, settled)
		tag(last.number, last.to, px, true, comingAt)
		if px > settled then
			if last.number > 1 then tag(last.number - 1, last.from, settledFor(last.from), true, px) else tag(0, last.from, 0, false, px) end
		end
	elseif first then
		tag(0, first.name, 0, false, comingAt)
	end
	for i, tg in ipairs(s.lanes[1].tags) do
		if i > 1 then tag(tg.number, tg.name, x(tg.time) - x0 + 2, true) end
	end
end

-- what I'm down for in a plan, so nobody learns it from the first warning sign: the card before the pull; say: the
-- timed list in chat too (/dbm cd mine); announce: the plan's tank order in chat, for leads and healers: "room" says
-- it (reaching the room), true only when it differs from the order last said (a plan with the tanks changed)
CP.toldOrder = {}	-- [plan id] = the tank order last said in chat
local function tellMine(id, say, announce)
	if AOE_ONLY then return end -- no cooldowns shown while tank planning is off
	local text = saved.plans[id]
	if not text or not DBM.Options.CooldownPlanEnabled then return end
	local list = {}
	local plan = CP.Parse(text)
	for _, r in ipairs(plan.rows) do
		if r.player == playerName then list[#list + 1] = clock(r.time) .. " " .. r.spell .. reason(r) end
	end
	-- before the pull, only in the boss's room (its mod's PrefightRoom): anywhere else it isn't wanted
	local mod = modFor(id)
	if not active and not (mod and mod.PrefightRoom and GetSubZoneText() ~= mod.PrefightRoom) then
		shownFor = mod
		showCard(plan.rows, 0, true, true)
		local tanks = announce and planTanks(plan.rows)
		local order = tanks and tanks[1] .. "\0" .. tanks[2]
		if tanks and (announce == "room" or order ~= CP.toldOrder[id]) then
			CP.toldOrder[id] = order
			local function colored(name)
				local cc = classColor(name)
				return cc and ("|cff%02x%02x%02x%s|r"):format(cc.r * 255, cc.g * 255, cc.b * 255, name) or name
			end
			DBM:AddMsg(("Cooldown plan tanks: %s, then %s."):format(colored(tanks[1]), colored(tanks[2])))
		end
	end
	if #list > 0 and say then
		DBM:AddMsg(("Your cooldowns on %s (%d):"):format(id, #list))
		for _, line in ipairs(list) do DBM:AddMsg("  " .. line) end
	end
end
CP.tellMine = tellMine

-- the raid leader's name, nil outside a raid
function CP.RaidLeader()
	for i = 1, GetNumRaidMembers() do
		local name, rank = GetRaidRosterInfo(i)
		if rank == 2 then return name end
	end
end
-- Reaching the boss's room before the pull: my card from the leader's plan, if I have it (one sent while I was away
-- comes on the pull, which is soon enough)
function CP.Prefight(mod)
	local id = tostring(mod.id):lower()
	if AOE_ONLY or not saved or not DBM.Options.CooldownPlanEnabled or mod:IsInCombat() or active then return end
	if saved.plans[id] and saved.planFrom[id] == CP.RaidLeader() then tellMine(id, nil, "room") end
end
-- Out of a raid: its plans go, so none is shown or run for a raid I've left
function CP.ForgetRaidPlans()
	if not saved then return end
	for id in pairs(saved.plans) do
		saved.plans[id], saved.planFrom[id], saved.auto[id], CP.lastSent[id], CP.lastInputs[id] = nil, nil, nil, nil, nil
	end
	if not active then
		if card then card:Hide() end
		if strip then strip:Hide() end
	end
end
function CP.LoadedRaid()
	if GetNumRaidMembers() > 0 then CP.inRaid = true else CP.ForgetRaidPlans() end
end

-- leaving the room before the pull
function CP.HidePrefight()
	if not active and card then card:Hide() end
end

-- a boss's options: lock or free the card and timeline at once; "Move" brings both up with a stand-in plan
-- (or hides them again) so they can be placed outside a fight
function CP.ApplyLock(mod)
	shownFor = shownFor or mod
	applyLock()
end
-- the mock fight's misuses: each picks its row off the generated plan, as the plan differs with who I play.
-- The re-plan then runs as the plan's sender's would in a real pull.
local function firstRow(rows, after, ok)
	for _, r in ipairs(rows) do
		if r.time >= after and ok(r) then return r end
	end
end
local function firstUse(rows, r) -- no earlier row of the same cooldown: it's ready from the pull
	for _, o in ipairs(rows) do
		if o ~= r and o.player == r.player and o.spell == r.spell and o.time < r.time then return false end
	end
	return true
end
local function testCast(at, r, text)
	active.script[#active.script + 1] = {at = at, run = function()
		sayTest(text)
		liveUse({player = r.player, spell = r.spell, time = GetTime() - pullTime, dur = r.dur, target = r.target})
	end}
end
local TEST_MISUSES = {
	missed = function(rows) -- a swap's big cooldown never pressed
		local r = firstRow(rows, 30, function(r) return r.note == "Tank swap" end)
		if not r then return end
		active.skip[r] = true
		return ("%s won't press %s for the swap at %s"):format(r.player, r.spell, clock(r.time))
	end,
	late = function(rows) -- an external 12s late: a no-show at 6s, then a cast off the plan
		local r = firstRow(rows, 30, function(r) return r.target and r.player ~= r.target end)
		if not r then return end
		active.skip[r] = true
		testCast(r.time + 12, r, ("%s presses %s on %s, 12s late"):format(r.player, r.spell, r.target))
		return ("%s will press %s (due %s) 12s late"):format(r.player, r.spell, clock(r.time))
	end,
	early = function(rows) -- a tank's own cooldown 15s early, so it's down when it was planned
		local trinket = {}
		for _, c in ipairs(active.pool) do if c.trinket then trinket[c.player .. "\0" .. c.spell] = true end end
		local r = firstRow(rows, 45, function(r) return r.player == r.target and not trinket[r.player .. "\0" .. r.spell] and firstUse(rows, r) end)
		if not r then return end
		active.skip[r] = true
		testCast(r.time - 15, r, ("%s presses %s 15s early"):format(r.player, r.spell))
		return ("%s will press %s (due %s) 15s early"):format(r.player, r.spell, clock(r.time))
	end,
	death = function(rows, me) -- a healer with uses ahead dies (not me: my own unit is alive, which reads as a rez)
		local r = firstRow(rows, 60, function(r) return r.target and r.player ~= r.target and r.player ~= me end)
		if not r then return end
		active.script[#active.script + 1] = {at = r.time - 10, run = function()
			sayTest(r.player .. " dies")
			liveDeath(r.player)
		end}
		return ("%s will die 10s before their %s at %s"):format(r.player, r.spell, clock(r.time))
	end,
	tankdeath = function(rows, me) -- the tank coming in at a swap dies before it: the other tank's rows are all that's left
		local r = firstRow(rows, 30, function(r) return r.note == "Tank swap" and r.player ~= me end)
		if not r then return end
		active.script[#active.script + 1] = {at = r.time - 10, run = function()
			sayTest(r.player .. " dies")
			liveDeath(r.player)
		end}
		return ("%s will die 10s before the swap at %s"):format(r.player, clock(r.time))
	end,
}

-- a mock fight with a stand-in raid (the usual roster, me as myself or its holy paladin), drawn through the real card and
-- timeline from the pull's 8.5s intro to Ascend, to see how they look and move; again to stop it.
-- misuse: one of TEST_MISUSES, so the fight goes off plan and is re-planned
function CP.TestFight(mod, misuse)
	if active and not active.test then return end -- a real pull is on
	if active then stop() return end
	if misuse and not TEST_MISUSES[misuse] then
		local names = {}
		for name in pairs(TEST_MISUSES) do names[#names + 1] = name end
		table.sort(names)
		DBM:AddMsg("/dbm cd test [" .. table.concat(names, "|") .. "]")
		return
	end
	-- you play yourself if you're in the roster, else its holy paladin
	local me = playerName
	for _, name in ipairs({"Onaqui", "Dracohouston", "Stickboard", "Illithris", "Halosylvan"}) do
		if name == me then me = "Shapiffany" end
	end
	-- power (% damage reduction) as players' clients report it: the planner pairs trinkets with the weakest
	local power = {[48792] = 51, [55233] = 30, [64763] = 10, [498] = 50, [64205] = 20, [6940] = 40, [1038] = 20, [31821] = 15, [33206] = 40,
		[642] = 0, [10278] = 0}
	local function C(player, spell, dur, cd, role, flag, flag2)
		local c = {player = player, spell = GetSpellInfo(spell) or tostring(spell), dur = dur, cd = cd, role = role, power = power[spell]}
		if flag then c[flag] = true end
		if flag2 then c[flag2] = true end
		return c
	end
	local hos = 6940 -- Hand of Sacrifice: never on its caster
	local pool = {
		C("Onaqui", 48792, 15, 120, "big"), C("Onaqui", 55233, 15, 60, "self"), C("Onaqui", 64763, 20, 120, "self", "trinket"),
		C("Dracohouston", 498, 15, 120, "big"), C("Dracohouston", 64763, 20, 120, "self", "trinket"),
		C("Dracohouston", 64205, 6, 120, "ext", "raid"), C("Dracohouston", hos, 12, 120, "ext", "notSelf"), C("Dracohouston", 1038, 10, 120, "self"),
		C(me, 64205, 6, 120, "ext", "raid"), C(me, hos, 12, 120, "ext", "notSelf"), C(me, 31821, 6, 120, "ext", "raid", "smashOnly"),
		C("Stickboard", 64205, 6, 120, "ext", "raid"), C("Stickboard", hos, 12, 120, "ext", "notSelf"), C("Stickboard", 31821, 6, 120, "ext", "raid", "smashOnly"),
		C("Illithris", 31821, 6, 120, "ext", "raid", "smashOnly"), C("Illithris", hos, 12, 120, "ext", "notSelf"),
		C("Halosylvan", 33206, 8, 144, "ext"),
	}
	-- every paladin's bubbles: a non-tank's Hand of Sacrifice goes up under one
	for _, name in ipairs({me, "Stickboard", "Illithris", "Dracohouston"}) do
		pool[#pool + 1] = C(name, 642, 12, 300, "bubble")
		pool[#pool + 1] = C(name, 10278, 10, 300, "bubble")
	end
	local rows = CP.Generate({pool = pool, tanks = {"Onaqui", "Dracohouston"}, weaker = "Dracohouston"})
	stop()
	shownFor = mod
	active = {rows = rows, test = true, classes = {Onaqui = "DEATHKNIGHT", Dracohouston = "PALADIN", [me] = "PALADIN",
		Stickboard = "PALADIN", Illithris = "PALADIN", Halosylvan = "PRIEST"}, pool = pool, weaker = "Dracohouston", skip = {}, script = {}}
	pullTime = GetTime() + 8.5
	CP.StarKillPicks = CP.MockStarPicks()
	wipe(done)
	fight = {uses = {}, dead = {}, missed = {}}
	if misuse then
		active.live = true
		local what = TEST_MISUSES[misuse](rows, me)
		DBM:AddMsg("Mock fight: " .. (what or "nothing in this plan to misuse that way, so it stays on plan"))
		table.sort(active.script, function(a, b) return a.at < b.at end)
	end
	ticker:Show()
end

function CP.ShowToMove(mod)
	if active then return end -- they're up for the fight already
	if (card and card:IsShown()) or (strip and strip:IsShown()) then
		if card then card:Hide() end
		if strip then strip:Hide() end
		return
	end
	shownFor = mod
	local other = "Other tank"
	local rows = {
		{time = 3, player = playerName, spell = "Your cooldown", dur = 12, target = playerName},
		{time = 22, player = playerName, spell = "Your next one", dur = 10, target = playerName},
		{time = 31, player = other, spell = "Their cooldown", dur = 12, target = other, note = "Tank swap"},
	}
	showCard(rows, 0, true)
	showStrip(rows, 0, true)
end

DBM:RegisterCallback("DBM_TimerStart", function(_, _, _, _, _, timerType)
	if timerType == "pull" and saved and saved.lastPlan then tellMine(saved.lastPlan) end
end)
DBM:RegisterCallback("DBM_Kill", stop)
DBM:RegisterCallback("DBM_Wipe", stop)

-- comms: L = plan line, Q = ask everyone for their CDs, C = one CD's duration and cooldown,
-- U = the plan's sender re-planned the rest of the fight, W = a hole it couldn't fill,
-- R = a plan arrived with lines missing (zoning mid-send): its sender whispers it again,
-- S = the raid leader's plan is unchanged: show your prefight card from it again
local incoming = {}
local received = {}	-- [sender .. "\0" .. plan id] = the last send of it received whole
local ASK_AFTER, ASK_TRIES = 3, 2	-- a plan still missing lines this long after the last one asks again, this many times

local function askMissing(sender, id)
	local inc = incoming[sender]
	if not inc or inc.id ~= id then return end -- complete, or a newer plan
	if GetTime() - inc.last < ASK_AFTER then
		DBM:Schedule(ASK_AFTER, askMissing, sender, id)
	elseif inc.asked < ASK_TRIES then
		inc.asked, inc.last = inc.asked + 1, GetTime()
		SendAddonMessage(PREFIX, "R\t" .. id, "WHISPER", sender)
		DBM:Schedule(ASK_AFTER, askMissing, sender, id)
	else
		incoming[sender] = nil
	end
end
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
events:RegisterEvent("SPELL_UPDATE_COOLDOWN")
events:RegisterEvent("RAID_ROSTER_UPDATE")
local toldReady = {} -- [spell] = when my cooldown was last seen back (GetTime)
for _, e in ipairs({"PLAYER_ENTERING_WORLD", "PLAYER_TALENT_UPDATE", "GLYPH_ADDED", "GLYPH_REMOVED", "GLYPH_UPDATED", "UNIT_INVENTORY_CHANGED"}) do
	events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_TALENT_UPDATE" or event:match("^GLYPH_") or (event == "UNIT_INVENTORY_CHANGED" and ... == "player") then
		DBM:Unschedule(computeMine)
		DBM:Schedule(1, computeMine)
		if event == "PLAYER_ENTERING_WORLD" then
			-- left the raid while away (or logged out of it): the roster reads empty for a moment on loading in, so
			-- only once it has had time to arrive
			local SETTLE = 10
			DBM:Unschedule(CP.LoadedRaid)
			DBM:Schedule(SETTLE, CP.LoadedRaid)
		end
	elseif event == "RAID_ROSTER_UPDATE" then
		if GetNumRaidMembers() > 0 then
			CP.inRaid = true
		elseif CP.inRaid then -- left it (a count of 0 on its own can be the roster not loaded yet)
			CP.inRaid = false
			CP.ForgetRaidPlans()
		end
	elseif event == "ADDON_LOADED" then
		if ... ~= "DBM-Core" then return end
		saved = DBM_CooldownPlans
		CP.BUBBLE_FULL, CP.BUBBLE_PHYS = GetSpellInfo(642) or CP.BUBBLE_FULL, GetSpellInfo(10278) or CP.BUBBLE_PHYS
		CP.WRATH, CP.SHIELD_GUARD, CP.LAY_ON_HANDS = GetSpellInfo(31884) or CP.WRATH, GetSpellInfo(498) or CP.SHIELD_GUARD, GetSpellInfo(48788) or CP.LAY_ON_HANDS
		CP.SALVATION = GetSpellInfo(1038) or CP.SALVATION
		saved.plans, saved.mine, saved.planFrom, saved.auto = saved.plans or {}, saved.mine or {}, saved.planFrom or {}, saved.auto or {}
		saved.mine[playerName] = saved.mine[playerName] or {}
		saved.prefightOver = nil -- a lockout-over mark an earlier version kept: the boss's room decides now
		reported[playerName] = saved.mine[playerName]
		for cast, c in pairs(data) do
			local name = GetSpellInfo(cast)
			if name then
				defaultByName[name], tracked[name], colorByName[name], shortByName[name] = {c.dur, c.cd, c.power}, true, STRIP_COLORS[cast], STRIP_SHORT[cast]
				roleByName[name], raidByName[name], trinketByName[name], smashOnlyByName[name], notSelfByName[name], healsByName[name] = c.role, c.raid, c.trinket, c.smashOnly, c.notSelf, c.heals
			end
		end
		for _, text in pairs(saved.plans) do track(text) end
	elseif event == "SPELL_UPDATE_COOLDOWN" then
		-- back sooner than last seen: the server cut it (Glyph of Guardian Spirit, when it saved no one). Say so again
		local now = GetTime()
		for spell, r in pairs(saved and saved.mine[playerName] or {}) do
			local wait = readyIn(spell)
			if wait > 0 and toldReady[spell] and now + wait < toldReady[spell] - 2 then
				sendOne(spell, r)
				heardReady(playerName, spell, wait) -- my own messages don't come back to me
			end
			toldReady[spell] = now + wait
		end
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, msg, _, sender = ...
		if prefix ~= PREFIX or sender == playerName or not saved then return end
		local kind = msg:sub(1, 1)
		if kind ~= "L" and kind ~= "U" then plog("got %s from %s", msg:gsub("\t", " "), sender) end
		if kind == "M" then
			reported[sender] = {} -- their whole list follows; a C on its own (back sooner, a first use measured) adds to it
		elseif kind == "C" then
			local _, spell, dur, cd, wait, power = strsplit("\t", msg)
			reported[sender] = reported[sender] or {}
			reported[sender][spell] = {dur = tonumber(dur), cd = tonumber(cd), power = tonumber(power), readyAt = GetTime() + (tonumber(wait) or 0)}
			heardReady(sender, spell, tonumber(wait) or 0)
		elseif kind == "T" then
			-- "T\t1\t<average item level>" or "T\t0"; an older client's "T\t1" sorts last
			local _, isTank, ilvl = strsplit("\t", msg)
			tankReported[sender] = isTank == "1" and (tonumber(ilvl) or 0) or nil
		elseif kind == "P" and active and active.live then
			-- a raider's own press (see the combat log handler); the same cast seen in the log too counts once
			local _, spell, t, dest = strsplit("\t", msg)
			t, dest = tonumber(t), dest ~= "" and dest or nil
			if spell and t then
				castSeen(sender, spell, dest, t, tracked[spell] and roleByName[spell] ~= "ext" and dest and dest ~= sender)
			end
		elseif kind == "Q" then
			sendMine()
		elseif kind == "S" then
			local id = msg:sub(3)
			if not active and sender == CP.RaidLeader() and saved.plans[id] and saved.planFrom[id] == sender then tellMine(id, nil, true) end
		elseif kind == "R" then
			local id = msg:sub(3)
			if saved.planFrom[id] == playerName and saved.plans[id] then
				-- under the send's own id when we still know it, so it only fills in what the asker is missing
				for _, m in ipairs(planMessages(id, saved.plans[id], sentAs[id]) or {}) do SendAddonMessage(PREFIX, m, "WHISPER", sender) end
			end
		elseif kind == "N" and active and sender == active.from then
			local _, t, player, spell = strsplit("\t", msg)
			t = tonumber(t)
			for i = #active.rows, 1, -1 do
				local r = active.rows[i]
				if t and r.player == player and r.spell == spell and math.abs(r.time - t) < 0.01 then table.remove(active.rows, i) end
			end
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
		elseif kind == "L" and DBM:GetRaidRank(sender) > 0 then
			local id, sendId, count, i, line = msg:match("^L\t([^\t]+)\t(%d+)\t(%d+)\t(%d+)\t(.*)$")
			if not id then return end
			sendId = tonumber(sendId)
			-- each send has its own id: a newer send starts over, so a resend is never finished by an older copy's
			-- lines, and lines of a send already received (or older) are late copies
			if sendId <= (received[sender .. "\0" .. id] or -1) then return end
			local inc = incoming[sender]
			if inc and inc.id == id and sendId < inc.send then return end
			if not inc or inc.id ~= id or sendId > inc.send then
				inc = {id = id, send = sendId, lines = {}, got = 0, asked = inc and inc.id == id and inc.asked or 0}
				incoming[sender] = inc
				DBM:Unschedule(askMissing, sender, id)
				DBM:Schedule(ASK_AFTER, askMissing, sender, id)
			end
			inc.last = GetTime()
			if not inc.lines[tonumber(i)] then inc.got = inc.got + 1 end
			inc.lines[tonumber(i)] = line
			if inc.got == tonumber(count) then
				incoming[sender] = nil
				received[sender .. "\0" .. id] = sendId
				DBM:Unschedule(askMissing, sender, id)
				local text = table.concat(inc.lines, "\n")
				local same = saved.plans[id] == text and saved.planFrom[id] == sender
				saved.plans[id] = text
				saved.planFrom[id] = sender
				saved.auto[id] = nil
				saved.lastPlan = id
				track(text)
				if CP.PlanChanged then CP.PlanChanged(id) end
				if not same then DBM:AddMsg(("Cooldown plan for %s received from %s."):format(id, sender)) end
				tellMine(id, nil, true)
				-- the leader's plan made on the pull: start on it now
				if pulled and pulled.id == id and pulled.mod:IsInCombat() and not AOE_ONLY then startPlan() end
			end
		end
	else
		local _, sub, sourceGUID, sourceName, _, destGUID, destName, _, spellId, spell = ...
		-- one of the caster's own cooldowns put on someone else (a threat Hand of Salvation) isn't the planned use,
		-- though its cooldown is gone all the same
		local offSelf = tracked[spell] and roleByName[spell] ~= "ext" and destName and destName ~= sourceName
		if active and not active.live and sub == "SPELL_CAST_SUCCESS" and sourceName == playerName and tracked[spell] and not offSelf then
			local i = CP.Match(active.rows, {player = sourceName, spell = spell, time = GetTime() - pullTime})
			if i then active.rows[i].done = true end
		end
		if active and sub == "SPELL_CAST_SUCCESS" and sourceName == playerName and active.taunts then
			local now = GetTime() - pullTime
			for _, r in ipairs(active.taunts) do
				if not r.done and spell == r.cast and math.abs(now - r.time) <= MATCH then r.done = true break end
			end
		end
		if active and spellId == 64412 and (sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_APPLIED_DOSE") then
			-- Phase Punch is on whoever has the boss; its stacks say when they'll hand over
			fight.holder, fight.stacks = destName, sub == "SPELL_AURA_APPLIED" and 1 or select(13, ...)
		end
		-- my own press goes to the raid too (P): phased in a Black Hole, nobody outside sees it in their combat log
		if active and not active.test and active.from ~= playerName and sub == "SPELL_CAST_SUCCESS" and sourceName == playerName
			and (tracked[spell] or spell == CP.WRATH) then
			send(("P\t%s\t%.1f\t%s"):format(spell, GetTime() - pullTime, destName or ""))
		end
		if active and active.live then
			if sub == "UNIT_DIED" and destName then
				liveDeath(destName)
			elseif sub == "SPELL_CAST_SUCCESS" and sourceName and (tracked[spell] or spell == CP.WRATH) then
				castSeen(sourceName, spell, destName, GetTime() - pullTime, offSelf)
			end
		end
		if not tracked[spell] or not sourceName then return end
		if sub == "SPELL_CAST_SUCCESS" or sub == "SPELL_AURA_APPLIED" then
			local now = GetTime()
			lastUsed[sourceName] = lastUsed[sourceName] or {}
			local used = lastUsed[sourceName][spell]
			if not used or now - used > 3 then lastUsed[sourceName][spell] = now end
		end
	end
end)

-- editor
-- /dbm cd's window: the plan as columns, read-only (plans are made, not written)
local view = {lines = {}}
local VIEW_X, VIEW_W, ROW_H = {0, 42, 126, 284, 318, 398}, {40, 82, 156, 32, 78, 92}, 15 -- time, player, cooldown, duration, target, note

local function colored(name)
	local cc = name and classColor(name)
	return cc and ("|cff%02x%02x%02x%s|r"):format(cc.r * 255, cc.g * 255, cc.b * 255, name) or name or ""
end

function view.line(i)
	local line = {}
	for k = 1, #VIEW_X do
		local fs = view.child:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
		fs:SetPoint("TOPLEFT", VIEW_X[k], -(i - 1) * ROW_H)
		fs:SetSize(VIEW_W[k], ROW_H)
		fs:SetJustifyH("LEFT")
		line[k] = fs
	end
	view.lines[i] = line
	return line
end

function view.fill()
	local f, id = view.frame, view.id
	local rows = CP.Parse(saved.plans[id] or "").rows
	f.title:SetText("Cooldown plan: " .. id)
	f.sub:SetText(#rows == 0 and "no plan yet" or ("made by %s, %d uses"):format(saved.planFrom[id] or "?", #rows))
	for i, r in ipairs(rows) do
		local line, swap = view.lines[i] or view.line(i), r.note == "Tank swap"
		line[1]:SetText("|cffa1a1a1" .. clock(r.time) .. "|r")
		line[2]:SetText(colored(r.player))
		line[3]:SetText(swap and "|cffffd100" .. r.spell .. "|r" or r.spell)
		line[4]:SetText(r.dur and ("|cffa1a1a1%gs|r"):format(r.dur) or "")
		line[5]:SetText(colored(r.target))
		line[6]:SetText(r.note and ((swap and "|cffffd100" or "|cffa1a1a1") .. r.note .. "|r") or "")
		for _, fs in ipairs(line) do fs:Show() end
	end
	for i = #rows + 1, #view.lines do
		for _, fs in ipairs(view.lines[i]) do fs:Hide() end
	end
	view.child:SetHeight(math.max(1, #rows * ROW_H))
	if DBM:GetRaidRank() == 2 then view.remake:Show() else view.remake:Hide() end
end

-- a plan made or received while the window shows it: shown as it is now
function CP.PlanChanged(id)
	if view.frame and view.frame:IsShown() and view.id == id then view.fill() end
end

function view.create()
	local f = CreateFrame("Frame", "DBMCooldownPlanView", UIParent)
	view.frame = f
	f:SetFrameStrata("DIALOG")
	f:SetSize(560, 380)
	f:SetPoint("CENTER")
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = {left = 11, right = 12, top = 12, bottom = 11},
	})
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	f.title:SetPoint("TOP", 0, -18)
	f.sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	f.sub:SetPoint("TOP", 0, -34)
	f.sub:SetTextColor(0.63, 0.63, 0.63)
	for k, name in ipairs({"Time", "Player", "Cooldown", "Dur", "Target", "Note"}) do
		local h = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		h:SetPoint("TOPLEFT", 22 + VIEW_X[k], -54)
		h:SetTextColor(0.63, 0.63, 0.63)
		h:SetText(name)
	end
	local rule = f:CreateTexture(nil, "ARTWORK")
	rule:SetTexture(1, 1, 1, 0.15)
	rule:SetHeight(1)
	rule:SetPoint("TOPLEFT", 22, -69)
	rule:SetPoint("TOPRIGHT", -42, -69)
	local scroll = CreateFrame("ScrollFrame", "DBMCooldownPlanViewScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 22, -74)
	scroll:SetPoint("BOTTOMRIGHT", -42, 48)
	view.child = CreateFrame("Frame", nil, scroll)
	view.child:SetSize(490, 1)
	scroll:SetScrollChild(view.child)
	local function button(text, x, onClick)
		local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		b:SetSize(80, 22)
		b:SetPoint("BOTTOM", x, 16)
		b:SetText(text)
		b:SetScript("OnClick", onClick)
		return b
	end
	view.remake = button("Remake", -50, function() CP.Remake(view.id) end)
	button(CLOSE, 50, function() f:Hide() end)
	tinsert(UISpecialFrames, "DBMCooldownPlanView")
end

-- /dbm cd [boss]: show that boss's plan (default Algalon); /dbm cd mine: my cooldowns in the last plan;
-- /dbm cd log: the planner's log (saved variables) on or off;
-- /dbm cd replan: make the plan again now (leader);
-- /dbm cd test [missed|late|early|death]: start or stop a mock fight, with that cooldown misuse re-planned
function DBM:CooldownPlanCommand(arg)
	arg = trim(arg or ""):lower()
	if arg == "log" then
		saved.logOn = not saved.logOn or nil
		DBM:AddMsg(("Cooldown plan log %s."):format(saved.logOn and "on: it's written to the saved variables on a reload or logout" or "off"))
		return
	end
	if arg == "mine" then
		if saved.lastPlan then tellMine(saved.lastPlan, true) end
		return
	end
	if arg == "replan" then
		CP.Remake(view.id or "algalon")
		return
	end
	local misuse = arg:match("^test%s*(%a*)$")
	if misuse then -- temporary: the mock fight without going through Algalon's options
		CP.TestFight(DBM:GetModByName("Algalon"), misuse ~= "" and misuse or nil)
		return
	end
	view.id = arg ~= "" and arg or "algalon"
	if not view.frame then view.create() end
	view.fill()
	view.frame:Show()
end
