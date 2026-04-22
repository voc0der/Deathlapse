## [Unreleased]

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
