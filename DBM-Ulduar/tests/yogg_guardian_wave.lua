-- Checks the Yogg-Saron P1 guardian wave chain against boss_yoggsaron.cpp and Spell.dbc.
--
-- Script rules under test:
--   EVENT_SARA_P1_SUMMON is due at the pull and on execution does
--     events.Repeat(20000 - min(_summonedGuardiansCount, 5) * 2000); ++_summonedGuardiansCount  (:919)
--   so the interval runs from EXECUTION, not from when the tick came due.
--   UpdateAI returns early while Sara is casting (:906), so a tick due mid-cast executes only when
--   that cast ends, and every later wave inherits the shift.
--   Her P1 target-selector cast is 4s on a 4.9s cycle (:938).
--   EVENT_SARA_P1_SPELLS is armed when the doors close at 15s, so her first cast is at t=15.
-- Spell.dbc:
--   63031 is a periodic trigger of 62979 with EffectAuraPeriod_1 = 10000, so the guardian appears
--   exactly 10s after its tick ran.
--   63134/63138/63147 have CastingTimeIndex 15 = 4000ms, the cast that holds her in UNIT_STATE_CASTING.
-- The log has no yells, so each pull is anchored on Sara's first cast, which the script puts at
-- exactly pull+15: the doors close at 15s and arm EVENT_SARA_P1_SPELLS at 0ms.
--
-- Nothing here is fitted. Both constants come from the DBC, the gaps from the script.

local SARA_P1_CAST = 4
local GUARDIAN_CLOUD_DELAY = 10
local guardianGaps = {20, 18, 16, 14, 12}--gap after wave N, 10s from wave 6 on

-- Sara's SPELL_CAST_START times and guardian SPELL_SUMMON times, seconds from the pull, from the
-- 21 Sep 2026 Ulduar log (4 pulls).

local SARA_P1_CAST = 4
local GUARDIAN_CLOUD_DELAY = 10
local GUARDIAN_JITTER = 0.4
local guardianGaps = {20, 18, 16, 14, 12}--gap after wave N, 10s from wave 6 on

local pulls = {
	{casts = {15.0, 19.91, 24.83, 29.74, 34.66, 39.57, 44.49, 54.31, 59.24, 64.23, 69.16, 74.11, 78.97, 83.88, 88.79, 93.69, 98.6, 103.53, 108.45, 113.36, 118.29, 123.27, 128.21, 133.15, 138.05, 143.06},
	 spawns = {10.15, 33.95, 53.62, 73.35, 88.09, 102.81, 112.85, 113.67, 122.88, 123.68, 132.93, 137.57, 139.85, 141.95, 142.97, 147.57}},
	{casts = {15.0, 19.94, 24.83, 34.66, 39.58, 44.56, 54.38, 59.29, 64.21, 74.01, 78.96, 83.95, 88.86, 93.77, 98.79, 103.7, 108.69, 113.59, 118.51, 123.43, 128.46, 133.36, 138.28},
	 spawns = {10.06, 33.94, 53.67, 73.32, 88.05, 102.89, 112.91, 122.92, 132.93, 143.01, 143.01}},
	{casts = {15.0, 19.93, 24.84, 29.75, 34.67, 39.66, 44.57, 49.47, 54.39, 59.29, 64.21, 74.07, 78.97, 83.88, 88.88, 93.8, 98.8, 103.81, 108.8, 113.81, 118.81, 123.83, 128.82},
	 spawns = {9.91, 33.88, 53.63, 73.26, 88.08, 89.27, 102.79, 112.97, 122.82, 132.83}},
	{casts = {15.0, 19.99, 29.82, 34.82, 39.73, 44.65, 49.54, 54.44, 59.36, 64.27, 69.17, 74.09, 79.09, 88.92, 93.91, 98.88, 103.74, 108.75, 113.74, 118.65, 123.59, 128.56},
	 spawns = {9.98, 34.02, 53.76, 73.38, 88.2, 103.03, 113.04, 123.11, 133.07}},
}

