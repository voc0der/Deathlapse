# Contributing

Thanks for working on `Deathlapse`.

Keep changes focused on the death timeline, event capture, and the minimap button. This repo does not need extra process or feature sprawl.

## Local Setup

- Target client: TBC Anniversary Classic
- Addon install path: `World of Warcraft/_anniversary_/Interface/AddOns/`
- Main runtime files are listed in [Deathlapse.toc](Deathlapse.toc)

## Development

Keep a local Blizzard UI mirror at `../wow-ui-source`. If you do not already have it:

```bash
git clone https://github.com/Gethe/wow-ui-source ../wow-ui-source
```

Refresh before starting work:

```bash
git -C ../wow-ui-source pull --ff-only
```

Use `../wow-ui-source` first for TOC interface numbers, FrameXML, and Blizzard UI/API questions before changing addon code or guessing at client behavior.

Run the local test suite:

```bash
lua tests/run.lua
```

Run a syntax check before opening a PR:

```bash
luac -p Deathlapse.lua tests/run.lua
```

If you change packaging or release behavior, verify the runtime-only package contents:

```bash
bash ./.github/scripts/verify-release-package.sh
```

## Project Expectations

- Keep the addon focused on death recap display and event capture.
- Prefer small, targeted changes over broad rewrites.
- If you add a new runtime file, include it in [Deathlapse.toc](Deathlapse.toc).
- Player-facing packages should only include files the game client actually needs.

## Pull Requests

- Use conventional commit titles: `feat(...)`, `fix(...)`, `docs(...)`, or `ci(...)`.
- Include a short summary of what changed and how you verified it.
- If the change affects game UI, include screenshots or a description of visible behavior.
- Add the `build` label when you want the PR package workflow to post a downloadable artifact.
- Keep PRs scoped to one logical change when possible.

## Releases

- Release steps are documented in [RELEASING.md](RELEASING.md).
- Version bumps should update the addon version in [Deathlapse.toc](Deathlapse.toc) and add a section to [CHANGELOG.md](CHANGELOG.md).
