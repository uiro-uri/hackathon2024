# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## Project overview

"Slay the Spinner" is a Beyblade-style battler crossed with a Slay-the-Spire-style branching map
and rarity-weighted roguelike upgrades. Two spinning tops collide in a sloped stadium; whoever's
rotation speed (`rps`) runs out first loses.

The game is being **rebuilt in Godot 4** targeting browser (HTML5 export) and Steam (native
export). The Godot project lives in `godot/`.

`archive/flask-prototype/` holds the original Flask implementation. **It is frozen reference
only — do not extend it.** It validated the game design, but it computed physics server-side per
HTTP request and replayed the result as CSS `@keyframes`, which is not a real-time client game and
cannot ship to a browser or Steam.

## Working on the Godot project

Godot 4.7.x is the tested version — CI installs 4.7.1 stable and `project.godot` tags feature `4.7`;
the same binary is both the editor and the headless CLI.

```bash
scripts/verify.sh           # everything (see below)
scripts/verify.sh --quick   # skip the rendering checks
```

**On WSL, do not open this project with the Windows build of Godot.** Anything Windows writes into
the WSL filesystem through `\\wsl.localhost\` lands as **root-owned — no sudo involved**, because
WSL's 9P file server runs as root. Merely opening the project in Windows Godot makes
`project.godot` and `.godot/` root-owned, and then: imports fail on permissions, `.import` files
get rewritten to `valid=false`, and you silently get builds with the font and translations missing
(exit 0 throughout); git can no longer switch branches because it cannot overwrite
`project.godot`; Godot spews `shader_gles3.cpp` errors because it cannot write its shader cache.
Launching the editor with sudo causes the same thing.

Use the WSL-side Godot instead — WSLg puts the window on the Windows desktop, and it skips 9P so
imports are faster:

```bash
~/bin/godot4 --path godot -e
```

Recovering needs no sudo as long as the parent directory is yours: `rm -rf godot/.godot` and
`git checkout -- godot/project.godot`. `verify.sh` stage 0 detects the state.

### Verification

Exit codes are not trusted here — a build with the font and translations missing exited 0. Each
stage of `scripts/verify.sh` has a substantive pass criterion:

| Stage | Criterion |
|---|---|
| 0. preflight | everything under `godot/` is owned by us (the root-ownership trap above) |
| 1. import ×2 | the **2nd** run has no errors (the 1st legitimately errors: `.translation` files and the font aren't generated yet at boot) |
| 2. tests | exit code **and** the completed-test count — a GDScript runtime error aborts a function without failing the run |
| 3. headless run | no errors from `--quit-after` |
| 4. export ×3 | exit code, a `.pck` size floor, **and** that the Web preset's `variant/thread_support` is off — enabling it makes Godot demand SharedArrayBuffer, which needs COOP/COEP headers that GitHub Pages cannot serve, so the game would break in production only |
| 5. native render | launch the **exported** Linux binary, capture via `--write-movie`, assert non-blank |
| 6. web render | Chromium on the served export, at both landscape (1280×720) and portrait (SP = phone in a mobile browser; no dedicated build): Godot booted, no JS errors, canvas non-blank |
| 7. SP screen flow | portrait Chromium navigates Title→Map→Battle; each screen booted, no errors, canvas non-blank, **and the screen actually changed** after each click — catches the responsive Map/Battle layout breaking |

Stage 5 deliberately runs `build/linux/slay-the-spinner.x86_64`, not `--path godot`. Running the
project only proves the editor can play it from source; a broken binary/pck pairing would sail
through. What ships is the export, so the export is what gets launched.

Stages 5–7 leave images in `build/verify/` to eyeball: `native.png`, `web.png` (landscape),
`sp.png` (phone-portrait Title), and `sp_map.png` / `sp_battle.png` (phone-portrait Map/Battle).
The SP portrait size defaults to 390×844 (`SP_W`/`SP_H`); the portrait vertical bias used by the
screenshot navigator defaults to 0.7 (`SP_BIAS`) and must match the screens' `portrait_vertical_bias`
so the harness clicks land on the (moved) map node.

Stage 7's Title click is found by **scanning the rendered pixels** for the button, not by a computed
offset. The offset it used before ("screen centre + 19px") silently drifted as the Title's contents
changed: the click landed on nothing, `sp_map.png` was really a screenshot of Title, and the stage
still went green because it only counted colours. That is why the stage now also asserts the screen
changed between clicks (`SP_MOVE_MIN`, default 3%). The map node click is still computed — it is
geometry, and `verify_sp_screens.py` mirrors `MapScreen.gd`'s `PANEL_RIGHT` / `TITLE_BOTTOM` /
`EDGE_MARGIN`, so **changing those constants means changing both files**.

Map and Battle lay out responsively **only in portrait** (taller than 16:9): content scales up to
fill the width and sits slightly below center, driven by pure helpers in
`scripts/core/screen_layout.gd` (headless-tested in `test_screen_layout.gd`). Landscape (16:9) is
left exactly as the scene defines it — `ScreenLayout.is_portrait` gates the whole thing. The
per-screen `portrait_fill` / `portrait_vertical_bias` are `@export`s tuned by feel; if you change a
default, update `SP_BIAS` in `verify_sp_screens.py` to match.

**Font sizes have one source: `scripts/core/font_scale.gd` (`FontScale`).** Scenes never write a
size — they name a role via `theme_type_variation = &"Heading"`, and `FontScale.build_theme()` turns
the role table into a `Theme`. Because a phone in portrait renders the 1280-wide canvas at ~0.3×,
each role carries a separate portrait size, scaled hardest at the small end (Caption 2.0× down to
Display 1.33×) so headings don't outgrow the 1280 width. `FontScale.chrome_scale()` is the matching
multiplier for containers pinned by offsets (reward cards, the acquired panel, the stat HUD, corner
buttons) — enlarge text without it and the text spills out of its box.

Godot's theme inheritance only walks Control and Window nodes, so `get_window().theme` reaches
**nothing** here: `ScreenHolder` is a `Node`, `Battle`'s root is a `Node2D`, `StatPanel` is a
`CanvasLayer`. `FontScale.apply()` walks down and assigns to the topmost Control on each branch;
`Main` calls it per screen. A missed assignment is silent — text just stays 16px — which is what
`apply()` returning a count, and the SP screenshots, are there to catch.

Tests live in `godot/tests/`; `run_tests.gd` is the entry point. When adding a test suite, add its
name to `EXPECTED_TESTS` — the runner cross-checks that every suite ran to completion, because a
GDScript runtime error silently aborts just that function and would otherwise report success.

**A new test isn't done until it has caught a deliberately broken implementation.** Every suite in
this repo was validated by sabotaging the code (flip a sign, drop a clamp, skip a guard) and
watching the test fail — several tests that "looked right" turned out to check nothing. Two
mechanics for that workflow: `git add` the new files *before* sabotaging, because
`git checkout --` restores the index copy and silently erases never-staged work (this has
destroyed uncommitted code twice); and run `verify.sh` with a distinct `WEB_PORT=<port>` when
parallel sessions might hold the default 8099 — the port guard fails loudly instead of silently
verifying a stale build, but only if ports don't collide.

For balance questions and physics-bug hunting, `scripts/playtest.sh` runs bot armies through
`BattleResolver` headlessly (25k battles in ~10s, deterministic by seed) and emits
`build/playtest/report.md`; see `docs/playtest.md`. Invariant violations there come with the full
request JSON — `BattleRequest.from_dict()` reproduces them instantly. If you change the
progression in `Main.gd` (enemy-per-step, rewards), mirror it in `godot/playtest/run_sim.gd`.

Visual bugs need measurement, not screenshots: a single frame cannot show that something is
static or flickering. Capture with `--write-movie` at **60fps** (other rates alias differently
and don't reproduce what players see) and diff adjacent frames, or count pixels by color — the
"spinning disc frozen at rps=15" and "87px telegraph hidden under the disc" bugs were both
invisible in stills.

### Architecture

State flows through an autoload singleton and scene swaps, replacing the prototype's Flask session
and routes:

- **`autoloads/GameState.gd`** — one run's state (player stats, map tree, pending enemy, acquired
  parts). In-memory only; no save/resume, matching the prototype's session dying on restart.
- **`scenes/main/Main.gd`** — swaps screens under `ScreenHolder` and owns all routing decisions.
  Screens emit signals about what happened; they never decide where to go next.
- **`scenes/title/`**, **`scenes/map/`**, **`scenes/battle/`**, **`scenes/reward/`** — the screens.
- **`scripts/core/spinner_physics.gd`** — the physics formulas, as pure static functions with no
  Node or scene dependency, so headless tests call them directly.
- **`scripts/core/spinner_stats.gd`** — `SpinnerStats`: mass, radius, friction, restitution, rps.
- **`scripts/data/map_tree.gd`** — branching map generation, keyed by `Vector2i(step, column)`.
- **`scripts/data/enemy_roster.gd`** — enemy table and which level appears at which step.
- **`scripts/data/`** also holds the rest of the roguelike data layer: `custom_part.gd` /
  `custom_part_catalog.gd` (the rarity-weighted reward parts), `enemy_data.gd`, `enemy_spawn.gd`
  (`EnemySpawn.plan()`, see below), and `field_data.gd` / `field_roster.gd` (per-step stage
  variations).

### Battles are resolved up front, then played back

A launch is the only input a battle ever gets, so the whole fight is computed at launch time and
then replayed. **`Battle.gd` is a playback machine — do not put gameplay logic in its loop.**

- **`scripts/battle/battle_resolver.gd`** — `resolve(request) -> BattleResult`, a pure function
  (no Node, no scene, no RNG, capped step count). This is the intended **server swap point** for
  future online play: today it runs locally; later a server runs the same code.
- **`scripts/battle/battle_request.gd` / `battle_result.gd`** — the full input/output, both
  `to_dict()`-serializable; a JSON round-trip must not change the outcome (tested). Results carry
  whole trajectories, not input+seed: Godot does not guarantee float reproducibility across
  platforms, so replaying from a seed can produce a different winner on a different machine.
- Playback samples frames with linear interpolation (render fps is independent of the physics
  step) and emits collision sparks when playback time reaches each recorded impact.

The enemy's spawn (position/velocity) is an **input** decided in `_ready()` via
`EnemySpawn.plan()` and telegraphed before the player launches — not an outcome of resolution.

### The telegraph may wobble; the launch may not

`EnemyTelegraph` shows the enemy's committed plan wobbling inside a bounded envelope
(`TelegraphWobble`, pure functions of time) so it can't be read at a glance. **The wobble is
display-only: anything that launches must use the committed plan, never the displayed values** —
otherwise the telegraph becomes a lie. A test pins this; keep it green. The wobble is zero at
t=0 (frequency-scattered, not phase-scattered) so the disc doesn't jump the frame the telegraph
appears. Launch positions are clamped inside the arena via `ArenaWall.clamp_inside` — the mouse
can point outside, but shots from outside the walls skip the bounce check (inward movement never
collides) and gave a free run-up.

### Physics: it is deliberately fake

**Conservation laws do not hold system-wide and must not be treated as design constraints.**
`spin_kick` converts rotation into linear motion, so energy increases. The momentum/energy tests
exist only to check that the *elastic-collision formula itself* was written correctly — they are
not laws the game must satisfy. If tuning wants an inelastic collision, change the test.

The force pulling tops toward the center is **the stadium's slope**, not gravity and not a spring.
`StageShape.DISH` (linear in displacement) is a parabolic bowl; `StageShape.CONE` is a constant
slope. Both are selectable because which one feels right is an open question.

**Do not attempt numerical comparison against `archive/flask-prototype/simulation.py`.** `Vector2`
components are 32-bit while GDScript's `float` and numpy are 64-bit, and collisions amplify the
divergence exponentially — exact agreement is impossible and chasing it builds a test that can
never go green. The prototype's *numbers* are discarded outright; only the shape of the formulas
carried over. Tuning is judged by feel, and every tunable is an `@export` so it can be changed in
the Inspector.

Tests therefore assert direction, monotonicity, and other value-independent properties that survive
tuning. Map generation is tested by generating many maps and checking invariants (no dead ends, no
dangling arrows, no orphans, no crossing arrows), with a seedable RNG so a failure is reproducible.

### Localization

Bilingual (Japanese/English) from the start. All UI strings are keys resolved through
`godot/translations/strings.csv`; `Control` nodes auto-translate their `text`. A missing key renders
as the key itself, which is how you spot gaps.

The bundled Noto Sans JP is load-bearing: Godot's default font has no CJK glyphs and Japanese
renders as tofu (□). `run_tests.gd` asserts the default font actually has Japanese glyphs, because
the `.pck` size check does not catch this (the font ships regardless of whether it's referenced).

Comments and commit messages are in Japanese. Keep the existing language of what you edit.

**Do not put explanatory comments in `godot/project.godot`** — Godot regenerates the file whenever
settings are written and strips them.

### Sound effects (SE)

For SE, see `docs/se.md`. No audio infrastructure exists yet — no `AudioStreamPlayer`, no audio
bus, no assets. It's deliberately **not** implemented yet: there are no sourced/licensed sound
assets, and the physics is still being tuned by feel, so there's nothing stable to bind SE
triggers to. When it lands, collision SE should hook the same recorded impacts that playback uses
for sparks (`BattleResult.impacts`), not the physics step.

## Shipping

The web build deploys to GitHub Pages from `main` via `.github/workflows/pages.yml`, gated on
`scripts/verify.sh` going green — the same script, not a CI-only reimplementation. It is live at
<https://uiro-uri.github.io/slay-the-spinner/>.

For Steam, see `docs/steam.md`. GodotSteam is deliberately **not** vendored yet — without an App ID it cannot
initialize, so it would be an untestable 50MB+ binary in the repo. When it goes in, every Steam call
must sit behind an availability guard: the same codebase ships to browser (no Steam API), native
without Steam, and native under Steam.

## バージョニング

バージョン番号の単一情報源は `godot/project.godot` の `application/config/version`（0.0.0 開始）。
`scripts/core/game_version.gd` の `GameVersion.display()` がそこを読んで `vX.Y.Z` を組み立て、
タイトル / ゲームクリア / ゲームオーバーの各画面が隅に表示する（`GameVersion.format()` は純関数で
`test_game_version.gd` が書式と設定の同期を固定している）。

番号を上げる規則:

| 変更の種類 | 上げる桁 | 例 |
|---|---|---|
| 機能追加・バランス調整 | マイナー `+0.1` | 0.1.0 → 0.2.0 |
| バグ修正 | パッチ `+0.0.1` | 0.2.0 → 0.2.1 |
| メジャー | 指定時のみ | 0.9.0 → 1.0.0 |

変更をマージするたびに `project.godot` の `config/version` を上げ、`CHANGELOG.md`（リポジトリルート）
に同じ番号で一項目追記する。

## Conventions

- Build output goes to `build/` at the repo root, deliberately outside `godot/`. Inside it, Godot
  rescans the exported PNGs as project resources.
- Commit `export_presets.cfg`, `.import`, and `.uid` files — the `.uid` sidecars are Godot's stable
  resource IDs, and scenes reference scripts by them, so an untracked `.uid` next to a committed
  `.gd` is a gap to commit, **not** a stray to delete. `.godot/`, `build/`, and `*.translation` are
  generated.
