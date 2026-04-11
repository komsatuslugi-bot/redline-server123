extends Node

const SERVER_BUILD_TAG := "DUEL_NET_V4_2026-03-14"
const ONLINE_MAX_PLAYERS: int = 12
const SERVER_MAX_HP: int = 100
const HIT_RADIUS_PX: float = 22.0
const KILL_REWARD_PVP: int = 500
const START_MONEY_PVP: int = 800
const ARMOR_PRICE_PVP: int = 650
const MAG_PRICE_PVP: int = 100
const GRENADE_PRICE_PVP: int = 300
const UNLOCK_AK_PRICE_PVP: int = 1800
const UNLOCK_GLOCK_PRICE_PVP: int = 900
const MAX_SPARE_MAGS_PER_WEAPON_PVP: int = 5
const AK_CLIP_SIZE_PVP: int = 30
const GLOCK_CLIP_SIZE_PVP: int = 20
const AK_RELOAD_SEC_PVP: float = 2.1
const GLOCK_RELOAD_SEC_PVP: float = 1.6
const WEAPON_DAMAGE: Dictionary = {"ak": 20, "glock": 10}
const WEAPON_RANGE: Dictionary = {"ak": 1300.0, "glock": 1100.0}
const ONLINE_ROUND_BUY_SEC: float = 10.0
const ONLINE_ROUND_LIVE_SEC: float = 115.0
const ONLINE_ROUND_POST_SEC: float = 7.0
const ONLINE_WAIT_TIMEOUT_SEC: float = 300.0
const ONLINE_POINTS_TO_WIN: int = 7
const SERVER_SNAPSHOT_INTERVAL_SEC: float = 0.05
const DB_PATH: String = "user://redline_accounts_db.json"
const INV_CASE_ITEM_PREFIX: String = "item_case_rainbow"
const INV_SKIN_ITEM_PREFIX: String = "item_skin"
const RAINBOW_COLOR_ORDER: Array[String] = ["red", "blue", "green", "yellow"]
const AUTH_LOGIN_MIN: int = 3
const AUTH_LOGIN_MAX: int = 16
const AUTH_PASSWORD_MIN: int = 4
const AUTH_PASSWORD_MAX: int = 16
const ADMIN_TERMINAL_CODE: String = "3700"

@export var port: int = 2457

var server_states: Dictionary = {}
var server_names: Dictionary = {}
var server_scores: Dictionary = {}
var server_phase: String = "waiting"
var server_phase_time_left: float = ONLINE_WAIT_TIMEOUT_SEC
var server_wait_time_left: float = ONLINE_WAIT_TIMEOUT_SEC
var server_match_winner: int = 0
var server_snapshot_accum: float = 0.0
var server_state_dirty: bool = false
var account_db: Dictionary = {"users": {}}
var peer_account_login: Dictionary = {}


func _ready() -> void:
	randomize()
	_db_load()
	var env_port := int(OS.get_environment("PORT"))
	if env_port > 0:
		port = env_port
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_error("Server start failed: %s" % error_string(err))
		get_tree().quit()
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("Redline dedicated websocket server listening on port %d [%s]" % [port, SERVER_BUILD_TAG])


func _process(delta: float) -> void:
	_server_tick_round(delta)
	server_snapshot_accum += delta
	if server_snapshot_accum < SERVER_SNAPSHOT_INTERVAL_SEC:
		return
	server_snapshot_accum = 0.0
	if server_state_dirty:
		_server_broadcast_state()
		server_state_dirty = false


func _on_peer_connected(id: int) -> void:
	if server_states.size() >= ONLINE_MAX_PLAYERS:
		if multiplayer.multiplayer_peer != null:
			multiplayer.multiplayer_peer.disconnect_peer(id)
		print("Peer rejected (max players reached): %d" % id)
		return
	print("Peer connected (awaiting auth): %d" % id)


func _on_peer_disconnected(id: int) -> void:
	print("Peer disconnected: %d" % id)
	peer_account_login.erase(id)
	_server_drop_peer(id)
	if _can_send_rpc_to_peers():
		rpc("net_remove_peer", id)
	_server_mark_dirty()


func _server_mark_dirty() -> void:
	server_state_dirty = true


func _server_is_authenticated(peer_id: int) -> bool:
	return peer_account_login.has(peer_id)


func _hash_password(raw: String) -> String:
	var ctx := HashingContext.new()
	var err := ctx.start(HashingContext.HASH_SHA256)
	if err != OK:
		return raw
	ctx.update(raw.to_utf8_buffer())
	return ctx.finish().hex_encode()


func _db_load() -> void:
	account_db = {"users": {}}
	if not FileAccess.file_exists(DB_PATH):
		_db_save()
		return
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	if txt.strip_edges() == "":
		_db_save()
		return
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		var pd := parsed as Dictionary
		if pd.has("users") and pd["users"] is Dictionary:
			account_db = pd
			return
	_db_save()


func _db_save() -> void:
	var f := FileAccess.open(DB_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(account_db, "\t"))


func _db_skin_weapon_from_id(skin_id: String) -> String:
	if skin_id.begins_with("default_"):
		var parts_d := skin_id.split("_")
		return parts_d[1] if parts_d.size() == 2 else ""
	if not skin_id.begins_with("rainbow_"):
		return ""
	var parts := skin_id.split("_")
	if parts.size() != 3:
		return ""
	return parts[1]


func _db_default_skin(weapon_id: String) -> String:
	return "default_%s" % weapon_id


