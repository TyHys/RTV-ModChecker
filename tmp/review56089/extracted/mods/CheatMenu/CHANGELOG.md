# Road to Vostok Mods — Session Changelog

This changelog captures everything built, fixed, or removed in this session,
across the full arc: VitalsTuner standalone iterations (v0.1.0 → v0.1.7) →
merge into CheatMenu (v10.3.0) → post-merge polish and bug fixes → v10.4.x
teleport / weapon dashboard / noclip / fly-speed round → v10.5.x AI-awareness
suite (Invisible / ESP with three themes / Freeze / Thermal-through-walls)
→ v10.6.x Profiles persistence + community-feedback polish + audit fixes.

---

## CheatMenu v10.6.2 — Stability + audit fixes

### Fixed

- **C1 (critical data loss):** `_exit_tree` now restores `controller.collision_mask` + `controller.collision_layer` from `_saved_collision_mask` / `_saved_collision_layer` when `_noclip_applied` is true, and clears the flag. Previously, mod unload with Noclip ON left the player with zeroed masks permanently — intangible until relaunch.
- **F5 unresponsive regression from v10.6.1:** `_style_label()` is typed `Label` but the new spawn-quantity LineEdit was being passed in. Godot's static parser rejected the script → autoload failed → F5 had no handler. Fixed by inlining the theme overrides at the `qty_edit` construction site (L3766). Side audit: grepped every `_style_label` call (73 total), confirmed all other call sites pass proper Label refs.
- **Double-flush on shutdown:** `NOTIFICATION_WM_CLOSE_REQUEST` and `_exit_tree` both ran `_profile_flush_if_dirty` + `_tuner_save_cfg`. New `_saved_at_close` sentinel set after WM_CLOSE's save pass; `_exit_tree` skips if already done. ~2–3ms faster shutdown.
- **`saved_recoil` dict cleared in `_exit_tree`** after the restoration loop. Prevents re-spawned autoload from replaying stale WeaponData refs during dev reloads.
- **`_profile_migrate_legacy` validates teleport slots** — each dict entry now type-checked for `name: String` + `pos: Vector3` before being appended to the new profile. Capped at `MAX_TELEPORT_SLOTS`. Previously, bad legacy data was copied verbatim and filtered only at apply time.

### Removed

- **Dead `_esp_thermal_scanline` function** (~10 lines at L13928). Became unreachable after v10.6.1 removed its call site.

---

## CheatMenu v10.6.1 — Community-feedback polish pass

### Added

- **Editable spawn-quantity box** — `[−][N][+]` stepper's static label replaced with a `LineEdit`. Click to focus, type 1–999,999. `SPAWN_QTY_MAX` bumped 99 → 999,999 to support max-cash / max-ammo use cases. Auto-grows via `_qty_edit_width_for()` as digits are entered. Commit on Enter or focus-out clamps to range and rewrites the field so out-of-range values get visibly corrected. Stepper buttons still work and keep the field in sync. Addresses _soybean_alien_'s "300 ammo at a time" feedback and subsumes the originally-triaged S2 max-cash button request.
- **`cheat_ai_esp_hide_dead` toggle** — new var, default true. Early `continue` in `_ai_esp_draw_all`'s outer iterator skips any AI where `"dead" in ai and ai.dead`. New row in Combat tab's AI INTELLIGENCE section. Addresses _davodal_'s "adjust for the dead" request.
- Registered `cheat_ai_esp_hide_dead` in `SETTABLE_VARS` and `_profile_default_cheats()` so it participates in profile capture automatically.

### Changed

- **Thermal ESP scan-line removed** — deleted the `_esp_thermal_scanline(ctl, viewport_size)` call site in `_esp_draw_thermal`. The function body was left defined in place (until v10.6.2 removed it entirely). Addresses _davodal_'s feedback.
- **Fly Mode default keybind dropped** — removed the `"toggle_fly": {device: 0, key: KEY_F8, ...}` entry from `_apply_default_keybinds`. Fresh installs launch with Fly Mode unbound; existing users keep their binding via profile autosave. Avoids F8 clashes with other mods.

### Notes

