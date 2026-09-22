-- Checks the Yogg-Saron phase 3 Immortal Guardian chain against boss_yoggsaron.cpp and Spell.dbc.
--
-- Script rules under test:
--   EVENT_YS_SUMMON_GUARDIAN is armed at 0ms when the Shadowy Barrier comes off, and on execution
--   does SummonImmortalGuardian(); events.Repeat(10s)                                (:1290, :1359)
--   Yogg's UpdateAI returns early while he is casting (:1338), and Repeat() measures from
--   EXECUTION, so a tick due mid-channel runs at the end of it and every later add inherits that.
--   The add is created rooted and passive for SPAWN_STASIS_TIME (:2001) but is attackable
--   throughout, so the bar marks the summon. Raid log 2026-09-22: each add first took damage
--   1.9-3.0s after its predicted tick, which is pickup time, so the tick is the spawn.
-- Spell.dbc:
--   64163 Lunatic Gaze carries SPELL_ATTR1_CHANNELED_2 with a 4000ms duration, so it holds him in
--   UNIT_STATE_CASTING for 4s. He re-rolls it on Repeat(13s, 22s), so it cannot be precomputed.

local TICK = 10
local STASIS = 0--the bar marks the tick itself
local CHANNEL = 4

-- Mirror of immortalGuardianWave() / lunaticGazeStall() in YoggSaron.lua. Returns the times the
-- bars expire, which must be the times the adds actually go live.
local function replay(channels, n)
	local due, out, ci = 0, {}, 1
	for _ = 1, n do
		-- a channel starting before this tick, and still running when it comes due, holds it
		while channels[ci] and channels[ci] + CHANNEL <= due do ci = ci + 1 end
		local c = channels[ci]
		if c and c < due and due < c + CHANNEL then due = c + CHANNEL end
		out[#out + 1] = due + STASIS
		due = due + TICK
	end
	return out
end

local function eq(got, want, what)
	for i = 1, #want do
		assert(math.abs(got[i] - want[i]) < 0.001,
			("%s: add %d goes live at %.1fs, bar expires %.1fs"):format(what, i, want[i], got[i]))
	end
end

-- Undisturbed: first add is summoned by the phase change and goes live one stasis later, then flat.
eq(replay({}, 6), {0, 10, 20, 30, 40, 50}, "no channel")

-- A channel from 18 to 22 swallows the tick due at 20, which then runs at 22. Every later add
-- inherits the 2s, because Repeat() runs from execution.
eq(replay({18}, 5), {0, 10, 22, 32, 42}, "channel over a tick")

-- A channel that ends before a tick comes due changes nothing.
eq(replay({15}, 4), {0, 10, 20, 30}, "channel clear of every tick")

-- A channel ending exactly as a tick comes due does not hold it: the early return is checked
-- before ExecuteEvent, and by then he is no longer casting.
eq(replay({18, 28}, 5), {0, 10, 22, 32, 42}, "channel ending on the tick")

-- Two stalls accumulate rather than cancelling. After the first, tick 4 falls due at 32, so it
-- takes a channel still running then to hold it again.
eq(replay({18, 30}, 5), {0, 10, 22, 34, 44}, "two stalls")

-- The bar must never be shorter than the gap between adds going live, or a restart would truncate
-- the one still running. This is what broke when the stasis was added to each bar's length.
local live = replay({18, 45, 70}, 12)
for i = 2, #live do
	assert(live[i] - live[i - 1] >= TICK - 0.001,
		("adds %d and %d go live %.1fs apart, under the %ds tick"):format(i - 1, i, live[i] - live[i - 1], TICK))
end

print("yogg_immortal_guardian: ok (channel " .. CHANNEL .. "s, tick " .. TICK .. "s)")