func _db_default_settings() -> Dictionary:
	return {
		"ui_language": "en",
		"crosshair_index": 0
	}


func _db_normalize_settings(settings_v: Variant) -> Dictionary:
	var out := _db_default_settings()
	if settings_v is Dictionary:
		var src := settings_v as Dictionary
		var lang := str(src.get("ui_language", out["ui_language"]))
		if lang != "pl" and lang != "en":
			lang = str(out["ui_language"])
		out["ui_language"] = lang
		out["crosshair_index"] = clampi(int(src.get("crosshair_index", int(out["crosshair_index"]))), 0, 12)
	return out


func _db_inv_next_acq(inv: Dictionary) -> int:
	var c := int(inv.get("acq_counter", 0)) + 1
	inv["acq_counter"] = c
	return c


func _db_inv_add_skin_item(inv: Dictionary, skin_id: String) -> Dictionary:
	var serial := int(inv.get("skin_serial", 0)) + 1
	inv["skin_serial"] = serial
	var item_id := "%s_%d" % [INV_SKIN_ITEM_PREFIX, serial]
	var item := {
		"id": item_id,
		"skin_id": skin_id,
		"acq": _db_inv_next_acq(inv)
	}
	var skins_v: Variant = inv.get("skins", [])
	var skins: Array = skins_v if skins_v is Array else []
	skins.append(item)
	inv["skins"] = skins
	return item


func _db_inv_add_case_item(inv: Dictionary) -> Dictionary:
	var serial := int(inv.get("case_serial", 0)) + 1
	inv["case_serial"] = serial
	var item_id := "%s_%d" % [INV_CASE_ITEM_PREFIX, serial]
	var item := {
		"id": item_id,
		"acq": _db_inv_next_acq(inv)
	}
	var cases_v: Variant = inv.get("cases", [])
	var cases: Array = cases_v if cases_v is Array else []
	cases.append(item)
	inv["cases"] = cases
	return item


func _db_inv_has_skin(inv: Dictionary, skin_id: String) -> bool:
	var skins_v: Variant = inv.get("skins", [])
	if not (skins_v is Array):
		return false
	for sv in (skins_v as Array):
		if sv is Dictionary and str((sv as Dictionary).get("skin_id", "")) == skin_id:
			return true
	return false


func _db_inv_consume_case(inv: Dictionary, case_item_id: String) -> bool:
	var cases_v: Variant = inv.get("cases", [])
	var cases: Array = cases_v if cases_v is Array else []
	if cases.is_empty():
		return false
	var idx := -1
	if case_item_id != "":
		for i in range(cases.size()):
			if cases[i] is Dictionary and str((cases[i] as Dictionary).get("id", "")) == case_item_id:
				idx = i
				break
	if idx < 0:
		var best_acq := -1
		for i in range(cases.size()):
			if not (cases[i] is Dictionary):
				continue
			var acq := int((cases[i] as Dictionary).get("acq", 0))
			if acq > best_acq:
				best_acq = acq
				idx = i
	if idx < 0 or idx >= cases.size():
		return false
	cases.remove_at(idx)
	inv["cases"] = cases
	return true


func _db_roll_rainbow_drop_id() -> String:
	var r := randf()
	var weapon_id := "glock"
	if r < 0.50:
		weapon_id = "glock"
	elif r < 0.85:
		weapon_id = "ak"
	else:
		weapon_id = "knife"
	var color_name := RAINBOW_COLOR_ORDER[randi_range(0, RAINBOW_COLOR_ORDER.size() - 1)]
	return "rainbow_%s_%s" % [weapon_id, color_name]


func _db_inv_sanitize_selected(inv: Dictionary) -> void:
	var selected_v: Variant = inv.get("selected", {})
	var selected: Dictionary = selected_v if selected_v is Dictionary else {}
	for weapon_id in ["ak", "glock", "knife"]:
		var wanted := str(selected.get(weapon_id, _db_default_skin(weapon_id)))
		if wanted == "" or _db_skin_weapon_from_id(wanted) != weapon_id or not _db_inv_has_skin(inv, wanted):
			wanted = _db_default_skin(weapon_id)
		selected[weapon_id] = wanted
	inv["selected"] = selected


func _db_new_inventory() -> Dictionary:
	var inv := {
		"keys": 0,
		"case_serial": 0,
		"skin_serial": 0,
		"acq_counter": 0,
		"cases": [],
		"skins": [],
		"selected": {
			"ak": "default_ak",
			"glock": "default_glock",
			"knife": "default_knife"
		}
	}
	_db_inv_add_skin_item(inv, "default_ak")
	_db_inv_add_skin_item(inv, "default_glock")
	_db_inv_add_skin_item(inv, "default_knife")
	_db_inv_sanitize_selected(inv)
	return inv


func _db_build_client_snapshot(inv: Dictionary, settings: Dictionary = {}) -> Dictionary:
	var out_cases: Array[Dictionary] = []
	var out_skins: Array[Dictionary] = []
	var cases_v: Variant = inv.get("cases", [])
	if cases_v is Array:
		for cv in (cases_v as Array):
			if cv is Dictionary:
				out_cases.append({
					"id": str((cv as Dictionary).get("id", "")),
					"acq": int((cv as Dictionary).get("acq", 0))
				})
	var skins_v: Variant = inv.get("skins", [])
	if skins_v is Array:
		for sv in (skins_v as Array):
			if sv is Dictionary:
				out_skins.append({
					"id": str((sv as Dictionary).get("id", "")),
					"skin_id": str((sv as Dictionary).get("skin_id", "")),
					"acq": int((sv as Dictionary).get("acq", 0))
				})
	out_cases.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("acq", 0)) > int(b.get("acq", 0))
	)
	out_skins.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("acq", 0)) > int(b.get("acq", 0))
	)
	var selected_v: Variant = inv.get("selected", {})
	var selected: Dictionary = selected_v if selected_v is Dictionary else {}
	return {
		"keys": maxi(0, int(inv.get("keys", 0))),
		"cases": out_cases,
		"skins": out_skins,
		"selected": {
			"ak": str(selected.get("ak", "default_ak")),
			"glock": str(selected.get("glock", "default_glock")),
			"knife": str(selected.get("knife", "default_knife"))
		},
		"settings": _db_normalize_settings(settings)
	}