- S3 "sliders stick across sessions" request from _soybean_alien_ fulfilled automatically by v10.6.0's profile autosave — no code change, documented in release notes.
- W1 "world event rate tuner" (EquiliteMW's BTR/boss/airdrop chance sliders) deferred to v10.7.0 — mod has zero existing hooks into the game's event system, needs its own exploration session.

---

## CheatMenu v10.6.0 — Profiles (3-slot persistent user state)

### Added

- **3-slot profile system** — three named loadouts that capture the entire user-tunable surface of the mod. File layout: `user://cheatmenu_profiles/_active.cfg` (active-slot pointer) + `profile_1.cfg / profile_2.cfg / profile_3.cfg` (monolithic). Each file has sections `[meta]` `[cheats]` `[favorites]` `[teleport_slots]` `[keybinds]` `[tuner]` `[real_time]`. Internal slot count is `PROFILE_COUNT`-bounded (UI fixed at 3 by spec; data model is N-capable for future import/export/cloud-sync).
- **`_profile_serialize_live() -> Dictionary`** — pure function snapshotting every `SETTABLE_VARS` var, `favorite_actions`, `teleport_slots`, `keybinds`, tuner state, `cheat_real_time`. Paired with `_profile_apply_dict(d)`. Stable-dict layer — ConfigFile is just on-disk encoding; export/import/sync can reuse the dict shape without touching file I/O.
- **Autosave with 1.0s debounce** — `_profile_mark_dirty()` called from every mutation site (17 total — cheat toggles, sliders, teleport save/rename/delete, favorite add/remove, keybind assign/clear, tuner multiplier/freeze/lock/immune changes, real-time slider + presets). Timer decrements in `_process` and flushes to the active profile file. Burst-clamp (floor timer to 0.25s if 20+ mutations stacked) protects against future bulk-preset actions.
- **Atomic writes** — `_profile_write_atomic(path, cfg)` uses `.tmp` + `DirAccess.rename`. Crash or disk-full mid-write leaves the old file intact. Pre-rename `DirAccess.remove` on Windows to overcome the "rename refuses to overwrite" behavior.
- **Schema versioning** — every file stamps `schema_version = PROFILE_SCHEMA_VERSION` (currently 1). Load-time schema gate: `> current` refuses load with toast (do not overwrite; preserves downgrade path); `< current` would run migration (stub for future).
- **Type-validated loads** — per-field `typeof()` check before `set()`. Int↔float promotion allowed (ConfigFile round-trip). Mismatches logged + skipped, so a hand-edited broken profile can't crash the mod. Same defensive pattern as v10.5.1's keybind loader.
- **Dual-write rollout** — legacy `_save_favorites()`, `_save_teleport_slots()`, `_save_keybinds()`, `_save_real_time_pref()`, `_tuner_request_save()` all fire alongside `_profile_mark_dirty()` for one release. Legacy `.cfg` files act as backup; profile system is authoritative on load. Strip in v10.7.
- **Two-phase bootstrap** — `_profile_bootstrap_early()` called from `_ready` before legacy loaders; populates in-memory state for keybinds/favorites/tuner/teleports/real-time from the active profile's non-world sections. `_profile_bootstrap_deferred_world()` drained from `_process` once `controller_found` is true; applies controller-gated cheats (`cheat_speed_mult`, `cheat_no_overweight`, etc.) queued during startup or mid-zone-transition profile switches.
- **First-launch migration** — if `user://cheatmenu_profiles/` doesn't exist, `_profile_migrate_legacy()` reads all v10.5.x per-subsystem cfgs into a fresh profile 1 named "Default"; seeds profiles 2 & 3 with `_profile_defaults_dict`; writes `_active.cfg` pointing at slot 0. Zero migration friction.
- **PROFILES tab** (`_load_category_profiles`) — new Combat-strip entry in `DASHBOARD_NAV_DEFS`. Three cards per-slot via `_build_profile_card`; header status strip showing "Active: ★ Name — Auto-saving in 0.4s…". Card layout: active-marker row, last-saved relative timestamp, content sections (CHEATS / TELEPORTS / FAVORITES / KEYBINDS) with friendly labels, color-coded section headers with count, truncation at 6 items per section with "+ N more", empty-state prompt for fresh slots. Button row varies by active state: `[FLUSH] [RENAME] [RESET]` on active; `[LOAD] [SAVE] [RENAME] [RESET]` on others.
- **HUD chip** — `[PROF:Name]` prepended to the top-right cheat-tag row via `_profile_hud_prefix()` (truncates names > 10 chars with `…`). Refreshed by `_refresh_profile_chip()` on switch/rename.
- **`_show_name_prompt`** modal reused from v10.4.0 for rename dialog. `_show_confirm` reused for reset confirmation.
- **Double-fire guards** — `_name_prompt_submitting` + panel-liveness check on the rename flow; `_delete_confirm_acting` + auto-clear when `confirm_panel` goes invalid (catches the CANCEL path the shared helper doesn't hook).
- **Applicator-layer refactor** — extracted 8 side-effect branches from `_on_cheat_toggled` (no_overweight, tac_hud, real_time, tuner_enabled, unlock_crafting, no_headbob, no_recoil, no_fall_dmg) and 3 from `_on_slider_changed` (speed_mult, jump_mult, fov) into private `_apply_<name>()` functions plus a central `_apply_cheat_side_effects(var, val)` dispatcher. Profile-load calls applicators directly under `_profile_suspend_hud = true` so ~33 sequential applicator calls don't each rebuild the HUD row.
- **`_update_hud` suspend guard** — first-line `if _profile_suspend_hud: return`. Paired with the bulk-apply flag. One `_update_hud()` at end of apply pass.
- **Content-signature rebuild avoidance** — per-card `_profile_card_content_signature[idx]` stores `last_modified` (shifted by active-state bit). Content sections only rebuild when the signature changes, not on per-frame autosave-countdown refreshes. Solves a would-be ~720 Button creates/sec storm during slider drag with Profiles tab open.
- **Button-row rebuild avoidance** — `_profile_card_button_built_for_active` + `_profile_card_button_built_dirty` sentinels; buttons only recreate when the active-marker or dirty-ghost state actually transitions.

### Changed

- **`SETTABLE_VARS` expansion** — added `cheat_ai_esp_theme`, `cheat_ai_esp_hide_dead` so both participate in profile serialization.
- **`DASHBOARD_CATEGORY_NAMES`** — append `"Profiles"`.
- **`DASHBOARD_NAV_DEFS`** — append PROFILES entry on the second row between TUNER and KEYBINDS.
- **`_load_category` match block** — added `"Profiles": _load_category_profiles()` branch.
- **`_ready` lifecycle order** — `_tuner_init_state` (tuner maps need keys before profile apply writes into them) → `_tuner_build_ticker` → `_profile_bootstrap_early` → (if not bootstrap_complete) legacy loads → `_tuner_mark_loaded_freezes_for_recapture` (moved AFTER load so it sees the loaded freeze flags, not pre-init zeros).
- **`NOTIFICATION_WM_CLOSE_REQUEST` + `_exit_tree`** both flush `_profile_flush_if_dirty()` before the tuner/keybind legacy saves. Window close is a force-flush path.
- **Summary counter counts DEVIATIONS from default**, not raw trues — so an empty profile correctly reads "0 cheats" even when `cheat_ai_esp_walls` defaults to true. Single `_profile_default_cheats()` helper is source-of-truth for both the seeder and the counter. Float comparison uses 0.001 epsilon.

### Fixed

- Parse errors during development:
  - Ternary-from-untyped-Array walrus: `var x := _profile_names[idx] if ... else PROFILE_DEFAULT_NAMES[idx]` — Godot can't infer when both branches are Variant. Fixed by adding explicit `var x: String = ...` annotations at 4 sites, plus strongly typing `PROFILE_DEFAULT_NAMES` as `Array[String]` and `_profile_names` etc. as `Array[String]` / `Array[int]` / `Array[Dictionary]`.
  - `"tuner." + sub` inside untyped-iterator: `var sec: String = "tuner." + String(sub)`.

---

## CheatMenu v10.3.0 — merged VitalsTuner + large UX pass

### Added

- **Vitals Tuner feature** (merged from standalone `VitalsTuner.vmz`, now deprecated). New 6th dashboard category `Tuner` with:
  - Per-vital **drain** and **regen** multipliers (0.0x–5.0x, 0.1 step) for all 9 vitals: Health, Energy, Hydration, Mental, Body Temp, Oxygen, Body Stamina, Arm Stamina, Cat.
  - Per-vital **Freeze** (pin to captured value) and **Lock Max** (pin to 100) toggles.
  - 12 **condition immunities**: starvation, dehydration, insanity, frostbite, bleeding, fracture, burn, rupture, headshot, poisoning, isBurning, overweight.
  - **Master Enable** toggle (favoriteable via ★) with descriptive caption and green-tint/dim visual feedback on active/inactive state.
  - One-shot action buttons: **Refill All Vitals**, **Heal Only**, **Clear All Ailments**, **Reset Multipliers**.
  - Live **XX / 100** value readout beside each vital (color-coded red/yellow/green by current value).
- **Observer/corrector pipeline** for the Tuner: `_VitalsTicker` child node with `process_physics_priority = 1000` runs after `Character.gd` every physics frame, scales diffs by user multipliers, respects a `TUNER_JUMP_CUTOFF` of 1.5 units/tick so item consumes / bed sleep / weapon damage pass through unmodified.
- **CheatMenu coexistence guard** inside `_tuner_apply_correction` — skips vitals that a vanilla CheatMenu pin-cheat is already controlling (god_mode, inf_energy, etc.) so the two systems never fight.
- **Legacy cfg auto-migration** from `user://RTV_VitalsTuner_settings.cfg` → `user://cheatmenu_vitals_tuner.cfg` on first launch of merged mod. Logs the migration to the debug console.
- **New bindable action** `tuner_master` (unbound by default) in a new **Tuner** keybind category.
- **HUD tag** `[ TUNER ]` appears when master is enabled and at least one setting is non-default.
- **SPAWN quantity stepper** on every non-weapon item in the Spawner: `[−] [N] [+]` control (range 1–99) above each SPAWN button. Persists the chosen quantity per item across catalog filters/pagination.
- **Batch spawn helper** `_spawn_quantity(item, qty)` that loops `_add_to_inventory`, leveraging the game's native AutoStack for stackables and creating independent slots for non-stackables. Partial-batch inventory-full handling with informative toasts.
- **Modern button styling** (`_make_button_modern`) with rounded corners, pseudo-bevel border, tinted drop-shadow glow, and distinct hover/pressed states. Applied to SPAWN buttons and qty-stepper buttons.
- **Featured nav button** system — `DASHBOARD_NAV_DEFS` now supports a `"featured": true` flag. SPAWNER promoted to top-right position with green CheatMenu accent fill, bold font, ◆ glyph prefix, and persistent highlight regardless of which tab is active.
- **Startup banner** for the Tuner — logs the active keybind and the autoload's tree path on every launch for instant proof-of-life verification.

### Changed

- **Version**: CheatMenu 10.2.0 → 10.3.0. Header banner comment + mod.txt description updated.
- **Dashboard max carry capacity**: now reads the game's own `interface.currentInventoryCapacity` property directly instead of our parallel computation. Matches inventory UI exactly (base + all equipped containers' `itemData.capacity`). Compensates for `No Overweight` cheat by subtracting the 9999 sentinel and adding back the captured original.
- **Dashboard current carry weight**: now reads `interface.currentInventoryWeight` directly. Matches the inventory UI's "KG" readout exactly — only grid contents count, not the equipped containers themselves (mirrors RTV's design intent and the `heavyGear` internal flag separation).
- **Dashboard refresh cadence**: 0.5 s → **0.15 s** while dashboard is visible, so pickups / drops / spawns update the CARRY, ammo match, and stockpile widgets in ~150 ms instead of half a second.
- **One-shot actions** (`_action_heal`, `_action_clear_ailments`, `_action_refill_vitals`) augmented to call `Character.Bleeding(false)` / `Character.Starvation(false)` / etc. via `_tuner_set_cond` so indicator audio stops and UI badges clear cleanly (previously just wrote the bool flags).
- **Action button labels & coverage**: Heal Only / Clear All Ailments / Refill All Vitals actions now present in both the Player tab (unchanged) and the Tuner tab (new), sharing the same augmented implementations.
- **Inventory scan** simplified — `_scan_inventory_if_stale` dropped its parallel weight accumulation (≈50 lines removed), keeps only stockpile counts + ammo-by-caliber since neither is exposed as a game property.
- **Tuner UI layout** rebalanced to a final 50 / 25 / 25 three-column split (VITALS / IMMUNITIES / ACTIONS) with `MarginContainer` right-padding so slider `1.0x` readouts don't collide with the inner scrollbar.
- **Tuner scroll behavior**: only the VITALS column scrolls internally; IMMUNITIES and ACTIONS stay pinned. Section headers stay pinned above the scrollable content.
- **Tuner top cards collapse** — when the Tuner tab is active, the WEAPON / ENEMY BAND / STOCKPILE cards hide (same treatment as World tab) so the tuner has full vertical space on 1080p without scrolling the outer panel.
- **Immunities grid** → single-column stacked list for tighter column width and flush-left label/toggle pairing.
- **Master Enable toggle** rebuilt as a compact custom row (toggle + ★ left, spacer, Reset Sliders right) so the CheckButton indicator sits flush to its label instead of being pushed to the far right by `SIZE_EXPAND_FILL`.
- **Per-vital blocks** restructured — Multipliers + Freeze/Lock controls now live in the same block per vital, guaranteeing perfect alignment (was a multi-column mismatch before).
- **Spawn button column** vertical-centered (`SIZE_SHRINK_CENTER`) so SPAWN chips stay aligned across rows regardless of metadata height; width bumped 92 → 136 px to fit the new qty stepper; separation 2 → 4 px.
- **SPAWN buttons** visually overhauled: solid green chip (alpha +0.4), tinted emission shadow (green glow), asymmetric LED-edge bevel (2 px top / 1 px bottom, inverted on press), SemiBold 12 pt with text shadow, hover pushes glow size 5 → 8 px and label color to `COL_POSITIVE`.
- **Tuner master toggle** now dims the VITALS + IMMUNITIES sections (50 % alpha) when master is off and lightly green-tints them when on — unmistakable active/inactive feedback.

