extends Node
## ================================================================
## Road to Vostok — Cheat Menu v10
## F5  = Cheat Panel     F6 = Item Spawner     ESC = Close
##
## v10.3.0 — Merged VitalsTuner (formerly a standalone mod) as a new
## "Tuner" dashboard category. Per-vital drain/regen multipliers,
## freezes, max-locks, and condition immunities. See "VITALS TUNER"
## banner further down the file for the ported implementation.
## ================================================================

const VERSION := "10.6.2"

# ── Cash System quick-spawn amounts (soft-dep) ─────────────────
const CASH_AMOUNTS := [100, 500, 1000, 5000, 10000]

# ── Keybinds ───────────────────────────────────────────────────
# Every bindable action, grouped by category for the Keys tab UI.
# type = "oneshot" calls fn; type = "toggle" flips var via _on_cheat_toggled.
const KEYBIND_CONFIG_PATH := "user://cheatmenu_binds.cfg"
const BIND_CATEGORIES := ["Vitals", "Movement", "Combat", "World", "Inventory", "Cabin", "Misc", "Tuner"]

# ── Vitals Tuner constants (v10.3.0 — merged from VitalsTuner.vmz) ─
# The Tuner is an observer/corrector on top of the vanilla drain/regen
# system: every physics tick we snapshot each vital's per-tick delta and
# scale it by a user-configured multiplier. Instant events (food, sleep,
# weapon damage) produce diffs larger than TUNER_JUMP_CUTOFF and are
# passed through unmodified. Freezes pin to a captured value, Lock Max
# pins at 100, and condition immunities clear the corresponding
# game_data bool flag each tick.
const TUNER_CONFIG_PATH := "user://cheatmenu_vitals_tuner.cfg"
const TUNER_LEGACY_CFG_PATH := "user://RTV_VitalsTuner_settings.cfg"
const TUNER_CFG_SCHEMA_VERSION := 1
const TUNER_VITALS := [
	"health", "energy", "hydration", "mental", "temperature",
	"oxygen", "bodyStamina", "armStamina", "cat",
]
const TUNER_VITAL_DISPLAY := {
	"health":      "Health",
	"energy":      "Energy",
	"hydration":   "Hydration",
	"mental":      "Mental",
	"temperature": "Body Temp",
	"oxygen":      "Oxygen",
	"bodyStamina": "Body Stamina",
	"armStamina":  "Arm Stamina",
	"cat":         "Cat",
}
const TUNER_CONDITIONS := [
	"starvation", "dehydration", "insanity", "frostbite",
	"bleeding", "fracture", "burn", "rupture",
	"headshot", "poisoning", "isBurning", "overweight",
]
const TUNER_CONDITION_DISPLAY := {
	"starvation":  "Starvation",
	"dehydration": "Dehydration",
	"insanity":    "Insanity",
	"frostbite":   "Frostbite",
	"bleeding":    "Bleeding",
	"fracture":    "Fracture",
	"burn":        "Burn",
	"rupture":     "Rupture",
	"headshot":    "Headshot",
	"poisoning":   "Poisoning",
	"isBurning":   "On Fire",
	"overweight":  "Overweight",
}
# Condition name -> Character.gd clear function. Calling these on the
# Character node (not just writing the bool) fires the proper audio +
# UI cleanup pass (indicator sound stops, badges clear).
#
# NOTE: TUNER_CONDITIONS intentionally contains two MORE entries than
# this dict does — "poisoning" and "isBurning". Both are externally-set
# flags (by food items / fire Area3Ds via Detector.gd) and Character.gd
# has no corresponding setter/clear function. _tuner_call_cure() no-ops
# gracefully via the `""` default when a condition isn't in this dict,
# which is the correct behavior: we still write the flag to false in
# _tuner_enforce_immunities, there's just no audio/UI cleanup pass to
# trigger because Character.gd never fired one for these flags either.
const TUNER_CONDITION_CURE_FN := {
	"starvation":  "Starvation",
	"dehydration": "Dehydration",
	"insanity":    "Insanity",
	"frostbite":   "Frostbite",
	"bleeding":    "Bleeding",
	"fracture":    "Fracture",
	"burn":        "Burn",
	"rupture":     "Rupture",
	"headshot":    "Headshot",
	"overweight":  "Overweight",
	# (no "poisoning" or "isBurning" — see note above)
}
# Per-tick diffs with abs value above this are treated as instant events
# (food consume, bed sleep, weapon damage) and passed through unmodified.
# At 60 Hz the largest continuous drain is delta*10 ≈ 0.166 (burn), the
# largest regen is delta*50 ≈ 0.833 (oxygen surfacing), well below 1.5.
# Smallest legitimate item payload is +1, comfortably above.
const TUNER_JUMP_CUTOFF := 1.5
const TUNER_MULT_MIN := 0.0
const TUNER_MULT_MAX := 5.0
const TUNER_MULT_STEP := 0.1
const TUNER_VITAL_MIN := 0.0
const TUNER_VITAL_MAX := 100.0
const TUNER_LIVE_REFRESH_SEC := 0.3
const TUNER_DEBOUNCE_SAVE_SEC := 0.75

# Which vitals get a Regen slider in the Tuner UI. The observer's regen
# scaling mechanic needs a passive regen source in the vanilla game to
# multiply against — for vitals that only recover from consume items,
# the slider has no effect and we hide it to keep the UI honest.
#
# Health is included because v10.3.1 introduced a SYNTHETIC passive
# regen (_tuner_apply_synthetic_health_regen) so the slider finally has
# teeth: it controls how fast you passively recover HP when damaged and
# no active injury (bleeding/fracture/burn/rupture/headshot) is blocking
# recovery. Base rate = TUNER_HEALTH_REGEN_BASE_HP_PER_SEC × slider.
const TUNER_VITALS_WITH_REGEN := [
	"health",       # synthetic regen, see _tuner_apply_synthetic_health_regen
	"mental",       # vanilla: +delta/4 near heat
	"temperature",  # vanilla: +delta in summer/shelter/tutorial/heat
	"oxygen",       # vanilla: +delta*50 when surfacing from water
	"bodyStamina",  # vanilla: +delta*10 when not running
	"armStamina",   # vanilla: +delta*20 when relaxed
]
# Synthetic-regen curve for Health. Maps the "health" regen slider value
# to an HP/sec rate via piecewise-linear interpolation between anchor
# points. This gives us a non-linear curve (slow in the middle, quick
# at the high end) that a single base × slider multiply couldn't hit.
#
# Targets (slider → time to heal 0→100 HP):
#   0.2×  →  25 min  (1500 s, 0.0667 HP/s) — trickle
#   0.5×  →  15 min  ( 900 s, 0.1111 HP/s) — slow
#   1.0×  →  10 min  ( 600 s, 0.1667 HP/s) — default, background pacing
#   2.0×  →   5 min  ( 300 s, 0.3333 HP/s) — noticeable
#   5.0×  →   1 min  (  60 s, 1.6667 HP/s) — emergency-brake fast
# Below 0.2× the curve linearly tapers to 0 at slider = 0.
# Regen is blocked while any active damaging condition is present —
# bleeds / fractures / burns / ruptures / headshots need to be cleared
# first.
const TUNER_HEALTH_REGEN_CURVE := [
	[0.0, 0.0],
	[0.2, 0.0667],
	[0.5, 0.1111],
	[1.0, 0.1667],
	[2.0, 0.3333],
	[5.0, 1.6667],
]
const TUNER_HEALTH_REGEN_BLOCKERS := [
	"bleeding", "fracture", "burn", "rupture", "headshot",
]

# ── Auto-Med (v10.3.2) ─────────────────────────────────────────
# On injury rising edge, the mod auto-spawns the canonical cure into
# the player's inventory (or drops near them if inventory is full and
# the player has stopped moving). Max 2 of each item kept in stock —
# the top-up rule means players never hoard mountains of bandages but
# always have at least 2 on hand when hurt.
#
# Injury → canonical item name mapping. Resolved to ItemData refs
# lazily via _auto_med_resolve_refs_if_needed() once the catalog is
# scanned. Names match the `name` field of the Resource (stable across
# minor game patches), not the filename.
#
# Insanity intentionally excluded — the only curing item is AFAK
# (rarity 2, 1.2 kg) and auto-spawning a rare heavy kit on mental
# breakdown is heavy-handed. The Tuner → Immunities → Insanity toggle
# handles that use case without Auto-Med.
const AUTO_MED_INJURIES := ["bleeding", "fracture", "burn", "rupture", "headshot"]
const AUTO_MED_INJURY_ITEM_MAP := {
	"bleeding": "Bandage",
	"fracture": "Splint",
	"burn":     "Balm",
	"rupture":  "Medkit",
	"headshot": "IFAK",
}
const AUTO_MED_STOCK_TARGET := 2       # never stock more than N per injury type
const AUTO_MED_STOP_THRESHOLD := 2.5   # seconds of stillness before drop fires

const BINDABLE_ACTIONS := {
	# ── Vitals ──
	"heal":            {"cat": "Vitals", "label": "Heal to Full",          "type": "oneshot", "fn": "_action_heal"},
	"clear_ailments":  {"cat": "Vitals", "label": "Clear All Ailments",    "type": "oneshot", "fn": "_action_clear_ailments"},
	"refill_vitals":   {"cat": "Vitals", "label": "Refill All Vitals",     "type": "oneshot", "fn": "_action_refill_vitals"},
	"god_mode":        {"cat": "Vitals", "label": "Toggle God Mode",       "type": "toggle",  "var": "cheat_god_mode"},
	"inf_stamina":     {"cat": "Vitals", "label": "Toggle Inf Stamina",    "type": "toggle",  "var": "cheat_inf_stamina"},
	"inf_energy":      {"cat": "Vitals", "label": "Toggle Inf Energy",     "type": "toggle",  "var": "cheat_inf_energy"},
	"inf_hydration":   {"cat": "Vitals", "label": "Toggle Inf Hydration",  "type": "toggle",  "var": "cheat_inf_hydration"},
	"inf_oxygen":      {"cat": "Vitals", "label": "Toggle Inf Oxygen",     "type": "toggle",  "var": "cheat_inf_oxygen"},
	"max_mental":      {"cat": "Vitals", "label": "Toggle Max Mental",     "type": "toggle",  "var": "cheat_max_mental"},
	"no_temp_loss":    {"cat": "Vitals", "label": "Toggle No Temp Loss",   "type": "toggle",  "var": "cheat_no_temp_loss"},
	"auto_med":        {"cat": "Vitals", "label": "Toggle Auto-Med",       "type": "toggle",  "var": "cheat_auto_med"},
	# ── Movement ──
	"toggle_fly":      {"cat": "Movement", "label": "Toggle Fly Mode",     "type": "oneshot", "fn": "_action_toggle_fly"},
	"toggle_noclip":   {"cat": "Movement", "label": "Toggle Noclip",       "type": "toggle",  "var": "cheat_noclip"},
	"tp_save":         {"cat": "Movement", "label": "Save Position",      "type": "oneshot", "fn": "_action_tp_save"},
	"tp_last":         {"cat": "Movement", "label": "Teleport to Last",   "type": "oneshot", "fn": "_action_tp_last"},
	"tp_list":         {"cat": "Movement", "label": "Show Saved Positions","type": "oneshot", "fn": "_action_tp_list"},
	"tp_menu":         {"cat": "Movement", "label": "Open Teleport Menu", "type": "oneshot", "fn": "_action_tp_menu"},
	"no_fall_dmg":     {"cat": "Movement", "label": "Toggle No Fall Damage","type": "toggle", "var": "cheat_no_fall_dmg"},
	"no_headbob":      {"cat": "Movement", "label": "Toggle No Head Bob",  "type": "toggle",  "var": "cheat_no_headbob"},
	# ── Combat ──
	"no_recoil":       {"cat": "Combat", "label": "Toggle No Recoil",      "type": "toggle",  "var": "cheat_no_recoil"},
	"inf_ammo":        {"cat": "Combat", "label": "Toggle Infinite Ammo",  "type": "toggle",  "var": "cheat_inf_ammo"},
	"no_jam":          {"cat": "Combat", "label": "Toggle No Weapon Jam",  "type": "toggle",  "var": "cheat_no_jam"},
	"inf_armor":       {"cat": "Combat", "label": "Toggle Infinite Armor", "type": "toggle",  "var": "cheat_inf_armor"},
	"tac_hud":         {"cat": "Combat", "label": "Toggle Tactical HUD",   "type": "toggle",  "var": "cheat_tac_hud"},
	# v10.5.0 — AI awareness controls. See the AI INTELLIGENCE MODULE
	# block at the end of this file for the implementation notes.
	"ai_invisible":    {"cat": "Combat", "label": "Toggle Invisible to AI","type": "toggle",  "var": "cheat_ai_invisible"},
	"ai_esp":          {"cat": "Combat", "label": "Toggle AI ESP Overlay", "type": "toggle",  "var": "cheat_ai_esp"},
	"ai_freeze":       {"cat": "Combat", "label": "Toggle Freeze All AI",  "type": "toggle",  "var": "cheat_ai_freeze"},
	"ai_esp_walls":    {"cat": "Combat", "label": "Toggle Thermal X-Ray",  "type": "toggle",  "var": "cheat_ai_esp_walls"},
	# ── World ──
	"freeze_time":     {"cat": "World", "label": "Toggle Freeze Time",     "type": "toggle",  "var": "cheat_freeze_time"},
	"real_time":       {"cat": "World", "label": "Toggle Real Time Sync",  "type": "toggle",  "var": "cheat_real_time"},
	"restock_traders": {"cat": "World", "label": "Restock All Traders",    "type": "oneshot", "fn": "_action_restock_traders"},
	# ── Inventory ──
	"sort_type":       {"cat": "Inventory", "label": "Sort Inventory (Type)",   "type": "oneshot", "fn": "_action_sort_inventory_type"},
	"sort_weight":     {"cat": "Inventory", "label": "Sort Inventory (Weight)", "type": "oneshot", "fn": "_action_sort_inventory_weight"},
	"stack_dupes":     {"cat": "Inventory", "label": "Stack All Duplicates",    "type": "oneshot", "fn": "_action_stack_duplicates"},
	"no_overweight":   {"cat": "Inventory", "label": "Toggle No Overweight",    "type": "toggle",  "var": "cheat_no_overweight"},
	# ── Cabin ──
	"cabin_stash":     {"cat": "Cabin", "label": "Stash Inventory to Cabin",    "type": "oneshot", "fn": "_action_cabin_stash"},
	"vacuum_stash":    {"cat": "Cabin", "label": "Vacuum + Auto-Stash",         "type": "oneshot", "fn": "_action_vacuum_and_stash"},
	"vacuum_floor":    {"cat": "Cabin", "label": "Vacuum Floor Items",          "type": "oneshot", "fn": "_action_vacuum_floor"},
	"cabin_browser":   {"cat": "Cabin", "label": "Open Cabin Browser",          "type": "oneshot", "fn": "_open_cabin_browser"},
	"return_cabin":    {"cat": "Cabin", "label": "Return to Cabin (prompt)",    "type": "oneshot", "fn": "_action_return_to_cabin_prompt"},
	"delete_floor":    {"cat": "Cabin", "label": "Delete Floor Items (prompt)", "type": "oneshot", "fn": "_action_delete_floor_prompt"},
	# ── Misc ──
	"cat_immortal":    {"cat": "Misc", "label": "Toggle Cat Immortal",     "type": "toggle",  "var": "cheat_cat_immortal"},
	"unlock_crafting": {"cat": "Misc", "label": "Toggle Craft Anywhere",   "type": "toggle",  "var": "cheat_unlock_crafting"},
	"weapon_dashboard":{"cat": "Misc", "label": "Open Weapon Dashboard",   "type": "oneshot", "fn": "_open_weapon_dashboard"},
	# ── Tuner ── (v10.3.0 — merged from VitalsTuner)
	"tuner_master":    {"cat": "Tuner", "label": "Toggle Vitals Tuner",    "type": "toggle",  "var": "cheat_tuner_enabled"},
	"tuner_reset":     {"cat": "Tuner", "label": "Reset Tuner Sliders",    "type": "oneshot", "fn": "_action_tuner_reset_multipliers"},
}

# Runtime keybind state: {action_name: {"device": 0|1, "key": int, "ctrl": bool, "shift": bool, "alt": bool}}
# device 0 = keyboard physical_keycode, 1 = mouse button_index
var keybinds: Dictionary = {}
var _capturing_action: String = ""
var keybind_list_vbox: VBoxContainer = null

# ── Shared game state resource ──────────────────────────────────
var game_data = preload("res://Resources/GameData.tres")

# ── Cheat toggles ───────────────────────────────────────────────
var cheat_god_mode        := false
var cheat_inf_stamina     := false
var cheat_inf_energy      := false
var cheat_inf_hydration   := false
var cheat_inf_oxygen      := false
var cheat_max_mental      := false
var cheat_no_temp_loss    := false
var cheat_no_overweight   := false
var cheat_speed_mult      := 1.0
var cheat_jump_mult       := 1.0
# v10.4.4 — Fly-speed tuning. The game's Fly() hardcodes base=1.0 and
# Shift=100.0 (which users report as "very very slow" and "way too
# fast"). We override via a post-physics position boost (see
# _fly_apply_speed) so the effective per-frame motion matches these
# user-tunable values. Ctrl slow-mode stays at 0.1x of the base.
var cheat_fly_speed       := 15.0   # replaces game's base (1.0)
var cheat_fly_sprint_mult := 4.0    # Shift multiplier; final sprint = base * mult
var cheat_freeze_time     := false
var cheat_time_speed      := 1.0
var cheat_real_time       := false
# Tracks the last system-clock-derived time written by the real-time
# sync branch in _process. Used to detect wall-clock midnight crossings
# (last_t ≈ 2359, new_t ≈ 0) so we can manually fire day++ to replicate
# what the game's own `if time >= 2400.0` check would do if it weren't
# bypassed by our direct-write approach. Reset to -1.0 when the toggle
# turns off so re-enabling later doesn't double-fire.
var _real_time_last_t: float = -1.0
var cheat_no_recoil       := false
var cheat_no_sway         := false
var cheat_no_fall_dmg     := false
var cheat_no_headbob      := false
# v10.4.3 — Noclip: zeros the controller's collision_mask + collision_layer
# so the player passes through world geometry. Pairs naturally with Fly Mode
# but works standalone (e.g. to clip out of a stuck seam). See _apply_noclip.
var cheat_noclip          := false
# Sentinel state for noclip — when _noclip_applied is true we have
# overridden the controller's masks and must restore them on toggle-off
# or controller loss (zone transition).
var _noclip_applied: bool = false
var _saved_collision_mask: int = 0
var _saved_collision_layer: int = 0
var cheat_inf_ammo        := false
var cheat_no_jam          := false
var cheat_inf_armor       := false  # Pins equipped armor plate condition at 100
# v10.5.0 — AI awareness cheats. Each is observed by the AIIntelTicker
# (priority 1000, runs AFTER AI._physics_process), so our writes are
# always the authoritative value for the frame the player sees.
var cheat_ai_invisible    := false
var cheat_ai_esp          := false
var cheat_ai_freeze       := false    # v10.5.6 — pin AI.pause = true, full-stop
var cheat_ai_esp_theme: int = ESP_THEME_VOSTOK    # v10.5.7 — ESP visual theme index
var cheat_ai_esp_walls    := true     # v10.5.10 — Thermal through-walls sub-toggle (default ON — matches "thermal = x-ray" user expectation)
var cheat_ai_esp_hide_dead := true     # v10.6.1 — hide killed NPCs from the ESP overlay (default ON; _davodal_ feedback)
var cheat_cat_immortal    := false
var cheat_fov             := 70.0
var cheat_unlock_crafting := false
var cheat_tac_hud         := false
var original_time_rate    := 0.2777
var sim_found             := false
var sim_ref               = null  # Cached Simulation node reference
# Watchdog state for detecting runaway day rollovers. If day advances
# more than WATCHDOG_MAX_DAYS_PER_SEC in a single second, something
# is forcing repeated rollovers and we self-disable all time cheats
# as a failsafe. Natural max from our own cheats is ~0.14 days/sec
# (Time Speed at 20x), so anything above this threshold is a bug.
var _watchdog_last_day: int = -1
var _watchdog_last_check_ms: int = 0
var _watchdog_days_seen: int = 0
const WATCHDOG_MAX_DAYS_PER_SEC := 3
const WATCHDOG_WINDOW_MS := 1000

# ── Time/World UI refs ─────────────────────────────────────────
var time_display: Label = null
var time_slider: HSlider = null

# ── Teleport bookmarks (v10.4.0) ───────────────────────────────
# Each entry: { "id": int, "name": String, "pos": Vector3 }
# Using a stable monotonic id — NOT the array index — so rapid-click
# handlers can never operate on a wrong slot after the array shifts
# from a delete. See _find_slot_idx_by_id().
# Persisted to disk at TELEPORT_CONFIG_PATH.
var teleport_slots: Array = []
var _teleport_next_id: int = 1
const MAX_TELEPORT_SLOTS := 10
const TELEPORT_CONFIG_PATH := "user://cheatmenu_teleport_slots.cfg"

# Picker / name-prompt overlay state (v10.4.0)
var teleport_picker_panel: PanelContainer = null
var teleport_picker_list_vbox: VBoxContainer = null
var teleport_picker_backdrop: ColorRect = null
var name_prompt_panel: PanelContainer = null
var name_prompt_backdrop: ColorRect = null

# Double-click / double-submit guards — each dialog flips its flag on
# the first user action so a rapid second press becomes a no-op. Cleared
# when the dialog is closed (or replaced).
var _name_prompt_submitting: bool = false
var _delete_confirm_acting: bool = false

# Overlay mouse-mode claim — set when an overlay is opened from a
# keybind path (cheat menu closed, cursor captured in gameplay) and we
# had to flip the cursor VISIBLE ourselves. Stores the prior mouse mode
# so we can restore it exactly on the last-overlay close.
var _overlay_mouse_owned: bool = false
var _overlay_prior_mouse_mode: int = Input.MOUSE_MODE_CAPTURED

# ── Original controller values (captured once) ──────────────────
var base_walk_speed   := 2.5
var base_sprint_speed := 5.0
var base_crouch_speed := 1.0
var base_jump_vel     := 7.0
var base_fall_threshold := 5.0
var base_headbob      := 1.0
var base_fov          := 70.0
var headbob_overridden := false  # Track if WE set headbob to 0
var base_carry_weight := 10.0    # Original Interface.baseCarryWeight
var carry_weight_captured := false
# v10.5.1 — sentinel for _discover_controller baseline capture. Flips
# true on first successful capture and never flips back, so zone
# transitions that re-discover the controller don't overwrite base
# speeds with values that may already reflect an active speed cheat.
var _baselines_captured: bool = false

# ── Craft-anywhere originals (same pattern as headbob) ─────────
# game_data.heat and game_data.PRX_Workbench are stored in a preloaded
# ItemData resource. If the mod sets them true and the game saves while
# the cheat is on, the flags leak into the player's real save. We capture
# the originals on first override and restore in _exit_tree + the else
# branch of _process.
var base_heat := false
var base_prx_workbench := false
var craft_unlock_overridden := false

# ── Saved originals for weapon mods (keyed by Resource) ────────
var saved_recoil := {}   # WeaponData -> {vr, hr, kick}
var saved_sway   := {}   # Sway node instance_id -> {base, aim, canted}
var saved_riser  := {}   # {semiRise, autoRise} — saved once

# Cached refs for the No Recoil hot path. Resolving absolute node paths
# on every _process tick is a measurable drag on low-spec hardware, so
# we cache and re-resolve only when `is_instance_valid` says the cached
# ref has gone stale (scene change, player death, etc.).
var _cached_riser: Node = null
var _cached_cam_noise: Node = null

# ── Whitelist for set() calls ──────────────────────────────────
const SETTABLE_VARS := [
	"cheat_god_mode", "cheat_inf_stamina", "cheat_inf_energy",
	"cheat_inf_hydration", "cheat_inf_oxygen", "cheat_max_mental",
	"cheat_no_temp_loss", "cheat_no_overweight", "cheat_speed_mult",
	"cheat_jump_mult", "cheat_freeze_time", "cheat_time_speed",
	"cheat_no_recoil", "cheat_no_fall_dmg",
	"cheat_no_headbob", "cheat_inf_ammo", "cheat_no_jam", "cheat_inf_armor",
	"cheat_cat_immortal", "cheat_fov", "cheat_unlock_crafting",
	"cheat_tac_hud", "cheat_real_time",
	"cheat_tuner_enabled",  # v10.3.0 — Vitals Tuner master enable
	"cheat_auto_med",       # v10.3.2 — Auto-Med auto-stock on injury
	"cheat_noclip",         # v10.4.3 — Noclip (fly-through-walls)
	"cheat_fly_speed", "cheat_fly_sprint_mult",  # v10.4.4 — Fly-speed tuning
	"cheat_ai_invisible",   # v10.5.0 — Invisible to AI (sensor hijack)
	"cheat_ai_esp",         # v10.5.0 — AI ESP overlay (projection draw)
	"cheat_ai_freeze",      # v10.5.6 — full AI pause (mood: frozen)
	"cheat_ai_esp_walls",   # v10.5.9 — Thermal shader: render through walls
	"cheat_ai_esp_theme",   # v10.5.7 — ESP visual theme index (int)
	"cheat_ai_esp_hide_dead", # v10.6.1 — skip dead AIs in ESP overlay
]

# ── Vitals Tuner state (v10.3.0) ────────────────────────────────
# Gated by cheat_tuner_enabled; the per-physics-tick ticker child is
# the only driver that touches any of these. All modifications go
# through game_data (in-memory); persistence via _tuner_save_cfg.
var cheat_tuner_enabled := false
var tuner_drain_mult := {}              # vital -> float (default 1.0)
var tuner_regen_mult := {}              # vital -> float (default 1.0)
var tuner_freeze := {}                  # vital -> bool
var tuner_freeze_val := {}              # vital -> float (captured on toggle)
var tuner_lock_max := {}                # vital -> bool
var tuner_immune := {}                  # condition -> bool
var tuner_prev := {}                    # vital -> last observed value
var tuner_bootstrap := true             # reseed prev before first correction
var tuner_was_dead := false             # rising-edge detection for isDead
var _tuner_freeze_needs_recapture := {} # vital -> bool (H2 fix from v0.1.7)
var _tuner_cached_character: Node = null
var tuner_ticker: Node = null
# UI refs (populated by _load_category_tuner)
var tuner_drain_sliders := {}
var tuner_drain_labels := {}
var tuner_regen_sliders := {}
var tuner_regen_labels := {}
var tuner_freeze_checks := {}
var tuner_lock_checks := {}
var tuner_immune_checks := {}
var tuner_live_value_labels := {}
var _tuner_live_refresh_timer := 0.0
var _tuner_pending_save := false
var _tuner_save_timer := 0.0
# UI containers whose modulate we dim when cheat_tuner_enabled is off so
# the user sees at a glance that their settings aren't being enforced.
# Repopulated on every _load_category_tuner build (cleared first).
var _tuner_dim_targets: Array = []

# ── Auto-Med state (v10.3.2) ───────────────────────────────────
# Runs independently of cheat_tuner_enabled. Rising-edge detection on
# the 5 injury flags in AUTO_MED_INJURIES; when an edge fires we top
# up the matching canonical item to AUTO_MED_STOCK_TARGET in the
# player's inventory, queuing the overflow to the ground if the
# inventory is full. Ground drops wait for a AUTO_MED_STOP_THRESHOLD
# window of stillness so items don't plop behind the player during
# a sprint.
var cheat_auto_med := false
var _auto_med_prev := {                         # prev injury-flag state for edge detection
	"bleeding": false, "fracture": false, "burn": false,
	"rupture": false, "headshot": false,
}
var _auto_med_bootstrap := true                 # seed prev on first tick, skip edge fire
var _auto_med_item_refs := {}                   # injury -> ItemData (lazy-resolved)
var _auto_med_refs_ready := false
var _auto_med_pending_drops: Array = []         # ItemData queued for ground drop
var _auto_med_stop_timer := 0.0                 # accumulated stillness since last movement
var _auto_med_scan_requested := false           # avoid double-deferring _scan_catalog

# ── Node references ─────────────────────────────────────────────
var canvas: CanvasLayer
var cheat_panel: PanelContainer
var hud_label: Label
var toast_label: Label
var toast_bg: PanelContainer
var toast_timer := 0.0
var controller: CharacterBody3D = null
var controller_found := false

# ── UI state ────────────────────────────────────────────────────
var cheat_open    := false
# v10.6.2 — set true in NOTIFICATION_WM_CLOSE_REQUEST after saving all
# subsystem cfgs. Checked in _exit_tree to skip a redundant save pass
# (H4 audit item). Only read during shutdown — no thread safety needed.
var _saved_at_close := false
var toggle_refs   := {}          # cheat_name -> CheckButton

# ── Cheat panel tabs ───────────────────────────────────────────
var cheat_tab_container: Control = null
var cheat_tab_pages := {}        # tab_name -> ScrollContainer
var cheat_active_tab := ""
var cheat_tab_buttons := {}      # tab_name -> Button
var cheat_tab_bar: HBoxContainer = null  # Tab strip ref — hidden in sub-menu host mode
var submenu_back_button: Button = null    # "← DASHBOARD" button, visible only in sub-menu mode
var submenu_mode := false                 # True while cheat_panel is hosting a sub-menu

# ── Dashboard (v10.3.0 landing page, v10.3.1 loadout+world refresh) ──
const FAVORITES_CONFIG_PATH := "user://cheatmenu_favorites.cfg"
const REAL_TIME_CONFIG_PATH := "user://cheatmenu_real_time.cfg"
const MAX_FAVORITES := 10

# ── Profiles (v10.6.0) ──────────────────────────────────────────
# Users can save up to PROFILE_COUNT named loadouts. Each profile
# captures the entire user-tunable surface of the mod: every
# SETTABLE_VARS entry, favorites, teleport bookmarks, keybinds, the
# Vitals Tuner state, and the Real-Time pref. Autosave on mutation
# (debounced), atomic writes, schema-versioned for forward migration.
# Internal loops are N-capable (bounded by PROFILE_COUNT); the UI is
# intentionally pinned to 3 slots per the v10.6 spec.
const PROFILE_COUNT := 3
const PROFILE_SCHEMA_VERSION := 1
const PROFILE_DIR := "user://cheatmenu_profiles/"
const PROFILE_ACTIVE_PATH := "user://cheatmenu_profiles/_active.cfg"
const PROFILE_AUTOSAVE_DEBOUNCE_SEC := 1.0
const PROFILE_AUTOSAVE_FLOOR_SEC := 0.25          # clamp for dirty-burst
const PROFILE_DIRTY_BURST_THRESHOLD := 20
const PROFILE_NAME_MAX_LEN := 32
const PROFILE_DEFAULT_NAMES: Array[String] = ["Default", "Slot 2", "Slot 3"]

# Active-pointer + autosave state (mirrors the _tuner_save_timer pattern)
var _active_profile_idx: int = 0                   # 0..PROFILE_COUNT-1
var _profile_dirty: bool = false
var _profile_save_timer: float = 0.0
var _profile_dirty_count: int = 0                  # for burst-clamp
var _profile_load_in_progress: bool = false        # spam-click guard
var _profile_bootstrap_complete: bool = false      # sentinel for legacy-load skip
var _profile_dir_verified: bool = false            # cache for _profile_ensure_dir (M1)
var _profile_pending_world_apply: bool = false     # controller-gated defer flag
var _profile_pending_world_cheats: Dictionary = {} # cheats-dict waiting for controller
var _profile_suspend_hud: bool = false             # bulk-apply HUD throttle
# Per-slot metadata cache, rebuilt from disk on change (avoids re-reading
# all 3 profile files every time the Profiles tab repaints).
var _profile_names: Array[String] = []             # length PROFILE_COUNT
var _profile_uuids: Array[String] = []             # length PROFILE_COUNT
var _profile_last_modified: Array[int] = []        # unix ts × PROFILE_COUNT
var _profile_summaries: Array[Dictionary] = []     # counts cache × PROFILE_COUNT

# Inline categories that populate the dashboard content area instead of
# opening a sub-menu. Everything else (Spawner, Keys) uses _open_submenu
# and opens in the floating cheat_panel host.
const DASHBOARD_CATEGORY_NAMES := ["Player", "Combat", "World", "Inventory", "Cabin", "Tuner", "Profiles"]
var dashboard_panel: PanelContainer = null
var dashboard_weapon_vbox: VBoxContainer = null     # Rebuilt on slot change
var dashboard_weapon_stats_vbox: VBoxContainer = null  # Carry weight + ammo match, refreshed every tick
var _dashboard_weapon_stats_signature: Array = []   # [weight_int, max_int, pri_cal, sec_cal, pri_ammo, sec_ammo]
var dashboard_intel_vbox: VBoxContainer = null      # Scavenged-dispatch threat card
var dashboard_world_strip: Label = null             # Compact single-line world info (replaces world card in v10.6)
var dashboard_stockpile_onyou_vbox: VBoxContainer = null  # Rebuilt on refresh
var dashboard_stockpile_cabins_vbox: VBoxContainer = null # Rebuilt on refresh
var dashboard_favorites_row: HBoxContainer = null
var dashboard_refresh_countdown := 0.0
var dashboard_weapon_dirty := true   # Force rebuild of weapon card on next refresh
var _dashboard_weapon_rendered_slot := ""  # v10.4.2 — slot name (primary/secondary) last rendered into the card; used to detect held-weapon swaps and trigger a rebuild
var favorite_actions: Array = []     # Ordered list of SETTABLE_VARS keys (favorited cheats)
var favorite_buttons := {}            # var_name -> Button on dashboard row (for live state sync)
var favorite_star_refs := {}          # var_name -> star Button next to each cheat toggle
# v10.6 inline content area
var dashboard_content_area: VBoxContainer = null   # Full-width holder below the nav row
var dashboard_content_header: Label = null         # "▸ PLAYER" etc. — left cell of header row
var dashboard_header_center: VBoxContainer = null  # Middle cell of header row. World tab parents time_display + time_slider here so they sit over the TIME column instead of inside it; all other categories leave it empty.
var dashboard_content_sliders: VBoxContainer = null # Pinned sliders (full width)
var dashboard_content_columns: HBoxContainer = null # N VBox children, holds toggles/actions
var dashboard_cards_section: VBoxContainer = null  # Wrapper around the 3 top cards; collapsed for World tab
var dashboard_last_category: String = "Player"     # Sticky; restored on dashboard open
var dashboard_nav_buttons: Dictionary = {}         # category_name -> Button (highlight selected)
var _cabin_counts_cache: Dictionary = {}
var _cabin_counts_cache_valid := false
# Per-frame inventory scan cache. The dashboard loadout + stockpile cards
# both read the player's inventoryGrid on every 0.5s tick. Without this
# cache, the grid was walked three times per tick (carry weight, ammo by
# caliber, inventory counts). _scan_inventory_if_stale() populates all
# three results in a single pass, keyed by Engine.get_process_frames()
# so multiple callers in the same frame share the walk.
var _inv_scan_frame: int = -1
var _inv_scan_ammo_by_cal: Dictionary = {}
var _inv_scan_counts: Dictionary = {}
# Tracks which furniture-lookup-miss patterns have already been logged
# this session. Prevents the output log from being spammed when a caller
# probes for furniture that isn't in the current scene (e.g. a non-cabin
# map). Each unique pattern-set logs once.
var _furniture_miss_logged: Dictionary = {}
# Rendered-state signatures so the 0.5s refresh can skip rebuilding
# stockpile rows, loadout, and world cards when nothing has changed.
# Avoids pointless node churn on the scene tree.
var _dashboard_onyou_rendered := {}    # Last rendered inventory counts
var _dashboard_cabins_rendered := {}   # Last rendered cabin counts
var _dashboard_intel_signature: Array = []  # [contact_count, nearest_dist, nearest_state, alerted, wave_in]
var _cached_ai_spawner: Node = null         # Cached /root/.../AISpawner ref, re-resolved on null
# Loot bulletin (v10.6.1) — cached per-map scan of LootContainer nodes
# for high-rarity items. Refreshed when the map name changes; loot is
# rolled at container _ready() so it never changes mid-map.
var _loot_bulletin_cache: Dictionary = {}
var _loot_bulletin_cache_map: String = ""
# Gradient button shaders cache (v10.6.2). One Shader instance per
# effect type is compiled lazily on first use and reused across every
# button that wants that effect. Each button still gets its own
# ShaderMaterial so per-instance uniforms (color_top / color_bot) stay
# independent.
var _cached_shaders: Dictionary = {}

# ── Tactical HUD overlay (v10.4.0) ──────────────────────────────
# Persistent in-game widget anchored top-right that shows live AI data
# while the player is actively playing (not in the cheat menu).
var tac_hud_panel: PanelContainer = null
var tac_hud_subtitle: Label = null
var tac_hud_grid: GridContainer = null
var tac_hud_overflow_label: Label = null
var tac_hud_refresh_countdown: float = 0.0
var _tac_hud_signature: Array = []

# ── Debug log (v10.6.24) ────────────────────────────────────────
# In-memory ring buffer of the mod's own log messages, populated by
# _log(). Surfaced in a floating panel via the DEBUG button in the
# dashboard footer so the player can watch cheat state transitions
# in real time without tailing godot.log. Godot's native log (print
# / push_warning / push_error) is still written unchanged so
# godot.log remains the authoritative source of truth.
const DEBUG_LOG_MAX := 500
const DEBUG_LOG_REFRESH_INTERVAL := 0.2
var debug_log_buffer: Array = []        # each entry: {ts:String, lvl:String, msg:String}
var debug_log_dirty: bool = false
var debug_log_panel: PanelContainer = null
var debug_log_rich: RichTextLabel = null
var debug_log_status: Label = null
var debug_log_pause_btn: Button = null
var debug_log_paused: bool = false
var debug_log_refresh_countdown: float = 0.0

# ── Catalog ─────────────────────────────────────────────────────
var items_by_category := {}      # "Weapons" -> [ItemData, ...]
var scene_for_item    := {}      # ItemData  -> PackedScene
var catalog_ready     := false

# ── Spawner state ───────────────────────────────────────────────
var item_container: VBoxContainer
var search_input:   LineEdit
var page_info:      Label
var subcat_bar:     HBoxContainer
var active_tab_btn: Button = null
var active_sub_btn: Button = null
var selected_cat    := ""
var selected_subcat := ""
var sort_field      := "name"
var sort_ascending  := true
var current_page    := 0
const PAGE_SIZE     := 20
var spawn_cooldown  := 0.0

# ── Bulk-spawn quantity state ──────────────────────────────────
# Each non-weapon catalog row exposes a [−][qty][+] stepper beside its
# SPAWN button. The chosen quantity persists per ItemData reference so
# re-filtering or paginating the catalog doesn't reset it, and users
# can queue up "I always spawn 5 of these" without re-setting every time.
const SPAWN_QTY_MIN := 1
const SPAWN_QTY_MAX := 999999   # v10.6.1 — raised from 99 to support
                                 # bulk ammo (300 rounds) and Cash
                                 # System max-stack (999,999) via the
                                 # new editable qty LineEdit
var _spawn_qty_by_item: Dictionary = {}

# ── Game assets (loaded at runtime) ─────────────────────────────
var game_font: Font = null
var game_font_bold: Font = null
var game_tile: Texture2D = null
var game_grabber: Texture2D = null
# Custom button backgrounds shipped with the mod. Keyed by short name
# (e.g. "dawn", "noon") so button builders can look them up by tag
# without hardcoding paths. Loaded once at _load_game_assets time.
var button_textures: Dictionary = {}
# Procedurally generated streak texture used by GPUParticles2D-based
# rain effects. Generated once at _load_game_assets time and reused
# by every particle emitter.
var rain_particle_texture: Texture2D = null

# ── Theme constants — matched to game's actual UI ───────────────
const COL_BG         := Color(0, 0, 0, 0.88)
const COL_POSITIVE   := Color(0, 1, 0, 1)
const COL_NEGATIVE   := Color(1, 0, 0, 1)
const COL_WARNING    := Color(1, 0.85, 0, 1)  # Amber — used for mid-range vital live readouts
const COL_TEXT       := Color(1, 1, 1, 1)
const COL_TEXT_DIM   := Color(1, 1, 1, 0.5)
const COL_DIM        := Color(1, 1, 1, 0.25)
const COL_SEPARATOR  := Color(1, 1, 1, 0.125)
const COL_SHADOW     := Color(0, 0, 0, 1)
const COL_RARE       := Color(1, 0, 0, 1)
const COL_LEGEND     := Color(0.54, 0, 0.54, 1)
const COL_BTN_NORMAL := Color(0.25, 0.25, 0.25, 0.25)
const COL_BTN_HOVER  := Color(0.25, 0.25, 0.25, 0.5)
const COL_BTN_PRESS  := Color(0.5, 0.5, 0.5, 0.5)
const COL_SPAWN_BTN  := Color(0.15, 0.35, 0.15, 0.5)
const COL_SPAWN_HVR  := Color(0.2, 0.45, 0.2, 0.6)
const COL_DANGER_BTN := Color(0.4, 0.1, 0.1, 0.5)
const COL_DANGER_HVR := Color(0.5, 0.15, 0.15, 0.6)
const ICON_SIZE      := Vector2(52, 52)
const FLOOR_HEIGHT_MAX := 0.8  # Items above this Y are considered on furniture

# ── Gradient button shaders (v10.6.2 World tab) ────────────────
# Static two-color vertical gradient. Used by the time-preset buttons
# and the non-animated weather buttons. COLOR.rgb on the fragment comes
# from mixing color_top (UV.y=0) to color_bot (UV.y=1).
const GRADIENT_SHADER_CODE := """shader_type canvas_item;
uniform vec4 color_top : source_color;
uniform vec4 color_bot : source_color;
void fragment() {
	COLOR = mix(color_top, color_bot, UV.y);
}
"""

# Rain effect (v10.6.3 enhanced). Two-layer streaks at different
# scales for depth, per-stripe hash so streaks aren't perfectly
# uniform, plus a light mist fade at the bottom of the button.
const RAIN_SHADER_CODE := """shader_type canvas_item;
uniform vec4 color_top : source_color;
uniform vec4 color_bot : source_color;

float rain_layer(vec2 uv, float t, float scale_x, float scale_y, float speed, float density) {
	vec2 suv = uv * vec2(scale_x, scale_y);
	suv.y += t * speed;
	suv.x += suv.y * 0.32;
	vec2 id = floor(suv);
	float h = fract(sin(dot(id, vec2(12.9898, 78.233))) * 43758.5453);
	if (h > density) {
		return 0.0;
	}
	float stripe = fract(suv.y + h * 0.35);
	return smoothstep(0.90, 0.97, stripe) * (0.35 + 0.65 * h);
}

void fragment() {
	vec4 base = mix(color_top, color_bot, UV.y);
	// Background layer — denser, fainter, slower
	float back = rain_layer(UV, TIME, 38.0, 4.2, 3.0, 0.85) * 0.35;
	// Foreground layer — sparser, brighter, faster
	float fore = rain_layer(UV, TIME, 22.0, 3.0, 5.0, 0.75) * 0.55;
	// Soft mist at the bottom third
	float mist = smoothstep(0.55, 1.0, UV.y) * 0.12;
	vec3 rain_col = vec3(0.78, 0.88, 1.0);
	COLOR.rgb = base.rgb + rain_col * (back + fore) + vec3(0.82, 0.88, 0.96) * mist;
	COLOR.a = base.a;
}
"""

# Storm effect (v10.6.3 enhanced). Drifting fbm cloud layer + rain
# streaks + periodic lightning flash. Clouds use a custom 2D value
# noise with 4 octaves of fbm. All procedural, no textures needed.
const STORM_SHADER_CODE := """shader_type canvas_item;
uniform vec4 color_top : source_color;
uniform vec4 color_bot : source_color;

float shash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float snoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = shash(i + vec2(0.0, 0.0));
	float b = shash(i + vec2(1.0, 0.0));
	float c = shash(i + vec2(0.0, 1.0));
	float d = shash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * snoise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec4 base = mix(color_top, color_bot, UV.y);

	// Drifting cloud layer — fbm noise with slow horizontal motion.
	// Concentrated in the upper half of the button.
	vec2 cloud_uv = UV * vec2(3.5, 2.2) + vec2(TIME * 0.07, TIME * 0.01);
	float cloud_density = fbm(cloud_uv);
	float cloud_mask = smoothstep(0.28, 0.72, cloud_density);
	cloud_mask *= (1.0 - UV.y * 0.65);
	vec3 cloud_color = vec3(0.38, 0.36, 0.48);
	base.rgb = mix(base.rgb, cloud_color, cloud_mask * 0.55);

	// Rain streaks — single layer to keep GPU cost sane
	vec2 rain_uv = UV * vec2(22.0, 3.5);
	rain_uv.y += TIME * 4.2;
	rain_uv.x += UV.y * 0.55;
	float rhash = fract(sin(dot(floor(rain_uv), vec2(12.9898, 78.233))) * 43758.5453);
	float streak = smoothstep(0.90, 0.96, fract(rain_uv.y + rhash * 0.3));
	base.rgb += vec3(0.72, 0.82, 0.98) * streak * 0.5;

	// Lightning flash — sharp bright pulse every ~3.5s
	float flash_phase = fract(TIME * 0.28);
	float flash = 0.0;
	if (flash_phase < 0.04) {
		flash = (1.0 - flash_phase / 0.04);
	}
	base.rgb += vec3(0.92, 0.90, 1.0) * flash * 0.75;

	COLOR = vec4(base.rgb, base.a);
}
"""

# Rain OVERLAY (v10.6.7). Used on top of a painted rain background
# texture — outputs transparent everywhere except where streaks are,
# so the underlying painting shows through between streaks. Tuned to
# match the Grok-painted base: sparse streaks, cool blue-white color,
# -15 degree skew (left-leaning) matching the wind in the source art.
# Two parallax layers (back/fore) sell the depth. Zero gradient base.
const RAIN_OVERLAY_SHADER_CODE := """shader_type canvas_item;

float rain_layer(vec2 uv, float t, float sx, float sy, float speed, float density, float skew) {
	vec2 suv = uv * vec2(sx, sy);
	suv.x += suv.y * skew;
	suv.y += t * speed;
	vec2 id = floor(suv);
	float h = fract(sin(dot(id, vec2(12.9898, 78.233))) * 43758.5453);
	if (h > density) {
		return 0.0;
	}
	float stripe = fract(suv.y + h * 0.35);
	return smoothstep(0.88, 0.97, stripe) * (0.35 + 0.65 * h);
}

void fragment() {
	float skew = -0.28;
	float back = rain_layer(UV, TIME, 30.0, 3.8, 2.6, 0.55, skew) * 0.40;
	float fore = rain_layer(UV, TIME, 19.0, 2.9, 4.2, 0.45, skew) * 0.65;
	float total = clamp(back + fore, 0.0, 1.0);
	COLOR = vec4(0.86, 0.92, 1.0, total * 0.75);
}
"""

# Aurora effect. Hardcoded green+purple palette that morphs over time.
# Mix factor walks across UV + sin(TIME) so the bands shift horizontally.
const AURORA_SHADER_CODE := """shader_type canvas_item;
void fragment() {
	float t = TIME * 0.4;
	float x = UV.x;
	float y = UV.y;
	vec3 c1 = vec3(0.15, 0.55, 0.35) * (0.75 + 0.25 * sin(t + x * 5.0));
	vec3 c2 = vec3(0.35, 0.15, 0.65) * (0.75 + 0.25 * cos(t * 1.3 + y * 5.0 + x * 2.0));
	vec3 c = mix(c1, c2, smoothstep(0.0, 1.0, y + sin(t + x * 4.0) * 0.15));
	COLOR = vec4(c, 1.0);
}
"""

# ── Category definitions with accent colors ─────────────────────
const CATEGORIES := [
	["Weapons",     Color(0.9, 0.3, 0.2)],
	["Ammo",        Color(0.9, 0.7, 0.2)],
	["Medical",     Color(0.9, 0.2, 0.3)],
	["Food",        Color(0.3, 0.8, 0.3)],
	["Attachments", Color(0.5, 0.4, 0.8)],
	["Equipment",   Color(0.3, 0.6, 0.8)],
	["Knives",      Color(0.6, 0.6, 0.6)],
	["Grenades",    Color(0.8, 0.5, 0.2)],
	["Keys",        Color(0.8, 0.8, 0.3)],
	["Misc",        Color(0.5, 0.5, 0.6)],
]


# ================================================================
#  LIFECYCLE
# ================================================================

func _ready():
	# Keep processing even when the game pauses the scene tree (ESC
	# settings menu calls get_tree().paused = true). Without this,
	# our _process freezes and the TAC HUD stays visible because the
	# hide code never gets a chance to run.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# v10.4.4 — Run our _physics_process AFTER the game's Controller.gd
	# so _fly_apply_speed sees the post-move_and_slide velocity and can
	# apply its position correction cleanly. Lower value = earlier; the
	# game's scene-node physics runs at the default 0, so 1000 puts us
	# reliably last. Mirrors the pattern used by _VitalsTicker.
	process_physics_priority = 1000
	_load_game_assets()
	# v10.6.0 — Profile system is the new source of truth. Tuner state
	# MUST be initialized before profile bootstrap so _profile_apply_tuner
	# has the map keys it writes into; legacy loaders run AFTER bootstrap
	# and only when the profile system failed to populate state.
	_tuner_init_state()
	_tuner_build_ticker()
	_profile_bootstrap_early()
	# Legacy loaders stay in place as dual-write fallback. When
	# _profile_bootstrap_complete is true the profile already populated
	# state — running the legacy loads again would either no-op or
	# overwrite with matching values. Safer to skip.
	if not _profile_bootstrap_complete:
		_load_keybinds()
		_load_favorites()
		_load_real_time_pref()
		_load_teleport_slots()
		_tuner_load_cfg()
	# Runs AFTER all state (profile OR legacy) is loaded so loaded freeze
	# flags get properly marked for session-start value recapture. Moving
	# this below the load block fixes a v10.6.0 ordering bug where the
	# original pre-profile call ran against freshly-initialized empty
	# state (all freezes = false) and flagged nothing.
	_tuner_mark_loaded_freezes_for_recapture()
	canvas = CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)
	# v10.5.0 — AI awareness module. Ticker + ESP overlay spawn here so
	# the ticker's physics priority is set before its first frame. See
	# the AI INTELLIGENCE MODULE block at the bottom of this file.
	_ai_build_ticker()
	_ai_build_esp_overlay()
	_build_cheat_panel()
	_build_dashboard_panel()
	_build_tac_hud_panel()
	_build_hud()
	_build_toast()
	cheat_panel.visible = false
	dashboard_panel.visible = false
	_log("v%s loaded — F5 dashboard | F6 spawner | ESC close" % VERSION)
	_log("All modifications are in-memory only. Restart game to restore defaults.")
	# v10.3.2: Eagerly scan the item catalog on next idle frame so Auto-Med
	# has its canonical cure items resolved BEFORE the player's first
	# injury. Previously the catalog was lazily scanned on first F6 —
	# players who never opened the Spawner and then took damage would see
	# the first injury silently fail (refs weren't resolved yet, rising
	# edge got consumed). Deferring to next idle keeps mod-load snappy.
	if not catalog_ready:
		call_deferred("_scan_catalog")


# v10.5.1 — belt-and-suspenders restoration hook for window-close.
# Godot fires NOTIFICATION_WM_CLOSE_REQUEST when the user clicks the X
# / Alt+F4 BEFORE the SceneTree teardown begins. We flush pending cfg
# saves early so a late-resolving tree teardown can't lose them.
# NOTE: the cheat-mutated fields (game_data.heat, headbob, baseFOV,
# WeaponData.recoil, etc.) are NOT auto-persisted by Godot — they're
# in-memory only unless the game calls ResourceSaver.save on the
# owning resource. Cross-check of Loader.gd confirms the game persists
# a fresh CharacterSave.new() with a whitelisted subset of fields, so
# none of the mod's overrides escape to disk. This hook is defensive,
# not corrective — it just tightens the save timing.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# v10.6.0 — Profile autosave flushes FIRST so the authoritative
		# state lands on disk before the legacy dual-write. If the
		# profile write fails for any reason, the legacy saves still
		# provide a fallback.
		_profile_flush_if_dirty()
		_tuner_save_cfg()
		_save_keybinds()
		# v10.6.2 — H4 fix: mark that we've already flushed here so
		# the _exit_tree teardown (which runs shortly after this) can
		# skip the redundant save. Harmless otherwise but wastes ~2ms
		# of disk I/O in the critical shutdown window.
		_saved_at_close = true


func _exit_tree():
	# v10.6.0 — Same ordering as _notification: profile flush first.
	# v10.6.2 — Skip saves if WM_CLOSE already flushed them.
	if not _saved_at_close:
		_profile_flush_if_dirty()
	# Vitals Tuner (v10.3.0): flush pending cfg save + tear down ticker.
	# The observer is non-destructive by design — it only applies scaled
	# corrections to values the game already writes — so there are no
	# baseline values to restore on game_data. Any active immunities will
	# re-trigger naturally on next frame if their conditions still hold.
	# v10.6.2 — skip if WM_CLOSE already saved (H4 audit item).
	if not _saved_at_close:
		_tuner_save_cfg()
	if is_instance_valid(tuner_ticker):
		tuner_ticker.queue_free()
	# v10.5.0 — tear down AI module. Ticker is a plain Node — its
	# owner_ref gate in _physics_process means one last tick may fire
	# on a freed owner; is_instance_valid in the ticker body handles
	# that. ESP overlay is parented to `canvas` and freed by canvas
	# teardown, but we null the ref defensively.
	if is_instance_valid(_ai_ticker):
		_ai_ticker.queue_free()
	_ai_ticker = null
	if is_instance_valid(_ai_esp_overlay):
		_ai_esp_overlay.queue_free()
	_ai_esp_overlay = null
	if is_instance_valid(_ai_esp_layer):
		_ai_esp_layer.queue_free()
	_ai_esp_layer = null
	# v10.5.9 — restore every mesh we overrode before the autoload
	# frees. Mod unload without this would leave orphaned thermal
	# materials on AIs until the next scene reload.
	_esp_thermal_shader_restore_all()
	# Restore all modified game values on mod unload / scene change
	if controller_found and is_instance_valid(controller):
		controller.walkSpeed = base_walk_speed
		controller.sprintSpeed = base_sprint_speed
		controller.crouchSpeed = base_crouch_speed
		controller.jumpVelocity = base_jump_vel
		if "fallThreshold" in controller:
			controller.fallThreshold = base_fall_threshold
		# v10.6.2 — C1 fix: restore noclip collision masks on mod unload.
		# Without this, unloading the mod while cheat_noclip is true leaves
		# the controller with collision_mask=0 / collision_layer=0 and the
		# player stays permanently intangible until they relaunch the game.
		# The runtime path in _apply_noclip_if_needed restores correctly on
		# toggle-off, but _process won't fire post-free, so _exit_tree has
		# to handle it explicitly.
		if _noclip_applied:
			controller.collision_mask = _saved_collision_mask
			controller.collision_layer = _saved_collision_layer
			_noclip_applied = false
	if headbob_overridden and "headbob" in game_data:
		game_data.headbob = base_headbob
	if craft_unlock_overridden:
		if "heat" in game_data:
			game_data.heat = base_heat
		if "PRX_Workbench" in game_data:
			game_data.PRX_Workbench = base_prx_workbench
		craft_unlock_overridden = false
	if carry_weight_captured:
		var ow_interface = _get_interface()
		if ow_interface != null and is_instance_valid(ow_interface) and "baseCarryWeight" in ow_interface:
			ow_interface.baseCarryWeight = base_carry_weight
	if "baseFOV" in game_data:
		game_data.baseFOV = base_fov
	# Restore recoil values
	for weapon_data in saved_recoil:
		if is_instance_valid(weapon_data):
			var orig = saved_recoil[weapon_data]
			if "verticalRecoil" in weapon_data:
				weapon_data.verticalRecoil = orig["vr"]
			if "horizontalRecoil" in weapon_data:
				weapon_data.horizontalRecoil = orig["hr"]
			if "kick" in weapon_data:
				weapon_data.kick = orig["kick"]
	# v10.6.2 — H2 fix: clear the dict so a re-spawned autoload (dev
	# reload scenarios) starts from an empty baseline instead of re-
	# applying stale WeaponData refs from a freed previous session.
	saved_recoil.clear()
	# Restore Riser values
	if not saved_riser.is_empty() and get_tree() != null:
		var riser = get_tree().current_scene.get_node_or_null("/root/Map/Core/Controller/Pelvis/Riser") if get_tree().current_scene else null
		if riser != null and is_instance_valid(riser) and "semiRise" in riser:
			riser.semiRise = saved_riser["semi"]
			riser.autoRise = saved_riser["auto"]
	# Restore time rate
	if sim_found and sim_ref != null and is_instance_valid(sim_ref):
		sim_ref.rate = original_time_rate
	# Unfreeze if panels were open
	if cheat_open:
		game_data.freeze = false
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# Tear down the TAC HUD overlay so it doesn't linger on the canvas
	# after the mod unloads. Toggle is also forced off so a reload starts
	# from a known state.
	cheat_tac_hud = false
	if is_instance_valid(tac_hud_panel):
		tac_hud_panel.queue_free()


func _load_game_assets():
	# Load the game's own font for native look
	var font_res = load("res://Fonts/Lora-Regular.ttf")
	if font_res is Font:
		game_font = font_res
		_log("Loaded game font: Lora-Regular")
	var font_bold_res = load("res://Fonts/Lora-SemiBold.ttf")
	if font_bold_res is Font:
		game_font_bold = font_bold_res
		_log("Loaded game font: Lora-SemiBold")
	# Load the tile texture used for panel backgrounds
	var tile_res = load("res://UI/Sprites/Tile.png")
	if tile_res is Texture2D:
		game_tile = tile_res
		_log("Loaded game tile texture")
	# Load the slider grabber
	var grabber_res = load("res://UI/Sprites/Grabber.png")
	if grabber_res is Texture2D:
		game_grabber = grabber_res
		_log("Loaded game grabber texture")
	# Load custom button backgrounds shipped with the mod (v10.6.4).
	# Godot's standard `load()` fails on PNG files packaged inside a mod
	# VMZ because they don't ship with an .import file (Godot needs that
	# file to know how to decode the PNG as a Texture2D). Workaround:
	# decode the PNG directly into an Image via `Image.load()` or via
	# raw bytes through FileAccess, then wrap in an ImageTexture. Both
	# bypass the import system entirely and work with mod-packaged PNGs.
	for tex_key in ["dawn", "noon", "dusk", "night",
			"season_summer", "season_winter",
			"weather_neutral", "weather_rain", "weather_storm",
			"weather_overcast", "weather_fog", "weather_wind", "weather_aurora"]:
		var tex: Texture2D = _load_mod_png("res://mods/CheatMenu/assets/buttons/%s.png" % tex_key)
		if tex != null:
			button_textures[tex_key] = tex
			_log("Loaded button texture: %s (%dx%d)" % [tex_key, tex.get_width(), tex.get_height()])
		else:
			_log("button texture missing: %s" % tex_key, "warning")
	# Rain particle system is parked for future iteration — the
	# generator function + _make_rain_particles helper are kept below
	# but not called so the texture isn't wasted at startup.

# Loads a PNG from a mod-packaged path into a runtime Texture2D. Tries
# `Image.load()` first (works with res:// paths for raw images that
# don't have an .import file), falls back to reading raw bytes via
# FileAccess and decoding with `load_png_from_buffer()`. Returns null
# if both paths fail.
func _load_mod_png(path: String) -> Texture2D:
	var img := Image.new()
	var err := img.load(path)
	if err == OK and not img.is_empty():
		return ImageTexture.create_from_image(img)
	# Fallback — read raw bytes and decode manually.
	if FileAccess.file_exists(path):
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.size() > 0:
			var img2 := Image.new()
			var err2 := img2.load_png_from_buffer(bytes)
			if err2 == OK and not img2.is_empty():
				return ImageTexture.create_from_image(img2)
	return null

# Generates the soft streak texture used by rain particles. 4 wide,
# 16 tall. Vertical alpha gradient peaks near the center and fades
# at the top and bottom so each raindrop has a tapered shape instead
# of a hard-edged rectangle. RGB is slightly blue-tinted white to
# match natural rain color. Runs once at mod startup.
func _generate_rain_particle_texture() -> Texture2D:
	var w: int = 4
	var h: int = 20
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var cx: float = float(w - 1) * 0.5
	for y in h:
		# Vertical alpha: 0 at edges, 1 in the middle, via sin curve
		var t: float = float(y) / float(h - 1)
		var a_vert: float = pow(sin(t * PI), 1.4)
		for x in w:
			# Horizontal alpha taper: full at center, 0 at edges
			var dx: float = abs(float(x) - cx) / max(cx, 0.001)
			var a_horz: float = 1.0 - dx
			var alpha: float = clamp(a_vert * a_horz, 0.0, 1.0)
			img.set_pixel(x, y, Color(0.88, 0.94, 1.0, alpha))
	return ImageTexture.create_from_image(img)

# Builds a two-layer GPUParticles2D rain emitter for a button-sized
# Control. Returns a Node2D holding both emitters so the caller can
# add the whole thing as a single child.
#
# Layer 1 (far):  many small slow particles for background parallax
# Layer 2 (near): fewer large fast particles for foreground detail
#
# Both layers use the same streak texture. Both emit from a horizontal
# strip at the top of the button and fall roughly vertically with a
# slight leftward slant matching the wind in the Grok-painted base art.
# Rotation of each particle is tied to its direction so streaks lean
# the way they're falling instead of being drawn as vertical rectangles
# moving diagonally (the telltale "fake rain" look).
func _make_rain_particles(parent: Control) -> Node2D:
	var root := Node2D.new()

	# Tunables — tweak these to match a specific painted scene
	var slant_deg: float = -12.0                          # -left, +right
	var slant_rad: float = deg_to_rad(slant_deg)
	var dir_vec := Vector3(sin(slant_rad), cos(slant_rad), 0.0)

	# ── Far layer: small, slow, dense ─────────────────────────
	var far := GPUParticles2D.new()
	far.amount = 60
	far.lifetime = 0.55
	far.preprocess = 0.55  # pre-fill so the button shows active rain immediately
	far.explosiveness = 0.0
	far.randomness = 0.35
	far.local_coords = true
	far.texture = rain_particle_texture
	var far_mat := ParticleProcessMaterial.new()
	far_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	far_mat.emission_box_extents = Vector3(110, 1, 0)
	far_mat.direction = dir_vec
	far_mat.spread = 3.0
	far_mat.initial_velocity_min = 260.0
	far_mat.initial_velocity_max = 310.0
	far_mat.scale_min = 0.6
	far_mat.scale_max = 1.0
	far_mat.gravity = Vector3(0, 40, 0)
	far_mat.angle_min = slant_deg
	far_mat.angle_max = slant_deg
	far_mat.color = Color(0.85, 0.92, 1.0, 0.55)
	far.process_material = far_mat
	root.add_child(far)

	# ── Near layer: larger, faster, sparser ───────────────────
	var near := GPUParticles2D.new()
	near.amount = 22
	near.lifetime = 0.40
	near.preprocess = 0.40
	near.explosiveness = 0.0
	near.randomness = 0.45
	near.local_coords = true
	near.texture = rain_particle_texture
	var near_mat := ParticleProcessMaterial.new()
	near_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	near_mat.emission_box_extents = Vector3(110, 1, 0)
	near_mat.direction = dir_vec
	near_mat.spread = 4.0
	near_mat.initial_velocity_min = 400.0
	near_mat.initial_velocity_max = 480.0
	near_mat.scale_min = 1.2
	near_mat.scale_max = 1.8
	near_mat.gravity = Vector3(0, 60, 0)
	near_mat.angle_min = slant_deg
	near_mat.angle_max = slant_deg
	near_mat.color = Color(0.92, 0.96, 1.0, 0.85)
	near.process_material = near_mat
	root.add_child(near)

	# Reposition the emitter when the parent Control is laid out or
	# resized. Node2D children of a Control don't anchor automatically,
	# so we listen to `resized` and sync the position + emission extents.
	var update := func():
		if not is_instance_valid(parent) or not is_instance_valid(root):
			return
		var w: float = parent.size.x
		root.position = Vector2(w * 0.5, 0.0)
		if is_instance_valid(far.process_material):
			(far.process_material as ParticleProcessMaterial).emission_box_extents = Vector3(w * 0.5, 1, 0)
		if is_instance_valid(near.process_material):
			(near.process_material as ParticleProcessMaterial).emission_box_extents = Vector3(w * 0.5, 1, 0)
	parent.resized.connect(update)
	# Deferred one-shot so the initial layout kicks the emitter to the
	# right size before the first frame renders.
	parent.call_deferred("emit_signal", "resized")

	return root


func _input(event: InputEvent):
	# ─────────────────────────────────────────────────────────────
	# F5 / F6 have the highest possible priority — they ALWAYS work,
	# even during rebind capture. This prevents the silent trap where
	# a user who clicked "rebind" in the Keys tab then pressed F5 to
	# abort would see nothing happen (the old rebind gate ate the
	# event and rejected F5 as reserved). If capture is in progress,
	# we cancel it first so the user returns to normal menu state.
	# ─────────────────────────────────────────────────────────────
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F5:
			if _capturing_action != "":
				_cancel_capture()
			cheat_open = !cheat_open
			_set_game_frozen(cheat_open)
			if cheat_open:
				_show_dashboard()
				_sync_toggle_ui()
			else:
				_hide_all_menus()
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_F6:
			if _capturing_action != "":
				_cancel_capture()
			if not cheat_open:
				cheat_open = true
				_set_game_frozen(true)
				_sync_toggle_ui()
			_open_submenu("Spawner")
			if not catalog_ready:
				call_deferred("_scan_catalog")
			get_viewport().set_input_as_handled()
			return

	# Keybind rebind capture mode eats all OTHER input until a key/button lands
	if _capturing_action != "":
		_try_capture_bind(event)
		return

	# Mouse button keybinds fire via a separate path (InputEventMouseButton)
	if event is InputEventMouseButton:
		if event.pressed and _try_fire_keybind(event):
			get_viewport().set_input_as_handled()
		return

	if not event is InputEventKey or not event.pressed or event.echo:
		return
	# Block Tab/Enter/Space from reaching our UI when menus are open
	# This prevents keyboard focus cycling through buttons
	if cheat_open and event.keycode in [KEY_TAB, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		get_viewport().set_input_as_handled()
		return
	# Remaining hardcoded menu control (F5/F6 handled above at top priority)
	match event.keycode:
		KEY_ESCAPE:
			# v10.5.1 — sub-subpanel cascade runs BEFORE the cheat_open
			# check so ESC dismisses an orphaned teleport picker / name
			# prompt even when the dashboard isn't the thing that opened
			# it (e.g. picker launched via a direct keybind). Without
			# this first check, ESC fell through to the game's handler
			# while the overlay stayed on screen.
			if _any_subsubpanel_open():
				_close_all_subpanels()
				get_viewport().set_input_as_handled()
				return
			# ESC cascade: sub-menu > dashboard > closed
			if cheat_open:
				if submenu_mode:
					_show_dashboard()
				else:
					# v10.3.0 fix: ESC from the top-level dashboard lets
					# the event propagate to the game's own ESC handler
					# (which opens the settings menu and takes ownership
					# of mouse visibility + pause). We previously called
					# _set_game_frozen(false) here — that captured the
					# mouse AFTER the game made it visible, producing
					# the "mouse disappears in pause menu" bug.
					# We still release game_data.freeze so the game can
					# freeze its own way; we DO NOT touch mouse mode.
					# Also invalidate the open-time snapshot — the game
					# is about to take mouse ownership so our saved
					# value is stale from this point on.
					cheat_open = false
					_hide_all_menus()
					if "freeze" in game_data:
						game_data.freeze = false
					_mouse_state_captured = false
			return
	# Fall through to user-configured keybinds
	if _try_fire_keybind(event):
		get_viewport().set_input_as_handled()


func _process(delta: float):
	# Scene transition guard — current_scene is null while zone loading
	if get_tree() == null or get_tree().current_scene == null:
		return

	# Controller discovery — re-discover after zone transition
	if not controller_found or not is_instance_valid(controller):
		controller_found = false
		_discover_controller()

	# v10.6.0 — Drain any controller-gated cheats that were queued during
	# bootstrap or a mid-zone profile switch. Fires exactly once per apply
	# cycle and only when the Controller is in the scene.
	if _profile_pending_world_apply and controller_found:
		_profile_bootstrap_deferred_world()

	# v10.6.0 — Autosave debounce. Runs every frame; cheap no-op unless
	# something is dirty. Flushes to the active profile file when the
	# timer elapses. Also refreshes the Profiles-tab UI countdown while
	# the Profiles tab is open so the user sees the ticker counting down.
	_profile_tick_autosave(delta)
	if _profile_dirty and cheat_active_tab == "Profiles":
		_refresh_profiles_ui()

	# Simulation discovery — capture original rate once, cache reference
	if not sim_found:
		sim_ref = get_node_or_null("/root/Simulation")
		if sim_ref != null and "rate" in sim_ref:
			original_time_rate = sim_ref.rate
			sim_found = true
			_log("Simulation found — base rate=%.4f" % original_time_rate)

	# Time controls — apply freeze / speed multiplier / real-time sync.
	# Real Time takes highest priority when enabled: it pins sim_ref.time
	# to the player's local system clock every frame and zeros the sim
	# rate so the game's natural advance doesn't fight us back.
	#
	# NOTE: we write sim_ref.time directly (not via rate-slowing) because
	# the game's time encoding is base-100-minutes-per-hour linear float,
	# so a simple rate scalar can't make the display match wall clock —
	# the minute hand would tick at 1.67x real time within each hour.
	# Direct write is the only way to keep the displayed minute exactly
	# matching the player's watch.
	#
	# Side effect: writing sim_ref.time directly bypasses the game's
	# own `if time >= 2400.0: day += 1` check in Simulation.gd, so we
	# detect wall-clock midnight crossings manually and fire the day
	# increment + Loader.UpdateProgression() to match what the game
	# would do on natural advancement.
	if sim_found and sim_ref != null and is_instance_valid(sim_ref):
		if cheat_real_time:
			var sys_time: Dictionary = Time.get_time_dict_from_system()
			var rt_h: int = int(sys_time.get("hour", 0))
			var rt_m: int = int(sys_time.get("minute", 0))
			var rt_s: int = int(sys_time.get("second", 0))
			# HHMM encoding + fractional seconds for smooth sub-minute
			# ticking. sim_ref.time is a float; integer portion is what
			# the display reads.
			var rt_t: float = float(rt_h * 100 + rt_m) + float(rt_s) / 60.0
			# Midnight wrap: previous tick was near end-of-day and
			# current tick is at start-of-day → bump day + call the
			# game's progression update so mid-day loot respawns,
			# quest timers, etc. fire like they would naturally.
			if _real_time_last_t > 2300.0 and rt_t < 100.0:
				_advance_day_by_one("real_time_midnight")
			_real_time_last_t = rt_t
			# Route every sim.time write through the safe setter so
			# the rollover-protection applies uniformly, even for
			# automated per-frame writes like Real Time sync.
			_safe_set_sim_time(rt_t, "real_time_sync")
			sim_ref.rate = 0.0
		elif cheat_freeze_time:
			sim_ref.rate = 0.0
			_real_time_last_t = -1.0
		elif cheat_time_speed != 1.0:
			sim_ref.rate = original_time_rate * cheat_time_speed
			_real_time_last_t = -1.0
		else:
			sim_ref.rate = original_time_rate
			_real_time_last_t = -1.0
		# Update time display and slider when panel is open.
		# is_instance_valid() is required — typed Node refs don't auto-null
		# after queue_free(), so `!= null` can dereference a freed label.
		if cheat_open and is_instance_valid(time_display):
			var t = sim_ref.time
			var clock_str = _format_sim_clock(t, cheat_real_time)
			var tod_name = _get_tod_name(t)
			var season_name = "Summer" if sim_ref.season == 1 else "Winter"
			time_display.text = "Time: %s  (%s)  Day %d  %s  [%s]" % [clock_str, tod_name, sim_ref.day, season_name, sim_ref.weather]
			if is_instance_valid(time_slider) and not time_slider.has_focus():
				time_slider.set_value_no_signal(t)
		# Runaway-day watchdog (defense layer 4). If the day counter
		# advances more than WATCHDOG_MAX_DAYS_PER_SEC inside a single
		# rolling 1-second window, something is forcing repeated
		# rollovers — well above any rate our cheats should produce.
		# Self-disable every time cheat as a failsafe and log loudly.
		_watchdog_check_day_rollovers()

	# Spawn cooldown tick
	if spawn_cooldown > 0.0:
		spawn_cooldown -= delta

	# Weapon dashboard — auto-refresh the ammo/status labels, NOT the whole
	# panel, UNLESS the player has swapped which weapon is drawn (v10.4.1).
	# If drawn-slot differs from dashboard_active_slot we do a full rebuild
	# so the card (icon, name, attachments) tracks the held weapon. Empty
	# held ("" = fists / no draw) leaves the dashboard on its current slot.
	if dashboard_open and is_instance_valid(dashboard_vbox):
		dashboard_refresh_timer -= delta
		if dashboard_refresh_timer <= 0.0:
			dashboard_refresh_timer = 0.5
			var held := _get_active_weapon_slot()
			if held != "" and held != dashboard_active_slot and _get_slot_data_for(held) != null:
				dashboard_active_slot = held
				_refresh_dashboard_content()
			else:
				_update_dashboard_live_stats()

	# Main dashboard — live refresh vitals bars, stockpile counts, weapon card,
	# and favorites state. 0.15s cadence (v10.3.0) so carry weight, ammo
	# match, and stockpile counts feel live when the player picks up,
	# drops, or spawns items. Cheap to do — every widget the refresh
	# touches reads from the once-per-frame inventory scan cache.
	# Use is_instance_valid so a queued-free panel doesn't slip through.
	if is_instance_valid(dashboard_panel) and dashboard_panel.visible:
		dashboard_refresh_countdown -= delta
		if dashboard_refresh_countdown <= 0.0:
			dashboard_refresh_countdown = 0.15
			_refresh_dashboard_live()

	# Tactical HUD overlay. Split into two cadences so the panel can
	# open and close instantly the moment the player enters or leaves
	# a menu, without paying the cost of a full contact-list rebuild
	# every frame:
	#   - Visibility gate: runs EVERY frame. Cheap boolean checks only
	#     (mouse mode, shelter, enemies present, cheat toggle). Lets the
	#     panel hide/show in one frame rather than up to 250ms later.
	#   - Content refresh: stays throttled at 4Hz via the countdown.
	#     Rebuilds the contact rows, bearings, health bars, etc.
	if is_instance_valid(tac_hud_panel):
		var should_show := _tac_hud_should_show()
		if not should_show and tac_hud_panel.visible:
			tac_hud_panel.visible = false
			_tac_hud_signature = []
		tac_hud_refresh_countdown -= delta
		if tac_hud_refresh_countdown <= 0.0:
			tac_hud_refresh_countdown = TAC_HUD_REFRESH_INTERVAL
			_refresh_tac_hud()
		# Minimap pulse animation is GPU-driven via shader TIME uniform;
		# no per-frame CPU work needed.

	# Debug log — throttled redraw so bursty _log() calls don't
	# thrash the RichTextLabel's text layout. Redraw is skipped
	# entirely when the panel is closed or paused (no work done).
	if _is_debug_log_visible() and debug_log_dirty and not debug_log_paused:
		debug_log_refresh_countdown -= delta
		if debug_log_refresh_countdown <= 0.0:
			debug_log_refresh_countdown = DEBUG_LOG_REFRESH_INTERVAL
			_refresh_debug_log_view()

	# Toast fade
	if toast_timer > 0.0:
		toast_timer -= delta
		if toast_timer <= 0.0:
			toast_bg.visible = false

	# Vitals Tuner (v10.3.0): debounced persistence + throttled live-value
	# refresh. Runs independently of _any_cheat_active() because the tuner
	# has its own ticker-driven pipeline and its own master toggle; adding
	# cheat_tuner_enabled to the gate would false-positive the entire
	# _process cheat block below.
	if _tuner_pending_save:
		_tuner_save_timer -= delta
		if _tuner_save_timer <= 0.0:
			_tuner_pending_save = false
			call_deferred("_tuner_save_cfg")
	if cheat_open and cheat_active_tab == "Tuner":
		_tuner_live_refresh_timer -= delta
		if _tuner_live_refresh_timer <= 0.0:
			_tuner_refresh_live_values()
			_tuner_live_refresh_timer = TUNER_LIVE_REFRESH_SEC

	# Skip cheat application if nothing is active
	if not _any_cheat_active():
		return

	# Apply cheats
	if cheat_god_mode:
		game_data.health = 100.0
		game_data.isDead = false
		game_data.bleeding = false
		game_data.fracture = false
		game_data.burn = false
		game_data.rupture = false
		game_data.headshot = false
		game_data.isBurning = false
	if cheat_inf_stamina:
		game_data.bodyStamina = 100.0
		game_data.armStamina = 100.0
	if cheat_inf_energy:
		game_data.energy = 100.0
		game_data.starvation = false
	if cheat_inf_hydration:
		game_data.hydration = 100.0
		game_data.dehydration = false
	if cheat_inf_oxygen:
		game_data.oxygen = 100.0
	if cheat_max_mental:
		game_data.mental = 100.0
		game_data.insanity = false
	if cheat_no_temp_loss:
		game_data.temperature = 100.0
		game_data.frostbite = false
	if cheat_no_overweight:
		var ow_interface = _get_interface()
		if ow_interface != null and is_instance_valid(ow_interface) and "baseCarryWeight" in ow_interface:
			if not carry_weight_captured and ow_interface.baseCarryWeight < 9000:
				base_carry_weight = ow_interface.baseCarryWeight
				carry_weight_captured = true
			ow_interface.baseCarryWeight = 9999.0
	if cheat_no_jam:
		if "jammed" in game_data:
			game_data.jammed = false
	if cheat_inf_armor:
		_apply_infinite_armor()
	if cheat_cat_immortal:
		if "cat" in game_data:
			game_data.cat = 100.0
		if "catDead" in game_data:
			game_data.catDead = false
	if cheat_no_headbob:
		if "headbob" in game_data:
			game_data.headbob = 0.0
			headbob_overridden = true
	elif headbob_overridden:
		if "headbob" in game_data:
			game_data.headbob = base_headbob
		headbob_overridden = false
	# v10.4.3 — Noclip. Zeros the CharacterBody3D's collision_mask +
	# collision_layer so the player passes through world geometry.
	# Pairs naturally with Fly Mode (F8) for fly-through-walls movement.
	# Bookkeeping guarantees we only save the pre-noclip masks once per
	# ON cycle and restore exactly on toggle-off; also self-corrects if
	# the controller is lost to a zone transition (state clears, next
	# discovery re-applies automatically if cheat_noclip is still true).
	_apply_noclip_if_needed()
	if cheat_fov != base_fov:
		if "baseFOV" in game_data:
			game_data.baseFOV = cheat_fov
	if cheat_inf_ammo:
		_apply_infinite_ammo()
	if cheat_unlock_crafting:
		if not craft_unlock_overridden:
			if "heat" in game_data:
				base_heat = game_data.heat
			if "PRX_Workbench" in game_data:
				base_prx_workbench = game_data.PRX_Workbench
			craft_unlock_overridden = true
		if "heat" in game_data:
			game_data.heat = true
		if "PRX_Workbench" in game_data:
			game_data.PRX_Workbench = true
	elif craft_unlock_overridden:
		if "heat" in game_data:
			game_data.heat = base_heat
		if "PRX_Workbench" in game_data:
			game_data.PRX_Workbench = base_prx_workbench
		craft_unlock_overridden = false

	# Speed and jump — with validity check and direct currentSpeed override
	if controller_found:
		if not is_instance_valid(controller):
			controller = null
			controller_found = false
			_log("Controller lost — re-discovering", "warning")
		elif controller != null:
			if cheat_speed_mult != 1.0:
				controller.walkSpeed = base_walk_speed * cheat_speed_mult
				controller.sprintSpeed = base_sprint_speed * cheat_speed_mult
				controller.crouchSpeed = base_crouch_speed * cheat_speed_mult
				# Force currentSpeed directly for instant effect
				if "currentSpeed" in controller:
					if controller.currentSpeed > 0.1:
						var target = base_walk_speed * cheat_speed_mult
						if "isRunning" in game_data and game_data.isRunning:
							target = base_sprint_speed * cheat_speed_mult
						elif "isCrouching" in game_data and game_data.isCrouching:
							target = base_crouch_speed * cheat_speed_mult
						controller.currentSpeed = target
			else:
				# Reset ALL values including currentSpeed for clean return to default
				controller.walkSpeed = base_walk_speed
				controller.sprintSpeed = base_sprint_speed
				controller.crouchSpeed = base_crouch_speed
				# Kill lingering boost when slider drops back to 1.0 — but only
				# clamp if currentSpeed is ABOVE sprint (i.e. a real leftover boost).
				# Clamping against walkSpeed here broke normal sprinting at 1.0x.
				if "currentSpeed" in controller:
					if controller.currentSpeed > base_sprint_speed + 0.5:
						controller.currentSpeed = base_sprint_speed

			if cheat_jump_mult != 1.0:
				controller.jumpVelocity = base_jump_vel * cheat_jump_mult
			else:
				controller.jumpVelocity = base_jump_vel

			# No fall damage — set threshold impossibly high
			if cheat_no_fall_dmg:
				if "fallThreshold" in controller:
					controller.fallThreshold = 99999.0
			else:
				if "fallThreshold" in controller and controller.fallThreshold > 9999:
					controller.fallThreshold = base_fall_threshold

	# No recoil (includes sway removal)
	if cheat_no_recoil:
		_apply_weapon_mods()

	_update_hud()


func _any_cheat_active() -> bool:
	# IMPORTANT: this also returns true while an "overridden" flag is
	# still set — even if the owning cheat has been toggled off. That
	# keeps _process running for one more frame so the elif cleanup
	# branches below can restore captured base values. Without this,
	# turning off the last active cheat would skip the cleanup pass
	# entirely (the cheat itself is false, so the main gate would
	# return, leaving stale overrides on game_data).
	return (cheat_god_mode or cheat_inf_stamina or cheat_inf_energy
		or cheat_inf_hydration or cheat_inf_oxygen or cheat_max_mental
		or cheat_no_temp_loss or cheat_no_overweight
		or cheat_speed_mult != 1.0 or cheat_jump_mult != 1.0
		or cheat_freeze_time or cheat_time_speed != 1.0
		or cheat_no_recoil or cheat_no_fall_dmg
		or cheat_no_headbob or cheat_inf_ammo or cheat_no_jam or cheat_inf_armor
		or cheat_cat_immortal or cheat_fov != base_fov
		or cheat_unlock_crafting
		or cheat_noclip or _noclip_applied
		or cheat_ai_invisible or cheat_ai_esp or cheat_ai_freeze
		or craft_unlock_overridden or headbob_overridden)


# ================================================================
#  VITALS TUNER — observer/corrector pipeline (v10.3.0)
# ================================================================
# Merged from VitalsTuner.vmz v0.1.7. The standalone mod is deprecated;
# this is now the single source of truth.
#
# MECHANISM: every physics tick, AFTER Character.gd has drained/regened
# each vital, we compute the per-tick delta and scale it by the user's
# drain or regen multiplier. Instant events (eating food, sleeping in
# bed, weapon damage) produce diffs larger than TUNER_JUMP_CUTOFF and
# are passed through unmodified, so their game-intended impact survives.
#
# WHY A CHILD NODE: Godot 4's process_physics_priority controls the tick
# order within _physics_process. Higher runs LATER. 1000 guarantees we
# tick AFTER Character.gd regardless of autoload ordering — our
# observation always sees the post-step vitals.

class _VitalsTicker extends Node:
	var owner_ref: Node
	func _physics_process(delta: float):
		# is_instance_valid guards against owner being mid-free during
		# mod unload. Plain `if owner_ref` returns true for freed Objects.
		if is_instance_valid(owner_ref) and owner_ref.has_method("_tuner_on_physics_tick"):
			owner_ref._tuner_on_physics_tick(delta)

func _tuner_build_ticker():
	tuner_ticker = _VitalsTicker.new()
	tuner_ticker.owner_ref = self
	tuner_ticker.name = "VitalsTunerTicker"
	# Set priority + process mode BEFORE add_child so the node is
	# registered with the correct values from the first physics frame.
	tuner_ticker.process_physics_priority = 1000
	tuner_ticker.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(tuner_ticker)

func _tuner_init_state():
	for v in TUNER_VITALS:
		tuner_drain_mult[v] = 1.0
		tuner_regen_mult[v] = 1.0
		tuner_freeze[v] = false
		tuner_freeze_val[v] = TUNER_VITAL_MAX
		tuner_lock_max[v] = false
		_tuner_freeze_needs_recapture[v] = false
	for c in TUNER_CONDITIONS:
		tuner_immune[c] = false

# Mark every persisted-true freeze for re-capture after load. Called
# immediately after _tuner_load_cfg so the first enforce pass captures
# the loaded save's current value rather than snapping to whatever was
# frozen last session. Without this, loading a save with health=95 but
# freeze_val=73 from last session would yank health to 73.
func _tuner_mark_loaded_freezes_for_recapture():
	for v in TUNER_VITALS:
		if tuner_freeze[v]:
			_tuner_freeze_needs_recapture[v] = true

# Main physics tick callback. Executes the pipeline only when the master
# toggle is on AND the game is in a stable state (not transitioning,
# loading, or in a death screen).
func _tuner_on_physics_tick(delta: float):
	if game_data == null:
		return

	# v10.3.2: Auto-Med runs independently of the Tuner master toggle
	# so users can keep vanilla drain/regen while still getting the
	# auto-stock behavior. Runs BEFORE the tuner-master gate and BEFORE
	# _tuner_enforce_immunities so it sees injury flags in their active
	# state (immunities clear them same-tick).
	if cheat_auto_med:
		_auto_med_tick(delta)

	if not cheat_tuner_enabled:
		return
	_tuner_detect_reset_edge()
	if _tuner_is_paused_state():
		tuner_bootstrap = true
		return
	if tuner_bootstrap:
		_tuner_seed_prev()
		tuner_bootstrap = false
		return
	_tuner_apply_correction()
	_tuner_enforce_freeze_and_lock()
	_tuner_enforce_immunities()
	# v10.3.1: synthetic health regen runs AFTER the observer correction
	# + enforcement passes so the regen we add isn't observed and re-scaled
	# on the next tick. _tuner_update_prev immediately below snapshots the
	# post-regen health value, so tick t+1's diff (current - prev) captures
	# only new vanilla game changes, not our synthetic addition.
	_tuner_apply_synthetic_health_regen(delta)
	_tuner_update_prev()

func _tuner_is_paused_state() -> bool:
	# Explicit bool() wraps: game_data.* returns Variant; a chain of `or`
	# over Variants is also Variant, and Godot 4 strict mode refuses to
	# coerce that into the function's declared `bool` return type.
	if game_data == null:
		return true
	return bool(game_data.isTransitioning) or bool(game_data.isCaching) or bool(game_data.isDead)

func _tuner_detect_reset_edge():
	var d: bool = bool(game_data.isDead)
	if d and not tuner_was_dead:
		tuner_bootstrap = true
	tuner_was_dead = d

# Observer core. For each vital, compare current to previous, scale the
# difference, write back. Per-vital CheatMenu guards: if the vanilla pin
# cheat is active for this vital (e.g. cheat_inf_energy pins energy=100
# every _process frame), skip our correction so there's no fight.
func _tuner_apply_correction():
	# Defensive: if the state dicts somehow haven't been initialized
	# (e.g. script reloaded mid-session, partial init failure), don't
	# crash on dict[key] access. _tuner_init_state in _ready should
	# always have run by the time the ticker fires.
	if tuner_drain_mult.is_empty():
		return
	for v in TUNER_VITALS:
		if _tuner_vital_is_pinned_by_cheat(v):
			continue
		var cur: float = float(game_data.get(v))
		var p: float = float(tuner_prev.get(v, cur))
		var diff := cur - p
		if abs(diff) < 0.00001:
			continue
		if abs(diff) > TUNER_JUMP_CUTOFF:
			# Instant event — pass through (food, sleep, damage).
			continue
		var mult: float = tuner_regen_mult[v] if diff > 0.0 else tuner_drain_mult[v]
		if mult == 1.0:
			continue  # short-circuit: no correction needed
		var correction := diff * (mult - 1.0)
		game_data.set(v, clampf(cur + correction, TUNER_VITAL_MIN, TUNER_VITAL_MAX))

# Returns true when the vanilla CheatMenu pin-to-100 cheat is active for
# this vital. The cheat writes 100 every _process frame; leave it alone.
func _tuner_vital_is_pinned_by_cheat(vital: String) -> bool:
	match vital:
		"health":      return cheat_god_mode
		"energy":      return cheat_inf_energy
		"hydration":   return cheat_inf_hydration
		"mental":      return cheat_max_mental
		"temperature": return cheat_no_temp_loss
		"oxygen":      return cheat_inf_oxygen
		"bodyStamina", "armStamina": return cheat_inf_stamina
		"cat":         return cheat_cat_immortal
	return false

func _tuner_enforce_freeze_and_lock():
	for v in TUNER_VITALS:
		if tuner_lock_max[v]:
			game_data.set(v, TUNER_VITAL_MAX)
		elif tuner_freeze[v]:
			# If this freeze was loaded from cfg, capture the current
			# in-game vital value now. Recapture happens once per session
			# per vital so the user's settings don't override a fresh save.
			if _tuner_freeze_needs_recapture.get(v, false):
				tuner_freeze_val[v] = float(game_data.get(v))
				_tuner_freeze_needs_recapture[v] = false
			game_data.set(v, tuner_freeze_val[v])

func _tuner_enforce_immunities():
	# Note: Character.gd runs BEFORE our ticker, so on any frame where a
	# condition flips false→true, its corresponding Health() drain gets
	# applied for that single frame before we clear it here. At 60 Hz
	# this is ≤ 0.017 HP per trigger — negligible and self-healing as
	# subsequent frames see the flag cleared.
	for c in TUNER_CONDITIONS:
		if tuner_immune[c] and bool(game_data.get(c)):
			game_data.set(c, false)

# v10.3.1: synthetic passive regen for Health — the only vital the
# Tuner actively ADDS to instead of scaling existing deltas. Vanilla
# RTV has no passive HP recovery (you heal only from medical items),
# so the Health regen slider used to be a dead control. Now it maps
# to a real HP-per-second regen rate, blocked by active injuries so
# the game's damage model stays meaningful.
func _tuner_apply_synthetic_health_regen(delta: float):
	var mult: float = float(tuner_regen_mult.get("health", 0.0))
	if mult <= 0.0:
		return
	# Don't fight the vanilla God Mode cheat — it pins HP to 100 every
	# _process frame, so our regen would just be wasted writes anyway.
	if cheat_god_mode:
		return
	var cur: float = float(game_data.health)
	if cur >= TUNER_VITAL_MAX:
		return
	# Injuries gate the regen — you can still clear them via items,
	# the Clear All Ailments action, or the condition immunity toggles,
	# which unblocks the regen on the next tick.
	for cond in TUNER_HEALTH_REGEN_BLOCKERS:
		if bool(game_data.get(cond)):
			return
	var rate: float = _tuner_health_regen_rate(mult)
	var add: float = rate * delta
	game_data.health = clampf(cur + add, TUNER_VITAL_MIN, TUNER_VITAL_MAX)


# Piecewise-linear interpolation across TUNER_HEALTH_REGEN_CURVE.
# Returns HP/sec for a given slider value. Clamps to curve endpoints
# outside the defined range.
func _tuner_health_regen_rate(mult: float) -> float:
	if mult <= 0.0:
		return 0.0
	var pts: Array = TUNER_HEALTH_REGEN_CURVE
	var last: Array = pts[pts.size() - 1]
	if mult >= float(last[0]):
		return float(last[1])
	for i in range(pts.size() - 1):
		var a: Array = pts[i]
		var b: Array = pts[i + 1]
		var a_s: float = float(a[0])
		var b_s: float = float(b[0])
		if mult >= a_s and mult <= b_s:
			var t: float = (mult - a_s) / (b_s - a_s)
			return lerp(float(a[1]), float(b[1]), t)
	return 0.0


# ================================================================
#  AUTO-MED  (v10.3.2)
# ================================================================
# Rising-edge detection on the 5 injury flags → top up canonical cure
# item in inventory to AUTO_MED_STOCK_TARGET. Overflow queues for
# ground drop, which waits for a stillness window so items don't plop
# behind a sprinting player.
#
# Called from _tuner_on_physics_tick when cheat_auto_med is on.
# Independent of the Tuner master toggle.

func _auto_med_tick(delta: float):
	# Pause during death / load / scene transition; re-seed on return
	# so a mid-transition injury flag isn't treated as a rising edge.
	if bool(game_data.isDead) or bool(game_data.isCaching) \
			or bool(game_data.isTransitioning):
		_auto_med_bootstrap = true
		# Clear any queued drops tied to the player's previous position —
		# dropping them post-respawn would scatter items at the wrong spot.
		_auto_med_pending_drops.clear()
		_auto_med_stop_timer = 0.0
		return

	_auto_med_resolve_refs_if_needed()

	if _auto_med_bootstrap:
		_auto_med_seed_prev()
		_auto_med_bootstrap = false
		return

	# Rising-edge detection per injury. Read the CURRENT game_data state,
	# compare to last tick's cached state; trigger if false→true.
	for injury in AUTO_MED_INJURIES:
		var cur: bool = bool(game_data.get(injury))
		var prev: bool = bool(_auto_med_prev.get(injury, false))
		if cur and not prev:
			_auto_med_on_injury_triggered(injury)
		_auto_med_prev[injury] = cur

	# Drop queue drains only while the player has been still long enough.
	_auto_med_process_drop_queue(delta)

func _auto_med_seed_prev():
	for injury in AUTO_MED_INJURIES:
		_auto_med_prev[injury] = bool(game_data.get(injury))

# Lazy one-time resolve of item-name → ItemData. The catalog is
# populated by _scan_catalog on first Spawner open; Auto-Med can't
# wait for that, so we defer-trigger the scan ourselves if it hasn't
# run yet. Subsequent ticks return quickly via the _refs_ready flag.
func _auto_med_resolve_refs_if_needed():
	if _auto_med_refs_ready:
		return
	if not catalog_ready:
		if not _auto_med_scan_requested:
			_auto_med_scan_requested = true
			call_deferred("_scan_catalog")
		return
	_auto_med_item_refs.clear()
	for injury in AUTO_MED_INJURY_ITEM_MAP:
		var want_name: String = AUTO_MED_INJURY_ITEM_MAP[injury]
		for item in scene_for_item.keys():
			if str(_safe(item, "name", "")) == want_name:
				_auto_med_item_refs[injury] = item
				break
	_auto_med_refs_ready = true
	var missing: Array = []
	for injury in AUTO_MED_INJURY_ITEM_MAP:
		if not _auto_med_item_refs.has(injury):
			missing.append(AUTO_MED_INJURY_ITEM_MAP[injury])
	if missing.is_empty():
		_log("Auto-Med: resolved %d item refs" % _auto_med_item_refs.size())
	else:
		_log("Auto-Med: failed to resolve: %s" % ", ".join(missing), "warning")

	# Retroactive check: if an injury rising-edge fired WHILE refs weren't
	# resolved yet (first injury on a fresh session before catalog scan
	# finished), the edge was detected but item lookup failed silently.
	# Now that refs are ready, re-check active injuries and trigger for
	# any that are currently active. No double-trigger risk: we only
	# fire for injuries whose prev is already `true` (meaning the edge
	# was consumed without auto-med firing) AND the condition is still
	# active. An injury that's been cleared since then will fire fresh
	# on its next rising edge naturally.
	for injury in AUTO_MED_INJURIES:
		if bool(game_data.get(injury)) and bool(_auto_med_prev.get(injury, false)):
			_auto_med_on_injury_triggered(injury)

# Count how many of a specific ItemData are in the player's inventory
# grid. All medical items are non-stackable so this is slot-count, not
# stack-amount. Equipment slots aren't relevant (you can't wear a
# bandage), so we only walk inventoryGrid.
func _auto_med_count_in_inventory(item_data) -> int:
	var iface = _get_interface()
	if iface == null or not is_instance_valid(iface):
		return 0
	if not "inventoryGrid" in iface:
		return 0
	var grid = iface.inventoryGrid
	if grid == null or not is_instance_valid(grid):
		return 0
	var target_name := str(_safe(item_data, "name", ""))
	if target_name == "":
		return 0
	var count := 0
	for child in grid.get_children():
		if not is_instance_valid(child) or not "slotData" in child:
			continue
		var sd = child.slotData
		if sd == null or sd.itemData == null:
			continue
		if str(_safe(sd.itemData, "name", "")) == target_name:
			count += 1
	return count

# Central injury-triggered handler. Figures out needed top-up amount,
# tries to add to inventory, queues overflow for ground drop.
func _auto_med_on_injury_triggered(injury: String):
	var item = _auto_med_item_refs.get(injury, null)
	if item == null:
		# Catalog not resolved yet or item missing — silent no-op;
		# _auto_med_resolve_refs_if_needed has already scheduled a scan.
		return
	var item_name := str(_safe(item, "name", "?"))
	var current_count := _auto_med_count_in_inventory(item)
	var needed: int = AUTO_MED_STOCK_TARGET - current_count
	if needed <= 0:
		_show_toast("Already stocked: %d × %s" % [AUTO_MED_STOCK_TARGET, item_name])
		return
	# Try to add up to `needed` into the inventory. _add_to_inventory
	# returns false when the grid is full — remaining count goes into
	# the ground-drop queue.
	var added := 0
	for _i in range(needed):
		if _add_to_inventory(item):
			added += 1
		else:
			break
	var remaining := needed - added
	if added > 0:
		_show_toast("Added %s ×%d" % [item_name, added])
	if remaining > 0:
		for _i in range(remaining):
			_auto_med_pending_drops.append(item)
		_auto_med_stop_timer = 0.0  # require a fresh stillness window

# Drain the pending-drop queue after the player has been still for
# AUTO_MED_STOP_THRESHOLD seconds. Reset the timer whenever motion
# is detected — a single step restarts the dwell window.
func _auto_med_process_drop_queue(delta: float):
	if _auto_med_pending_drops.is_empty():
		_auto_med_stop_timer = 0.0
		return
	if bool(game_data.isMoving):
		_auto_med_stop_timer = 0.0
		return
	_auto_med_stop_timer += delta
	if _auto_med_stop_timer < AUTO_MED_STOP_THRESHOLD:
		return
	# Player has held still long enough — drop everything queued.
	var summary := {}  # item_name -> count (for the summary toast)
	for item in _auto_med_pending_drops:
		if _spawn_in_world(item):
			var nm := str(_safe(item, "name", "?"))
			summary[nm] = int(summary.get(nm, 0)) + 1
	_auto_med_pending_drops.clear()
	_auto_med_stop_timer = 0.0
	if not summary.is_empty():
		var parts: Array = []
		for nm in summary:
			parts.append("%s ×%d" % [nm, summary[nm]])
		_show_toast("Dropped near you: %s" % ", ".join(parts))


func _tuner_seed_prev():
	for v in TUNER_VITALS:
		tuner_prev[v] = float(game_data.get(v))

func _tuner_update_prev():
	for v in TUNER_VITALS:
		tuner_prev[v] = float(game_data.get(v))

# True if any tuner state deviates from factory defaults. Gates the HUD
# tag so users with the master toggle on but everything at baseline
# don't see a confusing "TUNER" tag for a no-op configuration.
func _tuner_has_nondefault_state() -> bool:
	for v in TUNER_VITALS:
		if tuner_drain_mult[v] != 1.0: return true
		if tuner_regen_mult[v] != 1.0: return true
		if tuner_freeze[v]: return true
		if tuner_lock_max[v]: return true
	for c in TUNER_CONDITIONS:
		if tuner_immune[c]: return true
	return false

# Lazy + validated Character node lookup. RTV's Character lives at a
# fixed path; cache is invalidated by is_instance_valid after scene
# transitions so we re-resolve automatically.
func _tuner_get_character() -> Node:
	if is_instance_valid(_tuner_cached_character):
		return _tuner_cached_character
	if get_tree() == null or get_tree().current_scene == null:
		return null
	_tuner_cached_character = get_tree().current_scene.get_node_or_null(
			"/root/Map/Core/Controller/Character")
	return _tuner_cached_character

# Sets a condition bool on game_data AND calls Character's corresponding
# cure function (Character.Bleeding(false), Character.Starvation(false),
# etc.) so the indicator sound stops and the UI badge clears.
func _tuner_set_cond(character: Node, cond: String, active: bool):
	game_data.set(cond, active)
	_tuner_call_cure(character, cond, active)

func _tuner_call_cure(character, cond: String, active: bool):
	if character == null: return
	var fn: String = TUNER_CONDITION_CURE_FN.get(cond, "")
	if fn == "": return
	if character.has_method(fn):
		character.call(fn, active)

# Oneshot action: reset every drain/regen multiplier to 1.0. UI sliders
# are synced via set_value_no_signal so no cascade of value_changed
# handlers (each would re-schedule a save). Single save at end.
func _action_tuner_reset_multipliers():
	for v in TUNER_VITALS:
		tuner_drain_mult[v] = 1.0
		tuner_regen_mult[v] = 1.0
		if tuner_drain_sliders.has(v) and is_instance_valid(tuner_drain_sliders[v]):
			tuner_drain_sliders[v].set_value_no_signal(1.0)
			if tuner_drain_labels.has(v) and is_instance_valid(tuner_drain_labels[v]):
				tuner_drain_labels[v].text = "1.0x"
		if tuner_regen_sliders.has(v) and is_instance_valid(tuner_regen_sliders[v]):
			tuner_regen_sliders[v].set_value_no_signal(1.0)
			if tuner_regen_labels.has(v) and is_instance_valid(tuner_regen_labels[v]):
				tuner_regen_labels[v].text = "1.0x"
	_tuner_request_save()
	_show_toast("Tuner sliders reset")

# Refreshes the per-vital live value labels shown in the Tuner tab.
# Called from _process at TUNER_LIVE_REFRESH_SEC cadence while the tab
# is open — avoids per-frame label thrash.
func _tuner_refresh_live_values():
	if game_data == null: return
	for v in TUNER_VITALS:
		if not tuner_live_value_labels.has(v): continue
		var lbl: Label = tuner_live_value_labels[v]
		if not is_instance_valid(lbl): continue
		var val: float = float(game_data.get(v))
		lbl.text = "%d / 100" % int(round(val))
		# Direct font_color override — modulate chains would wash out
		# against the dim base color.
		var col: Color
		if val <= 25.0:      col = COL_NEGATIVE
		elif val <= 50.0:    col = COL_WARNING
		else:                col = COL_POSITIVE
		lbl.add_theme_color_override("font_color", col)



# ================================================================
#  CONTROLLER DISCOVERY
# ================================================================

func _discover_controller():
	# v10.5.1 — prefer the canonical hardcoded path first. The rest of
	# the mod already references /root/Map/Core/Controller directly
	# (e.g. the Character lookup at 1838, Riser lookup at 919/4650), so
	# keying controller discovery off the same path is consistent AND
	# removes the ambiguity where an AI CharacterBody3D with a
	# walkSpeed-like property could accidentally match the search.
	# Walk the canonical path first; fall back to shape-match. Typed
	# as CharacterBody3D throughout — the canonical path IS a
	# CharacterBody3D in this game, and the fallback filter restricts
	# to that class, so the assignment at the bottom is type-safe.
	var node: CharacterBody3D = null
	if get_tree() != null and get_tree().current_scene != null:
		var canonical := get_tree().current_scene.get_node_or_null("/root/Map/Core/Controller")
		if canonical is CharacterBody3D and "walkSpeed" in canonical and "sprintSpeed" in canonical:
			node = canonical
	# Fall back to a shape-match search if the canonical path is
	# missing (future-proofing for scene-path refactors in the game).
	if node == null:
		for candidate in get_tree().root.find_children("*", "CharacterBody3D", true, false):
			if "walkSpeed" in candidate and "sprintSpeed" in candidate:
				node = candidate
				break
	if node == null:
		return
	controller = node
	controller_found = true
	# v10.5.1 — capture baselines EXACTLY ONCE per session via the
	# _baselines_captured sentinel. Without it, re-discovery after a
	# zone transition could re-read `walkSpeed` while a speed cheat is
	# active — poisoning the baseline with a modified value. The new
	# controller spawns with game defaults, but if any mod / hook set
	# walkSpeed before our _process runs, we'd capture the wrong base.
	# Fixed constants here would be even safer but they aren't exposed
	# anywhere we can read from, so session-pinning is the right
	# compromise.
	if not _baselines_captured:
		base_walk_speed = node.walkSpeed
		base_sprint_speed = node.sprintSpeed
		base_crouch_speed = node.crouchSpeed
		base_jump_vel = node.jumpVelocity
		if "fallThreshold" in node:
			base_fall_threshold = node.fallThreshold
		base_headbob = game_data.headbob if "headbob" in game_data else 1.0
		base_fov = game_data.baseFOV if "baseFOV" in game_data else 70.0
		_baselines_captured = true
		_log("Controller found — base values: walk=%.1f sprint=%.1f crouch=%.1f jump=%.1f fall=%.1f" % [base_walk_speed, base_sprint_speed, base_crouch_speed, base_jump_vel, base_fall_threshold])
	else:
		_log("Controller re-discovered (zone transition) — reusing cached baselines")


# ================================================================
#  FREEZE / UNFREEZE
# ================================================================

# Snapshot of the pre-open game state so closing CheatMenu restores
# exactly what was there — not a hardcoded "captured mouse + unfrozen".
# Without this, opening CheatMenu over the Tab inventory and then
# closing CheatMenu leaves the mouse captured even though the inventory
# is still visible, producing the "mouse moves character head while UI
# is showing" bug.
var _saved_mouse_mode: int = Input.MOUSE_MODE_CAPTURED
var _saved_freeze: bool = false
var _mouse_state_captured := false

func _set_game_frozen(frozen: bool):
	if frozen:
		# Snapshot the pre-open state exactly ONCE per open cycle.
		# Subsequent _set_game_frozen(true) calls (e.g. F6 after F5 on
		# same session) must NOT overwrite the snapshot with our own
		# VISIBLE-mode override.
		if not _mouse_state_captured:
			_saved_mouse_mode = Input.get_mouse_mode()
			_saved_freeze = bool(game_data.freeze) if "freeze" in game_data else false
			_mouse_state_captured = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		if "freeze" in game_data:
			game_data.freeze = true
	else:
		# Restore snapshotted state. If the game inventory / settings /
		# trade / craft UI was open before F5, mouse stays VISIBLE and
		# the user can keep interacting with that UI. If we were in
		# pure gameplay, mouse returns to CAPTURED as before.
		if _mouse_state_captured:
			Input.set_mouse_mode(_saved_mouse_mode)
			if "freeze" in game_data:
				game_data.freeze = _saved_freeze
			_mouse_state_captured = false
		else:
			# No snapshot was taken (e.g. called defensively on exit_tree
			# without a matching open). Fall back to gameplay defaults.
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			if "freeze" in game_data:
				game_data.freeze = false

func _close_cheat():
	cheat_open = false
	_hide_all_menus()
	_set_game_frozen(false)

func _close_all_subpanels():
	_close_builder()
	_close_dashboard()
	_close_cabin_browser()
	_close_confirm()
	# v10.4.0 — teleport overlays register with the subpanel cascade so
	# ESC / F5 close / tab-switch all tear them down cleanly.
	_close_name_prompt()
	_close_teleport_picker()

# True if any "sub-sub-panel" is open on top of the sub-menu host panel.
# Used by the ESC cascade to decide whether ESC should close that panel
# first instead of returning to the dashboard. Uses is_instance_valid
# so stale refs (already queue_free'd but not yet null-assigned) don't
# produce false positives.
func _any_subsubpanel_open() -> bool:
	if cabin_browser_panel != null and is_instance_valid(cabin_browser_panel):
		return true
	if builder_panel != null and is_instance_valid(builder_panel):
		return true
	# v10.4.0
	if teleport_picker_panel != null and is_instance_valid(teleport_picker_panel):
		return true
	if name_prompt_panel != null and is_instance_valid(name_prompt_panel):
		return true
	return false

# ── v10.3.0 dashboard / sub-menu navigation ──────────────────────
# The dashboard is the landing page on F5. Sub-menus are the existing
# tab pages, hosted inside cheat_panel with the tab strip hidden.

func _show_dashboard():
	submenu_mode = false
	if cheat_panel != null:
		cheat_panel.visible = false
	if is_instance_valid(submenu_back_button):
		submenu_back_button.visible = false
	if is_instance_valid(cheat_tab_bar):
		cheat_tab_bar.visible = true
	# Tear down any sub-sub-panels that were layered on top of a sub-menu.
	_close_all_subpanels()
	if dashboard_panel != null:
		dashboard_panel.visible = true
		# Force a full refresh when the dashboard comes back into view so
		# every card reflects any state changes that happened inside the
		# sub-menu. Setting rendered signatures to sentinels guarantees
		# the first refresh tick rebuilds every card regardless of whether
		# the data happens to match, which covers the case of initial
		# empty-state renders (an empty signature equal to empty real data
		# would otherwise skip the rebuild and leave the card blank).
		dashboard_weapon_dirty = true
		_dashboard_onyou_rendered = {"__force_rebuild": -1}
		_dashboard_cabins_rendered = {"__force_rebuild": -1}
		_dashboard_intel_signature = ["__force_rebuild"]
		_dashboard_weapon_stats_signature = ["__force_rebuild"]
		_invalidate_cabin_counts_cache()
		_rebuild_dashboard_favorites_row()
		dashboard_refresh_countdown = 0.0
		_refresh_dashboard_live()
		# Restore the sticky inline category content. On first-ever open
		# this loads Player (the default); subsequent opens load whichever
		# category was active last.
		_load_category(dashboard_last_category)

func _hide_all_menus():
	if dashboard_panel != null:
		dashboard_panel.visible = false
	if cheat_panel != null:
		cheat_panel.visible = false
	if is_instance_valid(submenu_back_button):
		submenu_back_button.visible = false
	_close_all_subpanels()
	# Hide the debug log panel too — it lives on the same canvas and
	# would otherwise linger on-screen after the user closes the menu.
	_close_debug_log()
	submenu_mode = false

func _open_submenu(tab_name: String):
	# v10.6: only Spawner and Keys use the floating cheat_panel host.
	# Everything else populates the inline dashboard content area via
	# _load_category() and never touches this path.
	if tab_name != "Spawner" and tab_name != "Keys":
		return
	if not cheat_tab_pages.has(tab_name):
		return
	submenu_mode = true
	if dashboard_panel != null:
		dashboard_panel.visible = false
	# Reuse the existing tab press handler for page visibility + styling + width
	_on_cheat_tab_pressed(tab_name)
	# Hide the tab strip in sub-menu mode — dashboard buttons are the nav now.
	# The BACK button replaces it at the top of the content.
	if is_instance_valid(cheat_tab_bar):
		cheat_tab_bar.visible = false
	if is_instance_valid(submenu_back_button):
		submenu_back_button.visible = true
	if cheat_panel != null:
		cheat_panel.visible = true


# ================================================================
#  ACTIVE CHEATS HUD  (persistent on-screen indicator)
# ================================================================

func _build_hud():
	hud_label = Label.new()
	hud_label.anchor_left = 0.0
	hud_label.anchor_top = 0.0
	hud_label.offset_left = 10
	hud_label.offset_top = 6
	_style_label(hud_label, 13, COL_POSITIVE)
	hud_label.visible = false
	canvas.add_child(hud_label)

func _update_hud():
	# v10.6.0 — Suspend-flag early return. _profile_apply_cheats flips this
	# true while bulk-loading a profile so the ~33 sequential applicator
	# calls don't each rebuild the HUD row (O(n²) string churn). The
	# apply path always calls _update_hud() exactly once at the end after
	# flipping the flag back to false.
	if _profile_suspend_hud:
		return
	var parts := []
	# v10.6.0 — active profile prefix chip so users always know which
	# loadout is driving their live state. Always first in the list.
	var prof_prefix := _profile_hud_prefix()
	if prof_prefix != "":
		parts.append(prof_prefix)
	if cheat_god_mode:      parts.append("GOD")
	if cheat_inf_stamina:   parts.append("STAM")
	if cheat_inf_energy:    parts.append("FOOD")
	if cheat_inf_hydration: parts.append("WATER")
	if cheat_inf_oxygen:    parts.append("O2")
	if cheat_max_mental:    parts.append("MIND")
	if cheat_no_temp_loss:  parts.append("TEMP")
	if cheat_no_overweight: parts.append("NO-WT")
	if cheat_speed_mult != 1.0: parts.append("SPD:%.1fx" % cheat_speed_mult)
	if cheat_jump_mult != 1.0:  parts.append("JMP:%.1fx" % cheat_jump_mult)
	if cheat_real_time:         parts.append("REAL-TIME")
	elif cheat_freeze_time:     parts.append("TIME-STOP")
	elif cheat_time_speed != 1.0: parts.append("TIME:%.0fx" % cheat_time_speed)
	if cheat_no_recoil:     parts.append("NO-RCL")
	if cheat_no_fall_dmg:   parts.append("NO-FALL")
	if cheat_noclip:        parts.append("NOCLIP")
	if cheat_inf_ammo:      parts.append("INF-AMMO")
	if cheat_no_jam:        parts.append("NO-JAM")
	if cheat_inf_armor:     parts.append("ARMOR")
	if cheat_cat_immortal:  parts.append("CAT")
	# v10.3.0 — single tag for the Vitals Tuner. Only shown when master is
	# on AND at least one setting deviates from defaults; a plain master
	# toggle with all sliders at 1.0 has no visible effect so no tag.
	if cheat_tuner_enabled and _tuner_has_nondefault_state():
		parts.append("TUNER")
	# v10.3.2 — Auto-Med visible when on. Players scanning the HUD during
	# combat know their medical stock is being auto-managed.
	if cheat_auto_med:
		parts.append("MED")
	# v10.5.0 — AI awareness cheats. "INV" = sensor hijack is live (AI
	# cannot gain sight on you). "ESP" = projection overlay is drawing
	# over the HUD. Both are read-by-the-ticker toggles and the tag
	# reflects the exact state the ticker is in, not a cached flag.
	if cheat_ai_invisible:
		parts.append("INV")
	if cheat_ai_esp:
		parts.append("ESP")
	if cheat_ai_freeze:
		parts.append("FRZ")

	if parts.size() > 0:
		hud_label.text = "[ " + " | ".join(parts) + " ]"
		hud_label.visible = not cheat_open
	else:
		hud_label.visible = false


# ================================================================
#  TOAST NOTIFICATIONS
# ================================================================

func _build_toast():
	toast_bg = PanelContainer.new()
	toast_bg.anchor_left = 0.3
	toast_bg.anchor_top = 0.9
	toast_bg.anchor_right = 0.7
	toast_bg.anchor_bottom = 0.95
	toast_bg.add_theme_stylebox_override("panel", _make_tile_style(0.7))
	toast_bg.visible = false
	canvas.add_child(toast_bg)

	toast_label = Label.new()
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toast_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_label(toast_label, 14, COL_POSITIVE)
	toast_bg.add_child(toast_label)

func _show_toast(message: String, color: Color = COL_POSITIVE):
	toast_label.text = message
	toast_label.add_theme_color_override("font_color", color)
	toast_bg.visible = true
	toast_timer = 3.0


# ================================================================
#  CHEAT PANEL
# ================================================================

func _build_cheat_panel():
	cheat_panel = PanelContainer.new()
	cheat_panel.add_theme_stylebox_override("panel", _make_tile_style(0.86))
	cheat_panel.anchor_left = 0.01
	cheat_panel.anchor_top = 0.02
	cheat_panel.anchor_right = 0.65
	cheat_panel.anchor_bottom = 0.98

	var main_vbox = VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_theme_constant_override("separation", 4)
	cheat_panel.add_child(main_vbox)

	_add_title(main_vbox, "CHEAT MENU")
	_add_info_label(main_vbox, "v%s  |  F5 Dashboard  |  ESC Back" % VERSION, COL_DIM, 11)

	# ── Back to Dashboard button (only visible in sub-menu host mode) ──
	# v10.6.1: much higher contrast — dark amber fill + brighter border
	# so users can actually see it against the tile background.
	submenu_back_button = _make_styled_button("← BACK TO DASHBOARD", Color(0.32, 0.22, 0.08, 0.92), Color(0.45, 0.32, 0.12, 0.95))
	submenu_back_button.custom_minimum_size = Vector2(0, 34)
	submenu_back_button.add_theme_font_size_override("font_size", 13)
	submenu_back_button.add_theme_color_override("font_color", Color(1, 0.82, 0.4, 1))
	submenu_back_button.add_theme_color_override("font_hover_color", Color(1, 0.92, 0.55, 1))
	submenu_back_button.pressed.connect(_show_dashboard)
	submenu_back_button.visible = false
	main_vbox.add_child(submenu_back_button)

	# ── Tab bar ──
	cheat_tab_bar = HBoxContainer.new()
	cheat_tab_bar.add_theme_constant_override("separation", 2)
	main_vbox.add_child(cheat_tab_bar)

	# v10.6: only Spawner and Keys still live inside the floating
	# cheat_panel. PLAYER / COMBAT / WORLD / INVENTORY / CABIN moved
	# inline to the dashboard content area.
	var tab_names = ["Spawner", "Keys"]
	for tab_name in tab_names:
		var tbtn = _make_styled_button(tab_name, COL_BTN_NORMAL, COL_BTN_HOVER)
		tbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tbtn.custom_minimum_size = Vector2(0, 28)
		tbtn.add_theme_font_size_override("font_size", 11)
		tbtn.add_theme_color_override("font_color", COL_TEXT_DIM)
		tbtn.add_theme_color_override("font_hover_color", COL_TEXT)
		tbtn.pressed.connect(_on_cheat_tab_pressed.bind(tab_name))
		cheat_tab_bar.add_child(tbtn)
		cheat_tab_buttons[tab_name] = tbtn
	_add_separator(main_vbox)

	# ── Tab content area ──
	cheat_tab_container = Control.new()
	cheat_tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cheat_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(cheat_tab_container)

	# Build the two floating-panel pages that survived the v10.6 cleanup.
	_build_tab_spawner()
	_build_tab_keybinds()

	# Close button at bottom (always visible)
	_add_action_button(main_vbox, "CLOSE  [F5]", "_close_cheat", COL_DANGER_BTN)

	canvas.add_child(cheat_panel)

	# Sub-menus default to Spawner (full width) but the panel stays hidden
	# until the user picks something from the dashboard. All pages are
	# hidden by default; _open_submenu shows exactly one.
	for tname in cheat_tab_pages:
		cheat_tab_pages[tname].visible = false
	cheat_active_tab = ""

func _update_panel_width():
	# Spawner needs room for the two-column catalog + weapon dashboard layout.
	# Every other sub-menu is comfortable at 0.65 right anchor.
	if cheat_active_tab == "Spawner":
		cheat_panel.anchor_right = 0.98
	else:
		cheat_panel.anchor_right = 0.65

func _on_cheat_tab_pressed(tab_name: String):
	# v10.6: only Spawner and Keys route through this handler. Other
	# tabs were removed when categories went inline on the dashboard.
	if tab_name != "Spawner" and tab_name != "Keys":
		return
	# Close sub-sub-panels when switching tabs. The cheat_panel tab strip
	# is hidden in v10.3.0 sub-menu mode, so this only fires when we're
	# already inside a sub-menu and the user clicked a tab button directly.
	if cheat_active_tab != tab_name:
		_close_all_subpanels()
	# Hide all pages, show selected
	for tname in cheat_tab_pages:
		cheat_tab_pages[tname].visible = (tname == tab_name)
	# Update button styling
	for tname in cheat_tab_buttons:
		if tname == tab_name:
			cheat_tab_buttons[tname].add_theme_color_override("font_color", COL_TEXT)
			cheat_tab_buttons[tname].add_theme_stylebox_override("normal", _make_button_flat(COL_SPAWN_BTN))
		else:
			cheat_tab_buttons[tname].add_theme_color_override("font_color", COL_TEXT_DIM)
			cheat_tab_buttons[tname].add_theme_stylebox_override("normal", _make_button_flat(COL_BTN_NORMAL))
	cheat_active_tab = tab_name
	# Adjust panel width — Spawner tab uses full width for two-column layout
	_update_panel_width()
	# Spawner tab: scan catalog + open dashboard
	if tab_name == "Spawner":
		if not catalog_ready:
			call_deferred("_scan_catalog")
		call_deferred("_open_weapon_dashboard")

func _make_tab_page(tab_name: String) -> VBoxContainer:
	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cheat_tab_container.add_child(scroll)
	scroll.visible = false
	cheat_tab_pages[tab_name] = scroll

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(vbox)
	return vbox

func _sync_toggle_ui():
	# Guard against stale refs — the content area rebuilds on every
	# category swap, so toggle_refs can briefly contain freed CheckButtons
	# before _prune_stale_refs runs. Skip them here instead of crashing.
	for cheat_name in toggle_refs:
		var btn = toggle_refs[cheat_name]
		if not is_instance_valid(btn):
			continue
		btn.set_pressed_no_signal(get(cheat_name))

# ================================================================
#  DEBUG LOG  (v10.6.24)
# ================================================================
# Single entry point for every diagnostic message the mod emits.
# Calls the matching Godot builtin so godot.log is unchanged, and
# also appends to an in-memory ring buffer that the DEBUG window
# can display live. Valid levels: "info" (default), "warning",
# "error". Unknown levels fall through to print().
func _log(msg: String, level: String = "info"):
	var ts_dict: Dictionary = Time.get_time_dict_from_system()
	var ts: String = "%02d:%02d:%02d" % [
		int(ts_dict.get("hour", 0)),
		int(ts_dict.get("minute", 0)),
		int(ts_dict.get("second", 0)),
	]
	debug_log_buffer.append({"ts": ts, "lvl": level, "msg": msg})
	# Trim the head of the buffer to keep memory bounded. Using slice
	# here instead of pop_front in a loop so a burst of log calls
	# doesn't walk the array repeatedly.
	if debug_log_buffer.size() > DEBUG_LOG_MAX:
		debug_log_buffer = debug_log_buffer.slice(debug_log_buffer.size() - DEBUG_LOG_MAX)
	debug_log_dirty = true
	var line: String = "[CheatMenu] " + msg
	match level:
		"warning":
			push_warning(line)
		"error":
			push_error(line)
		_:
			print(line)

func _ensure_debug_log_panel():
	# Lazy-builds the debug log floating panel on first open. Sits on
	# the same CanvasLayer as the cheat / dashboard panels so it
	# renders on top of the game without fighting with menu z-order.
	if debug_log_panel != null and is_instance_valid(debug_log_panel):
		return
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_tile_style(0.94))
	panel.anchor_left = 0.18
	panel.anchor_top = 0.12
	panel.anchor_right = 0.82
	panel.anchor_bottom = 0.88
	canvas.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "DEBUG LOG"
	_style_label(title, 14, COL_TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	debug_log_status = Label.new()
	debug_log_status.text = "0 entries"
	_style_label(debug_log_status, 10, COL_DIM)
	debug_log_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(debug_log_status)

	_add_separator(vbox)

	# Log body. bbcode is enabled so level-colored tags render inline.
	# scroll_following keeps new lines visible without a manual scroll
	# on each append. selection_enabled lets the player drag-select
	# lines for manual copy when needed.
	debug_log_rich = RichTextLabel.new()
	debug_log_rich.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	debug_log_rich.size_flags_vertical = Control.SIZE_EXPAND_FILL
	debug_log_rich.bbcode_enabled = true
	debug_log_rich.scroll_following = true
	debug_log_rich.selection_enabled = true
	debug_log_rich.add_theme_color_override("default_color", COL_TEXT_DIM)
	if game_font:
		debug_log_rich.add_theme_font_override("normal_font", game_font)
		debug_log_rich.add_theme_font_override("mono_font", game_font)
	debug_log_rich.add_theme_font_size_override("normal_font_size", 11)
	vbox.add_child(debug_log_rich)

	_add_separator(vbox)

	# Action row: Pause / Clear / Copy / Close.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(row)

	debug_log_pause_btn = _make_styled_button("PAUSE", COL_BTN_NORMAL, COL_BTN_HOVER)
	debug_log_pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	debug_log_pause_btn.custom_minimum_size = Vector2(0, 30)
	debug_log_pause_btn.add_theme_font_size_override("font_size", 11)
	debug_log_pause_btn.pressed.connect(_on_debug_log_toggle_pause)
	row.add_child(debug_log_pause_btn)

	var clear_btn := _make_styled_button("CLEAR", COL_BTN_NORMAL, COL_BTN_HOVER)
	clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_btn.custom_minimum_size = Vector2(0, 30)
	clear_btn.add_theme_font_size_override("font_size", 11)
	clear_btn.pressed.connect(_on_debug_log_clear)
	row.add_child(clear_btn)

	var copy_btn := _make_styled_button("COPY", COL_BTN_NORMAL, COL_BTN_HOVER)
	copy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_btn.custom_minimum_size = Vector2(0, 30)
	copy_btn.add_theme_font_size_override("font_size", 11)
	copy_btn.pressed.connect(_on_debug_log_copy)
	row.add_child(copy_btn)

	var close_btn := _make_styled_button("CLOSE", COL_DANGER_BTN, COL_DANGER_HVR)
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.custom_minimum_size = Vector2(0, 30)
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.pressed.connect(_close_debug_log)
	row.add_child(close_btn)

	panel.visible = false
	debug_log_panel = panel

func _open_debug_log():
	_ensure_debug_log_panel()
	if debug_log_panel == null or not is_instance_valid(debug_log_panel):
		return
	debug_log_panel.visible = true
	debug_log_panel.move_to_front()
	debug_log_dirty = true
	debug_log_refresh_countdown = 0.0
	_refresh_debug_log_view()
	_log("Debug log opened (%d entries buffered)" % debug_log_buffer.size())

func _close_debug_log():
	if debug_log_panel != null and is_instance_valid(debug_log_panel):
		debug_log_panel.visible = false

func _is_debug_log_visible() -> bool:
	return debug_log_panel != null and is_instance_valid(debug_log_panel) and debug_log_panel.visible

func _on_debug_log_toggle_pause():
	debug_log_paused = not debug_log_paused
	if debug_log_pause_btn != null and is_instance_valid(debug_log_pause_btn):
		debug_log_pause_btn.text = "RESUME" if debug_log_paused else "PAUSE"
	if not debug_log_paused:
		debug_log_dirty = true
		_refresh_debug_log_view()
	else:
		# Refresh the status line so the (PAUSED) suffix appears immediately.
		if debug_log_status != null and is_instance_valid(debug_log_status):
			debug_log_status.text = "%d entries (PAUSED)" % debug_log_buffer.size()

func _on_debug_log_clear():
	debug_log_buffer.clear()
	debug_log_dirty = true
	if debug_log_rich != null and is_instance_valid(debug_log_rich):
		debug_log_rich.clear()
	if debug_log_status != null and is_instance_valid(debug_log_status):
		var tag := " (PAUSED)" if debug_log_paused else ""
		debug_log_status.text = "0 entries" + tag

func _on_debug_log_copy():
	var lines: Array = []
	for entry in debug_log_buffer:
		lines.append("[%s] [%s] %s" % [
			entry.get("ts", ""),
			entry.get("lvl", "info"),
			entry.get("msg", ""),
		])
	var blob := "\n".join(lines)
	DisplayServer.clipboard_set(blob)
	_show_toast("Copied %d log entries to clipboard" % lines.size())

func _refresh_debug_log_view():
	# Re-render the buffer into the RichTextLabel. Throttled to
	# DEBUG_LOG_REFRESH_INTERVAL by the _process caller so bursts of
	# log messages don't thrash the text layout.
	if not _is_debug_log_visible():
		return
	if debug_log_paused:
		return
	if not debug_log_dirty:
		return
	debug_log_dirty = false
	if debug_log_rich == null or not is_instance_valid(debug_log_rich):
		return
	debug_log_rich.clear()
	for entry in debug_log_buffer:
		var lvl: String = entry.get("lvl", "info")
		var col: String = "b0b0b0"
		if lvl == "warning":
			col = "e0d060"
		elif lvl == "error":
			col = "ff6060"
		var line := "[color=#606060]%s[/color] [color=#%s]%s[/color]\n" % [
			entry.get("ts", ""),
			col,
			entry.get("msg", "").replace("[", "[lb]"),
		]
		debug_log_rich.append_text(line)
	if debug_log_status != null and is_instance_valid(debug_log_status):
		debug_log_status.text = "%d entries" % debug_log_buffer.size()

func _build_tab_spawner():
	# Spawner tab uses a two-column layout: left = item catalog, right = weapon dashboard
	var page = Control.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cheat_tab_container.add_child(page)
	page.visible = false
	cheat_tab_pages["Spawner"] = page

	# ── Two-column split ──
	var h_split = HBoxContainer.new()
	h_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h_split.add_theme_constant_override("separation", 6)
	h_split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_child(h_split)

	# ── LEFT COLUMN: Item Catalog ──
	var catalog_box = VBoxContainer.new()
	catalog_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	catalog_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	catalog_box.size_flags_stretch_ratio = 1.6
	catalog_box.add_theme_constant_override("separation", 4)
	h_split.add_child(catalog_box)

	# Search row
	var search_row = HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 4)
	catalog_box.add_child(search_row)

	search_input = LineEdit.new()
	search_input.placeholder_text = "Search all items..."
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.custom_minimum_size = Vector2(0, 32)
	search_input.focus_mode = Control.FOCUS_CLICK
	if game_font:
		search_input.add_theme_font_override("font", game_font)
	search_input.add_theme_font_size_override("font_size", 14)
	search_input.add_theme_color_override("font_color", COL_TEXT)
	search_input.text_changed.connect(_on_search_changed)
	search_row.add_child(search_input)

	var clear_btn = _make_styled_button("Clear", COL_DANGER_BTN, COL_DANGER_HVR)
	clear_btn.custom_minimum_size = Vector2(60, 32)
	clear_btn.pressed.connect(_on_search_cleared)
	search_row.add_child(clear_btn)
	_add_separator(catalog_box)

	# Category tabs with accent bars
	var cat_grid = GridContainer.new()
	cat_grid.columns = 5
	cat_grid.add_theme_constant_override("h_separation", 3)
	cat_grid.add_theme_constant_override("v_separation", 3)
	catalog_box.add_child(cat_grid)

	for cat_def in CATEGORIES:
		var cat_name: String = cat_def[0]
		var cat_accent: Color = cat_def[1]
		var tab_wrap = VBoxContainer.new()
		tab_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab_wrap.add_theme_constant_override("separation", 0)
		cat_grid.add_child(tab_wrap)

		var btn = _make_styled_button(cat_name, COL_BTN_NORMAL, COL_BTN_HOVER)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 30)
		btn.add_theme_font_size_override("font_size", 12)
		btn.add_theme_color_override("font_color", COL_TEXT_DIM)
		btn.add_theme_color_override("font_hover_color", COL_TEXT)
		btn.pressed.connect(_on_category_pressed.bind(btn, cat_name))
		tab_wrap.add_child(btn)

		var accent_bar = ColorRect.new()
		accent_bar.custom_minimum_size = Vector2(0, 2)
		accent_bar.color = Color(cat_accent.r, cat_accent.g, cat_accent.b, 0.4)
		accent_bar.name = "AccentBar"
		tab_wrap.add_child(accent_bar)

	# Subcategory bar
	subcat_bar = HBoxContainer.new()
	subcat_bar.add_theme_constant_override("separation", 3)
	subcat_bar.visible = false
	catalog_box.add_child(subcat_bar)
	_add_separator(catalog_box)

	# Sort + pagination
	var controls_row = HBoxContainer.new()
	controls_row.add_theme_constant_override("separation", 4)
	catalog_box.add_child(controls_row)

	for sort_def in [["Name", "name"], ["Weight", "weight"], ["Rarity", "rarity"]]:
		var sort_btn = _make_styled_button(sort_def[0], COL_BTN_NORMAL, COL_BTN_HOVER)
		sort_btn.custom_minimum_size = Vector2(60, 26)
		sort_btn.add_theme_font_size_override("font_size", 11)
		sort_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
		sort_btn.add_theme_color_override("font_hover_color", COL_TEXT)
		sort_btn.pressed.connect(_on_sort_pressed.bind(sort_def[1]))
		controls_row.add_child(sort_btn)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls_row.add_child(spacer)

	var prev_btn = _make_styled_button("<", COL_BTN_NORMAL, COL_BTN_HOVER)
	prev_btn.custom_minimum_size = Vector2(36, 26)
	prev_btn.pressed.connect(_on_page_prev)
	controls_row.add_child(prev_btn)

	page_info = Label.new()
	_style_label(page_info, 12, COL_TEXT_DIM)
	controls_row.add_child(page_info)

	var next_btn = _make_styled_button(">", COL_BTN_NORMAL, COL_BTN_HOVER)
	next_btn.custom_minimum_size = Vector2(36, 26)
	next_btn.pressed.connect(_on_page_next)
	controls_row.add_child(next_btn)
	_add_separator(catalog_box)

	# Scrollable item list
	var item_scroll = ScrollContainer.new()
	item_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	item_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	catalog_box.add_child(item_scroll)

	item_container = VBoxContainer.new()
	item_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_container.add_theme_constant_override("separation", 3)
	item_scroll.add_child(item_container)

	_show_message("Select a category or search")

	# ── Vertical separator ──
	var sep = ColorRect.new()
	sep.custom_minimum_size = Vector2(1, 0)
	sep.color = COL_SEPARATOR
	sep.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h_split.add_child(sep)

	# ── RIGHT COLUMN: Weapon Dashboard ──
	var dash_panel = PanelContainer.new()
	dash_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dash_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dash_panel.size_flags_stretch_ratio = 1.0
	dash_panel.add_theme_stylebox_override("panel", _make_tile_style(0.4))
	h_split.add_child(dash_panel)

	var dash_scroll = ScrollContainer.new()
	dash_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dash_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dash_panel.add_child(dash_scroll)

	dashboard_vbox = VBoxContainer.new()
	dashboard_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_vbox.add_theme_constant_override("separation", 3)
	dash_scroll.add_child(dashboard_vbox)



# ================================================================
#  CATALOG SCANNER
# ================================================================

func _scan_catalog():
	_log("Scanning catalog...")
	# Reset catalog state so re-scans don't accumulate stale entries
	# (e.g., a Cash System cash_item_data ref from a previous scan).
	items_by_category.clear()
	scene_for_item.clear()
	var db_script = load("res://Scripts/Database.gd")
	if not db_script:
		_show_message("ERROR: Cannot load Database")
		return

	var constants = db_script.get_script_constant_map()
	var item_count := 0

	for const_name in constants:
		if not constants[const_name] is PackedScene:
			continue
		if "_Rig" in const_name:
			continue
		var scene_path = constants[const_name].resource_path
		if scene_path == null or scene_path == "":
			continue
		if "Assets/" in scene_path:
			continue
		var data_path = scene_path.replace(".tscn", ".tres")
		if not ResourceLoader.exists(data_path):
			continue
		var resource = load(data_path)
		if resource == null:
			continue
		if not "name" in resource:
			continue
		if resource.name == null or str(resource.name) == "":
			continue

		scene_for_item[resource] = constants[const_name]
		var category = _categorize_item(resource, scene_path)
		if category not in items_by_category:
			items_by_category[category] = []
		items_by_category[category].append(resource)
		item_count += 1

	# ── Soft-dependency: inject Cash System's runtime cash item ──
	# Cash is created at runtime by CashMain._init_cash_item() so it's
	# not in the vanilla Database, but it IS a real ItemData resource
	# and renders cleanly in our spawner. We add it to the Misc bucket
	# only if Cash System is installed and its item is initialized.
	var cm = _get_cash_main()
	if cm != null and "cash_item_data" in cm and cm.cash_item_data != null:
		if "Misc" not in items_by_category:
			items_by_category["Misc"] = []
		items_by_category["Misc"].append(cm.cash_item_data)
		item_count += 1
		_log("Cash System detected — added Euro Cash to Misc catalog")

	# ── Soft-dependency: inject Secure Container items ──
	# Secure Container creates 3 ItemData resources at runtime
	# (Field Pouch, Secure Pouch, Secure Case) stored in _item_data
	# dict. They're Equipment type with slots=["Pouch"]. We add them
	# to the Equipment bucket so they show up alongside vanilla gear.
	if _secure_container_available():
		var sc = _get_secure_container()
		if "Equipment" not in items_by_category:
			items_by_category["Equipment"] = []
		var sc_count := 0
		for file_id in sc._item_data:
			var sc_item = sc._item_data[file_id]
			if sc_item != null and is_instance_valid(sc_item):
				items_by_category["Equipment"].append(sc_item)
				item_count += 1
				sc_count += 1
		if sc_count > 0:
			_log("Secure Container detected — added %d items to Equipment catalog" % sc_count)

	catalog_ready = true
	_log("Catalog ready: %d items across %d categories" % [item_count, items_by_category.size()])
	_show_message("Ready — %d items loaded. Pick a category!" % item_count)


func _categorize_item(resource, path: String) -> String:
	# Categorize by item TYPE first (authoritative), then fall back to path
	# This prevents magazines in Items/Weapons/ from showing in the Weapons tab
	var item_type = str(_safe(resource, "type", ""))
	match item_type:
		"Weapon":
			return "Weapons"
		"Ammo":
			return "Ammo"
		"Attachment":
			return "Attachments"
		"Medical":
			return "Medical"
		"Consumable", "Consumables":
			return "Food"
		"Grenade":
			return "Grenades"
		"Knife":
			return "Knives"
		"Key":
			return "Keys"
		"Armor", "Helmet", "Rig", "Backpack", "Clothing", "Belt Pouch":
			return "Equipment"
	# Fall back to path-based categorization for types without a clear match
	var lower = path.to_lower()
	if "weapons/" in lower:
		return "Weapons"
	if "ammo/" in lower:
		return "Ammo"
	if "medical/" in lower:
		return "Medical"
	if "consumable" in lower:
		return "Food"
	if "attachment" in lower:
		return "Attachments"
	if "kniv" in lower or "knife" in lower:
		return "Knives"
	if "grenade" in lower:
		return "Grenades"
	if "keys/" in lower:
		return "Keys"
	if "clothing" in lower or "backpack" in lower or "rigs/" in lower or "helmet" in lower or "belt" in lower or "armor/" in lower:
		return "Equipment"
	return "Misc"


# ================================================================
#  SPAWNER — EVENT HANDLERS
# ================================================================

func _on_search_changed(_text: String):
	current_page = 0
	_refresh_item_list()

func _on_search_cleared():
	search_input.text = ""
	current_page = 0
	_refresh_item_list()

func _on_category_pressed(btn: Button, cat_name: String):
	# Reset previous tab styling
	if active_tab_btn:
		active_tab_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
		# Dim the accent bar on the old tab
		var old_parent = active_tab_btn.get_parent()
		if old_parent and old_parent.get_child_count() > 1:
			var old_bar = old_parent.get_child(1)
			if old_bar is ColorRect:
				old_bar.color.a = 0.4
	active_tab_btn = btn
	btn.add_theme_color_override("font_color", COL_TEXT)
	# Brighten the accent bar on the active tab
	var new_parent = btn.get_parent()
	if new_parent and new_parent.get_child_count() > 1:
		var new_bar = new_parent.get_child(1)
		if new_bar is ColorRect:
			new_bar.color.a = 1.0
	selected_cat = cat_name
	selected_subcat = ""
	current_page = 0
	_build_subcategories(cat_name)
	_refresh_item_list()

func _on_subcategory_pressed(btn: Button, subcat_value: String):
	if active_sub_btn:
		active_sub_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
	active_sub_btn = btn
	btn.add_theme_color_override("font_color", COL_TEXT)
	selected_subcat = subcat_value
	current_page = 0
	_refresh_item_list()

func _on_sort_pressed(field: String):
	if sort_field == field:
		sort_ascending = !sort_ascending
	else:
		sort_field = field
		sort_ascending = true
	current_page = 0
	_refresh_item_list()

func _on_page_prev():
	if current_page > 0:
		current_page -= 1
		_refresh_item_list()

func _on_page_next():
	current_page += 1
	_refresh_item_list()


# ================================================================
#  GENERIC SUBCATEGORY SYSTEM
# ================================================================

func _get_item_subcat(item, category: String) -> String:
	match category:
		"Weapons":
			var wt = str(_safe(item, "weaponType", ""))
			return wt if wt != "" else "Other"
		"Ammo":
			var name_l = str(_safe(item, "name", "")).to_lower()
			if "9x18" in name_l or "9x19" in name_l or "45" in name_l:
				return "Pistol"
			elif "12" in name_l or "shell" in name_l:
				return "Shotgun"
			else:
				return "Rifle"
		"Equipment":
			var slots = _safe(item, "slots", [])
			var item_type = str(_safe(item, "type", ""))
			if _safe(item, "plate", false):
				return "Armor Plate"
			if item_type == "Helmet":
				return "Helmet"
			if "Rig" in item_type or "rig" in str(_safe(item, "name", "")).to_lower():
				return "Rig"
			if slots is Array and slots.size() > 0:
				var slot = str(slots[0])
				if slot == "Head":
					return "Head"
				elif slot == "Torso":
					return "Torso"
				elif slot == "Legs":
					return "Legs"
				elif slot == "Feet":
					return "Feet"
				elif slot == "Hands":
					return "Hands"
				elif slot == "Belt":
					return "Belt"
			var path = str(_safe(item, "resource_path", "")).to_lower()
			if "backpack" in path:
				return "Backpack"
			if "belt" in path:
				return "Belt"
			return "Other"
		"Attachments":
			var sub = str(_safe(item, "subtype", ""))
			return sub if sub != "" else "Other"
		"Food":
			var name_l = str(_safe(item, "name", "")).to_lower()
			var path = str(_safe(item, "resource_path", "")).to_lower()
			if "juice" in name_l or "soda" in name_l or "water" in name_l or "beer" in name_l or "coffee" in name_l or "kompot" in name_l or "kilju" in name_l or "energy_drink" in name_l:
				return "Drinks"
			elif "cooked" in name_l or "cooked" in path:
				return "Cooked"
			elif "canned" in name_l or "canned" in path:
				return "Canned"
			else:
				return "Other"
		"Medical":
			if _safe(item, "bleeding", false):
				return "Bleeding"
			if _safe(item, "fracture", false):
				return "Fracture"
			if _safe(item, "burn", false):
				return "Burn"
			var hp = _safe(item, "health", 0.0)
			if hp > 0:
				return "Healing"
			return "Other"
		_:
			return ""


func _build_subcategories(category: String):
	for child in subcat_bar.get_children():
		child.queue_free()
	active_sub_btn = null

	if category not in items_by_category:
		subcat_bar.visible = false
		return

	# Collect unique subcategories
	var subcats := {}
	for item in items_by_category[category]:
		var sc = _get_item_subcat(item, category)
		if sc != "":
			subcats[sc] = true

	# Only show if there are 2+ subcategories
	if subcats.size() < 2:
		subcat_bar.visible = false
		return

	subcat_bar.visible = true

	# "All" button
	var all_btn = _make_styled_button("All", COL_BTN_NORMAL, COL_BTN_HOVER)
	all_btn.custom_minimum_size = Vector2(55, 28)
	all_btn.add_theme_font_size_override("font_size", 11)
	all_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
	all_btn.add_theme_color_override("font_hover_color", COL_TEXT)
	all_btn.pressed.connect(_on_subcategory_pressed.bind(all_btn, ""))
	subcat_bar.add_child(all_btn)

	# Subcategory buttons
	for sc_name in subcats:
		var sc_btn = _make_styled_button(sc_name, COL_BTN_NORMAL, COL_BTN_HOVER)
		sc_btn.custom_minimum_size = Vector2(55, 28)
		sc_btn.add_theme_font_size_override("font_size", 11)
		sc_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
		sc_btn.add_theme_color_override("font_hover_color", COL_TEXT)
		sc_btn.pressed.connect(_on_subcategory_pressed.bind(sc_btn, sc_name))
		subcat_bar.add_child(sc_btn)


# ================================================================
#  ITEM LIST RENDERER
# ================================================================

func _show_message(text: String):
	for child in item_container.get_children():
		child.queue_free()
	var label = Label.new()
	_style_label(label, 14, COL_TEXT_DIM)
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	item_container.add_child(label)


func _refresh_item_list():
	for child in item_container.get_children():
		child.queue_free()

	var query = search_input.text.strip_edges().to_lower()

	# When searching with 2+ characters, search across ALL categories
	if query.length() >= 2:
		var items := []
		for cat in items_by_category:
			for it in items_by_category[cat]:
				var item_name = str(_safe(it, "name", "")).to_lower()
				if query in item_name:
					items.append(it)
		# Sort, paginate, and display — skip category/subcat filters
		items.sort_custom(_compare_items)
		var total = items.size()
		var max_page = max(0, (total - 1) / PAGE_SIZE)
		current_page = clamp(current_page, 0, max_page)
		var start_idx = current_page * PAGE_SIZE
		var end_idx = min(start_idx + PAGE_SIZE, total)
		if page_info:
			page_info.text = "  %d/%d  (%d)  " % [current_page + 1, max_page + 1, total]
		if total == 0:
			_show_message("No items found for \"%s\"" % search_input.text.strip_edges())
			return
		for i in range(start_idx, end_idx):
			_build_item_card(items[i])
		return

	if selected_cat == "" or selected_cat not in items_by_category:
		_show_message("Select a category")
		return

	var items = items_by_category[selected_cat].duplicate()

	# Subcategory filter
	if selected_subcat != "":
		var filtered := []
		for it in items:
			var sc = _get_item_subcat(it, selected_cat)
			if sc == selected_subcat:
				filtered.append(it)
		items = filtered

	# Sort
	items.sort_custom(_compare_items)

	# Pagination
	var total = items.size()
	var max_page = max(0, (total - 1) / PAGE_SIZE)
	current_page = clamp(current_page, 0, max_page)
	var start_idx = current_page * PAGE_SIZE
	var end_idx = min(start_idx + PAGE_SIZE, total)

	if page_info:
		page_info.text = "  %d/%d  (%d)  " % [current_page + 1, max_page + 1, total]

	if total == 0:
		_show_message("No items found")
		return

	for i in range(start_idx, end_idx):
		_build_item_card(items[i])


# ================================================================
#  ITEM CARD BUILDER
# ================================================================

func _build_item_card(item):
	if item == null:
		return

	var card = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _make_tile_style(0.5))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)

	# ── Icon ──
	var icon_tex = _safe(item, "icon", null)
	if icon_tex != null and icon_tex is Texture2D:
		var icon_rect = TextureRect.new()
		icon_rect.texture = icon_tex
		icon_rect.custom_minimum_size = ICON_SIZE
		icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon_rect)
	else:
		var placeholder = ColorRect.new()
		placeholder.custom_minimum_size = ICON_SIZE
		placeholder.color = Color(1, 1, 1, 0.047)
		row.add_child(placeholder)

	# ── Info column ──
	var info_col = VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.add_theme_constant_override("separation", 2)
	row.add_child(info_col)

	# Name
	var item_name = str(_safe(item, "name", "Unknown"))
	_add_info_label(info_col, item_name, COL_TEXT, 16)

	# Type | Weight
	var type_parts := []
	var item_type = str(_safe(item, "type", ""))
	var item_subtype = str(_safe(item, "subtype", ""))
	if item_type != "":
		type_parts.append(item_type)
	if item_subtype != "":
		type_parts.append(item_subtype)
	var item_weight = _safe(item, "weight", 0.0)
	type_parts.append("%.1f kg" % item_weight)
	_add_info_label(info_col, " | ".join(type_parts), COL_TEXT_DIM, 12)

	# Rarity — game uses Common=Green, Rare=Red, Legendary=DarkViolet
	var rarity = _safe(item, "rarity", 0)
	if rarity == 1:
		_add_info_label(info_col, "Rare", COL_RARE, 12)
	elif rarity == 2:
		_add_info_label(info_col, "Legendary", COL_LEGEND, 12)

	# Weapon stats
	if "weaponType" in item and "damage" in item:
		var stats_parts := []
		var dmg = _safe(item, "damage", 0.0)
		var pen = _safe(item, "penetration", 0)
		var fire_rate = _safe(item, "fireRate", 0.0)
		var mag_size = _safe(item, "magazineSize", 0)
		var caliber = str(_safe(item, "caliber", ""))
		if dmg > 0:
			stats_parts.append("DMG:%d" % dmg)
		if pen > 0:
			stats_parts.append("PEN:%d" % pen)
		if fire_rate > 0:
			stats_parts.append("RPM:%.0f" % (60.0 / fire_rate))
		if mag_size > 0:
			stats_parts.append("MAG:%d" % mag_size)
		if caliber != "":
			stats_parts.append(caliber)
		if stats_parts.size() > 0:
			_add_info_label(info_col, " | ".join(stats_parts), COL_TEXT_DIM, 11)
		var weapon_type = str(_safe(item, "weaponType", ""))
		if weapon_type != "":
			_add_info_label(info_col, weapon_type, COL_TEXT_DIM, 11)

	# Vital effects
	var vital_parts := []
	if _safe(item, "health", 0.0) != 0:
		vital_parts.append("HP:%+.0f" % item.health)
	if _safe(item, "energy", 0.0) != 0:
		vital_parts.append("Eng:%+.0f" % item.energy)
	if _safe(item, "hydration", 0.0) != 0:
		vital_parts.append("Hyd:%+.0f" % item.hydration)
	if _safe(item, "mental", 0.0) != 0:
		vital_parts.append("Mnt:%+.0f" % item.mental)
	if _safe(item, "temperature", 0.0) != 0:
		vital_parts.append("Tmp:%+.0f" % item.temperature)
	if vital_parts.size() > 0:
		_add_info_label(info_col, " | ".join(vital_parts), COL_POSITIVE, 11)

	# Medical treatments
	var med_parts := []
	if _safe(item, "bleeding", false):
		med_parts.append("Bleeding")
	if _safe(item, "fracture", false):
		med_parts.append("Fracture")
	if _safe(item, "burn", false):
		med_parts.append("Burn")
	if _safe(item, "rupture", false):
		med_parts.append("Rupture")
	if _safe(item, "headshot", false):
		med_parts.append("Headshot")
	if med_parts.size() > 0:
		_add_info_label(info_col, "Treats: " + ", ".join(med_parts), COL_NEGATIVE, 11)

	# Armor
	var protection = _safe(item, "protection", 0)
	if protection > 0:
		var armor_text = "Protection: Level %d" % protection
		var rating = str(_safe(item, "rating", ""))
		if rating != "":
			armor_text += " (%s)" % rating
		_add_info_label(info_col, armor_text, COL_TEXT_DIM, 11)

	# Equipment slots
	var slots = _safe(item, "slots", [])
	if slots is Array and slots.size() > 0:
		_add_info_label(info_col, "Equip: " + ", ".join(slots), COL_POSITIVE, 11)

	# ── Spawn buttons ──
	# Vertically center the button column in each row so buttons don't
	# "drift" up or down based on how much metadata (stats, rarity,
	# description) the info column next to them contains. Previously rows
	# with Rare badges or stat lines pushed this column taller than rows
	# without, so the SPAWN button landed at different Y positions per
	# row — jarring when scrolling the list.
	# Width bumped to 136px to fit the [−][qty][+] stepper that now sits
	# above each non-weapon row's SPAWN chip (weapons keep the old 100px
	# since their button column has its own 4 variant buttons instead).
	var btn_col = VBoxContainer.new()
	btn_col.add_theme_constant_override("separation", 4)
	btn_col.custom_minimum_size = Vector2(136, 0)
	btn_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(btn_col)

	var is_weapon = "weaponType" in item and "damage" in item
	# Soft-dep: detect Cash System's runtime cash item by its unique file id.
	# If matched, replace the normal spawn column with a 2-column grid of
	# amount quick-buttons so the card stays compact vertically.
	var is_cash = str(_safe(item, "file", "")) == "Cash" and _cash_system_available()
	if is_cash:
		btn_col.custom_minimum_size = Vector2(170, 0)
		var cash_grid = GridContainer.new()
		cash_grid.columns = 2
		cash_grid.add_theme_constant_override("h_separation", 2)
		cash_grid.add_theme_constant_override("v_separation", 2)
		cash_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn_col.add_child(cash_grid)
		for amt in CASH_AMOUNTS:
			var cash_btn = _make_spawn_button("+ €%s" % _format_cash_amount(amt), COL_SPAWN_BTN, COL_SPAWN_HVR)
			cash_btn.custom_minimum_size = Vector2(82, 24)
			cash_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cash_btn.pressed.connect(_cash_add.bind(amt))
			cash_grid.add_child(cash_btn)
	elif is_weapon:
		var bare_btn = _make_spawn_button("BARE", COL_BTN_NORMAL, COL_BTN_HOVER)
		bare_btn.pressed.connect(_spawn_weapon_bare.bind(item))
		btn_col.add_child(bare_btn)

		var combat_btn = _make_spawn_button("+MAG+AMMO", COL_SPAWN_BTN, COL_SPAWN_HVR)
		combat_btn.pressed.connect(_spawn_weapon_combat.bind(item))
		btn_col.add_child(combat_btn)

		var full_btn = _make_spawn_button("FULL KIT", COL_SPAWN_BTN, COL_SPAWN_HVR)
		full_btn.pressed.connect(_spawn_weapon_full.bind(item))
		btn_col.add_child(full_btn)

		var custom_btn = _make_spawn_button("CUSTOMIZE", Color(0.35, 0.3, 0.15, 0.5), Color(0.45, 0.4, 0.2, 0.6))
		custom_btn.pressed.connect(_open_weapon_builder.bind(item))
		btn_col.add_child(custom_btn)
	else:
		# Non-weapon items: quantity stepper above the SPAWN chip lets
		# the user batch-spawn. Stackable items (ammo, food) will have
		# their quantity auto-merged into existing stacks by the game's
		# AutoStack; non-stackables (keys, armor plates, backpacks) each
		# get their own slot. See _spawn_quantity for behavior details.
		var qty_ctrl := _make_qty_control(item)
		btn_col.add_child(qty_ctrl)

		var spawn_btn = _make_spawn_button("SPAWN", COL_SPAWN_BTN, COL_SPAWN_HVR)
		spawn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spawn_btn.pressed.connect(func(): _spawn_quantity(item, _get_spawn_qty(item)))
		btn_col.add_child(spawn_btn)

	item_container.add_child(card)


# ================================================================
#  SPAWNING ENGINE — builds weapons with attachments pre-attached
# ================================================================

var builder_panel: PanelContainer
var builder_weapon = null
var builder_checkboxes := {}

# ── Weapon Dashboard (embedded in Spawner tab right column) ─────
var dashboard_vbox: VBoxContainer = null
var dashboard_open := false
var dashboard_refresh_timer := 0.0
var dash_ammo_label: Label = null
var dash_chamber_label: Label = null
var dash_condition_label: Label = null

func _get_interface():
	if get_tree() == null or get_tree().current_scene == null:
		return null
	return get_tree().current_scene.get_node_or_null("/root/Map/Core/UI/Interface")


func _get_compatible_items(weapon) -> Array:
	var result := []
	if weapon == null:
		return result
	if not "compatible" in weapon:
		return result
	var compat = weapon.compatible
	if not compat is Array:
		return result
	for item in compat:
		if item == null:
			continue
		if not is_instance_valid(item):
			continue
		if not "name" in item:
			continue
		if item.name == null or str(item.name) == "":
			continue
		result.append(item)
	return result


func _build_weapon_slot(weapon_data, attachments: Array, mag_data, ammo_count: int) -> SlotData:
	var slot = SlotData.new()
	slot.itemData = weapon_data
	slot.condition = 100
	slot.amount = 0
	slot.chamber = false

	# Add attachments to nested
	for att in attachments:
		if att == null:
			continue
		var subtype = str(_safe(att, "subtype", ""))
		var already_has := false
		for existing in slot.nested:
			if str(_safe(existing, "subtype", "")) == subtype and subtype != "":
				already_has = true
				break
		if not already_has:
			slot.nested.append(att)

	# Add magazine to nested and set ammo count
	if mag_data != null:
		slot.nested.append(mag_data)
		slot.amount = ammo_count
		slot.chamber = true

	return slot


func _add_to_inventory(item_data) -> bool:
	if item_data == null:
		return false
	if spawn_cooldown > 0.0:
		return false

	var interface = _get_interface()
	if interface == null:
		_log("Interface not found — dropping in world", "warning")
		return _spawn_in_world(item_data)

	var new_slot = SlotData.new()
	new_slot.itemData = item_data
	new_slot.condition = 100

	var default_amount = _safe(item_data, "defaultAmount", 0)
	var show_amount = _safe(item_data, "showAmount", false)
	if show_amount and default_amount > 0:
		new_slot.amount = default_amount

	if interface.AutoStack(new_slot, interface.inventoryGrid):
		interface.UpdateStats(false)
		return true

	if interface.Create(new_slot, interface.inventoryGrid, false):
		interface.UpdateStats(false)
		return true

	_show_toast("Inventory full! Dropped on ground.", COL_NEGATIVE)
	return _spawn_in_world(item_data)


func _add_built_weapon_to_inventory(slot_data: SlotData) -> bool:
	var interface = _get_interface()
	if interface == null:
		_log("Interface not found", "warning")
		return false

	if interface.Create(slot_data, interface.inventoryGrid, false):
		interface.UpdateStats(false)
		return true

	_show_toast("Inventory full!", COL_NEGATIVE)
	return false


func _spawn_in_world(item_data) -> bool:
	if item_data == null:
		return false
	var scene: PackedScene = null
	if item_data in scene_for_item:
		scene = scene_for_item[item_data]
	else:
		var target_name = str(_safe(item_data, "name", ""))
		for cached in scene_for_item:
			if str(_safe(cached, "name", "")) == target_name:
				scene = scene_for_item[cached]
				break
	if scene == null:
		return false
	var instance = scene.instantiate()
	if get_tree() == null or get_tree().current_scene == null:
		instance.queue_free()
		return false
	get_tree().current_scene.add_child(instance)
	if not is_instance_valid(instance):
		return false
	if instance is Node3D:
		var origin := Vector3.ZERO
		if "playerPosition" in game_data:
			origin = game_data.playerPosition
		instance.global_position = origin + Vector3(randf_range(-0.6, 0.6), 0.5, randf_range(-0.6, 0.6))
	return true


func _spawn_single(item):
	if _add_to_inventory(item):
		_show_toast("Added: " + str(_safe(item, "name", "?")))
		spawn_cooldown = 0.3

# Bulk variant of _spawn_single. Loops over _add_to_inventory N times so
# the game's AutoStack logic can merge stackable items into existing
# stacks (ammo, food) while non-stackables each get their own slot
# (backpacks, armor plates, keys). Bails cleanly when the inventory
# fills — the toast reports how many actually landed so the user knows
# a partial batch happened.
func _spawn_quantity(item, qty: int):
	if item == null:
		return
	var n: int = clampi(qty, SPAWN_QTY_MIN, SPAWN_QTY_MAX)
	# Bypass the per-call cooldown for the whole batch; we'll restore a
	# single cooldown at the end so rapid back-to-back "spawn 50" clicks
	# can't stampede the inventory resizer. _add_to_inventory only sets
	# cooldown via _spawn_single/_spawn_weapon_*, so zeroing it once is
	# sufficient for the loop.
	spawn_cooldown = 0.0
	var added := 0
	for i in range(n):
		if not _add_to_inventory(item):
			break
		added += 1
	var name_str := str(_safe(item, "name", "?"))
	if added == 0:
		_show_toast("Inventory full — nothing added", COL_NEGATIVE)
	elif added < n:
		_show_toast("Added %d of %d %s (inventory full)" % [added, n, name_str], COL_NEGATIVE)
	else:
		_show_toast("Added %s ×%d" % [name_str, added])
	# Scale cooldown with batch size so huge batches enforce a longer
	# breather before the next click. Capped at 1.0s.
	spawn_cooldown = clampf(0.3 + 0.02 * added, 0.3, 1.0)

# Reads the user's chosen spawn quantity for this item, defaulting to 1
# on first access. Clamped to valid range so hand-edited dict values
# can't poison the stepper.
func _get_spawn_qty(item) -> int:
	var v: int = int(_spawn_qty_by_item.get(item, SPAWN_QTY_MIN))
	return clampi(v, SPAWN_QTY_MIN, SPAWN_QTY_MAX)

# Builds the [−][qty][+] stepper HBox for a single catalog row. The
# label is captured by the button callbacks so the two step buttons
# and the label stay in sync without needing an external ref dict.
func _make_qty_control(item) -> Control:
	# v10.6.1 — Qty is now a click-to-edit LineEdit. Users can type any
	# int up to SPAWN_QTY_MAX (999,999) for bulk ammo / cash max-stack.
	# The +/- buttons still work for small tweaks and update the
	# LineEdit's text in sync. Width auto-grows with digit count and
	# shrinks back when the user clears big numbers.
	var box := HBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)

	var minus := _make_qty_step_button("−")
	box.add_child(minus)

	var qty_edit := LineEdit.new()
	qty_edit.text = str(_get_spawn_qty(item))
	qty_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	qty_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qty_edit.custom_minimum_size = Vector2(_qty_edit_width_for(qty_edit.text), 28)
	qty_edit.max_length = 7                         # matches SPAWN_QTY_MAX digit count
	qty_edit.caret_blink = true
	qty_edit.select_all_on_focus = true
	qty_edit.focus_mode = Control.FOCUS_CLICK
	qty_edit.tooltip_text = "Click to edit quantity. Enter or click away to commit. Range 1–%d." % SPAWN_QTY_MAX
	# v10.6.2 — inline the theme overrides instead of calling
	# _style_label() because that helper is typed `Label` and Godot's
	# parser rejects a LineEdit at that call site. LineEdit shares the
	# same add_theme_* API as Label (both inherit from Control), so
	# the effect is identical — just compile-time type-safe now.
	if game_font:
		qty_edit.add_theme_font_override("font", game_font)
	qty_edit.add_theme_font_size_override("font_size", 13)
	qty_edit.add_theme_color_override("font_color", COL_TEXT)
	if game_font_bold:
		qty_edit.add_theme_font_override("font", game_font_bold)
	# Visual affordance that this is editable — subtle 1 px border
	# using the game's separator color, slightly rounded.
	var edit_style := StyleBoxFlat.new()
	edit_style.bg_color = Color(0.08, 0.08, 0.10, 0.85)
	edit_style.border_color = COL_SEPARATOR
	edit_style.border_width_left = 1
	edit_style.border_width_right = 1
	edit_style.border_width_top = 1
	edit_style.border_width_bottom = 1
	edit_style.set_corner_radius_all(3)
	edit_style.set_content_margin_all(4)
	qty_edit.add_theme_stylebox_override("normal", edit_style)
	var edit_focus_style := edit_style.duplicate()
	edit_focus_style.border_color = COL_POSITIVE
	qty_edit.add_theme_stylebox_override("focus", edit_focus_style)
	box.add_child(qty_edit)

	var plus := _make_qty_step_button("+")
	box.add_child(plus)

	# Text-changed: reject non-digits in place AND resize width so the
	# box grows/shrinks with content. Doesn't commit to the spawn-qty
	# dict yet (that happens on Enter / focus-out).
	qty_edit.text_changed.connect(func(new_text: String):
		var digits := _qty_digits_only(new_text)
		if digits != new_text:
			var caret := qty_edit.caret_column
			qty_edit.text = digits
			qty_edit.caret_column = min(caret, digits.length())
		qty_edit.custom_minimum_size.x = _qty_edit_width_for(qty_edit.text)
	)
	qty_edit.text_submitted.connect(func(_t: String):
		_commit_spawn_qty_from_edit(item, qty_edit)
		qty_edit.release_focus()
	)
	qty_edit.focus_exited.connect(func():
		_commit_spawn_qty_from_edit(item, qty_edit)
	)

	minus.pressed.connect(func():
		var cur := _get_spawn_qty(item)
		var new_val: int = clampi(cur - 1, SPAWN_QTY_MIN, SPAWN_QTY_MAX)
		_spawn_qty_by_item[item] = new_val
		if is_instance_valid(qty_edit):
			qty_edit.text = str(new_val)
			qty_edit.custom_minimum_size.x = _qty_edit_width_for(qty_edit.text)
	)
	plus.pressed.connect(func():
		var cur := _get_spawn_qty(item)
		var new_val: int = clampi(cur + 1, SPAWN_QTY_MIN, SPAWN_QTY_MAX)
		_spawn_qty_by_item[item] = new_val
		if is_instance_valid(qty_edit):
			qty_edit.text = str(new_val)
			qty_edit.custom_minimum_size.x = _qty_edit_width_for(qty_edit.text)
	)
	return box

# Strips any non-digit characters from a qty-edit input. Called from the
# text_changed signal so the LineEdit silently rejects letters / symbols
# while preserving the user's cursor position as best we can.
func _qty_digits_only(s: String) -> String:
	var out := ""
	for ch in s:
		if ch >= "0" and ch <= "9":
			out += ch
	return out

# Commits a LineEdit's current text to the per-item spawn-qty dict,
# clamping to [SPAWN_QTY_MIN, SPAWN_QTY_MAX] and rewriting the box's
# text so out-of-range input is visibly corrected (e.g. user types "0"
# → box snaps to "1"). No-ops when the edit was freed between signal
# dispatch and handler.
func _commit_spawn_qty_from_edit(item, edit: LineEdit) -> void:
	if edit == null or not is_instance_valid(edit):
		return
	var raw := edit.text.strip_edges()
	var n := SPAWN_QTY_MIN if raw == "" else int(raw)
	var clamped: int = clampi(n, SPAWN_QTY_MIN, SPAWN_QTY_MAX)
	_spawn_qty_by_item[item] = clamped
	var repainted := str(clamped)
	if edit.text != repainted:
		edit.text = repainted
	edit.custom_minimum_size.x = _qty_edit_width_for(edit.text)

# Pixel-width estimator for auto-sizing the qty edit box. Rough but
# stable — 10 px per digit plus 16 px padding for the caret + border,
# floored at 36 px so the box never looks cramped on single digits.
func _qty_edit_width_for(text: String) -> float:
	return max(36.0, float(text.length()) * 10.0 + 16.0)

# Small square step button for the qty control. Uses the same modern
# styling as the main spawn button but at reduced size + neutral color
# so the SPAWN chip stays the visual anchor of the row.
func _make_qty_step_button(glyph: String) -> Button:
	var btn := Button.new()
	btn.text = glyph
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(28, 28)
	btn.add_theme_stylebox_override("normal",  _make_button_modern(COL_BTN_NORMAL, "normal", false))
	btn.add_theme_stylebox_override("hover",   _make_button_modern(COL_BTN_HOVER,  "hover",  false))
	btn.add_theme_stylebox_override("pressed", _make_button_modern(COL_BTN_PRESS,  "pressed", false))
	btn.add_theme_stylebox_override("focus",   _make_button_modern(Color(0, 0, 0, 0), "normal", false))
	if game_font_bold:
		btn.add_theme_font_override("font", game_font_bold)
	elif game_font:
		btn.add_theme_font_override("font", game_font)
	btn.add_theme_font_size_override("font_size", 16)
	btn.add_theme_color_override("font_color", COL_TEXT)
	btn.add_theme_color_override("font_hover_color", COL_POSITIVE)
	return btn


func _spawn_weapon_bare(item):
	var slot = _build_weapon_slot(item, [], null, 0)
	if _add_built_weapon_to_inventory(slot):
		_show_toast("Added: " + str(_safe(item, "name", "?")) + " (bare)")
		spawn_cooldown = 0.3


func _spawn_weapon_combat(item):
	var parts := []
	var weapon_name = str(_safe(item, "name", "?"))
	var compatible = _get_compatible_items(item)

	var mag_data = null
	for compat in compatible:
		var subtype = str(_safe(compat, "subtype", ""))
		if subtype == "Magazine" or "drum" in str(_safe(compat, "name", "")).to_lower():
			mag_data = compat
			break

	var ammo_count = 0
	if mag_data != null:
		ammo_count = _safe(mag_data, "maxAmount", _safe(mag_data, "defaultAmount", 0))
		parts.append("Magazine (loaded)")

	var slot = _build_weapon_slot(item, [], mag_data, ammo_count)
	if _add_built_weapon_to_inventory(slot):
		parts.insert(0, weapon_name)

	var ammo = _safe(item, "ammo", null)
	if ammo != null:
		_add_to_inventory(ammo)
		_add_to_inventory(ammo)
		parts.append("Ammo x2")

	_show_toast("Added: " + " + ".join(parts))
	spawn_cooldown = 0.5


func _spawn_weapon_full(item):
	var parts := []
	var weapon_name = str(_safe(item, "name", "?"))
	var compatible = _get_compatible_items(item)

	var mag_data = null
	var attachments := []
	for compat in compatible:
		var subtype = str(_safe(compat, "subtype", ""))
		var item_type = str(_safe(compat, "type", ""))
		if subtype == "Magazine" or "drum" in str(_safe(compat, "name", "")).to_lower():
			if mag_data == null:
				mag_data = compat
		elif item_type == "Ammo":
			pass
		else:
			attachments.append(compat)

	var ammo_count = 0
	if mag_data != null:
		ammo_count = _safe(mag_data, "maxAmount", _safe(mag_data, "defaultAmount", 0))
		parts.append("Magazine (loaded)")

	var slot = _build_weapon_slot(item, attachments, mag_data, ammo_count)
	if _add_built_weapon_to_inventory(slot):
		parts.insert(0, weapon_name)

	if attachments.size() > 0:
		parts.append("%d attachments" % attachments.size())

	var ammo = _safe(item, "ammo", null)
	if ammo != null:
		_add_to_inventory(ammo)
		_add_to_inventory(ammo)
		_add_to_inventory(ammo)
		parts.append("Ammo x3")

	_show_toast("Added: " + " + ".join(parts))
	spawn_cooldown = 1.0


# ================================================================
#  WEAPON BUILDER / CUSTOMIZER
# ================================================================

func _open_weapon_builder(weapon):
	_close_dashboard()  # Close dashboard to avoid overlap
	builder_weapon = weapon
	builder_checkboxes.clear()

	if builder_panel != null:
		builder_panel.queue_free()

	builder_panel = PanelContainer.new()
	builder_panel.add_theme_stylebox_override("panel", _make_tile_style(0.86))
	builder_panel.anchor_left = 0.67
	builder_panel.anchor_top = 0.05
	builder_panel.anchor_right = 0.98
	builder_panel.anchor_bottom = 0.95
	canvas.add_child(builder_panel)

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	builder_panel.add_child(scroll)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(vbox)

	# Title
	_add_title(vbox, "WEAPON BUILDER")
	_add_separator(vbox)

	# Weapon info
	var weapon_name = str(_safe(weapon, "name", "?"))
	_add_info_label(vbox, weapon_name, COL_TEXT, 16)

	# Weapon icon
	var icon_tex = _safe(weapon, "icon", null)
	if icon_tex != null and icon_tex is Texture2D:
		var icon_rect = TextureRect.new()
		icon_rect.texture = icon_tex
		icon_rect.custom_minimum_size = Vector2(120, 80)
		icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		vbox.add_child(icon_rect)

	# Stats
	var dmg = _safe(weapon, "damage", 0.0)
	var cal = str(_safe(weapon, "caliber", ""))
	var mag_sz = _safe(weapon, "magazineSize", 0)
	_add_info_label(vbox, "DMG: %d  |  CAL: %s  |  MAG: %d" % [dmg, cal, mag_sz], COL_TEXT_DIM, 12)
	_add_separator(vbox)

	# Compatible attachments
	var compatible = _get_compatible_items(weapon)
	if compatible.size() == 0:
		_add_info_label(vbox, "No compatible attachments found", COL_TEXT_DIM, 12)
	else:
		_add_section_header(vbox, "SELECT ATTACHMENTS")
		_add_separator(vbox)

		# Group by subtype
		var groups := {}
		for compat in compatible:
			var subtype = str(_safe(compat, "subtype", ""))
			var item_type = str(_safe(compat, "type", ""))
			var group_name = subtype if subtype != "" else item_type
			if group_name == "":
				group_name = "Other"
			if group_name not in groups:
				groups[group_name] = []
			groups[group_name].append(compat)

		for group_name in groups:
			_add_info_label(vbox, group_name + " (pick one)", COL_TEXT_DIM, 13)

			var group_checks := []

			# "None" option for non-required groups
			if group_name != "Ammo":
				var none_check = CheckButton.new()
				none_check.text = "None"
				none_check.focus_mode = Control.FOCUS_NONE
				_style_button_font(none_check, 12, COL_TEXT_DIM)
				vbox.add_child(none_check)
				group_checks.append(none_check)

			for compat in groups[group_name]:
				var att_name = str(_safe(compat, "name", "?"))
				var check = CheckButton.new()
				check.text = att_name
				check.focus_mode = Control.FOCUS_NONE
				_style_button_font(check, 12, COL_TEXT)
				vbox.add_child(check)
				builder_checkboxes[compat] = check
				group_checks.append(check)

			# Set default selection
			if group_name == "Magazine" and group_checks.size() > 1:
				group_checks[1].button_pressed = true
			elif group_name == "Ammo" and group_checks.size() > 0:
				group_checks[0].button_pressed = true
			elif group_checks.size() > 0:
				group_checks[0].button_pressed = true

			# Connect radio behavior
			for check in group_checks:
				check.toggled.connect(_on_builder_radio.bind(check, group_checks))

			_add_separator(vbox)

	# Build button
	var build_btn = _make_styled_button("BUILD & ADD TO INVENTORY", COL_SPAWN_BTN, COL_SPAWN_HVR)
	build_btn.custom_minimum_size = Vector2(0, 40)
	build_btn.add_theme_font_size_override("font_size", 14)
	build_btn.add_theme_color_override("font_color", COL_POSITIVE)
	build_btn.add_theme_color_override("font_hover_color", COL_TEXT)
	build_btn.pressed.connect(_on_build_weapon)
	vbox.add_child(build_btn)

	_add_separator(vbox)

	# Close button
	var close_btn = _make_styled_button("CANCEL", COL_DANGER_BTN, COL_DANGER_HVR)
	close_btn.custom_minimum_size = Vector2(0, 34)
	close_btn.pressed.connect(_close_builder)
	vbox.add_child(close_btn)


func _on_build_weapon():
	if builder_weapon == null:
		return

	var attachments := []
	var mag_data = null
	var include_ammo := false

	for item_data in builder_checkboxes:
		var checkbox: CheckButton = builder_checkboxes[item_data]
		if not checkbox.button_pressed:
			continue

		var subtype = str(_safe(item_data, "subtype", ""))
		var item_type = str(_safe(item_data, "type", ""))

		if subtype == "Magazine" or "drum" in str(_safe(item_data, "name", "")).to_lower():
			mag_data = item_data
		elif item_type == "Ammo":
			include_ammo = true
		else:
			attachments.append(item_data)

	var ammo_count = 0
	if mag_data != null:
		ammo_count = _safe(mag_data, "maxAmount", _safe(mag_data, "defaultAmount", 0))

	var slot = _build_weapon_slot(builder_weapon, attachments, mag_data, ammo_count)
	if _add_built_weapon_to_inventory(slot):
		var weapon_name = str(_safe(builder_weapon, "name", "?"))
		var att_count = attachments.size()
		var msg = "Built: " + weapon_name
		if att_count > 0:
			msg += " + %d attachments" % att_count
		if mag_data != null:
			msg += " + mag (loaded)"
		_show_toast(msg)

		if include_ammo:
			var ammo = _safe(builder_weapon, "ammo", null)
			if ammo != null:
				_add_to_inventory(ammo)
				_add_to_inventory(ammo)

	spawn_cooldown = 0.5
	_close_builder()


func _close_builder():
	if builder_panel != null:
		builder_panel.queue_free()
		builder_panel = null
	builder_weapon = null
	builder_checkboxes.clear()

func _on_builder_radio(toggled_on: bool, source: CheckButton, group: Array):
	if toggled_on:
		for check in group:
			if check != source and check.button_pressed:
				check.set_pressed_no_signal(false)


# ================================================================
#  WEAPON DASHBOARD — live view of equipped weapon
# ================================================================

func _get_slot_data_for(slot_name: String):
	var rig_mgr = _get_rig_manager()
	if rig_mgr == null or not is_instance_valid(rig_mgr):
		return null
	var slot_ref = null
	if slot_name == "primary" and "primarySlot" in rig_mgr:
		slot_ref = rig_mgr.primarySlot
	elif slot_name == "secondary" and "secondarySlot" in rig_mgr:
		slot_ref = rig_mgr.secondarySlot
	if slot_ref == null or not is_instance_valid(slot_ref):
		return null
	if slot_ref.get_child_count() == 0:
		return null
	var child = slot_ref.get_child(0)
	if not is_instance_valid(child) or not "slotData" in child:
		return null
	var sd = child.slotData
	if sd != null and sd.itemData != null and "weaponType" in sd.itemData:
		return sd
	return null

var dashboard_active_slot := "primary"

# v10.4.1 — Return the slot name the player currently has DRAWN, as
# indicated by the game's own gameData.primary / gameData.secondary
# booleans (set by RigManager on draw/holster). Returns "" when no
# weapon is drawn (fists / empty). Mirrors the pattern already used by
# _apply_infinite_ammo (see line 4668) so the dashboard behaves
# consistently with other "act on the held weapon" cheats.
func _get_active_weapon_slot() -> String:
	if game_data == null:
		return ""
	if "primary" in game_data and game_data.primary:
		return "primary"
	if "secondary" in game_data and game_data.secondary:
		return "secondary"
	return ""

func _open_weapon_dashboard():
	if dashboard_vbox == null:
		return
	# v10.3.0: the weapon dashboard lives inside the Spawner submenu. If the
	# user fires this from the main dashboard (or any other submenu), jump
	# into the Spawner submenu first so the content is actually visible.
	if not submenu_mode or cheat_active_tab != "Spawner":
		if cheat_open:
			_open_submenu("Spawner")
		# Fall through — _open_submenu calls _on_cheat_tab_pressed which
		# call_deferreds _open_weapon_dashboard. We'll be re-entered shortly.
		return
	if dashboard_open:
		_refresh_dashboard_content()
		return

	_close_builder()  # Close builder to avoid overlap
	dashboard_open = true
	dashboard_refresh_timer = 0.0

	# v10.4.1 — Default to the weapon the player currently has DRAWN so the
	# dashboard shows what they're actually wielding (reported by _davodal_:
	# secondary was invisible on open even when it was the held weapon).
	# Fall back to whichever slot has a weapon if nothing is drawn (fists).
	var held := _get_active_weapon_slot()
	if held != "" and _get_slot_data_for(held) != null:
		dashboard_active_slot = held
	elif _get_slot_data_for("primary") != null:
		dashboard_active_slot = "primary"
	elif _get_slot_data_for("secondary") != null:
		dashboard_active_slot = "secondary"

	_refresh_dashboard_content()

func _close_dashboard():
	dashboard_open = false
	if dashboard_vbox != null:
		for child in dashboard_vbox.get_children():
			child.queue_free()
	dash_ammo_label = null
	dash_chamber_label = null
	dash_condition_label = null

func _update_dashboard_live_stats():
	# Only update text on existing labels — never rebuild the panel
	var slot_data = _get_slot_data_for(dashboard_active_slot)
	if slot_data == null or slot_data.itemData == null:
		return
	if dash_ammo_label != null and is_instance_valid(dash_ammo_label):
		var mag_size = _safe(slot_data.itemData, "magazineSize", 0)
		var current_ammo = _safe(slot_data, "amount", 0)
		dash_ammo_label.text = "%d / %d" % [current_ammo, mag_size]
		var ammo_color = COL_POSITIVE if current_ammo > 0 else COL_NEGATIVE
		dash_ammo_label.add_theme_color_override("font_color", ammo_color)
	if dash_chamber_label != null and is_instance_valid(dash_chamber_label):
		var chambered = _safe(slot_data, "chamber", false)
		var fm = _safe(slot_data, "mode", 1)
		dash_chamber_label.text = "Chamber: " + ("Yes" if chambered else "No") + " | Mode: " + ("Auto" if fm == 2 else "Semi")
	if dash_condition_label != null and is_instance_valid(dash_condition_label):
		var condition = _safe(slot_data, "condition", 100)
		dash_condition_label.text = "Condition: %d%%" % condition
		var cc = COL_POSITIVE if condition > 50 else (Color(1, 1, 0, 1) if condition > 25 else COL_NEGATIVE)
		dash_condition_label.add_theme_color_override("font_color", cc)

func _refresh_dashboard_content():
	if dashboard_vbox == null:
		return
	for child in dashboard_vbox.get_children():
		child.queue_free()

	# ── Header ──
	_add_title(dashboard_vbox, "WEAPON DASHBOARD")

	# ── Slot selector (Primary / Secondary tabs) ──
	var pri_data = _get_slot_data_for("primary")
	var sec_data = _get_slot_data_for("secondary")
	if pri_data != null or sec_data != null:
		var slot_row = HBoxContainer.new()
		slot_row.add_theme_constant_override("separation", 3)
		dashboard_vbox.add_child(slot_row)
		if pri_data != null:
			var pri_name = str(_safe(pri_data.itemData, "name", "Primary"))
			var pri_active = dashboard_active_slot == "primary"
			var pri_btn = _make_styled_button(pri_name, COL_SPAWN_BTN if pri_active else COL_BTN_NORMAL, COL_BTN_HOVER)
			pri_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pri_btn.custom_minimum_size = Vector2(0, 28)
			pri_btn.add_theme_font_size_override("font_size", 11)
			pri_btn.add_theme_color_override("font_color", COL_TEXT if pri_active else COL_TEXT_DIM)
			pri_btn.pressed.connect(_dashboard_switch_slot.bind("primary"))
			slot_row.add_child(pri_btn)
		if sec_data != null:
			var sec_name = str(_safe(sec_data.itemData, "name", "Secondary"))
			var sec_active = dashboard_active_slot == "secondary"
			var sec_btn = _make_styled_button(sec_name, COL_SPAWN_BTN if sec_active else COL_BTN_NORMAL, COL_BTN_HOVER)
			sec_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sec_btn.custom_minimum_size = Vector2(0, 28)
			sec_btn.add_theme_font_size_override("font_size", 11)
			sec_btn.add_theme_color_override("font_color", COL_TEXT if sec_active else COL_TEXT_DIM)
			sec_btn.pressed.connect(_dashboard_switch_slot.bind("secondary"))
			slot_row.add_child(sec_btn)

	_add_separator(dashboard_vbox)

	var slot_data = _get_slot_data_for(dashboard_active_slot)
	if slot_data == null:
		# Try the other slot
		dashboard_active_slot = "secondary" if dashboard_active_slot == "primary" else "primary"
		slot_data = _get_slot_data_for(dashboard_active_slot)
	if slot_data == null or slot_data.itemData == null:
		_add_info_label(dashboard_vbox, "No weapon equipped", COL_TEXT_DIM, 14)
		_add_info_label(dashboard_vbox, "Equip a weapon in your inventory", COL_TEXT_DIM, 12)
		return

	var weapon_data = slot_data.itemData

	# ── Weapon icon (large, centered) ──
	var icon_tex = _safe(weapon_data, "icon", null)
	if icon_tex != null and icon_tex is Texture2D:
		var icon_bg = PanelContainer.new()
		icon_bg.add_theme_stylebox_override("panel", _make_tile_style(0.4))
		dashboard_vbox.add_child(icon_bg)
		var icon_center = CenterContainer.new()
		icon_bg.add_child(icon_center)
		var icon_rect = TextureRect.new()
		icon_rect.texture = icon_tex
		icon_rect.custom_minimum_size = Vector2(200, 120)
		icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_center.add_child(icon_rect)

	# ── Weapon name + type ──
	var weapon_name = str(_safe(weapon_data, "name", "Unknown"))
	var weapon_type = str(_safe(weapon_data, "weaponType", ""))
	_add_info_label(dashboard_vbox, weapon_name, COL_TEXT, 18)
	if weapon_type != "":
		_add_info_label(dashboard_vbox, weapon_type, COL_TEXT_DIM, 12)

	# ── Stats bar ──
	var stats := []
	var dmg = _safe(weapon_data, "damage", 0.0)
	var cal = str(_safe(weapon_data, "caliber", ""))
	var pen = _safe(weapon_data, "penetration", 0)
	var fr = _safe(weapon_data, "fireRate", 0.0)
	if dmg > 0: stats.append("DMG %d" % dmg)
	if pen > 0: stats.append("PEN %d" % pen)
	if fr > 0: stats.append("RPM %.0f" % (60.0 / fr))
	if cal != "": stats.append(cal)
	if stats.size() > 0:
		_add_info_label(dashboard_vbox, " | ".join(stats), COL_TEXT_DIM, 11)
	_add_separator(dashboard_vbox)

	# ── Ammo & Status ──
	var mag_size = _safe(weapon_data, "magazineSize", 0)
	var current_ammo = _safe(slot_data, "amount", 0)
	var chambered = _safe(slot_data, "chamber", false)
	var condition = _safe(slot_data, "condition", 100)

	# Ammo row with fill button
	var ammo_row = HBoxContainer.new()
	ammo_row.add_theme_constant_override("separation", 6)
	dashboard_vbox.add_child(ammo_row)

	var ammo_color = COL_POSITIVE if current_ammo > 0 else COL_NEGATIVE
	dash_ammo_label = Label.new()
	_style_label(dash_ammo_label, 16, ammo_color)
	dash_ammo_label.text = "%d / %d" % [current_ammo, mag_size]
	dash_ammo_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ammo_row.add_child(dash_ammo_label)

	var fill_btn = _make_styled_button("FILL MAG", COL_SPAWN_BTN, COL_SPAWN_HVR)
	fill_btn.custom_minimum_size = Vector2(76, 26)
	fill_btn.add_theme_font_size_override("font_size", 10)
	fill_btn.pressed.connect(_dashboard_fill_mag)
	ammo_row.add_child(fill_btn)

	# Status row (chamber + mode — updated live)
	dash_chamber_label = Label.new()
	_style_label(dash_chamber_label, 11, COL_TEXT_DIM)
	dash_chamber_label.text = "Chamber: " + ("Yes" if chambered else "No") + " | Mode: " + ("Auto" if _safe(slot_data, "mode", 1) == 2 else "Semi")
	dashboard_vbox.add_child(dash_chamber_label)

	# Condition bar (updated live)
	var cond_color = COL_POSITIVE if condition > 50 else (Color(1, 1, 0, 1) if condition > 25 else COL_NEGATIVE)
	var cond_row = HBoxContainer.new()
	cond_row.add_theme_constant_override("separation", 6)
	dashboard_vbox.add_child(cond_row)
	dash_condition_label = Label.new()
	_style_label(dash_condition_label, 11, cond_color)
	dash_condition_label.text = "Condition: %d%%" % condition
	dash_condition_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cond_row.add_child(dash_condition_label)
	var repair_btn = _make_styled_button("REPAIR", COL_SPAWN_BTN, COL_SPAWN_HVR)
	repair_btn.custom_minimum_size = Vector2(64, 24)
	repair_btn.add_theme_font_size_override("font_size", 10)
	repair_btn.pressed.connect(_dashboard_repair)
	cond_row.add_child(repair_btn)
	_add_separator(dashboard_vbox)

	# ── Equipped Attachments ──
	_add_section_header(dashboard_vbox, "ATTACHMENTS")
	var nested = _safe(slot_data, "nested", [])
	if nested is Array and nested.size() > 0:
		for att in nested:
			if att == null:
				continue
			var att_name = str(_safe(att, "name", "?"))
			var att_sub = str(_safe(att, "subtype", ""))
			var att_row = HBoxContainer.new()
			att_row.add_theme_constant_override("separation", 4)
			dashboard_vbox.add_child(att_row)

			# Attachment icon if available
			var att_icon = _safe(att, "icon", null)
			if att_icon != null and att_icon is Texture2D:
				var att_ir = TextureRect.new()
				att_ir.texture = att_icon
				att_ir.custom_minimum_size = Vector2(24, 24)
				att_ir.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
				att_ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				att_row.add_child(att_ir)

			var att_label = Label.new()
			_style_label(att_label, 11, COL_TEXT)
			att_label.text = att_name
			if att_sub != "":
				att_label.text = att_sub + ": " + att_name
			att_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			att_row.add_child(att_label)

			var rem_btn = _make_styled_button("X", COL_DANGER_BTN, COL_DANGER_HVR)
			rem_btn.custom_minimum_size = Vector2(28, 24)
			rem_btn.add_theme_font_size_override("font_size", 10)
			rem_btn.pressed.connect(_dashboard_remove_attachment.bind(att))
			att_row.add_child(rem_btn)
	else:
		_add_info_label(dashboard_vbox, "None equipped", COL_TEXT_DIM, 11)
	_add_separator(dashboard_vbox)

	# ── Compatible Items — hot-swap ──
	_add_section_header(dashboard_vbox, "AVAILABLE ATTACHMENTS")
	var compatible = _get_compatible_items(weapon_data)
	# Group by subtype, skip Ammo
	var groups := {}
	for compat in compatible:
		var subtype = str(_safe(compat, "subtype", ""))
		var c_type = str(_safe(compat, "type", ""))
		var gk = subtype if subtype != "" else c_type
		if gk == "" or gk == "Ammo":
			continue
		if gk not in groups:
			groups[gk] = []
		groups[gk].append(compat)

	if groups.size() == 0:
		_add_info_label(dashboard_vbox, "No compatible attachments", COL_TEXT_DIM, 11)
	else:
		# Build map of currently equipped subtypes
		var equipped_map := {}
		if nested is Array:
			for att in nested:
				if att != null:
					var sub = str(_safe(att, "subtype", ""))
					if sub != "":
						equipped_map[sub] = att

		for group_name in groups:
			_add_info_label(dashboard_vbox, group_name, COL_TEXT_DIM, 11)
			for compat in groups[group_name]:
				var c_name = str(_safe(compat, "name", "?"))
				var c_sub = str(_safe(compat, "subtype", ""))
				var is_on = c_sub in equipped_map and equipped_map[c_sub] == compat

				var c_row = HBoxContainer.new()
				c_row.add_theme_constant_override("separation", 4)
				dashboard_vbox.add_child(c_row)

				# Small icon
				var c_icon = _safe(compat, "icon", null)
				if c_icon != null and c_icon is Texture2D:
					var cir = TextureRect.new()
					cir.texture = c_icon
					cir.custom_minimum_size = Vector2(20, 20)
					cir.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
					cir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					c_row.add_child(cir)

				var c_label = Label.new()
				_style_label(c_label, 11, COL_POSITIVE if is_on else COL_TEXT_DIM)
				c_label.text = c_name
				c_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				c_row.add_child(c_label)

				if is_on:
					var off_btn = _make_styled_button("REMOVE", COL_DANGER_BTN, COL_DANGER_HVR)
					off_btn.custom_minimum_size = Vector2(64, 22)
					off_btn.add_theme_font_size_override("font_size", 9)
					off_btn.pressed.connect(_dashboard_remove_attachment.bind(compat))
					c_row.add_child(off_btn)
				else:
					var on_btn = _make_styled_button("ATTACH", COL_SPAWN_BTN, COL_SPAWN_HVR)
					on_btn.custom_minimum_size = Vector2(64, 22)
					on_btn.add_theme_font_size_override("font_size", 9)
					on_btn.pressed.connect(_dashboard_attach.bind(compat))
					c_row.add_child(on_btn)



func _dashboard_switch_slot(slot_name: String):
	dashboard_active_slot = slot_name
	_refresh_dashboard_content()

func _dashboard_fill_mag():
	var slot_data = _get_slot_data_for(dashboard_active_slot)
	if slot_data == null:
		slot_data = _get_active_slot_data()
	if slot_data == null or slot_data.itemData == null:
		_show_toast("No weapon found", COL_NEGATIVE)
		return
	if "magazineSize" in slot_data.itemData:
		slot_data.amount = slot_data.itemData.magazineSize
		slot_data.chamber = true
		# Release slide lock on the active weapon rig
		var rig = _get_active_weapon_rig()
		if rig != null and "slideLocked" in rig:
			rig.slideLocked = false
		_show_toast("Magazine filled: %d rounds" % slot_data.amount)
		_refresh_dashboard_content()

func _dashboard_repair():
	var slot_data = _get_slot_data_for(dashboard_active_slot)
	if slot_data == null:
		slot_data = _get_active_slot_data()
	if slot_data == null:
		return
	slot_data.condition = 100
	_show_toast("Weapon repaired to 100%")
	_refresh_dashboard_content()

func _dashboard_remove_attachment(attachment):
	var slot_data = _get_slot_data_for(dashboard_active_slot)
	if slot_data == null:
		slot_data = _get_active_slot_data()
	if slot_data == null:
		return
	if slot_data.nested is Array and attachment in slot_data.nested:
		slot_data.nested.erase(attachment)
		var rig_mgr = _get_rig_manager()
		if rig_mgr != null and "UpdateRig" in rig_mgr:
			rig_mgr.UpdateRig(false)
		_show_toast("Removed: " + str(_safe(attachment, "name", "?")))
		_refresh_dashboard_content()

func _dashboard_attach(attachment):
	var slot_data = _get_slot_data_for(dashboard_active_slot)
	if slot_data == null:
		slot_data = _get_active_slot_data()
	if slot_data == null:
		return
	var subtype = str(_safe(attachment, "subtype", ""))
	# Remove existing of same subtype
	if subtype != "" and slot_data.nested is Array:
		var to_remove = null
		for existing in slot_data.nested:
			if str(_safe(existing, "subtype", "")) == subtype:
				to_remove = existing
				break
		if to_remove != null:
			slot_data.nested.erase(to_remove)
	if slot_data.nested is Array:
		slot_data.nested.append(attachment)
	var rig_mgr = _get_rig_manager()
	if rig_mgr != null and "UpdateRig" in rig_mgr:
		rig_mgr.UpdateRig(false)
	_show_toast("Attached: " + str(_safe(attachment, "name", "?")))
	_refresh_dashboard_content()


# ================================================================
#  CHEAT ACTIONS
# ================================================================

func _action_toggle_fly():
	game_data.isFlying = !game_data.isFlying
	_show_toast("Fly Mode: " + ("ON" if game_data.isFlying else "OFF"))

# v10.3.0 — augmented with Character.gd cure calls so indicator sounds
# stop and UI badges clear when an action fires. Calling the cure fn
# when the flag was already false is a cheap no-op; safe to call
# unconditionally via _tuner_set_cond for the flags we care about.

func _action_heal():
	var character := _tuner_get_character()
	game_data.health = 100.0
	game_data.isDead = false
	# Clear the combat ailments that have Character.gd cleanup hooks.
	for c in ["bleeding", "fracture", "burn", "rupture", "headshot"]:
		if bool(game_data.get(c)):
			_tuner_set_cond(character, c, false)
	if game_data.isBurning:
		game_data.isBurning = false
	_show_toast("Healed to full")

func _action_clear_ailments():
	var character := _tuner_get_character()
	for c in TUNER_CONDITIONS:
		if bool(game_data.get(c)):
			_tuner_set_cond(character, c, false)
	_show_toast("All ailments cleared")

func _action_refill_vitals():
	var character := _tuner_get_character()
	for v in TUNER_VITALS:
		game_data.set(v, TUNER_VITAL_MAX)
	for c in TUNER_CONDITIONS:
		if bool(game_data.get(c)):
			_tuner_set_cond(character, c, false)
	# Reseed observer so it doesn't see the jump-to-100 as a drain event
	# on the next physics tick.
	tuner_bootstrap = true
	_show_toast("All vitals refilled")


# ================================================================
#  TIME & WORLD ACTIONS
# ================================================================

func _get_tod_name(t: float) -> String:
	if t >= 500 and t < 700:
		return "Dawn"
	elif t >= 700 and t < 1600:
		return "Day"
	elif t >= 1600 and t < 1900:
		return "Dusk"
	else:
		return "Night"

# ── Time write safety (defense-in-depth, v10.3.2) ────────────────
# The game's Simulation._process treats `time >= 2400.0` as a day
# rollover: `time = 0; day += 1; Loader.UpdateProgression()`.
# If any mod code writes exactly 2400 to sim_ref.time, every write
# fires a fresh rollover — and if writes happen many times per
# second (e.g. slider jitter), the day counter spins out of control.
# A user originally reported this as "50 days a second."
#
# This constant is the ceiling we allow ourselves to write. 2399.9
# reads as 23:59 in the HHMM display, is safely below the game's
# >= 2400 threshold, and never triggers a rollover regardless of
# how rapidly it is written.
const SAFE_TIME_MAX := 2399.9
const SIM_ROLLOVER_THRESHOLD := 2400.0

# Centralized safe setter for sim_ref.time. Every write to the
# game's time state goes through here. Guards:
#   1. Null/invalid sim_ref check.
#   2. Hard clamp to [0.0, SAFE_TIME_MAX] so no write can ever
#      trigger a rollover. A caller trying to set 2400 or higher
#      gets 2399.9 instead.
#   3. Rate limit on writes that would push time backwards (rolling
#      forward is always allowed since sim advances naturally).
#      Specifically: if two writes within 16ms both target values
#      >= 2300 (i.e. near the rollover zone), only the first sticks
#      and subsequent writes are dropped. This kills the jitter-loop
#      failure mode at the source regardless of caller.
#   4. If clamping or rate-limiting happens, log it with the source
#      name so future bugs are diagnosable from the debug panel.
var _last_sim_time_write_ms: int = 0
var _last_sim_time_write_val: float = -1.0
const SIM_TIME_WRITE_MIN_INTERVAL_MS := 16
const SIM_TIME_ROLLOVER_ZONE := 2300.0

# Manual day advance gating (slider-driven, v10.3.3).
#
# Two independent mechanisms, either of which is sufficient to
# block runaway day advances:
#
# 1. Drag-session lock (`_slider_advanced_this_drag`). Flipped on
#    when the slider triggers a day advance; cleared only when the
#    HSlider emits drag_ended (user releases the mouse button).
#    This guarantees "one drag = at most one day" regardless of
#    how many value_changed events fire inside a single drag.
#    This is the primary gate.
# 2. Time-based cooldown (`_last_manual_day_advance_ms`). A 500ms
#    minimum interval between day advances. This handles paths
#    that don't go through drag_ended — keyboard input, code-driven
#    slider changes, rapid click-release-click on the track, etc.
#    It's a backstop in case the drag-lock ever has a gap.
var _slider_advanced_this_drag: bool = false
var _last_manual_day_advance_ms: int = -1000000
const MANUAL_DAY_ADVANCE_COOLDOWN_MS := 500

func _safe_set_sim_time(val: float, source: String) -> bool:
	if sim_ref == null or not is_instance_valid(sim_ref) or not ("time" in sim_ref):
		return false
	var clamped: float = clamp(val, 0.0, SAFE_TIME_MAX)
	if clamped != val:
		_log("time write clamped from %.2f to %.2f (source=%s)" % [val, clamped, source], "warning")
	# Rate limit on rapid writes near the rollover zone.
	var now_ms: int = Time.get_ticks_msec()
	if clamped >= SIM_TIME_ROLLOVER_ZONE \
			and _last_sim_time_write_val >= SIM_TIME_ROLLOVER_ZONE \
			and (now_ms - _last_sim_time_write_ms) < SIM_TIME_WRITE_MIN_INTERVAL_MS:
		# Drop this write — the previous one is still fresh and
		# consecutive writes near the rollover line would only
		# risk retriggering the game's day increment unnecessarily.
		return false
	_last_sim_time_write_ms = now_ms
	_last_sim_time_write_val = clamped
	sim_ref.time = clamped
	return true

# Single-source-of-truth clock formatter. Converts a raw sim.time
# value (0..2400 HHMM-decimal encoding) to a "HH:MM" string that
# matches what the vanilla game shows on its own HUD — including
# the Interface.gd:3173 rollup that turns minutes >= 60 into the
# next hour at :00. All display sites (World tab readout, dashboard
# strip, time-slider toast, preset-button toast) call this so they
# can't diverge. Pass `real_time_mode = true` when the source value
# was written by Real Time sync (which uses 0-59 minutes directly)
# to skip the 5-minute snap and show exact minutes.
func _format_sim_clock(t: float, real_time_mode: bool = false) -> String:
	var hours: int = int(t / 100.0) % 24
	var minutes_raw: float = fmod(t, 100.0)
	var minutes: int
	if real_time_mode:
		minutes = int(minutes_raw)
	else:
		minutes = int(floor(minutes_raw / 5.0) * 5)
	if minutes >= 60:
		minutes = 0
		hours = (hours + 1) % 24
	return "%02d:%02d" % [hours, minutes]

# Watchdog: observe sim_ref.day every frame. If it advances more
# than WATCHDOG_MAX_DAYS_PER_SEC times inside a rolling 1-second
# window, we assume a rollover runaway has somehow slipped through
# every other guard and we forcibly disable every cheat that could
# touch time. Also logs a loud warning so the user can report it.
func _watchdog_check_day_rollovers():
	if sim_ref == null or not is_instance_valid(sim_ref) or not ("day" in sim_ref):
		return
	# Skip the watchdog entirely when the player is in a shelter.
	# The cabin's sleep system legitimately fast-forwards time by
	# multiple hours (and sometimes across midnight) when the player
	# uses a bed, which shows up as a burst of day-advances. That is
	# intended gameplay, not a runaway bug, so we don't want the
	# watchdog disabling time cheats or spamming a red toast.
	# Baseline still gets captured so the watchdog resumes correctly
	# once the player leaves the shelter.
	if bool(_safe(game_data, "shelter", false)):
		_watchdog_last_day = int(sim_ref.day)
		_watchdog_last_check_ms = Time.get_ticks_msec()
		_watchdog_days_seen = 0
		return
	var cur_day: int = int(sim_ref.day)
	var now_ms: int = Time.get_ticks_msec()
	# First-ever observation — just capture baseline.
	if _watchdog_last_day < 0:
		_watchdog_last_day = cur_day
		_watchdog_last_check_ms = now_ms
		return
	# Reset the rolling window every WATCHDOG_WINDOW_MS.
	if now_ms - _watchdog_last_check_ms >= WATCHDOG_WINDOW_MS:
		_watchdog_last_check_ms = now_ms
		_watchdog_days_seen = 0
	# Count how many days advanced this frame. Usually 0, sometimes
	# 1 at natural midnight. Anything larger is itself suspicious.
	var delta_days: int = cur_day - _watchdog_last_day
	if delta_days > 0:
		_watchdog_days_seen += delta_days
	_watchdog_last_day = cur_day
	# Trip the breaker if the window is over the threshold.
	if _watchdog_days_seen > WATCHDOG_MAX_DAYS_PER_SEC:
		_log("Day rollover watchdog tripped (%d days in %d ms) — disabling time cheats as failsafe" \
			% [_watchdog_days_seen, now_ms - _watchdog_last_check_ms], "error")
		# Self-disable every cheat that touches time. Each flip
		# routes through _on_cheat_toggled for proper cleanup.
		if cheat_real_time:
			_on_cheat_toggled(false, "cheat_real_time")
		if cheat_freeze_time:
			_on_cheat_toggled(false, "cheat_freeze_time")
		if cheat_time_speed != 1.0:
			cheat_time_speed = 1.0
			_sync_toggle_ui()
		_show_toast("Time cheats disabled — runaway rollover detected", COL_NEGATIVE)
		# Reset the window so we don't spam toasts.
		_watchdog_days_seen = 0
		_watchdog_last_check_ms = now_ms

func _on_time_slider_changed(new_val: float):
	# Manual slider drag implies the user wants a specific time, so
	# Real Time sync auto-disables. _sync_toggle_ui refreshes the
	# Real Time checkbox in the UI so the user sees it untick.
	# Persist the new "off" state so reloading the game doesn't
	# re-enable Real Time after an explicit override.
	if cheat_real_time:
		cheat_real_time = false
		_sync_toggle_ui()
		_save_real_time_pref()
		_profile_mark_dirty()  # v10.6.0 dual-write
	# Hitting max (2400) is the user's signal "advance to tomorrow".
	# Advance day by 1 and wrap time to 00:00. The drag-session lock
	# guarantees at-most-one-per-drag: once advanced, we ignore every
	# subsequent value_changed(2400) in this drag until drag_ended
	# fires on mouse release. The cooldown is a belt-and-suspenders
	# backup covering non-drag paths (keyboard, code-driven writes).
	#
	# CRITICAL: if we did fall through to _safe_set_sim_time for
	# pinned-at-max events, it would clamp to 2399.9 — which parks
	# sim.time one frame away from the game's natural rollover, and
	# the game's own time += rate * delta would hit >= 2400 every
	# frame, producing the runaway behavior we're protecting against.
	# So we always return early on new_val >= 2400, writing nothing.
	if new_val >= 2400.0:
		if _slider_advanced_this_drag:
			# Already advanced during this drag. Wait for release.
			return
		var now_ms: int = Time.get_ticks_msec()
		if (now_ms - _last_manual_day_advance_ms) >= MANUAL_DAY_ADVANCE_COOLDOWN_MS:
			_slider_advanced_this_drag = true
			_last_manual_day_advance_ms = now_ms
			_advance_day_by_one("time_slider_wrap")
			# Wrap time to 00:00 on the slider AND in sim. The
			# set_value_no_signal keeps this from re-triggering
			# _on_time_slider_changed recursively.
			if time_slider != null and is_instance_valid(time_slider):
				time_slider.set_value_no_signal(0.0)
			_safe_set_sim_time(0.0, "time_slider_wrap")
			_show_toast("Advanced to next day (Day %d)" % int(_safe(sim_ref, "day", 0)))
		return
	# Normal in-day slider move. Safe setter clamps + rate-limits.
	if _safe_set_sim_time(new_val, "time_slider"):
		var display_val: float = min(new_val, SAFE_TIME_MAX)
		_show_toast("Time set to %s (%s)" % [_format_sim_clock(display_val), _get_tod_name(display_val)])

func _on_time_slider_drag_ended(_value_changed_flag: bool):
	# Godot's HSlider fires this signal when the user releases the
	# mouse button after dragging the grabber. We use it to clear
	# the drag-session lock so the next drag can advance another
	# day. Without this hook the flag would stay set forever and
	# day advance would be one-shot for the whole session.
	_slider_advanced_this_drag = false

# Shared helper for any code path that needs to advance the day
# counter by exactly one. Calls Loader.UpdateProgression() so
# downstream systems (loot respawn, quest timers, etc.) run the
# same as they would for a natural midnight crossing.
func _advance_day_by_one(source: String):
	if sim_ref == null or not is_instance_valid(sim_ref) or not ("day" in sim_ref):
		return
	sim_ref.day = int(sim_ref.day) + 1
	var loader = get_node_or_null("/root/Loader")
	if loader != null and is_instance_valid(loader) and loader.has_method("UpdateProgression"):
		loader.UpdateProgression()
	_log("Day advanced to %d (source=%s)" % [int(sim_ref.day), source])

func _action_set_time(target_time: float):
	# Clicking a preset (Dawn/Noon/Dusk/Night) also auto-disables
	# Real Time sync for the same reason, and persists the flip.
	if cheat_real_time:
		cheat_real_time = false
		_sync_toggle_ui()
		_save_real_time_pref()
		_profile_mark_dirty()  # v10.6.0 dual-write
	if _safe_set_sim_time(target_time, "preset_button"):
		var display_val: float = min(target_time, SAFE_TIME_MAX)
		if time_slider:
			time_slider.set_value_no_signal(display_val)
		_show_toast("Time set to %s (%s)" % [_format_sim_clock(display_val), _get_tod_name(display_val)])
	else:
		_show_toast("Simulation not found", COL_NEGATIVE)

func _action_set_season(season_id: int):
	if sim_ref != null and is_instance_valid(sim_ref) and "season" in sim_ref:
		sim_ref.season = season_id
		var sname = "Summer" if season_id == 1 else "Winter"
		_show_toast("Season: " + sname)
	else:
		_show_toast("Simulation not found", COL_NEGATIVE)

func _action_set_weather(weather_name: String):
	if sim_ref != null and is_instance_valid(sim_ref) and "weather" in sim_ref:
		sim_ref.weather = weather_name
		sim_ref.weatherTime = 9999.0
		_show_toast("Weather: " + weather_name)
	else:
		_show_toast("Simulation not found", COL_NEGATIVE)


# ================================================================
#  WEAPON MODS (No Recoil — includes sway removal)
# ================================================================

func _get_rig_manager():
	if get_tree() == null or get_tree().current_scene == null:
		return null
	return get_tree().current_scene.get_node_or_null("/root/Map/Core/Camera/Manager")

func _get_active_weapon_rig():
	var rig_mgr = _get_rig_manager()
	if rig_mgr == null or not is_instance_valid(rig_mgr) or rig_mgr.get_child_count() == 0:
		return null
	var rig = rig_mgr.get_child(rig_mgr.get_child_count() - 1)
	if not is_instance_valid(rig) or rig.get_script() == null:
		return null
	if "recoil" in rig and "data" in rig:
		return rig
	return null

func _get_active_slot_data():
	# Try drawn weapon first, then fallback to equipment slots
	var sd = _get_slot_data_for("primary")
	if sd != null:
		return sd
	sd = _get_slot_data_for("secondary")
	return sd

func _get_cached_riser() -> Node:
	if _cached_riser != null and is_instance_valid(_cached_riser):
		return _cached_riser
	if get_tree() == null or get_tree().current_scene == null:
		return null
	_cached_riser = get_tree().current_scene.get_node_or_null("/root/Map/Core/Controller/Pelvis/Riser")
	return _cached_riser

func _get_cached_cam_noise() -> Node:
	if _cached_cam_noise != null and is_instance_valid(_cached_cam_noise):
		return _cached_cam_noise
	if get_tree() == null or get_tree().current_scene == null:
		return null
	_cached_cam_noise = get_tree().current_scene.get_node_or_null("/root/Map/Core/Controller/Pelvis/Riser/Head/Bob/Impulse/Damage/Noise")
	return _cached_cam_noise

func _restore_all_recoil_and_sway():
	# Iterate every weapon resource we ever touched and restore its
	# original recoil values, then clear the dict so it cannot grow.
	# Called when No Recoil toggles off or the mod shuts down.
	for weapon_data in saved_recoil:
		if not is_instance_valid(weapon_data):
			continue
		var orig = saved_recoil[weapon_data]
		if "verticalRecoil" in weapon_data:
			weapon_data.verticalRecoil = orig["vr"]
		if "horizontalRecoil" in weapon_data:
			weapon_data.horizontalRecoil = orig["hr"]
		if "kick" in weapon_data:
			weapon_data.kick = orig["kick"]
	saved_recoil.clear()
	# Sway nodes are node refs, not resources, so restoring them by
	# instance_id isn't safe across scene changes. Just clear the dict —
	# any Sway node that's still alive will pick up its default values
	# on the next scene load.
	saved_sway.clear()
	# Riser is captured once and restored via the cached ref.
	if not saved_riser.is_empty():
		var riser_restore = _get_cached_riser()
		if riser_restore != null and "semiRise" in riser_restore:
			riser_restore.semiRise = saved_riser["semi"]
			riser_restore.autoRise = saved_riser["auto"]
		saved_riser.clear()

func _apply_weapon_mods():
	var rig = _get_active_weapon_rig()
	if rig == null:
		return

	# ── No Recoil ──
	if cheat_no_recoil:
		# Save original WeaponData recoil values (once per resource).
		# v10.5.1 — additional guard: never capture a baseline of
		# { 0, 0, 0 }. That sentinel means "already zeroed by us in a
		# prior toggle cycle" — capturing it would permanently lose the
		# real baseline. Normal weapons always have non-zero vr or kick.
		if rig.data != null and rig.data not in saved_recoil:
			if "verticalRecoil" in rig.data:
				var cur_vr: float = float(rig.data.verticalRecoil)
				var cur_hr: float = float(rig.data.get("horizontalRecoil")) if "horizontalRecoil" in rig.data else 0.0
				var cur_kick: float = float(rig.data.get("kick")) if "kick" in rig.data else 0.0
				if cur_vr != 0.0 or cur_hr != 0.0 or cur_kick != 0.0:
					saved_recoil[rig.data] = {
						"vr": cur_vr,
						"hr": cur_hr,
						"kick": cur_kick,
					}
		# Only zero source values AFTER we've captured originals (prevents brief-frame zero on swap)
		if rig.data != null and rig.data in saved_recoil:
			if "verticalRecoil" in rig.data:
				rig.data.verticalRecoil = 0.0
			if "horizontalRecoil" in rig.data:
				rig.data.horizontalRecoil = 0.0
			if "kick" in rig.data:
				rig.data.kick = 0.0
		# Zero live recoil node values
		if rig.recoil != null and is_instance_valid(rig.recoil):
			if "currentKick" in rig.recoil:
				rig.recoil.currentKick = Vector3.ZERO
			if "currentRotation" in rig.recoil:
				rig.recoil.currentRotation = Vector3.ZERO
			rig.recoil.position = Vector3.ZERO
			rig.recoil.rotation = Vector3.ZERO
		# Kill weapon rig camera noise (firing shake)
		var noise_node = rig.get_node_or_null("Handling/Sway/Noise")
		if noise_node != null and is_instance_valid(noise_node) and "finalAmplitude" in noise_node:
			noise_node.finalAmplitude = 0.0
			noise_node.targetAmplitude = 0.0
			noise_node.rotation = Vector3.ZERO
		# Kill camera-level noise (second CameraNoise instance on the camera itself)
		var cam_noise = _get_cached_cam_noise()
		if cam_noise != null and "finalAmplitude" in cam_noise:
			cam_noise.finalAmplitude = 0.0
			cam_noise.targetAmplitude = 0.0
			cam_noise.rotation = Vector3.ZERO
		# Kill Riser body rise — rotates entire upper body/camera upward when firing
		var riser = _get_cached_riser()
		if riser != null and "semiRise" in riser:
			if saved_riser.is_empty():
				saved_riser = {"semi": riser.semiRise, "auto": riser.autoRise}
			riser.semiRise = 0.0
			riser.autoRise = 0.0
			riser.rotation_degrees.x = lerp(riser.rotation_degrees.x, 0.0, 0.5)
		# Kill weapon rig Noise.gd sway increase when firing (separate from CameraNoise)
		var rig_noise = rig.get_node_or_null("Handling/Sway/Noise")
		if rig_noise != null and is_instance_valid(rig_noise):
			if "targetAmplitude" in rig_noise:
				rig_noise.targetAmplitude = 0.0
				rig_noise.targetFrequency = 0.0
			if "finalAmplitude" in rig_noise:
				rig_noise.finalAmplitude = 0.0
			rig_noise.rotation = Vector3.ZERO
	else:
		# Restore every weapon we touched and clear the caches so they
		# don't grow across long sessions with frequent weapon swaps.
		if not saved_recoil.is_empty() or not saved_sway.is_empty() or not saved_riser.is_empty():
			_restore_all_recoil_and_sway()

	# ── Sway (bundled with No Recoil; restore handled in the else above) ──
	if cheat_no_recoil:
		var sway_node = rig.get_node_or_null("Handling/Sway")
		if sway_node != null and is_instance_valid(sway_node):
			var sway_id = sway_node.get_instance_id()
			if sway_id not in saved_sway and "baseMultiplier" in sway_node:
				saved_sway[sway_id] = {
					"base": sway_node.baseMultiplier,
					"aim": sway_node.get("aimMultiplier") if "aimMultiplier" in sway_node else 0.2,
					"canted": sway_node.get("cantedMultiplier") if "cantedMultiplier" in sway_node else 0.2,
				}
			if "baseMultiplier" in sway_node:
				sway_node.baseMultiplier = 0.0
			if "aimMultiplier" in sway_node:
				sway_node.aimMultiplier = 0.0
			if "cantedMultiplier" in sway_node:
				sway_node.cantedMultiplier = 0.0


# ================================================================
#  FLY SPEED OVERRIDE (v10.4.4 — tunable replacements for 1.0 / 100.0)
# ================================================================
# The game's Controller.Fly() hardcodes three speed tiers:
#   base    = 1.0   (walk fly — users report as "very very slow")
#   Shift   = 100.0 ("way too fast", 100x leap)
#   Ctrl    = 0.5   (slow mode, preserved)
# We can't modify Controller.gd, but our autoload's _physics_process runs
# at process_physics_priority=1000 — i.e. AFTER scene-node physics — so
# by the time we tick, move_and_slide has already placed the player
# using the game's per-frame velocity. We then add an incremental
# position delta to bring the NET per-frame motion to our target speed.
#
# Net motion = game_motion + correction
#            = vel*delta    + dir*(target - |vel|)*delta
#            = dir*target*delta                         ← effective speed = target
#
# Collision caveat: the correction is a raw position write (no
# move_and_slide), so at very high multipliers the player can clip
# through thin geometry. Pairs naturally with Noclip for fly-through-
# walls; without Noclip the game's own move_and_slide still collides
# at the ORIGINAL speed, so only our "extra" motion is un-checked.
func _physics_process(delta: float):
	_fly_apply_speed(delta)

func _fly_apply_speed(delta: float):
	if game_data == null or not ("isFlying" in game_data) or not game_data.isFlying:
		return
	if not controller_found or controller == null or not is_instance_valid(controller):
		return
	var vel: Vector3 = controller.velocity
	var mag := vel.length()
	if mag < 0.01:
		return   # player idle mid-air; no direction to scale
	# Determine which tier the game just applied. KEY_SHIFT and KEY_CTRL
	# are read live from Input — same source Controller.Fly() uses, so
	# our interpretation matches the game's on the same physics tick.
	var target_mag := cheat_fly_speed
	if Input.is_key_pressed(KEY_SHIFT):
		target_mag = cheat_fly_speed * cheat_fly_sprint_mult
	elif Input.is_key_pressed(KEY_CTRL):
		target_mag = cheat_fly_speed * 0.1
	# Guard against no-op micro-corrections (target already matches).
	if absf(target_mag - mag) < 0.01:
		return
	var dir: Vector3 = vel / mag
	controller.global_position += dir * (target_mag - mag) * delta


# ================================================================
#  NOCLIP (v10.4.3 — fly-through-walls)
# ================================================================
# Strategy: zero `collision_mask` and `collision_layer` on the
# CharacterBody3D controller. With both at 0 the physics server skips
# all collision tests for this body, so `move_and_slide()` (including
# the one inside the game's own Fly() loop) passes cleanly through walls.
# This is preferable to toggling each CollisionShape3D's `disabled`
# flag because (a) the game actively manages Stand/Crouch colliders on
# every crouch transition — fighting that would be fragile, and
# (b) restoring exactly two integers is trivial and race-free.
#
# State machine:
#   cheat_noclip OFF + _noclip_applied == false  → no-op
#   cheat_noclip ON  + _noclip_applied == false  → save masks, zero, flip flag
#   cheat_noclip ON  + _noclip_applied == true   → no-op (already applied)
#   cheat_noclip OFF + _noclip_applied == true   → restore masks, clear flag
# Controller loss (zone transition, death respawn) clears the flag so
# the next discovered controller gets re-applied if cheat_noclip is
# still true.
func _apply_noclip_if_needed():
	if not controller_found or controller == null or not is_instance_valid(controller):
		# Controller gone — any applied state belonged to a freed node.
		# Reset the flag so the next discovery re-applies cleanly.
		_noclip_applied = false
		return
	if cheat_noclip and not _noclip_applied:
		_saved_collision_mask = controller.collision_mask
		_saved_collision_layer = controller.collision_layer
		controller.collision_mask = 0
		controller.collision_layer = 0
		_noclip_applied = true
	elif not cheat_noclip and _noclip_applied:
		controller.collision_mask = _saved_collision_mask
		controller.collision_layer = _saved_collision_layer
		_noclip_applied = false


# ================================================================
#  INFINITE AMMO
# ================================================================

func _apply_infinite_ammo():
	# Prioritize the DRAWN weapon, not just whichever slot has a weapon.
	# v10.5.1 — guard the game_data reads. These fields are standard on
	# the shared GameData resource but have historically been added
	# across game versions; the rest of the mod uses `"X" in game_data`
	# checks consistently (see _save_character_save, _get_slot_data_for),
	# and this call site was the one exception.
	var slot_data = null
	var has_primary: bool = "primary" in game_data and bool(game_data.primary)
	var has_secondary: bool = "secondary" in game_data and bool(game_data.secondary)
	if has_primary:
		slot_data = _get_slot_data_for("primary")
	elif has_secondary:
		slot_data = _get_slot_data_for("secondary")
	if slot_data == null:
		slot_data = _get_active_slot_data()
	if slot_data == null:
		return
	if "amount" in slot_data and slot_data.itemData != null:
		if "magazineSize" in slot_data.itemData:
			slot_data.amount = slot_data.itemData.magazineSize
		slot_data.chamber = true
		# Keep slide forward
		var rig = _get_active_weapon_rig()
		if rig != null and "slideLocked" in rig:
			rig.slideLocked = false


# ================================================================
#  INFINITE ARMOR
# ================================================================
# Game's Interface.gd:2739 applies armor damage like this:
#   for itemData in slotData.nested:
#       if itemData.type == "Armor" && slotData.condition != 0:
#           if itemData.protection > penetration:
#               slotData.condition -= randi_range(15, 20)
#
# Plates sit as nested slots inside the rig's slotData on the player.
# Helmets sit on the helmet equipment slot directly. To keep them all
# pinned at 100 we walk the equipment tree each tick and refill the
# condition of any Armor / helmet / plate / carrier item we find. If
# a plate is damaged mid-hit we snap it back before the next hit can
# break it.
func _apply_infinite_armor():
	var interface = _get_interface()
	if interface == null or not is_instance_valid(interface):
		return
	# Walk every equipment slot (Helmet, Rig, etc.). Each slot can
	# either directly contain armor (helmets) or nest plates inside a
	# carrier (rigs with plate inserts). We handle both.
	for slot in _iter_equipment_items(interface):
		_refill_armor_slot_condition(slot)

# Yields every equipped item's node from the interface's equipment
# grid. Each returned node exposes `slotData` with itemData/condition/
# nested. Keeps the walker code generic so helmets, plates, carriers,
# and any future armor type get covered the same way.
func _iter_equipment_items(interface) -> Array:
	var out: Array = []
	if not ("equipmentGrid" in interface) or interface.equipmentGrid == null:
		return out
	for eq_slot in interface.equipmentGrid.get_children():
		if eq_slot.get_child_count() == 0:
			continue
		out.append(eq_slot.get_child(0))
	return out

# Refills the given equipment item's condition to 100 if it's armor,
# AND recurses into nested plates. The game's armor-damage logic
# reads both the parent slot's condition (helmets) and the nested
# plate's condition (rigs) so we pin both.
func _refill_armor_slot_condition(node):
	if node == null or not is_instance_valid(node):
		return
	if not ("slotData" in node) or node.slotData == null:
		return
	var sd = node.slotData
	var item = sd.itemData if ("itemData" in sd) else null
	if item != null and _is_armor_item(item):
		if "condition" in sd and float(sd.condition) < 100.0:
			sd.condition = 100.0
	# Walk nested plates. nested can hold SlotData or ItemData
	# depending on the slot type — inspect each entry defensively.
	if "nested" in sd and sd.nested is Array:
		for entry in sd.nested:
			if entry == null:
				continue
			# Case A: entry is a SlotData (rig's plate inserts).
			if "itemData" in entry and "condition" in entry:
				if entry.itemData != null and _is_armor_item(entry.itemData):
					if float(entry.condition) < 100.0:
						entry.condition = 100.0
			# Case B: entry is a raw ItemData (no per-instance
			# condition). Nothing to pin at this level; the
			# game reads parent slotData.condition in that case,
			# which we already handled above.

func _is_armor_item(item) -> bool:
	if item == null:
		return false
	# Covers Armor type (catches plates + armor pieces), plus the
	# explicit plate/carrier/helmet booleans on ItemData.
	if "type" in item and str(item.type) == "Armor":
		return true
	if "plate" in item and bool(item.plate):
		return true
	if "carrier" in item and bool(item.carrier):
		return true
	if "helmet" in item and bool(item.helmet):
		return true
	return false



# ================================================================
#  TELEPORT SYSTEM
# ================================================================

# Keys used in the persisted slot dict — avoids typos / magic strings.
const _TP_KEY_ID   := "id"
const _TP_KEY_NAME := "name"
const _TP_KEY_POS  := "pos"

func _action_tp_save():
	# v10.4.0 — Prompt the user for a nickname, then append an id-tagged
	# dict. Empty / whitespace-only → auto-default. Cancel aborts.
	var pos: Vector3 = game_data.playerPosition
	var default_name := _next_default_slot_name()
	_show_name_prompt(
		"SAVE POSITION",
		"Name this spot (optional):",
		default_name,
		Callable(self, "_finalize_tp_save").bind(pos, default_name)
	)

func _finalize_tp_save(entered: String, pos: Vector3, default_name: String):
	var final_name := entered.strip_edges()
	if final_name == "":
		final_name = default_name
	if teleport_slots.size() >= MAX_TELEPORT_SLOTS:
		teleport_slots.pop_front()
	teleport_slots.append({
		_TP_KEY_ID: _teleport_next_id,
		_TP_KEY_NAME: final_name,
		_TP_KEY_POS: pos,
	})
	_teleport_next_id += 1
	_save_teleport_slots()
	_profile_mark_dirty()  # v10.6.0 dual-write
	_show_toast("Saved '%s' at %.0f, %.0f, %.0f" % [final_name, pos.x, pos.y, pos.z])
	# If the picker is currently open (e.g. user bound tp_save and hit it
	# mid-browse), refresh the list so the new row appears live.
	_refresh_teleport_picker()

func _action_tp_last():
	if teleport_slots.size() == 0:
		_show_toast("No saved positions", COL_NEGATIVE)
		return
	var slot: Dictionary = teleport_slots[teleport_slots.size() - 1]
	var pos: Vector3 = slot.get(_TP_KEY_POS, Vector3.ZERO)
	var nm: String = String(slot.get(_TP_KEY_NAME, "Unknown"))
	if controller_found and is_instance_valid(controller):
		controller.global_position = pos
		_show_toast("Teleported to '%s'" % nm)
	else:
		_show_toast("Controller not found", COL_NEGATIVE)

func _action_tp_list():
	# v10.4.0 — Back-compat: old "show list as toast" keybind now opens
	# the interactive picker. Action id preserved so existing user binds
	# keep working.
	_open_teleport_picker()

func _action_tp_menu():
	_open_teleport_picker()

# Lowest positive integer N such that "Spot N" is not currently in use.
# Avoids numbering collisions with slots the user saved earlier and never
# deleted (e.g. if you saved 5 then deleted #3, the next default is "Spot 3"
# instead of "Spot 6"). Bounded at MAX_TELEPORT_SLOTS + 1 in the degenerate
# case where every integer 1..MAX is taken by a custom name happening to
# match "Spot N".
func _next_default_slot_name() -> String:
	var used := {}
	for slot in teleport_slots:
		if slot is Dictionary:
			used[String(slot.get(_TP_KEY_NAME, ""))] = true
	var n := 1
	while n <= MAX_TELEPORT_SLOTS + 1:
		var candidate := "Spot %d" % n
		if not used.has(candidate):
			return candidate
		n += 1
	# Unreachable under normal usage; fallback keeps us deterministic.
	return "Spot %d" % (teleport_slots.size() + 1)

# O(n) lookup by stable id. Returns -1 if the slot no longer exists
# (e.g. deleted between when a row was rendered and when the user clicked
# its button). Callers must check the return value.
func _find_slot_idx_by_id(id: int) -> int:
	for i in range(teleport_slots.size()):
		var slot = teleport_slots[i]
		if slot is Dictionary and int(slot.get(_TP_KEY_ID, -1)) == id:
			return i
	return -1

# ── Persistence (v10.4.0) ──────────────────────────────────────
func _load_teleport_slots():
	teleport_slots.clear()
	_teleport_next_id = 1
	var cfg := ConfigFile.new()
	var err := cfg.load(TELEPORT_CONFIG_PATH)
	if err != OK:
		if err != ERR_FILE_NOT_FOUND:
			_log("Failed to load teleport slots (err %d) from %s" % [err, TELEPORT_CONFIG_PATH], "warning")
		return
	var raw = cfg.get_value("slots", "list", [])
	if not (raw is Array):
		return
	var max_id := 0
	for v in raw:
		if not (v is Dictionary and v.has(_TP_KEY_NAME) and v.has(_TP_KEY_POS) and v[_TP_KEY_POS] is Vector3):
			continue
		# Migrate pre-id records: assign a fresh id if missing/zero.
		var id := int(v.get(_TP_KEY_ID, 0))
		if id <= 0:
			id = max_id + 1
		teleport_slots.append({
			_TP_KEY_ID: id,
			_TP_KEY_NAME: String(v[_TP_KEY_NAME]),
			_TP_KEY_POS: v[_TP_KEY_POS],
		})
		if id > max_id:
			max_id = id
		if teleport_slots.size() >= MAX_TELEPORT_SLOTS:
			break
	_teleport_next_id = max_id + 1

func _save_teleport_slots():
	var cfg := ConfigFile.new()
	cfg.set_value("slots", "list", teleport_slots)
	var err := cfg.save(TELEPORT_CONFIG_PATH)
	if err != OK:
		_log("Failed to save teleport slots (err %d) to %s" % [err, TELEPORT_CONFIG_PATH], "warning")
		_show_toast("Failed to save teleport slots (err %d)" % err, COL_NEGATIVE)

# ── Mouse-mode ownership for overlay dialogs (v10.4.0) ─────────
# When an overlay is opened via a keybind while the cheat menu is
# closed, the cursor is typically CAPTURED by gameplay and the user
# cannot click dialog buttons. We flip to VISIBLE and remember the
# prior mode so the exact state is restored on the last-overlay close.
# When the cheat menu is already open, it already owns the mouse and
# we leave it alone (cheat menu's own close path handles restoration).
func _overlay_claim_mouse_if_needed():
	if cheat_open:
		return
	if _overlay_mouse_owned:
		return
	_overlay_prior_mouse_mode = Input.get_mouse_mode()
	_overlay_mouse_owned = true
	if _overlay_prior_mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _overlay_release_mouse_if_last():
	if not _overlay_mouse_owned:
		return
	if cheat_open:
		return
	# Another overlay still open? Defer restoration.
	# v10.5.1 — also inspect backdrop nodes. Prior revision only checked
	# the panels themselves, so a close-sequence that freed the panel
	# before its backdrop (or vice versa) could race the mouse release
	# into a state where the backdrop was still catching clicks.
	if name_prompt_panel != null and is_instance_valid(name_prompt_panel):
		return
	if teleport_picker_panel != null and is_instance_valid(teleport_picker_panel):
		return
	if name_prompt_backdrop != null and is_instance_valid(name_prompt_backdrop):
		return
	if teleport_picker_backdrop != null and is_instance_valid(teleport_picker_backdrop):
		return
	Input.set_mouse_mode(_overlay_prior_mouse_mode)
	_overlay_mouse_owned = false

# ── Shared modal overlay scaffolding (DRY) ─────────────────────
# Builds backdrop + PanelContainer + MarginContainer + VBox with the
# project's standard styling and returns the vbox for the caller to
# populate. anchors is a Rect2 whose x/y are the top-left anchor and
# size is the anchor extent (e.g. Rect2(0.3, 0.35, 0.4, 0.3) covers
# 30–70 % horizontally and 35–65 % vertically).
func _make_modal_overlay(anchors: Rect2, backdrop_alpha: float) -> Dictionary:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, backdrop_alpha)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_tile_style(0.92))
	panel.anchor_left = anchors.position.x
	panel.anchor_top = anchors.position.y
	panel.anchor_right = anchors.position.x + anchors.size.x
	panel.anchor_bottom = anchors.position.y + anchors.size.y
	canvas.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	return {"backdrop": backdrop, "panel": panel, "vbox": vbox}

# ── Name-prompt dialog (v10.4.0, reusable) ─────────────────────
func _show_name_prompt(title: String, message: String, default_text: String, on_confirm: Callable):
	_close_name_prompt()
	_overlay_claim_mouse_if_needed()
	_name_prompt_submitting = false

	var overlay := _make_modal_overlay(Rect2(0.3, 0.35, 0.4, 0.3), 0.45)
	name_prompt_backdrop = overlay["backdrop"]
	name_prompt_panel = overlay["panel"]
	var vbox: VBoxContainer = overlay["vbox"]

	_add_title(vbox, title)
	_add_info_label(vbox, message, COL_TEXT_DIM, 13)

	var edit := LineEdit.new()
	edit.text = default_text
	edit.max_length = 32
	edit.custom_minimum_size = Vector2(0, 32)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.select_all_on_focus = true
	if game_font:
		edit.add_theme_font_override("font", game_font)
	edit.add_theme_font_size_override("font_size", 14)
	edit.add_theme_color_override("font_color", COL_TEXT)
	vbox.add_child(edit)
	edit.grab_focus.call_deferred()
	# Enter-to-submit. text_submitted emits (new_text); we bind on_confirm
	# so the handler can dispatch without re-reading the edit.
	edit.text_submitted.connect(Callable(self, "_on_name_prompt_submit").bind(on_confirm))

	_add_separator(vbox)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var ok_btn := _make_styled_button("OK", COL_SPAWN_BTN, COL_SPAWN_HVR)
	ok_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok_btn.custom_minimum_size = Vector2(0, 40)
	ok_btn.pressed.connect(Callable(self, "_on_name_prompt_ok").bind(edit, on_confirm))
	btn_row.add_child(ok_btn)

	var cancel_btn := _make_styled_button("CANCEL", COL_DANGER_BTN, COL_DANGER_HVR)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.custom_minimum_size = Vector2(0, 40)
	cancel_btn.pressed.connect(_close_name_prompt)
	btn_row.add_child(cancel_btn)

# Shared submission path. Two layers of defense against double-fire:
#   (1) panel liveness — if it's already queued-free from a prior
#       click in the same frame, reject the stale second click.
#   (2) _name_prompt_submitting — belt-and-suspenders in case the panel
#       is still alive but we're re-entering (e.g. OK click followed by
#       Enter within the button's processing window).
# Flag lives at module scope because _close_name_prompt clears the
# panel ref before we dispatch the callback.
func _name_prompt_commit(txt: String, on_confirm: Callable):
	if name_prompt_panel == null or not is_instance_valid(name_prompt_panel):
		return
	if _name_prompt_submitting:
		return
	_name_prompt_submitting = true
	_close_name_prompt()
	if on_confirm.is_valid():
		on_confirm.call(txt)

func _on_name_prompt_ok(edit: LineEdit, on_confirm: Callable):
	var txt := ""
	if edit != null and is_instance_valid(edit):
		txt = edit.text
	_name_prompt_commit(txt, on_confirm)

func _on_name_prompt_submit(text: String, on_confirm: Callable):
	_name_prompt_commit(text, on_confirm)

func _close_name_prompt():
	if name_prompt_panel != null and is_instance_valid(name_prompt_panel):
		name_prompt_panel.queue_free()
	name_prompt_panel = null
	if name_prompt_backdrop != null and is_instance_valid(name_prompt_backdrop):
		name_prompt_backdrop.queue_free()
	name_prompt_backdrop = null
	_name_prompt_submitting = false
	_overlay_release_mouse_if_last()

# ── Picker menu (v10.4.0) ──────────────────────────────────────
func _open_teleport_picker():
	_close_teleport_picker()
	_overlay_claim_mouse_if_needed()

	var overlay := _make_modal_overlay(Rect2(0.2, 0.15, 0.6, 0.7), 0.55)
	teleport_picker_backdrop = overlay["backdrop"]
	teleport_picker_panel = overlay["panel"]
	var vbox: VBoxContainer = overlay["vbox"]
	vbox.add_theme_constant_override("separation", 6)

	_add_title(vbox, "TELEPORT BOOKMARKS")
	_add_info_label(vbox, "Click GO to jump to a saved spot. RENAME/DELETE manage it.", COL_TEXT_DIM, 12)
	_add_separator(vbox)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	teleport_picker_list_vbox = VBoxContainer.new()
	teleport_picker_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	teleport_picker_list_vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(teleport_picker_list_vbox)

	_add_separator(vbox)

	var close_btn := _make_styled_button("CLOSE", COL_BTN_NORMAL, COL_BTN_HOVER)
	close_btn.custom_minimum_size = Vector2(0, 36)
	close_btn.pressed.connect(_close_teleport_picker)
	vbox.add_child(close_btn)

	_refresh_teleport_picker()

func _refresh_teleport_picker():
	# Safe to call when the picker isn't open — no-op.
	if teleport_picker_list_vbox == null or not is_instance_valid(teleport_picker_list_vbox):
		return
	for child in teleport_picker_list_vbox.get_children():
		child.queue_free()
	if teleport_slots.size() == 0:
		_add_info_label(teleport_picker_list_vbox, "No bookmarks saved yet. Use 'Save Position' to add one.", COL_TEXT_DIM, 13)
		return
	for i in range(teleport_slots.size()):
		_add_teleport_row(teleport_picker_list_vbox, i)

func _add_teleport_row(parent: VBoxContainer, idx: int):
	var slot: Dictionary = teleport_slots[idx]
	var slot_id: int = int(slot.get(_TP_KEY_ID, 0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	# All row buttons bind the STABLE slot id, not the array index — so
	# a stale click after a delete/refresh can't point at the wrong row.
	var go_btn := _make_styled_button("GO", COL_SPAWN_BTN, COL_SPAWN_HVR)
	go_btn.custom_minimum_size = Vector2(60, 30)
	go_btn.pressed.connect(Callable(self, "_teleport_to_slot_by_id").bind(slot_id))
	row.add_child(go_btn)

	var label := Label.new()
	var pos: Vector3 = slot.get(_TP_KEY_POS, Vector3.ZERO)
	label.text = "%s  —  %.0f, %.0f, %.0f" % [String(slot.get(_TP_KEY_NAME, "?")), pos.x, pos.y, pos.z]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	if game_font:
		label.add_theme_font_override("font", game_font)
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", COL_TEXT)
	row.add_child(label)

	var rename_btn := _make_styled_button("RENAME", COL_BTN_NORMAL, COL_BTN_HOVER)
	rename_btn.custom_minimum_size = Vector2(80, 30)
	rename_btn.pressed.connect(Callable(self, "_rename_teleport_slot_by_id").bind(slot_id))
	row.add_child(rename_btn)

	var del_btn := _make_styled_button("DELETE", COL_DANGER_BTN, COL_DANGER_HVR)
	del_btn.custom_minimum_size = Vector2(80, 30)
	del_btn.pressed.connect(Callable(self, "_delete_teleport_slot_by_id").bind(slot_id))
	row.add_child(del_btn)

func _teleport_to_slot_by_id(id: int):
	var idx := _find_slot_idx_by_id(id)
	if idx < 0:
		return  # slot was deleted between render and click — silently ignore
	var slot: Dictionary = teleport_slots[idx]
	var pos: Vector3 = slot.get(_TP_KEY_POS, Vector3.ZERO)
	var nm: String = String(slot.get(_TP_KEY_NAME, "?"))
	if controller_found and is_instance_valid(controller):
		controller.global_position = pos
		_show_toast("Teleported to '%s'" % nm)
		_close_teleport_picker()
	else:
		_show_toast("Controller not found", COL_NEGATIVE)

func _rename_teleport_slot_by_id(id: int):
	var idx := _find_slot_idx_by_id(id)
	if idx < 0:
		return
	var current_name: String = String(teleport_slots[idx].get(_TP_KEY_NAME, ""))
	_show_name_prompt(
		"RENAME BOOKMARK",
		"New name:",
		current_name,
		Callable(self, "_finalize_rename_slot").bind(id, current_name)
	)

func _finalize_rename_slot(entered: String, id: int, current_name: String):
	var idx := _find_slot_idx_by_id(id)
	if idx < 0:
		return
	var final_name := entered.strip_edges()
	if final_name == "":
		final_name = current_name
	teleport_slots[idx][_TP_KEY_NAME] = final_name
	_save_teleport_slots()
	_profile_mark_dirty()  # v10.6.0 dual-write
	_refresh_teleport_picker()
	_show_toast("Renamed to '%s'" % final_name)

func _delete_teleport_slot_by_id(id: int):
	# One-shot guard — prevents the YES button in _show_confirm from
	# firing twice on a rapid double-click and deleting the WRONG slot
	# after the array shifts. If the prior confirm was dismissed via
	# CANCEL (whose handler we can't hook since _show_confirm wires NO
	# directly to _close_confirm), the flag would otherwise stay stuck,
	# locking out subsequent deletes. Auto-clear if the confirm panel
	# is gone — that's the unambiguous signal that any prior flow ended.
	if _delete_confirm_acting and (confirm_panel == null or not is_instance_valid(confirm_panel)):
		_delete_confirm_acting = false
	if _delete_confirm_acting:
		return
	var idx := _find_slot_idx_by_id(id)
	if idx < 0:
		return
	var nm: String = String(teleport_slots[idx].get(_TP_KEY_NAME, "?"))
	_delete_confirm_acting = true
	_show_confirm(
		"DELETE BOOKMARK",
		"Remove '%s'?" % nm,
		Callable(self, "_finalize_delete_slot").bind(id, nm)
	)

func _finalize_delete_slot(id: int, nm: String):
	_close_confirm()
	# Clear the one-shot regardless of whether we find the slot — the
	# dialog is gone and any further YES clicks are stale.
	_delete_confirm_acting = false
	var idx := _find_slot_idx_by_id(id)
	if idx < 0:
		return
	teleport_slots.remove_at(idx)
	_save_teleport_slots()
	_profile_mark_dirty()  # v10.6.0 dual-write
	_refresh_teleport_picker()
	_show_toast("Deleted '%s'" % nm)

func _close_teleport_picker():
	if teleport_picker_panel != null and is_instance_valid(teleport_picker_panel):
		teleport_picker_panel.queue_free()
	teleport_picker_panel = null
	teleport_picker_list_vbox = null
	if teleport_picker_backdrop != null and is_instance_valid(teleport_picker_backdrop):
		teleport_picker_backdrop.queue_free()
	teleport_picker_backdrop = null
	# Closing the picker while a confirm was mid-flight — reset the
	# one-shot so the next delete is usable.
	_delete_confirm_acting = false
	_overlay_release_mouse_if_last()


# ================================================================
#  ECONOMY / CRAFTING ACTIONS
# ================================================================

func _action_restock_traders():
	if get_tree() == null or get_tree().current_scene == null:
		return
	# v10.5.1 — tightened discovery. Two fixes:
	#  1. `"CreateSupply" in node` was relying on GDScript's `in`
	#     operator matching scripted functions, which is inconsistent
	#     across Object vs. native-class paths. `has_method` is the
	#     canonical check and matches what the rest of the file does.
	#  2. Search is still O(N) across every Node3D in the tree — that's
	#     inherent without a "Trader" scene group — but we now filter
	#     on cheap property existence first (`traderData`) before the
	#     more expensive method lookup, trimming the work done on the
	#     thousands of Node3Ds a large map typically has.
	var count := 0
	for node in get_tree().root.find_children("*", "Node3D", true, false):
		if not is_instance_valid(node):
			continue
		if node.get_script() == null:
			continue
		if not ("traderData" in node):
			continue
		if not node.has_method("CreateSupply"):
			continue
		node.CreateSupply()
		count += 1
	if count > 0:
		_show_toast("Restocked %d traders" % count)
	else:
		_show_toast("No traders found", COL_NEGATIVE)


# ================================================================
#  INVENTORY SORT
# ================================================================

const TYPE_SORT_ORDER := {
	"Weapon": 0, "Ammo": 1, "Attachment": 2, "Armor": 3, "Helmet": 4,
	"Rig": 5, "Backpack": 6, "Belt Pouch": 7, "Clothing": 8,
	"Medical": 9, "Consumable": 10, "Consumables": 11, "Fish": 12,
	"Electronics": 13, "Grenade": 14, "Knife": 15, "Key": 16,
	"Instrument": 17, "Literature": 18, "Lore": 19, "Fishing": 20,
	"Misc": 21, " Misc": 21,
}

func _get_type_order(item_type: String) -> int:
	if item_type in TYPE_SORT_ORDER:
		return TYPE_SORT_ORDER[item_type]
	return 99

func _action_sort_inventory_type():
	_sort_inventory("type")

func _action_sort_inventory_weight():
	_sort_inventory("weight")

func _action_stack_duplicates():
	var interface = _get_interface()
	if interface == null:
		_show_toast("Interface not found", COL_NEGATIVE)
		return
	var grid = interface.inventoryGrid
	if not is_instance_valid(grid):
		return

	# Collect all items and try to stack them
	var stacked := 0
	var items_list = grid.get_children().duplicate()
	for i in range(items_list.size()):
		var item_a = items_list[i]
		if not is_instance_valid(item_a) or not "slotData" in item_a:
			continue
		if item_a.slotData == null or item_a.slotData.itemData == null:
			continue
		if not item_a.slotData.itemData.stackable:
			continue
		for j in range(i + 1, items_list.size()):
			var item_b = items_list[j]
			if not is_instance_valid(item_b) or not "slotData" in item_b:
				continue
			if item_b.slotData == null or item_b.slotData.itemData == null:
				continue
			if item_a.slotData.itemData.file != item_b.slotData.itemData.file:
				continue
			# Same item type — try to merge
			var max_amt = item_a.slotData.itemData.maxAmount
			var space = max_amt - item_a.slotData.amount
			if space <= 0:
				continue
			var transfer = min(space, item_b.slotData.amount)
			item_a.slotData.amount += transfer
			item_b.slotData.amount -= transfer
			stacked += 1
			if item_b.slotData.amount <= 0:
				grid.Pick(item_b)
				item_b.queue_free()

	if stacked > 0:
		interface.UpdateStats(false)
		_show_toast("Stacked %d item groups" % stacked)
	else:
		_show_toast("Nothing to stack")

func _sort_inventory(mode: String):
	var interface = _get_interface()
	if interface == null:
		_show_toast("Interface not found", COL_NEGATIVE)
		return
	var grid = interface.inventoryGrid
	if not is_instance_valid(grid):
		return

	# Step 1: Collect all items and their SlotData
	var item_nodes = []
	for child in grid.get_children():
		if not is_instance_valid(child):
			continue
		if "slotData" in child and child.slotData != null and child.slotData.itemData != null:
			item_nodes.append(child)

	if item_nodes.size() == 0:
		_show_toast("Inventory is empty")
		return

	# Step 2: Pick all items out of the grid (frees cells)
	var picked_items := []
	for item in item_nodes:
		if grid.items.has(item):
			grid.Pick(item)
			picked_items.append(item)

	# Step 3: Sort — largest items first (better packing), then by category
	if mode == "type":
		picked_items.sort_custom(func(a, b):
			var ta = _get_type_order(str(_safe(a.slotData.itemData, "type", "")))
			var tb = _get_type_order(str(_safe(b.slotData.itemData, "type", "")))
			if ta != tb:
				return ta < tb
			# Same type — sort by size (area) descending for better packing
			var sa = a.slotData.itemData.size.x * a.slotData.itemData.size.y
			var sb = b.slotData.itemData.size.x * b.slotData.itemData.size.y
			return sa > sb
		)
	elif mode == "weight":
		picked_items.sort_custom(func(a, b):
			var wa = _safe(a.slotData.itemData, "weight", 0.0)
			var wb = _safe(b.slotData.itemData, "weight", 0.0)
			if wa != wb:
				return wa > wb
			var sa = a.slotData.itemData.size.x * a.slotData.itemData.size.y
			var sb = b.slotData.itemData.size.x * b.slotData.itemData.size.y
			return sa > sb
		)

	# Step 4: Place items back in sorted order
	var placed := 0
	var failed := []
	for item in picked_items:
		# Reset rotation for clean packing
		if item.rotated:
			item.rotated = false
			item.size = Vector2(item.slotData.itemData.size.x * 64, item.slotData.itemData.size.y * 64)
		if grid.Spawn(item):
			placed += 1
		else:
			# Try rotated
			item.rotated = true
			item.size = Vector2(item.slotData.itemData.size.y * 64, item.slotData.itemData.size.x * 64)
			if grid.Spawn(item):
				placed += 1
			else:
				# Couldn't fit — put back unrotated
				item.rotated = false
				item.size = Vector2(item.slotData.itemData.size.x * 64, item.slotData.itemData.size.y * 64)
				failed.append(item)

	# Try to fit failed items one more time (grid may have space now)
	var dropped := 0
	for item in failed:
		if not grid.Spawn(item):
			# Drop on ground as last resort — prevent orphaned nodes
			if item.slotData != null and item.slotData.itemData != null:
				_spawn_in_world(item.slotData.itemData)
			item.queue_free()
			dropped += 1
	if dropped > 0:
		_show_toast("%d items couldn't fit — dropped on ground" % dropped, COL_NEGATIVE)

	interface.UpdateStats(false)
	var sort_name = "type" if mode == "type" else "weight"
	_show_toast("Sorted %d items by %s" % [placed, sort_name])


# ================================================================
#  CABIN AUTO-STASH
# ================================================================

func _get_cabin_containers() -> Array:
	# Returns array of {container: LootContainer, name: String, size: Vector2}
	var result := []
	if get_tree() == null:
		return result
	var furnitures = get_tree().get_nodes_in_group("Furniture")
	for furniture in furnitures:
		if not is_instance_valid(furniture):
			continue
		if furniture.owner == null or not is_instance_valid(furniture.owner):
			continue
		if furniture.owner is LootContainer:
			var cont = furniture.owner as LootContainer
			var name = cont.containerName if "containerName" in cont else "Unknown"
			var sz = cont.containerSize if "containerSize" in cont else Vector2(8, 13)
			result.append({"container": cont, "name": name, "size": sz})
	return result

func _classify_container(container_name: String) -> Array:
	# Only two typed containers in the default cabin:
	#   Fridge → food/drinks
	#   Nightstand → keys, personal/small items
	# Everything else (Cabinet, Medical Cabinet, Crate, etc.) is generic
	var lower = container_name.to_lower()
	if "fridge" in lower or "freezer" in lower or "stove" in lower:
		return ["Consumable", "Consumables", "Fish"]
	if "nightstand" in lower:
		return ["Key", "Electronics", "Instrument", "Literature", "Lore", "Casette"]
	# All other containers accept everything
	return []

func _container_accepts_item(container_name: String, item_type: String) -> bool:
	# Only returns true if this container has a SPECIFIC classification that includes the item type
	# Generic containers (empty classification) return false here — they're handled in pass 2
	var accepted = _classify_container(container_name)
	if accepted.size() == 0:
		return false
	return item_type in accepted

func _force_container_repack(cont):
	# Move all items from storage into loot and mark as not-storaged.
	# This forces the game to use Create() (auto-placement) instead of
	# LoadGridItem() (fixed positions) when the container is next opened.
	# The game will re-save with correct positions when the container is closed.
	# IMPORTANT: append to loot, don't overwrite — loot may contain
	# original items from a first-visit container that were never loaded.
	if "storage" in cont and "loot" in cont:
		if cont.loot is Array:
			cont.loot.append_array(cont.storage)
		else:
			cont.loot = cont.storage.duplicate()
		cont.storage.clear()
		cont.storaged = false
	# Any container mutation invalidates the dashboard cabin-aggregate cache.
	_invalidate_cabin_counts_cache()

func _stash_single_item(item_slotdata, containers: Array) -> bool:
	# Shared 3-pass stash logic: typed -> generic -> overflow
	# Returns true if item was stashed, false if no container had space.
	# Any successful stash invalidates the dashboard cabin counts cache so
	# the STOCKPILE card reflects the new totals on its next refresh tick.
	if item_slotdata == null or item_slotdata.itemData == null:
		return false
	var item_type = str(_safe(item_slotdata.itemData, "type", ""))
	var item_size = _safe(item_slotdata.itemData, "size", Vector2(1, 1))
	# Pass 1: type-matched containers
	for cont_info in containers:
		if not _container_accepts_item(cont_info["name"], item_type):
			continue
		if not _container_can_fit(cont_info["container"], item_size):
			continue
		var new_slot = SlotData.new()
		new_slot.Update(item_slotdata)
		cont_info["container"].storage.append(new_slot)
		cont_info["container"].storaged = true
		_invalidate_cabin_counts_cache()
		return true
	# Pass 2: generic containers
	for cont_info in containers:
		var accepted = _classify_container(cont_info["name"])
		if accepted.size() != 0:
			continue
		if not _container_can_fit(cont_info["container"], item_size):
			continue
		var new_slot = SlotData.new()
		new_slot.Update(item_slotdata)
		cont_info["container"].storage.append(new_slot)
		cont_info["container"].storaged = true
		_invalidate_cabin_counts_cache()
		return true
	# Pass 3: overflow — any container with space
	for cont_info in containers:
		if not _container_can_fit(cont_info["container"], item_size):
			continue
		var new_slot = SlotData.new()
		new_slot.Update(item_slotdata)
		cont_info["container"].storage.append(new_slot)
		cont_info["container"].storaged = true
		_invalidate_cabin_counts_cache()
		return true
	return false

func _container_can_fit(cont, item_size: Vector2) -> bool:
	var item_w = int(item_size.x)
	var item_h = int(item_size.y)
	var cont_w = int(cont.containerSize.x)
	var cont_h = int(cont.containerSize.y)
	# Item must physically fit in at least one orientation
	var fits_normal = item_w <= cont_w and item_h <= cont_h
	var fits_rotated = item_h <= cont_w and item_w <= cont_h
	if not fits_normal and not fits_rotated:
		return false
	# Since we write directly to container.storage (not a real grid),
	# the game will handle actual placement when the container is opened.
	# Use stored item count as a soft cap — the game's grid packer is more
	# efficient than area math (Tetris packing + rotation).
	# Allow up to total_cells items (worst case all 1x1).
	# The game will gracefully handle overflow by dropping items that don't fit
	# when the container is next opened.
	var total_cells = cont_w * cont_h
	var stored_count = cont.storage.size() if "storage" in cont and cont.storage is Array else 0
	if stored_count >= total_cells:
		return false
	return true

func _action_cabin_stash():
	# Check if we're in the shelter
	if not ("shelter" in game_data and game_data.shelter):
		_show_toast("Must be in your cabin!", COL_NEGATIVE)
		return

	var interface = _get_interface()
	if interface == null:
		_show_toast("Interface not found", COL_NEGATIVE)
		return

	var inv_grid = interface.inventoryGrid
	if not is_instance_valid(inv_grid):
		return

	# Get cabin containers
	var containers = _get_cabin_containers()
	if containers.size() == 0:
		_show_toast("No containers found in cabin", COL_NEGATIVE)
		return

	# Collect non-equipped inventory items
	var items_to_stash := []
	for child in inv_grid.get_children():
		if not is_instance_valid(child) or not "slotData" in child:
			continue
		if child.slotData == null or child.slotData.itemData == null:
			continue
		# Skip equipped items
		if "equipped" in child and child.equipped:
			continue
		items_to_stash.append(child)

	if items_to_stash.size() == 0:
		_show_toast("No items to stash")
		return

	var stashed := 0
	var stash_summary := {}

	for item in items_to_stash:
		if not is_instance_valid(item):
			continue
		if _stash_single_item(item.slotData, containers):
			var item_type = str(_safe(item.slotData.itemData, "type", ""))
			inv_grid.Pick(item)
			item.queue_free()
			stashed += 1
			if item_type not in stash_summary:
				stash_summary[item_type] = 0
			stash_summary[item_type] += 1

	if stashed > 0:
		# Force all modified containers to repack on next open
		for cont_info in containers:
			_force_container_repack(cont_info["container"])
		interface.UpdateStats(false)
		var parts := []
		for t in stash_summary:
			parts.append("%d %s" % [stash_summary[t], t])
		_show_toast("Stashed: " + ", ".join(parts))
	else:
		_show_toast("No space in cabin containers", COL_NEGATIVE)


# ================================================================
#  STARTER STASH  (v10.3.2)
# ================================================================
# Pre-populates the cabin with a curated kit: food in the fridge,
# supplies in the medical cabinet, misc/ammo in generic cabinets and
# shelves, clothing placed on the couch, and a weapon + ammo on the
# table. Items are picked from the live catalog at runtime so a game
# update that renames or replaces an item only silently drops that
# one slot — the rest of the kit still lands.
#
# Always available (no first-run flag). Running it twice appends,
# so a re-run is a valid "top up a looted cabin" shortcut. The
# container-fit check prevents infinite growth.

# Height offsets above each furniture node's local origin to its top
# surface. Derived from the Parenter Area3D collision shape in the
# scene files (Sofa_Leather_F.tscn, Table_Cabin_F.tscn):
#
#   Sofa:  parenter pos (0, 0.5, -0.028)  + shape max Y  0.525  = 1.025m
#   Table: parenter pos (0, 0.4,  0)      + shape max Y  0.425  = 0.825m
#
# Pickup._ready() freezes rigid bodies the moment they spawn (freeze_mode
# = FREEZE_MODE_STATIC), so items stay at exactly the world position we
# place them at — gravity never runs. That means these Y offsets must
# correspond to the actual target surface, not a drop height.
#
# Table origin is at world Y=0.4; table top collider is at local Y=0.775
# → world Y=1.175. To have a rifle's handle rest on the surface we spawn
# the origin a hair above 1.175. Ammo boxes are thinner so they sit
# slightly lower. Values below are local offsets added to table_origin.y.
const STARTER_TABLE_Y := 1.00       # rifle: user validated this Y earlier
const STARTER_TABLE_AMMO_Y := 0.79  # ammo: lowered so boxes rest near the table top
# Sofa origin is at world Y=0.4; cushion top ≈ world Y=0.95 — user's last
# test with this value looked right, so keep it.
const STARTER_COUCH_Y := 0.55

# Per-category target counts for the container stash pass.
const STARTER_FOOD_ITEMS := 8      # Distinct food items to place in fridge
const STARTER_FOOD_QTY   := 2      # Qty per food item
const STARTER_MED_ITEMS  := 6      # Distinct medical items in the med cabinet
const STARTER_MED_QTY    := 2      # Qty per medical item
const STARTER_AMMO_TYPES := 3      # Distinct ammo types placed on the table
const STARTER_MISC_ITEMS := 4      # Misc items placed in generic cabinets/shelves

# Clothing slot preference order — we place one item per slot on the couch.
const STARTER_CLOTHING_SLOTS := ["Torso", "Legs", "Feet", "Head", "Chest", "Backpack"]

# Priority keywords for curating which items land in each container. The
# first keyword a given item name contains wins; lower index = higher
# priority. Items that match nothing go to the back of the queue. This
# lets us bias the starter kit toward genuinely useful items (water,
# major heals, rifles) without hardcoding exact file names that would
# break if the game renames an asset.
const STARTER_FOOD_PRIORITY := [
	"water", "bottle", "juice", "milk", "coffee", "tea", "drink",
	"canned", "stew", "ration", "mre",
	"meat", "fish", "chocolate", "bread", "meal", "candy", "nut",
]
const STARTER_MED_PRIORITY := [
	"ifak", "medkit", "med kit", "first aid",
	"morphine", "painkiller", "tourniquet",
	"bandage", "gauze", "splint", "antibiotic", "pill", "syringe",
]
const STARTER_WEAPON_PRIORITY := [
	"ak", "m4", "rifle", "smg", "shotgun", "pistol",
]

func _action_starter_stash_coming_soon():
	# Starter Stash is temporarily disabled while item placement on the
	# table/couch is being finalized. Real implementation below stays in
	# the file so it can be re-enabled in a later release.
	_show_toast("Starter Kit - coming soon", COL_TEXT_DIM)

func _action_stock_starter_stash():
	if not ("shelter" in game_data and game_data.shelter):
		_show_toast("Must be in your cabin!", COL_NEGATIVE)
		return
	# Catalog is lazy-loaded (normally on first Spawner open). Scan it now
	# synchronously if it hasn't been populated yet, so the player doesn't
	# have to open F6 as a prerequisite for this feature.
	if not catalog_ready:
		_scan_catalog()
	if not catalog_ready or items_by_category.is_empty():
		_show_toast("Catalog scan failed — Database unavailable", COL_NEGATIVE)
		return

	var containers = _get_cabin_containers()
	if containers.size() == 0:
		_show_toast("No containers found in cabin", COL_NEGATIVE)
		return

	var totals := {"food": 0, "medical": 0, "misc": 0, "couch": 0, "table": 0}
	var touched_conts: Array = []

	# ── Fridge: food + drink, priority-sorted so water/drinks land first ──
	var fridge = _starter_find_container(containers, ["fridge", "freezer"])
	if fridge != null and items_by_category.has("Food"):
		var food_sorted = _starter_sort_by_priority(items_by_category["Food"], STARTER_FOOD_PRIORITY)
		var placed_items := 0
		for item_data in food_sorted:
			if placed_items >= STARTER_FOOD_ITEMS:
				break
			var added = _starter_add_item(fridge, item_data, STARTER_FOOD_QTY)
			if added > 0:
				totals["food"] += added
				placed_items += 1
		if placed_items > 0 and not touched_conts.has(fridge):
			touched_conts.append(fridge)
	else:
		_log("starter_stash: no fridge container found", "warning")

	# ── Medical: route each item through the same 3-pass stash the working
	# Cabin Stash feature uses. It tries type-matched containers first, then
	# any generic container (Cabinet_Wood / Medical Cabinet / etc.), then
	# any container with space. We don't need to hand-pick a container.
	_log("starter_stash: categories = %s" % [items_by_category.keys()])
	if items_by_category.has("Medical"):
		var med_sorted = _starter_sort_by_priority(items_by_category["Medical"], STARTER_MED_PRIORITY)
		_log("starter_stash: medical pool size = %d" % med_sorted.size())
		var placed_items := 0
		for item_data in med_sorted:
			if placed_items >= STARTER_MED_ITEMS:
				break
			var placed_any_qty := false
			for i in range(STARTER_MED_QTY):
				var slot = SlotData.new()
				slot.itemData = item_data
				slot.amount = 1
				slot.condition = 100
				if _stash_single_item(slot, containers):
					totals["medical"] += 1
					placed_any_qty = true
			if placed_any_qty:
				placed_items += 1
		_log("starter_stash: placed %d medical items (total qty %d)" % [placed_items, totals["medical"]])
		# _stash_single_item doesn't tell us which container it used, so mark
		# every container for force-repack. No-op on containers it didn't touch.
		for cont_info in containers:
			if not touched_conts.has(cont_info["container"]):
				touched_conts.append(cont_info["container"])
	else:
		_log("starter_stash: no Medical category in catalog", "warning")

	# ── Generic cabinet/shelf: misc spillover (attachments + equipment extras) ──
	var generic = _starter_find_generic_container(containers, [fridge])
	if generic != null:
		var misc_pool: Array = []
		if items_by_category.has("Attachments"):
			misc_pool.append_array(items_by_category["Attachments"])
		if items_by_category.has("Misc"):
			misc_pool.append_array(items_by_category["Misc"])
		var placed_items := 0
		for item_data in misc_pool:
			if placed_items >= STARTER_MISC_ITEMS:
				break
			var added = _starter_add_item(generic, item_data, 1)
			if added > 0:
				totals["misc"] += added
				placed_items += 1
		if placed_items > 0 and not touched_conts.has(generic):
			touched_conts.append(generic)

	# ── Look up couch + table upfront so we can use one to orient the other ──
	var couch = _find_cabin_furniture(["sofa", "couch"])
	var table = _find_cabin_furniture(["table"])

	# ── Couch: clothing placed as world items on the cushion front ──
	if couch != null and items_by_category.has("Equipment"):
		var couch_origin: Vector3 = couch.global_position
		_log("starter_stash: couch '%s' at %s" % [couch.name, couch_origin])
		# Compute "forward" (away from wall, toward cushion front) by aiming
		# at the table if we found it; otherwise fall back to world +Z.
		var forward := Vector3(0, 0, 1)
		if table != null:
			var delta = table.global_position - couch_origin
			delta.y = 0.0
			if delta.length() > 0.1:
				forward = delta.normalized()
		# Lateral axis: perpendicular to forward in the XZ plane.
		var lateral := Vector3(-forward.z, 0.0, forward.x)
		var seen_names: Dictionary = {}
		for slot_name in STARTER_CLOTHING_SLOTS:
			var item_data = _starter_find_equipment_for_slot(slot_name, seen_names)
			if item_data == null:
				continue
			seen_names[str(_safe(item_data, "name", ""))] = true
			var fwd_amt = randf_range(0.05, 0.30)
			var lat_amt = randf_range(-0.70, 0.70)
			var drop = couch_origin + forward * fwd_amt + lateral * lat_amt + Vector3(0.0, STARTER_COUCH_Y, 0.0)
			if _starter_spawn_world_at(item_data, drop):
				totals["couch"] += 1
	else:
		_log("starter_stash: couch NOT found in Furniture group", "warning")

	# ── Table: one weapon + a few ammo boxes ──
	if table != null:
		var table_origin: Vector3 = table.global_position
		_log("starter_stash: table '%s' at %s" % [table.name, table_origin])
		if items_by_category.has("Weapons") and items_by_category["Weapons"].size() > 0:
			var weapons_sorted = _starter_sort_by_priority(items_by_category["Weapons"], STARTER_WEAPON_PRIORITY)
			for weapon_data in weapons_sorted:
				if weapon_data == null:
					continue
				if _starter_spawn_world_at(weapon_data, table_origin + Vector3(0.0, STARTER_TABLE_Y, 0.0)):
					totals["table"] += 1
					break
		# Ammo boxes next to it
		if items_by_category.has("Ammo"):
			var placed := 0
			for ammo_data in items_by_category["Ammo"]:
				if placed >= STARTER_AMMO_TYPES:
					break
				var offset = Vector3(
					randf_range(-0.5, 0.5),
					STARTER_TABLE_AMMO_Y,
					randf_range(-0.25, 0.25)
				)
				if _starter_spawn_world_at(ammo_data, table_origin + offset):
					totals["table"] += 1
					placed += 1
	else:
		_log("starter_stash: table NOT found in Furniture group", "warning")

	# Force-repack any container we wrote to, same as cabin_stash.
	for cont in touched_conts:
		_force_container_repack(cont)
	_invalidate_cabin_counts_cache()

	var total_container = totals["food"] + totals["medical"] + totals["misc"]
	var total_world = totals["couch"] + totals["table"]
	if total_container == 0 and total_world == 0:
		_show_toast("Starter stash: nothing placed (no matching items in catalog)", COL_NEGATIVE)
		return
	_show_toast("Starter stash: %d food · %d med · %d misc · %d couch · %d table" % [
		totals["food"], totals["medical"], totals["misc"], totals["couch"], totals["table"]
	])


# ── Starter stash helpers ──────────────────────────────────────

func _starter_find_container(containers: Array, name_patterns: Array):
	# Returns the first LootContainer whose containerName contains any of
	# the given substrings (case-insensitive). Used to pick the fridge and
	# medical cabinet by name rather than node path so cabin layout changes
	# between game versions don't break this.
	for cont_info in containers:
		var n = str(cont_info["name"]).to_lower()
		for patt in name_patterns:
			if patt in n:
				return cont_info["container"]
	return null

func _starter_find_generic_container(containers: Array, exclude: Array):
	# Returns the first generic cabinet/shelf (classification is empty) that
	# is NOT in the exclude list. Used to pick a spillover bucket for misc
	# items without re-using the fridge or medical cabinet.
	for cont_info in containers:
		var accepted = _classify_container(cont_info["name"])
		if accepted.size() != 0:
			continue
		if exclude.has(cont_info["container"]):
			continue
		return cont_info["container"]
	return null

func _starter_find_equipment_for_slot(slot_name: String, seen_names: Dictionary):
	# Returns the first Equipment item whose .slots array contains the
	# requested slot name. Skips items whose name we already placed so we
	# don't double-drop the same jacket twice across slot queries.
	if not items_by_category.has("Equipment"):
		return null
	for item_data in items_by_category["Equipment"]:
		if item_data == null:
			continue
		var slots = _safe(item_data, "slots", [])
		if not (slots is Array) or not slots.has(slot_name):
			continue
		var item_name = str(_safe(item_data, "name", ""))
		if seen_names.has(item_name):
			continue
		return item_data
	return null

func _starter_add_item(cont, item_data, qty: int) -> int:
	# Appends `qty` of item_data to cont.storage. Stackable items get one
	# SlotData with amount=qty. Non-stackable items get qty individual
	# SlotDatas of amount=1. Returns number of slot rows actually added
	# (so a zero return means the container refused every attempt).
	if cont == null or item_data == null or qty <= 0:
		return 0
	var size = _safe(item_data, "size", Vector2(1, 1))
	var stackable = bool(_safe(item_data, "stackable", false))
	var added := 0
	if stackable:
		if _container_can_fit(cont, size):
			var slot = SlotData.new()
			slot.itemData = item_data
			slot.amount = qty
			slot.condition = 100
			cont.storage.append(slot)
			added = 1
	else:
		for i in range(qty):
			if not _container_can_fit(cont, size):
				break
			var slot = SlotData.new()
			slot.itemData = item_data
			slot.amount = 1
			slot.condition = 100
			cont.storage.append(slot)
			added += 1
	if added > 0:
		cont.storaged = true
	return added

func _starter_spawn_world_at(item_data, world_pos: Vector3) -> bool:
	# Instantiates the item's PackedScene and plants it at world_pos.
	# Same backbone as _spawn_in_world() but accepts an explicit target
	# instead of defaulting to the player position. Returns false if the
	# scene isn't cached (e.g., Cash item with no pickup scene).
	if item_data == null:
		return false
	var scene: PackedScene = scene_for_item.get(item_data, null)
	if scene == null:
		return false
	var instance = scene.instantiate()
	if get_tree() == null or get_tree().current_scene == null:
		instance.queue_free()
		return false
	get_tree().current_scene.add_child(instance)
	if not is_instance_valid(instance):
		return false
	if instance is Node3D:
		instance.global_position = world_pos
	return true

func _find_cabin_furniture(name_substrings: Array) -> Node:
	# Locates a furniture root (Sofa_Leather_F, Table_Cabin_F, etc.) by
	# scanning the "Furniture" group — same approach as _get_cabin_containers.
	# The group stores each furniture's inner Furniture child node; its
	# .owner is the root Node3D whose name we match against. Returns the
	# first match so caller can read .global_position directly.
	if get_tree() == null:
		return null
	var patterns: Array = []
	for p in name_substrings:
		patterns.append(str(p).to_lower())
	var debug_seen: Array = []
	for inner in get_tree().get_nodes_in_group("Furniture"):
		if not is_instance_valid(inner):
			continue
		var root = inner.owner
		if root == null or not is_instance_valid(root):
			continue
		var root_name = str(root.name).to_lower()
		debug_seen.append(root_name)
		for patt in patterns:
			if patt in root_name:
				return root
	# Log each unique miss only once per session to avoid spamming the
	# output log when starter-stash runs on a map without cabin furniture.
	var miss_key = ",".join(patterns)
	if not _furniture_miss_logged.has(miss_key):
		_furniture_miss_logged[miss_key] = true
		_log("furniture lookup miss for %s — group contents: %s" % [patterns, debug_seen], "warning")
	return null

func _starter_sort_by_priority(items: Array, priority_keywords: Array) -> Array:
	# Returns a copy of `items` sorted so entries whose name contains an
	# earlier priority keyword come first. Ties broken by keyword index
	# then stable-ish order from the input array. Items with no keyword
	# match go to the back. Keeps the starter kit biased toward genuinely
	# useful picks (water, major heals, real rifles) without hardcoding
	# exact item names.
	var scored: Array = []
	var idx := 0
	for item_data in items:
		var n = str(_safe(item_data, "name", "")).to_lower()
		var score := 9999
		for i in range(priority_keywords.size()):
			if str(priority_keywords[i]) in n:
				score = i
				break
		scored.append({"item": item_data, "score": score, "idx": idx})
		idx += 1
	scored.sort_custom(func(a, b):
		if a["score"] != b["score"]:
			return a["score"] < b["score"]
		return a["idx"] < b["idx"]
	)
	var result: Array = []
	for entry in scored:
		result.append(entry["item"])
	return result


func _open_cabin_browser():
	if not ("shelter" in game_data and game_data.shelter):
		_show_toast("Must be in your cabin!", COL_NEGATIVE)
		return
	if cabin_browser_panel != null:
		_close_cabin_browser()
		return

	var containers = _get_cabin_containers()
	if containers.size() == 0:
		_show_toast("No containers found in cabin", COL_NEGATIVE)
		return

	# Hide the main cheat panel while browsing so it doesn't bleed through
	cabin_browser_was_cheat_visible = cheat_panel != null and cheat_panel.visible
	if cheat_panel != null:
		cheat_panel.visible = false

	# Opaque dark backdrop covering the whole screen
	cabin_browser_backdrop = ColorRect.new()
	cabin_browser_backdrop.color = Color(0, 0, 0, 0.78)
	cabin_browser_backdrop.anchor_left = 0.0
	cabin_browser_backdrop.anchor_top = 0.0
	cabin_browser_backdrop.anchor_right = 1.0
	cabin_browser_backdrop.anchor_bottom = 1.0
	cabin_browser_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(cabin_browser_backdrop)

	cabin_browser_panel = PanelContainer.new()
	cabin_browser_panel.add_theme_stylebox_override("panel", _make_tile_style(1.0))
	cabin_browser_panel.anchor_left = 0.06
	cabin_browser_panel.anchor_top = 0.03
	cabin_browser_panel.anchor_right = 0.94
	cabin_browser_panel.anchor_bottom = 0.97
	canvas.add_child(cabin_browser_panel)

	var main_vbox = VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_theme_constant_override("separation", 4)
	cabin_browser_panel.add_child(main_vbox)

	# Title
	_add_title(main_vbox, "CABIN STORAGE BROWSER")

	# Search bar
	var search_row = HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 4)
	main_vbox.add_child(search_row)

	cabin_browser_search = LineEdit.new()
	cabin_browser_search.placeholder_text = "Search items (type 2+ characters)..."
	cabin_browser_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cabin_browser_search.custom_minimum_size = Vector2(0, 32)
	cabin_browser_search.focus_mode = Control.FOCUS_CLICK
	if game_font:
		cabin_browser_search.add_theme_font_override("font", game_font)
	cabin_browser_search.add_theme_font_size_override("font_size", 14)
	cabin_browser_search.add_theme_color_override("font_color", COL_TEXT)
	cabin_browser_search.text_changed.connect(_on_cabin_browser_search)
	search_row.add_child(cabin_browser_search)

	var clear_btn = _make_styled_button("Clear", COL_DANGER_BTN, COL_DANGER_HVR)
	clear_btn.custom_minimum_size = Vector2(60, 32)
	clear_btn.pressed.connect(_on_cabin_browser_clear_search)
	search_row.add_child(clear_btn)

	# Filter buttons — centered row with fixed-width buttons
	var filter_outer = HBoxContainer.new()
	filter_outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_outer.alignment = BoxContainer.ALIGNMENT_CENTER
	main_vbox.add_child(filter_outer)

	var filter_label = Label.new()
	_style_label(filter_label, 11, COL_TEXT_DIM)
	filter_label.text = "Filter:"
	filter_outer.add_child(filter_label)

	var filter_row = HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 3)
	filter_outer.add_child(filter_row)

	cabin_browser_filter_btns.clear()
	for f_name in ["All", "Weapon", "Ammo", "Medical", "Food", "Equipment", "Attachment", "Misc"]:
		var fbtn = _make_styled_button(f_name, COL_BTN_NORMAL, COL_BTN_HOVER)
		fbtn.custom_minimum_size = Vector2(78, 26)
		fbtn.add_theme_font_size_override("font_size", 10)
		fbtn.add_theme_color_override("font_hover_color", COL_TEXT)
		fbtn.pressed.connect(_on_cabin_browser_filter.bind(f_name))
		filter_row.add_child(fbtn)
		cabin_browser_filter_btns[f_name] = fbtn
	_restyle_filter_buttons()

	# Sort buttons
	var sort_row = HBoxContainer.new()
	sort_row.add_theme_constant_override("separation", 3)
	main_vbox.add_child(sort_row)

	sort_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_add_info_label(sort_row, "Sort:", COL_TEXT_DIM, 11)
	cabin_browser_sort_btns.clear()
	for s_def in [["Name", "name"], ["Weight", "weight"], ["Type", "type"]]:
		var sbtn = _make_styled_button(s_def[0], COL_BTN_NORMAL, COL_BTN_HOVER)
		sbtn.custom_minimum_size = Vector2(64, 24)
		sbtn.add_theme_font_size_override("font_size", 10)
		sbtn.add_theme_color_override("font_hover_color", COL_TEXT)
		sbtn.pressed.connect(_on_cabin_browser_sort.bind(s_def[1]))
		sort_row.add_child(sbtn)
		cabin_browser_sort_btns[s_def[1]] = sbtn
	_restyle_sort_buttons()

	_add_separator(main_vbox)

	# Scrollable content area
	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(scroll)

	cabin_browser_vbox = VBoxContainer.new()
	cabin_browser_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cabin_browser_vbox.add_theme_constant_override("separation", 3)
	scroll.add_child(cabin_browser_vbox)

	_add_separator(main_vbox)
	_add_action_button(main_vbox, "CLOSE BROWSER", "_close_cabin_browser", COL_DANGER_BTN)

	_refresh_cabin_browser()

func _close_cabin_browser():
	# Repack all containers that were modified during browsing
	for cont in cabin_browser_dirty_containers:
		if is_instance_valid(cont):
			_force_container_repack(cont)
	cabin_browser_dirty_containers.clear()
	if cabin_browser_panel != null:
		cabin_browser_panel.queue_free()
		cabin_browser_panel = null
	if cabin_browser_backdrop != null:
		cabin_browser_backdrop.queue_free()
		cabin_browser_backdrop = null
	cabin_browser_vbox = null
	cabin_browser_search = null
	cabin_browser_selected.clear()
	cabin_browser_filter_btns.clear()
	cabin_browser_sort_btns.clear()
	# Restore the main cheat panel only if the cheat menu is still open
	# AND we're actually in sub-menu mode (v10.3.0 dashboard-first UX).
	# ESC/F5 close paths set cheat_open=false BEFORE calling _close_all_subpanels,
	# so gating on cheat_open prevents us from resurrecting the panel after a global close.
	if cheat_panel != null and cabin_browser_was_cheat_visible and cheat_open and submenu_mode:
		cheat_panel.visible = true
	cabin_browser_was_cheat_visible = false
	# User may have moved items between containers — invalidate cache so
	# the dashboard reflects the new state on the next refresh.
	_invalidate_cabin_counts_cache()

func _on_cabin_browser_search(_text: String):
	_refresh_cabin_browser()

func _on_cabin_browser_clear_search():
	if cabin_browser_search != null:
		cabin_browser_search.text = ""
	_refresh_cabin_browser()

func _on_cabin_browser_filter(filter_name: String):
	cabin_browser_filter = filter_name
	_restyle_filter_buttons()
	_refresh_cabin_browser()

func _on_cabin_browser_sort(sort_mode: String):
	cabin_browser_sort = sort_mode
	_restyle_sort_buttons()
	_refresh_cabin_browser()

func _restyle_filter_buttons():
	for f_name in cabin_browser_filter_btns:
		var btn = cabin_browser_filter_btns[f_name]
		if not is_instance_valid(btn):
			continue
		var is_active = f_name == cabin_browser_filter
		btn.add_theme_stylebox_override("normal", _make_button_flat(COL_SPAWN_BTN if is_active else COL_BTN_NORMAL))
		btn.add_theme_stylebox_override("hover", _make_button_flat(COL_SPAWN_HVR if is_active else COL_BTN_HOVER))
		btn.add_theme_color_override("font_color", COL_TEXT if is_active else COL_TEXT_DIM)

func _restyle_sort_buttons():
	for mode in cabin_browser_sort_btns:
		var btn = cabin_browser_sort_btns[mode]
		if not is_instance_valid(btn):
			continue
		var is_active = mode == cabin_browser_sort
		btn.add_theme_stylebox_override("normal", _make_button_flat(COL_SPAWN_BTN if is_active else COL_BTN_NORMAL))
		btn.add_theme_stylebox_override("hover", _make_button_flat(COL_SPAWN_HVR if is_active else COL_BTN_HOVER))
		btn.add_theme_color_override("font_color", COL_TEXT if is_active else COL_TEXT_DIM)

func _cabin_browser_item_matches_filter(item_data, search_query: String) -> bool:
	if item_data == null:
		return false
	var item_type = str(_safe(item_data, "type", ""))
	var item_name = str(_safe(item_data, "name", "")).to_lower()

	# Search filter
	if search_query.length() >= 2 and search_query not in item_name:
		return false

	# Type filter
	if cabin_browser_filter == "All":
		return true
	match cabin_browser_filter:
		"Weapon":
			return item_type == "Weapon"
		"Ammo":
			return item_type == "Ammo"
		"Medical":
			return item_type == "Medical"
		"Food":
			return item_type in ["Consumable", "Consumables", "Fish"]
		"Equipment":
			return item_type in ["Armor", "Helmet", "Rig", "Backpack", "Clothing", "Belt Pouch"]
		"Attachment":
			return item_type == "Attachment"
		"Misc":
			return item_type not in ["Weapon", "Ammo", "Medical", "Consumable", "Consumables", "Fish", "Armor", "Helmet", "Rig", "Backpack", "Clothing", "Belt Pouch", "Attachment"]
	return true

func _is_selected(_container, slot_data) -> bool:
	return cabin_browser_selected.has(slot_data)

func _on_cabin_browser_row_input(event: InputEvent, container, slot_data):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_toggle_selection(container, slot_data)
		get_viewport().set_input_as_handled()

func _toggle_selection(container, slot_data):
	if cabin_browser_selected.has(slot_data):
		cabin_browser_selected.erase(slot_data)
	else:
		cabin_browser_selected[slot_data] = container
	_refresh_cabin_browser()

func _clear_selection():
	cabin_browser_selected.clear()
	_refresh_cabin_browser()

func _refresh_cabin_browser():
	if cabin_browser_vbox == null:
		return
	for child in cabin_browser_vbox.get_children():
		child.queue_free()

	var containers = _get_cabin_containers()
	var search_query = ""
	if cabin_browser_search != null:
		search_query = cabin_browser_search.text.strip_edges().to_lower()

	var total_items := 0
	var shown_items := 0
	var has_selection = cabin_browser_selected.size() > 0

	# ── Selection action bar (sticky at top when items selected) ──
	if has_selection:
		var sel_bar = PanelContainer.new()
		var sel_style = StyleBoxFlat.new()
		sel_style.bg_color = Color(0.1, 0.25, 0.1, 0.8)
		sel_style.set_content_margin_all(8)
		sel_bar.add_theme_stylebox_override("panel", sel_style)
		sel_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cabin_browser_vbox.add_child(sel_bar)

		var sel_row = HBoxContainer.new()
		sel_row.add_theme_constant_override("separation", 8)
		sel_bar.add_child(sel_row)

		var sel_label = Label.new()
		_style_label(sel_label, 14, COL_POSITIVE)
		sel_label.text = "%d item%s selected — click a container to move them, or:" % [cabin_browser_selected.size(), "s" if cabin_browser_selected.size() != 1 else ""]
		sel_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sel_row.add_child(sel_label)

		var take_sel_btn = _make_styled_button("TAKE TO INVENTORY", COL_SPAWN_BTN, COL_SPAWN_HVR)
		take_sel_btn.custom_minimum_size = Vector2(140, 30)
		take_sel_btn.add_theme_font_size_override("font_size", 11)
		take_sel_btn.pressed.connect(_cabin_browser_take_selected)
		sel_row.add_child(take_sel_btn)

		var clear_sel_btn = _make_styled_button("DESELECT ALL", COL_DANGER_BTN, COL_DANGER_HVR)
		clear_sel_btn.custom_minimum_size = Vector2(100, 30)
		clear_sel_btn.add_theme_font_size_override("font_size", 11)
		clear_sel_btn.pressed.connect(_clear_selection)
		sel_row.add_child(clear_sel_btn)

	for cont_info in containers:
		var cont = cont_info["container"]
		var cname = cont_info["name"]
		var total_cells = int(cont_info["size"].x) * int(cont_info["size"].y)
		var storage = cont.storage if "storage" in cont and cont.storage is Array else []

		total_items += storage.size()

		# Collect matching items
		var matching := []
		for slot_data in storage:
			if slot_data == null or slot_data.itemData == null:
				continue
			if _cabin_browser_item_matches_filter(slot_data.itemData, search_query):
				matching.append(slot_data)

		# Sort
		matching.sort_custom(func(a, b):
			match cabin_browser_sort:
				"weight":
					return _safe(a.itemData, "weight", 0.0) > _safe(b.itemData, "weight", 0.0)
				"type":
					return str(_safe(a.itemData, "type", "")) < str(_safe(b.itemData, "type", ""))
				_:
					return str(_safe(a.itemData, "name", "")).to_lower() < str(_safe(b.itemData, "name", "")).to_lower()
		)

		# Skip empty containers when filtering
		if matching.size() == 0 and (search_query.length() >= 2 or cabin_browser_filter != "All"):
			continue

		# ── Container card header ──
		var card = PanelContainer.new()
		var card_style = StyleBoxFlat.new()
		card_style.bg_color = Color(0.11, 0.11, 0.13, 0.85)
		card_style.border_color = Color(0.28, 0.28, 0.32, 0.9)
		card_style.border_width_left = 1
		card_style.border_width_right = 1
		card_style.border_width_top = 1
		card_style.border_width_bottom = 1
		card_style.corner_radius_top_left = 3
		card_style.corner_radius_top_right = 3
		card_style.corner_radius_bottom_left = 3
		card_style.corner_radius_bottom_right = 3
		card_style.content_margin_left = 10
		card_style.content_margin_right = 10
		card_style.content_margin_top = 8
		card_style.content_margin_bottom = 8
		card.add_theme_stylebox_override("panel", card_style)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cabin_browser_vbox.add_child(card)

		var card_vbox = VBoxContainer.new()
		card_vbox.add_theme_constant_override("separation", 4)
		card.add_child(card_vbox)

		# Header row: name + stats + action buttons
		var header_row = HBoxContainer.new()
		header_row.add_theme_constant_override("separation", 10)
		card_vbox.add_child(header_row)

		var name_label = Label.new()
		_style_label(name_label, 16, COL_TEXT if storage.size() > 0 else COL_TEXT_DIM)
		name_label.text = cname
		header_row.add_child(name_label)

		# Inline empty/subtitle tag (no floating label in middle of card)
		if storage.size() == 0:
			var empty_tag = Label.new()
			_style_label(empty_tag, 11, COL_TEXT_DIM)
			empty_tag.text = "(empty)"
			header_row.add_child(empty_tag)
		elif matching.size() == 0:
			var nomatch_tag = Label.new()
			_style_label(nomatch_tag, 11, COL_TEXT_DIM)
			nomatch_tag.text = "(no matches)"
			header_row.add_child(nomatch_tag)

		var spacer = Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header_row.add_child(spacer)

		# Item count badge
		var badge = Label.new()
		_style_label(badge, 12, COL_POSITIVE if storage.size() > 0 else COL_TEXT_DIM)
		if matching.size() != storage.size():
			badge.text = "%d / %d items" % [matching.size(), storage.size()]
		else:
			badge.text = "%d items" % storage.size()
		header_row.add_child(badge)

		var slots_label = Label.new()
		_style_label(slots_label, 11, COL_TEXT_DIM)
		slots_label.text = "· %d slots" % total_cells
		header_row.add_child(slots_label)

		# MOVE HERE button (when items selected from other containers)
		if has_selection:
			var sel_from_other := 0
			for sel_cont in cabin_browser_selected.values():
				if sel_cont != cont:
					sel_from_other += 1
			if sel_from_other > 0:
				var move_btn = _make_styled_button("MOVE %d HERE" % sel_from_other, Color(0.15, 0.25, 0.45, 0.6), Color(0.2, 0.35, 0.55, 0.7))
				move_btn.custom_minimum_size = Vector2(110, 28)
				move_btn.add_theme_font_size_override("font_size", 10)
				move_btn.pressed.connect(_cabin_browser_move_to.bind(cont))
				header_row.add_child(move_btn)

		# Select All button
		if matching.size() > 0:
			var sel_all_btn = _make_styled_button("SELECT ALL", COL_BTN_NORMAL, COL_BTN_HOVER)
			sel_all_btn.custom_minimum_size = Vector2(82, 26)
			sel_all_btn.add_theme_font_size_override("font_size", 9)
			sel_all_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
			sel_all_btn.pressed.connect(_cabin_browser_select_all.bind(cont, matching))
			header_row.add_child(sel_all_btn)

		# ── Item rows (PanelContainer — Button isn't a Container and won't lay out children) ──
		for slot_data in matching:
			shown_items += 1
			var item_data = slot_data.itemData
			var selected = _is_selected(cont, slot_data)

			var row_panel = PanelContainer.new()
			row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var row_style = StyleBoxFlat.new()
			row_style.bg_color = Color(0.1, 0.3, 0.1, 0.45) if selected else Color(0.06, 0.06, 0.08, 0.55)
			row_style.border_color = Color(0.3, 0.55, 0.3, 0.9) if selected else Color(0.18, 0.18, 0.22, 0.9)
			row_style.border_width_left = 1
			row_style.border_width_right = 1
			row_style.border_width_top = 1
			row_style.border_width_bottom = 1
			row_style.corner_radius_top_left = 2
			row_style.corner_radius_top_right = 2
			row_style.corner_radius_bottom_left = 2
			row_style.corner_radius_bottom_right = 2
			row_style.content_margin_left = 8
			row_style.content_margin_right = 8
			row_style.content_margin_top = 5
			row_style.content_margin_bottom = 5
			row_panel.add_theme_stylebox_override("panel", row_style)
			row_panel.mouse_filter = Control.MOUSE_FILTER_STOP
			row_panel.gui_input.connect(_on_cabin_browser_row_input.bind(cont, slot_data))
			card_vbox.add_child(row_panel)

			var item_row = HBoxContainer.new()
			item_row.add_theme_constant_override("separation", 8)
			row_panel.add_child(item_row)

			var sel_bar_item = ColorRect.new()
			sel_bar_item.custom_minimum_size = Vector2(3, 0)
			sel_bar_item.size_flags_vertical = Control.SIZE_EXPAND_FILL
			sel_bar_item.color = COL_POSITIVE if selected else Color(1, 1, 1, 0.05)
			sel_bar_item.mouse_filter = Control.MOUSE_FILTER_IGNORE
			item_row.add_child(sel_bar_item)

			var icon_tex = _safe(item_data, "icon", null)
			if icon_tex != null and icon_tex is Texture2D:
				var icon_rect = TextureRect.new()
				icon_rect.texture = icon_tex
				icon_rect.custom_minimum_size = Vector2(36, 36)
				icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
				icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
				item_row.add_child(icon_rect)

			var info_col = VBoxContainer.new()
			info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			info_col.add_theme_constant_override("separation", 0)
			info_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
			item_row.add_child(info_col)

			var item_name_label = Label.new()
			_style_label(item_name_label, 13, COL_POSITIVE if selected else COL_TEXT)
			item_name_label.text = str(_safe(item_data, "name", "?"))
			item_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			info_col.add_child(item_name_label)

			var type_line = Label.new()
			_style_label(type_line, 10, COL_TEXT_DIM)
			var type_parts := []
			type_parts.append(str(_safe(item_data, "type", "")))
			type_parts.append("%.1fkg" % _safe(item_data, "weight", 0.0))
			var amount = _safe(slot_data, "amount", 0)
			if amount > 0:
				type_parts.append("x%d" % amount)
			var condition = _safe(slot_data, "condition", 100)
			if _safe(item_data, "showCondition", false):
				type_parts.append("%d%%" % condition)
			type_line.text = " | ".join(type_parts)
			type_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			info_col.add_child(type_line)

			var take_btn = _make_styled_button("TAKE", COL_SPAWN_BTN, COL_SPAWN_HVR)
			take_btn.custom_minimum_size = Vector2(52, 30)
			take_btn.add_theme_font_size_override("font_size", 10)
			take_btn.pressed.connect(_cabin_browser_take_item.bind(cont, slot_data))
			item_row.add_child(take_btn)

	# ── Summary footer ──
	_add_separator(cabin_browser_vbox)
	var summary = Label.new()
	_style_label(summary, 11, COL_TEXT_DIM)
	if search_query.length() >= 2 or cabin_browser_filter != "All":
		summary.text = "Showing %d of %d items across %d containers  |  Click rows to select, then move or take" % [shown_items, total_items, containers.size()]
	else:
		summary.text = "%d items across %d containers  |  Click rows to select, then move or take" % [total_items, containers.size()]
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cabin_browser_vbox.add_child(summary)

func _cabin_browser_select_all(container, items: Array):
	for slot_data in items:
		if not cabin_browser_selected.has(slot_data):
			cabin_browser_selected[slot_data] = container
	_refresh_cabin_browser()

func _cabin_browser_take_item(container, slot_data):
	var interface = _get_interface()
	if interface == null:
		_show_toast("Interface not found", COL_NEGATIVE)
		return
	if interface.AutoStack(slot_data, interface.inventoryGrid):
		interface.UpdateStats(false)
	elif interface.Create(slot_data, interface.inventoryGrid, false):
		interface.UpdateStats(false)
	else:
		_show_toast("Inventory full", COL_NEGATIVE)
		return
	if "storage" in container and container.storage is Array:
		container.storage.erase(slot_data)
		cabin_browser_dirty_containers[container] = true
	cabin_browser_selected.erase(slot_data)
	_show_toast("Took: " + str(_safe(slot_data.itemData, "name", "?")))
	_refresh_cabin_browser()

func _cabin_browser_take_selected():
	var interface = _get_interface()
	if interface == null:
		_show_toast("Interface not found", COL_NEGATIVE)
		return
	var taken := 0
	# Snapshot keys so we can mutate the dict during iteration.
	for sd in cabin_browser_selected.keys():
		var cont = cabin_browser_selected[sd]
		if interface.AutoStack(sd, interface.inventoryGrid):
			interface.UpdateStats(false)
		elif interface.Create(sd, interface.inventoryGrid, false):
			interface.UpdateStats(false)
		else:
			continue
		if "storage" in cont and cont.storage is Array:
			cont.storage.erase(sd)
			cabin_browser_dirty_containers[cont] = true
		taken += 1
	cabin_browser_selected.clear()
	if taken > 0:
		_show_toast("Took %d items to inventory" % taken)
	else:
		_show_toast("Inventory full", COL_NEGATIVE)
	_refresh_cabin_browser()

func _cabin_browser_move_to(target_container):
	var capacity = _get_container_capacity(target_container)
	var current_fill = target_container.storage.size() if "storage" in target_container and target_container.storage is Array else 0
	var moved := 0
	var skipped_full := 0
	# Snapshot keys so we can mutate during iteration.
	for sd in cabin_browser_selected.keys():
		var src_cont = cabin_browser_selected[sd]
		if src_cont == target_container:
			continue
		if capacity > 0 and current_fill + moved >= capacity:
			skipped_full += 1
			continue
		# Remove from source
		if "storage" in src_cont and src_cont.storage is Array:
			src_cont.storage.erase(sd)
			cabin_browser_dirty_containers[src_cont] = true
		# Add to target — SlotData.Update() defensively copies state
		# so the source slot reference can't leak grid position data.
		var new_slot = SlotData.new()
		new_slot.Update(sd)
		target_container.storage.append(new_slot)
		cabin_browser_dirty_containers[target_container] = true
		cabin_browser_selected.erase(sd)
		moved += 1
	if moved > 0:
		var target_name = target_container.containerName if "containerName" in target_container else "container"
		if skipped_full > 0:
			_show_toast("Moved %d to %s (%d skipped — target full)" % [moved, target_name, skipped_full], COL_NEGATIVE)
		else:
			_show_toast("Moved %d items to %s" % [moved, target_name])
	elif skipped_full > 0:
		_show_toast("Target container full", COL_NEGATIVE)
	_refresh_cabin_browser()

func _get_container_capacity(container) -> int:
	# Look up capacity via the canonical _get_cabin_containers() scan
	# so we respect whatever sizing logic that function applies.
	for info in _get_cabin_containers():
		if info["container"] == container:
			return int(info["size"].x) * int(info["size"].y)
	return 0


# ================================================================
#  SECURE CONTAINER — soft-dependency integration (modworkshop #56154)
# ================================================================
# Same null-guard pattern as Cash System below. If Secure Container
# is not installed, _get_secure_container() returns null and the
# catalog scan skips the injection. Zero impact on users without the
# mod — they never see these items and the spawner works as before.

func _get_secure_container():
	# Returns the SecureContainer autoload if installed and valid.
	if not Engine.has_meta("SecureContainer"):
		return null
	var sc = Engine.get_meta("SecureContainer", null)
	if sc == null or not is_instance_valid(sc):
		return null
	return sc

func _secure_container_available() -> bool:
	var sc = _get_secure_container()
	if sc == null:
		return false
	# The mod stores its ItemData resources in _item_data dict. If that
	# dict is missing or empty, the mod hasn't finished initializing yet.
	if not ("_item_data" in sc):
		return false
	if sc._item_data == null or sc._item_data.is_empty():
		return false
	return true


# ================================================================
#  CASH SYSTEM — soft-dependency integration (modworkshop #55951)
# ================================================================
# Every entry point is null-guarded. If Cash System is not installed,
# not initialized, its API changed, or the autoload was freed during
# a scene transition, these functions all return safely without any
# effect on the base mod. The UI section is hidden entirely when the
# mod is absent, so users who don't have it see zero difference.

func _get_cash_main():
	# Returns the CashMain autoload if it's installed, valid, and ready.
	# Returns null in every failure mode — callers must handle null.
	# NOTE: No scene-tree guard here. Engine.has_meta() is process-global
	# and safe to call during our _ready() (before the main scene loads),
	# which is critical because the dashboard builder runs at that time.
	# CashMain's own AddCash/_get_interface methods are null-safe, so any
	# runtime call we make through cm.* also handles scene transitions.
	if not Engine.has_meta("CashMain"):
		return null
	var cm = Engine.get_meta("CashMain", null)
	if cm == null or not is_instance_valid(cm):
		return null
	return cm

func _cash_system_available() -> bool:
	var cm = _get_cash_main()
	if cm == null:
		return false
	# Verify the core API methods actually exist. If the cash mod
	# changes its public API in a future version, we fail gracefully
	# instead of crashing.
	return cm.has_method("AddCash") and cm.has_method("CountCash") and cm.has_method("RemoveAllCash")

func _cash_ready_to_use() -> bool:
	# Stronger check: API present AND cash_item_data loaded. Cash mod
	# initializes cash_item_data asynchronously in _ready(), so there's
	# a brief window on startup where the API exists but AddCash would
	# fail. We gate on that too.
	var cm = _get_cash_main()
	if cm == null or not _cash_system_available():
		return false
	if not ("cash_item_data" in cm):
		return false
	if cm.cash_item_data == null:
		return false
	return true

func _format_cash_amount(n: int) -> String:
	# Thousands separator without relying on locale.
	var s = str(n)
	var negative = s.begins_with("-")
	if negative:
		s = s.substr(1)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count == 3 and i > 0:
			out = "," + out
			count = 0
	return ("-" + out) if negative else out

func _cash_add(amount: int):
	if amount <= 0:
		return
	var cm = _get_cash_main()
	if cm == null:
		_show_toast("Cash System not installed", COL_NEGATIVE)
		return
	if not _cash_ready_to_use():
		_show_toast("Cash System still initializing", COL_NEGATIVE)
		return
	# AddCash is a dynamic call — a future Cash System version could change
	# the return type. Only treat an explicit `true` bool as success;
	# anything else (null, int, changed API) falls through as failure.
	var result = cm.AddCash(amount)
	if typeof(result) == TYPE_BOOL and result:
		_show_toast("Added €%s" % _format_cash_amount(amount))
	else:
		_show_toast("Inventory full", COL_NEGATIVE)


# ================================================================
#  VACUUM — collect loose floor items
# ================================================================

# ================================================================
#  RETURN TO CABIN
# ================================================================

var confirm_panel: PanelContainer = null

# ── Cabin Browser ──────────────────────────────────────────────
var cabin_browser_panel: PanelContainer = null
var cabin_browser_backdrop: ColorRect = null
var cabin_browser_vbox: VBoxContainer = null
var cabin_browser_search: LineEdit = null
var cabin_browser_filter := "All"
var cabin_browser_sort := "name"
# slot_data (Object) → container (Object). Dict for O(1) lookup from
# refresh's inner loop (was O(n²) with the previous Array-of-dicts model).
var cabin_browser_selected := {}
var cabin_browser_dirty_containers := {}  # Set: container → true (repacked at close)
var cabin_browser_was_cheat_visible := false
# name → Button refs so filter/sort changes can restyle in place
# instead of tearing down and rebuilding the whole panel.
var cabin_browser_filter_btns := {}
var cabin_browser_sort_btns := {}

func _action_return_to_cabin_prompt():
	# Check if already in cabin
	if "shelter" in game_data and game_data.shelter:
		_show_toast("You're already in your cabin!")
		return
	# Check if a shelter save exists
	var loader = get_node_or_null("/root/Loader")
	if loader == null:
		_show_toast("Loader not found", COL_NEGATIVE)
		return
	var shelter_name = loader.ValidateShelter()
	if shelter_name == "":
		_show_toast("No shelter unlocked yet", COL_NEGATIVE)
		return
	# Show confirmation dialog
	_show_confirm("Return to " + shelter_name + "?", "Your current map progress will be saved first.", _action_return_to_cabin_confirmed)

func _action_return_to_cabin_confirmed():
	_close_confirm()
	_close_cheat()

	var loader = get_node_or_null("/root/Loader")
	if loader == null:
		_show_toast("Loader not found", COL_NEGATIVE)
		return

	var shelter_name = loader.ValidateShelter()
	if shelter_name == "":
		_show_toast("No shelter found", COL_NEGATIVE)
		return

	# Save current state before traveling
	if "SaveCharacter" in loader:
		loader.SaveCharacter()
	if "SaveWorld" in loader:
		loader.SaveWorld()
	# If currently in a shelter, save it too
	if "shelter" in game_data and game_data.shelter:
		var current_map = str(_safe(game_data, "currentMap", ""))
		if current_map != "" and "SaveShelter" in loader:
			loader.SaveShelter(current_map)

	# Travel to the shelter
	_log("Returning to shelter: %s" % shelter_name)
	loader.LoadScene(shelter_name)

func _show_confirm(title: String, message: String, confirm_callable: Callable):
	_close_confirm()
	confirm_panel = PanelContainer.new()
	confirm_panel.add_theme_stylebox_override("panel", _make_tile_style(0.92))
	confirm_panel.anchor_left = 0.3
	confirm_panel.anchor_top = 0.35
	confirm_panel.anchor_right = 0.7
	confirm_panel.anchor_bottom = 0.65
	canvas.add_child(confirm_panel)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	confirm_panel.add_child(vbox)

	var spacer_top = Control.new()
	spacer_top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer_top)

	_add_title(vbox, title)
	_add_info_label(vbox, message, COL_TEXT_DIM, 13)
	_add_separator(vbox)

	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var yes_btn = _make_styled_button("YES — CONFIRM", COL_SPAWN_BTN, COL_SPAWN_HVR)
	yes_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	yes_btn.custom_minimum_size = Vector2(0, 40)
	yes_btn.add_theme_font_size_override("font_size", 14)
	yes_btn.pressed.connect(confirm_callable)
	btn_row.add_child(yes_btn)

	var no_btn = _make_styled_button("CANCEL", COL_DANGER_BTN, COL_DANGER_HVR)
	no_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	no_btn.custom_minimum_size = Vector2(0, 40)
	no_btn.add_theme_font_size_override("font_size", 14)
	no_btn.pressed.connect(_close_confirm)
	btn_row.add_child(no_btn)

	var spacer_bottom = Control.new()
	spacer_bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer_bottom)

func _close_confirm():
	if confirm_panel != null:
		confirm_panel.queue_free()
		confirm_panel = null


# ================================================================
#  DELETE FLOOR ITEMS
# ================================================================

func _action_delete_floor_prompt():
	if not ("shelter" in game_data and game_data.shelter):
		_show_toast("Must be in your cabin!", COL_NEGATIVE)
		return
	var floor_items = _get_floor_items()
	if floor_items.size() == 0:
		_show_toast("No loose items found")
		return
	_show_confirm(
		"Delete %d floor items?" % floor_items.size(),
		"This will permanently destroy all loose items on the ground. Cannot be undone.",
		_action_delete_floor_confirmed
	)

func _action_delete_floor_confirmed():
	_close_confirm()
	var floor_items = _get_floor_items()
	var count := 0
	for item in floor_items:
		if is_instance_valid(item):
			item.queue_free()
			count += 1
	if count > 0:
		_show_toast("Deleted %d floor items" % count)
	else:
		_show_toast("No items to delete")


func _get_floor_items() -> Array:
	# Find all loose Pickup nodes on the FLOOR only
	# Items above 0.6m are likely sitting on furniture (tables, shelves, counters)
	var result := []
	if get_tree() == null:
		return result
	var items = get_tree().get_nodes_in_group("Item")
	for item in items:
		if not is_instance_valid(item):
			continue
		if not item is RigidBody3D:
			continue
		if not "slotData" in item or item.slotData == null:
			continue
		if item.slotData.itemData == null:
			continue
		if not item.global_position.is_finite():
			continue
		if item.global_position.y < -10.0:
			continue
		# Skip items on furniture (above floor level)
		if item.global_position.y > FLOOR_HEIGHT_MAX:
			continue
		result.append(item)
	return result

func _action_vacuum_floor():
	if not ("shelter" in game_data and game_data.shelter):
		_show_toast("Must be in your cabin!", COL_NEGATIVE)
		return

	var interface = _get_interface()
	if interface == null:
		_show_toast("Interface not found", COL_NEGATIVE)
		return

	var floor_items = _get_floor_items()
	if floor_items.size() == 0:
		_show_toast("No loose items found")
		return

	var collected := 0
	var failed := 0
	for item in floor_items:
		if not is_instance_valid(item):
			continue
		# Use the same logic as the game's Pickup.Interact()
		if interface.AutoStack(item.slotData, interface.inventoryGrid):
			interface.UpdateStats(false)
			item.queue_free()
			collected += 1
		elif interface.Create(item.slotData, interface.inventoryGrid, false):
			interface.UpdateStats(false)
			item.queue_free()
			collected += 1
		else:
			failed += 1

	if collected > 0:
		var msg = "Collected %d items from floor" % collected
		if failed > 0:
			msg += " (%d couldn't fit)" % failed
		_show_toast(msg)
	else:
		_show_toast("Inventory full — no items collected", COL_NEGATIVE)

func _action_vacuum_and_stash():
	if not ("shelter" in game_data and game_data.shelter):
		_show_toast("Must be in your cabin!", COL_NEGATIVE)
		return

	var interface = _get_interface()
	if interface == null:
		_show_toast("Interface not found", COL_NEGATIVE)
		return

	var containers = _get_cabin_containers()
	var floor_items = _get_floor_items()

	if floor_items.size() == 0 and containers.size() == 0:
		_show_toast("Nothing to clean up")
		return

	# Phase 1: Try to stash floor items DIRECTLY into containers
	var stashed_direct := 0
	var remaining_items := []

	if containers.size() > 0:
		for item in floor_items:
			if not is_instance_valid(item):
				continue
			if _stash_single_item(item.slotData, containers):
				item.queue_free()
				stashed_direct += 1
			else:
				remaining_items.append(item)
	else:
		remaining_items = floor_items

	# Phase 2: Remaining floor items go to inventory
	var collected := 0
	for item in remaining_items:
		if not is_instance_valid(item):
			continue
		if interface.AutoStack(item.slotData, interface.inventoryGrid):
			interface.UpdateStats(false)
			item.queue_free()
			collected += 1
		elif interface.Create(item.slotData, interface.inventoryGrid, false):
			interface.UpdateStats(false)
			item.queue_free()
			collected += 1

	# Phase 3: Stash inventory items into containers (full 3-pass via helper)
	var stashed_inv := 0
	if containers.size() > 0:
		var inv_grid = interface.inventoryGrid
		if is_instance_valid(inv_grid):
			var inv_items := []
			for child in inv_grid.get_children():
				if not is_instance_valid(child) or not "slotData" in child:
					continue
				if child.slotData == null or child.slotData.itemData == null:
					continue
				if "equipped" in child and child.equipped:
					continue
				inv_items.append(child)

			for item in inv_items:
				if not is_instance_valid(item):
					continue
				if _stash_single_item(item.slotData, containers):
					inv_grid.Pick(item)
					item.queue_free()
					stashed_inv += 1

	# Force all modified containers to repack on next open
	if stashed_direct > 0 or stashed_inv > 0:
		for cont_info in containers:
			_force_container_repack(cont_info["container"])

	interface.UpdateStats(false)

	# Build summary
	var parts := []
	if stashed_direct > 0:
		parts.append("%d floor items to containers" % stashed_direct)
	if collected > 0:
		parts.append("%d to inventory" % collected)
	if stashed_inv > 0:
		parts.append("%d from inventory to containers" % stashed_inv)
	var total = stashed_direct + collected + stashed_inv
	if total > 0:
		_show_toast("Cleaned: " + ", ".join(parts))
	else:
		_show_toast("Nothing could be moved")


# ================================================================
#  KEYBINDS — persistence, matching, capture, dispatch, UI
# ================================================================
# Bindings persist in user://cheatmenu_binds.cfg (resolves to the
# game's userdata dir — %APPDATA%\Road to Vostok\ on Windows).
# Dict-based matching deliberately avoids polluting the engine's
# InputMap, so we never risk clashing with RTV's own actions.

func _apply_default_keybinds():
	# v10.6.1 — Ship with NO preset keybinds per community request
	# (soybean_alien: "please remove the Fly Mode and Heal keybinds and
	# let the keybinds be mapped by user"). Existing users who already
	# have F7/F8 bound from a prior session keep them via the persisted
	# cheatmenu_binds.cfg → _load_keybinds path; only fresh installs
	# start empty. Every action is user-map-your-own now.
	keybinds = {}

func _load_keybinds():
	var cfg := ConfigFile.new()
	var err := cfg.load(KEYBIND_CONFIG_PATH)
	if err != OK:
		_apply_default_keybinds()
		return
	var loaded := {}
	for action_name in BINDABLE_ACTIONS.keys():
		var bind = cfg.get_value("binds", action_name, null)
		# v10.5.1 — strict shape + TYPE validation. ConfigFile values
		# are Variant; hand-edited junk ("key = ohno") would coerce
		# through int() to 0 and stomp every unset F-key bind to
		# keycode 0, silently colliding. Type-check each field against
		# its expected primitive before accepting the bind.
		if not (bind is Dictionary):
			continue
		if not (bind.has("key") and bind.has("device")):
			continue
		if typeof(bind["key"]) != TYPE_INT or typeof(bind["device"]) != TYPE_INT:
			_log("Dropping malformed bind '%s' — non-int key/device" % action_name, "warning")
			continue
		# Modifier flags default to false if missing, but if present
		# they must be bools. A malformed cfg with "ctrl = true" as a
		# string would match truthy and silently require holding Ctrl
		# to fire any bound action.
		for mod_key in ["ctrl", "shift", "alt"]:
			if bind.has(mod_key) and typeof(bind[mod_key]) != TYPE_BOOL:
				bind[mod_key] = false
		loaded[action_name] = bind
	if loaded.is_empty():
		_apply_default_keybinds()
	else:
		keybinds = loaded

func _save_keybinds():
	# v10.5.1 — if the dict is empty we'd overwrite the cfg with no
	# entries, which on the next load falls through to defaults and
	# loses the user's customizations. This can happen on a tight
	# startup race where WM_CLOSE_REQUEST arrives before _load_keybinds
	# has populated the dict. Better to save nothing than to erase.
	if keybinds.is_empty():
		return
	var cfg := ConfigFile.new()
	for action_name in keybinds.keys():
		cfg.set_value("binds", action_name, keybinds[action_name])
	var err := cfg.save(KEYBIND_CONFIG_PATH)
	if err != OK:
		_log("Failed to save keybinds (err %d) to %s" % [err, KEYBIND_CONFIG_PATH], "warning")
		_show_toast("Failed to save keybinds (err %d)" % err, COL_NEGATIVE)


# ── Vitals Tuner persistence (v10.3.0) ─────────────────────────
# Keeps tuner state in its own cfg file so the existing keybind /
# favorites / real-time cfgs stay pristine. On first launch we check
# for a legacy VitalsTuner.vmz cfg and port it forward transparently.

func _tuner_request_save():
	_tuner_pending_save = true
	_tuner_save_timer = TUNER_DEBOUNCE_SAVE_SEC
	# v10.6.0 — also dirty the active profile so the tuner mutation
	# propagates through dual-write. Single choke-point covers all 5
	# tuner mutation call-sites.
	if not _profile_suspend_hud:
		_profile_mark_dirty()

func _tuner_load_cfg():
	var cfg := ConfigFile.new()
	if cfg.load(TUNER_CONFIG_PATH) == OK:
		_tuner_apply_cfg(cfg)
		return
	# First run: try to port the legacy standalone mod's cfg.
	var legacy := ConfigFile.new()
	if legacy.load(TUNER_LEGACY_CFG_PATH) == OK:
		_tuner_apply_legacy_cfg(legacy)
		_tuner_save_cfg()
		_log("Migrated VitalsTuner v0.1.x settings → cheatmenu_vitals_tuner.cfg")
	# Otherwise: fresh install, defaults from _tuner_init_state stand.

# Applies a native (v10.3.0+) Tuner cfg. The cfg layout matches
# _tuner_save_cfg below: [tuner] for scalars, one [tuner.X] section
# per per-vital or per-condition map. All float reads are clamped to
# safe ranges — defends against hand-edited cfg files.
func _tuner_apply_cfg(cfg: ConfigFile):
	var schema: int = int(cfg.get_value("tuner", "schema_version", 1))
	if schema > TUNER_CFG_SCHEMA_VERSION:
		_log("Tuner cfg schema %d newer than runtime (%d) — loading defensively" \
				% [schema, TUNER_CFG_SCHEMA_VERSION], "warning")
	cheat_tuner_enabled = bool(cfg.get_value("tuner", "enabled", false))
	for v in TUNER_VITALS:
		tuner_drain_mult[v] = clampf(float(cfg.get_value("tuner.drain_mult", v, 1.0)),
				TUNER_MULT_MIN, TUNER_MULT_MAX)
		tuner_regen_mult[v] = clampf(float(cfg.get_value("tuner.regen_mult", v, 1.0)),
				TUNER_MULT_MIN, TUNER_MULT_MAX)
		tuner_freeze[v] = bool(cfg.get_value("tuner.freeze", v, false))
		tuner_freeze_val[v] = clampf(float(cfg.get_value("tuner.freeze_val", v, TUNER_VITAL_MAX)),
				TUNER_VITAL_MIN, TUNER_VITAL_MAX)
		tuner_lock_max[v] = bool(cfg.get_value("tuner.lock_max", v, false))
	for c in TUNER_CONDITIONS:
		tuner_immune[c] = bool(cfg.get_value("tuner.immune", c, false))

# Applies the legacy VitalsTuner.vmz cfg layout (flat sections with
# `drain_<vital>` / `freeze_<vital>` / `lock_max_<vital>` prefixed keys
# — see VitalsTuner/Main.gd v0.1.7 _save_cfg). Only called once, during
# first-run migration; subsequent sessions use the native layout.
func _tuner_apply_legacy_cfg(cfg: ConfigFile):
	cheat_tuner_enabled = bool(cfg.get_value("general", "enabled", false))
	for v in TUNER_VITALS:
		tuner_drain_mult[v] = clampf(float(cfg.get_value("multipliers", "drain_" + v, 1.0)),
				TUNER_MULT_MIN, TUNER_MULT_MAX)
		tuner_regen_mult[v] = clampf(float(cfg.get_value("multipliers", "regen_" + v, 1.0)),
				TUNER_MULT_MIN, TUNER_MULT_MAX)
		tuner_freeze[v] = bool(cfg.get_value("flags", "freeze_" + v, false))
		tuner_freeze_val[v] = clampf(float(cfg.get_value("flags", "freeze_val_" + v, TUNER_VITAL_MAX)),
				TUNER_VITAL_MIN, TUNER_VITAL_MAX)
		tuner_lock_max[v] = bool(cfg.get_value("flags", "lock_max_" + v, false))
	for c in TUNER_CONDITIONS:
		tuner_immune[c] = bool(cfg.get_value("immunities", c, false))

func _tuner_save_cfg():
	# v10.5.1 — guard deferred invocation on a torn-down autoload.
	# _tuner_save_cfg is reachable via call_deferred from the debounced
	# dirty-flag flush in _process AND from the WM_CLOSE_REQUEST hook.
	# Three failure modes to guard:
	#  1. _exit_tree fires between the call_deferred dispatch and the
	#     actual invocation → is_inside_tree() returns false.
	#  2. WM_CLOSE arrives during mod startup before _tuner_init_state
	#     has populated tuner_drain_mult — the TUNER_VITALS loop below
	#     would crash with a key-not-found.
	#  3. Normal debounced-save path when everything is healthy.
	if not is_inside_tree():
		return
	if tuner_drain_mult.is_empty():
		return  # startup race: state not yet seeded, nothing to persist
	var cfg := ConfigFile.new()
	cfg.set_value("tuner", "schema_version", TUNER_CFG_SCHEMA_VERSION)
	cfg.set_value("tuner", "enabled", cheat_tuner_enabled)
	for v in TUNER_VITALS:
		cfg.set_value("tuner.drain_mult", v, tuner_drain_mult[v])
		cfg.set_value("tuner.regen_mult", v, tuner_regen_mult[v])
		cfg.set_value("tuner.freeze", v, tuner_freeze[v])
		cfg.set_value("tuner.freeze_val", v, tuner_freeze_val[v])
		cfg.set_value("tuner.lock_max", v, tuner_lock_max[v])
	for c in TUNER_CONDITIONS:
		cfg.set_value("tuner.immune", c, tuner_immune[c])
	var err := cfg.save(TUNER_CONFIG_PATH)
	if err != OK:
		_log("Failed to save Tuner cfg (err %d) to %s" % [err, TUNER_CONFIG_PATH], "warning")


func _is_modifier_keycode(kc: int) -> bool:
	return kc in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META, KEY_CAPSLOCK]

func _is_reserved_keycode(kc: int) -> bool:
	# Menu controls are hardcoded and must not be rebindable.
	return kc in [KEY_F5, KEY_F6, KEY_ESCAPE]

func _is_reserved_mouse_button(btn: int) -> bool:
	# Left/Right would break shooting and aiming.
	return btn in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]

func _mouse_button_display(btn: int) -> String:
	match btn:
		MOUSE_BUTTON_MIDDLE:       return "MMB"
		MOUSE_BUTTON_XBUTTON1:     return "Mouse4"
		MOUSE_BUTTON_XBUTTON2:     return "Mouse5"
		MOUSE_BUTTON_WHEEL_UP:     return "WheelUp"
		MOUSE_BUTTON_WHEEL_DOWN:   return "WheelDown"
		MOUSE_BUTTON_WHEEL_LEFT:   return "WheelLeft"
		MOUSE_BUTTON_WHEEL_RIGHT:  return "WheelRight"
		MOUSE_BUTTON_LEFT:         return "LMB"
		MOUSE_BUTTON_RIGHT:        return "RMB"
		_: return "Mouse%d" % btn

func _bind_display_name(bind: Dictionary) -> String:
	if bind == null or bind.is_empty():
		return "Unbound"
	var parts := []
	if bind.get("ctrl", false):  parts.append("Ctrl")
	if bind.get("alt", false):   parts.append("Alt")
	if bind.get("shift", false): parts.append("Shift")
	var key_name := ""
	if bind.get("device", 0) == 1:
		key_name = _mouse_button_display(int(bind.get("key", 0)))
	else:
		key_name = OS.get_keycode_string(int(bind.get("key", 0)))
		if key_name == "":
			key_name = "Key%d" % int(bind.get("key", 0))
	parts.append(key_name)
	return "+".join(parts)

func _event_matches_bind(event: InputEvent, bind: Dictionary) -> bool:
	if bind == null or bind.is_empty():
		return false
	if event is InputEventKey:
		if bind.get("device", 0) != 0:
			return false
		if event.physical_keycode != int(bind.get("key", -1)):
			return false
		return event.ctrl_pressed == bind.get("ctrl", false) \
			and event.shift_pressed == bind.get("shift", false) \
			and event.alt_pressed == bind.get("alt", false)
	elif event is InputEventMouseButton:
		if bind.get("device", 0) != 1:
			return false
		if event.button_index != int(bind.get("key", -1)):
			return false
		return event.ctrl_pressed == bind.get("ctrl", false) \
			and event.shift_pressed == bind.get("shift", false) \
			and event.alt_pressed == bind.get("alt", false)
	return false

func _try_fire_keybind(event: InputEvent) -> bool:
	# Key events: skip pure-modifier presses (they'd match modifier-less binds).
	if event is InputEventKey and _is_modifier_keycode(event.physical_keycode):
		return false
	# Don't hijack input when the user is typing into one of our text fields
	# (e.g. spawner search, cabin-browser search). Applies to BOTH key and
	# mouse-button binds — an extra-mouse-button bind would otherwise fire
	# while the user is mid-typing and clicking.
	var vp = get_viewport()
	if vp != null:
		var focused = vp.gui_get_focus_owner()
		if focused != null and (focused is LineEdit or focused is TextEdit):
			return false
	for action_name in keybinds.keys():
		if _event_matches_bind(event, keybinds[action_name]):
			_kb_execute(action_name)
			return true
	return false

func _kb_execute(action_name: String):
	var entry = BINDABLE_ACTIONS.get(action_name)
	if entry == null:
		return
	var t = entry.get("type", "")
	if t == "oneshot":
		var fn = entry.get("fn", "")
		if fn != "" and has_method(fn):
			call(fn)
	elif t == "toggle":
		var var_name = entry.get("var", "")
		if var_name in SETTABLE_VARS:
			var new_val = not bool(get(var_name))
			# Route through the canonical toggle handler so side effects
			# (e.g. No Overweight weight override) still run.
			_on_cheat_toggled(new_val, var_name)
			_sync_toggle_ui()
			_show_toast("%s: %s" % [entry.get("label", var_name), "ON" if new_val else "OFF"])

func _try_capture_bind(event: InputEvent):
	# ESC cancels capture without binding anything.
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_capture()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var kc = event.physical_keycode
		if _is_modifier_keycode(kc):
			return  # wait for a real key after the modifier
		if _is_reserved_keycode(kc):
			_show_toast("F5/F6/ESC are reserved for menu control", COL_NEGATIVE)
			return
		var new_bind = {
			"device": 0,
			"key": kc,
			"ctrl": event.ctrl_pressed,
			"shift": event.shift_pressed,
			"alt": event.alt_pressed,
		}
		_unbind_duplicate(new_bind, _capturing_action)
		keybinds[_capturing_action] = new_bind
		_finalize_capture()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed:
		var btn = event.button_index
		if _is_reserved_mouse_button(btn):
			_show_toast("LMB/RMB are reserved (shooting/aim)", COL_NEGATIVE)
			return
		var new_bind = {
			"device": 1,
			"key": btn,
			"ctrl": event.ctrl_pressed,
			"shift": event.shift_pressed,
			"alt": event.alt_pressed,
		}
		_unbind_duplicate(new_bind, _capturing_action)
		keybinds[_capturing_action] = new_bind
		_finalize_capture()
		get_viewport().set_input_as_handled()
		return

func _binds_equal(a: Dictionary, b: Dictionary) -> bool:
	# Deep compare on the five fields that define a bind. Any missing field
	# is treated as its default so older dicts don't falsely mismatch.
	if a == null or b == null or a.is_empty() or b.is_empty():
		return false
	return int(a.get("device", 0)) == int(b.get("device", 0)) \
		and int(a.get("key", -1)) == int(b.get("key", -2)) \
		and bool(a.get("ctrl", false)) == bool(b.get("ctrl", false)) \
		and bool(a.get("shift", false)) == bool(b.get("shift", false)) \
		and bool(a.get("alt", false)) == bool(b.get("alt", false))

func _unbind_duplicate(new_bind: Dictionary, except_action: String):
	# Remove any existing action whose bind matches new_bind. Prevents silent
	# shadowing when two actions share the same key combo. Toasts what moved.
	var collisions: Array = []
	for action_name in keybinds.keys():
		if action_name == except_action:
			continue
		if _binds_equal(keybinds[action_name], new_bind):
			collisions.append(action_name)
	for action_name in collisions:
		keybinds.erase(action_name)
		var entry = BINDABLE_ACTIONS.get(action_name, {})
		_show_toast("Unbound '%s' (key reassigned)" % entry.get("label", action_name), COL_NEGATIVE)

func _cancel_capture():
	_capturing_action = ""
	_refresh_keybind_ui()
	_show_toast("Rebind cancelled")

func _finalize_capture():
	var finalized = _capturing_action
	_capturing_action = ""
	_save_keybinds()
	_profile_mark_dirty()  # v10.6.0 dual-write
	_refresh_keybind_ui()
	var bind = keybinds.get(finalized, {})
	var entry = BINDABLE_ACTIONS.get(finalized, {})
	_show_toast("Bound '%s' to %s" % [entry.get("label", finalized), _bind_display_name(bind)])
	_check_bind_conflict(finalized)

func _check_bind_conflict(action_name: String):
	# Warn if the bind overlaps an existing game InputMap entry. Checks both
	# keyboard and mouse-button devices so the warning is symmetric.
	var bind = keybinds.get(action_name, {})
	if bind.is_empty():
		return
	var device = int(bind.get("device", 0))
	var target = int(bind.get("key", -1))
	for game_action in InputMap.get_actions():
		if game_action.begins_with("ui_"):
			continue
		for ev in InputMap.action_get_events(game_action):
			if device == 0 and ev is InputEventKey and ev.physical_keycode == target:
				_show_toast("Warning: also used by game action '%s'" % game_action, COL_NEGATIVE)
				return
			if device == 1 and ev is InputEventMouseButton and ev.button_index == target:
				_show_toast("Warning: also used by game action '%s'" % game_action, COL_NEGATIVE)
				return

# ── Keybinds tab UI ──────────────────────────────────────────────

func _build_tab_keybinds():
	var v = _make_tab_page("Keys")
	_add_title(v, "KEYBINDS")
	_add_info_label(v, "Click a bind to rebind. Right-click to clear. Hold Ctrl/Shift/Alt when pressing the key to capture a combo. Mouse buttons and wheel are supported. ESC cancels capture. F5/F6/ESC are reserved.", COL_TEXT_DIM, 11)
	_add_separator(v)
	var list_vbox = VBoxContainer.new()
	list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_vbox.add_theme_constant_override("separation", 3)
	v.add_child(list_vbox)
	keybind_list_vbox = list_vbox
	_refresh_keybind_ui()

func _refresh_keybind_ui():
	if keybind_list_vbox == null or not is_instance_valid(keybind_list_vbox):
		return
	for child in keybind_list_vbox.get_children():
		child.queue_free()
	var by_cat := {}
	for action_name in BINDABLE_ACTIONS.keys():
		var cat = BINDABLE_ACTIONS[action_name].get("cat", "Misc")
		if cat not in by_cat:
			by_cat[cat] = []
		by_cat[cat].append(action_name)
	for cat in BIND_CATEGORIES:
		if not by_cat.has(cat):
			continue
		var header = Label.new()
		_style_label(header, 13, COL_POSITIVE)
		header.text = "── %s ──" % cat.to_upper()
		keybind_list_vbox.add_child(header)
		for action_name in by_cat[cat]:
			_build_keybind_row(action_name)
		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(0, 4)
		keybind_list_vbox.add_child(spacer)

func _build_keybind_row(action_name: String):
	var entry = BINDABLE_ACTIONS[action_name]
	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	keybind_list_vbox.add_child(row)

	var lbl = Label.new()
	_style_label(lbl, 12, COL_TEXT)
	lbl.text = entry.get("label", action_name)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var is_capturing = _capturing_action == action_name
	var bind = keybinds.get(action_name, {})
	var btn_text: String
	if is_capturing:
		btn_text = "Press key/button... (ESC cancel)"
	else:
		btn_text = _bind_display_name(bind)

	var bg_col = COL_SPAWN_BTN if is_capturing else COL_BTN_NORMAL
	var hv_col = COL_SPAWN_HVR if is_capturing else COL_BTN_HOVER
	var bind_btn = _make_styled_button(btn_text, bg_col, hv_col)
	bind_btn.custom_minimum_size = Vector2(220, 26)
	bind_btn.add_theme_font_size_override("font_size", 11)
	bind_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	bind_btn.gui_input.connect(_on_keybind_button_input.bind(action_name))
	row.add_child(bind_btn)

	var clear_btn = _make_styled_button("X", COL_DANGER_BTN, COL_DANGER_HVR)
	clear_btn.custom_minimum_size = Vector2(26, 26)
	clear_btn.add_theme_font_size_override("font_size", 11)
	clear_btn.pressed.connect(_on_keybind_clear.bind(action_name))
	row.add_child(clear_btn)

func _on_keybind_button_input(event: InputEvent, action_name: String):
	if not event is InputEventMouseButton or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		# Enter capture mode for this row.
		_capturing_action = action_name
		_refresh_keybind_ui()
		get_viewport().set_input_as_handled()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_on_keybind_clear(action_name)
		get_viewport().set_input_as_handled()

func _on_keybind_clear(action_name: String):
	if not keybinds.has(action_name):
		_show_toast("Already unbound")
		return
	keybinds.erase(action_name)
	_save_keybinds()
	_profile_mark_dirty()  # v10.6.0 dual-write
	_refresh_keybind_ui()
	var entry = BINDABLE_ACTIONS.get(action_name, {})
	_show_toast("Unbound '%s'" % entry.get("label", action_name))


# ================================================================
#  SAFE PROPERTY ACCESS
# ================================================================

func _safe(obj, prop: String, fallback = null):
	if obj == null:
		return fallback
	if prop in obj:
		return obj.get(prop)
	return fallback

# ──────────────────────────────────────────────────────────────
# CHEAT SIDE-EFFECT APPLICATORS (v10.6.0)
# ──────────────────────────────────────────────────────────────
# Each applicator encapsulates the side-effects a specific cheat
# triggers BEYOND the bare `set(var, value)`. Extracted from what used
# to be inline branches inside _on_cheat_toggled / _on_slider_changed
# so the profile system can replay the same side-effects during bulk
# profile loads without re-entering the live-toggle paths (which would
# also fire _log, _update_hud, and legacy cfg writes 33 times per load).
#
# Each applicator is:
#   * idempotent — calling it repeatedly with the same value is safe
#   * defensive — controller_found / game_data property guards everywhere
#   * mechanical — body is the VERBATIM branch code from v10.5.17's
#     _on_cheat_toggled / _on_slider_changed (diff-reviewable per branch)

func _apply_no_overweight(enabled: bool):
	var ow_interface = _get_interface()
	if ow_interface != null and is_instance_valid(ow_interface) and "baseCarryWeight" in ow_interface:
		if enabled:
			if not carry_weight_captured and ow_interface.baseCarryWeight < 9000:
				base_carry_weight = ow_interface.baseCarryWeight
				carry_weight_captured = true
			ow_interface.baseCarryWeight = 9999.0
		else:
			if carry_weight_captured:
				ow_interface.baseCarryWeight = base_carry_weight
				carry_weight_captured = false
		# Force the game to re-evaluate weight/overweight immediately.
		# v10.5.1 — guard UpdateStats via has_method. If a future game
		# version renames the method or our discovered node isn't
		# actually the Interface (see _get_interface fallbacks),
		# crashing on a missing method is worse than the stat simply
		# not refreshing until the player moves.
		if ow_interface.has_method("UpdateStats"):
			ow_interface.UpdateStats(false)

func _apply_tac_hud(_enabled: bool):
	# TAC HUD visibility reads cheat_tac_hud live; flipping the countdown
	# to 0 forces the next tick to reconcile visibility against the
	# current value. Works whether enabled went true or false.
	tac_hud_refresh_countdown = 0.0
	_refresh_tac_hud()

func _apply_real_time(_enabled: bool):
	# Persist to legacy real_time.cfg. Keeps dual-write contract with the
	# profiles system — until v10.7 strips legacy writes, both paths
	# update in sync. The legacy save is safe during profile-load (one
	# write per load) and intentional as part of the rollout.
	_save_real_time_pref()

func _apply_tuner_master(_enabled: bool):
	# Dim/brighten the Tuner tab's controls. Reads cheat_tuner_enabled
	# live, so setting the var before calling this is sufficient.
	_apply_tuner_master_visual_state()

func _apply_unlock_crafting(enabled: bool):
	# Craft Anywhere OFF → restore heat + PRX_Workbench immediately. This
	# cannot wait for _process to notice the toggle flip because _process
	# is gated by _any_cheat_active(), which returns false as soon as the
	# last cheat is disabled, so the cleanup branch never gets a chance
	# to run from there. Doing it here is also instantaneous rather than
	# one frame late. (see bug fixed in v10.6.26)
	if not enabled and craft_unlock_overridden:
		if "heat" in game_data:
			game_data.heat = base_heat
		if "PRX_Workbench" in game_data:
			game_data.PRX_Workbench = base_prx_workbench
		craft_unlock_overridden = false

func _apply_no_headbob(enabled: bool):
	# No Head Bob OFF → same early-return race — restore immediately.
	if not enabled and headbob_overridden:
		if "headbob" in game_data:
			game_data.headbob = base_headbob
		headbob_overridden = false

func _apply_no_recoil(enabled: bool):
	# No Recoil OFF → restore every weapon + sway + riser we touched.
	# _apply_weapon_mods() is only invoked from _process when the cheat
	# is ON, so its internal else-branch restore is dead code. Running
	# _restore_all_recoil_and_sway() here is the only reliable path.
	# (see bug fixed in v10.6.27)
	if not enabled:
		_restore_all_recoil_and_sway()

func _apply_no_fall_dmg(enabled: bool):
	# No Fall Damage OFF → restore fallThreshold on the controller. The
	# _process else-branch is gated behind _any_cheat_active() so it
	# never fires when this is the only active cheat.
	if not enabled:
		if controller_found and is_instance_valid(controller) and "fallThreshold" in controller:
			controller.fallThreshold = base_fall_threshold

func _apply_speed_mult(new_val: float):
	# Immediate-write restoration for the speed slider. _process applies
	# speed_mult per-frame while the slider is "active" (not at its
	# neutral baseline 1.0), but _process is gated behind _any_cheat_active()
	# which returns false the moment a slider returns to its baseline —
	# so the reset branches inside _process never run and the game stays
	# stuck at the last non-baseline value. Handling the write here
	# guarantees the transition to baseline always applies, regardless
	# of whether any other cheats happen to be active.
	# (see bugs fixed in v10.6.27)
	if controller_found and is_instance_valid(controller):
		if new_val == 1.0:
			controller.walkSpeed = base_walk_speed
			controller.sprintSpeed = base_sprint_speed
			controller.crouchSpeed = base_crouch_speed
			# Kill a lingering currentSpeed boost so the player doesn't
			# keep coasting at 5x after the slider drops.
			if "currentSpeed" in controller and controller.currentSpeed > base_sprint_speed + 0.5:
				controller.currentSpeed = base_sprint_speed

func _apply_jump_mult(new_val: float):
	if controller_found and is_instance_valid(controller):
		if new_val == 1.0:
			controller.jumpVelocity = base_jump_vel

func _apply_fov(new_val: float):
	# Write every tick unconditionally — the _process branch had a
	# `!= base_fov` guard that caused game_data.baseFOV to stay stale
	# when the user dragged the slider exactly back to base.
	if "baseFOV" in game_data:
		game_data.baseFOV = new_val

func _apply_cheat_side_effects(variable_name: String, value):
	# Central dispatcher — _on_cheat_toggled and _on_slider_changed call
	# this after their set(var, value); profile-load's _profile_apply_cheats
	# calls it for every controller-dependent field. Unknown vars fall
	# through (most cheats have no extra side-effects).
	match variable_name:
		"cheat_no_overweight":   _apply_no_overweight(bool(value))
		"cheat_tac_hud":         _apply_tac_hud(bool(value))
		"cheat_real_time":       _apply_real_time(bool(value))
		"cheat_tuner_enabled":   _apply_tuner_master(bool(value))
		"cheat_unlock_crafting": _apply_unlock_crafting(bool(value))
		"cheat_no_headbob":      _apply_no_headbob(bool(value))
		"cheat_no_recoil":       _apply_no_recoil(bool(value))
		"cheat_no_fall_dmg":     _apply_no_fall_dmg(bool(value))
		"cheat_speed_mult":      _apply_speed_mult(float(value))
		"cheat_jump_mult":       _apply_jump_mult(float(value))
		"cheat_fov":             _apply_fov(float(value))

func _on_cheat_toggled(enabled: bool, variable_name: String):
	if variable_name not in SETTABLE_VARS:
		return
	set(variable_name, enabled)
	# Log every cheat toggle so the DEBUG window shows real-time state
	# transitions. Uses the raw variable name for grep-friendliness.
	_log("toggle %s = %s" % [variable_name, "ON" if enabled else "OFF"])
	_apply_cheat_side_effects(variable_name, enabled)
	_update_hud()
	# v10.6.0 — mark the active profile dirty so autosave picks this up.
	# Gated against the profile-load suspend flag so bulk applies don't
	# write-amplify. Single mark per toggle regardless of which cheat.
	if not _profile_suspend_hud:
		_profile_mark_dirty()

func _on_slider_changed(new_val: float, variable_name: String, display: Label, label_text: String):
	if variable_name not in SETTABLE_VARS:
		return
	set(variable_name, new_val)
	if variable_name == "cheat_fov":
		display.text = label_text + ": " + str(int(new_val))
	else:
		display.text = label_text + ": " + ("%.1fx" % new_val)
	_apply_cheat_side_effects(variable_name, new_val)
	_update_hud()
	# v10.6.0 — mark the active profile dirty. Burst-clamp in
	# _profile_mark_dirty coalesces a long slider drag (many rapid
	# value_changed signals) into a single debounced save.
	if not _profile_suspend_hud:
		_profile_mark_dirty()

func _compare_items(a, b) -> bool:
	if sort_field == "weight":
		var aw = _safe(a, "weight", 0.0)
		var bw = _safe(b, "weight", 0.0)
		if sort_ascending:
			return aw < bw
		else:
			return aw > bw
	elif sort_field == "rarity":
		var ar = _safe(a, "rarity", 0)
		var br = _safe(b, "rarity", 0)
		if sort_ascending:
			return ar < br
		else:
			return ar > br
	else:
		var an = str(_safe(a, "name", "")).to_lower()
		var bn = str(_safe(b, "name", "")).to_lower()
		if sort_ascending:
			return an < bn
		else:
			return an > bn


# ================================================================
#  UI FACTORY FUNCTIONS — matched to game's native styling
# ================================================================

func _make_tile_style(alpha: float = 0.86) -> StyleBox:
	# Use the game's Tile.png texture for panel backgrounds — exactly how the game does it
	if game_tile:
		var style = StyleBoxTexture.new()
		style.texture = game_tile
		style.texture_margin_left = 1.0
		style.texture_margin_top = 1.0
		style.texture_margin_right = 1.0
		style.texture_margin_bottom = 1.0
		style.modulate_color = Color(1, 1, 1, alpha)
		style.content_margin_left = 12
		style.content_margin_top = 12
		style.content_margin_right = 12
		style.content_margin_bottom = 12
		return style
	else:
		# Fallback flat style if Tile.png not available
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.05, 0.05, 0.05, alpha)
		style.set_content_margin_all(12)
		return style

func _make_button_flat(bg_color: Color) -> StyleBoxFlat:
	# Game buttons: flat gray StyleBoxFlat, no border, no corners
	var style = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_content_margin_all(4)
	return style

func _make_styled_button(text: String, normal_color: Color, hover_color: Color) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_stylebox_override("normal", _make_button_flat(normal_color))
	btn.add_theme_stylebox_override("hover", _make_button_flat(hover_color))
	btn.add_theme_stylebox_override("pressed", _make_button_flat(COL_BTN_PRESS))
	btn.add_theme_stylebox_override("focus", _make_button_flat(Color(0, 0, 0, 0)))
	_style_button_font(btn, 12, COL_TEXT)
	return btn

# Modern button style: rounded corners, subtle top-lighter border for a
# fake bevel, tinted drop shadow for a glow/emission effect. Hover state
# amplifies the glow; pressed state removes it and inverts the bevel.
# Godot 4 StyleBoxFlat has all this built in — no shader required.
#
# `state` values: "normal" | "hover" | "pressed" | "focus"
# `glow_tint` lets the shadow take on the button's color so it reads as
# backlit emission (a soft neon glow) rather than a plain drop shadow.
func _make_button_modern(bg_color: Color, state: String = "normal", glow_tint: bool = true) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	# Bump fill opacity so the button reads as a solid chip, not a
	# washed-out overlay. The source palette colors all ship at ~0.5
	# alpha (designed for subtle toggles), which is the wrong weight
	# for a hero action button. Cap at 0.95 to keep ever-so-slight
	# depth vs the panel behind it.
	style.bg_color = Color(bg_color.r, bg_color.g, bg_color.b, clampf(bg_color.a + 0.4, 0.0, 0.95))
	# Soft corners — 4px reads as modern without going bubbly.
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.anti_aliasing = true
	# Beveled border: thicker (2px) highlight on top for an "LED edge"
	# look, 1px on the other sides. Pressed state inverts vertically —
	# bright edge drops to the bottom as if the light source shifted.
	var bevel_shift: float = -0.18 if state == "pressed" else 0.22
	var bright := Color(
		clampf(bg_color.r + bevel_shift, 0.0, 1.0),
		clampf(bg_color.g + bevel_shift, 0.0, 1.0),
		clampf(bg_color.b + bevel_shift, 0.0, 1.0),
		1.0
	)
	style.border_color = bright
	if state == "pressed":
		style.border_width_top = 1
		style.border_width_bottom = 2
	else:
		style.border_width_top = 2
		style.border_width_bottom = 1
	style.border_width_left = 1
	style.border_width_right = 1
	# Emissive glow: shadow takes on the button's own hue so it reads
	# as backlight rather than a neutral drop shadow. Pure-black fallback
	# if glow_tint is disabled.
	var glow := Color(bg_color.r, bg_color.g, bg_color.b, 0.7) if glow_tint \
		else Color(0, 0, 0, 0.5)
	match state:
		"hover":
			style.shadow_color = Color(glow.r, glow.g, glow.b, 0.85)
			style.shadow_size = 8
			style.shadow_offset = Vector2(0, 2)
		"pressed":
			style.shadow_color = Color(0, 0, 0, 0.0)
			style.shadow_size = 0
		_:
			style.shadow_color = glow
			style.shadow_size = 5
			style.shadow_offset = Vector2(0, 2)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style

func _make_spawn_button(label: String, normal_color: Color, hover_color: Color) -> Button:
	# Spawn buttons use the modern styling — a dedicated "chip" look that
	# signals these are primary actions. A pressed_color darkens the fill
	# further for the click feedback since the state sprite alone loses
	# the shadow cue.
	var pressed_color := Color(
		max(0.0, normal_color.r * 0.7),
		max(0.0, normal_color.g * 0.7),
		max(0.0, normal_color.b * 0.7),
		normal_color.a
	)
	var btn := Button.new()
	btn.text = label
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_stylebox_override("normal",  _make_button_modern(normal_color, "normal"))
	btn.add_theme_stylebox_override("hover",   _make_button_modern(hover_color,  "hover"))
	btn.add_theme_stylebox_override("pressed", _make_button_modern(pressed_color, "pressed"))
	btn.add_theme_stylebox_override("focus",   _make_button_modern(Color(0, 0, 0, 0), "normal", false))
	btn.custom_minimum_size = Vector2(100, 34)
	# Bold typeface at 12pt — punchier label that matches the
	# increased visual weight of the chip. Falls back to regular
	# game_font if SemiBold didn't load.
	if game_font_bold:
		btn.add_theme_font_override("font", game_font_bold)
	elif game_font:
		btn.add_theme_font_override("font", game_font)
	btn.add_theme_font_size_override("font_size", 12)
	btn.add_theme_color_override("font_color", COL_TEXT)
	btn.add_theme_color_override("font_hover_color", COL_POSITIVE)
	btn.add_theme_color_override("font_shadow_color", COL_SHADOW)
	btn.add_theme_constant_override("shadow_offset_x", 1)
	btn.add_theme_constant_override("shadow_offset_y", 1)
	return btn

# Lazy shader compile + cache. Each effect has a shader_key string
# ("gradient", "rain", "storm", "aurora"). The first caller for a key
# compiles the source once; subsequent callers reuse the same Shader
# instance. ShaderMaterial instances are still per-button so uniforms
# stay isolated.
func _get_cached_shader(shader_key: String, code: String) -> Shader:
	if _cached_shaders.has(shader_key):
		var existing = _cached_shaders[shader_key]
		if is_instance_valid(existing):
			return existing
	var sh := Shader.new()
	sh.code = code
	_cached_shaders[shader_key] = sh
	return sh

# Builds a gradient-backed button as a Control composite:
#   Control (root, click-through wrapper)
#     ├── TextureRect or ColorRect (background — custom texture OR shader-driven gradient)
#     ├── Panel (thin border, ignores mouse)
#     ├── [optional icon nodes — sun/moon/stars, ignore mouse]
#     ├── ColorRect (hover overlay, hidden by default, toggled on hover)
#     └── Button (flat, transparent, catches clicks and shows text)
#
# When a `bg_texture` is provided, it becomes the visual base layer and
# the shader gradient/animation is skipped entirely — the texture art
# replaces the procedural look. shader_key is ignored in that case.
# When no texture is provided, the shader path is used: "gradient" /
# "rain" / "storm" / "aurora".
# icon_mode adds decorative sun/moon panels ("sun_dawn", "sun_noon",
# "sun_dusk", "moon") but should only be used when there's no texture,
# since texture art usually bakes its own sun/moon into the image.
func _make_gradient_button(text: String, shader_key: String, top: Color, bot: Color, font_color: Color, on_pressed: Callable, icon_mode: String = "", row_height: int = 30, bg_texture: Texture2D = null) -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(0, row_height)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	if bg_texture != null:
		# Texture path — ship-custom art as the background layer.
		# v10.6.15: STRETCH_KEEP_ASPECT_COVERED preserves native aspect
		# and crops overflow, so narrow buttons (like the season row at
		# ~6:1) don't vertically squish 4:1 source art. clip_contents
		# on the root hides the cropped portion.
		root.clip_contents = true
		var trect := TextureRect.new()
		trect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		trect.texture = bg_texture
		trect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		trect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		trect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		trect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(trect)
		# Optional animated overlay on top of the painted texture.
		# Used for weather buttons that want motion (rain streaks,
		# storm flashes, aurora shimmer) layered over hand-painted
		# base art. The overlay shader outputs transparent alpha
		# everywhere except the motion pixels, so the painting shows
		# through cleanly between streaks.
		var overlay_code: String = ""
		var overlay_key: String = ""
		match shader_key:
			"rain_overlay":
				overlay_code = RAIN_OVERLAY_SHADER_CODE
				overlay_key = "rain_overlay"
		if overlay_code != "":
			var overlay_mat := ShaderMaterial.new()
			overlay_mat.shader = _get_cached_shader(overlay_key, overlay_code)
			var overlay := ColorRect.new()
			overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			overlay.color = Color.WHITE
			overlay.material = overlay_mat
			overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(overlay)
	else:
		# Shader path — procedural gradient or animation.
		var code: String = GRADIENT_SHADER_CODE
		match shader_key:
			"gradient":
				code = GRADIENT_SHADER_CODE
			"rain":
				code = RAIN_SHADER_CODE
			"storm":
				code = STORM_SHADER_CODE
			"aurora":
				code = AURORA_SHADER_CODE
		var mat := ShaderMaterial.new()
		mat.shader = _get_cached_shader(shader_key, code)
		if shader_key != "aurora":
			mat.set_shader_parameter("color_top", top)
			mat.set_shader_parameter("color_bot", bot)
		var bg := ColorRect.new()
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.color = Color.WHITE
		bg.material = mat
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(bg)

	# Thin border for definition against the dashboard background
	var border_style := StyleBoxFlat.new()
	border_style.bg_color = Color(0, 0, 0, 0)
	border_style.border_color = Color(0, 0, 0, 0.55)
	border_style.border_width_left = 1
	border_style.border_width_right = 1
	border_style.border_width_top = 1
	border_style.border_width_bottom = 1
	var border := Panel.new()
	border.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	border.add_theme_stylebox_override("panel", border_style)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(border)

	# Decorative icon layer — sun disc, moon crescent + stars, etc.
	# Skipped when the background is a texture (art bakes its own icons).
	if icon_mode != "" and bg_texture == null:
		_add_time_icon(root, icon_mode)

	# Hover highlight overlay — fades in when the mouse enters the button.
	var hover_overlay := ColorRect.new()
	hover_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hover_overlay.color = Color(1, 1, 1, 0.18)
	hover_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hover_overlay.visible = false
	root.add_child(hover_overlay)

	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.add_theme_color_override("font_color", font_color)
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	btn.add_theme_constant_override("outline_size", 4)
	btn.add_theme_font_size_override("font_size", 12)
	if game_font:
		btn.add_theme_font_override("font", game_font)
	btn.pressed.connect(on_pressed)
	btn.mouse_entered.connect(func(): hover_overlay.visible = true)
	btn.mouse_exited.connect(func(): hover_overlay.visible = false)
	root.add_child(btn)

	return root

# Tiny helper — creates a Panel node with a rounded-corner StyleBoxFlat
# so the Panel renders as a solid-colored disc. Used by the time-button
# icon layer to paint sun and moon glyphs without extra textures.
func _make_circle_panel(diameter: int, color: Color) -> Panel:
	var p := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(int(diameter * 0.5))
	p.add_theme_stylebox_override("panel", style)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

# Positions decorative sun / moon / star icons inside a gradient button
# composite. Modes are "sun_dawn" (horizon sun bottom-center), "sun_noon"
# (bright sun top-center), "sun_dusk" (red sun bottom-left), and "moon"
# (white crescent top-right with a few scattered star dots).
func _add_time_icon(parent: Control, mode: String):
	match mode:
		"sun_dawn":
			# Sun disc rising at bottom-center
			var sun := _make_circle_panel(22, Color(1.0, 0.85, 0.45, 0.95))
			sun.anchor_left = 0.5
			sun.anchor_right = 0.5
			sun.anchor_top = 1.0
			sun.anchor_bottom = 1.0
			sun.offset_left = -11
			sun.offset_right = 11
			sun.offset_top = -26
			sun.offset_bottom = -4
			parent.add_child(sun)
			# Soft halo (larger lower-alpha disc behind)
			var halo := _make_circle_panel(32, Color(1.0, 0.85, 0.45, 0.22))
			halo.anchor_left = 0.5
			halo.anchor_right = 0.5
			halo.anchor_top = 1.0
			halo.anchor_bottom = 1.0
			halo.offset_left = -16
			halo.offset_right = 16
			halo.offset_top = -31
			halo.offset_bottom = 1
			parent.add_child(halo)
			parent.move_child(halo, parent.get_child_count() - 2)
		"sun_noon":
			# Bright sun high — center top area
			var sun := _make_circle_panel(20, Color(1.0, 0.95, 0.55, 1.0))
			sun.anchor_left = 0.5
			sun.anchor_right = 0.5
			sun.anchor_top = 0.0
			sun.anchor_bottom = 0.0
			sun.offset_left = -10
			sun.offset_right = 10
			sun.offset_top = 4
			sun.offset_bottom = 24
			parent.add_child(sun)
			var halo := _make_circle_panel(30, Color(1.0, 0.95, 0.55, 0.25))
			halo.anchor_left = 0.5
			halo.anchor_right = 0.5
			halo.anchor_top = 0.0
			halo.anchor_bottom = 0.0
			halo.offset_left = -15
			halo.offset_right = 15
			halo.offset_top = -1
			halo.offset_bottom = 29
			parent.add_child(halo)
			parent.move_child(halo, parent.get_child_count() - 2)
		"sun_dusk":
			# Red-orange sun setting at bottom-left
			var sun := _make_circle_panel(22, Color(1.0, 0.55, 0.25, 0.95))
			sun.anchor_left = 0.0
			sun.anchor_right = 0.0
			sun.anchor_top = 1.0
			sun.anchor_bottom = 1.0
			sun.offset_left = 6
			sun.offset_right = 28
			sun.offset_top = -28
			sun.offset_bottom = -6
			parent.add_child(sun)
			var halo := _make_circle_panel(34, Color(1.0, 0.5, 0.2, 0.22))
			halo.anchor_left = 0.0
			halo.anchor_right = 0.0
			halo.anchor_top = 1.0
			halo.anchor_bottom = 1.0
			halo.offset_left = 0
			halo.offset_right = 34
			halo.offset_top = -34
			halo.offset_bottom = 0
			parent.add_child(halo)
			parent.move_child(halo, parent.get_child_count() - 2)
		"moon":
			# Cream moon disc at top-right
			var moon := _make_circle_panel(18, Color(0.96, 0.94, 0.86, 0.95))
			moon.anchor_left = 1.0
			moon.anchor_right = 1.0
			moon.anchor_top = 0.0
			moon.anchor_bottom = 0.0
			moon.offset_left = -26
			moon.offset_right = -8
			moon.offset_top = 6
			moon.offset_bottom = 24
			parent.add_child(moon)
			# Scattered stars on the left side of the button.
			var star_positions: Array = [
				Vector2(-50, 8),
				Vector2(-62, 20),
				Vector2(-42, 26),
				Vector2(-78, 14),
			]
			for pos in star_positions:
				var star := ColorRect.new()
				star.color = Color(1, 1, 1, 0.85)
				star.anchor_left = 1.0
				star.anchor_right = 1.0
				star.anchor_top = 0.0
				star.anchor_bottom = 0.0
				star.offset_left = pos.x
				star.offset_right = pos.x + 2
				star.offset_top = pos.y
				star.offset_bottom = pos.y + 2
				star.mouse_filter = Control.MOUSE_FILTER_IGNORE
				parent.add_child(star)

func _style_label(label: Label, size: int = 16, color: Color = COL_TEXT):
	# Apply game font + text shadow to any label
	if game_font:
		label.add_theme_font_override("font", game_font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", COL_SHADOW)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)

func _style_button_font(btn: Button, size: int = 12, color: Color = COL_TEXT):
	# Apply game font + shadow to any button
	if game_font:
		btn.add_theme_font_override("font", game_font)
	btn.add_theme_font_size_override("font_size", size)
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_color_override("font_hover_color", COL_TEXT)

func _add_title(parent: Control, text: String):
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if game_font_bold:
		label.add_theme_font_override("font", game_font_bold)
	elif game_font:
		label.add_theme_font_override("font", game_font)
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", COL_TEXT)
	label.add_theme_color_override("font_shadow_color", COL_SHADOW)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	parent.add_child(label)

func _add_separator(parent: Control):
	var sep = HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	# Match game separator: thin white line at 12.5% alpha
	var line_style = StyleBoxLine.new()
	line_style.color = COL_SEPARATOR
	line_style.grow_begin = 0.0
	line_style.grow_end = 0.0
	line_style.thickness = 2
	sep.add_theme_stylebox_override("separator", line_style)
	parent.add_child(sep)

func _add_section_header(parent: Control, text: String):
	var label = Label.new()
	label.text = text
	_style_label(label, 13, COL_TEXT_DIM)
	parent.add_child(label)

func _add_cheat_toggle(parent: Control, label_text: String, variable_name: String):
	# Row: [CheckButton (cheat)] [★ favorite toggle]. The star is a small
	# inline button that add/removes this cheat from the dashboard favorites
	# row. Keeping it right-adjacent to the toggle means discoverability
	# without needing hidden right-click gestures.
	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)

	var toggle = CheckButton.new()
	toggle.text = label_text
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button_font(toggle, 13, COL_TEXT_DIM)
	toggle.add_theme_color_override("font_hover_color", COL_TEXT)
	# Initialize visual pressed state from the current variable value BEFORE
	# wiring the toggled signal, so categories that rebuild lazily (e.g. the
	# World tab on first open after startup) reflect persisted / pre-existing
	# cheat state instead of appearing unchecked. set_pressed_no_signal avoids
	# firing _on_cheat_toggled during construction.
	toggle.set_pressed_no_signal(bool(get(variable_name)))
	toggle.toggled.connect(_on_cheat_toggled.bind(variable_name))
	row.add_child(toggle)
	toggle_refs[variable_name] = toggle

	var star = _make_favorite_star_button(variable_name)
	row.add_child(star)
	favorite_star_refs[variable_name] = star
	_apply_favorite_star_state(star, variable_name)

func _make_favorite_star_button(variable_name: String) -> Button:
	# Small square button to the right of a cheat toggle. No font override
	# so Godot's default theme font renders the ★ / ☆ glyphs (Lora doesn't
	# ship the Miscellaneous Symbols block). Fixed 28x28 so a row of
	# toggles lines up vertically.
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(28, 28)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.flat = true
	btn.tooltip_text = "Add to dashboard favorites"
	btn.pressed.connect(_on_favorite_star_pressed.bind(variable_name))
	return btn

func _apply_favorite_star_state(btn: Button, variable_name: String):
	# Updates the star button's glyph and color to reflect current favorite
	# membership. Called from both initial build and _refresh_favorite_stars.
	if not is_instance_valid(btn):
		return
	var is_fav = favorite_actions.has(variable_name)
	btn.text = "★" if is_fav else "☆"
	var gold = Color(1.0, 0.85, 0.2, 1.0)
	btn.add_theme_color_override("font_color", gold if is_fav else COL_TEXT_DIM)
	btn.add_theme_color_override("font_hover_color", gold)
	btn.add_theme_color_override("font_pressed_color", gold)
	btn.tooltip_text = "Remove from dashboard favorites" if is_fav else "Add to dashboard favorites"

func _on_favorite_star_pressed(variable_name: String):
	_toggle_favorite(variable_name)

func _refresh_favorite_stars():
	# Re-sync every registered star button to match the current favorites
	# list. Called from _toggle_favorite after the list mutates.
	for var_name in favorite_star_refs.keys():
		_apply_favorite_star_state(favorite_star_refs[var_name], var_name)

func _add_value_slider(parent: Control, label_text: String, variable_name: String, min_val: float, max_val: float, step_val: float):
	var container = VBoxContainer.new()
	container.add_theme_constant_override("separation", 1)
	var display = Label.new()
	if variable_name == "cheat_fov":
		display.text = label_text + ": " + str(int(get(variable_name)))
	else:
		display.text = label_text + ": " + ("%.1fx" % float(get(variable_name)))
	_style_label(display, 13, COL_TEXT_DIM)
	container.add_child(display)
	var slider = HSlider.new()
	slider.focus_mode = Control.FOCUS_NONE
	slider.scrollable = false
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step_val
	slider.value = get(variable_name)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Apply game's slider styling
	if game_grabber:
		slider.add_theme_icon_override("grabber", game_grabber)
		slider.add_theme_icon_override("grabber_highlight", game_grabber)
	# Match game slider track style
	var track_style = StyleBoxLine.new()
	track_style.color = COL_SEPARATOR
	track_style.grow_begin = 0.0
	track_style.grow_end = 0.0
	track_style.thickness = 2
	slider.add_theme_stylebox_override("slider", track_style)
	# Grabber area
	var grabber_area = StyleBoxFlat.new()
	grabber_area.bg_color = Color(1, 1, 1, 0.5)
	grabber_area.set_corner_radius_all(4)
	grabber_area.set_content_margin_all(4)
	slider.add_theme_stylebox_override("grabber_area", grabber_area)
	slider.add_theme_stylebox_override("grabber_area_highlight", grabber_area)
	slider.value_changed.connect(_on_slider_changed.bind(variable_name, display, label_text))
	container.add_child(slider)
	parent.add_child(container)

func _add_action_button(parent: Control, label_text: String, method_name: String, bg_color: Color):
	var hover_color = Color(bg_color.r + 0.1, bg_color.g + 0.1, bg_color.b + 0.1, min(bg_color.a + 0.1, 1.0))
	var btn = _make_styled_button(label_text, bg_color, hover_color)
	btn.custom_minimum_size = Vector2(0, 32)
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", COL_TEXT_DIM)
	btn.add_theme_color_override("font_hover_color", COL_TEXT)
	btn.pressed.connect(Callable(self, method_name))
	parent.add_child(btn)

func _add_info_label(parent: Control, text: String, color: Color, font_size: int = 12):
	var label = Label.new()
	label.text = text
	_style_label(label, font_size, color)
	parent.add_child(label)


# ================================================================
#  DASHBOARD (v10.3.0) — landing page shown on F5
# ================================================================
# The dashboard is a separate PanelContainer from cheat_panel. On F5,
# the dashboard shows first; clicking a navigation button hides it and
# opens the corresponding sub-menu (which reuses the existing tabbed
# cheat_panel with the tab strip hidden and a BACK button at the top).
#
# Live refresh happens every 0.5s via _refresh_dashboard_live(), driven
# from _process(). Only label/bar text is mutated during refresh — the
# card structure is built once in _build_dashboard_panel() and reused.

# Navigation buttons. Each entry maps to a tab page.
const DASHBOARD_NAV_DEFS := [
	# Top row — four core category tabs, with the headline SPAWNER
	# feature occupying the top-right "CTA" slot. `featured: true`
	# tells _build_dashboard_nav_row to render it with the game's
	# green accent color + bold font, signaling "this one is special"
	# at a glance. Users scanning the nav row land on the green
	# button naturally after reading left-to-right.
	{"label": "PLAYER",    "tab": "Player"},
	{"label": "COMBAT",    "tab": "Combat"},
	{"label": "WORLD",     "tab": "World"},
	{"label": "◆ SPAWNER", "tab": "Spawner",    "featured": true},
	# Bottom row — supporting tabs + keybinds + profiles.
	{"label": "INVENTORY", "tab": "Inventory"},
	{"label": "CABIN",     "tab": "Cabin"},
	{"label": "TUNER",     "tab": "Tuner"},     # v10.3.0 — Vitals Tuner
	{"label": "PROFILES",  "tab": "Profiles"},  # v10.6.0 — 3-slot loadout presets
	{"label": "KEYBINDS",  "tab": "Keys"},
]

# Friendly labels for favorites. Source of truth is BINDABLE_ACTIONS
# (which has a label per action) but that's keyed by action name, not
# by variable name. _favorite_label() resolves either way.
func _favorite_label(var_name: String) -> String:
	# First check BINDABLE_ACTIONS for a matching "var" entry
	for action_name in BINDABLE_ACTIONS:
		var entry = BINDABLE_ACTIONS[action_name]
		if entry.get("type", "") == "toggle" and entry.get("var", "") == var_name:
			return entry.get("label", var_name)
	# Fallback: strip "cheat_" prefix and title-case
	var s = var_name
	if s.begins_with("cheat_"):
		s = s.substr(6)
	return s.replace("_", " ").capitalize()


# ──────────────────────────────────────────────────────────────
# PROFILES SUBSYSTEM (v10.6.0)
# ──────────────────────────────────────────────────────────────
# 3-slot persistent user state. Every mutation site in the mod
# calls _profile_mark_dirty() (alongside its legacy _save_X() during
# the one-release dual-write window) which arms a 1-second debounce
# timer; the timer expiring flushes current live state to the active
# profile file. Window-close and _exit_tree force-flush synchronously.
#
# Architecture: live state ⇄ Dictionary ⇄ ConfigFile ⇄ profile_N.cfg
#   - _profile_serialize_live()   → Dictionary (pure)
#   - _profile_apply_dict(d)      ← Dictionary (pure on the way in;
#                                    invokes applicators for side-effects)
#   - _profile_dict_to_cfg(d)     → ConfigFile
#   - _profile_cfg_to_dict(cfg)   ← ConfigFile
#   - _profile_write_atomic()     .tmp + rename for crash-safety
#
# The stable-dict layer lets a future export/import or cloud sync
# feature reuse every serializer without touching file I/O.

# ── Autosave / dirty machinery ────────────────────────────────

func _profile_mark_dirty() -> void:
	_profile_dirty = true
	_profile_dirty_count += 1
	# Burst-clamp: programmatic bulk mutation (future "preset" actions)
	# would otherwise defer the save for up to the full debounce window.
	# Once we exceed the burst threshold, floor the remaining timer so
	# we flush soon and reset the counter.
	if _profile_dirty_count > PROFILE_DIRTY_BURST_THRESHOLD:
		if _profile_save_timer > PROFILE_AUTOSAVE_FLOOR_SEC:
			_profile_save_timer = PROFILE_AUTOSAVE_FLOOR_SEC
	else:
		_profile_save_timer = PROFILE_AUTOSAVE_DEBOUNCE_SEC

func _profile_tick_autosave(delta: float) -> void:
	if not _profile_dirty:
		return
	_profile_save_timer -= delta
	if _profile_save_timer <= 0.0:
		_profile_flush_if_dirty()

func _profile_flush_if_dirty() -> void:
	if not _profile_dirty:
		return
	# Guard against the startup race: dirty flag set before bootstrap
	# completed. Skipping the save is safer than writing an empty state.
	if not _profile_bootstrap_complete:
		return
	_profile_save(_active_profile_idx)
	_profile_dirty = false
	_profile_dirty_count = 0
	_profile_save_timer = 0.0

# ── Atomic file I/O ───────────────────────────────────────────

func _profile_path(idx: int) -> String:
	# On-disk files are 1-indexed (profile_1.cfg, profile_2.cfg, ...) for
	# human-friendliness; internal idx is 0-indexed.
	return "%sprofile_%d.cfg" % [PROFILE_DIR, idx + 1]

func _profile_ensure_dir() -> bool:
	# M1 fix — cache the verified result. Every _profile_write_atomic
	# was calling this, meaning two DirAccess.open() roundtrips per
	# save (once here, once for the rename). The dir doesn't vanish
	# mid-session in practice, so once we've verified it exists we
	# can short-circuit. First call does the real check.
	if _profile_dir_verified:
		return true
	var da := DirAccess.open("user://")
	if da == null:
		_log("profile: cannot open user:// for DirAccess", "warning")
		return false
	if not da.dir_exists(PROFILE_DIR):
		var err := da.make_dir_recursive(PROFILE_DIR)
		if err != OK:
			_log("profile: make_dir_recursive failed (err %d) on %s" % [err, PROFILE_DIR], "warning")
			return false
	_profile_dir_verified = true
	return true

func _profile_write_atomic(path: String, cfg: ConfigFile) -> bool:
	if not _profile_ensure_dir():
		return false
	var tmp := path + ".tmp"
	var save_err := cfg.save(tmp)
	if save_err != OK:
		_log("profile: tmp write failed (err %d) on %s" % [save_err, tmp], "warning")
		return false
	# DirAccess.rename refuses to overwrite on Windows, so clear the
	# destination first. If the remove fails, the rename will also fail
	# below and we report the error uniformly.
	var da := DirAccess.open("user://")
	if da == null:
		_log("profile: DirAccess.open user:// failed during rename", "warning")
		return false
	if FileAccess.file_exists(path):
		var rm_err := da.remove(path)
		if rm_err != OK and rm_err != ERR_FILE_NOT_FOUND:
			_log("profile: pre-rename remove failed (err %d) on %s" % [rm_err, path], "warning")
			# Fall through — rename may still succeed on some filesystems.
	var rn_err := da.rename(tmp, path)
	if rn_err != OK:
		_log("profile: rename failed (err %d) %s → %s" % [rn_err, tmp, path], "warning")
		# Leave the .tmp in place for diagnostic purposes; will be
		# overwritten on next successful save.
		return false
	return true

func _profile_read_active_pointer() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(PROFILE_ACTIVE_PATH) != OK:
		return 0
	var idx: int = int(cfg.get_value("active", "idx", 0))
	if idx < 0 or idx >= PROFILE_COUNT:
		return 0
	return idx

func _profile_write_active_pointer(idx: int) -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("active", "idx", idx)
	cfg.set_value("active", "schema_version", PROFILE_SCHEMA_VERSION)
	return _profile_write_atomic(PROFILE_ACTIVE_PATH, cfg)

# ── Serialization layer: live state → Dictionary ──────────────

func _profile_serialize_live() -> Dictionary:
	var d := {
		"meta": _profile_serialize_meta(),
		"cheats": _profile_serialize_cheats(),
		"favorites": _profile_serialize_favorites(),
		"teleport_slots": _profile_serialize_teleports(),
		"keybinds": _profile_serialize_keybinds(),
		"tuner": _profile_serialize_tuner(),
		"real_time": _profile_serialize_real_time(),
	}
	return d

func _profile_serialize_meta() -> Dictionary:
	# Meta is filled in around a serialized live dict by the caller —
	# this function returns a stub; _profile_save() stamps name, uuid,
	# last_modified, content_hash into it before writing. Keeps the
	# serializer pure.
	return {
		"schema_version": PROFILE_SCHEMA_VERSION,
		"mod_version": VERSION,
	}

func _profile_serialize_cheats() -> Dictionary:
	var out := {}
	for var_name in SETTABLE_VARS:
		out[var_name] = get(var_name)
	return out

func _profile_serialize_favorites() -> Array:
	return favorite_actions.duplicate()

func _profile_serialize_teleports() -> Array:
	# Deep-copy so mutating the live array after serialization doesn't
	# corrupt the captured snapshot. Each slot is a flat Dictionary, so
	# a shallow duplicate of each entry is sufficient.
	var out: Array = []
	for slot in teleport_slots:
		if slot is Dictionary:
			out.append(slot.duplicate())
	return out

func _profile_serialize_keybinds() -> Dictionary:
	var out := {}
	for action_name in keybinds.keys():
		var bind = keybinds[action_name]
		if bind is Dictionary:
			out[action_name] = bind.duplicate()
	return out

func _profile_serialize_tuner() -> Dictionary:
	var out := {
		"enabled": cheat_tuner_enabled,
		"drain_mult": {},
		"regen_mult": {},
		"freeze": {},
		"freeze_val": {},
		"lock_max": {},
		"immune": {},
	}
	for v in TUNER_VITALS:
		out["drain_mult"][v] = tuner_drain_mult.get(v, 1.0)
		out["regen_mult"][v] = tuner_regen_mult.get(v, 1.0)
		out["freeze"][v] = tuner_freeze.get(v, false)
		out["freeze_val"][v] = tuner_freeze_val.get(v, 100.0)
		out["lock_max"][v] = tuner_lock_max.get(v, false)
	for c in TUNER_CONDITIONS:
		out["immune"][c] = tuner_immune.get(c, false)
	return out

func _profile_serialize_real_time() -> Dictionary:
	return {"enabled": cheat_real_time}

# ── Apply layer: Dictionary → live state (with side-effects) ──

func _profile_apply_dict(d: Dictionary) -> void:
	if not (d is Dictionary) or d.is_empty():
		return
	# Strict apply-order documented in the plan file. Meta is read by
	# _profile_load before we're called, but we recompute fallbacks
	# defensively here in case of manual invocation.
	_profile_suspend_hud = true
	# 1. keybinds (purely internal — no world side-effects)
	if d.has("keybinds"):
		_profile_apply_keybinds(d["keybinds"])
	# 2. favorites (internal list; row refresh happens at finalize)
	if d.has("favorites"):
		_profile_apply_favorites(d["favorites"])
	# 3. real_time (scalar bool; no legacy save trigger from here)
	if d.has("real_time"):
		_profile_apply_real_time_dict(d["real_time"])
	# 4. tuner (must precede cheat_tuner_enabled so master-dim visuals
	#    paint against the final values)
	if d.has("tuner"):
		_profile_apply_tuner(d["tuner"])
	# 5. teleports
	if d.has("teleport_slots"):
		_profile_apply_teleports(d["teleport_slots"])
	# 6. cheats (LAST; two-pass inside)
	if d.has("cheats"):
		_profile_apply_cheats(d["cheats"])
	_profile_suspend_hud = false
	# Finalize — one HUD rebuild, one favorites row refresh, chip update.
	_update_hud()
	_refresh_dashboard_favorites_state()
	if is_instance_valid(teleport_picker_list_vbox):
		_refresh_teleport_picker()
	_refresh_profile_chip()

func _profile_apply_keybinds(kb) -> void:
	if not (kb is Dictionary):
		return
	for action_name in kb.keys():
		if not (action_name is String):
			continue
		if action_name not in BINDABLE_ACTIONS:
			continue  # stale key from an older mod version
		var bind = kb[action_name]
		if not (bind is Dictionary):
			continue
		# Defensive field-level type check (mirrors v10.5.1 keybind loader).
		if not (bind.has("key") and typeof(bind["key"]) == TYPE_INT):
			continue
		# Normalize — fill any missing modifier/device flags with defaults.
		var normalized := {
			"device": int(bind.get("device", 0)),
			"key": int(bind["key"]),
			"ctrl": bool(bind.get("ctrl", false)),
			"shift": bool(bind.get("shift", false)),
			"alt": bool(bind.get("alt", false)),
		}
		keybinds[action_name] = normalized
	_refresh_keybind_ui()

func _profile_apply_favorites(favs) -> void:
	if not (favs is Array):
		return
	favorite_actions.clear()
	for v in favs:
		if typeof(v) == TYPE_STRING and v in SETTABLE_VARS and v not in favorite_actions:
			favorite_actions.append(v)
		if favorite_actions.size() >= MAX_FAVORITES:
			break

func _profile_apply_real_time_dict(rt) -> void:
	if not (rt is Dictionary):
		return
	if rt.has("enabled"):
		cheat_real_time = bool(rt["enabled"])

func _profile_apply_tuner(t) -> void:
	if not (t is Dictionary):
		return
	# Populate all tuner maps first, THEN flip cheat_tuner_enabled so the
	# master-state visual paints against the final values.
	if t.has("drain_mult") and t["drain_mult"] is Dictionary:
		for v in TUNER_VITALS:
			if t["drain_mult"].has(v):
				tuner_drain_mult[v] = clampf(float(t["drain_mult"][v]), TUNER_MULT_MIN, TUNER_MULT_MAX)
	if t.has("regen_mult") and t["regen_mult"] is Dictionary:
		for v in TUNER_VITALS:
			if t["regen_mult"].has(v):
				tuner_regen_mult[v] = clampf(float(t["regen_mult"][v]), TUNER_MULT_MIN, TUNER_MULT_MAX)
	if t.has("freeze") and t["freeze"] is Dictionary:
		for v in TUNER_VITALS:
			if t["freeze"].has(v):
				tuner_freeze[v] = bool(t["freeze"][v])
	if t.has("freeze_val") and t["freeze_val"] is Dictionary:
		for v in TUNER_VITALS:
			if t["freeze_val"].has(v):
				tuner_freeze_val[v] = clampf(float(t["freeze_val"][v]), TUNER_VITAL_MIN, TUNER_VITAL_MAX)
	if t.has("lock_max") and t["lock_max"] is Dictionary:
		for v in TUNER_VITALS:
			if t["lock_max"].has(v):
				tuner_lock_max[v] = bool(t["lock_max"][v])
	if t.has("immune") and t["immune"] is Dictionary:
		for c in TUNER_CONDITIONS:
			if t["immune"].has(c):
				tuner_immune[c] = bool(t["immune"][c])
	if t.has("enabled"):
		cheat_tuner_enabled = bool(t["enabled"])
		_apply_tuner_master(cheat_tuner_enabled)

func _profile_apply_teleports(tps) -> void:
	if not (tps is Array):
		return
	teleport_slots.clear()
	_teleport_next_id = 1
	var max_id := 0
	for v in tps:
		if not (v is Dictionary and v.has("name") and v.has("pos") and v["pos"] is Vector3):
			continue
		var id := int(v.get("id", 0))
		if id <= 0:
			id = max_id + 1
		teleport_slots.append({
			"id": id,
			"name": String(v["name"]),
			"pos": v["pos"],
		})
		if id > max_id:
			max_id = id
		if teleport_slots.size() >= MAX_TELEPORT_SLOTS:
			break
	_teleport_next_id = max_id + 1

func _profile_apply_cheats(cheats) -> void:
	if not (cheats is Dictionary):
		return
	# Pass A — safe, no controller dependency.
	var pass_a := ["cheat_fov", "cheat_time_speed", "cheat_freeze_time",
				   "cheat_fly_speed", "cheat_fly_sprint_mult",
				   "cheat_ai_esp_theme"]
	for var_name in pass_a:
		if cheats.has(var_name):
			_profile_apply_one_cheat(var_name, cheats[var_name])
	# Pass B — controller-gated or side-effect-heavy.
	var pass_b_controller := ["cheat_speed_mult", "cheat_jump_mult",
							  "cheat_no_overweight", "cheat_no_fall_dmg",
							  "cheat_no_recoil", "cheat_no_headbob",
							  "cheat_unlock_crafting"]
	var pass_b_generic: Array = []
	# Anything not in pass_a or pass_b_controller gets a generic apply.
	for var_name in SETTABLE_VARS:
		if var_name in pass_a or var_name in pass_b_controller:
			continue
		if cheats.has(var_name):
			pass_b_generic.append(var_name)

	if controller_found and is_instance_valid(controller):
		for var_name in pass_b_controller:
			if cheats.has(var_name):
				_profile_apply_one_cheat(var_name, cheats[var_name])
		for var_name in pass_b_generic:
			_profile_apply_one_cheat(var_name, cheats[var_name])
	else:
		# Controller not ready — apply generics now (they don't need it),
		# defer controller-gated vars until _process sees controller_found.
		for var_name in pass_b_generic:
			_profile_apply_one_cheat(var_name, cheats[var_name])
		_profile_pending_world_cheats.clear()
		for var_name in pass_b_controller:
			if cheats.has(var_name):
				_profile_pending_world_cheats[var_name] = cheats[var_name]
		if not _profile_pending_world_cheats.is_empty():
			_profile_pending_world_apply = true

func _profile_apply_one_cheat(var_name: String, value) -> void:
	if var_name not in SETTABLE_VARS:
		return
	var expected_type: int = typeof(get(var_name))
	var got_type: int = typeof(value)
	# Allow int↔float promotion since ConfigFile can round-trip either.
	if got_type != expected_type:
		var can_promote := (expected_type == TYPE_FLOAT and got_type == TYPE_INT) \
						or (expected_type == TYPE_INT and got_type == TYPE_FLOAT)
		if not can_promote:
			_log("profile: type mismatch on %s (expected %d, got %d), skipping" \
				% [var_name, expected_type, got_type], "warning")
			return
	if expected_type == TYPE_FLOAT:
		set(var_name, float(value))
	elif expected_type == TYPE_INT:
		set(var_name, int(value))
	elif expected_type == TYPE_BOOL:
		set(var_name, bool(value))
	else:
		set(var_name, value)
	_apply_cheat_side_effects(var_name, get(var_name))

func _profile_bootstrap_deferred_world() -> void:
	# Drained from _process once controller_found flips true. Applies any
	# controller-gated cheats queued from a bootstrap or switch that
	# happened before the Controller was in the scene.
	if not _profile_pending_world_apply:
		return
	if not controller_found or not is_instance_valid(controller):
		return
	_profile_suspend_hud = true
	for var_name in _profile_pending_world_cheats.keys():
		_profile_apply_one_cheat(var_name, _profile_pending_world_cheats[var_name])
	_profile_suspend_hud = false
	_profile_pending_world_cheats.clear()
	_profile_pending_world_apply = false
	_update_hud()

# ── Dictionary ↔ ConfigFile bridge ────────────────────────────

func _profile_dict_to_cfg(d: Dictionary) -> ConfigFile:
	var cfg := ConfigFile.new()
	# [meta]
	var meta: Dictionary = d.get("meta", {})
	for k in meta.keys():
		cfg.set_value("meta", String(k), meta[k])
	# [cheats] — one key per var
	var cheats: Dictionary = d.get("cheats", {})
	for k in cheats.keys():
		cfg.set_value("cheats", String(k), cheats[k])
	# [favorites] — store as single list
	cfg.set_value("favorites", "list", d.get("favorites", []))
	# [teleport_slots]
	cfg.set_value("teleport_slots", "list", d.get("teleport_slots", []))
	# [keybinds] — one key per action
	var binds: Dictionary = d.get("keybinds", {})
	for k in binds.keys():
		cfg.set_value("keybinds", String(k), binds[k])
	# [tuner] — mirrors _tuner_save_cfg's section layout for forward compat
	var tuner: Dictionary = d.get("tuner", {})
	cfg.set_value("tuner", "enabled", tuner.get("enabled", false))
	for sub in ["drain_mult", "regen_mult", "freeze", "freeze_val", "lock_max"]:
		var sub_dict: Dictionary = tuner.get(sub, {})
		for v in TUNER_VITALS:
			if sub_dict.has(v):
				cfg.set_value("tuner." + sub, v, sub_dict[v])
	var immune_dict: Dictionary = tuner.get("immune", {})
	for c in TUNER_CONDITIONS:
		if immune_dict.has(c):
			cfg.set_value("tuner.immune", c, immune_dict[c])
	# [real_time]
	cfg.set_value("real_time", "enabled", d.get("real_time", {}).get("enabled", false))
	return cfg

func _profile_cfg_to_dict(cfg: ConfigFile) -> Dictionary:
	var d := {}
	# [meta]
	var meta := {}
	if cfg.has_section("meta"):
		for k in cfg.get_section_keys("meta"):
			meta[k] = cfg.get_value("meta", k)
	d["meta"] = meta
	# [cheats]
	var cheats := {}
	if cfg.has_section("cheats"):
		for k in cfg.get_section_keys("cheats"):
			cheats[k] = cfg.get_value("cheats", k)
	d["cheats"] = cheats
	# [favorites]
	d["favorites"] = cfg.get_value("favorites", "list", [])
	# [teleport_slots]
	d["teleport_slots"] = cfg.get_value("teleport_slots", "list", [])
	# [keybinds]
	var binds := {}
	if cfg.has_section("keybinds"):
		for k in cfg.get_section_keys("keybinds"):
			binds[k] = cfg.get_value("keybinds", k)
	d["keybinds"] = binds
	# [tuner] — reassemble nested sub-dicts
	var tuner := {
		"enabled": bool(cfg.get_value("tuner", "enabled", false)),
		"drain_mult": {}, "regen_mult": {}, "freeze": {},
		"freeze_val": {}, "lock_max": {}, "immune": {},
	}
	for sub in ["drain_mult", "regen_mult", "freeze", "freeze_val", "lock_max"]:
		var sec: String = "tuner." + String(sub)
		if cfg.has_section(sec):
			for k in cfg.get_section_keys(sec):
				tuner[sub][k] = cfg.get_value(sec, k)
	if cfg.has_section("tuner.immune"):
		for k in cfg.get_section_keys("tuner.immune"):
			tuner["immune"][k] = cfg.get_value("tuner.immune", k)
	d["tuner"] = tuner
	# [real_time]
	d["real_time"] = {"enabled": bool(cfg.get_value("real_time", "enabled", false))}
	return d

# ── Core ops ──────────────────────────────────────────────────

func _profile_load(idx: int, apply_live: bool = true) -> bool:
	if idx < 0 or idx >= PROFILE_COUNT:
		return false
	var path := _profile_path(idx)
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if err != OK:
		if err != ERR_FILE_NOT_FOUND:
			_log("profile: load(%d) failed err=%d path=%s" % [idx, err, path], "warning")
			_show_toast("Profile %d unreadable — using defaults" % (idx + 1), COL_NEGATIVE)
		# Missing/corrupt file: apply defaults to live state if requested,
		# but DO NOT overwrite the file (preserves recovery if the file
		# was briefly corrupt mid-write).
		if apply_live:
			_profile_apply_dict(_profile_defaults_dict(idx))
		return false
	# Schema gate
	var schema: int = int(cfg.get_value("meta", "schema_version", 1))
	if schema > PROFILE_SCHEMA_VERSION:
		_log("profile: schema %d newer than runtime %d — refusing load" \
			% [schema, PROFILE_SCHEMA_VERSION], "warning")
		_show_toast("Profile %d written by newer mod — update to load" % (idx + 1), COL_NEGATIVE)
		return false
	if apply_live:
		_profile_apply_dict(_profile_cfg_to_dict(cfg))
	# Refresh metadata cache slot even on apply=false (LOAD preview).
	_profile_refresh_meta_slot(idx, cfg)
	return true

func _profile_save(idx: int) -> bool:
	if idx < 0 or idx >= PROFILE_COUNT:
		return false
	# Belt-and-suspenders: never serialize empty tuner state. In the
	# v10.6.0 _ready order this is unreachable (tuner inits BEFORE
	# bootstrap), but keeping the guard protects against a future
	# ordering regression silently wiping tuner data. Cheap check.
	if tuner_drain_mult.is_empty():
		_log("profile: save(%d) skipped — tuner state not yet seeded" % idx, "warning")
		return false
	var d := _profile_serialize_live()
	# Stamp live meta into the dict before writing.
	var meta: Dictionary = d.get("meta", {})
	meta["name"] = _profile_names[idx] if idx < _profile_names.size() else PROFILE_DEFAULT_NAMES[idx]
	meta["uuid"] = _profile_uuids[idx] if idx < _profile_uuids.size() and _profile_uuids[idx] != "" else _profile_new_uuid()
	meta["last_modified"] = int(Time.get_unix_time_from_system())
	if idx < _profile_uuids.size():
		_profile_uuids[idx] = meta["uuid"]
	if idx < _profile_last_modified.size():
		_profile_last_modified[idx] = meta["last_modified"]
	d["meta"] = meta
	var cfg := _profile_dict_to_cfg(d)
	if not _profile_write_atomic(_profile_path(idx), cfg):
		_show_toast("Failed to save profile %d" % (idx + 1), COL_NEGATIVE)
		return false
	_profile_refresh_meta_slot(idx, cfg)
	return true

func _profile_switch(target_idx: int) -> bool:
	if _profile_load_in_progress:
		return false
	if target_idx < 0 or target_idx >= PROFILE_COUNT:
		return false
	if target_idx == _active_profile_idx:
		return true  # no-op
	if _profile_any_modal_open():
		_show_toast("Close dialog first", COL_NEGATIVE)
		return false
	_profile_load_in_progress = true
	# 1. Flush current (if any pending changes).
	_profile_flush_if_dirty()
	# 2. Parse target into a staging dict — abort if unparseable/schema-bad.
	var cfg := ConfigFile.new()
	var path := _profile_path(target_idx)
	var staging: Dictionary
	var load_err := cfg.load(path)
	if load_err == OK:
		var schema: int = int(cfg.get_value("meta", "schema_version", 1))
		if schema > PROFILE_SCHEMA_VERSION:
			_log("profile: switch refused — slot %d schema %d newer than %d" \
				% [target_idx, schema, PROFILE_SCHEMA_VERSION], "warning")
			_show_toast("Profile %d from newer mod version" % (target_idx + 1), COL_NEGATIVE)
			_profile_load_in_progress = false
			return false
		staging = _profile_cfg_to_dict(cfg)
	else:
		# Missing/unreadable — switch to defaults so the slot becomes usable.
		staging = _profile_defaults_dict(target_idx)
	# 3. Write active pointer atomically BEFORE applying — if we crash
	#    during apply, the next launch points at the target and loads it
	#    cleanly rather than pointing at a half-loaded source.
	if not _profile_write_active_pointer(target_idx):
		_profile_load_in_progress = false
		return false
	_active_profile_idx = target_idx
	# 4. Apply.
	_profile_apply_dict(staging)
	# 5. Clean up dirty flag (new slot's state is freshly in sync).
	_profile_dirty = false
	_profile_dirty_count = 0
	_profile_save_timer = 0.0
	_profile_load_in_progress = false
	_show_toast("Loaded profile: %s" % _profile_names[target_idx])
	if cheat_active_tab == "Profiles":
		_refresh_profiles_ui()
	return true

func _profile_reset(idx: int) -> bool:
	if idx < 0 or idx >= PROFILE_COUNT:
		return false
	var defaults := _profile_defaults_dict(idx)
	var cfg := _profile_dict_to_cfg(defaults)
	# Stamp meta.
	cfg.set_value("meta", "schema_version", PROFILE_SCHEMA_VERSION)
	cfg.set_value("meta", "name", PROFILE_DEFAULT_NAMES[idx])
	cfg.set_value("meta", "uuid", _profile_new_uuid())
	cfg.set_value("meta", "last_modified", int(Time.get_unix_time_from_system()))
	cfg.set_value("meta", "mod_version", VERSION)
	if not _profile_write_atomic(_profile_path(idx), cfg):
		_show_toast("Failed to reset profile %d" % (idx + 1), COL_NEGATIVE)
		return false
	_profile_refresh_meta_slot(idx, cfg)
	# If the active slot was reset, re-apply defaults to live state.
	if idx == _active_profile_idx:
		_profile_apply_dict(defaults)
		_profile_dirty = false
		_profile_dirty_count = 0
	_show_toast("Profile %d reset" % (idx + 1))
	if cheat_active_tab == "Profiles":
		_refresh_profiles_ui()
	return true

func _profile_rename(idx: int, new_name: String) -> bool:
	if idx < 0 or idx >= PROFILE_COUNT:
		return false
	var sanitized := _profile_sanitize_name(new_name)
	if sanitized == "":
		return false  # caller keeps old name
	if idx < _profile_names.size():
		_profile_names[idx] = sanitized
	# Rewrite the file meta. Load existing cfg, update name, atomic save.
	var cfg := ConfigFile.new()
	var err := cfg.load(_profile_path(idx))
	if err == OK:
		cfg.set_value("meta", "name", sanitized)
		cfg.set_value("meta", "last_modified", int(Time.get_unix_time_from_system()))
		_profile_write_atomic(_profile_path(idx), cfg)
		_profile_refresh_meta_slot(idx, cfg)
	# If active, update the HUD chip.
	if idx == _active_profile_idx:
		_refresh_profile_chip()
	if cheat_active_tab == "Profiles":
		_refresh_profiles_ui()
	return true

func _profile_copy(from_idx: int, to_idx: int, new_name: String) -> bool:
	# Copies the CURRENT LIVE STATE (not from_idx's file) into to_idx. Used
	# as the "SAVE" button on non-active slot cards: copies what you're
	# currently running into that slot.
	if to_idx < 0 or to_idx >= PROFILE_COUNT:
		return false
	var sanitized := _profile_sanitize_name(new_name)
	if sanitized == "":
		sanitized = String(PROFILE_DEFAULT_NAMES[to_idx])
	if to_idx < _profile_names.size():
		_profile_names[to_idx] = sanitized
	# Regenerate UUID — copy is a new slot identity.
	if to_idx < _profile_uuids.size():
		_profile_uuids[to_idx] = _profile_new_uuid()
	var ok := _profile_save(to_idx)
	if ok:
		_show_toast("Saved live state → %s" % sanitized)
	return ok

# ── Bootstrap / migration ─────────────────────────────────────

func _profile_bootstrap_early() -> void:
	# Called from _ready BEFORE the legacy _load_X() calls. Populates
	# profile metadata caches and the active-pointer, then applies the
	# active profile's non-world state. Controller-gated state is queued
	# for _profile_bootstrap_deferred_world().
	_profile_names.resize(PROFILE_COUNT)
	_profile_uuids.resize(PROFILE_COUNT)
	_profile_last_modified.resize(PROFILE_COUNT)
	_profile_summaries.resize(PROFILE_COUNT)
	for i in range(PROFILE_COUNT):
		_profile_names[i] = PROFILE_DEFAULT_NAMES[i]
		_profile_uuids[i] = ""
		_profile_last_modified[i] = 0
		_profile_summaries[i] = {}

	if not _profile_ensure_dir():
		# DirAccess failed — profile system can't work. Fall back to
		# legacy loads. _profile_bootstrap_complete stays false so
		# mutations won't try to flush.
		return

	var first_run := not FileAccess.file_exists(PROFILE_ACTIVE_PATH)
	if first_run:
		_log("profile: first-run migration — seeding profile 1 from legacy cfgs")
		var legacy_dict := _profile_migrate_legacy()
		# Write slot 1 with migrated state + empty slots 2/3.
		_profile_write_slot_dict(0, legacy_dict, PROFILE_DEFAULT_NAMES[0])
		_profile_write_slot_dict(1, _profile_defaults_dict(1), PROFILE_DEFAULT_NAMES[1])
		_profile_write_slot_dict(2, _profile_defaults_dict(2), PROFILE_DEFAULT_NAMES[2])
		_profile_write_active_pointer(0)
		_active_profile_idx = 0
	else:
		_active_profile_idx = _profile_read_active_pointer()

	# Populate meta cache from disk.
	for i in range(PROFILE_COUNT):
		var cfg := ConfigFile.new()
		if cfg.load(_profile_path(i)) == OK:
			_profile_refresh_meta_slot(i, cfg)

	# Apply active profile's non-world sections to live state.
	# Controller-gated vars may queue via _profile_pending_world_apply.
	var active_cfg := ConfigFile.new()
	if active_cfg.load(_profile_path(_active_profile_idx)) == OK:
		_profile_apply_dict(_profile_cfg_to_dict(active_cfg))

	_profile_bootstrap_complete = true

func _profile_migrate_legacy() -> Dictionary:
	# Read existing v10.5.x per-subsystem cfgs into a fresh profile dict.
	# Each read uses direct ConfigFile ops — we don't invoke the legacy
	# _load_X() functions because those also mutate live state, and at
	# this point bootstrap hasn't run yet so live state is all defaults.
	var d := _profile_defaults_dict(0)

	# favorites.cfg → favorites
	var fav_cfg := ConfigFile.new()
	if fav_cfg.load(FAVORITES_CONFIG_PATH) == OK:
		var raw = fav_cfg.get_value("favorites", "list", [])
		if raw is Array:
			var out: Array = []
			for v in raw:
				if typeof(v) == TYPE_STRING and v in SETTABLE_VARS and v not in out:
					out.append(v)
			d["favorites"] = out

	# teleport_slots.cfg → teleport_slots
	# v10.6.2 — M2 fix: validate each slot's dict shape during migration
	# rather than trusting _profile_apply_teleports to filter at load.
	# Prevents bad data from being re-saved into the shiny new profile
	# file. Mirrors the validation inside _profile_apply_teleports so
	# the migrated dict is already clean.
	var tp_cfg := ConfigFile.new()
	if tp_cfg.load(TELEPORT_CONFIG_PATH) == OK:
		var raw = tp_cfg.get_value("slots", "list", [])
		if raw is Array:
			var cleaned: Array = []
			for slot in raw:
				if slot is Dictionary \
						and slot.has("name") and typeof(slot["name"]) == TYPE_STRING \
						and slot.has("pos") and slot["pos"] is Vector3:
					cleaned.append(slot)
				if cleaned.size() >= MAX_TELEPORT_SLOTS:
					break
			d["teleport_slots"] = cleaned

	# binds.cfg → keybinds
	var kb_cfg := ConfigFile.new()
	if kb_cfg.load(KEYBIND_CONFIG_PATH) == OK:
		var out := {}
		for action_name in BINDABLE_ACTIONS.keys():
			var bind = kb_cfg.get_value("binds", action_name, null)
			if bind is Dictionary:
				out[action_name] = bind
		d["keybinds"] = out

	# real_time.cfg → real_time
	var rt_cfg := ConfigFile.new()
	if rt_cfg.load(REAL_TIME_CONFIG_PATH) == OK:
		d["real_time"] = {"enabled": bool(rt_cfg.get_value("cheats", "real_time", false))}

	# vitals_tuner.cfg → tuner (schema_version bumps are handled by
	# _tuner_apply_cfg's existing gate; we replicate its field reads here).
	var tu_cfg := ConfigFile.new()
	if tu_cfg.load(TUNER_CONFIG_PATH) == OK:
		var tuner := {
			"enabled": bool(tu_cfg.get_value("tuner", "enabled", false)),
			"drain_mult": {}, "regen_mult": {}, "freeze": {},
			"freeze_val": {}, "lock_max": {}, "immune": {},
		}
		for v in TUNER_VITALS:
			tuner["drain_mult"][v] = clampf(float(tu_cfg.get_value("tuner.drain_mult", v, 1.0)), TUNER_MULT_MIN, TUNER_MULT_MAX)
			tuner["regen_mult"][v] = clampf(float(tu_cfg.get_value("tuner.regen_mult", v, 1.0)), TUNER_MULT_MIN, TUNER_MULT_MAX)
			tuner["freeze"][v] = bool(tu_cfg.get_value("tuner.freeze", v, false))
			tuner["freeze_val"][v] = clampf(float(tu_cfg.get_value("tuner.freeze_val", v, TUNER_VITAL_MAX)), TUNER_VITAL_MIN, TUNER_VITAL_MAX)
			tuner["lock_max"][v] = bool(tu_cfg.get_value("tuner.lock_max", v, false))
		for c in TUNER_CONDITIONS:
			tuner["immune"][c] = bool(tu_cfg.get_value("tuner.immune", c, false))
		d["tuner"] = tuner

	# Cheats aren't persisted in any legacy file (in-memory only in v10.5.x),
	# so migrated profile 1's [cheats] section stays at defaults.
	return d

func _profile_write_slot_dict(idx: int, d: Dictionary, name: String) -> bool:
	var cfg := _profile_dict_to_cfg(d)
	cfg.set_value("meta", "schema_version", PROFILE_SCHEMA_VERSION)
	cfg.set_value("meta", "name", name)
	var uuid := _profile_new_uuid()
	cfg.set_value("meta", "uuid", uuid)
	cfg.set_value("meta", "created_at", int(Time.get_unix_time_from_system()))
	cfg.set_value("meta", "last_modified", int(Time.get_unix_time_from_system()))
	cfg.set_value("meta", "mod_version", VERSION)
	if idx < _profile_names.size():
		_profile_names[idx] = name
	if idx < _profile_uuids.size():
		_profile_uuids[idx] = uuid
	return _profile_write_atomic(_profile_path(idx), cfg)

func _profile_default_cheats() -> Dictionary:
	# Single source of truth for shipping-default values across all
	# SETTABLE_VARS. Used by (a) _profile_defaults_dict when seeding an
	# empty slot and (b) _profile_refresh_meta_slot's summary counter to
	# decide which cheats "deviate from default" — a count of "user has
	# customized this" rather than "this var is literally true". Kept in
	# lock-step with the class var declarations; add new SETTABLE_VARS
	# entries here too.
	return {
		"cheat_god_mode": false, "cheat_inf_stamina": false, "cheat_inf_energy": false,
		"cheat_inf_hydration": false, "cheat_inf_oxygen": false, "cheat_max_mental": false,
		"cheat_no_temp_loss": false, "cheat_no_overweight": false,
		"cheat_speed_mult": 1.0, "cheat_jump_mult": 1.0,
		"cheat_freeze_time": false, "cheat_time_speed": 1.0,
		"cheat_no_recoil": false, "cheat_no_fall_dmg": false,
		"cheat_no_headbob": false, "cheat_inf_ammo": false, "cheat_no_jam": false,
		"cheat_inf_armor": false, "cheat_cat_immortal": false,
		"cheat_fov": 70.0, "cheat_unlock_crafting": false,
		"cheat_tac_hud": false, "cheat_real_time": false,
		"cheat_tuner_enabled": false, "cheat_auto_med": false,
		"cheat_noclip": false, "cheat_fly_speed": 15.0, "cheat_fly_sprint_mult": 4.0,
		"cheat_ai_invisible": false, "cheat_ai_esp": false, "cheat_ai_freeze": false,
		"cheat_ai_esp_walls": true,   # thermal-see-through-walls default per v10.5.10
		"cheat_ai_esp_theme": ESP_THEME_VOSTOK,
		"cheat_ai_esp_hide_dead": true,  # skip killed AIs per v10.6.1 (_davodal_ feedback)
	}

func _profile_defaults_dict(_idx: int) -> Dictionary:
	# The canonical "empty" profile: every SETTABLE_VARS entry at its
	# declared default.
	var cheats := {}
	var defaults := _profile_default_cheats()
	for k in defaults.keys():
		cheats[k] = defaults[k]
	var tuner := {
		"enabled": false,
		"drain_mult": {}, "regen_mult": {}, "freeze": {},
		"freeze_val": {}, "lock_max": {}, "immune": {},
	}
	for v in TUNER_VITALS:
		tuner["drain_mult"][v] = 1.0
		tuner["regen_mult"][v] = 1.0
		tuner["freeze"][v] = false
		tuner["freeze_val"][v] = TUNER_VITAL_MAX
		tuner["lock_max"][v] = false
	for c in TUNER_CONDITIONS:
		tuner["immune"][c] = false
	return {
		"meta": {"schema_version": PROFILE_SCHEMA_VERSION, "mod_version": VERSION},
		"cheats": cheats,
		"favorites": [],
		"teleport_slots": [],
		"keybinds": {},  # empty = "use BINDABLE_ACTIONS defaults on load"
		"tuner": tuner,
		"real_time": {"enabled": false},
	}

# ── Metadata cache ────────────────────────────────────────────

func _profile_refresh_meta_slot(idx: int, cfg: ConfigFile) -> void:
	if idx < 0 or idx >= PROFILE_COUNT:
		return
	# H2 fix — sanitize on READ as well as write. A hand-edited or
	# externally-transferred profile could have control chars or an
	# oversize name in [meta] name; sanitizing here keeps the UI chip
	# and card label clean without the user ever having to re-save.
	var name := _profile_sanitize_name(String(cfg.get_value("meta", "name", PROFILE_DEFAULT_NAMES[idx])))
	if name == "":
		name = PROFILE_DEFAULT_NAMES[idx]
	var uuid := String(cfg.get_value("meta", "uuid", ""))
	var last_mod := int(cfg.get_value("meta", "last_modified", 0))
	if idx < _profile_names.size():
		_profile_names[idx] = name
	if idx < _profile_uuids.size():
		_profile_uuids[idx] = uuid
	if idx < _profile_last_modified.size():
		_profile_last_modified[idx] = last_mod
	# Rich summary cache backing the profile card's content sections.
	# "cheats_on" / "teleports" / "favorites" / "keybinds" are scalar
	# counts (kept for backward-compat with old code paths that read
	# them). The *_items arrays hold the actual list data the UI
	# renders — friendly label + detail suffix per row. Computed once
	# per save/load/reset, read many times per card refresh.
	# "cheats_on" counts vars that DEVIATE from the shipping default,
	# so an empty profile correctly reads "0" even when cheat_ai_esp_walls
	# defaults to true.
	var sum := {
		"cheats_on": 0, "favorites": 0, "teleports": 0, "keybinds": 0,
		"cheats_items": [], "teleports_items": [],
		"favorites_items": [], "keybinds_items": [],
		"last_modified": last_mod,
	}
	var defaults := _profile_default_cheats()
	if cfg.has_section("cheats"):
		for k in cfg.get_section_keys("cheats"):
			if not defaults.has(k):
				continue  # stale var from an older mod version
			var v = cfg.get_value("cheats", k)
			var d = defaults[k]
			var deviates := false
			if typeof(v) == TYPE_FLOAT and typeof(d) == TYPE_FLOAT:
				deviates = abs(float(v) - float(d)) > 0.001
			else:
				deviates = (v != d)
			if deviates:
				sum["cheats_on"] += 1
				sum["cheats_items"].append({
					"label": _favorite_label(k),
					"detail": _profile_format_cheat_value(k, v),
				})
	var favs = cfg.get_value("favorites", "list", [])
	if favs is Array:
		sum["favorites"] = favs.size()
		for fv in favs:
			if typeof(fv) == TYPE_STRING:
				sum["favorites_items"].append({"label": _favorite_label(String(fv))})
	var tps = cfg.get_value("teleport_slots", "list", [])
	if tps is Array:
		sum["teleports"] = tps.size()
		for t in tps:
			if not (t is Dictionary):
				continue
			var tp_name: String = String(t.get("name", "?"))
			var tp_pos = t.get("pos", Vector3.ZERO)
			if not (tp_pos is Vector3):
				tp_pos = Vector3.ZERO
			sum["teleports_items"].append({
				"label": tp_name,
				"detail": "%.0f, %.0f, %.0f" % [tp_pos.x, tp_pos.y, tp_pos.z],
			})
	if cfg.has_section("keybinds"):
		var kb_keys := cfg.get_section_keys("keybinds")
		sum["keybinds"] = kb_keys.size()
		for action_name in kb_keys:
			var bind = cfg.get_value("keybinds", action_name)
			if not (bind is Dictionary):
				continue
			var entry = BINDABLE_ACTIONS.get(action_name, {})
			var action_label: String = String(entry.get("label", action_name))
			sum["keybinds_items"].append({
				"label": action_label,
				"detail": _bind_display_name(bind),
			})
	if idx < _profile_summaries.size():
		_profile_summaries[idx] = sum

# ── Utility ───────────────────────────────────────────────────

func _profile_new_uuid() -> String:
	# Short pseudo-UUID — sufficient for slot identity + future sync
	# matching; not a cryptographic identifier.
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%08x-%04x-%04x" % [rng.randi(), rng.randi() & 0xFFFF, rng.randi() & 0xFFFF]

func _profile_sanitize_name(s: String) -> String:
	var out := s.strip_edges()
	# Strip control chars (0x00–0x1F) and DEL (0x7F); ConfigFile tolerates
	# them but they render ugly in the UI and could foul up file encodings.
	var clean := ""
	for ch in out:
		if ch.unicode_at(0) >= 0x20 and ch.unicode_at(0) != 0x7F:
			clean += ch
	if clean.length() > PROFILE_NAME_MAX_LEN:
		clean = clean.substr(0, PROFILE_NAME_MAX_LEN)
	return clean

func _profile_format_cheat_value(var_name: String, value) -> String:
	# Human-readable detail suffix for the profile-card cheats list.
	# Returns "" if the value is just a plain ON boolean (no extra info
	# beyond the label). Sliders and scalars get a terse readout so the
	# user can see what they set without opening the tab.
	match var_name:
		"cheat_speed_mult", "cheat_jump_mult", "cheat_time_speed":
			return "× %.1f" % float(value)
		"cheat_fly_speed":
			return "%.1f m/s" % float(value)
		"cheat_fly_sprint_mult":
			return "sprint × %.1f" % float(value)
		"cheat_fov":
			return "FOV %d°" % int(value)
		"cheat_ai_esp_theme":
			return _profile_esp_theme_name(int(value))
		_:
			# Boolean cheats: "on" is implicit since we only list
			# deviations. Keep the detail empty for a clean look.
			return ""

func _profile_esp_theme_name(theme_idx: int) -> String:
	match theme_idx:
		ESP_THEME_VOSTOK:  return "Vostok Intercept"
		ESP_THEME_THERMAL: return "Thermal"
		ESP_THEME_CHAMS:   return "Spectral Chams"
		_:                 return "Theme %d" % theme_idx

func _profile_any_modal_open() -> bool:
	# H3 fix — include the teleport picker. Profile switch while the
	# picker is open would rebuild teleport_slots under it, leaving
	# stale row bindings pointing at slots that may no longer exist
	# (or have different IDs). Blocking is safer than fixing up mid-op.
	if name_prompt_panel != null and is_instance_valid(name_prompt_panel):
		return true
	if confirm_panel != null and is_instance_valid(confirm_panel):
		return true
	if teleport_picker_panel != null and is_instance_valid(teleport_picker_panel):
		return true
	return false

# ── HUD chip ──────────────────────────────────────────────────

func _refresh_profile_chip() -> void:
	# The HUD is a single Label with a pipe-separated parts list built
	# by _update_hud(). We add the profile name as a prefix chip via
	# _profile_hud_prefix() inside the parts assembly. Here we just
	# kick a rebuild so the new name propagates.
	_update_hud()

func _profile_hud_prefix() -> String:
	# Returns the prefix chip string for the HUD row, e.g. "PROF:Combat".
	# Truncates long names to keep the HUD line readable.
	if _active_profile_idx < 0 or _active_profile_idx >= _profile_names.size():
		return ""
	var name: String = _profile_names[_active_profile_idx]
	if name == "":
		return ""
	const MAX := 10
	if name.length() > MAX:
		name = name.substr(0, MAX) + "…"
	return "PROF:" + name


# ── Favorites persistence ─────────────────────────────────────

func _load_favorites():
	favorite_actions = []
	var cfg := ConfigFile.new()
	var err := cfg.load(FAVORITES_CONFIG_PATH)
	if err != OK:
		# Missing file is the common case (fresh install) — fine to ignore.
		# Any other error means the config file exists but is corrupted,
		# which the user should know about so they can investigate.
		if err != ERR_FILE_NOT_FOUND:
			_log("Failed to load favorites (err %d) from %s" % [err, FAVORITES_CONFIG_PATH], "warning")
		return
	var raw = cfg.get_value("favorites", "list", [])
	if raw is Array:
		# Only keep entries that are still in SETTABLE_VARS so stale
		# entries from old versions don't break the dashboard.
		for v in raw:
			if typeof(v) == TYPE_STRING and v in SETTABLE_VARS and v not in favorite_actions:
				favorite_actions.append(v)

func _save_favorites():
	var cfg := ConfigFile.new()
	cfg.set_value("favorites", "list", favorite_actions)
	var err := cfg.save(FAVORITES_CONFIG_PATH)
	if err != OK:
		_log("Failed to save favorites (err %d) to %s" % [err, FAVORITES_CONFIG_PATH], "warning")
		_show_toast("Failed to save favorites (err %d)" % err, COL_NEGATIVE)

# Real Time sync is the only cheat toggle that persists across sessions,
# because it's an ambient "set it and forget it" feature — if the user
# enabled it last session, they probably still want it on this session.
# All other cheats remain in-memory only so they reset to off at startup.
func _load_real_time_pref():
	var cfg := ConfigFile.new()
	var err := cfg.load(REAL_TIME_CONFIG_PATH)
	if err != OK:
		# Missing file = fresh install, silent default to false.
		if err != ERR_FILE_NOT_FOUND:
			_log("Failed to load real_time pref (err %d) from %s" % [err, REAL_TIME_CONFIG_PATH], "warning")
		return
	cheat_real_time = bool(cfg.get_value("cheats", "real_time", false))
	if cheat_real_time:
		_log("Real Time sync restored from previous session")

func _save_real_time_pref():
	var cfg := ConfigFile.new()
	cfg.set_value("cheats", "real_time", cheat_real_time)
	var err := cfg.save(REAL_TIME_CONFIG_PATH)
	if err != OK:
		_log("Failed to save real_time pref (err %d) to %s" % [err, REAL_TIME_CONFIG_PATH], "warning")

func _toggle_favorite(var_name: String):
	if var_name not in SETTABLE_VARS:
		_show_toast("Not a favoritable cheat", COL_NEGATIVE)
		return
	var friendly = _favorite_label(var_name)
	if favorite_actions.has(var_name):
		favorite_actions.erase(var_name)
		_save_favorites()
		_profile_mark_dirty()  # v10.6.0 dual-write
		_show_toast("Removed '%s' from favorites" % friendly)
	else:
		if favorite_actions.size() >= MAX_FAVORITES:
			_show_toast("Favorites full (max %d)" % MAX_FAVORITES, COL_NEGATIVE)
			return
		favorite_actions.append(var_name)
		_save_favorites()
		_profile_mark_dirty()  # v10.6.0 dual-write
		_show_toast("Added '%s' to favorites" % friendly)
	# Rebuild the favorites row so it reflects the new set.
	if dashboard_panel != null and is_instance_valid(dashboard_favorites_row):
		_rebuild_dashboard_favorites_row()
	# Re-sync every star button in the tab pages so ★/☆ state stays in
	# lockstep with favorite_actions even when the dashboard isn't visible.
	_refresh_favorite_stars()


# ── Inventory / stockpile counts ──────────────────────────────

# Stockpile categories in display order. Dashboard cards iterate this.
const STOCKPILE_CATEGORIES := ["Medical", "Food", "Ammo", "Weapons", "Keys"]

# Accent colors for stockpile row icons. Matches the CATEGORIES constant
# (line 200) where it overlaps — Keys gets its own distinct color.
const STOCKPILE_COLORS := {
	"Medical": Color(0.9, 0.25, 0.35),
	"Food":    Color(0.35, 0.80, 0.35),
	"Ammo":    Color(0.9, 0.7, 0.2),
	"Weapons": Color(0.9, 0.35, 0.25),
	"Keys":    Color(0.8, 0.8, 0.3),
}

# ── Intel / threat radar ──────────────────────────────────────
# AI.gd uses a State enum; values come back as ints. We map them to short
# all-caps tags styled like a military dispatch.
const INTEL_STATE_NAMES := [
	"IDLE", "WANDER", "GUARD", "PATROL", "HIDE", "AMBUSH", "COVER",
	"DEFEND", "SHIFT", "COMBAT", "HUNT", "ATTACK", "VANTAGE", "RETURN",
]
# State indices that count as "actively hunting / engaging the player".
# Used to flag a contact with [!] in the radio readout.
const INTEL_ALERT_STATES := [5, 9, 10, 11]  # Ambush, Combat, Hunt, Attack
# 8-point compass tags. Index from _intel_bearing_for() maps directly here.
const INTEL_BEARING_TAGS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
# Distance buckets. Reported as labels on the contact lines so radio
# chatter feels fuzzy instead of GPS-precise.
const INTEL_BUCKET_CLOSE := 50.0
const INTEL_BUCKET_NEAR := 150.0
const INTEL_BUCKET_MID := 350.0
# Max contacts to enumerate on the readout. Anything over this gets
# summarized as "+N OTHERS". Keeps the card from blowing up on heavy
# spawn maps.
const INTEL_MAX_CONTACTS := 5
# Tactical HUD overlay tunables.
const TAC_HUD_MAX_ROWS := 10
const TAC_HUD_REFRESH_INTERVAL := 0.25

# Bucket a raw item type string into one of the stockpile categories.
# Returns "" if the item should not be counted (e.g. attachments).
func _stockpile_bucket(item_type: String) -> String:
	match item_type:
		"Medical": return "Medical"
		"Ammo":    return "Ammo"
		"Weapon":  return "Weapons"
		"Key":     return "Keys"
		"Consumable", "Consumables", "Fish":
			return "Food"
	return ""

# Helper to build an empty stockpile count dict so every code path returns
# the same shape regardless of which categories happened to be populated.
func _empty_stockpile_counts() -> Dictionary:
	var d := {}
	for cat in STOCKPILE_CATEGORIES:
		d[cat] = 0
	return d

# Walks the player's inventoryGrid ONCE per frame and fills three caches:
# total carry weight, ammo counts by caliber, and stockpile bucket counts.
# Callers below (_get_current_carry_weight, _get_ammo_by_caliber,
# _get_inventory_counts) all read from the cache, so the dashboard's
# 0.5s refresh walks the grid once instead of three times.
func _scan_inventory_if_stale():
	# Weight tracking was dropped from this scan in v10.3.0 — we now
	# read Interface.gd's own currentInventoryWeight / EquipmentWeight /
	# InventoryCapacity properties directly (see _get_current_carry_weight
	# and _get_max_carry_weight). What remains here is stockpile counts
	# by type bucket and ammo totals by caliber, neither of which the
	# game tracks as a property.
	var frame := Engine.get_process_frames()
	if _inv_scan_frame == frame:
		return
	_inv_scan_frame = frame
	_inv_scan_ammo_by_cal = {}
	_inv_scan_counts = _empty_stockpile_counts()
	var interface = _get_interface()
	if interface == null or not is_instance_valid(interface):
		return
	if "inventoryGrid" in interface:
		var grid = interface.inventoryGrid
		if grid != null and is_instance_valid(grid):
			for child in grid.get_children():
				if not is_instance_valid(child) or not "slotData" in child:
					continue
				var sd = child.slotData
				if sd == null or sd.itemData == null:
					continue
				var stackable = _safe(sd.itemData, "stackable", false)
				var amt = int(_safe(sd, "amount", 1)) if stackable else 1
				# Stockpile bucket
				var t = str(_safe(sd.itemData, "type", ""))
				var bucket = _stockpile_bucket(t)
				if bucket != "":
					_inv_scan_counts[bucket] += amt
				# Ammo caliber
				if t == "Ammo":
					var cal = str(_safe(sd.itemData, "caliber", ""))
					if cal != "":
						if cal in _inv_scan_ammo_by_cal:
							_inv_scan_ammo_by_cal[cal] += int(_safe(sd, "amount", 1))
						else:
							_inv_scan_ammo_by_cal[cal] = int(_safe(sd, "amount", 1))
	# Equipped weapons count as Weapons in the stockpile card.
	for slot in ["primary", "secondary"]:
		var wsd = _get_slot_data_for(slot)
		if wsd != null and wsd.itemData != null:
			_inv_scan_counts["Weapons"] += 1

# Count items the player is currently carrying. This includes:
#   1. Items in the main inventoryGrid (rig, backpack, etc. all live here)
#   2. EQUIPPED PRIMARY WEAPON — otherwise a pistol in hand would show 0 guns
#   3. EQUIPPED SECONDARY WEAPON
# Stackable items count their .amount, non-stackable items count as 1.
func _get_inventory_counts() -> Dictionary:
	_scan_inventory_if_stale()
	return _inv_scan_counts.duplicate()

# Current carry weight — reads Interface.gd's own computed
# currentInventoryWeight property. Matches exactly what the inventory
# UI shows in its "KG" readout (Interface.gd:561).
#
# IMPORTANT: we deliberately do NOT add currentEquipmentWeight here.
# The game tracks equipment weight internally for the heavyGear
# stamina flag, but the displayed KG number is purely what's IN the
# grid containers — the backpack/rig/helmet are considered "always
# with you" baseline mass, not part of what you're carrying. Adding
# currentEquipmentWeight would make our readout disagree with the
# inventory UI (e.g. an empty grid with an equipped backpack would
# show 1.8 kg here but 0.0 kg in the inventory).
func _get_current_carry_weight() -> float:
	var iface = _get_interface()
	if iface == null or not is_instance_valid(iface):
		return 0.0
	return float(_safe(iface, "currentInventoryWeight", 0.0))

# Max effective carry capacity — reads Interface.gd's own computed
# currentInventoryCapacity (base + every equipped container's capacity).
# When the No Overweight cheat is active, our override inflates
# baseCarryWeight to 9999; we subtract that back out and add the
# captured original so the player still sees their real effective
# capacity in the display.
func _get_max_carry_weight() -> float:
	var iface = _get_interface()
	if iface == null or not is_instance_valid(iface):
		return base_carry_weight
	var cap: float = float(_safe(iface, "currentInventoryCapacity", base_carry_weight))
	if carry_weight_captured:
		# Substitute the original baseCarryWeight back into the formula
		# so the display doesn't leak the cheat's 9999 sentinel.
		cap = cap - float(_safe(iface, "baseCarryWeight", base_carry_weight)) + base_carry_weight
	return cap

# Returns a dict of {caliber_string: total_amount} counting every ammo
# item in the inventory grouped by its caliber. Used for the ammo match
# widget on the LOADOUT card. Reads from the per-frame inventory scan
# cache — no extra grid walk.
func _get_ammo_by_caliber() -> Dictionary:
	_scan_inventory_if_stale()
	return _inv_scan_ammo_by_cal.duplicate()

# Reads the Cash System balance. Returns -1 if Cash System is not
# installed (soft dependency via Engine metadata). Matches the same
# detection pattern already used in the spawner code.
func _get_cash_balance() -> int:
	if not Engine.has_meta("CashMain"):
		return -1
	var cm = Engine.get_meta("CashMain", null)
	if cm == null or not is_instance_valid(cm):
		return -1
	if cm.has_method("CountCash"):
		return int(cm.CountCash())
	return -1

# Cat status for the WORLD card. Returns a short display string.
# Checks game_data.catDead (bool) and game_data.cat (float health).
func _get_cat_status() -> String:
	if not "cat" in game_data:
		return ""  # Cat system not present
	if _safe(game_data, "catDead", false):
		return "Dead"
	var cat_hp = float(_safe(game_data, "cat", 0.0))
	if cat_hp >= 80.0:
		return "Healthy"
	if cat_hp >= 40.0:
		return "Injured"
	if cat_hp > 0.0:
		return "Critical"
	return "Unknown"

# Same bucketing, but aggregated across every cabin container. Cached
# because iterating ~200 slots on every 0.5s tick is wasteful when the
# cabin state hasn't changed. Cache invalidates on:
#   - dashboard open (forced via _show_dashboard)
#   - cabin browser close (items may have moved)
#   - _force_container_repack (any operation that mutates containers)
#   - manual refresh button
func _get_cabin_counts_cached() -> Dictionary:
	if _cabin_counts_cache_valid:
		return _cabin_counts_cache
	var result := _empty_stockpile_counts()
	if get_tree() == null:
		return result
	for cont_info in _get_cabin_containers():
		var cont = cont_info.get("container")
		if cont == null or not is_instance_valid(cont):
			continue
		if not "storage" in cont or not cont.storage is Array:
			continue
		for slot_data in cont.storage:
			if slot_data == null or slot_data.itemData == null:
				continue
			var t = str(_safe(slot_data.itemData, "type", ""))
			var bucket = _stockpile_bucket(t)
			if bucket == "":
				continue
			var stackable = _safe(slot_data.itemData, "stackable", false)
			if stackable:
				result[bucket] += int(_safe(slot_data, "amount", 1))
			else:
				result[bucket] += 1
	_cabin_counts_cache = result
	_cabin_counts_cache_valid = true
	return result

func _invalidate_cabin_counts_cache():
	_cabin_counts_cache_valid = false


# ── Threat intel helpers ──────────────────────────────────────

# Returns every active AI node in the current scene. The game's enemy
# scenes (Bandit, Guard, Military, Punisher) are all instantiated into
# the "AI" group, so a single group lookup is enough. Returns an empty
# array when the tree is mid-transition or no enemies exist.
func _get_active_enemies() -> Array:
	if get_tree() == null:
		return []
	return get_tree().get_nodes_in_group("AI")

# Locates the AISpawner singleton/scene node and caches the ref. The
# spawner is parented somewhere under the active map scene, so we use
# find_child rather than a hardcoded path. Cache is invalidated by
# is_instance_valid so scene transitions auto-refresh.
func _get_ai_spawner() -> Node:
	if _cached_ai_spawner != null and is_instance_valid(_cached_ai_spawner):
		return _cached_ai_spawner
	if get_tree() == null or get_tree().current_scene == null:
		return null
	_cached_ai_spawner = get_tree().current_scene.find_child("AISpawner", true, false)
	return _cached_ai_spawner

# Map a State enum int to its short tag. Out-of-range or non-int values
# fall back to "UNKNOWN" so a future game update that adds states won't
# crash the dashboard.
func _intel_state_tag(state_value) -> String:
	var idx = int(state_value)
	if idx < 0 or idx >= INTEL_STATE_NAMES.size():
		return "UNKNOWN"
	return INTEL_STATE_NAMES[idx]

# Pulls the player's world position from gameData. Controller writes
# this every physics tick (Scripts/Controller.gd:252). Falls back to
# Vector3.ZERO when game_data isn't initialized yet so the bearing math
# downstream doesn't NaN out on an early dashboard open.
func _intel_get_player_pos() -> Vector3:
	if "playerPosition" in game_data:
		var p = game_data.playerPosition
		if p is Vector3:
			return p
	return Vector3.ZERO

# 8-point compass index from a player-relative AI position. Convention
# is +Z = south so atan2(dx, -dz) puts 0 at north, +X to the east.
# Returns 0..7 indexing INTEL_BEARING_TAGS. Returns 0 (N) when both
# positions coincide so we never produce garbage.
func _intel_bearing_for(player_pos: Vector3, ai_pos: Vector3) -> int:
	var dx: float = ai_pos.x - player_pos.x
	var dz: float = ai_pos.z - player_pos.z
	if abs(dx) < 0.001 and abs(dz) < 0.001:
		return 0
	var angle: float = atan2(dx, -dz)
	var slice: int = int(round(angle / (PI / 4.0)))
	return ((slice % 8) + 8) % 8

# Buckets a raw distance into the four labels we show on the radio
# readout. Keeps the dashboard from re-rendering on every meter walked.
func _intel_distance_bucket(d: float) -> String:
	if d < 0:
		return "??"
	if d <= INTEL_BUCKET_CLOSE:
		return "CLOSE"
	if d <= INTEL_BUCKET_NEAR:
		return "NEAR"
	if d <= INTEL_BUCKET_MID:
		return "MID"
	return "FAR"

# Pulls the active map's mapName property for the SCANNING [...] header.
# Every game scene sets mapName on its root Map node (Cabin.tscn:18 etc).
# Falls back to "SECTOR" when the tree isn't ready (loading screens).
func _intel_current_map_name() -> String:
	if get_tree() == null or get_tree().current_scene == null:
		return "SECTOR"
	var map = get_tree().current_scene
	if "mapName" in map:
		var n = map.mapName
		if n != null and str(n) != "":
			return str(n).to_upper()
	return "SECTOR"

# Derives an enemy's class (Bandit/Guard/Military/Punisher) from its
# scene_file_path since field-spawned AI use instance names like
# "AI_Mosin" that describe their weapon, not their class. The path
# looks like "res://AI/Bandit/AI_Bandit.tscn" — we grab the basename
# and strip the "AI_" prefix. Falls back to the trimmed node name when
# scene_file_path is empty (runtime-instantiated nodes).
func _tac_hud_read_type(enemy, fallback_name: String) -> String:
	if "scene_file_path" in enemy:
		var path: String = String(enemy.scene_file_path)
		if path != "":
			var base: String = path.get_file().get_basename()
			if base.begins_with("AI_"):
				base = base.substr(3)
			if base != "":
				return base
	return fallback_name

# Pulls a human-friendly weapon name from an AI's weaponData ref. AI.gd
# exposes either a WeaponData (which extends ItemData with .name/.display)
# or an AIWeaponData wrapping an inner .itemData. Try both shapes, fall
# back to "—" when nothing is held.
func _tac_hud_read_weapon(enemy) -> String:
	if not "weaponData" in enemy:
		return "—"
	var wd = enemy.weaponData
	if wd == null:
		return "—"
	if "name" in wd and str(wd.name) != "":
		return str(wd.name)
	if "display" in wd and str(wd.display) != "":
		return str(wd.display)
	if "itemData" in wd and wd.itemData != null:
		var inner = wd.itemData
		if "name" in inner and str(inner.name) != "":
			return str(inner.name)
		if "display" in inner and str(inner.display) != "":
			return str(inner.display)
	return "?"

# Mode of the bearing tags across all contacts. Used by the banner
# variants that say ">> chatter detected >> [DIR] <<" — picks the
# direction with the most active contacts. Falls back to the nearest
# contact's bearing when there's a tie or only one contact.
func _intel_dominant_direction(contacts: Array) -> String:
	if contacts.is_empty():
		return ""
	var counts: Dictionary = {}
	for c in contacts:
		var t: String = String(c.get("bearing_tag", ""))
		if t == "":
			continue
		counts[t] = int(counts.get(t, 0)) + 1
	var best: String = ""
	var best_n: int = 0
	for k in counts.keys():
		if int(counts[k]) > best_n:
			best_n = int(counts[k])
			best = String(k)
	if best != "":
		return best
	return String(contacts[0].get("bearing_tag", ""))

# Single pass over the AI group + spawner that builds the full radio
# payload. Sorts contacts by distance ascending. All property reads are
# guarded so a half-initialized AI node can't crash the readout.
#   Returns:
#     {
#       "contacts":     [ {distance, state_tag, alerted, name, visible,
#                          bearing_idx, bearing_tag, bucket}, ... ],
#       "active":       int,    # spawner.activeAgents or contacts fallback
#       "limit":        int,    # spawner.spawnLimit or 0
#       "next_wave":    float,  # spawner.spawnTime or -1.0
#       "any_alert":    bool,   # at least one contact in an alert state
#       "any_los":      bool,   # at least one contact with playerVisible
#       "noise":        float,  # max fireDetectionTimer across contacts
#       "dominant_dir": String, # mode bearing tag for the banner
#     }
func _intel_summary() -> Dictionary:
	var out: Dictionary = {
		"contacts": [],
		"active": 0,
		"limit": 0,
		"next_wave": -1.0,
		"any_alert": false,
		"any_los": false,
		"noise": 0.0,
		"dominant_dir": "",
	}
	var player_pos: Vector3 = _intel_get_player_pos()
	for enemy in _get_active_enemies():
		if not is_instance_valid(enemy):
			continue
		var dist: float = -1.0
		if "playerDistance3D" in enemy:
			dist = float(enemy.playerDistance3D)
		var state_val = 0
		if "currentState" in enemy:
			state_val = enemy.currentState
		var tag: String = _intel_state_tag(state_val)
		var alerted: bool = int(state_val) in INTEL_ALERT_STATES
		var visible: bool = false
		if "playerVisible" in enemy:
			visible = bool(enemy.playerVisible)
		var noise_t: float = 0.0
		if "fireDetectionTimer" in enemy:
			noise_t = float(enemy.fireDetectionTimer)
		var ename: String = str(enemy.name) if enemy.name != null else "?"
		# Trim trailing numeric suffix on instance names (Bandit3 -> Bandit)
		var clean: String = ename
		while clean.length() > 0:
			var last_char: String = clean.substr(clean.length() - 1, 1)
			if last_char < "0" or last_char > "9":
				break
			clean = clean.substr(0, clean.length() - 1)
		if clean == "":
			clean = ename
		# Bearing relative to the player. AI is CharacterBody3D so
		# global_position is always available.
		var bearing_idx: int = 0
		var bearing_tag: String = "N"
		if enemy is Node3D:
			bearing_idx = _intel_bearing_for(player_pos, enemy.global_position)
			bearing_tag = INTEL_BEARING_TAGS[bearing_idx]
		var bucket: String = _intel_distance_bucket(dist)
		# TAC HUD columns. type comes from scene_file_path now
		# (Bandit/Guard/Military/Punisher) with the trimmed node name
		# as a fallback. health is float for boss enemies but int for
		# regular grunts; cast to int for display. is_boss reads the
		# authoritative AI.gd @export var boss flag.
		var type_name: String = _tac_hud_read_type(enemy, clean)
		var weapon_name: String = _tac_hud_read_weapon(enemy)
		var health_int: int = int(_safe(enemy, "health", 0))
		var is_boss: bool = false
		if "boss" in enemy:
			is_boss = bool(enemy.boss)
		out["contacts"].append({
			"distance": dist,
			"state_tag": tag,
			"alerted": alerted,
			"visible": visible,
			"name": clean,
			"type": type_name,
			"weapon": weapon_name,
			"health": health_int,
			"is_boss": is_boss,
			"bearing_idx": bearing_idx,
			"bearing_tag": bearing_tag,
			"bucket": bucket,
		})
		if alerted:
			out["any_alert"] = true
		if visible:
			out["any_los"] = true
		if noise_t > float(out["noise"]):
			out["noise"] = noise_t
	# Sort by distance ascending; unknown distances (-1) sort last.
	out["contacts"].sort_custom(func(a, b):
		var ad: float = float(a["distance"]) if float(a["distance"]) >= 0 else 99999.0
		var bd: float = float(b["distance"]) if float(b["distance"]) >= 0 else 99999.0
		return ad < bd)
	# Compute the banner direction now that contacts are sorted.
	out["dominant_dir"] = _intel_dominant_direction(out["contacts"])
	# Spawner stats override contacts.size() if available.
	var spawner = _get_ai_spawner()
	if spawner != null and is_instance_valid(spawner):
		if "activeAgents" in spawner:
			out["active"] = int(spawner.activeAgents)
		else:
			out["active"] = out["contacts"].size()
		if "spawnLimit" in spawner:
			out["limit"] = int(spawner.spawnLimit)
		if "spawnTime" in spawner:
			out["next_wave"] = float(spawner.spawnTime)
	else:
		out["active"] = out["contacts"].size()
	return out


# ── Dashboard UI builders ──────────────────────────────────────

func _make_dashboard_card(parent: Control, title: String) -> VBoxContainer:
	# Reusable card skeleton: bordered PanelContainer with a title and an
	# inner VBox. The card is added to `parent`. Callers add their content
	# to the returned inner VBox.
	var card = PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.size_flags_stretch_ratio = 1.0
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.10, 0.85)
	style.border_color = Color(0.35, 0.35, 0.40, 0.95)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	card.add_theme_stylebox_override("panel", style)
	parent.add_child(card)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	var title_label = Label.new()
	title_label.text = title
	_style_label(title_label, 14, COL_TEXT)
	vbox.add_child(title_label)
	_add_separator(vbox)

	return vbox

func _make_dashboard_progress_bar(bar_color: Color) -> ProgressBar:
	# Single styled ProgressBar factory shared by the LOADOUT carry-weight
	# bar. Kept as a helper so the next card that needs a bar stays consistent.
	var bar = ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 0.0
	bar.custom_minimum_size = Vector2(0, 14)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.show_percentage = false
	var bar_bg = StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.12, 0.12, 0.14, 0.9)
	bar_bg.border_color = Color(0.3, 0.3, 0.35, 0.8)
	bar_bg.border_width_left = 1
	bar_bg.border_width_right = 1
	bar_bg.border_width_top = 1
	bar_bg.border_width_bottom = 1
	bar_bg.corner_radius_top_left = 2
	bar_bg.corner_radius_top_right = 2
	bar_bg.corner_radius_bottom_left = 2
	bar_bg.corner_radius_bottom_right = 2
	bar.add_theme_stylebox_override("background", bar_bg)
	var bar_fg = StyleBoxFlat.new()
	bar_fg.bg_color = bar_color
	bar_fg.corner_radius_top_left = 2
	bar_fg.corner_radius_top_right = 2
	bar_fg.corner_radius_bottom_left = 2
	bar_fg.corner_radius_bottom_right = 2
	bar.add_theme_stylebox_override("fill", bar_fg)
	return bar

func _build_dashboard_panel():
	dashboard_panel = PanelContainer.new()
	dashboard_panel.add_theme_stylebox_override("panel", _make_tile_style(0.86))
	# v10.6.11: full-screen panel so the taller painted button grids
	# (World → WEATHER) have room to fit without overflowing. Content
	# columns are also wrapped in their own scroll container below so
	# any remaining overflow is handled cleanly on smaller screens.
	dashboard_panel.anchor_left = 0.0
	dashboard_panel.anchor_top = 0.0
	dashboard_panel.anchor_right = 1.0
	dashboard_panel.anchor_bottom = 1.0
	canvas.add_child(dashboard_panel)

	var root = VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	dashboard_panel.add_child(root)

	_add_title(root, "CHEAT MENU")
	_add_info_label(root, "v%s  DASHBOARD  |  F5 Close  |  ESC Back" % VERSION, COL_DIM, 11)

	# ── Compact world strip (replaces v10.3 full-width world card) ──
	_build_dashboard_world_strip(root)

	# ── Top row cards — wrapped in a VBox so _load_category() can
	# collapse the whole section (separator + cards) when the user
	# opens the WORLD tab, giving the weather grid vertical room. ──
	dashboard_cards_section = VBoxContainer.new()
	dashboard_cards_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_cards_section.add_theme_constant_override("separation", 4)
	root.add_child(dashboard_cards_section)

	_add_separator(dashboard_cards_section)

	var cards_row = HBoxContainer.new()
	cards_row.add_theme_constant_override("separation", 8)
	cards_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dashboard_cards_section.add_child(cards_row)

	_build_dashboard_weapon_card(cards_row)
	_build_dashboard_intel_card(cards_row)
	_build_dashboard_stockpile_card(cards_row)

	_add_separator(dashboard_cards_section)

	# ── Favorites section ──
	_build_dashboard_favorites_section(root)

	_add_separator(root)

	# ── Navigation row ──
	_build_dashboard_nav_row(root)

	_add_separator(root)

	# ── Inline category content area (v10.6) ──
	_build_dashboard_content_area(root)

	_add_separator(root)

	# ── Footer ──
	# HBox so the centered hint text + a small right-aligned DEBUG
	# button share a row. The DEBUG button opens the live log panel
	# described in _open_debug_log().
	var footer_row = HBoxContainer.new()
	footer_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_theme_constant_override("separation", 8)
	root.add_child(footer_row)

	var footer = Label.new()
	footer.text = "F5 close  ·  F6 spawner  ·  ESC back  ·  Click the ☆ next to any cheat to favorite it"
	_style_label(footer, 10, COL_DIM)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(footer)

	var debug_btn = _make_styled_button("DEBUG", COL_BTN_NORMAL, COL_BTN_HOVER)
	debug_btn.custom_minimum_size = Vector2(70, 22)
	debug_btn.add_theme_font_size_override("font_size", 10)
	debug_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
	debug_btn.add_theme_color_override("font_hover_color", COL_TEXT)
	debug_btn.tooltip_text = "Open the live CheatMenu debug log"
	debug_btn.pressed.connect(_open_debug_log)
	footer_row.add_child(debug_btn)

func _build_dashboard_weapon_card(parent: Control):
	var card_vbox = _make_dashboard_card(parent, "WEAPON")

	# v10.4.2 — No scroll wrap. User requested that the entire weapon
	# readout (icon / name / ammo+condition / full attachment list /
	# carry + ammo-match footer) be visible at once. Card grows to fit;
	# the cards_row HBox uses SIZE_EXPAND_FILL on siblings so the intel
	# and stockpile cards match the new height without clipping.
	dashboard_weapon_vbox = VBoxContainer.new()
	dashboard_weapon_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_weapon_vbox.add_theme_constant_override("separation", 3)
	card_vbox.add_child(dashboard_weapon_vbox)

	# Carry weight + ammo match footer. Refreshed every 0.5s tick
	# (signature-gated) so weight crossing thresholds and ammo pickups
	# update live.
	_add_separator(card_vbox)
	dashboard_weapon_stats_vbox = VBoxContainer.new()
	dashboard_weapon_stats_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_weapon_stats_vbox.add_theme_constant_override("separation", 2)
	card_vbox.add_child(dashboard_weapon_stats_vbox)

	# Initial content populated by _rebuild_dashboard_weapon_card() on first
	# dashboard show.

func _build_dashboard_intel_card(parent: Control):
	# Hijacked-radio threat readout. In v10.6.1 this became a proper
	# intel report: threat breakdown, boss confirmation, and a loot
	# bulletin scanning LootContainer nodes in the region for high-
	# rarity items. The TAC HUD toggle lives at the top of this card
	# so the player can flip the in-game overlay without opening the
	# Combat category first.
	var card_vbox = _make_dashboard_card(parent, "...kssh... ENEMY BAND")

	# Pinned TAC HUD quick toggle — not inside the scroll so it's
	# always visible when the card is open.
	_add_cheat_toggle(card_vbox, "Tactical HUD", "cheat_tac_hud")
	_add_separator(card_vbox)

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card_vbox.add_child(scroll)

	dashboard_intel_vbox = VBoxContainer.new()
	dashboard_intel_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_intel_vbox.add_theme_constant_override("separation", 3)
	scroll.add_child(dashboard_intel_vbox)

func _build_dashboard_world_strip(parent: Control):
	# v10.6 — replaces the old full-width World card with a compact
	# single-line status strip. Shows day/season/time/weather/shelter
	# /cat/cash. Lives directly below the title so the heavy UI real
	# estate can be given to the inline category content area instead.
	dashboard_world_strip = Label.new()
	_style_label(dashboard_world_strip, 11, COL_TEXT_DIM)
	dashboard_world_strip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(dashboard_world_strip)

func _build_dashboard_stockpile_card(parent: Control):
	var card_vbox = _make_dashboard_card(parent, "STOCKPILE")

	# "ON YOU" section
	var onyou_hdr = Label.new()
	onyou_hdr.text = "▸ ON YOU"
	_style_label(onyou_hdr, 11, COL_POSITIVE)
	card_vbox.add_child(onyou_hdr)

	dashboard_stockpile_onyou_vbox = VBoxContainer.new()
	dashboard_stockpile_onyou_vbox.add_theme_constant_override("separation", 1)
	card_vbox.add_child(dashboard_stockpile_onyou_vbox)

	_add_separator(card_vbox)

	# "IN CABINS" section
	var cabins_hdr = Label.new()
	cabins_hdr.text = "▸ IN CABINS"
	_style_label(cabins_hdr, 11, COL_POSITIVE)
	card_vbox.add_child(cabins_hdr)

	dashboard_stockpile_cabins_vbox = VBoxContainer.new()
	dashboard_stockpile_cabins_vbox.add_theme_constant_override("separation", 1)
	card_vbox.add_child(dashboard_stockpile_cabins_vbox)

	# Push refresh button to the bottom.
	var spacer = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card_vbox.add_child(spacer)

	var refresh_btn = _make_styled_button("Refresh cabins", COL_BTN_NORMAL, COL_BTN_HOVER)
	refresh_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh_btn.custom_minimum_size = Vector2(0, 26)
	refresh_btn.add_theme_font_size_override("font_size", 10)
	refresh_btn.add_theme_color_override("font_color", COL_TEXT_DIM)
	refresh_btn.add_theme_color_override("font_hover_color", COL_TEXT)
	refresh_btn.pressed.connect(_dashboard_refresh_cabin_counts)
	card_vbox.add_child(refresh_btn)

func _build_dashboard_favorites_section(parent: Control):
	var hdr = Label.new()
	hdr.text = "FAVORITES  (click the ☆ next to any cheat toggle to favorite it)"
	_style_label(hdr, 11, COL_TEXT_DIM)
	parent.add_child(hdr)

	dashboard_favorites_row = HBoxContainer.new()
	dashboard_favorites_row.add_theme_constant_override("separation", 4)
	dashboard_favorites_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(dashboard_favorites_row)
	# Initial content populated by _rebuild_dashboard_favorites_row().

func _build_dashboard_nav_row(parent: Control):
	var hdr = Label.new()
	hdr.text = "NAVIGATION"
	_style_label(hdr, 11, COL_TEXT_DIM)
	parent.add_child(hdr)

	var nav_grid = GridContainer.new()
	nav_grid.columns = 4
	nav_grid.add_theme_constant_override("h_separation", 6)
	nav_grid.add_theme_constant_override("v_separation", 6)
	nav_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(nav_grid)

	for nav_def in DASHBOARD_NAV_DEFS:
		var featured: bool = bool(nav_def.get("featured", false))
		# Featured tabs (currently just SPAWNER) use the game's green
		# "spawn" accent color so they read as a CTA — the headline
		# interactive feature of the mod. Regular tabs stay neutral so
		# the green stands out, not blends in.
		var bg: Color = COL_SPAWN_BTN if featured else COL_BTN_NORMAL
		var hv: Color = COL_SPAWN_HVR if featured else COL_BTN_HOVER
		var btn = _make_styled_button(nav_def["label"], bg, hv)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 40)
		btn.add_theme_font_size_override("font_size", 14 if featured else 13)
		btn.add_theme_color_override("font_color", COL_POSITIVE if featured else COL_TEXT)
		btn.add_theme_color_override("font_hover_color", COL_TEXT)
		# Bold typeface on the featured button reinforces the hierarchy
		# without requiring larger dimensions that would break the grid.
		if featured and game_font_bold:
			btn.add_theme_font_override("font", game_font_bold)
		var tab_name: String = String(nav_def["tab"])
		if tab_name in DASHBOARD_CATEGORY_NAMES:
			btn.pressed.connect(_load_category.bind(tab_name))
		else:
			btn.pressed.connect(_open_submenu.bind(tab_name))
		dashboard_nav_buttons[tab_name] = btn
		nav_grid.add_child(btn)


# ── Inline category content area (v10.6) ───────────────────────
#
# v10.6 replaces the old tab-based sub-menu navigation for PLAYER/
# COMBAT/WORLD/INVENTORY/CABIN with an inline content area on the
# dashboard itself. Clicking one of those nav buttons populates
# `dashboard_content_sliders` (full-width pinned) and the column
# VBoxes inside `dashboard_content_columns` (grid of toggles and
# action buttons). SPAWNER and KEYBINDS still open as floating
# panels via _open_submenu().

func _build_dashboard_content_area(parent: Control):
	dashboard_content_area = VBoxContainer.new()
	dashboard_content_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_content_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dashboard_content_area.add_theme_constant_override("separation", 4)
	parent.add_child(dashboard_content_area)

	# Header row: three equal-weight cells so the left holds the "▸ PLAYER"
	# category label, the center is available for per-category inserts
	# (World uses it for the live time display + slider so they sit over
	# the TIME column instead of crowding it), and the right is an empty
	# spacer for symmetry. The 3 cells line up with World's 3-column
	# content layout so the center sits directly above the TIME section.
	var header_row := HBoxContainer.new()
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_theme_constant_override("separation", 12)
	dashboard_content_area.add_child(header_row)

	dashboard_content_header = Label.new()
	_style_label(dashboard_content_header, 13, COL_POSITIVE)
	dashboard_content_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_content_header.size_flags_stretch_ratio = 1.0
	dashboard_content_header.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_row.add_child(dashboard_content_header)

	dashboard_header_center = VBoxContainer.new()
	dashboard_header_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_header_center.size_flags_stretch_ratio = 1.0
	dashboard_header_center.add_theme_constant_override("separation", 1)
	header_row.add_child(dashboard_header_center)

	var header_right_spacer := Control.new()
	header_right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_right_spacer.size_flags_stretch_ratio = 1.0
	header_row.add_child(header_right_spacer)

	dashboard_content_sliders = VBoxContainer.new()
	dashboard_content_sliders.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_content_sliders.add_theme_constant_override("separation", 3)
	dashboard_content_area.add_child(dashboard_content_sliders)

	_add_separator(dashboard_content_area)

	# v10.6.11: Outer scroll container wraps the entire columns HBox so
	# tall category content (Player's SURVIVAL list, World's weather
	# grid) scrolls inside the dashboard instead of overflowing past
	# the bottom of the panel. Horizontal scroll is disabled — only
	# vertical overflow is allowed.
	var columns_scroll := ScrollContainer.new()
	columns_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	dashboard_content_area.add_child(columns_scroll)

	dashboard_content_columns = HBoxContainer.new()
	dashboard_content_columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_content_columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dashboard_content_columns.add_theme_constant_override("separation", 12)
	columns_scroll.add_child(dashboard_content_columns)

# Tears down every child of the sliders section and every column VBox
# (and its grandchildren). Also prunes toggle_refs and favorite_star_refs
# entries that now point to freed nodes so _sync_toggle_ui and the
# favorites system don't trip over stale references.
func _clear_content_area():
	if is_instance_valid(dashboard_content_sliders):
		for child in dashboard_content_sliders.get_children():
			child.queue_free()
	if is_instance_valid(dashboard_content_columns):
		for col in dashboard_content_columns.get_children():
			col.queue_free()
	# Wipe any per-category inserts parked in the header center cell
	# (World parents time_display + time_slider here). Without this,
	# switching from World → Player → World would stack two sets of
	# time widgets in the same cell.
	if is_instance_valid(dashboard_header_center):
		for child in dashboard_header_center.get_children():
			child.queue_free()
	# Prune toggle_refs and favorite_star_refs — the CheckButtons and
	# star Buttons we just queue_freed become invalid next frame, but
	# queue_free is deferred, so we mark stale ones as pending cleanup
	# via a deferred call. Pruning happens in _prune_stale_refs below.
	call_deferred("_prune_stale_refs")

func _prune_stale_refs():
	var stale_toggles: Array = []
	for key in toggle_refs:
		if not is_instance_valid(toggle_refs[key]):
			stale_toggles.append(key)
	for key in stale_toggles:
		toggle_refs.erase(key)
	var stale_stars: Array = []
	for key in favorite_star_refs:
		if not is_instance_valid(favorite_star_refs[key]):
			stale_stars.append(key)
	for key in stale_stars:
		favorite_star_refs.erase(key)

# Heuristic column count. Priority is readability — loaders can
# override by creating their own column VBoxes directly if they need
# a specific layout.
func _determine_column_count(item_count: int) -> int:
	if item_count <= 4:
		return 1
	if item_count <= 9:
		return 2
	if item_count <= 15:
		return 3
	return 4

# Creates `count` VBoxContainers as direct children of
# dashboard_content_columns and returns them so the caller can
# distribute items into them. Each column expands horizontally equally
# by default; callers can tweak `size_flags_stretch_ratio` per column.
# v10.6.11: no per-column scroll wrapping — the outer scroll on
# dashboard_content_columns handles any vertical overflow for the
# whole grid at once, which is simpler and avoids nested scrolling.
func _build_column_vboxes(count: int) -> Array:
	var cols: Array = []
	for i in range(count):
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_stretch_ratio = 1.0
		col.add_theme_constant_override("separation", 3)
		dashboard_content_columns.add_child(col)
		cols.append(col)
	return cols

# Updates visual highlight so the player can see which category the
# content area currently shows. Selected button gets the green spawn
# style; others revert to the default neutral look — EXCEPT for
# featured buttons (Spawner), which keep their green accent regardless
# of which tab is active, because their prominence is intrinsic to the
# feature they represent, not to being "currently open".
func _update_nav_button_highlights(active_category: String):
	for key in dashboard_nav_buttons:
		var btn: Button = dashboard_nav_buttons[key]
		if not is_instance_valid(btn):
			continue
		var is_featured := _is_nav_featured(key)
		if key == active_category or is_featured:
			btn.add_theme_color_override("font_color", COL_POSITIVE)
			btn.add_theme_stylebox_override("normal", _make_button_flat(COL_SPAWN_BTN))
		else:
			btn.add_theme_color_override("font_color", COL_TEXT)
			btn.add_theme_stylebox_override("normal", _make_button_flat(COL_BTN_NORMAL))

# Lookup helper — returns true if DASHBOARD_NAV_DEFS marks this tab as
# featured (currently used only by the SPAWNER entry).
func _is_nav_featured(tab_name: String) -> bool:
	for nav_def in DASHBOARD_NAV_DEFS:
		if String(nav_def.get("tab", "")) == tab_name:
			return bool(nav_def.get("featured", false))
	return false

# Main dispatcher. Called from nav button presses and from
# _show_dashboard on open (restores the sticky last selection).
func _load_category(category_name: String):
	if category_name not in DASHBOARD_CATEGORY_NAMES:
		return
	if not is_instance_valid(dashboard_content_header):
		return
	dashboard_last_category = category_name
	_clear_content_area()
	_update_nav_button_highlights(category_name)
	dashboard_content_header.text = "▸ %s" % category_name.to_upper()
	# v10.6.12: collapse the top cards row when the WORLD tab is active
	# so the weather grid has full vertical space. All other categories
	# keep the cards visible.
	# v10.3.0: same treatment for TUNER — the multipliers column + freeze/
	# lock column + immunities grid + actions need the extra vertical real
	# estate so the page doesn't scroll on 1080p.
	if is_instance_valid(dashboard_cards_section):
		dashboard_cards_section.visible = not (category_name in ["World", "Tuner", "Profiles"])
	match category_name:
		"Player":
			_load_category_player()
		"Combat":
			_load_category_combat()
		"World":
			_load_category_world()
		"Inventory":
			_load_category_inventory()
		"Cabin":
			_load_category_cabin()
		"Tuner":
			_load_category_tuner()
		"Profiles":
			_load_category_profiles()

func _load_category_player():
	# Sliders pinned top
	_add_value_slider(dashboard_content_sliders, "Speed", "cheat_speed_mult", 1.0, 10.0, 0.1)
	_add_value_slider(dashboard_content_sliders, "Jump", "cheat_jump_mult", 1.0, 5.0, 0.1)
	_add_value_slider(dashboard_content_sliders, "Fly Speed", "cheat_fly_speed", 1.0, 50.0, 0.5)
	_add_value_slider(dashboard_content_sliders, "Fly Sprint x", "cheat_fly_sprint_mult", 1.0, 15.0, 0.5)
	_add_value_slider(dashboard_content_sliders, "FOV", "cheat_fov", 50.0, 120.0, 5.0)
	# v10.6.25: 4 top-level sections but with uneven stretch ratios so
	# SURVIVAL gets double width (2.0) and QUICK ACTIONS is narrower
	# (0.85). SURVIVAL packs its 9 cheats into an internal 2-col
	# GridContainer so the section no longer needs to vertically
	# scroll. QUICK ACTIONS buttons shrink their min width to match
	# the narrower column.
	# Total stretch: 2.0 + 0.85 + 1.0 + 1.0 = 4.85
	#   SURVIVAL     ≈ 41.2%
	#   QUICK ACT    ≈ 17.5%
	#   MOVEMENT     ≈ 20.6%
	#   TELEPORT     ≈ 20.6%
	var cols: Array = _build_column_vboxes(4)
	var c0: VBoxContainer = cols[0]
	var c1: VBoxContainer = cols[1]
	var c2: VBoxContainer = cols[2]
	var c3: VBoxContainer = cols[3]
	c0.size_flags_stretch_ratio = 2.0
	c1.size_flags_stretch_ratio = 0.85
	c2.size_flags_stretch_ratio = 1.0
	c3.size_flags_stretch_ratio = 1.0
	# Column 0 — SURVIVAL (2-col grid of 9 cheats, no scroll)
	_add_section_header(c0, "SURVIVAL")
	var survival_grid := GridContainer.new()
	survival_grid.columns = 2
	survival_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	survival_grid.add_theme_constant_override("h_separation", 10)
	survival_grid.add_theme_constant_override("v_separation", 2)
	c0.add_child(survival_grid)
	_add_cheat_toggle(survival_grid, "God Mode", "cheat_god_mode")
	_add_cheat_toggle(survival_grid, "Infinite Stamina", "cheat_inf_stamina")
	_add_cheat_toggle(survival_grid, "Infinite Energy", "cheat_inf_energy")
	_add_cheat_toggle(survival_grid, "Infinite Hydration", "cheat_inf_hydration")
	_add_cheat_toggle(survival_grid, "Infinite Oxygen", "cheat_inf_oxygen")
	_add_cheat_toggle(survival_grid, "Max Mental", "cheat_max_mental")
	_add_cheat_toggle(survival_grid, "No Temp Loss", "cheat_no_temp_loss")
	_add_cheat_toggle(survival_grid, "No Overweight", "cheat_no_overweight")
	_add_cheat_toggle(survival_grid, "Cat Immortal", "cheat_cat_immortal")
	_add_cheat_toggle(survival_grid, "Auto-Med", "cheat_auto_med")
	# Column 1 — QUICK ACTIONS (narrower column, buttons shrink to fit)
	_add_section_header(c1, "QUICK ACTIONS")
	_add_action_button(c1, "Heal to Full", "_action_heal", COL_SPAWN_BTN)
	_add_action_button(c1, "Clear All Ailments", "_action_clear_ailments", COL_SPAWN_BTN)
	_add_action_button(c1, "Refill All Vitals", "_action_refill_vitals", COL_SPAWN_BTN)
	# Column 2 — MOVEMENT
	_add_section_header(c2, "MOVEMENT")
	_add_cheat_toggle(c2, "No Fall Damage", "cheat_no_fall_dmg")
	_add_cheat_toggle(c2, "No Head Bob", "cheat_no_headbob")
	_add_cheat_toggle(c2, "Noclip", "cheat_noclip")
	_add_action_button(c2, "Toggle Fly Mode", "_action_toggle_fly", COL_BTN_NORMAL)
	# Column 3 — TELEPORT
	_add_section_header(c3, "TELEPORT")
	_add_action_button(c3, "Save Position", "_action_tp_save", COL_SPAWN_BTN)
	_add_action_button(c3, "Teleport to Last", "_action_tp_last", COL_BTN_NORMAL)
	_add_action_button(c3, "Open Teleport Menu", "_action_tp_menu", COL_BTN_NORMAL)

func _load_category_combat():
	# TAC HUD toggle moved to the dashboard intel card (v10.6.1), so it
	# doesn't live in Combat any more. Weapons + economy stay here.
	# v10.6.2: Craft Anywhere moved to the WEAPON CHEATS column so it
	# sits closer to the other general-gameplay toggles.
	# v10.5.2: AI INTELLIGENCE section added to column 1 above ECONOMY.
	# The two toggles ship via BINDABLE_ACTIONS for keybind support and
	# render HUD tags (INV / ESP), but prior to this they had no
	# dashboard UI — you could only toggle them by keybind, which meant
	# most users never discovered the features. Putting them next to
	# WEAPON CHEATS makes the Combat tab feel thematically complete.
	var cols: Array = _build_column_vboxes(2)
	var c0: VBoxContainer = cols[0]
	var c1: VBoxContainer = cols[1]
	_add_section_header(c0, "WEAPON CHEATS")
	_add_cheat_toggle(c0, "No Recoil", "cheat_no_recoil")
	_add_cheat_toggle(c0, "Infinite Ammo", "cheat_inf_ammo")
	_add_cheat_toggle(c0, "No Weapon Jam", "cheat_no_jam")
	_add_cheat_toggle(c0, "Infinite Armor", "cheat_inf_armor")
	_add_cheat_toggle(c0, "Craft Anywhere", "cheat_unlock_crafting")
	_add_section_header(c1, "AI INTELLIGENCE")
	_add_cheat_toggle(c1, "Invisible to AI", "cheat_ai_invisible")
	_add_cheat_toggle(c1, "AI ESP Overlay", "cheat_ai_esp")
	_add_cheat_toggle(c1, "Freeze All AI", "cheat_ai_freeze")
	# v10.5.7 — ESP theme picker. Rebuilt whenever the Combat tab
	# reloads, so no need to cache a reference to the OptionButton.
	var theme_label := Label.new()
	theme_label.text = "ESP THEME"
	_style_label(theme_label, 10, COL_TEXT_DIM)
	c1.add_child(theme_label)
	var theme_picker := OptionButton.new()
	for i in ESP_THEME_COUNT:
		theme_picker.add_item(String(ESP_THEME_LABELS[i]))
	theme_picker.select(cheat_ai_esp_theme)
	theme_picker.custom_minimum_size = Vector2(0, 26)
	theme_picker.tooltip_text = "Switch the ESP visual style. Vostok = military corner brackets + Cyrillic callsigns. Thermal = heat-vision glow + scan line. Glitch = analog-flicker paranoid overlay."
	theme_picker.item_selected.connect(_on_esp_theme_selected)
	c1.add_child(theme_picker)
	# v10.5.9 — sub-toggle: when Thermal theme is active AND ESP is
	# on, flip the shader variant so the thermal silhouette renders
	# THROUGH walls (depth_test_disabled). No effect on other themes.
	_add_cheat_toggle(c1, "Thermal: See Through Walls", "cheat_ai_esp_walls")
	# v10.6.1 — skip ESP markers on killed AIs. Default ON; match with
	# per-theme state-tint logic (dead AIs inside the per-theme code
	# tint their bounding box a dim color when this toggle is OFF).
	_add_cheat_toggle(c1, "Hide Dead AI in ESP", "cheat_ai_esp_hide_dead")
	_add_section_header(c1, "ECONOMY")
	_add_action_button(c1, "Restock All Traders", "_action_restock_traders", COL_SPAWN_BTN)

func _load_category_world():
	# v10.6.18: reorganized into a 3-column 1:1:1 layout so each
	# sub-section (SEASON, TIME, WEATHER) gets its own balanced
	# column. At 1920px full-screen dashboard, each column lands
	# at ~640px wide, which gives the weather 2x2 grid cells
	# exactly 320×80 — the native 4:1 aspect of the painted source,
	# zero crop, full scenery visible. SEASON + TOGGLES sit stacked
	# in column 0; TIME is self-contained in column 1; WEATHER fills
	# column 2.
	# v10.6.25: Season buttons now live in a 2-col GridContainer at
	# row_height=80 so they match the size of the time preset and
	# weather buttons. The time display + slider are parented to the
	# header center cell (see _build_dashboard_content_area) so they
	# sit above the TIME column instead of inside it, which aligns
	# the SEASON / TIME / WEATHER painted button rows horizontally.
	var cols: Array = _build_column_vboxes(3)
	var c0: VBoxContainer = cols[0]
	var c1: VBoxContainer = cols[1]
	var c2: VBoxContainer = cols[2]

	# ── Column 0: SEASON + TOGGLES ──
	_add_section_header(c0, "SEASON")
	var season_grid := GridContainer.new()
	season_grid.columns = 2
	season_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	season_grid.add_theme_constant_override("h_separation", 4)
	season_grid.add_theme_constant_override("v_separation", 4)
	c0.add_child(season_grid)
	var season_defs: Array = [
		{"name": "Summer", "tex": "season_summer", "season": 1, "top": Color(0.4, 0.7, 0.3), "bot": Color(0.25, 0.55, 0.2), "font": Color(1, 1, 1)},
		{"name": "Winter", "tex": "season_winter", "season": 2, "top": Color(0.55, 0.68, 0.78), "bot": Color(0.35, 0.48, 0.60), "font": Color(1, 1, 1)},
	]
	for sdef in season_defs:
		var s_tex_key: String = String(sdef["tex"])
		var s_bg_tex: Texture2D = button_textures.get(s_tex_key, null)
		var s_btn_text: String = "" if s_bg_tex != null else String(sdef["name"])
		var sbtn := _make_gradient_button(
			s_btn_text,
			"gradient",
			Color(sdef["top"]),
			Color(sdef["bot"]),
			Color(sdef["font"]),
			_action_set_season.bind(int(sdef["season"])),
			"",
			80,
			s_bg_tex
		)
		var scell := VBoxContainer.new()
		scell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scell.add_theme_constant_override("separation", 1)
		season_grid.add_child(scell)
		scell.add_child(sbtn)
		if s_bg_tex != null:
			var s_caption := Label.new()
			s_caption.text = String(sdef["name"])
			s_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_style_label(s_caption, 10, COL_TEXT_DIM)
			scell.add_child(s_caption)
	_add_separator(c0)
	_add_section_header(c0, "TOGGLES")
	_add_cheat_toggle(c0, "Freeze Time", "cheat_freeze_time")
	_add_cheat_toggle(c0, "Real Time", "cheat_real_time")

	# ── Header center cell: time_display + time_slider ──
	# Parking these in the header row (instead of c1) means the TIME
	# column's painted buttons start at the same Y position as the
	# SEASON and WEATHER buttons, giving all three sections a shared
	# horizontal baseline. is_instance_valid() guard handles the very
	# first dashboard open before _build_dashboard_content_area has
	# ever run — in that case we fall back to parenting into c1 so
	# the widgets still exist for the _process refresh loop.
	var time_widgets_parent: Control = c1
	if is_instance_valid(dashboard_header_center):
		time_widgets_parent = dashboard_header_center
	time_display = Label.new()
	_style_label(time_display, 12, COL_TEXT)
	time_display.text = "Time: --:--"
	time_display.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_widgets_parent.add_child(time_display)
	time_slider = HSlider.new()
	time_slider.focus_mode = Control.FOCUS_NONE
	time_slider.scrollable = false
	time_slider.min_value = 0.0
	time_slider.max_value = 2400.0
	time_slider.step = 50.0
	time_slider.value = 1200.0
	time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if game_grabber:
		time_slider.add_theme_icon_override("grabber", game_grabber)
		time_slider.add_theme_icon_override("grabber_highlight", game_grabber)
	var ts_track := StyleBoxLine.new()
	ts_track.color = COL_SEPARATOR
	ts_track.grow_begin = 0.0
	ts_track.grow_end = 0.0
	ts_track.thickness = 2
	time_slider.add_theme_stylebox_override("slider", ts_track)
	var ts_area := StyleBoxFlat.new()
	ts_area.bg_color = Color(1, 1, 1, 0.5)
	ts_area.set_corner_radius_all(4)
	ts_area.set_content_margin_all(4)
	time_slider.add_theme_stylebox_override("grabber_area", ts_area)
	time_slider.add_theme_stylebox_override("grabber_area_highlight", ts_area)
	time_slider.value_changed.connect(_on_time_slider_changed)
	# Clear the drag-session lock when the user releases the mouse.
	# This re-arms the day-advance so the NEXT drag to max can
	# advance one day. Holding continuously never racks up multiple.
	time_slider.drag_ended.connect(_on_time_slider_drag_ended)
	time_widgets_parent.add_child(time_slider)

	# ── Column 1: TIME section header + 2x2 preset grid + speed ──
	_add_section_header(c1, "TIME")
	# 2x2 grid of painted time preset buttons. At c1 ~640px wide,
	# each cell is ~320px wide × 80px tall — 4:1 native aspect, same
	# as the weather cells, no crop.
	var time_preset_grid := GridContainer.new()
	time_preset_grid.columns = 2
	time_preset_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_preset_grid.add_theme_constant_override("h_separation", 4)
	time_preset_grid.add_theme_constant_override("v_separation", 4)
	c1.add_child(time_preset_grid)
	var time_defs: Array = [
		{"label": "Dawn",  "time": 550.0,  "tex": "dawn",  "top": Color(0.38, 0.30, 0.55), "bot": Color(0.95, 0.55, 0.35), "font": Color(1, 0.98, 0.95), "icon": "sun_dawn"},
		{"label": "Noon",  "time": 1200.0, "tex": "noon",  "top": Color(0.55, 0.78, 0.98), "bot": Color(0.32, 0.58, 0.88), "font": Color(1, 1, 1),         "icon": "sun_noon"},
		{"label": "Dusk",  "time": 1750.0, "tex": "dusk",  "top": Color(0.18, 0.12, 0.35), "bot": Color(0.88, 0.38, 0.22), "font": Color(1, 0.98, 0.95), "icon": "sun_dusk"},
		{"label": "Night", "time": 2200.0, "tex": "night", "top": Color(0.04, 0.04, 0.14), "bot": Color(0.12, 0.10, 0.24), "font": Color(0.85, 0.88, 1), "icon": "moon"},
	]
	for tdef in time_defs:
		var tex_key: String = String(tdef["tex"])
		var bg_tex: Texture2D = button_textures.get(tex_key, null)
		var btn_text: String = "" if bg_tex != null else String(tdef["label"])
		var pbtn := _make_gradient_button(
			btn_text,
			"gradient",
			Color(tdef["top"]),
			Color(tdef["bot"]),
			Color(tdef["font"]),
			_action_set_time.bind(float(tdef["time"])),
			String(tdef["icon"]),
			80,
			bg_tex
		)
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 1)
		time_preset_grid.add_child(cell)
		cell.add_child(pbtn)
		if bg_tex != null:
			var caption := Label.new()
			caption.text = String(tdef["label"])
			caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_style_label(caption, 9, COL_TEXT_DIM)
			cell.add_child(caption)
	_add_value_slider(c1, "Time Speed", "cheat_time_speed", 1.0, 20.0, 1.0)

	# ── Column 2: WEATHER 2-col grid, full column width ──
	# Each cell lands at ~320×80 = native 4:1 aspect, so the painted
	# scenes show without cropping.
	_add_section_header(c2, "WEATHER")
	var weather_grid := GridContainer.new()
	weather_grid.columns = 2
	weather_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	weather_grid.add_theme_constant_override("h_separation", 4)
	weather_grid.add_theme_constant_override("v_separation", 4)
	c2.add_child(weather_grid)

	var weather_defs: Array = [
		{"name": "Neutral",  "tex": "weather_neutral",  "shader": "gradient", "top": Color(0.45, 0.65, 0.92), "bot": Color(0.70, 0.86, 0.97), "font": Color(1, 1, 1)},
		{"name": "Rain",     "tex": "weather_rain",     "shader": "gradient", "top": Color(0.20, 0.25, 0.38), "bot": Color(0.35, 0.42, 0.52), "font": Color(0.92, 0.96, 1)},
		{"name": "Storm",    "tex": "weather_storm",    "shader": "gradient", "top": Color(0.06, 0.05, 0.13), "bot": Color(0.16, 0.13, 0.24), "font": Color(0.88, 0.90, 1)},
		{"name": "Overcast", "tex": "weather_overcast", "shader": "gradient", "top": Color(0.48, 0.50, 0.55), "bot": Color(0.66, 0.68, 0.72), "font": Color(1, 1, 1)},
		{"name": "Fog",      "tex": "weather_fog",      "shader": "gradient", "top": Color(0.72, 0.72, 0.76), "bot": Color(0.88, 0.88, 0.90), "font": Color(0.20, 0.20, 0.24)},
		{"name": "Wind",     "tex": "weather_wind",     "shader": "gradient", "top": Color(0.50, 0.55, 0.60), "bot": Color(0.62, 0.68, 0.72), "font": Color(1, 1, 1)},
		{"name": "Aurora",   "tex": "weather_aurora",   "shader": "gradient", "top": Color.WHITE,             "bot": Color.WHITE,             "font": Color(1, 1, 1)},
	]
	for wdef in weather_defs:
		var w_tex_key: String = String(wdef["tex"])
		var w_bg_tex: Texture2D = null
		if w_tex_key != "":
			w_bg_tex = button_textures.get(w_tex_key, null)
		var w_shader_key: String = String(wdef["shader"])
		var w_btn_text: String = "" if w_bg_tex != null else String(wdef["name"])
		var wbtn := _make_gradient_button(
			w_btn_text,
			w_shader_key,
			Color(wdef["top"]),
			Color(wdef["bot"]),
			Color(wdef["font"]),
			_action_set_weather.bind(String(wdef["name"])),
			"",
			80,
			w_bg_tex
		)
		# Each weather cell is a VBox so the caption sits under the
		# painted button. Spacing tightened to match the time preset
		# grid for a consistent crisp card look.
		# v10.6.18: cells naturally fill c2 at 3-column layout, ~320px
		# each, giving 4:1 aspect = zero crop on the 1024x256 sources.
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 1)
		weather_grid.add_child(cell)
		cell.add_child(wbtn)
		if w_bg_tex != null:
			var caption := Label.new()
			caption.text = String(wdef["name"])
			caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_style_label(caption, 9, COL_TEXT_DIM)
			cell.add_child(caption)

func _load_category_inventory():
	var cols: Array = _build_column_vboxes(1)
	var c0: VBoxContainer = cols[0]
	_add_section_header(c0, "SORT")
	_add_action_button(c0, "Sort Inventory (by Type)", "_action_sort_inventory_type", COL_SPAWN_BTN)
	_add_action_button(c0, "Sort Inventory (by Weight)", "_action_sort_inventory_weight", COL_SPAWN_BTN)
	_add_action_button(c0, "Stack All Duplicates", "_action_stack_duplicates", COL_SPAWN_BTN)

func _load_category_cabin():
	var cols: Array = _build_column_vboxes(3)
	var c0: VBoxContainer = cols[0]
	var c1: VBoxContainer = cols[1]
	var c2: VBoxContainer = cols[2]
	_add_section_header(c0, "AUTO-ORGANIZE")
	_add_action_button(c0, "Vacuum + Auto-Stash", "_action_vacuum_and_stash", COL_SPAWN_BTN)
	_add_action_button(c0, "Vacuum Floor Items", "_action_vacuum_floor", COL_BTN_NORMAL)
	_add_action_button(c0, "Stash Inventory to Cabin", "_action_cabin_stash", COL_BTN_NORMAL)
	_add_section_header(c1, "STARTER KIT")
	_add_info_label(c1, "Fills fridge/cabinets with food & meds, drapes clothing on the couch, puts a weapon on the table. Still being polished, stay tuned.", COL_TEXT_DIM, 10)
	_add_action_button(c1, "Stock Cabin (Coming Soon)", "_action_starter_stash_coming_soon", COL_BTN_NORMAL)
	_add_section_header(c1, "INFO")
	_add_action_button(c1, "Browse Cabin Storage", "_open_cabin_browser", COL_BTN_NORMAL)
	_add_section_header(c2, "TRAVEL")
	_add_action_button(c2, "Return to Cabin", "_action_return_to_cabin_prompt", COL_DANGER_BTN)
	# Spacer + DESTRUCTIVE section, separated from Return to Cabin so the
	# Delete Floor Items button can't be clicked by accident when the user
	# is aiming for Return to Cabin.
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 48)
	c2.add_child(gap)
	_add_section_header(c2, "DESTRUCTIVE")
	_add_action_button(c2, "Delete Floor Items", "_action_delete_floor_prompt", COL_DANGER_BTN)

# ── Vitals Tuner tab (v10.3.0) ─────────────────────────────────
# Layout philosophy: each of the 9 vitals is a self-contained "block"
# that owns its sliders AND its freeze/lock toggles. This guarantees
# alignment (can't happen with parallel columns of differing row
# heights) and reads naturally top-to-bottom as one vital at a time.
#
# Column stretch:  VITALS 2.5  |  IMMUNITIES 1.3  |  ACTIONS 1.0
# Total 4.8  →  vitals ≈ 52%, immunities ≈ 27%, actions ≈ 21%.
# Cards-section collapse (see _load_category) reclaims ~40% vertical
# so the whole tab fits a 1080p frame without scrolling at default zoom.
func _load_category_tuner():
	# ── Master row (pinned above the columns, full-width) ────────
	# Compact construction so the CheckButton indicator sits RIGHT NEXT
	# to its label instead of being pushed to the far right by
	# SIZE_EXPAND_FILL. The ★ star mirrors _add_cheat_toggle's favorites
	# wiring (cheat_tuner_enabled is in SETTABLE_VARS). A spacer pushes
	# the Reset Sliders button to the right edge.
	var master_row := HBoxContainer.new()
	master_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	master_row.add_theme_constant_override("separation", 6)
	dashboard_content_sliders.add_child(master_row)

	var master_cb := CheckButton.new()
	master_cb.text = "Master Enable — Vitals Tuner"
	master_cb.focus_mode = Control.FOCUS_NONE
	_style_button_font(master_cb, 14, COL_TEXT)
	master_cb.add_theme_color_override("font_hover_color", COL_TEXT)
	master_cb.set_pressed_no_signal(cheat_tuner_enabled)
	master_cb.toggled.connect(_on_cheat_toggled.bind("cheat_tuner_enabled"))
	master_row.add_child(master_cb)
	toggle_refs["cheat_tuner_enabled"] = master_cb

	var master_star := _make_favorite_star_button("cheat_tuner_enabled")
	master_row.add_child(master_star)
	favorite_star_refs["cheat_tuner_enabled"] = master_star
	_apply_favorite_star_state(master_star, "cheat_tuner_enabled")

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	master_row.add_child(spacer)

	var reset_btn := _make_styled_button("Reset Sliders", COL_BTN_NORMAL, COL_BTN_HOVER)
	reset_btn.pressed.connect(_action_tuner_reset_multipliers)
	reset_btn.custom_minimum_size = Vector2(140, 30)
	master_row.add_child(reset_btn)

	# One-line description so users know the master toggle is a kill-switch
	# for the ENTIRE tuner (not just one section). When off, sliders and
	# checkboxes remain editable so you can stage a loadout before turning
	# it on — they just aren't enforced yet.
	var master_desc := Label.new()
	master_desc.text = "Master kill-switch. When off, all multipliers, freezes, locks, and immunities are ignored — settings stay configurable."
	master_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	master_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(master_desc, 11, COL_TEXT_DIM)
	dashboard_content_sliders.add_child(master_desc)

	# ── Three content columns ────────────────────────────────────
	var cols: Array = _build_column_vboxes(3)
	# Balanced 50/25/25 split so the tab reads as three peer sections
	# rather than "one huge slider wall + two thin strips". Sliders at
	# 50% of the panel give comfortable travel (~480px on 1080p) without
	# forcing big mouse drags. Immunities and actions each get 25% for
	# full-label legibility.
	var c_vitals: VBoxContainer = cols[0]; c_vitals.size_flags_stretch_ratio = 2.0
	var c_imm: VBoxContainer    = cols[1]; c_imm.size_flags_stretch_ratio = 1.0
	var c_act: VBoxContainer    = cols[2]; c_act.size_flags_stretch_ratio = 1.0

	# Column 0 — per-vital blocks (all controls for one vital together)
	#
	# The header is pinned at the top of the column; only the vital
	# blocks themselves scroll. This prevents the outer dashboard scroll
	# from activating (which would otherwise move IMMUNITIES and ACTIONS
	# off-screen whenever VITALS overflows). The inner ScrollContainer
	# reports a bounded minimum size to its parent, so the outer scroll
	# sees short columns and stays put.
	_add_section_header(c_vitals, "VITALS")
	var vitals_scroll := ScrollContainer.new()
	vitals_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vitals_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vitals_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	c_vitals.add_child(vitals_scroll)

	# MarginContainer gives the content breathing room before the inner
	# scrollbar. Without this the slider "1.0x" value labels butt up
	# directly against the scroll track and read as clipped. margin_right
	# ≈ scrollbar thickness (~12px) + 4px visual padding.
	var vitals_margin := MarginContainer.new()
	vitals_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vitals_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vitals_margin.add_theme_constant_override("margin_right", 16)
	vitals_margin.add_theme_constant_override("margin_left", 2)
	vitals_scroll.add_child(vitals_margin)

	var vitals_list := VBoxContainer.new()
	vitals_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vitals_list.add_theme_constant_override("separation", 3)
	vitals_margin.add_child(vitals_list)

	for i in range(TUNER_VITALS.size()):
		var v: String = TUNER_VITALS[i]
		_tuner_build_vital_block(vitals_list, v)
		# Subtle divider between vitals (not after the last one).
		if i < TUNER_VITALS.size() - 1:
			_add_separator(vitals_list)

	# Column 1 — IMMUNITIES (single-column stacked list of 12 condition
	# toggles). Each row is a CheckButton with its label + indicator
	# flush together (no SIZE_EXPAND_FILL) so the column can stay narrow.
	_add_section_header(c_imm, "IMMUNITIES")
	var imm_list := VBoxContainer.new()
	imm_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	imm_list.add_theme_constant_override("separation", 2)
	c_imm.add_child(imm_list)
	for c in TUNER_CONDITIONS:
		var cb := CheckButton.new()
		cb.text = TUNER_CONDITION_DISPLAY.get(c, c)
		cb.focus_mode = Control.FOCUS_NONE
		_style_button_font(cb, 12, COL_TEXT_DIM)
		cb.add_theme_color_override("font_hover_color", COL_TEXT)
		cb.set_pressed_no_signal(bool(tuner_immune.get(c, false)))
		cb.toggled.connect(_on_tuner_immune_toggled.bind(c))
		imm_list.add_child(cb)
		tuner_immune_checks[c] = cb

	# Column 2 — ACTIONS (four buttons stacked, color-coded). These are
	# intentionally NOT in _tuner_dim_targets — they're one-shot actions
	# (Refill / Heal / Clear / Reset) that work regardless of the master
	# toggle, so dimming them would be misleading.
	_add_section_header(c_act, "ACTIONS")
	_add_action_button(c_act, "Refill All Vitals",   "_action_refill_vitals",           COL_SPAWN_BTN)
	_add_action_button(c_act, "Heal Only",           "_action_heal",                    COL_SPAWN_BTN)
	_add_action_button(c_act, "Clear All Ailments",  "_action_clear_ailments",          COL_SPAWN_BTN)
	_add_action_button(c_act, "Reset Multipliers",   "_action_tuner_reset_multipliers", COL_BTN_NORMAL)

	# Register the containers that should visually follow the master
	# toggle state. Cleared + rebuilt on every tab build so stale refs
	# from a previous build don't linger.
	_tuner_dim_targets.clear()
	_tuner_dim_targets.append(vitals_scroll)
	_tuner_dim_targets.append(imm_list)
	_apply_tuner_master_visual_state()

# Builds a complete self-contained block for ONE vital:
#
#   Health                              87 / 100
#   Drain  ━━━━━━●━━━━━    1.0x
#   Regen  ━━━━━━●━━━━━    1.0x
#            [Freeze]   [Lock Max]
#
# Node refs registered in tuner_*_sliders / tuner_*_labels /
# tuner_freeze_checks / tuner_lock_checks / tuner_live_value_labels
# dicts so the throttled live-refresh, reset-action, and state-sync
# code can find them post-build. The block owns its own layout so
# alignment is guaranteed — no dependency on a parallel column having
# the same row heights.
# ──────────────────────────────────────────────────────────────
# PROFILES TAB (v10.6.0)
# ──────────────────────────────────────────────────────────────

# UI state — rebuilt on every tab open; refs stay valid while the tab
# is live, become invalid on tab switch (and _clear_content_area's
# queue_free sweep).
var _profile_header_status_label: Label = null
var _profile_card_name_labels: Array = []        # [Label] × PROFILE_COUNT
var _profile_card_active_labels: Array = []      # [Label] × PROFILE_COUNT
var _profile_card_timestamp_labels: Array = []   # [Label] × PROFILE_COUNT
# v10.6.0 — per-card content surface: a VBox we drop section blocks
# into. Rebuilt only when the profile's `last_modified` changes
# (tracked by _profile_card_content_signature) so a cheat-toggle
# storm doesn't thrash it per-frame.
var _profile_card_content_vboxes: Array = []     # [VBoxContainer] × PROFILE_COUNT
var _profile_card_content_signature: Array[int] = []
var _profile_card_button_rows: Array = []        # [HBoxContainer] × PROFILE_COUNT
# Tracks the active_idx the buttons were last rebuilt against, per-card.
# Prevents the 720-rebuild/sec storm that would otherwise happen during
# slider drags on the Profiles tab (refresh fires every frame while
# _profile_dirty, and each rebuild queue_frees 4 Buttons and creates 4
# new ones). Only rebuild when the active marker actually moved.
# Also tracks the ghost state of the FLUSH button (active-only) so it
# rebuilds when dirty→clean transitions.
var _profile_card_button_built_for_active: Array = []  # [int] × PROFILE_COUNT
var _profile_card_button_built_dirty: Array = []       # [bool] × PROFILE_COUNT

func _load_category_profiles() -> void:
	# Full-width header strip (parented to dashboard_content_sliders so it
	# sits above the 3-column card row).
	_profile_header_status_label = Label.new()
	_style_label(_profile_header_status_label, 13, COL_TEXT_DIM)
	_profile_header_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_profile_header_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard_content_sliders.add_child(_profile_header_status_label)

	# 3 columns — one card per slot.
	var cols: Array = _build_column_vboxes(PROFILE_COUNT)
	_profile_card_name_labels.clear()
	_profile_card_active_labels.clear()
	_profile_card_timestamp_labels.clear()
	_profile_card_content_vboxes.clear()
	_profile_card_content_signature.clear()
	_profile_card_button_rows.clear()
	_profile_card_button_built_for_active.clear()
	_profile_card_button_built_dirty.clear()
	_profile_card_name_labels.resize(PROFILE_COUNT)
	_profile_card_active_labels.resize(PROFILE_COUNT)
	_profile_card_timestamp_labels.resize(PROFILE_COUNT)
	_profile_card_content_vboxes.resize(PROFILE_COUNT)
	_profile_card_content_signature.resize(PROFILE_COUNT)
	_profile_card_button_rows.resize(PROFILE_COUNT)
	_profile_card_button_built_for_active.resize(PROFILE_COUNT)
	_profile_card_button_built_dirty.resize(PROFILE_COUNT)
	for i in range(PROFILE_COUNT):
		_profile_card_button_built_for_active[i] = -1  # sentinel: never built
		_profile_card_button_built_dirty[i] = false
		_profile_card_content_signature[i] = -1        # sentinel: never built

	for i in range(PROFILE_COUNT):
		_build_profile_card(cols[i], i)

	_refresh_profiles_ui()

func _build_profile_card(parent: Container, idx: int) -> void:
	# Card skeleton — reuses the shared dashboard-card style.
	var card_vbox := _make_dashboard_card(parent, "PROFILE %d" % (idx + 1))
	card_vbox.add_theme_constant_override("separation", 6)

	# ── Header: active marker + profile name (big) ──
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	card_vbox.add_child(name_row)

	var active_label := Label.new()
	_style_label(active_label, 16, COL_POSITIVE)
	active_label.custom_minimum_size = Vector2(16, 0)
	name_row.add_child(active_label)
	_profile_card_active_labels[idx] = active_label

	var name_label := Label.new()
	_style_label(name_label, 15, COL_TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_label)
	_profile_card_name_labels[idx] = name_label

	# ── Sub-header: last-saved timestamp ──
	var ts_label := Label.new()
	_style_label(ts_label, 10, COL_DIM)
	card_vbox.add_child(ts_label)
	_profile_card_timestamp_labels[idx] = ts_label

	_add_separator(card_vbox)

	# ── Content area: scrollable list of sections ──
	# A ScrollContainer so long profiles don't blow out the card; inner
	# VBox is populated by _refresh_profile_card_content. Section
	# rebuilds are signature-gated to avoid per-frame churn.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card_vbox.add_child(scroll)

	var content_vbox := VBoxContainer.new()
	content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(content_vbox)
	_profile_card_content_vboxes[idx] = content_vbox

	_add_separator(card_vbox)

	# ── Button row — content varies between active/non-active slots. ──
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_vbox.add_child(btn_row)
	_profile_card_button_rows[idx] = btn_row

func _refresh_profiles_ui() -> void:
	if not is_instance_valid(_profile_header_status_label):
		return
	# Header — active slot + dirty-save countdown
	var active_name := "(none)"
	if _active_profile_idx >= 0 and _active_profile_idx < _profile_names.size():
		active_name = _profile_names[_active_profile_idx]
	var header := "Active: ★ %s" % active_name
	if _profile_dirty:
		var secs: float = max(0.0, _profile_save_timer)
		header += "   —   Auto-saving in %.1fs…" % secs
	else:
		header += "   —   All changes saved"
	_profile_header_status_label.text = header

	# Per-card refresh
	for i in range(PROFILE_COUNT):
		_refresh_profile_card(i)

func _refresh_profile_card(idx: int) -> void:
	if idx < 0 or idx >= PROFILE_COUNT:
		return
	if idx >= _profile_card_name_labels.size():
		return
	# Name + active marker
	var nm: String = _profile_names[idx] if idx < _profile_names.size() else PROFILE_DEFAULT_NAMES[idx]
	if is_instance_valid(_profile_card_name_labels[idx]):
		_profile_card_name_labels[idx].text = nm
	if is_instance_valid(_profile_card_active_labels[idx]):
		_profile_card_active_labels[idx].text = "★" if idx == _active_profile_idx else " "
	# Timestamp
	if is_instance_valid(_profile_card_timestamp_labels[idx]):
		var ts: int = _profile_last_modified[idx] if idx < _profile_last_modified.size() else 0
		_profile_card_timestamp_labels[idx].text = "Saved %s" % _profile_format_relative_time(ts)
	# Content sections — signature-gated rebuild
	_refresh_profile_card_content(idx)
	# Button row — signature-gated rebuild for active marker / dirty state
	_rebuild_profile_card_buttons(idx)

# Re-renders the Cheats / Teleports / Favorites / Keybinds sections
# inside the card's scrollable content vbox. Signature-gated on the
# profile's `last_modified` so the content doesn't get torn down and
# rebuilt on every frame while the user is dragging a slider —
# content only changes when the profile is saved, renamed, reset, or
# switched (all of which bump last_modified on disk).
func _refresh_profile_card_content(idx: int) -> void:
	if idx < 0 or idx >= _profile_card_content_vboxes.size():
		return
	var vbox: VBoxContainer = _profile_card_content_vboxes[idx]
	if not is_instance_valid(vbox):
		return
	var sum: Dictionary = _profile_summaries[idx] if idx < _profile_summaries.size() else {}
	var sig: int = int(sum.get("last_modified", 0))
	# Bump sig when slot becomes / stops being active so the "(active)"
	# cue can influence layout if we ever want it (cheap guard for free).
	if idx == _active_profile_idx:
		sig = sig * 2 + 1
	if idx < _profile_card_content_signature.size() and _profile_card_content_signature[idx] == sig \
			and vbox.get_child_count() > 0:
		return  # nothing new to render
	_profile_card_content_signature[idx] = sig
	for child in vbox.get_children():
		child.queue_free()

	# Empty-state message when the profile has nothing customized.
	var cheats_items: Array = sum.get("cheats_items", []) as Array
	var teleports_items: Array = sum.get("teleports_items", []) as Array
	var favorites_items: Array = sum.get("favorites_items", []) as Array
	var keybinds_items: Array = sum.get("keybinds_items", []) as Array
	var total := cheats_items.size() + teleports_items.size() \
			   + favorites_items.size() + keybinds_items.size()
	if total == 0:
		var empty_label := Label.new()
		empty_label.text = "This profile is empty.\nLoad it and start tweaking —\nchanges auto-save here."
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_style_label(empty_label, 11, COL_DIM)
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 8)
		vbox.add_child(spacer)
		vbox.add_child(empty_label)
		return

	_build_profile_section(vbox, "CHEATS",    cheats_items,    COL_POSITIVE)
	_build_profile_section(vbox, "TELEPORTS", teleports_items, COL_TEXT)
	_build_profile_section(vbox, "FAVORITES", favorites_items, Color(1.0, 0.82, 0.18, 1.0))  # star yellow
	_build_profile_section(vbox, "KEYBINDS",  keybinds_items,  COL_TEXT_DIM)

# Builds a titled section block inside the card. Skipped entirely when
# `items` is empty so the card stays compact for minimal profiles.
# Each item is a Dictionary with {"label", "detail"} (detail optional).
# Truncates to PROFILE_CARD_ITEMS_MAX with a "+N more" summary row.
const PROFILE_CARD_ITEMS_MAX := 6

func _build_profile_section(parent: VBoxContainer, title: String, items: Array, accent: Color) -> void:
	if items == null or items.size() == 0:
		return

	# Section header row — title on the left, count on the right.
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	parent.add_child(header_row)

	var title_label := Label.new()
	title_label.text = title
	_style_label(title_label, 10, accent)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(title_label)

	var count_label := Label.new()
	count_label.text = "%d" % items.size()
	_style_label(count_label, 10, COL_TEXT_DIM)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_row.add_child(count_label)

	# Thin underline below the section header for a clean look.
	var underline := ColorRect.new()
	underline.color = Color(accent.r, accent.g, accent.b, 0.35)
	underline.custom_minimum_size = Vector2(0, 1)
	parent.add_child(underline)

	# Items.
	var shown: int = min(items.size(), PROFILE_CARD_ITEMS_MAX)
	for i in range(shown):
		var item: Dictionary = items[i] as Dictionary
		_build_profile_item_row(parent, item)

	if items.size() > shown:
		var more_label := Label.new()
		more_label.text = "  + %d more…" % (items.size() - shown)
		_style_label(more_label, 10, COL_DIM)
		more_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		parent.add_child(more_label)

	# Bottom spacer so sections don't butt into each other.
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	parent.add_child(spacer)

func _build_profile_item_row(parent: VBoxContainer, item: Dictionary) -> void:
	var label_text: String = String(item.get("label", "?"))
	var detail: String = String(item.get("detail", ""))
	# Row: label (left, expand), detail (right, dim). When detail is
	# empty we just render the label alone.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.clip_text = true
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_label(lbl, 12, COL_TEXT)
	row.add_child(lbl)

	if detail != "":
		var d := Label.new()
		d.text = detail
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		d.clip_text = true
		_style_label(d, 11, COL_TEXT_DIM)
		row.add_child(d)

func _rebuild_profile_card_buttons(idx: int) -> void:
	if idx < 0 or idx >= _profile_card_button_rows.size():
		return
	var row: HBoxContainer = _profile_card_button_rows[idx]
	if not is_instance_valid(row):
		return
	# H1 fix — skip the queue_free + reconstruct unless something that
	# ACTUALLY changes the button row transitioned. The two triggers are
	# the active slot moving (swaps button layout entirely) and the
	# dirty flag (toggles the FLUSH button's ghost modulate on the
	# active card only).
	var is_active := (idx == _active_profile_idx)
	var want_active_marker := _active_profile_idx
	var want_dirty := _profile_dirty if is_active else false
	var built_active: int = _profile_card_button_built_for_active[idx] if idx < _profile_card_button_built_for_active.size() else -1
	var built_dirty: bool = _profile_card_button_built_dirty[idx] if idx < _profile_card_button_built_dirty.size() else false
	if built_active == want_active_marker and built_dirty == want_dirty and row.get_child_count() > 0:
		return  # no meaningful change; skip the churn
	for child in row.get_children():
		child.queue_free()
	_profile_card_button_built_for_active[idx] = want_active_marker
	_profile_card_button_built_dirty[idx] = want_dirty
	if is_active:
		# Active card: FLUSH, RENAME, RESET
		var flush_btn := _make_styled_button("FLUSH", COL_BTN_NORMAL, COL_BTN_HOVER)
		flush_btn.custom_minimum_size = Vector2(0, 28)
		flush_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		flush_btn.pressed.connect(_on_profile_flush_pressed.bind(idx))
		# Ghost the button when nothing to flush.
		if not _profile_dirty:
			flush_btn.modulate = Color(1, 1, 1, 0.5)
		row.add_child(flush_btn)
		var rename_btn := _make_styled_button("RENAME", COL_BTN_NORMAL, COL_BTN_HOVER)
		rename_btn.custom_minimum_size = Vector2(0, 28)
		rename_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rename_btn.pressed.connect(_on_profile_rename_pressed.bind(idx))
		row.add_child(rename_btn)
		var reset_btn := _make_styled_button("RESET", COL_DANGER_BTN, COL_DANGER_HVR)
		reset_btn.custom_minimum_size = Vector2(0, 28)
		reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		reset_btn.pressed.connect(_on_profile_reset_pressed.bind(idx))
		row.add_child(reset_btn)
	else:
		# Non-active card: LOAD, SAVE, RENAME, RESET (compact)
		var load_btn := _make_styled_button("LOAD", COL_SPAWN_BTN, COL_SPAWN_HVR)
		load_btn.custom_minimum_size = Vector2(0, 28)
		load_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		load_btn.pressed.connect(_on_profile_load_pressed.bind(idx))
		row.add_child(load_btn)
		var save_btn := _make_styled_button("SAVE", COL_BTN_NORMAL, COL_BTN_HOVER)
		save_btn.custom_minimum_size = Vector2(0, 28)
		save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		save_btn.pressed.connect(_on_profile_save_pressed.bind(idx))
		row.add_child(save_btn)
		var rename_btn := _make_styled_button("RENAME", COL_BTN_NORMAL, COL_BTN_HOVER)
		rename_btn.custom_minimum_size = Vector2(0, 28)
		rename_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rename_btn.pressed.connect(_on_profile_rename_pressed.bind(idx))
		row.add_child(rename_btn)
		var reset_btn := _make_styled_button("RESET", COL_DANGER_BTN, COL_DANGER_HVR)
		reset_btn.custom_minimum_size = Vector2(0, 28)
		reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		reset_btn.pressed.connect(_on_profile_reset_pressed.bind(idx))
		row.add_child(reset_btn)

# ── Button handlers ───────────────────────────────────────────

func _on_profile_load_pressed(idx: int) -> void:
	_profile_switch(idx)

func _on_profile_save_pressed(idx: int) -> void:
	# "Save current live state into this slot, don't switch."
	# Prompts for a name first — defaults to the slot's current name.
	var default_name: String = _profile_names[idx] if idx < _profile_names.size() else PROFILE_DEFAULT_NAMES[idx]
	_show_name_prompt(
		"SAVE TO PROFILE %d" % (idx + 1),
		"Name this loadout:",
		default_name,
		Callable(self, "_on_profile_save_confirmed").bind(idx)
	)

func _on_profile_save_confirmed(entered_name: String, idx: int) -> void:
	var sanitized := _profile_sanitize_name(entered_name)
	if sanitized == "":
		var fallback: String = _profile_names[idx] if idx < _profile_names.size() else PROFILE_DEFAULT_NAMES[idx]
		sanitized = fallback
	_profile_copy(_active_profile_idx, idx, sanitized)
	if cheat_active_tab == "Profiles":
		_refresh_profiles_ui()

func _on_profile_rename_pressed(idx: int) -> void:
	var current_name: String = _profile_names[idx] if idx < _profile_names.size() else PROFILE_DEFAULT_NAMES[idx]
	_show_name_prompt(
		"RENAME PROFILE %d" % (idx + 1),
		"New name:",
		current_name,
		Callable(self, "_on_profile_rename_confirmed").bind(idx, current_name)
	)

func _on_profile_rename_confirmed(entered_name: String, idx: int, _current_name: String) -> void:
	var sanitized := _profile_sanitize_name(entered_name)
	if sanitized == "":
		# Empty → keep old name
		return
	_profile_rename(idx, sanitized)

func _on_profile_reset_pressed(idx: int) -> void:
	var nm: String = _profile_names[idx] if idx < _profile_names.size() else PROFILE_DEFAULT_NAMES[idx]
	_show_confirm(
		"RESET PROFILE %d" % (idx + 1),
		"Clear '%s' to defaults?\nAll cheats / teleports / favorites in this slot will be lost." % nm,
		Callable(self, "_on_profile_reset_confirmed").bind(idx)
	)

func _on_profile_reset_confirmed(idx: int) -> void:
	_close_confirm()
	_profile_reset(idx)

func _on_profile_flush_pressed(idx: int) -> void:
	if idx != _active_profile_idx:
		return  # defensive — button only exists on active card
	_profile_flush_if_dirty()
	_show_toast("Profile saved")
	if cheat_active_tab == "Profiles":
		_refresh_profiles_ui()

# ── Formatting ────────────────────────────────────────────────

func _profile_format_relative_time(unix_ts: int) -> String:
	if unix_ts <= 0:
		return "never"
	var now := int(Time.get_unix_time_from_system())
	var delta := now - unix_ts
	if delta < 60:
		return "just now"
	if delta < 3600:
		return "%d min ago" % (delta / 60)
	if delta < 86400:
		return "%d hr ago" % (delta / 3600)
	if delta < 86400 * 7:
		return "%d day%s ago" % [delta / 86400, "s" if delta >= 86400 * 2 else ""]
	# Fall back to absolute date for older entries.
	var dt = Time.get_datetime_dict_from_unix_time(unix_ts)
	return "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]


func _tuner_build_vital_block(parent: Control, vital: String):
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 3)
	parent.add_child(block)

	# Header row: vital name (bold) + right-aligned live value readout.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	block.add_child(header)

	var name_lbl := Label.new()
	name_lbl.text = TUNER_VITAL_DISPLAY.get(vital, vital)
	if game_font_bold:
		name_lbl.add_theme_font_override("font", game_font_bold)
	elif game_font:
		name_lbl.add_theme_font_override("font", game_font)
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", COL_TEXT)
	name_lbl.add_theme_color_override("font_shadow_color", COL_SHADOW)
	name_lbl.add_theme_constant_override("shadow_offset_x", 1)
	name_lbl.add_theme_constant_override("shadow_offset_y", 1)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_lbl)

	var live_lbl := Label.new()
	live_lbl.text = "—"
	_style_label(live_lbl, 11, COL_TEXT_DIM)
	live_lbl.custom_minimum_size = Vector2(70, 0)
	live_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(live_lbl)
	tuner_live_value_labels[vital] = live_lbl

	# Multiplier sliders. Drain shows for every vital; Regen only shows
	# for vitals with meaningful passive regen (see TUNER_VITALS_WITH_REGEN
	# comment). Hiding the slider for dead vitals (energy / hydration /
	# cat) keeps the UI honest — no controls that silently do nothing.
	_tuner_build_mult_slider(block, vital, "drain")
	if vital in TUNER_VITALS_WITH_REGEN:
		_tuner_build_mult_slider(block, vital, "regen")

	# Freeze + Lock Max toggles — indented slightly so they visually
	# nest under the slider rows they apply to.
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 14)
	block.add_child(toggles)

	var indent := Control.new()
	indent.custom_minimum_size = Vector2(52, 0)   # matches slider caption width
	toggles.add_child(indent)

	var freeze_cb := CheckButton.new()
	freeze_cb.text = "Freeze"
	freeze_cb.focus_mode = Control.FOCUS_NONE
	_style_button_font(freeze_cb, 11, COL_TEXT_DIM)
	freeze_cb.add_theme_color_override("font_hover_color", COL_TEXT)
	freeze_cb.set_pressed_no_signal(bool(tuner_freeze.get(vital, false)))
	freeze_cb.toggled.connect(_on_tuner_freeze_toggled.bind(vital))
	toggles.add_child(freeze_cb)
	tuner_freeze_checks[vital] = freeze_cb

	var lock_cb := CheckButton.new()
	lock_cb.text = "Lock Max"
	lock_cb.focus_mode = Control.FOCUS_NONE
	_style_button_font(lock_cb, 11, COL_TEXT_DIM)
	lock_cb.add_theme_color_override("font_hover_color", COL_TEXT)
	lock_cb.set_pressed_no_signal(bool(tuner_lock_max.get(vital, false)))
	lock_cb.toggled.connect(_on_tuner_lock_toggled.bind(vital))
	toggles.add_child(lock_cb)
	tuner_lock_checks[vital] = lock_cb

# One multiplier slider row (either "drain" or "regen"). Stores into the
# appropriate tuner dict and refreshes the value label on change.
func _tuner_build_mult_slider(parent: Control, vital: String, kind: String):
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var caption := Label.new()
	caption.text = ("Drain" if kind == "drain" else "Regen")
	_style_label(caption, 11, COL_TEXT_DIM)
	caption.custom_minimum_size = Vector2(44, 0)
	row.add_child(caption)

	var initial: float = (tuner_drain_mult[vital] if kind == "drain" else tuner_regen_mult[vital])
	var slider := HSlider.new()
	slider.focus_mode = Control.FOCUS_NONE
	slider.scrollable = false
	slider.min_value = TUNER_MULT_MIN
	slider.max_value = TUNER_MULT_MAX
	slider.step = TUNER_MULT_STEP
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if game_grabber:
		slider.add_theme_icon_override("grabber", game_grabber)
		slider.add_theme_icon_override("grabber_highlight", game_grabber)
	var track := StyleBoxLine.new()
	track.color = COL_SEPARATOR
	track.grow_begin = 0.0
	track.grow_end = 0.0
	track.thickness = 2
	slider.add_theme_stylebox_override("slider", track)
	var grabber_area := StyleBoxFlat.new()
	grabber_area.bg_color = Color(1, 1, 1, 0.5)
	grabber_area.set_corner_radius_all(4)
	grabber_area.set_content_margin_all(4)
	slider.add_theme_stylebox_override("grabber_area", grabber_area)
	slider.add_theme_stylebox_override("grabber_area_highlight", grabber_area)
	row.add_child(slider)

	var val_lbl := Label.new()
	val_lbl.text = "%.1fx" % initial
	_style_label(val_lbl, 11, COL_TEXT_DIM)
	val_lbl.custom_minimum_size = Vector2(42, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_lbl)

	if kind == "drain":
		tuner_drain_sliders[vital] = slider
		tuner_drain_labels[vital] = val_lbl
	else:
		tuner_regen_sliders[vital] = slider
		tuner_regen_labels[vital] = val_lbl

	slider.value_changed.connect(_on_tuner_mult_changed.bind(vital, kind, val_lbl))


# ── Tuner UI signal handlers ───────────────────────────────────

func _on_tuner_mult_changed(new_val: float, vital: String, kind: String, lbl: Label):
	# Clamp defensively — slider range enforces this already, but a future
	# programmatic write via set_value_no_signal bypasses the range check.
	var v: float = clampf(new_val, TUNER_MULT_MIN, TUNER_MULT_MAX)
	if kind == "drain":
		tuner_drain_mult[vital] = v
	else:
		tuner_regen_mult[vital] = v
	if is_instance_valid(lbl):
		lbl.text = "%.1fx" % v
	_tuner_request_save()

func _on_tuner_freeze_toggled(on: bool, vital: String):
	tuner_freeze[vital] = on
	if on:
		# Capture the current vital value at toggle time so the freeze
		# pins to whatever the user has "now" rather than some stale
		# value from a previous session.
		tuner_freeze_val[vital] = float(game_data.get(vital))
	_tuner_request_save()

func _on_tuner_lock_toggled(on: bool, vital: String):
	tuner_lock_max[vital] = on
	# Lock Max wins over Freeze when both are on. When the user enables
	# lock, uncheck freeze to avoid confusion.
	if on and tuner_freeze_checks.has(vital) \
			and is_instance_valid(tuner_freeze_checks[vital]) \
			and tuner_freeze_checks[vital].button_pressed:
		tuner_freeze_checks[vital].set_pressed_no_signal(false)
		tuner_freeze[vital] = false
	_tuner_request_save()

func _on_tuner_immune_toggled(on: bool, cond: String):
	tuner_immune[cond] = on
	# Rising edge: cure immediately so the indicator sound stops without
	# waiting for the next physics tick to clear the flag.
	if on and bool(game_data.get(cond)):
		_tuner_set_cond(_tuner_get_character(), cond, false)
	_tuner_request_save()

# Walks the registered Tuner containers and adjusts their modulate so
# they read as "active" (full opacity, slight green tint) when the
# master toggle is on and "inactive" (half opacity, no tint) when off.
# Sliders / checkboxes / labels remain clickable in either state so the
# user can stage a loadout before enabling, they just look dormant.
#
# Called:
#   • On every _load_category_tuner build (applies the correct initial
#     state based on the loaded cfg value).
#   • From _on_cheat_toggled whenever cheat_tuner_enabled flips.
func _apply_tuner_master_visual_state():
	# Subtle green tint when active — the same COL_POSITIVE the rest of
	# CheatMenu uses for "this is on" feedback (favorites star, nav
	# highlight, HUD tags). modulate multiplies, so a tint near white
	# with green bias keeps legibility while signaling activity.
	var active_tint := Color(0.85, 1.0, 0.85, 1.0)
	var inactive_tint := Color(1.0, 1.0, 1.0, 0.5)
	var target_mod := active_tint if cheat_tuner_enabled else inactive_tint
	for target in _tuner_dim_targets:
		if is_instance_valid(target):
			target.modulate = target_mod


# ── Dashboard live refresh ─────────────────────────────────────

func _refresh_dashboard_live():
	# Called from _process() at 0.5s cadence when dashboard_panel.visible.
	# Also called directly from _show_dashboard() for an immediate first paint.
	_refresh_dashboard_intel_card()
	_refresh_dashboard_stockpile_card()
	_refresh_dashboard_world_strip()
	_refresh_dashboard_favorites_state()
	# v10.4.2 — Detect a held-weapon swap (primary ↔ secondary) since the
	# last rebuild and force a refresh so the card follows the drawn
	# weapon. Only trigger when the new held slot actually contains a
	# weapon; holstering to fists leaves the card on its last render.
	var _held_now := _get_active_weapon_slot()
	if _held_now != "" and _held_now != _dashboard_weapon_rendered_slot and _get_slot_data_for(_held_now) != null:
		dashboard_weapon_dirty = true
	if dashboard_weapon_dirty:
		_rebuild_dashboard_weapon_card()
		dashboard_weapon_dirty = false
	_refresh_dashboard_weapon_stats()

func _rebuild_dashboard_weapon_card():
	if not is_instance_valid(dashboard_weapon_vbox):
		return
	for child in dashboard_weapon_vbox.get_children():
		child.queue_free()

	# v10.4.2 — Prefer the DRAWN weapon (matches the v10.4.1 fix to
	# _open_weapon_dashboard). Fall back to whichever slot is occupied
	# when nothing is drawn (fists). We also remember which slot this
	# rebuild rendered into `_dashboard_weapon_rendered_slot` so the
	# 0.5s refresh loop in _refresh_dashboard_live can detect a swap
	# and dirty the card.
	var slot_data = null
	var rendered_slot := ""
	var held := _get_active_weapon_slot()
	if held != "":
		slot_data = _get_slot_data_for(held)
		if slot_data != null:
			rendered_slot = held
	if slot_data == null:
		slot_data = _get_slot_data_for("primary")
		if slot_data != null:
			rendered_slot = "primary"
	if slot_data == null:
		slot_data = _get_slot_data_for("secondary")
		if slot_data != null:
			rendered_slot = "secondary"
	_dashboard_weapon_rendered_slot = rendered_slot
	if slot_data == null or slot_data.itemData == null:
		_add_info_label(dashboard_weapon_vbox, "No weapon equipped", COL_TEXT_DIM, 13)
		_add_info_label(dashboard_weapon_vbox, "Equip a weapon to see details", COL_TEXT_DIM, 10)
		return

	var wd = slot_data.itemData

	# Icon
	var icon_tex = _safe(wd, "icon", null)
	if icon_tex != null and icon_tex is Texture2D:
		var icon_center = CenterContainer.new()
		dashboard_weapon_vbox.add_child(icon_center)
		var icon_rect = TextureRect.new()
		icon_rect.texture = icon_tex
		icon_rect.custom_minimum_size = Vector2(80, 80)
		icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_center.add_child(icon_rect)

	# Name
	_add_info_label(dashboard_weapon_vbox, str(_safe(wd, "name", "Unknown")), COL_TEXT, 14)

	# v10.4.2 — Ammo (left) + Condition (right) share a single row to
	# save vertical space and make the info scan at a glance. Ammo uses
	# SIZE_EXPAND_FILL so it takes the free width; condition right-aligns
	# against the card edge.
	var mag_size = _safe(wd, "magazineSize", 0)
	var current_ammo = _safe(slot_data, "amount", 0)
	var chambered = _safe(slot_data, "chamber", false)
	var fm = _safe(slot_data, "mode", 1)
	var mode_str = "Auto" if fm == 2 else "Semi"
	var ammo_text = "%s  %d/%d%s" % [mode_str, current_ammo, mag_size, (" +1" if chambered else "")]
	var condition = _safe(slot_data, "condition", 100)
	var cond_color = COL_POSITIVE if condition > 50 else (Color(1, 1, 0, 1) if condition > 25 else COL_NEGATIVE)

	var stats_row = HBoxContainer.new()
	stats_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_row.add_theme_constant_override("separation", 12)
	dashboard_weapon_vbox.add_child(stats_row)

	var ammo_label = Label.new()
	ammo_label.text = ammo_text
	_style_label(ammo_label, 12, COL_TEXT_DIM)
	ammo_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	stats_row.add_child(ammo_label)

	var cond_label = Label.new()
	cond_label.text = "Condition: %d%%" % condition
	_style_label(cond_label, 12, cond_color)
	cond_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stats_row.add_child(cond_label)

	_add_separator(dashboard_weapon_vbox)

	# Attachments — full list visible (no scroll wrap, v10.4.2).
	var nested = _safe(slot_data, "nested", [])
	if nested is Array and nested.size() > 0:
		_add_info_label(dashboard_weapon_vbox, "ATTACHMENTS", COL_TEXT_DIM, 10)
		for att in nested:
			if att == null:
				continue
			_add_info_label(dashboard_weapon_vbox, "  • " + str(_safe(att, "name", "?")), COL_TEXT, 11)
	else:
		_add_info_label(dashboard_weapon_vbox, "No attachments", COL_TEXT_DIM, 10)

	# Action buttons
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	dashboard_weapon_vbox.add_child(spacer)
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	dashboard_weapon_vbox.add_child(btn_row)
	var fill_btn = _make_styled_button("FILL MAG", COL_SPAWN_BTN, COL_SPAWN_HVR)
	fill_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fill_btn.custom_minimum_size = Vector2(0, 28)
	fill_btn.add_theme_font_size_override("font_size", 11)
	fill_btn.pressed.connect(_dashboard_weapon_fill)
	btn_row.add_child(fill_btn)
	var repair_btn = _make_styled_button("REPAIR", COL_SPAWN_BTN, COL_SPAWN_HVR)
	repair_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	repair_btn.custom_minimum_size = Vector2(0, 28)
	repair_btn.add_theme_font_size_override("font_size", 11)
	repair_btn.pressed.connect(_dashboard_weapon_repair)
	btn_row.add_child(repair_btn)

func _refresh_dashboard_weapon_stats():
	# Live carry weight bar + ammo-match readout pinned below the weapon
	# card. Cheap signature compare so we don't churn the scene tree on
	# every tick when nothing changed.
	if not is_instance_valid(dashboard_weapon_stats_vbox):
		return
	var weight_now = _get_current_carry_weight()
	var weight_max = _get_max_carry_weight()
	var pri = _get_slot_data_for("primary")
	var sec = _get_slot_data_for("secondary")
	var pri_cal = "" if pri == null or pri.itemData == null else str(_safe(pri.itemData, "caliber", ""))
	var sec_cal = "" if sec == null or sec.itemData == null else str(_safe(sec.itemData, "caliber", ""))
	var ammo_by_cal = _get_ammo_by_caliber()
	var pri_ammo = int(ammo_by_cal.get(pri_cal, 0)) if pri_cal != "" else -1
	var sec_ammo = int(ammo_by_cal.get(sec_cal, 0)) if sec_cal != "" else -1
	var sig: Array = [
		int(weight_now * 10.0),
		int(weight_max * 10.0),
		pri_cal, sec_cal, pri_ammo, sec_ammo,
	]
	if sig == _dashboard_weapon_stats_signature:
		return
	_dashboard_weapon_stats_signature = sig

	for child in dashboard_weapon_stats_vbox.get_children():
		child.queue_free()

	# Carry weight bar
	var weight_pct = 0.0
	if weight_max > 0.0:
		weight_pct = clamp((weight_now / weight_max) * 100.0, 0.0, 100.0)
	var weight_color = COL_POSITIVE
	if weight_pct >= 100.0:
		weight_color = COL_NEGATIVE
	elif weight_pct >= 80.0:
		weight_color = Color(1, 1, 0, 1)
	var w_label = Label.new()
	w_label.text = "CARRY  %.1f / %.1f kg" % [weight_now, weight_max]
	_style_label(w_label, 11, weight_color)
	dashboard_weapon_stats_vbox.add_child(w_label)
	var w_bar = _make_dashboard_progress_bar(weight_color)
	w_bar.value = weight_pct
	dashboard_weapon_stats_vbox.add_child(w_bar)

	# Ammo match for equipped calibers
	var has_ammo_section := pri_cal != "" or sec_cal != ""
	if has_ammo_section:
		var ammo_hdr = Label.new()
		ammo_hdr.text = "AMMO MATCH"
		_style_label(ammo_hdr, 10, COL_TEXT_DIM)
		dashboard_weapon_stats_vbox.add_child(ammo_hdr)
		if pri_cal != "":
			_dashboard_weapon_ammo_row(dashboard_weapon_stats_vbox, pri_cal, pri_ammo)
		if sec_cal != "" and sec_cal != pri_cal:
			_dashboard_weapon_ammo_row(dashboard_weapon_stats_vbox, sec_cal, sec_ammo)

func _dashboard_weapon_ammo_row(parent: Control, caliber: String, count: int):
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var cal_lbl = Label.new()
	cal_lbl.text = "  " + caliber
	_style_label(cal_lbl, 11, COL_TEXT_DIM)
	cal_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cal_lbl)
	var cnt_lbl = Label.new()
	cnt_lbl.text = str(count)
	var cnt_color = COL_POSITIVE if count > 0 else COL_NEGATIVE
	_style_label(cnt_lbl, 11, cnt_color)
	cnt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cnt_lbl.custom_minimum_size = Vector2(50, 0)
	row.add_child(cnt_lbl)

# Walks every LootContainer in the current scene and tallies how many
# hold items with rarity >= Rare (ItemData.Rarity.Rare = 1, Legendary = 2).
# Records the bearing tag of the nearest high-value container relative
# to the player's position. Runs once per map entry and caches the
# result — LootContainer rolls its contents at _ready() so the scan is
# a fixed-point read after scene load.
func _scan_loot_bulletin_if_stale(map_name: String) -> Dictionary:
	if _loot_bulletin_cache_map == map_name and not _loot_bulletin_cache.is_empty():
		return _loot_bulletin_cache
	_loot_bulletin_cache = _do_loot_bulletin_scan()
	_loot_bulletin_cache_map = map_name
	return _loot_bulletin_cache

func _do_loot_bulletin_scan() -> Dictionary:
	var result: Dictionary = {"count": 0, "bearing": "", "nearest_dist": -1.0}
	if get_tree() == null or get_tree().current_scene == null:
		return result
	var containers: Array = get_tree().current_scene.find_children("*", "LootContainer", true, false)
	if containers.is_empty():
		return result
	var player_pos: Vector3 = _intel_get_player_pos()
	var nearest_dist: float = 99999.0
	var nearest_bearing: String = ""
	var count: int = 0
	for container in containers:
		if not is_instance_valid(container):
			continue
		if not "loot" in container:
			continue
		var loot_array = container.loot
		if not loot_array is Array:
			continue
		var has_rare: bool = false
		for slot_data in loot_array:
			if slot_data == null:
				continue
			if not "itemData" in slot_data or slot_data.itemData == null:
				continue
			var rarity: int = int(_safe(slot_data.itemData, "rarity", 0))
			if rarity >= 1 and rarity <= 2:  # Rare or Legendary
				has_rare = true
				break
		if not has_rare:
			continue
		count += 1
		if container is Node3D:
			var dx: float = container.global_position.x - player_pos.x
			var dz: float = container.global_position.z - player_pos.z
			var d: float = sqrt(dx * dx + dz * dz)
			if d < nearest_dist:
				nearest_dist = d
				var bearing_idx: int = _intel_bearing_for(player_pos, container.global_position)
				nearest_bearing = INTEL_BEARING_TAGS[bearing_idx]
	result["count"] = count
	result["bearing"] = nearest_bearing
	result["nearest_dist"] = nearest_dist
	return result

func _refresh_dashboard_intel_card():
	# v10.6.1 intel report: threat summary (counts by class) + boss
	# confirmation + loot bulletin scanning LootContainer nodes for
	# high-rarity items. Replaces the raw contact list from earlier
	# versions. Signature-gated so a stable sector doesn't re-render.
	if not is_instance_valid(dashboard_intel_vbox):
		return
	var data: Dictionary = _intel_summary()
	var contacts: Array = data["contacts"]
	var dominant_dir: String = String(data["dominant_dir"])
	var map_name: String = _intel_current_map_name()

	# Threat breakdown: count contacts by type (Bandit/Guard/etc.)
	var type_counts: Dictionary = {}
	var boss_count: int = 0
	var nearest_boss_bearing: String = ""
	var nearest_boss_dist: float = 99999.0
	for c in contacts:
		var t: String = String(c.get("type", "unknown"))
		type_counts[t] = int(type_counts.get(t, 0)) + 1
		if bool(c.get("is_boss", false)):
			boss_count += 1
			var cd: float = float(c.get("distance", -1.0))
			if cd >= 0.0 and cd < nearest_boss_dist:
				nearest_boss_dist = cd
				nearest_boss_bearing = String(c.get("bearing_tag", ""))

	# Stringify threat breakdown in deterministic order for the signature.
	var type_keys: Array = type_counts.keys()
	type_keys.sort()
	var threat_summary: String = ""
	for k in type_keys:
		if threat_summary != "":
			threat_summary += ", "
		threat_summary += "%d %s" % [int(type_counts[k]), String(k).to_lower()]

	# Loot bulletin — cached per map.
	var loot: Dictionary = _scan_loot_bulletin_if_stale(map_name)
	var loot_count: int = int(loot.get("count", 0))
	var loot_dir: String = String(loot.get("bearing", ""))

	var sig: Array = [
		contacts.size(),
		map_name,
		dominant_dir,
		bool(data["any_alert"]),
		bool(data["any_los"]),
		threat_summary,
		boss_count,
		nearest_boss_bearing,
		loot_count,
		loot_dir,
		int(float(data["noise"]) * 2.0),
		int(float(data["next_wave"])),
	]
	if sig == _dashboard_intel_signature:
		return
	_dashboard_intel_signature = sig

	for child in dashboard_intel_vbox.get_children():
		child.queue_free()

	# ── Stamp header (current map as the AO label) ──
	var stamp = Label.new()
	stamp.text = "...kssh... >> SCANNING [%s] <<" % map_name
	_style_label(stamp, 10, COL_TEXT_DIM)
	stamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dashboard_intel_vbox.add_child(stamp)

	# ── Threat status banner ──
	var banner_text: String = "...static... airwaves dead"
	var banner_color: Color = COL_POSITIVE
	if bool(data["any_los"]):
		banner_text = ">> THEY SEE YOU <<"
		banner_color = COL_NEGATIVE
	elif bool(data["any_alert"]):
		var dir_a: String = dominant_dir if dominant_dir != "" else "?"
		banner_text = ">> hostile traffic >> %s <<" % dir_a
		banner_color = Color(1, 0.7, 0.2, 1)
	elif contacts.size() > 0:
		var dir_t: String = dominant_dir if dominant_dir != "" else "?"
		banner_text = ">> chatter detected >> %s <<" % dir_t
		banner_color = Color(0.85, 0.85, 0.55, 1)
	var banner = Label.new()
	banner.text = banner_text
	_style_label(banner, 12, banner_color)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dashboard_intel_vbox.add_child(banner)

	_add_separator(dashboard_intel_vbox)

	# ── Threat summary ──
	_dashboard_intel_kv(dashboard_intel_vbox, "... hostiles ..... %d" % contacts.size())
	if threat_summary != "":
		_dashboard_intel_kv(dashboard_intel_vbox, "... threats ...... " + threat_summary)
	else:
		_dashboard_intel_kv(dashboard_intel_vbox, "... threats ...... [ none reported ]", COL_TEXT_DIM)

	# ── Boss intel ──
	var boss_line: String = "... bosses ....... "
	var boss_color: Color = COL_TEXT_DIM
	if boss_count > 0:
		if nearest_boss_bearing != "":
			boss_line += "[ %d CONFIRMED %s ]" % [boss_count, nearest_boss_bearing]
		else:
			boss_line += "[ %d CONFIRMED ]" % boss_count
		boss_color = COL_NEGATIVE
	else:
		boss_line += "[ none detected ]"
	_dashboard_intel_kv(dashboard_intel_vbox, boss_line, boss_color)

	# ── Loot bulletin ──
	var loot_line: String = "... loot cache ... "
	var loot_color: Color = COL_TEXT_DIM
	if loot_count > 0:
		if loot_dir != "":
			loot_line += "[ %d HIGH-VALUE %s ]" % [loot_count, loot_dir]
		else:
			loot_line += "[ %d HIGH-VALUE ]" % loot_count
		loot_color = COL_POSITIVE
	else:
		loot_line += "[ no exceptional finds ]"
	_dashboard_intel_kv(dashboard_intel_vbox, loot_line, loot_color)

	# ── Noise + spawner wave ──
	var noise: float = float(data["noise"])
	if noise > 0.0:
		_dashboard_intel_kv(dashboard_intel_vbox, "... noise ........ gunfire trace %.1fs" % noise, Color(1, 0.7, 0.2, 1))
	else:
		_dashboard_intel_kv(dashboard_intel_vbox, "... noise ........ ...silent...", COL_TEXT_DIM)

	var next_wave: float = float(data["next_wave"])
	if next_wave > 0.0:
		_dashboard_intel_kv(dashboard_intel_vbox, "... next wave .... ~%ds" % int(next_wave), COL_TEXT_DIM)

	# Footer marker — sells the radio feel
	var footer = Label.new()
	footer.text = "...kssh... END FREQ ...kssh..."
	_style_label(footer, 9, COL_DIM)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dashboard_intel_vbox.add_child(footer)

func _dashboard_intel_kv(parent: Control, line: String, color := COL_TEXT):
	var lbl = Label.new()
	lbl.text = line
	_style_label(lbl, 11, color)
	parent.add_child(lbl)


# ── Tactical HUD overlay ──────────────────────────────────────
# Persistent in-game widget anchored top-right that lists every active
# AI with type/weapon/direction/range/health columns. Auto-hides in
# shelters, when the cheat menu is open, and when the contact list is
# empty. Refreshes at 4 Hz; signature-gated to skip rebuilds when the
# rendered values haven't moved.

# Recursively sets mouse_filter = IGNORE on a Control and every Control
# descendant. Used by the TAC HUD builder to guarantee that no child in
# the HUD subtree can eat game clicks, even if the player opens inventory
# or the world map and it visually overlaps the HUD area.
func _force_ignore_mouse(root: Node):
	if root is Control:
		(root as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in root.get_children():
		_force_ignore_mouse(child)

func _tac_hud_should_show() -> bool:
	if not cheat_tac_hud:
		return false
	# During gameplay RTV locks the cursor to MOUSE_MODE_CAPTURED. Every
	# menu switches away from that (ESC settings and inventory use
	# CONFINED, our F5 uses VISIBLE, etc). One check covers every menu
	# state in the game. Our autoload runs with PROCESS_MODE_ALWAYS so
	# this function still fires while the tree is paused.
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return false
	if bool(_safe(game_data, "shelter", false)):
		return false
	if _get_active_enemies().is_empty():
		return false
	return true

func _build_tac_hud_panel():
	tac_hud_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.06, 0.78)
	style.border_color = Color(1, 0.7, 0.2, 0.6)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	tac_hud_panel.add_theme_stylebox_override("panel", style)
	tac_hud_panel.anchor_left = 0.795
	tac_hud_panel.anchor_top = 0.02
	tac_hud_panel.anchor_right = 0.995
	# Collapsed bottom anchor lets PanelContainer auto-size to the
	# combined minimum size of its child VBox. Panel grows downward
	# from the top anchor and stops exactly where its content ends.
	tac_hud_panel.anchor_bottom = 0.02
	tac_hud_panel.visible = false
	tac_hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(tac_hud_panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	tac_hud_panel.add_child(v)

	var title := Label.new()
	title.text = "[ TAC HUD ]"
	_style_label(title, 11, Color(1, 0.7, 0.2, 1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)

	tac_hud_subtitle = Label.new()
	_style_label(tac_hud_subtitle, 10, COL_TEXT_DIM)
	tac_hud_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tac_hud_subtitle)

	_add_separator(v)

	tac_hud_grid = GridContainer.new()
	tac_hud_grid.columns = 6
	tac_hud_grid.add_theme_constant_override("h_separation", 6)
	tac_hud_grid.add_theme_constant_override("v_separation", 2)
	v.add_child(tac_hud_grid)

	tac_hud_overflow_label = Label.new()
	_style_label(tac_hud_overflow_label, 10, COL_TEXT_DIM)
	tac_hud_overflow_label.visible = false
	v.add_child(tac_hud_overflow_label)

	var footer := Label.new()
	footer.text = "... freq locked ..."
	_style_label(footer, 9, COL_DIM)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(footer)

	# Security: force mouse_filter = IGNORE on every Control in the
	# subtree so no HUD label/grid can eat game clicks if the player
	# opens the inventory or world map while the HUD is still visible
	# on screen.
	_force_ignore_mouse(tac_hud_panel)

func _refresh_tac_hud():
	if not is_instance_valid(tac_hud_panel):
		return
	if not _tac_hud_should_show():
		tac_hud_panel.visible = false
		_tac_hud_signature = []
		return
	var data: Dictionary = _intel_summary()
	var contacts: Array = data["contacts"]
	var map_name: String = _intel_current_map_name()
	var shown: int = min(contacts.size(), TAC_HUD_MAX_ROWS)
	var sig: Array = [contacts.size(), map_name]
	for i in range(shown):
		var c: Dictionary = contacts[i]
		sig.append([
			String(c.get("type", "")),
			String(c.get("weapon", "")),
			String(c.get("bearing_tag", "")),
			String(c.get("bucket", "")),
			int(c.get("health", 0)) / 5,
			bool(c.get("alerted", false)),
			bool(c.get("visible", false)),
		])
	tac_hud_panel.visible = true

	# List grid + subtitle only rebuild when the coarse signature flips,
	# avoiding per-tick node churn on the contact list.
	if sig == _tac_hud_signature:
		return
	_tac_hud_signature = sig

	# Grid and subtitle are children of tac_hud_panel, so in normal
	# operation they're valid whenever the panel is. Belt-and-suspenders
	# guards so a queue_free race during a scene transition can't touch
	# a freed node and crash the refresh.
	if not is_instance_valid(tac_hud_subtitle) or not is_instance_valid(tac_hud_grid):
		return

	var plural: String = "" if contacts.size() == 1 else "s"
	tac_hud_subtitle.text = ">> %s · %d contact%s <<" % [map_name, contacts.size(), plural]

	for child in tac_hud_grid.get_children():
		child.queue_free()
	var headers: Array = ["#", "TYPE", "WPN", "DIR", "RNG", "HP"]
	for h in headers:
		var hl := Label.new()
		hl.text = String(h)
		_style_label(hl, 9, COL_TEXT_DIM)
		tac_hud_grid.add_child(hl)
	for i in range(shown):
		var c: Dictionary = contacts[i]
		var line_color: Color = COL_TEXT
		if bool(c.get("visible", false)):
			line_color = COL_NEGATIVE
		elif bool(c.get("alerted", false)):
			line_color = Color(1, 0.7, 0.2, 1)
		elif String(c.get("bucket", "")) == "CLOSE":
			line_color = Color(1, 0.85, 0.4, 1)
		_tac_hud_cell(str(i + 1), line_color)
		_tac_hud_cell(String(c.get("type", "?")), line_color)
		var wpn: String = String(c.get("weapon", "—"))
		if wpn.length() > 12:
			wpn = wpn.substr(0, 11) + "…"
		_tac_hud_cell(wpn, line_color)
		_tac_hud_cell(String(c.get("bearing_tag", "?")), line_color)
		_tac_hud_cell(String(c.get("bucket", "?")), line_color)
		_tac_hud_cell(str(int(c.get("health", 0))), line_color)

	if contacts.size() > shown:
		tac_hud_overflow_label.visible = true
		tac_hud_overflow_label.text = "... +%d more on band" % (contacts.size() - shown)
	else:
		tac_hud_overflow_label.visible = false

func _tac_hud_cell(text: String, color: Color):
	var lbl := Label.new()
	lbl.text = text
	_style_label(lbl, 11, color)
	tac_hud_grid.add_child(lbl)


func _refresh_dashboard_world_strip():
	# v10.6 — compact single-line status strip. Reads the same sources
	# as the old world card, renders as one dim label.
	if not is_instance_valid(dashboard_world_strip):
		return
	var day: int = 0
	var season: int = 1
	var time_val: float = 0.0
	var weather: String = ""
	if sim_found and sim_ref != null and is_instance_valid(sim_ref):
		day = int(_safe(sim_ref, "day", 0))
		season = int(_safe(sim_ref, "season", 1))
		time_val = float(_safe(sim_ref, "time", 0.0))
		weather = str(_safe(sim_ref, "weather", ""))
	var in_cabin: bool = bool(_safe(game_data, "shelter", false))
	var cat_status: String = _get_cat_status()
	var cash_balance: int = _get_cash_balance()
	var season_name: String = "Summer" if season == 1 else "Winter"
	var parts: Array = []
	parts.append("Day %d" % day)
	parts.append(season_name)
	parts.append(_format_sim_clock(time_val, cheat_real_time))
	if weather != "":
		parts.append(weather)
	parts.append("In Cabin" if in_cabin else "Outdoors")
	if cat_status != "":
		parts.append("Cat: " + cat_status)
	if cash_balance >= 0:
		parts.append("%s ₽" % _format_thousands(cash_balance))
	dashboard_world_strip.text = "  ·  ".join(parts)

func _format_thousands(n: int) -> String:
	# Formats an integer with comma thousands separators for display.
	# e.g. 12450 -> "12,450". GDScript 4 has no builtin for this.
	var s = str(abs(n))
	var parts: Array = []
	while s.length() > 3:
		parts.push_front(s.substr(s.length() - 3, 3))
		s = s.substr(0, s.length() - 3)
	if s.length() > 0:
		parts.push_front(s)
	var joined = ",".join(parts)
	if n < 0:
		return "-" + joined
	return joined

func _refresh_dashboard_stockpile_card():
	# ON YOU — only rebuild rows when any count changed. Inventory reads
	# still happen every tick (cheap grid iteration), but we don't churn
	# the scene tree unless a number actually moved.
	if is_instance_valid(dashboard_stockpile_onyou_vbox):
		var inv = _get_inventory_counts()
		if not _counts_equal(inv, _dashboard_onyou_rendered):
			_dashboard_onyou_rendered = inv.duplicate()
			for child in dashboard_stockpile_onyou_vbox.get_children():
				child.queue_free()
			for cat in STOCKPILE_CATEGORIES:
				_dashboard_stockpile_row(dashboard_stockpile_onyou_vbox, cat, inv.get(cat, 0))
	# IN CABINS — same pattern. The cabin count helper itself is cached
	# at a coarser granularity, so this cache is a second-layer skip that
	# avoids even touching the vbox when nothing changed.
	if is_instance_valid(dashboard_stockpile_cabins_vbox):
		var cab = _get_cabin_counts_cached()
		if not _counts_equal(cab, _dashboard_cabins_rendered):
			_dashboard_cabins_rendered = cab.duplicate()
			for child in dashboard_stockpile_cabins_vbox.get_children():
				child.queue_free()
			for cat in STOCKPILE_CATEGORIES:
				_dashboard_stockpile_row(dashboard_stockpile_cabins_vbox, cat, cab.get(cat, 0))

func _counts_equal(a: Dictionary, b: Dictionary) -> bool:
	# Shallow compare for the 4-key stockpile dicts. Returns true iff
	# both dicts have identical Medical / Food / Ammo / Weapons counts.
	if a.size() != b.size():
		return false
	for k in a.keys():
		if not b.has(k) or int(a[k]) != int(b[k]):
			return false
	return true

func _make_stockpile_icon(category: String) -> PanelContainer:
	# 16x16 colored square with rounded corners. Using PanelContainer with
	# a StyleBoxFlat override so it lays out cleanly inside an HBoxContainer
	# without needing a dedicated min-size control.
	var color = STOCKPILE_COLORS.get(category, Color(0.5, 0.5, 0.5, 1.0))
	var icon = PanelContainer.new()
	icon.custom_minimum_size = Vector2(14, 14)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style = StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	style.content_margin_left = 0
	style.content_margin_right = 0
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	icon.add_theme_stylebox_override("panel", style)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon

func _dashboard_stockpile_row(parent: Control, name: String, count: int):
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	# Icon swatch on the left so each row has a distinct visual anchor.
	row.add_child(_make_stockpile_icon(name))
	var name_label = Label.new()
	name_label.text = name
	_style_label(name_label, 11, COL_TEXT_DIM)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var count_label = Label.new()
	count_label.text = str(count)
	_style_label(count_label, 11, COL_POSITIVE if count > 0 else COL_DIM)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.custom_minimum_size = Vector2(40, 0)
	row.add_child(count_label)

func _rebuild_dashboard_favorites_row():
	if not is_instance_valid(dashboard_favorites_row):
		return
	for child in dashboard_favorites_row.get_children():
		child.queue_free()
	favorite_buttons.clear()

	if favorite_actions.is_empty():
		var hint = Label.new()
		hint.text = "No favorites yet — open a sub-menu and click the ☆ next to any cheat toggle to add it here."
		_style_label(hint, 11, COL_DIM)
		dashboard_favorites_row.add_child(hint)
		return

	for var_name in favorite_actions:
		if var_name not in SETTABLE_VARS:
			continue
		var label_text = _favorite_label(var_name) + ": " + ("ON" if bool(get(var_name)) else "OFF")
		var is_on = bool(get(var_name))
		var bg = COL_SPAWN_BTN if is_on else COL_BTN_NORMAL
		var hv = COL_SPAWN_HVR if is_on else COL_BTN_HOVER
		var btn = _make_styled_button(label_text, bg, hv)
		btn.custom_minimum_size = Vector2(130, 34)
		btn.add_theme_font_size_override("font_size", 11)
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		btn.gui_input.connect(_on_favorite_button_input.bind(var_name))
		dashboard_favorites_row.add_child(btn)
		favorite_buttons[var_name] = btn

func _refresh_dashboard_favorites_state():
	# Only update labels/colors of existing buttons — do not rebuild the row
	# unless the favorites list itself changed (that's handled elsewhere).
	for var_name in favorite_buttons.keys():
		var btn = favorite_buttons[var_name]
		if not is_instance_valid(btn):
			continue
		if var_name not in SETTABLE_VARS:
			continue
		var is_on = bool(get(var_name))
		btn.text = _favorite_label(var_name) + ": " + ("ON" if is_on else "OFF")
		var bg = COL_SPAWN_BTN if is_on else COL_BTN_NORMAL
		var hv = COL_SPAWN_HVR if is_on else COL_BTN_HOVER
		btn.add_theme_stylebox_override("normal", _make_button_flat(bg))
		btn.add_theme_stylebox_override("hover", _make_button_flat(hv))

func _on_favorite_button_input(event: InputEvent, var_name: String):
	if not event is InputEventMouseButton or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		# Left-click toggles the cheat through the canonical handler so
		# side effects like No Overweight's baseCarryWeight override run.
		if var_name in SETTABLE_VARS:
			var new_val = not bool(get(var_name))
			_on_cheat_toggled(new_val, var_name)
			_sync_toggle_ui()
			_refresh_dashboard_favorites_state()
		get_viewport().set_input_as_handled()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		# Right-click removes from favorites.
		_toggle_favorite(var_name)
		get_viewport().set_input_as_handled()


# ── Dashboard card action buttons ──────────────────────────────

func _dashboard_weapon_fill():
	# Route through the existing weapon dashboard helper. It picks the
	# active slot and fills the magazine.
	_dashboard_fill_mag()
	dashboard_weapon_dirty = true
	dashboard_refresh_countdown = 0.0

func _dashboard_weapon_repair():
	_dashboard_repair()
	dashboard_weapon_dirty = true
	dashboard_refresh_countdown = 0.0

func _dashboard_refresh_cabin_counts():
	_invalidate_cabin_counts_cache()
	_refresh_dashboard_stockpile_card()
	_show_toast("Cabin stockpile refreshed")


# ================================================================
#  AI INTELLIGENCE MODULE — Invisibility + ESP (v10.5.0)
# ================================================================
# Two features share the same agent-discovery + frame-tick plumbing
# so the per-frame cost is paid once regardless of which toggles are
# on. The module is self-contained below this banner: constants,
# private state, ticker, ESP overlay class, and public helpers
# (`_ai_build_*`). The only coupling with the rest of the file is
# via `cheat_ai_invisible` / `cheat_ai_esp` flags + the two build
# calls wired into _ready().
#
# INVISIBILITY — PRE-AI SENSOR GATE (v10.5.4 rewrite)
# ----------------------------------------------------
# The obvious-looking shortcut is to remove the player from the
# "Player" group, since AI.gd's LOSCheck asserts
#   if LOS.get_collider().is_in_group("Player"): playerVisible=true
# That works for vision — but the SAME group check is also used by
# AI.Raycast (shot-hit routing → WeaponDamage), BTR.gd raycasts,
# and Explosion.gd splash damage. Removing the group makes the
# player silently bulletproof, which is out of scope for a feature
# advertised as "invisibility to AI".
#
# v10.5.0–v10.5.3 used a POST-AI ticker that zeroed playerVisible
# AFTER AI._physics_process already ran. That was too late: the AI's
# tick runs Sensor → Decision → ChangeState("Combat") → States →
# Combat(delta) → Fire(delta) ALL IN ONE FRAME, so zeroing after was
# cleanup theatre — the shot had already fired.
#
# v10.5.4 flips the architecture. The ticker now runs BEFORE the
# AI's _physics_process (process_physics_priority = -1000). Each
# frame we:
#   1. Set sensorActive = false — AI.gd gates Sensor/Parameters/
#      FireDetection on this flag; once false, LOSCheck never runs
#      and playerVisible / lastKnownLocation / fireDetected never
#      get set to truthy values.
#   2. Zero the four sensor output fields anyway — covers the case
#      where they were set true before we became active.
#   3. Pin playerDistance3D / 2D to 9999 — several state handlers
#      (Hide, Cover, Vantage, Shift, Attack) have distance-based
#      combat transitions (`if playerDistance3D < 10: ChangeState
#      ("Combat")`) that don't gate on playerVisible, so we have to
#      defeat those too.
#   4. If the AI was already mid-combat when invisibility toggled
#      on, ChangeState("Wander") to snap it out. Runs once per
#      transition thanks to edge-detection on currentState.
# When invisibility is OFF we flip sensorActive back to true so AI
# detection resumes naturally on the next tick — Parameters will
# recompute playerDistance3D from the real position.
#
# The reset is edge-detected: we only force-revert combat states
# when the ticker sees `playerVisible == true` OR
# `lastKnownLocation != Vector3.ZERO`. Once the AI is already in a
# safe state and those fields are zero, the tick is a cheap no-op
# pass (four writes, no ChangeState call).
#
# ESP — OVERLAY, NOT PER-AI NODES
# -------------------------------
# One Control.draw per frame beats N Label nodes updating positions
# each frame: no allocations on steady state, the draw is cheap
# enough to sit inside _process, and _draw ordering is stable
# across agent sort orders. unproject_position is frustum-safe
# (returns Vector2 even for behind-camera points), so we pre-cull
# by checking the camera-forward dot product and clamp offscreen
# labels to the viewport edge — classic ESP UX.

# ── Tuning constants ──────────────────────────────────────────
const AI_AGENTS_PATH       := "/root/Map/AI/Agents"
const AI_CHANGE_STATE_SAFE := "Wander"   # AI.gd internally cascades to "Idle" if no wander waypoints exist
const AI_COMBAT_STATE_ENUM_MIN := 6      # enum values ≥ this are combat-adjacent
const AI_ESP_MAX_DISTANCE  := 300.0      # meters — beyond this, skip draw
const AI_ESP_LABEL_FONT_SIZE := 12
const AI_ESP_LINE_HEIGHT     := 14
const AI_ESP_BOX_MIN_HEIGHT  := 24       # minimum vertical span for distant AIs
const AI_ESP_OVERLAY_LAYER   := 110      # above canvas(100), below tac_hud/panels

# v10.5.7 — ESP visual themes. Three distinct rendering paths sharing
# the same agent discovery + projection pipeline; _ai_esp_draw
# dispatches to the selected theme's per-AI renderer. Selection
# persists via ESP_THEME_CFG_PATH so users don't re-pick each session.
const ESP_THEME_VOSTOK  := 0             # tactical/military corner brackets + callsigns
const ESP_THEME_THERMAL := 1             # threat-colored ghost skin (red/yellow/green/blue tint)
const ESP_THEME_GLITCH  := 2             # paranoid/analog flicker + chromatic fringe
const ESP_THEME_CHAMS   := 3             # v10.5.17 — MOH-style spectral chams: real AI texture, translucent
const ESP_THEME_COUNT   := 4
const ESP_THEME_LABELS := [
	"Vostok Intercept",
	"Thermal Scanner",
	"Analog Glitch",
	"Spectral Chams",
]
const ESP_THEME_CFG_PATH := "user://cheatmenu_esp_theme.cfg"

# v10.5.9 — Shader-based thermal. Replaces the 2D skeleton-bone
# overlay with a real ShaderMaterial swap on the AI's MeshInstance3D,
# so the thermal silhouette is sampled from the actual mesh + live
# skinning. Two variants: walls-off (depth-tested, occluded by
# geometry) and walls-on (depth-test-disabled, x-ray through walls).
# Shipped as GDScript string constants rather than .gdshader files to
# sidestep the untested .vmz-shader-file loader path.
#
# Both variants share the same fragment code — only render_mode
# differs. We maintain two compiled Shader resources so the Godot
# shader cache can optimize each independently.
const THERMAL_SHADER_FRAG_BODY := """
// v10.5.15 — "Package B" ghost-skin upgrade. Stacks four layers
// informed by AAA reference research (Apex Bloodhound, Arkham
// Detective, Dishonored Dark Vision, Horizon Focus, Control):
//   1. Fresnel rim STACKING — inner (soft) + outer (sharp) exponents
//      instead of a single power, produces a contoured outline that
//      reads as a proper silhouette not a stamped border.
//   2. World-space TRIPLANAR noise — two octaves of value noise
//      sampled in world space with upward time scroll. "Converts
//      tint into ghost" per the visual research: the body looks
//      possessed by a flowing energy pattern rather than flat-tinted.
//   3. VERTEX breathing — slow sinusoidal push along NORMAL (~0.28 Hz,
//      8mm amplitude). Makes the silhouette feel alive instead of
//      flat-still. Godot auto-composes this AFTER its skinning pass
//      so it layers correctly on animated meshes.
//   4. PRISMATIC rim fringe — RGB channels at slightly different
//      Fresnel exponents, producing a subtle chromatic prism edge
//      without a full screen-space chromatic aberration pass.
//
// `dim_mode` uniform (0.0/1.0) controls the through-walls variant:
// when 1.0, the final color is scaled 35% and desaturated 55% toward
// gray — the canonical "this one is occluded" read used by
// Bloodhound / Arkham. When 0.0, full brightness (LOS pass).

uniform vec3 tint_color : source_color = vec3(0.3, 0.95, 0.4);
uniform float edge_glow : hint_range(0.0, 3.0) = 1.8;
uniform float core_brightness : hint_range(0.0, 2.0) = 1.0;
uniform float dim_mode : hint_range(0.0, 1.0) = 0.0;
uniform float breathe_amount : hint_range(0.0, 1.0) = 1.0;
uniform float noise_amount : hint_range(0.0, 1.0) = 0.7;

// World-space position varying, set in vertex() and read in
// fragment() for triplanar noise sampling.
varying vec3 v_wpos;

// ── Inline value noise. Used for the world-space flowing energy
//    pattern. Godot doesn't have a built-in noise() so we do it by
//    hand; cheap enough that stacking two octaves per fragment is
//    negligible on any modern GPU.
float _hash3(vec3 p) {
	p = fract(p * 0.3183099);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float _vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = _hash3(i + vec3(0.0, 0.0, 0.0));
	float b = _hash3(i + vec3(1.0, 0.0, 0.0));
	float c = _hash3(i + vec3(0.0, 1.0, 0.0));
	float d = _hash3(i + vec3(1.0, 1.0, 0.0));
	float e = _hash3(i + vec3(0.0, 0.0, 1.0));
	float g = _hash3(i + vec3(1.0, 0.0, 1.0));
	float h = _hash3(i + vec3(0.0, 1.0, 1.0));
	float j = _hash3(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(a, b, f.x), mix(c, d, f.x), f.y),
		mix(mix(e, g, f.x), mix(h, j, f.x), f.y),
		f.z);
}

void vertex() {
	// World-space position for triplanar sampling in fragment.
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Breathing displacement. Godot's auto-skinning has already run
	// by the time our body executes, so we add on top of the already-
	// posed VERTEX — animation composes correctly.
	// v10.5.16 — breathing is suppressed 80% in dim_mode so the
	// through-walls silhouette is calm/stable while the LOS body
	// pulses with the full breathing effect. Increases visual
	// differentiation between the two states.
	float breathe = sin(TIME * 1.8) * 0.008 * breathe_amount;
	breathe *= (1.0 - dim_mode * 0.8);
	VERTEX += NORMAL * breathe;
}

void fragment() {
	// NORMAL and VIEW are view-space; VIEW points fragment→camera.
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);

	// ── 1. Body base ─────────────────────────────────────────────
	vec3 body = tint_color * core_brightness * (0.65 + 0.35 * facing);

	// ── 2. World-space triplanar flowing noise ───────────────────
	// Two octaves, second at 2.3× scale and different scroll speed
	// for interference. World-space (not UV) so the pattern stays
	// stable as the AI rotates — mesh feels "possessed by" the
	// pattern rather than texture-mapped.
	vec3 np = v_wpos * 3.0 + vec3(0.0, TIME * 0.5, 0.0);
	float n1 = _vnoise(np);
	float n2 = _vnoise(np * 2.3 + vec3(0.0, TIME * 0.8, 0.0));
	float noise_val = n1 * 0.65 + n2 * 0.35;
	body *= (0.75 + 0.6 * noise_val * noise_amount);

	// ── 3. Fresnel rim stacking ──────────────────────────────────
	// Inner (low exponent) = soft falloff into body.
	// Outer (high exponent) = crisp silhouette outline.
	float fresnel_inner = pow(1.0 - facing, 1.5);
	float fresnel_outer = pow(1.0 - facing, 5.0);
	vec3 rim_color = mix(tint_color, vec3(1.0), 0.35);
	vec3 edge = rim_color * (fresnel_inner * 0.4 + fresnel_outer * 1.2) * edge_glow;

	// ── 4. Prismatic rim fringe ──────────────────────────────────
	// Three fresnel exponents give RGB channels slightly different
	// edge falloffs — "prism edge" look without needing actual
	// screen-space chromatic aberration.
	float f_r = pow(1.0 - facing, 3.0);
	float f_g = pow(1.0 - facing, 3.7);
	float f_b = pow(1.0 - facing, 4.5);
	vec3 prism = vec3(f_r, f_g, f_b) * tint_color * 0.7;
	edge += prism;

	// ── Dim mode for through-walls pass (v10.5.16 — cranked) ─────
	// Per the visual research: cinematic "behind wall" read combines
	// brightness crush + strong desaturation + cool-blue hue shift,
	// with the rim repurposed as a cyan silhouette-locator so you
	// can still see exactly WHERE the occluded AI is. This produces
	// a visually DIFFERENT state from the full LOS ghost, not just
	// a dimmer version of the same color.
	if (dim_mode > 0.5) {
		// Body: heavy desaturation first, then blend toward cool navy,
		// then crush brightness. Produces a very dark cool silhouette
		// that loosely retains the threat-tint hue underneath.
		float body_gray = dot(body, vec3(0.299, 0.587, 0.114));
		body = mix(body, vec3(body_gray), 0.85);
		body = mix(body, vec3(0.08, 0.12, 0.22), 0.70);
		body *= 0.55;

		// Rim: shift strongly toward cyan and boost slightly — the
		// occluded silhouette's outline becomes the primary locator
		// for where the AI is, so it needs to stay readable even as
		// the body fades near-black.
		edge = mix(edge, vec3(0.30, 0.75, 1.00), 0.75) * 1.25;
	}

	vec3 final_color = body + edge;

	ALBEDO = final_color;
}
"""

# v10.5.15 — "visible" variant used as either a standalone material
# (walls-off mode) OR as the `next_pass` in dual-pass mode. Standard
# depth test + write, so it only draws where the AI is actually in
# line-of-sight. In dual-pass mode it overlays the through pass for
# the "bright in LOS" look.
const THERMAL_SHADER_WALLS_OFF_CODE := "shader_type spatial;\nrender_mode unshaded;\n" + THERMAL_SHADER_FRAG_BODY
# v10.5.15 — "through" variant. Used as the PRIMARY material in
# dual-pass mode. Renders the AI even when occluded by world
# geometry. Critical render_mode flags:
#   depth_test_disabled — draws regardless of whether a wall is
#       in front of the AI.
#   depth_draw_never — doesn't WRITE depth. Important because the
#       next_pass layers on top with depth testing, and if this pass
#       wrote AI-depth into the buffer, the next_pass's test would
#       see our own fragments instead of the wall fragments and
#       misbehave. With depth_draw_never, next_pass compares against
#       the true world depth and correctly fills only the in-LOS
#       region.
#   cull_disabled — render both sides of every triangle so the AI
#       is visible from any viewing angle, not just front-facing
#       surfaces.
const THERMAL_SHADER_WALLS_ON_CODE := "shader_type spatial;\nrender_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled;\n" + THERMAL_SHADER_FRAG_BODY


# v10.5.17 — "Spectral Chams" shader. Fundamentally different approach
# from the Thermal theme: instead of replacing the AI's material with a
# threat-tinted effect, this samples the AI's ORIGINAL albedo texture
# and re-renders it translucent + through walls. Classic ghost-chams
# look (Medal of Honor: Allied Assault, circa 2002) — you see the real
# character (clothes, face, gear) but as a phantom presence.
#
# Key render_mode flags:
#   blend_mix — standard alpha blending, required for translucency.
#   depth_test_disabled — renders through world geometry.
#   depth_draw_never — transparent shouldn't write to depth buffer;
#       otherwise subsequent transparent draws misbehave.
#   cull_back — keep normal back-face culling so we don't see the
#       inside of the mesh through the outside on close-up.
#   unshaded — ignore world lighting. A ghost doesn't need shading.
#
# Uniforms:
#   albedo_tex — the AI's original diffuse texture, sampled per-UV so
#       clothes/face/gear texture detail all come through.
#   tint_color — optional subtle threat-color overlay (red/yellow/
#       green/blue). Mixed in at tint_mix intensity (default 0.20)
#       so the real texture dominates; tint just whispers the threat
#       state.
#   alpha_core / alpha_rim — transparency at body core vs silhouette
#       edge. Fresnel drives the interpolation. Core translucent,
#       rim more opaque for a clean silhouette pop.
#
# Vertex stage adds subtle breathing (~5mm, 0.32 Hz) for "alive ghost"
# feel without being a pulsing distraction.
const CHAMS_SHADER_CODE := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_back, unshaded;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform vec3 tint_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float alpha_core : hint_range(0.0, 1.0) = 0.28;
uniform float alpha_rim : hint_range(0.0, 1.0) = 0.90;
uniform float tint_mix : hint_range(0.0, 1.0) = 0.20;
uniform float brightness : hint_range(0.0, 3.0) = 1.15;

void vertex() {
	// Subtle breathing, half the amplitude of the thermal theme so
	// it doesn't visually compete with the real character details.
	VERTEX += NORMAL * sin(TIME * 2.0) * 0.005;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);

	// Fresnel — high at silhouette edges, low at fragment-facing core.
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = 1.0 - facing;
	float rim_factor = pow(fresnel, 2.0);

	// Body color: original texture, subtly whispered with threat tint.
	vec3 color = mix(tex.rgb, tex.rgb * tint_color, tint_mix);
	color *= brightness;

	// Alpha profile: translucent body, more opaque rim. Gives the
	// "X-ray meets ghost" look — you see through the body but the
	// silhouette pops clearly.
	float alpha = mix(alpha_core, alpha_rim, rim_factor) * tex.a;

	ALBEDO = color;
	ALPHA = alpha;
}
"""

# Cyrillic callsign mapping for Vostok Intercept — military/boss
# variants get Cyrillic prefixes to sell the "intercepted transmission"
# aesthetic. Civilian bandit types stay Latin.
const VOSTOK_CALLSIGN_MAP := {
	"Bandit":   "BANDIT",
	"Guard":    "ГВАРДИЯ",
	"Military": "ВОЙСКА",
	"Punisher": "КАРАТЕЛЬ",
}

# ── Private state ─────────────────────────────────────────────
var _ai_ticker: Node = null
var _ai_esp_overlay: Control = null
# Cached reference to the Agents parent. Invalidated when the scene
# transitions — _ai_resolve_agents_node re-resolves if the cached
# node is freed. Avoids a get_node_or_null per tick.
var _ai_agents_parent_cached: Node = null
# Overlay container — stored for symmetric teardown. Without a ref,
# we'd have to walk _ai_esp_overlay.get_parent() to free the layer.
var _ai_esp_layer: CanvasLayer = null
# Edge-tracker for invisibility-off restoration. When the cheat flips
# from true→false we need one restoration sweep over every AI to
# re-enable sensorActive, otherwise they stay blind forever.
var _ai_inv_was_active: bool = false
# Edge-tracker for Freeze AI. Mirrors the invisibility pattern — we
# need one unfreeze sweep when the cheat turns off, otherwise AIs
# stay paused indefinitely.
var _ai_freeze_was_active: bool = false

# v10.5.9 — thermal shader state.
# _shared_thermal_shader_{off,on}: the two Shader resources (compiled
#   ONCE each at _ready time; every AI's ShaderMaterial points at the
#   relevant one, so we get per-AI uniform divergence without per-AI
#   shader compilation.
# _thermal_saved_materials: instance_id(MeshInstance3D) → {
#     "mesh_id": int, "saved_mat": Material (can be null)
#   }. Keyed by instance_id (int) rather than the Node ref so freed
#   Nodes don't leak into the dict — on each tick we validate via
#   instance_from_id() and drop stale entries.
# _ai_esp_shader_was_active: edge sentinel for toggle-off restoration,
#   same pattern as _ai_inv_was_active.
# _ai_esp_shader_empty_ticks: consecutive ticks with zero agents
#   while shader mode is on. Used as the "probable scene transition"
#   heuristic to clear the whole saved-materials dict defensively.
var _shared_thermal_shader_off: Shader = null
var _shared_thermal_shader_on: Shader = null
# v10.5.17 — Spectral Chams shared Shader. Single variant (always
# renders through walls with translucent blend).
var _shared_chams_shader: Shader = null
var _thermal_saved_materials: Dictionary = {}
var _ai_esp_shader_was_active: bool = false
var _ai_esp_shader_empty_ticks: int = 0


# ── Ticker child node ─────────────────────────────────────────
# process_physics_priority = -1000 runs us BEFORE any in-scene
# CharacterBody3D (default priority 0), which means BEFORE every
# AI's _physics_process. v10.5.0-v10.5.3 used priority 1001 (after
# AI) and had the race-to-shoot bug documented in the module header.
# The negative priority is the authoritative fix: we pre-empt the
# AI's detection phase so Fire() never gets a chance to execute.
class _AIIntelTicker extends Node:
	var owner_ref: Node
	func _physics_process(delta: float) -> void:
		if is_instance_valid(owner_ref) and owner_ref.has_method("_ai_on_physics_tick"):
			owner_ref._ai_on_physics_tick(delta)


func _ai_build_ticker() -> void:
	_ai_ticker = _AIIntelTicker.new()
	_ai_ticker.owner_ref = self
	_ai_ticker.name = "AIIntelTicker"
	_ai_ticker.process_physics_priority = -1000
	add_child(_ai_ticker)


# Per-tick dispatcher. Runs every physics frame. Edge-tracks the
# invisibility toggle: when it flips OFF, we do one restoration pass
# over every agent to re-enable sensorActive, otherwise AIs would
# stay blind forever because our per-frame pre-empt had disabled it.
func _ai_on_physics_tick(_delta: float) -> void:
	# Invisibility-off transition: run a restoration sweep exactly
	# once when the cheat flips false, then go quiet.
	if not cheat_ai_invisible and _ai_inv_was_active:
		var agents_to_restore := _ai_resolve_agents_children()
		for ai in agents_to_restore:
			_ai_restore_sensor_on(ai)
		_ai_inv_was_active = false

	# Freeze-off transition: unfreeze every AI whose pause we had
	# pinned. Same edge-detection pattern as the invisibility restore.
	if not cheat_ai_freeze and _ai_freeze_was_active:
		var agents_to_thaw := _ai_resolve_agents_children()
		for ai in agents_to_thaw:
			_ai_unfreeze(ai)
		_ai_freeze_was_active = false

	# v10.5.9 — 3D-skin toggle-off. When ESP goes off OR the theme
	# switches away from a shader-based theme, restore every saved
	# material and empty the dict. Restoration iterates the DICT
	# (saved mesh refs), not the live agents list — so dead AIs,
	# ragdolls, and corpses all get cleaned up correctly.
	# v10.5.17 — CHAMS theme is also shader-based; include it.
	var shader_wanted: bool = cheat_ai_esp and (
		cheat_ai_esp_theme == ESP_THEME_THERMAL
		or cheat_ai_esp_theme == ESP_THEME_CHAMS
	)
	if not shader_wanted and _ai_esp_shader_was_active:
		_esp_thermal_shader_restore_all()
		_ai_esp_shader_was_active = false

	if not (cheat_ai_invisible or cheat_ai_esp or cheat_ai_freeze):
		return
	var agents := _ai_resolve_agents_children()

	# Thermal-shader scene-transition heuristic: if shader mode is on
	# and we see no agents for 2+ consecutive ticks, the scene likely
	# transitioned. Purge the saved-materials dict (meshes are freed
	# anyway) to avoid leaking stale entries.
	if shader_wanted and agents.is_empty():
		_ai_esp_shader_empty_ticks += 1
		if _ai_esp_shader_empty_ticks >= 2 and not _thermal_saved_materials.is_empty():
			_thermal_saved_materials.clear()
		return
	_ai_esp_shader_empty_ticks = 0

	if agents.is_empty():
		return

	if cheat_ai_invisible:
		_ai_inv_was_active = true
		for ai in agents:
			_ai_enforce_invisibility_on(ai)
	if cheat_ai_freeze:
		_ai_freeze_was_active = true
		for ai in agents:
			_ai_freeze_on(ai)

	# v10.5.9 / v10.5.17 — 3D-skin apply pass. For each close AI: swap
	# in the theme's material via the 3D-skin dispatcher (thermal or
	# chams). For each FAR AI that we previously swapped (AI moved
	# outside range mid-session), restore its original material so
	# the 2D fallback can take over cleanly (thermal only — chams
	# has no 2D fallback and just stops rendering at range).
	if shader_wanted:
		_ai_esp_shader_was_active = true
		var cam := _ai_resolve_camera()
		var cam_origin: Vector3 = cam.global_transform.origin if cam != null else Vector3.ZERO
		for ai in agents:
			if _esp_thermal_shader_wants_ai(ai, cam_origin):
				_esp_3d_skin_apply(ai)
			else:
				# Out of range now — if we had previously swapped, undo
				# that swap so far-range rendering uses original material.
				_esp_thermal_shader_restore_one(ai)
		# Periodic GC to drop entries whose mesh was freed.
		if int(Time.get_ticks_msec() / 1000.0) % 2 == 0:
			_esp_thermal_shader_gc()


# Resolve the live AI node list. v10.5.5 broadened from a single
# hardcoded /root/Map/AI/Agents lookup to a two-source union:
#
#   1. Game's native AISpawner parent: /root/Map/AI/Agents — this is
#      where the village / zone AIs end up after AISpawner.reparent.
#   2. Direct children of current_scene — external spawners
#      (InjuryTester v2.2.0's "Spawn AI in front of me" feature, and
#      any other testing mod that calls `current_scene.add_child(ai)`)
#      park their AIs here. Without this path, spawner-created AIs
#      would never receive invisibility enforcement OR ESP rendering,
#      which was the exact bug reported in v10.5.4: user tested with
#      spawner AIs instead of running to the village, and invisibility
#      appeared to do nothing because my ticker literally couldn't see
#      the AIs being tested against.
#
# Duck-type probe (_ai_looks_like_ai) identifies AI instances by their
# unique property shape — AI.gd has sensorActive + currentState +
# playerVisible together, no other class in the game does. Cheaper and
# more robust than scripting-class checks.
func _ai_resolve_agents_children() -> Array:
	var result: Array = []
	if not is_instance_valid(_ai_agents_parent_cached):
		_ai_agents_parent_cached = get_node_or_null(AI_AGENTS_PATH)
	if is_instance_valid(_ai_agents_parent_cached):
		for a in _ai_agents_parent_cached.get_children():
			if _ai_looks_like_ai(a):
				result.append(a)
	# Also walk the direct children of the current scene for spawner-
	# placed AIs. Not recursive — spawners park their AIs at the scene
	# root, not nested — so this stays O(direct-child-count).
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		for a in tree.current_scene.get_children():
			if _ai_looks_like_ai(a):
				result.append(a)
	return result


# Duck-type AI detection. An AI is the only class in RTV carrying all
# three of these fields together. Cheap — three property probes per
# candidate, only invoked on the bounded set of candidates the two
# search paths already produced.
func _ai_looks_like_ai(node: Node) -> bool:
	if not is_instance_valid(node):
		return false
	return ("sensorActive" in node) \
			and ("currentState" in node) \
			and ("playerVisible" in node)


# Pre-AI invisibility enforcement. Runs BEFORE AI._physics_process
# (via process_physics_priority = -1000 on the ticker), so everything
# we write here becomes the state AI sees when it runs this frame.
func _ai_enforce_invisibility_on(ai: Node) -> void:
	if not is_instance_valid(ai):
		return
	# Skip dead AIs — writing to a corpse is a waste and would mean a
	# gratuitous ChangeState call.
	if "dead" in ai and bool(ai.dead):
		return

	# 1. SENSOR GATE — the primary mechanism. AI.gd's _physics_process
	#    guards Sensor/Parameters/FireDetection on this flag
	#    (AI.gd:239). With it false, LOSCheck never runs and the raycast
	#    that writes playerVisible=true never happens.
	if "sensorActive" in ai:
		ai.sensorActive = false

	# 2. SENSOR OUTPUT FIELDS — zero anyway. Defense-in-depth for the
	#    case where they were set true on a prior tick before our ticker
	#    became active.
	var was_alerted: bool = false
	if "playerVisible" in ai and bool(ai.playerVisible):
		was_alerted = true
	if not was_alerted and "lastKnownLocation" in ai:
		if (ai.lastKnownLocation as Vector3) != Vector3.ZERO:
			was_alerted = true
	if "playerVisible" in ai:      ai.playerVisible = false
	if "lastKnownLocation" in ai:  ai.lastKnownLocation = Vector3.ZERO
	if "fireDetected" in ai:       ai.fireDetected = false
	if "extraVisibility" in ai:    ai.extraVisibility = 0.0

	# 3. DISTANCE PIN — Hide/Cover/Vantage/Shift/Attack state handlers
	#    have distance-based combat transitions (`if playerDistance3D <
	#    10: ChangeState("Combat")`) that don't gate on playerVisible.
	#    Pin distance to a huge value so those checks always fail.
	#    Parameters() would normally recompute this, but sensorActive=
	#    false (step 1) prevents Parameters from running, so our pinned
	#    value persists through the tick.
	if "playerDistance3D" in ai: ai.playerDistance3D = 9999.0
	if "playerDistance2D" in ai: ai.playerDistance2D = 9999.0

	# 4. STATE REVERT — unconditional revert of any combat-range state to
	#    Wander. v10.5.5 gated this on `was_alerted`, but that falsified
	#    itself immediately (step 2 zeros LKL each tick → was_alerted
	#    goes false next tick), so a spawner's deferred `ChangeState
	#    ("Attack")` landing after our first zeroing pass would never
	#    get reverted. Result: AI didn't fire (sensor off) but was still
	#    in Attack state, aggressively navigating to attack waypoints
	#    searching for a sightline.
	#
	#    The revert is SELF-GATED: ChangeState("Wander") sets
	#    currentState = 1 (< AI_COMBAT_STATE_ENUM_MIN = 6), so next tick
	#    the state check fails and we don't spam GetWanderWaypoint. The
	#    revert only re-fires if something external flips state back
	#    into the combat range — which is exactly the scenario this
	#    branch is here to catch.
	if "currentState" in ai and ai.has_method("ChangeState"):
		var st: int = int(ai.currentState)
		if st >= AI_COMBAT_STATE_ENUM_MIN:
			ai.ChangeState(AI_CHANGE_STATE_SAFE)


# Restore AI.sensorActive=true when invisibility toggles off. AI's
# next Parameters() tick will recompute playerDistance3D from the real
# player position, so we don't re-initialize distance fields here.
func _ai_restore_sensor_on(ai: Node) -> void:
	if not is_instance_valid(ai):
		return
	if "dead" in ai and bool(ai.dead):
		return
	if "sensorActive" in ai:
		ai.sensorActive = true


# Freeze AI: pin pause = true. AI.gd:235 has `if pause || dead: return`
# at the top of _physics_process, so setting this flag completely
# stops Sensor / Parameters / FireDetection / States / Movement /
# Rotation / Poles / Animate — the AI becomes a statue. Useful for
# setup, screenshots, or dealing with one target while the rest of
# the pack stands down.
#
# We DO still enforce invisibility on top of this if both toggles are
# on — harmless, belt and suspenders.
func _ai_freeze_on(ai: Node) -> void:
	if not is_instance_valid(ai):
		return
	if "dead" in ai and bool(ai.dead):
		return
	if "pause" in ai:
		ai.pause = true


# Unfreeze path for when the cheat toggles off. Only runs on the edge
# so we don't stomp the AI's own Activate/Pause cycling during normal
# gameplay (Activate sets pause=false; if we kept writing pause=false
# every tick a manual AI.Pause() call from the game would be undone).
func _ai_unfreeze(ai: Node) -> void:
	if not is_instance_valid(ai):
		return
	if "dead" in ai and bool(ai.dead):
		return
	if "pause" in ai:
		ai.pause = false


# ── ESP overlay ───────────────────────────────────────────────
# Custom Control subclass so we can override _draw cleanly without
# polluting the autoload with draw callbacks. Holds a back-ref to
# the autoload so the draw loop can read AI state + the toggle
# flag without a get_node roundtrip.
class _AIESPOverlay extends Control:
	var owner_ref: Node

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE     # never steal input
		set_anchors_preset(Control.PRESET_FULL_RECT)
		z_index = 5

	func _process(_d: float) -> void:
		# Always queue a redraw. Previous revision conditionally skipped
		# queue_redraw() when the toggle was off, which meant the LAST
		# frame drawn before toggle-off stayed visible indefinitely (GPU
		# buffer wasn't invalidated until something else forced a redraw,
		# like window resize). Always queuing + a fast early-return in
		# _draw gives us guaranteed same-frame clear on toggle-off at
		# the cost of one extra no-op _draw per inactive frame — trivial.
		if is_instance_valid(owner_ref):
			queue_redraw()

	func _draw() -> void:
		if not is_instance_valid(owner_ref):
			return
		if not bool(owner_ref.cheat_ai_esp):
			return    # fast-path: toggle off → no draw commands → canvas clears
		owner_ref._ai_esp_draw(self)


func _ai_build_esp_overlay() -> void:
	# v10.5.7 — restore the user's theme preference before the overlay
	# starts rendering. Safe to no-op if no cfg exists (first run).
	_esp_theme_load_cfg()
	# v10.5.9 — pre-compile the two thermal Shader resources so first-
	# frame apply doesn't cause a shader-compile hitch.
	_esp_thermal_shader_init()
	# Parent the overlay to its own CanvasLayer so it renders ABOVE
	# the rest of the mod UI (which sits on `canvas` layer 100) but
	# BELOW panels like the cheat menu dashboard — ESP on top of HUD,
	# panels on top of ESP.
	_ai_esp_layer = CanvasLayer.new()
	_ai_esp_layer.layer = AI_ESP_OVERLAY_LAYER
	_ai_esp_layer.name = "AIESPLayer"
	add_child(_ai_esp_layer)
	_ai_esp_overlay = _AIESPOverlay.new()
	_ai_esp_overlay.owner_ref = self
	_ai_esp_overlay.name = "AIESPOverlay"
	_ai_esp_layer.add_child(_ai_esp_overlay)


# Draw entry — called from the overlay's _draw with `self` so we
# can use draw_* methods in context.
# v10.5.7 — Theme dispatcher. Computes the common per-AI projection
# bundle once and passes it to the theme-specific per-AI renderer.
# Theme-level decorations (viewport scan line, compass arrows, glitch
# connections) are drawn separately before/after the per-AI pass so
# they layer correctly.
func _ai_esp_draw(ctl: Control) -> void:
	var camera := _ai_resolve_camera()
	if camera == null:
		return
	var agents := _ai_resolve_agents_children()
	var viewport_size: Vector2 = ctl.get_viewport_rect().size
	var cam_forward: Vector3 = -camera.global_transform.basis.z
	var cam_origin: Vector3 = camera.global_transform.origin
	var font := ctl.get_theme_default_font()

	# v10.6.1 — Thermal scan-line removed per community feedback
	# (_davodal_: "constant thermal scanner line... is kinda off").
	# v10.6.2 — the scan-line function body was also removed (was dead
	# code); see the comment block above where it used to live.

	if agents.is_empty():
		return

	# Per-AI pass
	for ai in agents:
		# v10.6.1 — skip killed AIs when the hide-dead toggle is on.
		# Per-theme code below already has its own ai.dead state-tint
		# logic for when the toggle is OFF; this guard short-circuits
		# the entire draw path for the on case.
		if cheat_ai_esp_hide_dead and "dead" in ai and bool(ai.dead):
			continue
		var proj := _esp_project_ai(ai, camera, cam_origin, cam_forward)
		if proj.is_empty():
			continue
		match cheat_ai_esp_theme:
			ESP_THEME_VOSTOK:
				_esp_draw_vostok(ctl, ai, proj, viewport_size, font)
			ESP_THEME_THERMAL:
				_esp_draw_thermal(ctl, ai, proj, viewport_size, font)
			ESP_THEME_GLITCH:
				_esp_draw_glitch(ctl, ai, proj, viewport_size, font)
			ESP_THEME_CHAMS:
				# v10.5.17 — Chams ghost renders via 3D ShaderMaterial;
				# we add a full tactical data card alongside for
				# callsign / HP / distance / state / LOCK info,
				# matching the Vostok theme's informational density
				# but styled with the chams tint as the accent.
				_esp_draw_chams_card(ctl, ai, proj, viewport_size, font)
			_:
				_esp_draw_vostok(ctl, ai, proj, viewport_size, font)

	# Post-pass (above AI markers)
	match cheat_ai_esp_theme:
		ESP_THEME_VOSTOK:
			_esp_vostok_offscreen_compass(ctl, agents, camera, viewport_size, cam_origin, cam_forward, font)
		ESP_THEME_GLITCH:
			_esp_glitch_connect_hostiles(ctl, agents, camera, cam_origin, cam_forward)


# Shared geometry projection. Returns {} when the AI is invalid,
# dead-pixel-far, behind the camera, or projects to a non-finite
# point. Otherwise returns a dict with the screen-space rect, head
# point, feet point, 3D distance, and base color.
func _esp_project_ai(ai: Node, camera: Camera3D, cam_origin: Vector3, cam_forward: Vector3) -> Dictionary:
	if not is_instance_valid(ai) or not (ai is Node3D):
		return {}
	var ai_pos: Vector3 = (ai as Node3D).global_position
	var to_ai: Vector3 = ai_pos - cam_origin
	var distance: float = to_ai.length()
	if distance > AI_ESP_MAX_DISTANCE:
		return {}
	if to_ai.dot(cam_forward) <= 0.0:
		return {}
	var head_world: Vector3 = ai_pos + Vector3(0, 1.8, 0)
	if "head" in ai and is_instance_valid(ai.head) and ai.head is Node3D:
		head_world = (ai.head as Node3D).global_position
	var head_2d: Vector2 = camera.unproject_position(head_world)
	var feet_2d: Vector2 = camera.unproject_position(ai_pos)
	if not _ai_vec2_is_finite(head_2d) or not _ai_vec2_is_finite(feet_2d):
		return {}
	var box_height: float = max(abs(feet_2d.y - head_2d.y), AI_ESP_BOX_MIN_HEIGHT)
	var box_width: float = box_height * 0.45
	var box_center_x: float = (head_2d.x + feet_2d.x) * 0.5
	var box_top_y: float = min(head_2d.y, feet_2d.y)
	return {
		"rect": Rect2(box_center_x - box_width * 0.5, box_top_y, box_width, box_height),
		"head_2d": head_2d,
		"feet_2d": feet_2d,
		"distance": distance,
		"color": _ai_esp_color_for(ai),
	}


# ──────────────────────────────────────────────────────────────
# THEME A — VOSTOK INTERCEPT
# Corner-bracket reticle + center crosshair + callsign data card.
# Brackets pulse when SEES YOU, dash when alerted but not engaged.
# ──────────────────────────────────────────────────────────────
# v10.5.17 — Spectral Chams data card. Same information density as
# the Vostok theme (callsign / HP bar / distance + state / LOCK
# warning) but accent-colored with the threat tint so it harmonizes
# with the ghost's subtle color whisper instead of fighting it.
func _esp_draw_chams_card(ctl: Control, ai: Node, proj: Dictionary,
		viewport_size: Vector2, font: Font) -> void:
	if font == null:
		return
	var rect: Rect2 = proj.rect
	var distance: float = proj.distance
	var tint: Color = _esp_thermal_tint_for(ai)
	# Slightly brighter-than-ghost accent so the text reads against
	# a dark world. Keep at 85% brightness so it doesn't shout.
	var color := Color(
		min(tint.r * 1.1, 1.0),
		min(tint.g * 1.1, 1.0),
		min(tint.b * 1.1, 1.0),
		0.95
	)
	var sees_you: bool = "playerVisible" in ai and bool(ai.playerVisible)

	# Card placement — prefer right of box, flip to left near edge.
	var card_w: float = 140.0
	var card_x: float = rect.position.x + rect.size.x + 8
	if card_x + card_w > viewport_size.x - 8:
		card_x = rect.position.x - card_w - 8
	var line_y: float = rect.position.y + 2
	var line_h: float = 13.0

	# Line 1: callsign (Cyrillic prefix for military/boss types).
	var callsign: String = _esp_vostok_callsign(ai)
	ctl.draw_string(font, Vector2(card_x, line_y + 9), callsign,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)
	line_y += line_h

	# Line 2: HP bar — integer + solid fill.
	if "health" in ai:
		var hp: int = int(round(float(ai.health)))
		var hp_max: int = 300 if ("boss" in ai and bool(ai.boss)) else 100
		ctl.draw_string(font, Vector2(card_x, line_y + 9), "HP",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)
		var bar_x: float = card_x + 22
		var bar_w: float = 46
		var bar_h: float = 6
		var bar_y: float = line_y + 2
		ctl.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h),
				Color(color.r * 0.2, color.g * 0.2, color.b * 0.2, 0.55), true)
		var fill_frac: float = clampf(float(hp) / float(hp_max), 0.0, 1.0)
		ctl.draw_rect(Rect2(bar_x, bar_y, bar_w * fill_frac, bar_h), color, true)
		ctl.draw_string(font, Vector2(bar_x + bar_w + 6, line_y + 9), str(hp),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)
		line_y += line_h

	# Line 3: distance · state.
	var state_name: String = _ai_state_name(ai)
	ctl.draw_string(font, Vector2(card_x, line_y + 9),
			"%dm · %s" % [int(round(distance)), state_name],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)

	# Line 4 (optional): SEES YOU warning pill.
	if sees_you:
		line_y += line_h
		var warn_col := Color(1.0, 0.25, 0.25, 1.0)
		ctl.draw_rect(Rect2(card_x, line_y + 2, 64, 12),
				Color(warn_col.r, warn_col.g, warn_col.b, 0.25), true)
		ctl.draw_string(font, Vector2(card_x + 4, line_y + 11), "LOCK",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, warn_col)


func _esp_draw_vostok(ctl: Control, ai: Node, proj: Dictionary, viewport_size: Vector2, font: Font) -> void:
	var rect: Rect2 = proj.rect
	var color: Color = proj.color
	var distance: float = proj.distance
	var head_2d: Vector2 = proj.head_2d
	var sees_you: bool = "playerVisible" in ai and bool(ai.playerVisible)
	var alerted: bool = ("lastKnownLocation" in ai) and ((ai.lastKnownLocation as Vector3) != Vector3.ZERO)
	# Pulse: arcs expand 0..4px outward on sees_you, 8 rad/s.
	var pulse: float = 0.0
	if sees_you:
		var t: float = Time.get_ticks_msec() / 1000.0
		pulse = 2.0 + 2.0 * sin(t * 8.0)
	# v10.5.14 — replaced the 4 L-shaped corner brackets (which
	# formed an implicit rectangle) with 4 curved quarter-arcs that
	# suggest a capsule shape around the AI. Still reads as a
	# tactical lock-on but targets the BODY silhouette rather than a
	# geometric box. Corner radius tracks the smaller box dimension
	# so the arcs feel proportionate at any AI screen size.
	var dashed: bool = alerted and not sees_you
	var grown := rect.grow(pulse)
	# Arc radius: 25% of the smaller box dim, minimum 8px so distant
	# AIs still get visible arcs.
	var arc_r: float = max(min(grown.size.x, grown.size.y) * 0.25, 8.0)
	# The 4 arc CENTERS are inset from the outer bounding rect by
	# arc_r, so the arcs sweep from one outer edge to the adjacent
	# outer edge — producing a capsule's curved corners.
	var inner_tl := grown.position + Vector2(arc_r, arc_r)
	var inner_tr := Vector2(grown.end.x - arc_r, grown.position.y + arc_r)
	var inner_bl := Vector2(grown.position.x + arc_r, grown.end.y - arc_r)
	var inner_br := grown.end - Vector2(arc_r, arc_r)
	# Angle conventions: 0 = +X, π/2 = +Y (Godot 2D Y points down).
	# Top-left arc:     π   → 3π/2 (sweeps from left edge up to top edge)
	# Top-right arc:    3π/2 → 2π
	# Bottom-right arc: 0    → π/2
	# Bottom-left arc:  π/2  → π
	_esp_arc(ctl, inner_tl, arc_r, PI,        PI * 1.5,  color, dashed)
	_esp_arc(ctl, inner_tr, arc_r, PI * 1.5,  TAU,       color, dashed)
	_esp_arc(ctl, inner_br, arc_r, 0.0,       PI * 0.5,  color, dashed)
	_esp_arc(ctl, inner_bl, arc_r, PI * 0.5,  PI,        color, dashed)
	# Center crosshair at the head position.
	var cl: float = 6.0
	ctl.draw_line(Vector2(head_2d.x - cl, head_2d.y), Vector2(head_2d.x + cl, head_2d.y), color, 1.0)
	ctl.draw_line(Vector2(head_2d.x, head_2d.y - cl), Vector2(head_2d.x, head_2d.y + cl), color, 1.0)
	if font == null:
		return
	# Data card. Prefer right side of box; flip to left near viewport edge.
	var card_w: float = 140.0
	var card_x: float = rect.position.x + rect.size.x + 8
	if card_x + card_w > viewport_size.x - 8:
		card_x = rect.position.x - card_w - 8
	var line_y: float = rect.position.y + 2
	var line_h: float = 13.0
	# Line 1: callsign (Cyrillic for military/boss types).
	var callsign: String = _esp_vostok_callsign(ai)
	ctl.draw_string(font, Vector2(card_x, line_y + 9), callsign,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)
	line_y += line_h
	# Line 2: HP bar — integer + solid fill.
	if "health" in ai:
		var hp: int = int(round(float(ai.health)))
		var hp_max: int = 300 if ("boss" in ai and bool(ai.boss)) else 100
		ctl.draw_string(font, Vector2(card_x, line_y + 9), "HP",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)
		var bar_x: float = card_x + 22
		var bar_w: float = 46
		var bar_h: float = 6
		var bar_y: float = line_y + 2
		ctl.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h),
				Color(color.r * 0.2, color.g * 0.2, color.b * 0.2, 0.6), true)
		var fill_frac: float = clampf(float(hp) / float(hp_max), 0.0, 1.0)
		ctl.draw_rect(Rect2(bar_x, bar_y, bar_w * fill_frac, bar_h), color, true)
		ctl.draw_string(font, Vector2(bar_x + bar_w + 6, line_y + 9), str(hp),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)
		line_y += line_h
	# Line 3: distance · state.
	var state_name: String = _ai_state_name(ai)
	ctl.draw_string(font, Vector2(card_x, line_y + 9),
			"%dm · %s" % [int(round(distance)), state_name],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)
	# Line 4 (optional): SEES YOU warning pill.
	if sees_you:
		line_y += line_h
		var warn_col := Color(1.0, 0.25, 0.25, 1.0)
		ctl.draw_rect(Rect2(card_x, line_y + 2, 64, 12), Color(warn_col.r, warn_col.g, warn_col.b, 0.25), true)
		ctl.draw_string(font, Vector2(card_x + 4, line_y + 11), "LOCK",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, warn_col)


# v10.5.14 — Draw one quarter-arc, solid or dashed. Used by the
# Vostok theme's capsule-corner lock-on. Solid mode uses Godot's
# native draw_arc; dashed mode manually steps the arc and draws
# alternating short line segments for a dotted look.
func _esp_arc(ctl: Control, center: Vector2, radius: float,
		start_angle: float, end_angle: float, color: Color, dashed: bool) -> void:
	if not dashed:
		ctl.draw_arc(center, radius, start_angle, end_angle, 16, color, 1.5, true)
		return
	# Dashed: sample the arc in 10 segments, draw 1 and skip 1.
	var segments: int = 10
	var prev: Vector2 = center + Vector2(cos(start_angle), sin(start_angle)) * radius
	for i in range(1, segments + 1):
		var t: float = float(i) / segments
		var ang: float = lerp(start_angle, end_angle, t)
		var next: Vector2 = center + Vector2(cos(ang), sin(ang)) * radius
		if i % 2 == 1:
			ctl.draw_line(prev, next, color, 1.5)
		prev = next


# Draw one L-shaped corner bracket. Legacy helper — no longer used
# by the Vostok theme after v10.5.14 but kept for any future theme
# that wants square-corner brackets.
#   origin: the corner point
#   h_len / v_len: arm lengths
#   dir.x: +1 arm extends right, -1 left
#   dir.y: +1 arm extends down,  -1 up
func _esp_bracket(ctl: Control, origin: Vector2, h_len: float, v_len: float,
		dir: Vector2, color: Color, dashed: bool) -> void:
	var h_end := origin + Vector2(h_len * dir.x, 0)
	var v_end := origin + Vector2(0, v_len * dir.y)
	if dashed:
		_esp_dashed_line(ctl, origin, h_end, color, 1.5, 3.0, 3.0)
		_esp_dashed_line(ctl, origin, v_end, color, 1.5, 3.0, 3.0)
	else:
		ctl.draw_line(origin, h_end, color, 1.5)
		ctl.draw_line(origin, v_end, color, 1.5)


# Dashed-line primitive. Godot 4 has draw_dashed_line on CanvasItem
# in some builds but not universally; this does it manually so we
# don't version-gate on engine features.
func _esp_dashed_line(ctl: Control, from: Vector2, to: Vector2, color: Color,
		width: float, dash_len: float, gap_len: float) -> void:
	var total: float = from.distance_to(to)
	if total <= 0.0:
		return
	var dir: Vector2 = (to - from) / total
	var pos: float = 0.0
	while pos < total:
		var seg_end: float = min(pos + dash_len, total)
		ctl.draw_line(from + dir * pos, from + dir * seg_end, color, width)
		pos = seg_end + gap_len


# Vostok callsign: AI type → possibly Cyrillic prefix + instance-id-
# derived 2-digit suffix. Suffix is stable per AI across frames because
# instance_id doesn't change mid-session.
func _esp_vostok_callsign(ai: Node) -> String:
	var type_name: String = _ai_display_type(ai)
	# Strip "(BOSS)" trailer so lookup works on the base type.
	var base: String = type_name.replace(" (BOSS)", "")
	var prefix: String = String(VOSTOK_CALLSIGN_MAP.get(base, base.to_upper()))
	var is_boss: bool = "boss" in ai and bool(ai.boss)
	var suffix: int = int(ai.get_instance_id()) % 100
	if is_boss:
		return "%s-%02d ★" % [prefix, suffix]
	return "%s-%02d" % [prefix, suffix]


# Off-screen compass arrows. For AIs outside the frustum, draw a small
# arrow at the viewport edge pointing toward the AI's world position,
# labeled with distance. Unique to the Vostok theme.
func _esp_vostok_offscreen_compass(ctl: Control, agents: Array, camera: Camera3D,
		viewport_size: Vector2, cam_origin: Vector3, cam_forward: Vector3, font: Font) -> void:
	if font == null:
		return
	var center: Vector2 = viewport_size * 0.5
	var margin: float = 24.0
	for ai in agents:
		if not is_instance_valid(ai) or not (ai is Node3D):
			continue
		var ai_pos: Vector3 = (ai as Node3D).global_position
		var to_ai: Vector3 = ai_pos - cam_origin
		var distance: float = to_ai.length()
		if distance > AI_ESP_MAX_DISTANCE:
			continue
		# Only draw arrow if AI is NOT on-screen.
		var on_screen: bool = to_ai.dot(cam_forward) > 0.0
		var screen_pt: Vector2 = Vector2.ZERO
		if on_screen:
			screen_pt = camera.unproject_position(ai_pos)
			if screen_pt.x >= 0 and screen_pt.x <= viewport_size.x \
					and screen_pt.y >= 0 and screen_pt.y <= viewport_size.y:
				continue  # on-screen, main draw already rendered this AI
		# Compute screen-space 2D direction from center to AI's projected
		# point. For behind-camera AIs the projection is unreliable, so
		# we use the horizontal angle between camera forward and to_ai.
		var right: Vector3 = camera.global_transform.basis.x
		var dx: float = right.dot(to_ai.normalized())
		var dz: float = cam_forward.dot(to_ai.normalized())
		var dir_2d: Vector2 = Vector2(dx, -dz).normalized()
		if dz < 0.0:
			# Behind camera — flip horizontal so arrow points toward the
			# edge the AI would appear at if the player rotated.
			dir_2d.x = sign(dx) if dx != 0.0 else 1.0
			dir_2d.y = 0.0
		# Clamp to viewport edge minus margin.
		var half: Vector2 = viewport_size * 0.5 - Vector2(margin, margin)
		var scale_factor: float = min(
				(half.x / abs(dir_2d.x)) if abs(dir_2d.x) > 0.001 else INF,
				(half.y / abs(dir_2d.y)) if abs(dir_2d.y) > 0.001 else INF
		)
		var arrow_pos: Vector2 = center + dir_2d * scale_factor
		# Draw triangular arrow.
		var color: Color = _ai_esp_color_for(ai)
		var perp := Vector2(-dir_2d.y, dir_2d.x)
		var tip := arrow_pos + dir_2d * 8.0
		var back1 := arrow_pos + perp * 5.0
		var back2 := arrow_pos - perp * 5.0
		ctl.draw_polygon(PackedVector2Array([tip, back1, back2]), PackedColorArray([color, color, color]))
		# Distance label behind the arrow.
		var label_pos: Vector2 = arrow_pos - dir_2d * 14.0 + Vector2(-8, 3)
		ctl.draw_string(font, label_pos, "%dm" % int(round(distance)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, color)


# ──────────────────────────────────────────────────────────────
# THEME B — THERMAL SCANNER
# Heat-vision radial glow (approximated via stacked alpha rects).
# v10.6.1 — the sweeping scan line was removed per community feedback
# (_davodal_: "constant thermal scanner line... is kinda off"). The
# former `_esp_thermal_scanline(ctl, viewport_size)` function was
# deleted in v10.6.2 (H1 audit item — dead code) after we confirmed
# no remaining callers. Git blame at commit range 10.5.17→10.6.2
# carries the original implementation if anyone wants it back.
# ──────────────────────────────────────────────────────────────


# v10.5.8 — thermal theme now dispatches on distance. Close-to-mid
# range uses the AI's live Skeleton3D to render a body-shaped
# silhouette that moves with the animator (arms swing, legs stride,
# posture shifts); far range falls back to the original box glow
# because the body projection collapses to a smudge anyway.
const THERMAL_BODY_MAX_DIST := 200.0


func _esp_draw_thermal(ctl: Control, ai: Node, proj: Dictionary,
		viewport_size: Vector2, font: Font) -> void:
	var distance: float = proj.distance
	var heat: float = _esp_thermal_heat_for(ai)
	# v10.5.9 — if the 3D shader path is actively overriding this AI's
	# material, the thermal silhouette is already being rendered in the
	# 3D scene — skip the 2D overlay entirely (would double up over
	# the real render). We still want a minimal distance label though.
	if distance < THERMAL_BODY_MAX_DIST and _esp_thermal_shader_is_applied_to(ai):
		if font != null and distance > 30.0:
			var lbl_col := Color(1.0, 0.95, 0.85, 0.75)
			var lx: float = proj.rect.position.x + proj.rect.size.x + 8
			if lx + 80 > viewport_size.x:
				lx = proj.rect.position.x - 80 - 8
			ctl.draw_string(font, Vector2(lx, proj.rect.position.y + 10),
					"%dm" % int(round(distance)),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, lbl_col)
		return
	# 2D body-silhouette render (v10.5.8 fallback for AIs without
	# skeleton or when shader path is unavailable) if close enough.
	if distance < THERMAL_BODY_MAX_DIST:
		var skel := _esp_thermal_find_skeleton(ai)
		if skel != null:
			_esp_thermal_render_body(ctl, ai, skel, proj, viewport_size, distance, heat, font)
			return
	# Far fallback: box glow. At > 200m the skeleton's on-screen size
	# is small enough that joint-accurate rendering isn't worth the
	# draw-call cost; a cleaner box reads better at a glance.
	_esp_thermal_render_distant(ctl, ai, proj, viewport_size, distance, heat, font)


# Query: is our thermal ShaderMaterial currently applied to this AI's
# MeshInstance3D override? Fast — just a dict lookup.
func _esp_thermal_shader_is_applied_to(ai: Node) -> bool:
	var mesh := _esp_thermal_resolve_mesh(ai)
	if mesh == null:
		return false
	return _thermal_saved_materials.has(mesh.get_instance_id())


# ──────────────────────────────────────────────────────────────
# v10.5.9 — Thermal shader pipeline
#
# State flow:
#   1. _ready → _ai_build_esp_overlay → _esp_thermal_shader_init
#      compiles the two Shader resources once.
#   2. Each physics tick, if theme == Thermal AND cheat_ai_esp AND
#      the AI is close enough to benefit from the shader look, we
#      swap its MeshInstance3D.surface_override_material(0) to a
#      fresh ShaderMaterial pointing at the appropriate shared
#      Shader. The AI's original material is saved in
#      _thermal_saved_materials keyed by the mesh's instance_id.
#   3. On theme change OR cheat_ai_esp toggle-off OR scene
#      transition (detected by N-empty-ticks heuristic), we iterate
#      the saved-materials dict and restore each mesh.
# ──────────────────────────────────────────────────────────────
func _esp_thermal_shader_init() -> void:
	if _shared_thermal_shader_off == null:
		_shared_thermal_shader_off = Shader.new()
		_shared_thermal_shader_off.code = THERMAL_SHADER_WALLS_OFF_CODE
	if _shared_thermal_shader_on == null:
		_shared_thermal_shader_on = Shader.new()
		_shared_thermal_shader_on.code = THERMAL_SHADER_WALLS_ON_CODE
	# v10.5.17 — pre-compile the Chams shader at load time so first-
	# frame apply doesn't hitch.
	if _shared_chams_shader == null:
		_shared_chams_shader = Shader.new()
		_shared_chams_shader.code = CHAMS_SHADER_CODE


# Resolve-and-cache the AI's MeshInstance3D. Stored via set_meta on
# the AI node itself so the cache lifecycles with the AI — if the AI
# is freed, the meta goes with it; no parallel dict to garbage-
# collect. AI.tscn structure is constant across variants:
# Bandit/Armature/Skeleton3D/Mesh, always a single MeshInstance3D
# with one surface.
func _esp_thermal_resolve_mesh(ai: Node) -> MeshInstance3D:
	if not is_instance_valid(ai):
		return null
	if ai.has_meta("_thermal_mesh_cache"):
		var cached = ai.get_meta("_thermal_mesh_cache")
		if cached is MeshInstance3D and is_instance_valid(cached):
			return cached as MeshInstance3D
	var meshes = ai.find_children("*", "MeshInstance3D", true, false)
	for m in meshes:
		if is_instance_valid(m):
			ai.set_meta("_thermal_mesh_cache", m)
			return m as MeshInstance3D
	return null


# Apply the thermal material to one AI if not already applied, or
# refresh its uniforms if already applied. Safe to call every tick.
func _esp_thermal_shader_apply(ai: Node) -> void:
	var mesh := _esp_thermal_resolve_mesh(ai)
	if mesh == null:
		return
	var mesh_id: int = mesh.get_instance_id()
	# v10.5.15 — dual-pass architecture. When cheat_ai_esp_walls is
	# true we apply a PRIMARY material using the through-walls shader
	# (depth_test_disabled, dim_mode=1.0) plus a next_pass material
	# using the visible shader (standard depth test, dim_mode=0.0).
	# Compositing order:
	#   Primary draws everywhere including through walls (dim/desat).
	#   Next_pass draws in LOS only (bright full ghost treatment).
	#   Where in LOS: next_pass overlays primary → bright visible.
	#   Where occluded: only primary draws → dim silhouette through
	#   wall (canonical Apex Bloodhound / Arkham Detective look).
	# When cheat_ai_esp_walls is false we apply ONLY the visible
	# shader — AIs outside LOS simply aren't drawn.
	var dual_pass: bool = bool(cheat_ai_esp_walls)
	var primary_shader: Shader = _shared_thermal_shader_on if dual_pass else _shared_thermal_shader_off
	if not _thermal_saved_materials.has(mesh_id):
		var saved = mesh.get_surface_override_material(0)
		_thermal_saved_materials[mesh_id] = {
			"mesh": mesh,
			"saved_mat": saved,
			"applied_primary": null,
			"applied_dual": false,
		}
	var entry: Dictionary = _thermal_saved_materials[mesh_id]
	var current_override = mesh.get_surface_override_material(0)

	# Rebuild the material chain if structure has changed OR first apply.
	var needs_rebuild: bool = (
		current_override == null
		or not (current_override is ShaderMaterial)
		or (current_override as ShaderMaterial).shader != primary_shader
		or bool(entry.get("applied_dual", false)) != dual_pass
	)
	if needs_rebuild:
		var primary := ShaderMaterial.new()
		# CRITICAL: assign the SHARED Shader resource directly. Do NOT
		# duplicate(true) — that deep-copies the Shader and triggers a
		# fresh compile per AI, causing a visible hitch at 20+ AIs.
		primary.shader = primary_shader
		if dual_pass:
			# Primary is the through-walls (dim) pass; next_pass is the
			# visible (bright) pass layered on top.
			var next_mat := ShaderMaterial.new()
			next_mat.shader = _shared_thermal_shader_off
			primary.next_pass = next_mat
		# else: walls-off → no next_pass, primary IS the visible shader.
		mesh.set_surface_override_material(0, primary)
		entry["applied_primary"] = primary_shader
		entry["applied_dual"] = dual_pass

	# ── Per-tick uniform sync ────────────────────────────────────
	# Tint updates live (state → color). dim_mode depends on which
	# pass this material is on. v10.5.16 — noise_amount +
	# breathe_amount also differ per-pass: the primary (dim) pass
	# gets reduced values so the through-walls silhouette is a calm,
	# clean read while the next_pass (bright, LOS) gets the full
	# fancy treatment. Increases visual contrast between the two.
	var applied_mat = mesh.get_surface_override_material(0)
	if applied_mat is ShaderMaterial:
		var primary_sm := applied_mat as ShaderMaterial
		var tint: Color = _esp_thermal_tint_for(ai)
		var tint_vec := Vector3(tint.r, tint.g, tint.b)
		primary_sm.set_shader_parameter("tint_color", tint_vec)
		primary_sm.set_shader_parameter("dim_mode", 1.0 if dual_pass else 0.0)
		if dual_pass:
			# Primary IS the dim/through pass. Calm it down: less
			# noise churn, less breathing, so the silhouette through
			# the wall reads as a steady cool marker.
			primary_sm.set_shader_parameter("noise_amount", 0.20)
			primary_sm.set_shader_parameter("breathe_amount", 0.25)
			if primary_sm.next_pass is ShaderMaterial:
				var next_sm := primary_sm.next_pass as ShaderMaterial
				next_sm.set_shader_parameter("tint_color", tint_vec)
				next_sm.set_shader_parameter("dim_mode", 0.0)
				next_sm.set_shader_parameter("noise_amount", 0.70)
				next_sm.set_shader_parameter("breathe_amount", 1.00)
		else:
			# Walls-off single pass: full fancy treatment on primary.
			primary_sm.set_shader_parameter("noise_amount", 0.70)
			primary_sm.set_shader_parameter("breathe_amount", 1.00)


# Restore everything. Iterates the saved dict (NOT the live agents
# list), so dead AIs / ragdolls / freed-node cases are all handled.
func _esp_thermal_shader_restore_all() -> void:
	for mesh_id in _thermal_saved_materials.keys():
		var entry: Dictionary = _thermal_saved_materials[mesh_id]
		var mesh = entry.get("mesh")
		# is_instance_valid + instance_from_id dual-check — is_instance_valid
		# can briefly lie on same-frame freeing.
		if mesh != null and is_instance_valid(mesh) \
				and instance_from_id(mesh_id) != null \
				and mesh is MeshInstance3D:
			(mesh as MeshInstance3D).set_surface_override_material(0, entry.get("saved_mat"))
	_thermal_saved_materials.clear()
	_ai_esp_shader_empty_ticks = 0


# v10.5.17 — Spectral Chams apply. Fundamentally different pipeline
# from thermal: we SAMPLE the AI's original albedo texture (from
# whichever material was active at first-apply time) and feed it into
# a custom ghost shader that renders it translucent + through walls.
# Player sees the real AI — clothes, face, gear, textures — but as a
# phantom. Classic MOH: AA ghost-chams aesthetic.
func _esp_chams_apply(ai: Node) -> void:
	var mesh := _esp_thermal_resolve_mesh(ai)
	if mesh == null:
		return
	var mesh_id: int = mesh.get_instance_id()

	# First-time: snapshot the existing override AND resolve the
	# original albedo texture. If we sample after override, we'd be
	# grabbing our own chams material's albedo instead of the real one.
	if not _thermal_saved_materials.has(mesh_id):
		var saved = mesh.get_surface_override_material(0)
		# Source material for the texture. If no override was set,
		# the mesh uses its ArrayMesh built-in material — grab that.
		var source_mat = saved
		if source_mat == null:
			source_mat = mesh.get_active_material(0)
		var albedo_tex: Texture2D = null
		if source_mat is ShaderMaterial:
			var t = (source_mat as ShaderMaterial).get_shader_parameter("albedo")
			if t is Texture2D:
				albedo_tex = t
		_thermal_saved_materials[mesh_id] = {
			"mesh": mesh,
			"saved_mat": saved,
			"applied_primary": null,
			"applied_dual": false,
			"applied_theme": -1,
			"albedo_cache": albedo_tex,
		}

	var entry: Dictionary = _thermal_saved_materials[mesh_id]
	var albedo_tex = entry.get("albedo_cache")
	if albedo_tex == null:
		# No source texture — can't do chams. Silent bail; theme just
		# doesn't render on this AI. Should be extremely rare for
		# RTV's AI meshes (all Bandit/Guard/Military/Punisher have
		# textured shaders).
		return

	var current_override = mesh.get_surface_override_material(0)
	var needs_rebuild: bool = (
		current_override == null
		or not (current_override is ShaderMaterial)
		or (current_override as ShaderMaterial).shader != _shared_chams_shader
		or int(entry.get("applied_theme", -1)) != ESP_THEME_CHAMS
	)
	if needs_rebuild:
		var chams_mat := ShaderMaterial.new()
		chams_mat.shader = _shared_chams_shader
		chams_mat.set_shader_parameter("albedo_tex", albedo_tex)
		mesh.set_surface_override_material(0, chams_mat)
		entry["applied_primary"] = _shared_chams_shader
		entry["applied_dual"] = false
		entry["applied_theme"] = ESP_THEME_CHAMS

	# Per-tick tint update. Threat-color whisper — the chams shader
	# uses tint_color at 20% mix so the real texture still dominates.
	var applied = mesh.get_surface_override_material(0)
	if applied is ShaderMaterial:
		var sm := applied as ShaderMaterial
		var tint: Color = _esp_thermal_tint_for(ai)
		sm.set_shader_parameter("tint_color", Vector3(tint.r, tint.g, tint.b))


# v10.5.17 — dispatcher that routes to the correct 3D-skin apply
# path based on the active ESP theme. Both thermal and chams are
# ShaderMaterial-override-based; Vostok and Glitch are 2D canvas
# drawing only and don't go through here.
func _esp_3d_skin_apply(ai: Node) -> void:
	match cheat_ai_esp_theme:
		ESP_THEME_THERMAL:
			_esp_thermal_shader_apply(ai)
		ESP_THEME_CHAMS:
			_esp_chams_apply(ai)


# Per-AI restore. Used when an AI moves beyond the shader distance
# mid-session — we undo its swap so the 2D box-glow fallback renders
# cleanly without a stale thermal material underneath.
func _esp_thermal_shader_restore_one(ai: Node) -> void:
	var mesh := _esp_thermal_resolve_mesh(ai)
	if mesh == null:
		return
	var mesh_id: int = mesh.get_instance_id()
	if not _thermal_saved_materials.has(mesh_id):
		return
	var entry: Dictionary = _thermal_saved_materials[mesh_id]
	mesh.set_surface_override_material(0, entry.get("saved_mat"))
	_thermal_saved_materials.erase(mesh_id)


# Garbage collection pass for the saved-materials dict. Drops entries
# whose MeshInstance3D is freed. Called every 60 ticks from the
# dispatcher to keep the dict from leaking across scene changes.
func _esp_thermal_shader_gc() -> void:
	var stale: Array = []
	for mesh_id in _thermal_saved_materials.keys():
		var entry: Dictionary = _thermal_saved_materials[mesh_id]
		var mesh = entry.get("mesh")
		if mesh == null or not is_instance_valid(mesh) or instance_from_id(mesh_id) == null:
			stale.append(mesh_id)
	for mesh_id in stale:
		_thermal_saved_materials.erase(mesh_id)


# Helper: should the shader path be active for this AI? (Close enough
# that the detailed silhouette is worth the material swap.) Far AIs
# get the existing box-glow overlay — their on-screen size is small
# enough that the shader won't read as more detailed than the 2D fall-
# back.
func _esp_thermal_shader_wants_ai(ai: Node, cam_origin: Vector3) -> bool:
	if not is_instance_valid(ai) or not (ai is Node3D):
		return false
	var d: float = ((ai as Node3D).global_position - cam_origin).length()
	return d < THERMAL_BODY_MAX_DIST


# v10.5.12 — threat-level semantic tint. Dead / passive / alerted /
# combat each get a distinct color. Called by both the 3D shader
# pipeline (via set_shader_parameter) AND the 2D fallback paths,
# so colors stay in lockstep across distance thresholds.
const ESP_TINT_COMBAT   := Color(1.00, 0.18, 0.15)  # red
const ESP_TINT_ALERTED  := Color(1.00, 0.82, 0.15)  # yellow
const ESP_TINT_PASSIVE  := Color(0.28, 0.95, 0.38)  # green
const ESP_TINT_DEAD     := Color(0.25, 0.55, 1.00)  # blue

func _esp_thermal_tint_for(ai: Node) -> Color:
	if "dead" in ai and bool(ai.dead):
		return ESP_TINT_DEAD
	if "currentState" in ai and int(ai.currentState) >= AI_COMBAT_STATE_ENUM_MIN:
		return ESP_TINT_COMBAT
	if "lastKnownLocation" in ai and (ai.lastKnownLocation as Vector3) != Vector3.ZERO:
		return ESP_TINT_ALERTED
	return ESP_TINT_PASSIVE


# Raycast-based occlusion test. Fires one ray from the active camera
# position to the AI's torso position; if anything between us hits,
# the AI is occluded. Excludes the AI itself via RID so the ray
# doesn't trivially terminate at its collision body.
#
# Called every physics tick per AI under shader mode. Cost is ~1
# raycast per AI per tick (negligible — Godot physics comfortably
# handles thousands of rays per second).
func _esp_thermal_check_occluded(ai: Node) -> bool:
	if not is_instance_valid(ai) or not (ai is Node3D):
		return false
	var camera := _ai_resolve_camera()
	if camera == null:
		return false
	var world := camera.get_world_3d()
	if world == null:
		return false
	var space := world.direct_space_state
	if space == null:
		return false
	var ai_torso: Vector3 = (ai as Node3D).global_position + Vector3(0, 1.0, 0)
	var cam_pos: Vector3 = camera.global_transform.origin
	var query := PhysicsRayQueryParameters3D.create(cam_pos, ai_torso)
	var exclusions: Array[RID] = []
	# Exclude the AI's own collision body so the ray doesn't hit it.
	if ai.has_method("get_rid"):
		exclusions.append(ai.get_rid())
	# Exclude the player's controller too — camera is inside its
	# capsule, and we don't want self-hits.
	if controller_found and is_instance_valid(controller) and controller.has_method("get_rid"):
		exclusions.append(controller.get_rid())
	query.exclude = exclusions
	# v10.5.13 — explicit flags. collision_mask = all 32 layers
	# (default, but belt-and-suspenders). collide_with_bodies = true
	# so StaticBody3D walls register. collide_with_areas = false so
	# we don't get false positives from trigger volumes (Area3D).
	query.collision_mask = 0xFFFFFFFF
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	return not hit.is_empty()


# Thermal heat level derived from AI state — kept as a legacy helper
# for the v10.5.8 2D skeleton-overlay fallback (used only when the
# shader path can't apply — e.g. AI has no MeshInstance3D). The
# primary threat display is now tint-based via _esp_thermal_tint_for.
func _esp_thermal_heat_for(ai: Node) -> float:
	if "dead" in ai and bool(ai.dead):
		return 0.25
	if "currentState" in ai and int(ai.currentState) >= AI_COMBAT_STATE_ENUM_MIN:
		return 1.0
	if "lastKnownLocation" in ai and (ai.lastKnownLocation as Vector3) != Vector3.ZERO:
		return 0.75
	return 0.55


# Resolve the AI's Skeleton3D. AI.gd declares `@export var skeleton:
# Skeleton3D` on line 21 so the fast path is a direct property read;
# the fallback walks the tree in case a future game update moves the
# skeleton to a different sub-node.
func _esp_thermal_find_skeleton(ai: Node) -> Skeleton3D:
	if not is_instance_valid(ai):
		return null
	if "skeleton" in ai:
		var s = ai.skeleton
		if s is Skeleton3D and is_instance_valid(s):
			return s as Skeleton3D
	for child in ai.find_children("*", "Skeleton3D", true, false):
		if is_instance_valid(child):
			return child as Skeleton3D
	return null


# Render the body silhouette via the live skeleton.
#
# Algorithm:
#   1. Project every bone's world position to screen space.
#   2. For each parent→child bone link, draw two stacked line
#      segments (wide/dim outer glow, narrower/bright inner core).
#      These form the "limb mass" connecting joints.
#   3. At each projected bone position draw two stacked circles
#      (outer halo + hot core). These are the joints that bulge
#      slightly brighter than the limbs, giving the silhouette a
#      subtle body-part articulation instead of a uniform stick.
#   4. If the AI has a named head PhysicalBone3D, render an extra
#      near-white blob there — canonical thermal hotspot.
#
# Radius/width scale with the projected box height so close AIs get
# thick limbs (body fills correctly) and distant AIs get thin ones.
func _esp_thermal_render_body(ctl: Control, ai: Node, skel: Skeleton3D,
		proj: Dictionary, viewport_size: Vector2, distance: float,
		heat: float, font: Font) -> void:
	var camera := _ai_resolve_camera()
	if camera == null:
		return
	var bone_count: int = skel.get_bone_count()
	if bone_count == 0:
		_esp_thermal_render_distant(ctl, ai, proj, viewport_size, distance, heat, font)
		return

	# v10.5.12 — derive the semantic tint once, then reuse for all
	# layers with varying alpha. Matches the 3D shader's tint system
	# so there's no color mismatch when shader path is unavailable.
	var tint: Color = _esp_thermal_tint_for(ai)

	# Joint/limb sizes track the AI's rendered box height so the
	# silhouette fills the body convincingly at any distance.
	var box_h: float = proj.rect.size.y
	var joint_r: float = clampf(box_h * 0.08, 2.0, 22.0)
	var limb_w: float = joint_r * 1.6

	# Project every bone once up front.
	var positions: PackedVector2Array = PackedVector2Array()
	positions.resize(bone_count)
	var valid: Array[bool] = []
	valid.resize(bone_count)
	for i in bone_count:
		var bone_pose: Transform3D = skel.get_bone_global_pose(i)
		var bone_world: Vector3 = skel.to_global(bone_pose.origin)
		var s: Vector2 = camera.unproject_position(bone_world)
		positions[i] = s
		valid[i] = _ai_vec2_is_finite(s)

	# Limb lines first (rendered UNDER joint circles).
	var limb_glow := Color(tint.r, tint.g, tint.b, 0.35)
	var limb_core := Color(tint.r, tint.g, tint.b, 0.80)
	for i in bone_count:
		if not valid[i]:
			continue
		var parent_idx: int = skel.get_bone_parent(i)
		if parent_idx < 0 or not valid[parent_idx]:
			continue
		ctl.draw_line(positions[parent_idx], positions[i], limb_glow, limb_w * 1.6)
		ctl.draw_line(positions[parent_idx], positions[i], limb_core, limb_w * 0.85)

	# Joint circles.
	var joint_halo := Color(tint.r, tint.g, tint.b, 0.45)
	var joint_hot := Color(tint.r, tint.g, tint.b, 0.92)
	for i in bone_count:
		if not valid[i]:
			continue
		ctl.draw_circle(positions[i], joint_r * 1.5, joint_halo)
		ctl.draw_circle(positions[i], joint_r * 0.75, joint_hot)

	# Head hotspot — lighten the tint toward white for a brighter
	# face-reads-as-hot spot (still hue-matched to the threat state).
	if "head" in ai and is_instance_valid(ai.head) and ai.head is Node3D:
		var head_world: Vector3 = (ai.head as Node3D).global_position
		var head_s: Vector2 = camera.unproject_position(head_world)
		if _ai_vec2_is_finite(head_s):
			var head_col := tint.lerp(Color(1.0, 1.0, 1.0, 1.0), 0.6)
			head_col.a = 0.96
			ctl.draw_circle(head_s, joint_r * 1.25, head_col)

	# Small distance pill. Only at > 30m since close-up the silhouette
	# is so clearly a person that a label feels cluttered.
	if font != null and distance > 30.0:
		var lbl_col := Color(1.0, 0.95, 0.85, 0.85)
		var lx: float = proj.rect.position.x + proj.rect.size.x + 8
		if lx + 80 > viewport_size.x:
			lx = proj.rect.position.x - 80 - 8
		ctl.draw_string(font, Vector2(lx, proj.rect.position.y + 10),
				"%dm" % int(round(distance)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, lbl_col)


# Far-range fallback — the old box-glow renderer, preserved verbatim
# because at > 200m the body silhouette collapses to a smudge and a
# cleaner box reads better.
func _esp_thermal_render_distant(ctl: Control, ai: Node, proj: Dictionary,
		viewport_size: Vector2, distance: float, heat: float, font: Font) -> void:
	var rect: Rect2 = proj.rect
	var cx: float = rect.position.x + rect.size.x * 0.5
	var cy: float = rect.position.y + rect.size.y * 0.5
	var base_w: float = rect.size.x
	var base_h: float = rect.size.y
	# v10.5.12 — use semantic tint (matches 3D shader) for the far
	# fallback so state reads consistently across the whole range.
	var tint: Color = _esp_thermal_tint_for(ai)
	for layer_idx in 6:
		var layer_f: float = float(layer_idx) / 5.0
		var grow: float = 1.0 + layer_f * 1.4
		var w: float = base_w * grow
		var h: float = base_h * grow
		var a: float = (1.0 - layer_f) * 0.18
		var col := Color(tint.r, tint.g, tint.b, a)
		ctl.draw_rect(Rect2(cx - w * 0.5, cy - h * 0.5, w, h), col, true)
	var core_col := Color(tint.r, tint.g, tint.b, 0.75)
	ctl.draw_rect(Rect2(rect.position.x + 2, rect.position.y + 2,
			max(rect.size.x - 4, 2), max(rect.size.y - 4, 2)), core_col, true)
	if font == null:
		return
	var label_x: float = rect.position.x + rect.size.x + 6
	if label_x + 120 > viewport_size.x:
		label_x = rect.position.x - 120 - 6
	ctl.draw_string(font, Vector2(label_x, rect.position.y + 10),
			_ai_display_type(ai).to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, core_col)
	ctl.draw_string(font, Vector2(label_x, rect.position.y + 24),
			"%dm" % int(round(distance)),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(core_col.r, core_col.g, core_col.b, 0.75))


# v10.5.11 — Ironbow palette (matches the 3D thermal_ramp shader
# function). Five piecewise segments going deep purple → magenta →
# red → orange → yellow → white-hot. Alpha passed separately so the
# caller can stack multiple layers for glow falloff.
#
# Segment anchors (must stay in lockstep with thermal_ramp in the
# GLSL shader string above, else AIs crossing THERMAL_BODY_MAX_DIST
# show a visible color seam).
func _esp_thermal_color(heat: float, alpha: float) -> Color:
	heat = clampf(heat, 0.0, 1.0)
	var r: float
	var g: float
	var b: float
	if heat < 0.2:
		# deep indigo → magenta
		var t: float = heat / 0.2
		r = lerp(0.08, 0.45, t)
		g = lerp(0.02, 0.08, t)
		b = lerp(0.22, 0.55, t)
	elif heat < 0.4:
		# magenta → red
		var t: float = (heat - 0.2) / 0.2
		r = lerp(0.45, 0.95, t)
		g = lerp(0.08, 0.15, t)
		b = lerp(0.55, 0.35, t)
	elif heat < 0.6:
		# red → orange
		var t: float = (heat - 0.4) / 0.2
		r = lerp(0.95, 1.00, t)
		g = lerp(0.15, 0.55, t)
		b = lerp(0.35, 0.05, t)
	elif heat < 0.8:
		# orange → yellow
		var t: float = (heat - 0.6) / 0.2
		r = 1.00
		g = lerp(0.55, 0.95, t)
		b = lerp(0.05, 0.15, t)
	else:
		# yellow → near-white
		var t: float = (heat - 0.8) / 0.2
		r = 1.00
		g = lerp(0.95, 1.00, t)
		b = lerp(0.15, 0.95, t)
	return Color(r, g, b, alpha)


# ──────────────────────────────────────────────────────────────
# THEME C — ANALOG GLITCH
# Dashed flickering outlines + VHS chromatic fringe + glitchy
# state labels. Connects hostile AIs with morse-code dash lines.
# ──────────────────────────────────────────────────────────────
func _esp_draw_glitch(ctl: Control, ai: Node, proj: Dictionary,
		viewport_size: Vector2, font: Font) -> void:
	var rect: Rect2 = proj.rect
	var base_color: Color = proj.color
	var distance: float = proj.distance
	# Frame-quantized flicker: 12 Hz binary (dash-visible vs dash-hidden).
	var t: float = Time.get_ticks_msec() / 1000.0
	var flicker_on: bool = fmod(t * 12.0, 1.0) > 0.3
	# VHS chromatic fringe: draw outline 3x at small offsets in R/G/B.
	var red_offs := Vector2(1, 0)
	var blue_offs := Vector2(-1, 0)
	var outline_col := base_color
	# Three offset outlines.
	_esp_glitch_dashed_rect(ctl,
			Rect2(rect.position + red_offs, rect.size),
			Color(1.0, 0.1, 0.1, 0.55), flicker_on)
	_esp_glitch_dashed_rect(ctl,
			Rect2(rect.position + blue_offs, rect.size),
			Color(0.1, 0.4, 1.0, 0.55), flicker_on)
	_esp_glitch_dashed_rect(ctl, rect, outline_col, flicker_on)
	# Scatter a few "static" pixels around the AI to sell the noise
	# aesthetic. Deterministic per AI instance so they don't dance
	# randomly — uses instance_id as seed.
	var rng := RandomNumberGenerator.new()
	rng.seed = int(ai.get_instance_id()) + int(t * 4.0)  # reseed 4x/sec
	for i in 5:
		var sx: float = rect.position.x + rng.randf_range(-12, rect.size.x + 12)
		var sy: float = rect.position.y + rng.randf_range(-8, rect.size.y + 8)
		var sa: float = rng.randf_range(0.15, 0.45)
		ctl.draw_rect(Rect2(sx, sy, 2, 2), Color(outline_col.r, outline_col.g, outline_col.b, sa), true)
	if font == null:
		return
	# Label with glitched state text on recent transitions. We detect
	# a transition by hashing (instance_id, state) and using current
	# time as a timer proxy — if within 300ms of a new hash, scramble.
	var state_name: String = _ai_state_name(ai)
	var label: String = _esp_glitch_maybe_scramble(state_name, ai, t)
	var label_x: float = rect.position.x + rect.size.x + 6
	if label_x + 120 > viewport_size.x:
		label_x = rect.position.x - 120 - 6
	ctl.draw_string(font, Vector2(label_x, rect.position.y + 10),
			_ai_display_type(ai).to_upper() + "@" + "%dm" % int(round(distance)),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, outline_col)
	ctl.draw_string(font, Vector2(label_x, rect.position.y + 24),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			Color(outline_col.r, outline_col.g, outline_col.b, 0.85))


# Dashed rectangle — just four dashed lines, lightly randomized gap
# phase each call so the dashes crawl slightly. flicker_on hides the
# whole rect for one frame out of every few to sell the glitch.
func _esp_glitch_dashed_rect(ctl: Control, rect: Rect2, color: Color, visible: bool) -> void:
	if not visible:
		return
	var tl := rect.position
	var tr := Vector2(rect.position.x + rect.size.x, rect.position.y)
	var bl := Vector2(rect.position.x, rect.position.y + rect.size.y)
	var br := rect.position + rect.size
	_esp_dashed_line(ctl, tl, tr, color, 1.0, 4.0, 2.0)
	_esp_dashed_line(ctl, tr, br, color, 1.0, 4.0, 2.0)
	_esp_dashed_line(ctl, br, bl, color, 1.0, 4.0, 2.0)
	_esp_dashed_line(ctl, bl, tl, color, 1.0, 4.0, 2.0)


# Scramble label text briefly on state change. Keeps a small per-AI
# "last seen state" marker via meta so the scramble triggers only on
# transitions, not every frame.
func _esp_glitch_maybe_scramble(label: String, ai: Node, t: float) -> String:
	var key: String = "_esp_glitch_prev_state"
	var prev = ai.get_meta(key, "")
	if String(prev) != label:
		ai.set_meta(key, label)
		ai.set_meta("_esp_glitch_flash_t", t)
	var flash_start: float = float(ai.get_meta("_esp_glitch_flash_t", -10.0))
	if t - flash_start < 0.3:
		# Scramble: replace each char with a random glyph for 300ms.
		var rng := RandomNumberGenerator.new()
		rng.seed = int(t * 1000.0)
		var out: String = ""
		var charset: String = "!@#$%^&*?█▓▒░#+X/\\"
		for i in label.length():
			out += charset[rng.randi_range(0, charset.length() - 1)]
		return out
	return label


# Connect hostile AIs with thin dashed lines to sell the "they're
# coordinating" paranoia vibe. Caps at N*(N-1)/2 pairs — at 10 hostile
# AIs that's 45 lines, still cheap.
func _esp_glitch_connect_hostiles(ctl: Control, agents: Array, camera: Camera3D,
		cam_origin: Vector3, cam_forward: Vector3) -> void:
	var hostiles: Array = []
	for ai in agents:
		if not is_instance_valid(ai) or not (ai is Node3D):
			continue
		if "dead" in ai and bool(ai.dead):
			continue
		if not ("currentState" in ai):
			continue
		if int(ai.currentState) < AI_COMBAT_STATE_ENUM_MIN:
			continue
		var ai_pos: Vector3 = (ai as Node3D).global_position
		if (ai_pos - cam_origin).dot(cam_forward) <= 0.0:
			continue
		var p: Vector2 = camera.unproject_position(ai_pos + Vector3(0, 1.0, 0))
		if not _ai_vec2_is_finite(p):
			continue
		hostiles.append(p)
	var col := Color(0.95, 0.25, 0.35, 0.40)
	for i in hostiles.size():
		for j in range(i + 1, hostiles.size()):
			_esp_dashed_line(ctl, hostiles[i], hostiles[j], col, 0.75, 3.0, 5.0)


# Build the per-agent info block. Kept as a small helper so the
# draw loop can focus on geometry.
func _ai_esp_label_lines(ai: Node, distance: float) -> Array[String]:
	var out: Array[String] = []
	out.append("%s · %dm" % [_ai_display_type(ai), int(round(distance))])
	# State and HP. Character.gd.boss AIs carry 300 HP; others 100.
	# We just print the raw integer — no bar — to keep the overlay
	# scannable at a glance.
	# AI.gd exposes a per-instance `health` float: boss=300, others=100.
	# (Not to be confused with Character.gd's gameData.health — that's
	# the player's HP; ai.health is the NPC's HP.)
	var state_name: String = _ai_state_name(ai)
	var hp: int = -1
	if "health" in ai:
		hp = int(round(float(ai.health)))
	if hp >= 0:
		out.append("%s · HP %d" % [state_name, hp])
	else:
		out.append(state_name)
	# Optional third line: "sees you" tag — if playerVisible is live,
	# the AI has the player in LOS right now. Super useful diagnostic
	# when paired with Invisibility to verify the hijack is working.
	if "playerVisible" in ai and bool(ai.playerVisible):
		out.append("SEES YOU")
	return out


# Map AI.State enum (0..13) to a display string. Mirrors the enum
# declared at AI.gd line ~55.
func _ai_state_name(ai: Node) -> String:
	if not ("currentState" in ai):
		return "?"
	var s: int = int(ai.currentState)
	match s:
		0: return "Idle"
		1: return "Wander"
		2: return "Guard"
		3: return "Patrol"
		4: return "Hide"
		5: return "Ambush"
		6: return "Cover"
		7: return "Defend"
		8: return "Shift"
		9: return "COMBAT"
		10: return "HUNT"
		11: return "ATTACK"
		12: return "Vantage"
		13: return "Return"
		_: return "?"


# Color-code the box by hostility. Red = actively engaging,
# orange = combat-adjacent (repositioning), yellow = alerted (has
# an LKL but not in combat), green = oblivious patrolling,
# gray = dead/invalid.
func _ai_esp_color_for(ai: Node) -> Color:
	if "dead" in ai and bool(ai.dead):
		return Color(0.45, 0.45, 0.50, 0.85)
	var s: int = 0
	if "currentState" in ai:
		s = int(ai.currentState)
	# Combat / Hunt / Attack / Vantage → red
	if s == 9 or s == 10 or s == 11 or s == 12:
		return Color(0.95, 0.20, 0.20, 0.95)
	# Cover / Defend / Shift / Return → orange (combat-adjacent)
	if s == 6 or s == 7 or s == 8 or s == 13:
		return Color(0.98, 0.55, 0.15, 0.95)
	# Alerted (has a last-known location logged) but passive state
	if "lastKnownLocation" in ai and (ai.lastKnownLocation as Vector3) != Vector3.ZERO:
		return Color(0.98, 0.90, 0.25, 0.95)
	# Default: oblivious
	return Color(0.35, 0.90, 0.45, 0.90)


# Best-effort display name for the AI type. AI scene instances are
# named after their .tscn (AI_Bandit, AI_Guard, etc.); Godot 4
# appends a trailing digit ("AI_Bandit2", "AI_Bandit3") when the
# same scene is instantiated multiple times.
#
# v10.5.2 — removed a dead "@"-suffix branch I wrote earlier under
# the false assumption that Godot 4 uses "@2" markers for duplicate
# node names. Godot 4 actually uses plain trailing digits AND
# actively sanitizes "@" out of Node.name assignments (replacing it
# with "_"). So a name like "AI_Foo@3" gets stored as "AI_Foo_3",
# which the digit-strip below turns into "AI_Foo_". The extra
# trailing-underscore strip cleans that case up. Caught by the test
# harness (_test_16_esp_display_type_strips_at_suffix).
func _ai_display_type(ai: Node) -> String:
	var n: String = ai.name
	if n.begins_with("AI_"):
		n = n.substr(3)
	# Strip trailing digits (duplicate-instance suffix).
	while n.length() > 0 and n[n.length() - 1] >= "0" and n[n.length() - 1] <= "9":
		n = n.substr(0, n.length() - 1)
	# Strip one trailing underscore — covers the Godot name-sanitization
	# case where an "@N" marker became "_N" before our digit strip.
	if n.length() > 0 and n[n.length() - 1] == "_":
		n = n.substr(0, n.length() - 1)
	# Boss variants set `boss = true` — tag that in the name.
	if "boss" in ai and bool(ai.boss):
		n += " (BOSS)"
	return n


# Active Camera3D. Godot's internal camera stack makes this an O(1)
# lookup, so we don't cache — caching would need invalidation on zone
# transition (camera tree is rebuilt) and is just extra state to break.
func _ai_resolve_camera() -> Camera3D:
	var vp := get_viewport()
	if vp == null:
		return null
	return vp.get_camera_3d()


# Vector2 finite check — Godot 4 exposes is_finite() on floats but not
# vector components directly; do it manually.
func _ai_vec2_is_finite(v: Vector2) -> bool:
	return is_finite(v.x) and is_finite(v.y)


# ──────────────────────────────────────────────────────────────
# ESP THEME PERSISTENCE (v10.5.7)
# ──────────────────────────────────────────────────────────────
func _esp_theme_load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(ESP_THEME_CFG_PATH) != OK:
		return
	var stored = cfg.get_value("esp", "theme", ESP_THEME_VOSTOK)
	if typeof(stored) == TYPE_INT and int(stored) >= 0 and int(stored) < ESP_THEME_COUNT:
		cheat_ai_esp_theme = int(stored)


func _esp_theme_save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("esp", "theme", int(cheat_ai_esp_theme))
	cfg.save(ESP_THEME_CFG_PATH)


# UI handler wired to the OptionButton in the Combat tab. `idx` comes
# from item_selected; clamp just in case. Persist immediately so the
# selection survives a crash.
func _on_esp_theme_selected(idx: int) -> void:
	if idx < 0 or idx >= ESP_THEME_COUNT:
		return
	# v10.5.17 — both THERMAL and CHAMS are shader-based themes that
	# override the AI's material. When leaving EITHER of them, run a
	# clean restoration sweep so the transition is crisp. If switching
	# between them, we also restore first — the apply path will re-
	# swap to the new theme's shader on the next tick.
	var was_shader_theme: bool = (
		cheat_ai_esp_theme == ESP_THEME_THERMAL
		or cheat_ai_esp_theme == ESP_THEME_CHAMS
	)
	var going_to_shader_theme: bool = (
		idx == ESP_THEME_THERMAL or idx == ESP_THEME_CHAMS
	)
	cheat_ai_esp_theme = idx
	_esp_theme_save_cfg()
	if was_shader_theme:
		_esp_thermal_shader_restore_all()
		_ai_esp_shader_was_active = false
	if is_instance_valid(_ai_esp_overlay):
		_ai_esp_overlay.queue_redraw()
	_show_toast("ESP theme: %s" % ESP_THEME_LABELS[idx])