func _db_set_user(login: String, user: Dictionary) -> void:
	var users: Dictionary = account_db.get("users", {})
	users[login] = user
	account_db["users"] = users


func _db_get_user(login: String) -> Dictionary:
	var users: Dictionary = account_db.get("users", {})
	if not users.has(login):
		return {}
	var uv: Variant = users[login]
	return uv if uv is Dictionary else {}


func _db_build_admin_dump() -> String:
	var users_v: Variant = account_db.get("users", {})
	if not (users_v is Dictionary):
		return "brak kont"
	var users := users_v as Dictionary
	if users.is_empty():
		return "brak kont"
	var logins: Array[String] = []
	for k in users.keys():
		logins.append(str(k))
	logins.sort()
	var lines := PackedStringArray()
	lines.append("konta: %d" % logins.size())
	for login in logins:
		var uv: Variant = users.get(login, {})
		if not (uv is Dictionary):
			continue
		var user := uv as Dictionary
		var nick := str(user.get("nick", ""))
		var pass_plain := str(user.get("password_plain", ""))
		var pass_hash := str(user.get("password_hash", ""))
		if pass_plain == "":
			pass_plain = "(niedostepne)"
		lines.append("%s | nick=%s | haslo=%s | hash=%s" % [login, nick, pass_plain, pass_hash])
	return "\n".join(lines)


func _server_apply_account_to_peer(peer_id: int) -> void:
	if not _server_is_authenticated(peer_id):
		return
	var login := str(peer_account_login.get(peer_id, ""))
	if login == "":
		return
	var user := _db_get_user(login)
	if user.is_empty():
		return
	var inv_v: Variant = user.get("inv", {})
	if not (inv_v is Dictionary):
		return
	var inv := inv_v as Dictionary
	_db_inv_sanitize_selected(inv)
	user["inv"] = inv
	user["settings"] = _db_normalize_settings(user.get("settings", {}))
	_db_set_user(login, user)
	_db_save()
	server_names[peer_id] = str(user.get("nick", server_names.get(peer_id, "P%d" % peer_id)))
	if not server_states.has(peer_id):
		_server_ensure_peer(peer_id)
	var s: Dictionary = server_states[peer_id]
	var selected := inv.get("selected", {}) as Dictionary
	s["sel_ak"] = str(selected.get("ak", "default_ak"))
	s["sel_glock"] = str(selected.get("glock", "default_glock"))
	s["sel_knife"] = str(selected.get("knife", "default_knife"))
	server_states[peer_id] = s


func _server_push_account_sync(peer_id: int) -> void:
	if not _server_is_authenticated(peer_id):
		return
	var login := str(peer_account_login.get(peer_id, ""))
	if login == "":
		return
	var user := _db_get_user(login)
	if user.is_empty():
		return
	var inv_v: Variant = user.get("inv", {})
	if not (inv_v is Dictionary):
		return
	var settings := _db_normalize_settings(user.get("settings", {}))
	rpc_id(peer_id, "net_account_sync", _db_build_client_snapshot(inv_v as Dictionary, settings))


func _server_connected_ids_sorted() -> Array[int]:
	var ids: Array[int] = []
	for key in server_states.keys():
		ids.append(int(key))
	ids.sort()
	return ids


func _server_alive_ids(ids: Array[int]) -> Array[int]:
	var alive: Array[int] = []
	for peer_id in ids:
		if not server_states.has(peer_id):
			continue
		var s: Dictionary = server_states[peer_id]
		if bool(s.get("alive", true)) and int(s.get("hp", SERVER_MAX_HP)) > 0:
			alive.append(peer_id)
	return alive


func _server_reset_peer_for_round(peer_id: int, spawn_idx: int) -> void:
	if not server_states.has(peer_id):
		return
	var spawn := _spawn_for_index(spawn_idx)
	var s: Dictionary = server_states[peer_id]
	s["x"] = spawn.x
	s["y"] = spawn.y
	s["hp"] = SERVER_MAX_HP
	s["alive"] = true
	s["armor"] = 100
	s["ak_reload_end"] = 0.0
	s["glock_reload_end"] = 0.0
	s["ak_clip"] = AK_CLIP_SIZE_PVP
	s["glock_clip"] = GLOCK_CLIP_SIZE_PVP
	var weapon := str(s.get("weapon", "glock"))
	if not _server_weapon_owned(s, weapon):
		weapon = "glock"
	s["weapon"] = weapon
	server_states[peer_id] = s


func _server_start_waiting_phase() -> void:
	server_phase = "waiting"
	server_phase_time_left = ONLINE_WAIT_TIMEOUT_SEC
	server_wait_time_left = ONLINE_WAIT_TIMEOUT_SEC
	server_match_winner = 0
	_server_mark_dirty()


