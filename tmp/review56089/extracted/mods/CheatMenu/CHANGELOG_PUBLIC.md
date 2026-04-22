# Cheat Menu · v10.6.2 Release Notes

> **Profiles — three named loadout slots that save everything, plus community-feedback polish and stability fixes.** The v10.6 line is the biggest persistence upgrade the mod has shipped. Every setting, slider, teleport bookmark, favorite, and keybind now auto-saves per profile and auto-loads on launch. Plus a round of fixes from three ModWorkshop commenters and a full code audit.

---

## 💾 Profiles — 3 slots, auto-save, auto-load (v10.6.0)

**Thanks to _soybean_alien_** for the "please make the sliders stick across sessions" request — this is the full answer.

Every user-tunable surface of the mod now lives in a profile:

- **Every cheat toggle** (~34 vars in `SETTABLE_VARS`)
- **Every slider** (Speed, Jump, Fly Speed, Fly Sprint, FOV, Time Speed)
- **All 10 teleport bookmarks** (with names, positions, IDs)
- **Your favorites row** (the ☆'d cheats on the dashboard)
- **Every keybind** (both defaults and your customizations)
- **Vitals Tuner state** (drain/regen multipliers, freezes, lock-max, condition immunities — 9 vitals × 5 fields + 12 conditions)
- **Real Time Sync preference**

### How it works

Open F5 → **PROFILES** tab. You see three cards. The active profile has a ★ and a **FLUSH** button; the other two have **LOAD / SAVE / RENAME / RESET**. The active profile auto-saves 1 second after any change. Close the game, come back, everything is exactly where you left it.

### The profile cards show what's inside

Each card now displays the actual contents — **CHEATS** (with values like `Speed × 2.5`, `FOV 90°`), **TELEPORTS** (with coordinates), **FAVORITES**, and **KEYBINDS** (with their bound keys). Scrollable inside each card, truncated at 6 rows per section with a "+ N more" indicator, color-coded section headers. At a glance you can see what each loadout is without loading it.

### Switch loadouts with one click

- `[COMBAT]` — God Mode, Infinite Ammo, ESP with Chams theme, speed × 2
- `[EXPLORATION]` — Teleport bookmarks for every cabin / trader, no cheats
- `[VANILLA]` — empty, for when you just want to play clean

The HUD top-left now shows `[ PROF:Combat | GOD | ESP | SPD:2.0x ]` so you always know which loadout is driving your live state.

### Under the hood (for the curious)

- **Monolithic `.cfg` per slot** at `user://cheatmenu_profiles/profile_{1,2,3}.cfg`. Each file has `[meta] [cheats] [favorites] [teleport_slots] [keybinds] [tuner] [real_time]` sections.
- **Atomic writes** — every save goes to a `.tmp` file then renames over the target. A crash or disk-full mid-write leaves the old profile intact.
- **Schema versioning** — each file stamps `schema_version = 1` in meta. Profiles written by a newer mod version get refused with an explanatory toast rather than corrupting on downgrade.
- **Type-validated loads** — every field type-checks against its class-default before being applied. A hand-edited broken profile can't crash the mod.
- **Dual-write rollout** — legacy `.cfg` files (favorites, keybinds, teleports, tuner, real_time) still get written in parallel for one release as a safety net. If anything goes wrong with the profile system, the legacy files let us hot-patch without user data loss. Stripped in v10.7.
- **Controller-readiness deferral** — if you switch profiles mid-zone-transition, non-world state (keybinds, favorites) applies immediately and controller-gated cheats (speed, jump, no-overweight, etc.) queue until the new Controller is in the scene.
- **First-launch migration** — existing v10.5.x users launch into v10.6: the profile system reads their current `cheatmenu_favorites.cfg`, `cheatmenu_teleport_slots.cfg`, `cheatmenu_binds.cfg`, `cheatmenu_vitals_tuner.cfg`, `cheatmenu_real_time.cfg`, packs it all into Profile 1 named "Default", and leaves Profiles 2 & 3 empty. Zero migration friction.

---

## 🛠️ Community feedback round (v10.6.1)

Three ModWorkshop commenters left feedback within hours of v10.6.0. Every item that didn't need deeper research is in this release.

### Editable spawn-quantity box (thanks _soybean_alien_)

The `[−][N][+]` stepper in the Item Spawner — previously a static number between two buttons — is now a **clickable text field**. Type any quantity up to **999,999**. The box auto-grows as you type more digits, shrinks back when you delete them. Enter or click-away commits; out-of-range values clamp visibly so you see what actually got saved. The +/- buttons still work for small tweaks and stay in sync with the field.

Concrete wins:
- **"300 .45 ACP rounds"** — type `300`, hit SPAWN. Done.
- **Max cash stack** — type `999999`, spawn Vostok Dollars if you have the Cash System mod. No dedicated button needed; the field covers it.
- **Small adjustments** still work with +/- for touch-friendly micro-tweaks.

### Thermal ESP scan-line removed (thanks _davodal_)

The horizontal scan-line sweeping top-to-bottom on the Thermal ESP theme is gone. _davodal_'s feedback: *"the constant thermal scanner line (moving through the entire screen) is kinda off."* Agreed — the thermal shader is the signal; the scan-line was noise. Vostok Intercept and Spectral Chams themes are unchanged.

### Dead AI hidden in ESP by default (thanks _davodal_)

New toggle **"Hide Dead AI in ESP"** in the Combat tab's AI INTELLIGENCE section, default **ON**. Previously, corpses kept drawing ESP boxes forever — useful as a kill confirmation, but cluttered in a body-heavy fight. Now they vanish the instant the AI's `ai.dead` flag flips. Flip the toggle off if you liked the old behavior.

### Fly Mode unbound by default

Removed F8 → Fly Mode from the default keybinds. Several players bound F8 to their own actions in other mods and the clash was annoying. Fresh installs now launch with Fly Mode unbound; anyone who had F8 bound from a prior session keeps their binding (profile system preserves it). Rebind to any key via the KEYBINDS tab.

### "Sliders stick across sessions" — already solved

_soybean_alien_ asked for Speed / Jump / FOV to remember their last-session values. The Profiles system handles this automatically — every slider is persisted per-profile and auto-restored on launch. No extra code needed.

---

## 🛡️ Stability + audit fixes (v10.6.2)

Post-v10.6.1 full-codebase audit surfaced a handful of real issues. Fixes shipped here:

- **Noclip restore on mod unload** — previously, if the mod was unloaded (scene change, dev reload) while Noclip was ON, the player's `collision_mask` stayed at 0 and they were permanently intangible until the game was relaunched. `_exit_tree` now explicitly restores the saved masks.
- **`_style_label(LineEdit)` parse error** — a v10.6.1 regression: the new qty-edit widget was a `LineEdit` but got passed to a helper typed for `Label`. Godot's static parser rejected the whole script. Fixed by inlining the theme overrides at the call site. This was the "F5 stopped working" bug during internal testing.
- **Dead `_esp_thermal_scanline` function removed** — with the scan-line call gone in v10.6.1, the defining function became unreachable. Deleted.
- **`saved_recoil` dict cleared on unload** — prevents a re-spawned autoload (dev reload) from replaying stale WeaponData refs.
- **De-duplicated close-time saves** — `NOTIFICATION_WM_CLOSE_REQUEST` and `_exit_tree` used to both flush profile + tuner + keybinds back-to-back. Now the first pass sets a sentinel flag and the second pass skips. ~3ms faster shutdown.
- **Profile migration validates teleport-slot dicts** — malformed legacy `cheatmenu_teleport_slots.cfg` entries are filtered during the migration to Profile 1 rather than being copied verbatim and filtered later.

### Security audit verdict

Full pass on all 13,500 lines of the mod. Conclusion: no security issues for a single-player mod. ConfigFile parsing is type-validated, all profile-loaded values are whitelisted against `SETTABLE_VARS`, no path traversal surface (on-disk paths are fixed with int-validated indices), and shared `GameData.tres` mutations are confirmed in-memory only (cross-checked against the game's own `Loader.SaveCharacter` whitelist — none of the mod's overrides escape to disk).

### AI-loot audit (addressing a user report)

A user wondered if the ESP was preventing AI corpses from dropping loot. Conclusion after full grep: **not possible** — CheatMenu is entirely read-only on AI data (zero writes to `ai.container`, `ai.loot`, `ai.dead`, `ai.health`), never overrides any game script via `take_over_path`, and the one function that writes to a `.loot` field is gated by `get_nodes_in_group("Furniture")` which AI corpses aren't in. The vanilla game's `LootContainer.GenerateLoot` has a designed 74% empty-corpse rate on every roll — that's the game, not the mod.

---

## 🧰 Technical cleanup this round

- **`_apply_cheat_side_effects` dispatcher** — extracted the 8 side-effect branches from `_on_cheat_toggled` (and 3 slider specials from `_on_slider_changed`) into tiny `_apply_<name>()` functions with a central match dispatcher. Profile loads call applicators directly under a `_profile_suspend_hud` flag so bulk applies don't rebuild the HUD row 34 times. Net code-quality win.
- **HUD chip**: `[PROF:Combat]` prepended to the existing `[ GOD | ESP | NO-FALL ]` tag row so you always know which profile is live.
- **`process_physics_priority = 1000`** on the autoload — already set in v10.4.4 for the fly-speed override, still in force.
- **Content-signature caching on Profile cards** — content only rebuilds when the profile's `last_modified` actually changes, not on every frame of a slider drag.
- **SETTABLE_VARS now includes `cheat_ai_esp_theme` and `cheat_ai_esp_hide_dead`** — both now participate in profile capture / restore automatically.

---

---

# Cheat Menu · v10.5.1 Release Notes

> **Executive audit pass.** One critical correctness bug in v10.5.0's AI module, plus a sweep of pre-existing HIGH and MEDIUM bugs across the 10k-line codebase. No user-facing feature changes — all fixes are invisible quality work.

---

## 🔴 Critical fix

### `"ChangeState" in ai` never matched — combat AIs stayed in combat

Godot 4's `in` operator on `Object` walks the property list only, not the method list. v10.5.0's invisibility-reset branch used `"ChangeState" in ai` as a method-existence guard — it was returning `false` for every AI in the game, silently skipping the combat-state force-revert. The sensor-field zeroing still worked, so AIs lost sight of you, but any AI that transitioned to Combat/Hunt/Attack within the same physics tick before our ticker ran would linger in combat state until its own timers expired.

**Fix**: `ai.has_method("ChangeState")` — matches the pattern used by the other 7 method-existence checks in the file.

---

## 🟠 High-priority fixes

### ESP overlay persisted after toggle-off

v10.5.0's ESP overlay only called `queue_redraw()` while the toggle was on. When you turned ESP off, no new redraw was requested and the last-frame bounding boxes sat in the GPU buffer until another redraw event (window resize, re-enable) fired. **Fix**: always `queue_redraw` while the overlay is alive; `_draw` early-returns when the flag is off, which clears the canvas because Godot rebuilds the draw list fresh every call.

### Controller baseline re-capture on zone transition

When you crossed a zone boundary the game freed the old Controller and spawned a new one. The mod re-discovered it and **re-captured baselines** — but if a speed cheat was active, the baseline re-read a value that might already have been modified, permanently poisoning the "restore to default" path. **Fix**: one-shot sentinel (`_baselines_captured`); after first successful capture, zone transitions re-acquire the controller reference but never re-read the baseline speeds.

### `_discover_controller` ambiguity

The old search (`find_children("*", "CharacterBody3D", ...)` with a `walkSpeed` property probe) could theoretically match an AI character — RTV's AIs are CharacterBody3Ds too. **Fix**: try the canonical `/root/Map/Core/Controller` path first (what the rest of the file uses), fall back to the shape-match only if that fails. Also deterministic.

### Infinite Ammo crashed on saves missing `primary` / `secondary`

`_apply_infinite_ammo` read `game_data.primary` without the `"X" in game_data` guard that's used everywhere else. A save that predated those fields would hard-error out of the `_process` tick every frame. **Fix**: gated reads.

### No-Recoil baseline capture edge case

If the same `WeaponData` resource was first encountered with its recoil values already at `{0, 0, 0}` (e.g. the cheat was already applied in a prior toggle cycle before our capture-once guard kicked in), the baseline would be saved as zero — and restoring on toggle-off would permanently strip the weapon of recoil. **Fix**: refuse to capture an all-zero baseline; it's the sentinel for "already ours", not a real default.

### Keybind config file type validation

`ConfigFile.get_value()` returns `Variant`. A hand-edited `cheatmenu_binds.cfg` with `key = "foo"` would coerce through `int()` to 0 and silently stomp every unset F-key bind to keycode 0, colliding with any future 0-key match. **Fix**: `typeof(v) == TYPE_INT` / `TYPE_BOOL` per-field check; malformed binds are dropped with a warning instead of silently corrupting the bind table.

### `_action_restock_traders` — method check by `in` operator

Used `"CreateSupply" in node` to probe for the method. GDScript 4's `in` on `Object` is property-only; the call site was relying on an inconsistent code path that matches scripted functions but not native methods. **Fix**: `has_method("CreateSupply")`, plus a cheap `traderData`-property pre-filter to trim the Node3D walk.

### `UpdateStats` without `has_method` guard

No-Overweight called `ow_interface.UpdateStats(false)` without verifying the method exists. If a future game version renamed `UpdateStats`, the mod would hard-error on every toggle. **Fix**: guard; if the method is missing, the stat just doesn't refresh until the player moves.

---

## 🟡 Medium fixes

### ESC didn't dismiss orphaned Teleport Picker

If you opened the teleport picker via a direct keybind (no dashboard), ESC would fall through to the game's pause-menu handler while the picker sat on top, unresponsive. **Fix**: run the sub-subpanel close cascade BEFORE the `cheat_open` branch. Picker / name-prompt now closes on ESC regardless of how it was opened.

### `_tuner_save_cfg` could fire on a freed autoload

Deferred via `call_deferred` from the debounced-save path. If `_exit_tree` landed between dispatch and invocation, the callable fired on a freed self. **Fix**: `is_inside_tree()` short-circuit + `tuner_drain_mult.is_empty()` startup-race guard.

### Mouse release missed backdrop nodes

`_overlay_release_mouse_if_last` checked panel refs but not their backdrop refs. Close sequences that freed the panel before its backdrop (or vice versa) could briefly release the mouse while the backdrop still caught clicks. **Fix**: inspect backdrops too.

### Belt-and-suspenders `NOTIFICATION_WM_CLOSE_REQUEST` hook

Godot fires this notification on Alt+F4 / window-close **before** the tree teardown begins. We now flush `_tuner_save_cfg` + `_save_keybinds` early on that signal, so a late-resolving tree teardown can't lose pending saves. Empty-dict guards on both saves prevent a tight startup race from erasing user customizations with a blank cfg.

---

## 🔬 Audit findings verified as false positives

The audit flagged "shared GameData.tres mutation leaks cheat overrides to disk on crash" (affecting `heat`, `PRX_Workbench`, `baseFOV`, `baseCarryWeight`, `headbob`, `WeaponData.recoil`). Cross-checked against the game's actual save path (`Loader.SaveCharacter` at `Scripts/Loader.gd:460-548`): the game saves a **fresh `CharacterSave.new()` instance** to `user://Character.tres`, copying only a **whitelisted subset** of fields (health, ailments, cat, weapon-draw flags, inventory). None of the cheat-mutated fields listed above are in that whitelist. Additionally, no game script calls `ResourceSaver.save()` on any `WeaponData` resource. Mutations to the shared `res://Resources/GameData.tres` are therefore in-memory only and wiped on game restart.

The defensive-engineering wisdom is still sound — and the v10.5.1 `NOTIFICATION_WM_CLOSE_REQUEST` hook above tightens save timing regardless — but a full architectural refactor to a runtime resource shim is not warranted for this codebase.

---

# Cheat Menu · v10.5.0 Release Notes

> **AI awareness controls.** Two new Combat-tab toggles that answer a long-standing community request: **Invisible to AI** and **AI ESP**. Both are sensor-layer features — no group hacks, no god-mode piggybacking. What you see in the HUD is exactly what the AI's state machine sees.

---

## 👁️ Invisible to AI

Toggle in the Combat category (or bind a hotkey via the Keys tab). HUD tag: `[ INV ]`.

### What it does

Hijacks the AI detection pipeline at the **sensor-output layer**, not at the physics layer. Each physics frame, after every AI has finished its own `_physics_process`, a priority-1001 ticker sweeps every live agent under `/root/Map/AI/Agents` and surgically resets the four fields the AI's state machine reads to decide whether to engage:

| Field | Reset to | Effect |
|---|---|---|
| `playerVisible` | `false` | LOS check result is forced negative |
| `lastKnownLocation` | `Vector3.ZERO` | No "hunt" waypoint |
| `fireDetected` | `false` | Muzzle-flash / firing direction cues ignored |
| `extraVisibility` | `0.0` | Extended sight range from prior fire/flash is cleared |

If an AI has already transitioned mid-tick into a combat-adjacent state (`Combat`, `Hunt`, `Attack`, `Vantage`, `Cover`, `Defend`, `Shift`, `Return`), the ticker calls `ai.ChangeState("Wander")` so the animator/audio cleanup runs the way the AI's own logic expects — no glitched poses, no lingering combat voice lines.

### Why not the obvious shortcut?

The one-line version of this feature would just remove the player from Godot's `"Player"` node group — `AI.gd`'s `LOSCheck()` would then fail its group membership test and `playerVisible` would never flip to true. **That shortcut breaks three other systems:** `AI.Raycast()` uses the same group check to route incoming damage, so shots pass through you; `BTR.gd` uses it for vehicle MG hits; `Explosion.gd` uses it for splash damage. Removing the group turns on invisibility *and* invincibility, which is two features wearing one name.

The sensor hijack keeps you properly targetable — stray grenades and environmental damage still apply — you just don't get *seen*. If you want bulletproof too, stack `God Mode`.

### Edge-detected disengagement

The ticker only pays the `ChangeState` cost on the frame it sees `playerVisible == true` or an `lastKnownLocation != ZERO`. In steady state (AI is already wandering), the tick is four writes and an exit — no state-machine churn.

---

## 📡 AI ESP

Toggle in the Combat category. HUD tag: `[ ESP ]`.

### What it does

Paints a color-coded bounding box + info block over every live AI within 300 m. One `Control._draw` call per frame, no per-agent nodes allocated. Sits on its own `CanvasLayer` (layer 110) so it renders above the game HUD but below the cheat panels — exactly where an overlay belongs.

### What each color means

| Color | States | Meaning |
|---|---|---|
| 🟥 **Red** | Combat / Hunt / Attack / Vantage | Actively engaging — shots may already be incoming |
| 🟧 **Orange** | Cover / Defend / Shift / Return | Combat-adjacent — repositioning or retreating |
| 🟨 **Yellow** | Any passive state + `lastKnownLocation != 0` | Alerted — investigating a sound or last sighting |
| 🟩 **Green** | Idle / Wander / Patrol / Guard / Ambush / Hide | Oblivious to you |
| ⬜ **Gray** | `dead == true` | Corpse (usually culled from draw but shown briefly on death) |

### The info block

Next to each box:
- **Line 1:** AI type (`Bandit`, `Guard`, `Military`, `Punisher`, with `(BOSS)` suffix for 300-HP variants) · **distance in meters**
- **Line 2:** Current state name (combat states in ALL CAPS for scanability) · **HP**
- **Line 3** (conditional): `SEES YOU` when the AI's own `playerVisible` is currently `true`. Pair this with Invisibility to verify the sensor hijack is winning — line 3 should disappear the instant INV is toggled on.

### Perf

Frustum-culled (behind-camera AIs skipped), distance-capped at 300 m, degenerate-projection safety net. In a typical Area 05 combat zone with 3–5 active agents the draw cost is negligible.

---

## 🔧 Integration notes for modders

Everything lives in one block at the bottom of `Main.gd` marked `AI INTELLIGENCE MODULE`. Adding more AI-aware features (e.g. a "freeze all AIs" toggle) is ~10 lines: declare the cheat var, add a BINDABLE_ACTIONS row, extend `_ai_on_physics_tick`, and extend `_update_hud`.

The ticker is `process_physics_priority = 1001`, one notch above the Vitals Tuner (1000), so AI overrides are always the *last* writes to AI state each frame. If you add a new ticker that needs to run after ours, use 1002+.

---

---

# Cheat Menu · v10.3.2 Release Notes

> **Auto-Med + Health Regen pacing curve.** Take a hit, get restocked. And the Health Regen slider now follows a hand-tuned curve so each notch maps to a specific time-to-full.

---

## 🩹 Auto-Med

Toggle **Auto-Med** in the Player tab's SURVIVAL column. From then on, every time you take a specific injury, the mod looks up the canonical cure and makes sure you have **at least 2** of it in your inventory.

| Injury | Auto-stocked item |
|---|---|
| **Bleeding** | Bandage |
| **Fracture** | Splint |
| **Burn** | Balm |
| **Rupture** | Medkit |
| **Headshot** | IFAK |

### How the stock rule works

- If you have **0** of the cure → mod adds **2**
- If you have **1** of the cure → mod adds **1** (top up to 2)
- If you already have **2** → mod does nothing, shows a toast: `Already stocked: 2 × Bandage`

So you never hoard mountains of bandages, but you always have exactly what you need when something goes wrong.

### Inventory full? It drops nearby — smartly.

If your inventory has no room when an injury fires, the items queue for a **ground drop**. The drop doesn't happen instantly — it waits until you've **stood still for 2.5 seconds** so you don't leave a trail of bandages behind you while sprinting through combat. A toast tells you what landed: `Dropped near you: Bandage ×2`.

If you start running again before the 2.5 s timer finishes, the queue just keeps waiting. Stop again, timer starts over, items drop when you're actually ready.

### Multiple injuries at once

Shotgun blast causing bleeding + fracture in the same instant? Auto-Med handles both independently — one Bandage restock, one Splint restock, both on the same physics tick.

### A new HUD tag

When Auto-Med is on, your HUD shows `[ MED ]` alongside any other active cheats (`[ GOD | MED | TUNER | … ]`) so you can see at a glance that the auto-restock is watching your back.

### Why NOT insanity?

Insanity is the one condition without a single-purpose cure — only AFAK (rarity 2, 1.2 kg) handles it, and auto-spawning a rare heavy medkit on every mental breakdown felt wrong. The existing **Tuner → Immunities → Insanity** toggle already handles that use case cleanly. So Auto-Med covers the five *physical* injuries only.

---

## ❤️ Health Regen — Hand-Tuned Pacing Curve

v10.3.1 introduced synthetic Health regen, but the single `base × slider` multiply made the default feel too quick. v10.3.2 replaces it with a **piecewise-linear curve** through five anchor points, so each notch on the slider maps to a specific recovery time:

| Slider | HP/sec | Full 0 → 100 heal time |
|:-:|:-:|:-:|
| 0.2× | 0.0667 | **25 min** — trickle |
| 0.5× | 0.1111 | **15 min** — slow |
| **1.0×** | **0.1667** | **10 min** — default, background pacing |
| 2.0× | 0.3333 | **5 min** — noticeable |
| 5.0× | 1.6667 | **1 min** — emergency brake |

Slider values between anchors interpolate smoothly — e.g. `0.7×` lands between the 0.5× and 1.0× rates (~12.5 min to full). Below `0.2×` the curve tapers linearly to zero; at `0.0×` regen is off entirely.

All the same guardrails from v10.3.1 apply: injuries still block regen (bleed / fracture / burn / rupture / headshot need clearing first), and God Mode overrides it.

---

---

# Cheat Menu · v10.3.1 Release Notes

> **Vitals Tuner — Honesty Pass.** Regen sliders that did nothing in vanilla are now either removed or made real. Health regen is now an actual gameplay feature.

---

## ❤️ Health Regen — Now An Actual Feature

In vanilla Road to Vostok, your Health bar never passively recovers — you heal only from medical items. v10.3.0 shipped a Health "Regen" slider anyway, but it did nothing (the game has no passive regen for the slider to scale).

**v10.3.1 fixes that.** The Health Regen slider now drives a **synthetic passive HP regeneration** that actually heals you over time:

- **At `1.0×` (default):** **0.5 HP/sec** — full heal from 0 takes ~3½ minutes
- **At `5.0×` (max):** 2.5 HP/sec — full heal from 0 in 40 seconds
- **At `0.0×`:** regen disabled, back to vanilla behavior

**Guardrails** — the regen *respects the game's injury model*. It won't fire while any of these are active:

- Bleeding
- Fracture
- Burn
- Rupture
- Headshot

You still need to patch a wound with bandages, splint a fracture, or use a condition immunity toggle to clear the blocker — then the regen kicks in. This keeps damage-mitigation gameplay meaningful while letting you recover between fights without a medkit run.

It also respects the existing `God Mode` cheat — if that's on, it already pins HP to 100, so the synthetic regen skips the redundant writes.

---

## 🧹 Dead Sliders Removed

Three vitals had regen sliders that didn't actually do anything because the game has no passive regen for them — only consume items (food, water, cat interaction). Those sliders are now hidden to keep the UI honest:

| Vital | v10.3.0 | v10.3.1 |
|---|---|---|
| Energy | Drain + Regen (Regen did nothing) | **Drain only** |
| Hydration | Drain + Regen (Regen did nothing) | **Drain only** |
| Cat | Drain + Regen (Regen did nothing) | **Drain only** |

The Freeze and Lock Max toggles are still available on all vitals. The observer / correction pipeline still handles the scaled drain correctly for all 9 vitals.

## 🎯 Still Regen-able (and these actually work as advertised)

- **Health** — synthetic regen (new, see above)
- **Mental** — scales the `+delta/4` you get near a fire / heat source
- **Body Temp** — scales the `+delta` you passively gain in summer, shelter, tutorial, or near heat
- **Oxygen** — scales the `+delta*50` surface-recovery after swimming
- **Body Stamina** — scales the recovery rate when you stop sprinting
- **Arm Stamina** — scales the recovery rate when you lower your weapon

---

## 📋 v10.3.1 At a Glance

> **Added:** Synthetic Health regen driven by the Health Regen slider · Injury-gated so damage still matters
>
> **Removed:** Dead Regen sliders on Energy, Hydration, Cat (those vitals only recover via items in vanilla — slider was a no-op)
>
> **Tuner UI:** Cleaner per-vital blocks — no more controls that silently do nothing

---

---

# Cheat Menu · v10.3.0 Release Notes

> **The Vitals Tuner Update** — fine-grained survival tuning, a reimagined spawner, and a wave of polish across the dashboard.

---

## ✨ Headline Feature

### 🎛️ Vitals Tuner — a new dashboard category

Dial in *exactly* how punishing the survival loop feels. Nine vitals, two sliders each, plus per-vital freezes and twelve condition immunities — all live, all adjustable without leaving the game.

| Vital | Drain × | Regen × | Freeze | Lock Max |
|---|:-:|:-:|:-:|:-:|
| Health | ✅ 0.0× – 5.0× | ✅ 0.0× – 5.0× | ✅ | ✅ |
| Energy | ✅ | ✅ | ✅ | ✅ |
| Hydration | ✅ | ✅ | ✅ | ✅ |
| Mental | ✅ | ✅ | ✅ | ✅ |
| Body Temp | ✅ | ✅ | ✅ | ✅ |
| Oxygen | ✅ | ✅ | ✅ | ✅ |
| Body Stamina | ✅ | ✅ | ✅ | ✅ |
| Arm Stamina | ✅ | ✅ | ✅ | ✅ |
| Cat | ✅ | ✅ | ✅ | ✅ |

**What it does, in plain English:**

- **Drain multiplier** → how fast the vital falls. `0.5×` means half as fast. `0×` means it won't drain at all. `3×` triples the rate.
- **Regen multiplier** → how fast it recovers. Passive regen in summer, near heat, or from game systems scales with this.
- **Freeze** → pins the vital at whatever value it's at right now. Handy for "keep me at 80% health forever."
- **Lock Max** → pins at 100. You're always topped off.
- **Condition Immunities** → 12 toggles for starvation, dehydration, insanity, frostbite, bleeding, fracture, burn, rupture, headshot, poisoning, on fire, and overweight. When checked, the condition clears itself within a physics tick.

### 🟢 Master Enable

One toggle at the top of the Tuner tab turns the entire system on or off. When **on**, the tuner glows green and all your settings are enforced. When **off**, the tab dims by 50% — you can still stage a loadout, but nothing is enforced yet.

When the tuner is active with non-default settings, a `[ TUNER ]` tag appears on the in-game HUD so you know at a glance that modified rules are in play.

### ⚡ Instant Actions

Four one-shot buttons in the Actions column:

- **Refill All Vitals** — every vital jumps to 100
- **Heal Only** — health to 100 + clears combat ailments (bleed/fracture/burn/rupture/headshot/on-fire)
- **Clear All Ailments** — every condition flag cleared
- **Reset Multipliers** — all 18 sliders snap back to `1.0×`

Each action now also fires the game's internal cleanup so indicator sounds stop and UI badges clear properly (previously just blanked the flags, leaving audio stragglers).

### 💾 Settings Persist

Your multipliers, freezes, locks, and immunity choices save to disk (`cheatmenu_vitals_tuner.cfg`) and reload next session automatically. No need to re-dial every time.

---

## 🎨 UI / UX Overhaul

### Spawner — Promoted & Polished

- **New position.** The SPAWNER button now sits in the **top-right "action slot"** of the dashboard nav — the most visually weighted spot in Western reading order. It's the feature users use most; it should look like it.
- **Featured styling.** Green accent fill, bold typography, ◆ decorative glyph, and persistent highlight regardless of which tab is active.

### Modern SPAWN Buttons

Every SPAWN chip rebuilt from the ground up. Gone: the flat, washed-out green rectangles. In their place:

- **Solid green chips** with soft rounded corners
- **Neon emission glow** that pulses on hover (green-tinted drop shadow instead of plain black)
- **LED-edge bevel** — bright 2px top border simulates overhead lighting
- **Press feedback** — the button "sinks" with an inverted bevel and the glow disappears
- **Bold SemiBold 12pt typography** with text shadow for punch
- **Hover tint** — label text shifts to bright green

### 🔢 Quantity Stepper for Item Spawning

Tired of clicking SPAWN thirty times for a full stack of ammo? **Each non-weapon item now has a `[−] [N] [+]` stepper above its SPAWN button.**

- Range **1–99** per item
- Your chosen quantity **persists per item across searches and pagination** — if you always spawn 20 of something, you only set it once
- Smart stacking: ammo, food, and other stackables auto-merge into existing stacks; non-stackables (keys, armor plates, backpacks) each get their own slot
- **Partial-fill handling** — if your inventory runs out mid-batch, the mod tells you exactly how many landed before it stopped

### 🎨 Tuner Tab Layout

A lot of layout work went into making the Tuner tab feel organized and professional rather than cramped:

- **50 / 25 / 25 three-column balance** (Vitals / Immunities / Actions) — sliders have comfortable travel without forcing big mouse drags
- **Per-vital self-contained blocks** — each vital's sliders and its Freeze/Lock toggles live together, so they always align perfectly
- **Top dashboard cards hide** when the Tuner tab is active (same as the World tab does), reclaiming ~40% of vertical space
- **Only the vitals column scrolls** internally; immunities and actions stay pinned so they're always in view
- **Proper scrollbar padding** — the `1.0×` readouts no longer butt up against the scroll track
- **Immunities stacked vertically** (single-column list) instead of a cramped 2-column grid
- **Compact master row** — the Master Enable toggle sits right next to its label instead of floating at the far right of the panel

### Master Toggle Description

A dim caption under the master toggle explains exactly what it does, so new users aren't confused:

> *Master kill-switch. When off, all multipliers, freezes, locks, and immunities are ignored — settings stay configurable.*

---

## 🐞 Bug Fixes

### CARRY Weight Display

The dashboard's carry-weight readout had **several issues** that all got fixed:

| Before | After |
|---|---|
| Showed `/ 10.0 kg` even with a 30-liter backpack equipped | Shows `/ 40.0 kg` (base + backpack capacity), matching the inventory UI exactly |
| Didn't update when you dropped or picked up items | Updates in real-time within ~150 ms |
| Weight math diverged from the game's inventory UI | Now reads the game's own properties directly — always matches |

The **refresh cadence** was also tightened from 0.5 s to 0.15 s while the dashboard is open, so pickups, drops, and spawn actions update the CARRY number, ammo match, and stockpile counts snappily instead of with a noticeable lag.

### ESC Key Doesn't Break the Pause Menu Anymore

**Before:** with the Cheat Menu open, pressing ESC would open the game's settings menu but leave the mouse captured — you couldn't click anything.
**After:** ESC cleanly hands mouse ownership to the settings menu. The cursor appears and the pause menu is fully interactive.

### Tab Inventory + F5 No Longer Traps the Mouse

**Before:** open the game inventory with Tab → press F5 for cheat menu → close cheat menu → the inventory was still visible but the mouse was hidden and mouse movement rotated the camera.
**After:** the mod now **snapshots your mouse/pause state when you open the cheat menu and restores it when you close.** If the inventory was open before F5, it stays fully interactive after closing F5.

### Audio Cleanup on Heal / Clear / Refill

**Before:** clicking "Clear All Ailments" blanked the condition flags but indicator sounds and UI badges for bleeding/fracture/burn/etc. lingered until the next state change.
**After:** each one-shot action fires the game's internal cleanup so audio stops and badges clear instantly.

---

## 🧹 Removed

### Compass Preview Prototype

The experimental 3D compass item preview that shipped as a dev feature has been removed while we reconsider the design. This knocks the mod size from **37.7 MB down to 4.7 MB** — an **~88% reduction** because the compass shipped with three high-detail mesh files.

The compass will return in a future release as a proper in-world item with inventory integration, rather than a floating debug preview.

---

## 📋 At a Glance

> **Added:** Vitals Tuner tab · Quantity stepper on spawner · Modern button styling · Featured spawner nav position · HUD `[ TUNER ]` tag · Automatic settings persistence
>
> **Fixed:** CARRY weight with backpack · Live dashboard refresh · ESC → pause menu mouse bug · Tab+F5 mouse trap · Ailment audio/badge cleanup
>
> **Removed:** Compass preview prototype (–33 MB)

---

## 🙏 Thanks

Huge thanks to everyone who reported bugs, suggested features, and helped test this release. The Vitals Tuner in particular went through seven iterations of playtesting feedback before it felt right.

**Questions, bugs, or feature ideas?** Drop them on ModWorkshop — I read every comment.

*Enjoy the update. Stay alive out there.*