-- Mirror of guardianWave() / saraCastStall() / guardianSpawned(): a tick may run either when it
-- comes due or at the end of the one cast that swallows it, and a spawn is believed only if the
-- tick it implies matches one of those two.
local function replay(pull)
	local due, stalled, wave, castEnd = 0, nil, 1, nil
	local events, accepted, rejected = {}, {}, {}
	for _, c in ipairs(pull.casts) do events[#events + 1] = {t = c, cast = true} end
	for _, x in ipairs(pull.spawns) do events[#events + 1] = {t = x} end
	table.sort(events, function(a, b) return a.t < b.t end)
	for _, e in ipairs(events) do
		if e.cast then
			castEnd = e.t + SARA_P1_CAST
			if not stalled and due > e.t and due < castEnd then
				stalled = castEnd
			end
		else
			local exec = e.t - GUARDIAN_CLOUD_DELAY
			local pick
			if stalled and math.abs(exec - stalled) <= GUARDIAN_JITTER then pick = stalled
			elseif math.abs(exec - due) <= GUARDIAN_JITTER then pick = due end
			if pick then
				accepted[#accepted + 1] = e.t
				due = pick + (guardianGaps[wave] or 10)
				wave = wave + 1
				-- A cast already running when the new tick comes due swallows it too. Once the gap is
				-- 10s it equals the cloud delay, so the tick comes due exactly now and only this sees it.
				stalled = (castEnd and castEnd > due and due >= castEnd - SARA_P1_CAST) and castEnd or nil
			else
				rejected[#rejected + 1] = e.t
			end
		end
	end
	return accepted, rejected
end

-- Regression: a tick coming due inside a cast that is ALREADY running stalls just as one that a
-- cast starts on top of. None of the logged pulls reach this -- their fast-range ticks all land in
-- the 0.9s gap between her casts -- but it is the case that broke in game, because at a 10s gap the
-- tick comes due the very instant the guardian appears, with no later cast event to speak for it.
local function stalls(due, castEnd)
	return (castEnd and castEnd > due and due >= castEnd - SARA_P1_CAST) and castEnd or nil
end
assert(stalls(100, 103) == 103, "a tick due 1s into a running cast must slip to its end")
assert(stalls(100, 100) == nil, "a cast ending exactly as the tick comes due does not hold it")
assert(stalls(100, 105) == nil, "a cast that only starts after the tick came due cannot hold it")
assert(stalls(100, nil) == nil, "no cast in flight, no stall")

local totalAccepted, totalRejected = 0, 0
for i, pull in ipairs(pulls) do
	local accepted, rejected = replay(pull)

	-- Wave 1 is due at the pull and cannot be stalled: her first cast is at t=15.
	assert(math.abs(accepted[1] - GUARDIAN_CLOUD_DELAY) <= GUARDIAN_JITTER,
		("pull %d: first wave at %.2fs, the 63031 period puts it at %ds")
			:format(i, accepted[1], GUARDIAN_CLOUD_DELAY))

	-- _summonedGuardiansCount only ever shortens the interval to a 10s floor, so two scheduled waves
	-- can never be closer than that. Anything nearer is a player walking into an Ominous Cloud
	-- (:1120); accepting one would show up here. Sync must also hold to the end of the pull, so no
	-- two accepted waves may be further apart than the 20s opening gap plus one stalled cast.
	for w = 2, #accepted do
		local span = accepted[w] - accepted[w - 1]
		assert(span >= 10 - GUARDIAN_JITTER,
			("pull %d: accepted waves %.2fs apart, under the 10s floor -- that was a cloud spawn")
				:format(i, span))
		assert(span <= 20 + SARA_P1_CAST + GUARDIAN_JITTER,
			("pull %d: lost sync, %.2fs between accepted waves %d and %d")
				:format(i, span, w - 1, w))
	end

	totalAccepted = totalAccepted + #accepted
	totalRejected = totalRejected + #rejected
end

assert(totalAccepted >= 34, "expected at least 34 scheduled waves, got " .. totalAccepted)
assert(totalRejected >= 2, "the logs contain player-triggered cloud spawns; none were refused")
print(("yogg_guardian_wave: ok (%d waves accepted, %d cloud spawns refused, %d pulls, no fitted constants)")
	:format(totalAccepted, totalRejected, #pulls))