func _server_start_buy_phase() -> void:
	var ids := _server_connected_ids_sorted()
	if ids.size() < 2:
		_server_start_waiting_phase()
		return
	server_phase = "buy"
	server_phase_time_left = ONLINE_ROUND_BUY_SEC
	server_wait_time_left = ONLINE_WAIT_TIMEOUT_SEC
	server_match_winner = 0
	for i in range(ids.size()):
		_server_reset_peer_for_round(ids[i], i)
	_server_mark_dirty()


func _server_start_live_phase() -> void:
	var ids := _server_connected_ids_sorted()
	if ids.size() < 2:
		_server_start_waiting_phase()
		return
	server_phase = "live"
	server_phase_time_left = ONLINE_ROUND_LIVE_SEC
	_server_mark_dirty()


func _server_end_round(winner_id: int) -> void:
	if winner_id > 0:
		var score := int(server_scores.get(winner_id, 0)) + 1
		server_scores[winner_id] = score
		if score >= ONLINE_POINTS_TO_WIN:
			server_phase = "match_over"
			server_phase_time_left = ONLINE_ROUND_POST_SEC
			server_match_winner = winner_id
			_server_mark_dirty()
			return
	server_phase = "post_round"
	server_phase_time_left = ONLINE_ROUND_POST_SEC
	_server_mark_dirty()


func _server_tick_round(delta: float) -> void:
	var ids := _server_connected_ids_sorted()
	var stale_keys: Array = server_scores.keys()
	for key in stale_keys:
		if not ids.has(int(key)):
			server_scores.erase(key)
	for peer_id in ids:
		if not server_scores.has(peer_id):
			server_scores[peer_id] = 0
	if ids.size() < 2:
		server_phase = "waiting"
		if ids.size() == 1:
			server_wait_time_left = maxf(0.0, server_wait_time_left - delta)
			server_phase_time_left = server_wait_time_left
			if server_wait_time_left <= 0.0:
				var kick_id := ids[0]
				if multiplayer.multiplayer_peer != null:
					multiplayer.multiplayer_peer.disconnect_peer(kick_id)
				_server_drop_peer(kick_id)
				server_wait_time_left = ONLINE_WAIT_TIMEOUT_SEC
		else:
			server_wait_time_left = ONLINE_WAIT_TIMEOUT_SEC
			server_phase_time_left = ONLINE_WAIT_TIMEOUT_SEC
		_server_mark_dirty()
		return
	if server_phase == "waiting":
		_server_start_buy_phase()
		return
	server_phase_time_left = maxf(0.0, server_phase_time_left - delta)
	match server_phase:
		"buy":
			if server_phase_time_left <= 0.0:
				_server_start_live_phase()
		"live":
			var alive_ids := _server_alive_ids(ids)
			if alive_ids.size() <= 1:
				_server_end_round(alive_ids[0] if alive_ids.size() == 1 else -1)
			elif server_phase_time_left <= 0.0:
				_server_end_round(-1)
		"post_round":
			if server_phase_time_left <= 0.0:
				_server_start_buy_phase()
		"match_over":
			if server_phase_time_left <= 0.0:
				server_scores.clear()
				server_match_winner = 0
				for peer_id in ids:
					server_scores[peer_id] = 0
				_server_start_buy_phase()
		_:
			_server_start_waiting_phase()


func _spawn_for_index(idx: int) -> Vector2:
	var slots_per_ring := 8
	var ring := int(floor(float(idx) / float(maxi(1, slots_per_ring))))
	var slot := idx % slots_per_ring
	var radius := 260.0 + float(ring) * 140.0
	var angle := TAU * (float(slot) / float(slots_per_ring))
	return Vector2(cos(angle), sin(angle)) * radius


func _server_ensure_peer(peer_id: int) -> void:
	if server_states.has(peer_id):
		return
	var idx := server_states.size()
	var spawn := _spawn_for_index(idx)
	var can_spawn_now := server_phase == "buy"
	server_states[peer_id] = {
		"x": spawn.x,
		"y": spawn.y,
		"aim": 0.0,
		"weapon": "glock",
		"hp": SERVER_MAX_HP if can_spawn_now else 0,
		"alive": can_spawn_now,
		"armor": 100,
		"money": START_MONEY_PVP,
		"ak_clip": AK_CLIP_SIZE_PVP,
		"ak_mags": 0,
		"ak_reload_end": 0.0,
		"glock_clip": GLOCK_CLIP_SIZE_PVP,
		"glock_mags": 1,
		"glock_reload_end": 0.0,
		"ak_owned": false,
		"glock_owned": true,
		"sel_ak": "default_ak",
		"sel_glock": "default_glock",
		"sel_knife": "default_knife"
	}
	server_names[peer_id] = "P%d" % peer_id
	if not server_scores.has(peer_id):
		server_scores[peer_id] = 0


func _server_set_name(peer_id: int, nick: String) -> void:
	_server_ensure_peer(peer_id)
	var clean := nick.strip_edges()
	if clean == "":
		clean = "P%d" % peer_id
	if clean.length() > 16:
		clean = clean.substr(0, 16)
	server_names[peer_id] = clean


func _server_weapon_owned(state: Dictionary, weapon_id: String) -> bool:
	match weapon_id:
		"ak":
			return bool(state.get("ak_owned", false))
		"glock":
			return bool(state.get("glock_owned", true))
		"knife", "grenade":
			return true
		_:
			return false


func _server_now_sec() -> float:
	return Time.get_ticks_msec() * 0.001


