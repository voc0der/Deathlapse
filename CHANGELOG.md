## [Unreleased]

## [1.1.3] - 2026-04-25

### Added
- `/dl about` command showing that Deathlapse was made by voc0der and linking to the GitHub repository

## [1.1.1] - 2026-04-24

### Added
- Resizable death recap frame with saved dimensions and `/dl reset`
- ElvUI skin detection for the recap frame when ElvUI is loaded
- Full-health/top-off clipping so the recap shows the meaningful final window up to 20 seconds
- Clip summary line showing total damage and visible sequence duration
- Test coverage for clipped death windows

### Changed
- Widened the default recap frame and made chart geometry respond to frame size
- Softened damage/heal/HP colors and grid opacity
- Reduced footer overlap by scaling icons, embedding hit counts in icons, and thinning time labels on dense charts

## [1.1.0] - 2026-04-23

### Changed
- Complete visual redesign modelled on the Heroes of the Storm death recap
- Timeline replaced by a waterfall HP bar chart: each column is one hit-group; the blue bar shows remaining HP, the red cap shows damage taken, green cap for heals
- Same-spell hits from the same source within 1 second are merged into a single column showing a ×N count, reducing DoT tick noise
- Spell icons (from `GetSpellInfo`) shown below each column; melee falls back to the ability icon, environmental to the drowning icon
- Time-before-death label beneath each icon
- Top attackers summary strip shows attacker names with their share of total damage
- HP trajectory reconstructed backwards from death using event amounts and overkill values — no separate UNIT_HEALTH tracking required
- White separator line at the hpAfter level clearly marks the transition between remaining HP and damage taken
- Overkill columns rendered in brighter red with the killing-blow column sized to the effective (non-overkill) damage
- Frame widened to 560 px; chart area 130 px tall with 25/50/75% gridlines and a Y-axis percentage strip
- `GroupX`, `ColWidth`, `HpY`, `ComputeHpTrajectory`, `GroupEvents` exported for test coverage (54 tests passing)
- `/dl test` generates a realistic multi-source scenario including DoT groups, heals, and an overkill kill shot

## [1.0.0] - 2026-04-22

### Added
- Initial release
- Horizontal death timeline showing the last 20 seconds of combat events before death
- Damage events rendered as colored vertical bars above the axis, scaled logarithmically by amount
- Heal events rendered as green bars below the axis
- Color-coded by damage school: Physical, Holy, Fire, Nature, Frost, Shadow, Arcane
- Overkill events highlighted in bright red with increased bar width
- Critical hits shown at full opacity with wider bars
- Hover tooltip over each marker showing source, spell, amount, and time offset
- Automatic display on `PLAYER_DEAD`; auto-hides on `PLAYER_ALIVE` / `PLAYER_UNGHOST`
- Minimap button (draggable around minimap) as the sole UI entry point
- Red dot indicator on minimap button when death data is available
- Killer identification with overkill-event preference
- Summary header: killer name, hit count, total damage, heal count, total healed
- `/dl test` command for previewing the timeline with synthetic data
- `/dl autoshow` toggle for controlling whether timeline appears automatically on death
- Draggable timeline frame with saved position
- Close-on-Escape support via `UISpecialFrames`
- SavedVariables: minimap position, timeline frame position, showOnDeath preference
- TBC Anniversary Classic (Interface 20505)
