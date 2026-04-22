# Deathlapse

A death-recap timeline for WoW TBC Anniversary Classic.

When you die, a horizontal strip appears showing everything that hit you — and healed you — during the 20 seconds before it happened. Each bar's height is proportional to the hit size. Hover any bar to see the source, spell, amount, and timing. The panel hides automatically when you're alive again.

The entire addon lives on the minimap. A small skull button orbits it; click it to toggle the panel or drag it to reposition. A red dot appears on the button when death data is available.

## Installation

Drop the `Deathlapse` folder into:

```
World of Warcraft/_anniversary_/Interface/AddOns/
```

## Usage

The timeline appears automatically when you die. Hover bars for details. Click the minimap button to show or hide it manually.

Slash commands via `/deathlapse` or `/dl`:

| Command | Effect |
|---------|--------|
| *(no args)* | Toggle timeline |
| `show` | Show timeline |
| `hide` | Hide timeline |
| `clear` | Clear the current death record |
| `minimap` | Toggle minimap button visibility |
| `autoshow` | Toggle auto-show on death (default: on) |
| `test` | Show a fake timeline for testing the UI |
| `help` | List commands |

## What the Timeline Shows

- **Above the axis** — incoming damage. Color indicates school (Physical, Fire, Shadow, Frost, Nature, Holy, Arcane). Overkill events are bright red.
- **Below the axis** — incoming heals. Green.
- **Bar height** — logarithmic scale; taller = more damage or healing.
- **Wider bars** — critical hits.
- **Header** — killer name, spell used, total hits, and totals for damage and healing.
- **Time axis** — left edge = 20 seconds before death, right edge = death moment.

## Color Reference

| School | Color |
|--------|-------|
| Physical | Orange-red |
| Holy | Gold |
| Fire | Orange |
| Nature | Green |
| Frost | Blue |
| Shadow | Purple |
| Arcane | Pink |
| Overkill | Bright red |
| Heal | Green |