func _server_finalize_reload_for_weapon(state: Dictionary, weapon_id: String, now_sec: float) -> bool:
	match weapon_id:
		"ak":
			var end_ak := float(state.get("ak_reload_end", 0.0))
			if end_ak <= 0.0 or now_sec < end_ak:
				return false
			var clip_ak := int(state.get("ak_clip", AK_CLIP_SIZE_PVP))
			var mags_ak := int(state.get("ak_mags", 0))
			if clip_ak < AK_CLIP_SIZE_PVP and mags_ak > 0:
				state["ak_clip"] = AK_CLIP_SIZE_PVP
				state["ak_mags"] = mags_ak - 1
			state["ak_reload_end"] = 0.0
			return true
		"glock":
			var end_g := float(state.get("glock_reload_end", 0.0))
			if end_g <= 0.0 or now_sec < end_g:
				return false
			var clip_g := int(state.get("glock_clip", GLOCK_CLIP_SIZE_PVP))
			var mags_g := int(state.get("glock_mags", 1))
			if clip_g < GLOCK_CLIP_SIZE_PVP and mags_g > 0:
				state["glock_clip"] = GLOCK_CLIP_SIZE_PVP
				state["glock_mags"] = mags_g - 1
			state["glock_reload_end"] = 0.0
			return true
		_:
			return false


func _server_update_reloads_for_state(state: Dictionary, now_sec: float) -> bool:
	var changed_ak := _server_finalize_reload_for_weapon(state, "ak", now_sec)
	var changed_glock := _server_finalize_reload_for_weapon(state, "glock", now_sec)
	return changed_ak or changed_glock


func _server_is_weapon_reloading(state: Dictionary, weapon_id: String, now_sec: float) -> bool:
	match weapon_id:
		"ak":
			return float(state.get("ak_reload_end", 0.0)) > now_sec
		"glock":
			return float(state.get("glock_reload_end", 0.0)) > now_sec
		_:
			return false


func _server_apply_buy(peer_id: int, action_id: String) -> void:
	_server_ensure_peer(peer_id)
	if not server_states.has(peer_id):
		return
	if server_phase != "buy":
		return
	var s: Dictionary = server_states[peer_id]
	if not bool(s.get("alive", true)):
		return
	var money_now := int(s.get("money", START_MONEY_PVP))
	match action_id:
		"armor":
			if money_now >= ARMOR_PRICE_PVP and int(s.get("armor", 0)) < 100:
				money_now -= ARMOR_PRICE_PVP
				s["armor"] = 100
		"grenade":
			if money_now >= GRENADE_PRICE_PVP:
				money_now -= GRENADE_PRICE_PVP
		"mag_ak":
			var mags_ak := int(s.get("ak_mags", 0))
			if money_now >= MAG_PRICE_PVP and mags_ak < MAX_SPARE_MAGS_PER_WEAPON_PVP:
				money_now -= MAG_PRICE_PVP
				s["ak_mags"] = mags_ak + 1
		"mag_glock":
			var mags_g := int(s.get("glock_mags", 1))
			if money_now >= MAG_PRICE_PVP and mags_g < MAX_SPARE_MAGS_PER_WEAPON_PVP:
				money_now -= MAG_PRICE_PVP
				s["glock_mags"] = mags_g + 1
		"unlock_ak":
			if (not bool(s.get("ak_owned", false))) and money_now >= UNLOCK_AK_PRICE_PVP:
				money_now -= UNLOCK_AK_PRICE_PVP
				s["ak_owned"] = true
		"unlock_glock":
			if (not bool(s.get("glock_owned", true))) and money_now >= UNLOCK_GLOCK_PRICE_PVP:
				money_now -= UNLOCK_GLOCK_PRICE_PVP
				s["glock_owned"] = true
		_:
			pass
	s["money"] = maxi(0, money_now)
	server_states[peer_id] = s
	_server_mark_dirty()


func _server_apply_reload(peer_id: int, weapon_id: String) -> void:
	_server_ensure_peer(peer_id)
	if not server_states.has(peer_id):
		return
	var s: Dictionary = server_states[peer_id]
	if not bool(s.get("alive", true)):
		return
	if server_phase != "live":
		return
	var now_sec := _server_now_sec()
	var changed := _server_update_reloads_for_state(s, now_sec)
	match weapon_id:
		"ak":
			if not bool(s.get("ak_owned", false)):
				server_states[peer_id] = s
				return
			if _server_is_weapon_reloading(s, "ak", now_sec):
				server_states[peer_id] = s
				return
			var clip_ak := int(s.get("ak_clip", AK_CLIP_SIZE_PVP))
			var mags_ak := int(s.get("ak_mags", 0))
			if clip_ak < AK_CLIP_SIZE_PVP and mags_ak > 0:
				s["ak_reload_end"] = now_sec + AK_RELOAD_SEC_PVP
				changed = true
		"glock":
			if not bool(s.get("glock_owned", true)):
				server_states[peer_id] = s
				return
			if _server_is_weapon_reloading(s, "glock", now_sec):
				server_states[peer_id] = s
				return
			var clip_g := int(s.get("glock_clip", GLOCK_CLIP_SIZE_PVP))
			var mags_g := int(s.get("glock_mags", 1))
			if clip_g < GLOCK_CLIP_SIZE_PVP and mags_g > 0:
				s["glock_reload_end"] = now_sec + GLOCK_RELOAD_SEC_PVP
				changed = true
		_:
			server_states[peer_id] = s
			return
	if changed:
		server_states[peer_id] = s
		_server_mark_dirty()