### Fixed

- **ESC key during gameplay** no longer leaves the mouse captured in the game's pause menu. CheatMenu's dashboard-level ESC handler previously called `_set_game_frozen(false)` which raced the game's settings menu for mouse ownership; now it only clears `game_data.freeze` and lets the game own mouse mode from that point forward.
- **Tab-inventory then F5-close bug** — opening the game's inventory (Tab), then F5 for cheat menu, then closing cheat menu would leave the cursor captured despite the inventory still being visible. Fixed by snapshotting mouse mode + freeze state on CheatMenu open and restoring them on close instead of hardcoding `CAPTURED`.
- **CARRY / capacity display** was reading only `baseCarryWeight` (10 kg) without the equipped backpack / rig capacity bonus (+30 on Jääkäri). Now uses the game's `currentInventoryCapacity` so the `/ 40.0` reading matches the inventory UI exactly.
- **Weight display vs inventory UI mismatch** — briefly, our CARRY was showing the backpack's own weight (1.8 kg) while the inventory UI showed 0.0 because equipment weight is intentionally excluded from the "KG" readout by the game. Reverted to match the game's `currentInventoryWeight` only.
- **Missing TUNER nav button** — adding "Tuner" to `DASHBOARD_CATEGORY_NAMES` wasn't enough; the nav row reads from a separate `DASHBOARD_NAV_DEFS` list which was missed in the initial merge.
- **Tuner tab alignment** — Multipliers and Freezes/Locks were in separate columns with mismatched row heights (4 rows vs 1 row per vital), making them impossible to align. Merged into per-vital self-contained blocks.

