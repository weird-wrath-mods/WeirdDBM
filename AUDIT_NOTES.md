# DBM-CC timer audit vs ChromieCraft server scripts

Cross-checked against `azerothcore-wotlk` (chromiecraft fork) at commit 5f5c287, 2026-05-17.
Server boss scripts in `src/server/scripts/Northrend/`.

Findings categorized:
- **DBM bug**: timer in DBM doesn't match server behavior — fix DBM.
- **Server bug**: cpp script is missing a mechanic that retail had — fix chromiecraft.
- **Conflict**: DBM and cpp disagree, need in-game verification before deciding which to change.
- **Minor**: under 2s drift, cosmetic.

---

## DBM-VoA

### Emalon (DBM bug)
- `Emalon.lua:40` `timerNovaCD:Start(20-delay)` — first Nova at 20s, but cpp `boss_emalon.cpp:143` schedules `EVENT_LIGHTNING_NOVA` at 40s. **Change initial to 40s.**
- `Emalon.lua:24` `timerOvercharge = NewNextTimer(45, ...)` — cpp `boss_emalon.cpp:183` `events.Repeat(40s)`. **Change to 40s.**

### Toravon (DBM bug)
- `Toravon.lua:26` `timerNextOrb = NewNextTimer(38, ...)` — cpp `boss_toravon.cpp:140` `events.Repeat(30s)`. **Change to 30s.**

### Toravon (Conflict — in-game test needed)
- `Toravon.lua:32` `timerWhiteout:Start(12.8-delay)` — cpp `boss_toravon.cpp:101` schedules first Whiteout at 25s. DBM observation says 12.8s. One is wrong.

### Koralon (Conflict — in-game test needed)
- `Koralon.lua:32` `timerNextMeteor:Start(44.9-delay)` — cpp `boss_koralon.cpp:94` schedules first Meteor Fists at 30s. DBM observation says 44.9s.

### Koralon (Server bug)
- DBM has `timerKoralonEnrage = NewBerserkTimer(300)`. cpp `boss_koralon.cpp` has no `EVENT_BERSERK` or any berserk scheduling. **Retail Koralon had 5min enrage; chromiecraft cpp is missing it.**

---

## DBM-Naxx

### Grobbulus (Conflict — verify mode)
- `Grobbulus.lua:64-68`: DBM 10man=540s, 25man=720s berserk.
- cpp `boss_grobbulus.cpp:105` `RAID_MODE(720s, 540s)` → 10man=720s, 25man=540s.
- Values inverted between DBM and cpp. Retail Grobbulus enrage = 9min on both modes per most sources.

### Sapphiron (Conflict — in-game test needed)
- `Sapphiron.lua:39` `timerAirPhase = NewTimer(55, ...)` — air-phase ground-cycle width 55s.
- cpp `boss_sapphiron.cpp:289` `EVENT_FLIGHT_START` `events.Repeat(45s)` — start-to-start cycle 45s.
- DBM pull-timer 45.74s matches cpp, but subsequent ground width 55s is 10s longer than cpp cycle.

### Missing berserk timers in DBM (cpp has them)
- Anub'Rekhan: cpp `JustEngagedWith` `ScheduleEnrageTimer(SPELL_BERSERK, 10min)`.
- Horsemen: cpp `RescheduleEvent(EVENT_BERSERK, 10min)`.
- Kel'Thuzad: cpp `ScheduleEvent(EVENT_ENRAGE, 15min)` in P1.

### Minor (sub-2s drift, cosmetic)
- Thaddius `timerThrow` 20.6s vs cpp 20s.
- Thaddius `timerNextShift` initial 21.8s vs cpp 20s.
- Sapphiron `timerTailSweep:Start(-delay)` (effectively 0s) vs cpp 10s pull schedule.

---

## DBM-EyeOfEternity

### Malygos (DBM bug)
- `Malygos.lua:23` `NewBerserkTimer(615)`. cpp `boss_malygos.cpp:401` `RescheduleEvent(EVENT_BERSERK, 10min)`. **Change to 600s.**

### Malygos (Conflict — verify)
- Vortex CD: cpp `boss_malygos.cpp:488` `RescheduleEvent(EVENT_START_VORTEX_0, 60s)` after land + ~25s vortex flight ≈ 85s start-to-start. DBM `Malygos.lua:34` `NewCDTimer("v72-74", ...)` — observed 72-74s. Either cpp's vortex actually completes faster than the 25s DelayEvents (=> ~72s), or DBM is timing land-to-cast.

---

## DBM-ChamberOfAspects

### Sartharion (Missing berserk in DBM)
- cpp `boss_sartharion.cpp:365` `ScheduleEvent(EVENT_SARTHARION_BERSERK, 15min)` — also fires on <30% HP via `DamageTaken`. DBM has no berserk timer. Add `NewBerserkTimer(900)`.

### Saviana (Minor drift)
- `Saviana.lua:70` `timerBreath:Start(14-delay)` — cpp first Flame Breath at 10s. 4s late.
- `Saviana.lua:69` `timerConflagCD:Start(30.1-delay)` — cpp first Conflag (via flight at 30s) ≈ 31s. Close.
- `Saviana.lua:26` `timerConflagCD = NewCDTimer(63.8, ...)` — cpp model ≈ 57s (50s flight + 7s ground). Observation 63.8s. 6s off, may include cast/travel.

### All other CoA bosses
Baltharus, Zarithrian, Halion (incl. P2 Twilight): clean.
Drake-only mods (Tenebron/Shadron/Vesperon): no timers to audit — only show Shadow Fissure cast warning.

---

## Notes

- cpp `events.Repeat(N)` is start-to-start of the same event; cast time and `UNIT_STATE_CASTING` gating may add 1-3s in-game.
- DBM `NewCDTimer`/`NewNextTimer` measure cast-start to cast-start when driven by `SPELL_CAST_START`/`SPELL_CAST_SUCCESS`.
- These are usually directly comparable; sub-2s drift can come from animation/cast-time and isn't worth chasing.