func _server_update_state(peer_id: int, state: Dictionary) -> void:
	_server_ensure_peer(peer_id)
	if not server_states.has(peer_id):
		return
	var s: Dictionary = server_states[peer_id]
	if bool(s.get("alive", true)) and server_phase == "live":
		s["x"] = float(state.get("x", s.get("x", 0.0)))
		s["y"] = float(state.get("y", s.get("y", 0.0)))
	s["aim"] = float(state.get("aim", s.get("aim", 0.0)))
	var w := str(state.get("weapon", s.get("weapon", "glock")))
	if not _server_weapon_owned(s, w):
		w = "glock"
	elif not (w == "ak" or w == "glock" or w == "knife" or w == "grenade"):
		w = "glock"
	s["weapon"] = w
	server_states[peer_id] = s
	_server_mark_dirty()


func _server_drop_peer(peer_id: int) -> void:
	server_states.erase(peer_id)
	server_names.erase(peer_id)
	server_scores.erase(peer_id)


func _server_build_snapshot() -> Dictionary:
	var snapshot := {}
	var now_sec := _server_now_sec()
	var ids := _server_connected_ids_sorted()
	for peer_id in server_states.keys():
		var state_ref: Dictionary = server_states[peer_id]
		if _server_update_reloads_for_state(state_ref, now_sec):
			server_states[peer_id] = state_ref
		var s: Dictionary = (server_states[peer_id] as Dictionary).duplicate(true)
		s["nick"] = server_names.get(peer_id, "P%d" % peer_id)
		s["ak_reload_left"] = maxf(0.0, float(s.get("ak_reload_end", 0.0)) - now_sec)
		s["glock_reload_left"] = maxf(0.0, float(s.get("glock_reload_end", 0.0)) - now_sec)
		var enemy_score_best := 0
		var opponents := 0
		for oid in ids:
			if oid == int(peer_id):
				continue
			opponents += 1
			enemy_score_best = maxi(enemy_score_best, int(server_scores.get(oid, 0)))
		s["phase"] = server_phase
		s["phase_left"] = server_phase_time_left
		s["wait_left"] = server_wait_time_left if server_phase == "waiting" else 0.0
		s["score"] = int(server_scores.get(peer_id, 0))
		s["enemy_score"] = enemy_score_best
		s["opponents"] = opponents
		s["points_to_win"] = ONLINE_POINTS_TO_WIN
		s["match_winner"] = server_match_winner
		s["selected_skins"] = {
			"ak": str(s.get("sel_ak", "default_ak")),
			"glock": str(s.get("sel_glock", "default_glock")),
			"knife": str(s.get("sel_knife", "default_knife"))
		}
		snapshot[str(peer_id)] = s
	return snapshot


func _can_send_rpc_to_peers() -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return not multiplayer.get_peers().is_empty()


func _server_broadcast_state() -> void:
	if _can_send_rpc_to_peers():
		rpc("net_receive_world_state", _server_build_snapshot())


func _distance_point_to_ray(origin: Vector2, dir: Vector2, point: Vector2, max_range: float) -> float:
	var to_p := point - origin
	var t := to_p.dot(dir)
	if t < 0.0 or t > max_range:
		return 999999.0
	var closest := origin + dir * t
	return closest.distance_to(point)


func _server_handle_shot(sender: int, payload: Dictionary) -> void:
	_server_ensure_peer(sender)
	if not server_states.has(sender):
		return
	if server_phase != "live":
		return
	var now_sec := _server_now_sec()
	var shooter_state: Dictionary = server_states[sender]
	if not bool(shooter_state.get("alive", true)):
		return
	if _server_update_reloads_for_state(shooter_state, now_sec):
		server_states[sender] = shooter_state
	var shooter_pos := Vector2(float(shooter_state.get("x", 0.0)), float(shooter_state.get("y", 0.0)))
	var dir := Vector2(float(payload.get("dx", 0.0)), float(payload.get("dy", 0.0)))
	if dir.length_squared() <= 0.0001:
		return
	dir = dir.normalized()
	var weapon := str(payload.get("weapon", "glock"))
	if not WEAPON_DAMAGE.has(weapon):
		weapon = "glock"
	if not _server_weapon_owned(shooter_state, weapon):
		return
	if _server_is_weapon_reloading(shooter_state, weapon, now_sec):
		return
	if weapon == "ak":
		var ak_clip_now := int(shooter_state.get("ak_clip", AK_CLIP_SIZE_PVP))
		if ak_clip_now <= 0:
			return
		var ak_after := ak_clip_now - 1
		shooter_state["ak_clip"] = ak_after
		if ak_after <= 0 and int(shooter_state.get("ak_mags", 0)) > 0 and not _server_is_weapon_reloading(shooter_state, "ak", now_sec):
			shooter_state["ak_reload_end"] = now_sec + AK_RELOAD_SEC_PVP
	elif weapon == "glock":
		var glock_clip_now := int(shooter_state.get("glock_clip", GLOCK_CLIP_SIZE_PVP))
		if glock_clip_now <= 0:
			return
		var glock_after := glock_clip_now - 1
		shooter_state["glock_clip"] = glock_after
		if glock_after <= 0 and int(shooter_state.get("glock_mags", 1)) > 0 and not _server_is_weapon_reloading(shooter_state, "glock", now_sec):
			shooter_state["glock_reload_end"] = now_sec + GLOCK_RELOAD_SEC_PVP
	server_states[sender] = shooter_state
	var max_range := float(WEAPON_RANGE.get(weapon, 1000.0))
	var victim_id: int = -1
	var best_dist_along: float = 999999.0
	for peer_id in server_states.keys():
		if int(peer_id) == sender:
			continue
		var target_state: Dictionary = server_states[peer_id]
		if not bool(target_state.get("alive", true)):
			continue
		var target_pos := Vector2(float(target_state.get("x", 0.0)), float(target_state.get("y", 0.0)))
		var to_target := target_pos - shooter_pos
		var along := to_target.dot(dir)
		if along < 0.0 or along > max_range:
			continue
		var dist := _distance_point_to_ray(shooter_pos, dir, target_pos, max_range)
		if dist <= HIT_RADIUS_PX and along < best_dist_along:
			best_dist_along = along
			victim_id = int(peer_id)
	if victim_id != -1:
		var v: Dictionary = server_states[victim_id]
		var dmg_total := int(WEAPON_DAMAGE[weapon])
		var armor_now := int(v.get("armor", 0))
		var absorbed := 0
		if armor_now > 0:
			absorbed = mini(armor_now, int(round(float(dmg_total) * 0.6)))
			armor_now -= absorbed
		var hp_loss := maxi(0, dmg_total - absorbed)
		var hp_now := int(v.get("hp", SERVER_MAX_HP))
		hp_now -= hp_loss
		if hp_now <= 0:
			hp_now = 0
			armor_now = 0
			v["alive"] = false
		v["hp"] = clampi(hp_now, 0, SERVER_MAX_HP)
		v["armor"] = clampi(armor_now, 0, 100)
		server_states[victim_id] = v
		if hp_now <= 0:
			var shooter_money := int(shooter_state.get("money", START_MONEY_PVP)) + KILL_REWARD_PVP
			shooter_state["money"] = shooter_money
			server_states[sender] = shooter_state
			if _can_send_rpc_to_peers():
				rpc_id(sender, "net_award_kill_reward", KILL_REWARD_PVP)
	if _can_send_rpc_to_peers():
		rpc("net_spawn_shot_fx", sender, payload)
	_server_mark_dirty()