### Removed

- **Compass preview prototype** — all associated code (`_action_compass_preview`, `_apply_surface_override_recursive`, `_make_surface_double_sided`, `_load_glb_runtime`, `_load_png_runtime`), BINDABLE_ACTIONS entry, COMPASS_ASSET_DIR const, `compass_preview_node` state, PROTOTYPE section button in Player tab, and the entire `assets/compass/` directory (3 GLB meshes + 1 PNG, ~33 MB). Mod size dropped **37.7 MB → 4.7 MB**.
- **Dead code**: `_close_panel`, `_inv_scan_weight` state var (superseded by game's `currentInventoryWeight`), parallel equipment-capacity iteration (superseded by `currentInventoryCapacity`).

### Tech debt eliminated

- ~240 lines of duplicated UI / input / keybind / asset-load code deleted by consolidating VitalsTuner into CheatMenu.
- Parallel weight-math logic replaced by direct reads of `Interface.gd`'s own properties — single source of truth, auto-follows future game updates.
- No more cross-mod `/root/ModLoader/CheatMenuMain` path lookup (was broken anyway — autoloads live at `/root/ModLoader/<name>`, not `/root/<name>`).

---

## VitalsTuner v0.1.7 (final standalone, pre-merge)

Standalone mod was iterated through v0.1.0 → v0.1.7 before being absorbed into CheatMenu v10.3.0. History preserved here for reference.

### v0.1.7 — Full audit pass

- **Fixed** silent runtime no-op in `_apply_master_visual_state`: `Dict[key].modulate.a = x` chain doesn't persist when the first property is a value-type struct returned through a Variant dict access. Replaced with a `_set_node_alpha(node, alpha)` helper that properly get/mutate/set the full `modulate` Color.
- **Fixed** Variant-chain parse fragility in `_is_paused_state` and `_detect_reset_edge`: wrapped `game_data.isTransitioning or game_data.isCaching or game_data.isDead` in explicit `bool()` calls.
- **Fixed** freed-ref risk in `_toggle_panel` diagnostic: `canvas.layer if canvas else -1` replaced with `is_instance_valid(canvas)` check.
- **Fixed** `keybind_code` enum-inference conflict: `:= KEY_F10` was inferred as `Key` type, breaking MouseButton assignments. Explicitly typed all keybind state as `int` / `bool`; removed `as Key` / `as MouseButton` casts.
- **Removed** dead `_close_panel` function (replaced entirely by `_close_panel_silent` earlier).

### v0.1.6 — Critical parse-error fix

- **Fixed** three Godot 4 strict-type parse errors that had silently blocked the autoload from instantiating since v0.1.1:
  - `Input.is_mouse_button_pressed(keybind_code)` — expected `MouseButton` got `int` → explicit `as MouseButton` cast
  - `var cm_holds_freeze := (cm != null and "cheat_open" in cm and cm.cheat_open)` — Variant-chain → explicit `: bool =` annotation + `bool()` wrap
  - Same issue in a sibling function
- **Fixed** broken indentation from an earlier `replace_all` edit that flattened an 8-space nested block to 4-space.
- **Diagnostic** logs added to confirm the mod actually loads (log lines appear in `%APPDATA%\Road to Vostok\logs\godot.log`).

### v0.1.5 — F10 default + diagnostics

- **Changed** default keybind to plain **F10** (verified free vs both game InputMap and CheatMenu defaults).
- **Added** extensive runtime logging: startup banner, hotkey-press events, panel open/close state, bootstrap reseeds.
- **Added** schema-v4 cfg migration that auto-resets existing installs to F10.

### v0.1.4 — Input polling architecture shift

- **Changed** main hotkey detection from `_input` event handler to `Input.is_physical_key_pressed()` polling in `_process`. Bypasses the scene tree's `set_input_as_handled` propagation rules entirely — no other mod / GUI control / viewport can steal our keybind.
- **Fixed** `_find_node_by_name` recursive tree search for CheatMenu (path was `/root/ModLoader/CheatMenuMain` not `/root/CheatMenuMain` — the coexistence guard had been dead code the whole time).

### v0.1.3 — Modifier chord support

- **Added** Ctrl / Shift / Alt modifier support for the keybind (CheatMenu's plain-F7 refill_vitals won't fire on Ctrl+F7 due to exact-modifier-match).
- **Changed** default to **Ctrl+F7**.
- **Added** schema-v3 cfg migration.
- **Added** chord display formatter (`Ctrl+F7`, `Shift+Mouse4`, etc.).

### v0.1.2 — F9 default

- **Changed** default keybind **F7 → F9** after discovery that CheatMenu binds plain F7 to `refill_vitals` by default.
- **Added** schema-v2 cfg migration that auto-rewrites F7 / F8 bindings to F9 for existing users (so they aren't locked out of the panel).

### v0.1.1 — Full code + security audit

- **Fixed** `_VitalsTicker.owner_ref` freed-object check: `if owner_ref` is truthy on freed Objects → switched to `is_instance_valid(owner_ref)`.
- **Added** load-time validation for `keybind_code` — rejects `KEY_NONE`, reserved keys (F5/F6/ESC etc.), out-of-range values; falls back to default.
- **Added** `clampf` on all multiplier values loaded from cfg to defend against hand-edited settings.
- **Fixed** `action_reset_multipliers` signal cascade: switched from `slider.value = 1.0` (fires `value_changed`) to `set_value_no_signal(1.0)` + single save call at end.
- **Fixed** `freeze_val` snap-back on load — saves loaded with `freeze = true` from a previous session would force the vital to last session's captured value. Now marks frozen vitals for re-capture on first enforce each session.
- **Fixed** `/root/CheatMenuMain` path lookup (autoloads live under `/root/ModLoader/`). Coexistence guard now uses recursive tree search with `is_instance_valid` caching.
- **Fixed** `_close_panel_silent` unconditionally clearing `game_data.freeze` when CheatMenu's panel wanted to hold it. Now checks `cheatmenu.cheat_open` before releasing.
- **Added** mouse-button rebind support (MMB, X1, X2, wheels).
- **Added** `RESERVED_KEYS` / `RESERVED_MOUSE` constants.
- **Added** master-enable visual dimming (50 % alpha when off).
- **Changed** `CheckBox` → `CheckButton` throughout the UI for better visual legibility in the dark RTV theme.
- **Changed** `_save_cfg` moved to `call_deferred` to avoid blocking `_process` on disk I/O.
- **Removed** dead color constants `COL_BG`, `COL_DIM`.
- **Added** `COL_WARN`, `VITAL_MIN`, `VITAL_MAX`, `LIVE_REFRESH_SEC` constants (replacing magic numbers).
- **Expanded** reserved-keys list (F4, F11, OS modifiers, Print / Pause / Lock).

### v0.1.0 — Initial release (standalone)

- **Observer/corrector** physics ticker with `process_physics_priority = 1000`.
- **Per-vital** drain/regen multipliers with 1.5-unit jump cutoff for instant-event pass-through.
- **Freeze**, **Lock Max**, **Condition Immunities**, **Refill/Heal/Clear/Reset** actions.
- **F7 hotkey** (later retired) with rebind UI.
- **ConfigFile persistence** at `user://RTV_VitalsTuner_settings.cfg`.
- **Right-side panel** on `CanvasLayer` layer 101, reusing the game's Lora font + Tile texture + Grabber slider sprite.
- **UI fixes**: panel-width tuning, scrollbar-padding MarginContainer, label min-widths so `100 / 100` and `1.0x` don't clip.
- **ESC fix**: ESC from open panel now falls through to the game's settings-menu handler without the cursor being recaptured mid-transition.

---

## Files touched this session

### Modified
- `_extracted/mods/CheatMenu/Main.gd` — ~8666 → ~9540 lines across all changes
- `_extracted/mod.txt` — version bump + description

### Created
- `_extracted/mods/CheatMenu/CHANGELOG.md` — this file
- `_vitalstuner_src/mod.txt` (archived)
- `_vitalstuner_src/mods/VitalsTuner/Main.gd` (archived)
- `_build_vitalstuner.py` (archived)

### Deleted
- `_extracted/mods/CheatMenu/assets/compass/` (3 GLB + 1 PNG, ~33 MB of prototype assets)

### Memory files updated
- `project_rtv_mod.md` — version bump to 10.3.0, feature summary
- `project_rtv_vitalstuner.md` — marked ARCHIVED, historical record preserved
- `MEMORY.md` — index updated

---

## Pending

- In-game QA of the final CheatMenu v10.3.0 build (disable `VitalsTuner.vmz` in mod loader first; verify auto-migration runs; walk the plan's verification checklist).
- Post-QA cleanup: remove `VitalsTuner.vmz` from `mods/`, archive `_vitalstuner_src/`, remove `_build_vitalstuner.py`.