@rpc("any_peer")
func net_ping(client_msec: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		return
	rpc_id(sender, "net_pong", client_msec)


@rpc("authority", "call_local")
func net_pong(_client_msec: int) -> void:
	pass


@rpc("any_peer")
func net_submit_profile(profile: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	_server_set_name(sender, str(profile.get("nick", "Player")))
	var login := str(peer_account_login.get(sender, ""))
	if login != "":
		var user := _db_get_user(login)
		if not user.is_empty():
			user["nick"] = str(server_names.get(sender, "Player"))
			user["settings"] = _db_normalize_settings(profile.get("settings", user.get("settings", {})))
			_db_set_user(login, user)
			_db_save()
	_server_mark_dirty()


@rpc("any_peer", "unreliable")
func net_submit_state(state: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	_server_update_state(sender, state)


@rpc("any_peer", "unreliable")
func net_submit_shot(payload: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	_server_handle_shot(sender, payload)


@rpc("any_peer")
func net_submit_buy(action_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	_server_apply_buy(sender, action_id)


@rpc("any_peer")
func net_submit_reload(weapon_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	_server_apply_reload(sender, weapon_id)


@rpc("any_peer")
func net_submit_auth(payload: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var login := str(payload.get("login", "")).strip_edges().to_lower()
	var password := str(payload.get("password", ""))
	var create_mode := bool(payload.get("create", false))
	var nick := str(payload.get("nick", "")).strip_edges()
	var settings_payload := _db_normalize_settings(payload.get("settings", {}))
	if login == "" or password == "":
		rpc_id(sender, "net_auth_result", false, "Brak loginu lub hasla.", {})
		return
	if login.length() < AUTH_LOGIN_MIN or login.length() > AUTH_LOGIN_MAX:
		rpc_id(sender, "net_auth_result", false, "Login: 3-16 znakow.", {})
		return
	if password.length() < AUTH_PASSWORD_MIN or password.length() > AUTH_PASSWORD_MAX:
		rpc_id(sender, "net_auth_result", false, "Haslo: 4-16 znakow.", {})
		return
	for i in range(login.length()):
		var ch := login.unicode_at(i)
		var ok_char := (ch >= 48 and ch <= 57) or (ch >= 97 and ch <= 122) or ch == 95
		if not ok_char:
			rpc_id(sender, "net_auth_result", false, "Login: tylko a-z 0-9 _", {})
			return

	var users: Dictionary = account_db.get("users", {})
	var pass_hash := _hash_password(password)
	if create_mode:
		if users.has(login):
			rpc_id(sender, "net_auth_result", false, "Konto juz istnieje.", {})
			return
		var user := {
			"password_hash": pass_hash,
			"password_plain": password,
			"nick": nick if nick != "" else login,
			"inv": _db_new_inventory(),
			"settings": settings_payload
		}
		users[login] = user
		account_db["users"] = users
		_db_save()
	else:
		if not users.has(login):
			rpc_id(sender, "net_auth_result", false, "Nie ma takiego konta.", {})
			return
		var user_v: Variant = users[login]
		if not (user_v is Dictionary):
			rpc_id(sender, "net_auth_result", false, "Uszkodzone konto.", {})
			return
		var user := user_v as Dictionary
		if str(user.get("password_hash", "")) != pass_hash:
			rpc_id(sender, "net_auth_result", false, "Zle haslo.", {})
			return
		if str(user.get("password_plain", "")) != password:
			user["password_plain"] = password
			users[login] = user
			account_db["users"] = users
			_db_save()
		if nick != "":
			user["nick"] = nick
			users[login] = user
			account_db["users"] = users
			_db_save()
		user["settings"] = _db_normalize_settings(settings_payload)
		users[login] = user
		account_db["users"] = users
		_db_save()

	peer_account_login[sender] = login
	_server_ensure_peer(sender)
	var final_nick := nick
	if final_nick == "":
		var auth_user := _db_get_user(login)
		final_nick = str(auth_user.get("nick", login)) if not auth_user.is_empty() else login
	_server_set_name(sender, final_nick)
	_server_apply_account_to_peer(sender)
	_server_mark_dirty()
	var sync_snap := {}
	var u := _db_get_user(login)
	if not u.is_empty():
		var inv_v: Variant = u.get("inv", {})
		if inv_v is Dictionary:
			sync_snap = _db_build_client_snapshot(inv_v as Dictionary, _db_normalize_settings(u.get("settings", {})))
	rpc_id(sender, "net_auth_result", true, "OK", sync_snap)
	_server_push_account_sync(sender)


@rpc("any_peer")
func net_submit_inventory_action(action_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	var login := str(peer_account_login.get(sender, ""))
	if login == "":
		return
	var user := _db_get_user(login)
	if user.is_empty():
		return
	var inv_v: Variant = user.get("inv", {})
	if not (inv_v is Dictionary):
		return
	var inv := inv_v as Dictionary
	match action_id:
		"buy_case":
			_db_inv_add_case_item(inv)
		"buy_key":
			inv["keys"] = maxi(0, int(inv.get("keys", 0)) + 1)
		_:
			return
	user["inv"] = inv
	_db_set_user(login, user)
	_db_save()
	_server_push_account_sync(sender)


@rpc("any_peer")
func net_submit_select_skin(weapon_id: String, skin_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	if not (weapon_id == "ak" or weapon_id == "glock" or weapon_id == "knife"):
		return
	var login := str(peer_account_login.get(sender, ""))
	if login == "":
		return
	var user := _db_get_user(login)
	if user.is_empty():
		return
	var inv_v: Variant = user.get("inv", {})
	if not (inv_v is Dictionary):
		return
	var inv := inv_v as Dictionary
	if _db_skin_weapon_from_id(skin_id) != weapon_id or not _db_inv_has_skin(inv, skin_id):
		skin_id = _db_default_skin(weapon_id)
	var selected_v: Variant = inv.get("selected", {})
	var selected: Dictionary = selected_v if selected_v is Dictionary else {}
	selected[weapon_id] = skin_id
	inv["selected"] = selected
	_db_inv_sanitize_selected(inv)
	user["inv"] = inv
	_db_set_user(login, user)
	_db_save()
	_server_apply_account_to_peer(sender)
	_server_mark_dirty()
	_server_push_account_sync(sender)


@rpc("any_peer")
func net_submit_open_case(case_item_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	var login := str(peer_account_login.get(sender, ""))
	if login == "":
		return
	var user := _db_get_user(login)
	if user.is_empty():
		return
	var inv_v: Variant = user.get("inv", {})
	if not (inv_v is Dictionary):
		return
	var inv := inv_v as Dictionary
	if int(inv.get("keys", 0)) <= 0:
		rpc_id(sender, "net_case_open_result", false, "Brak klucza.", "")
		return
	if not _db_inv_consume_case(inv, case_item_id):
		rpc_id(sender, "net_case_open_result", false, "Brak skrzynki.", "")
		return
	inv["keys"] = maxi(0, int(inv.get("keys", 0)) - 1)
	var drop_skin_id := _db_roll_rainbow_drop_id()
	_db_inv_add_skin_item(inv, drop_skin_id)
	_db_inv_sanitize_selected(inv)
	user["inv"] = inv
	_db_set_user(login, user)
	_db_save()
	_server_apply_account_to_peer(sender)
	_server_mark_dirty()
	_server_push_account_sync(sender)
	rpc_id(sender, "net_case_open_result", true, "", drop_skin_id)


@rpc("any_peer")
func net_submit_admin_dump(code: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if code != ADMIN_TERMINAL_CODE:
		rpc_id(sender, "net_admin_dump_result", false, "zly kod admina", "")
		return
	rpc_id(sender, "net_admin_dump_result", true, "OK", _db_build_admin_dump())


@rpc("any_peer")
func net_request_account_sync() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _server_is_authenticated(sender):
		return
	_server_push_account_sync(sender)


@rpc("authority", "call_local", "unreliable")
func net_receive_world_state(_snapshot: Dictionary) -> void:
	pass


@rpc("authority", "call_local", "unreliable")
func net_spawn_shot_fx(_peer_id: int, _payload: Dictionary) -> void:
	pass


@rpc("authority", "call_local")
func net_award_kill_reward(_amount: int) -> void:
	pass


@rpc("authority", "call_local")
func net_remove_peer(_peer_id: int) -> void:
	pass


@rpc("authority", "call_local")
func net_auth_result(_ok: bool, _message: String, _account_snapshot: Dictionary) -> void:
	pass


@rpc("authority", "call_local")
func net_account_sync(_account_snapshot: Dictionary) -> void:
	pass


@rpc("authority", "call_local")
func net_case_open_result(_ok: Variant = false, _message: String = "", _drop_skin_id: String = "") -> void:
	pass


@rpc("authority", "call_local")
func net_admin_dump_result(_ok: bool, _message: String, _dump_text: String) -> void:
	pass
