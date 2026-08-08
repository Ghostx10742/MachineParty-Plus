extends Node

# =============================================================================
#  MachineParty+ v1.5.0 - server browser + voice + chat for Machine Party
#  Created by J_axon and Krunk (equal creators). Built for the Machine Party
#  Mod Loader (MPML) by Krunk-theduck.
# -----------------------------------------------------------------------------
#  MPML loads mods as loose folders and gives each a `loader`. The party-finder
#  half lives in this one file (inner classes) and integrates by WATCHING the
#  scene tree at runtime (no script overrides), so class_name game scripts
#  (MainMenu) are no problem. The chat half (chat_manager.gd + chat_hud.gd) is
#  compiled from sibling files and booted from _mod_ready.
#
#  Features:
#    * Main-menu JOIN -> global public server browser (refresh, join, room code)
#    * Host "Make Lobby Public" toggle with lobby name, max players (<=4) and an
#      "Allow mid joining" option
#    * "Manage Players" for everyone: per-player mute + volume; host also gets
#      Kick / Ban
#    * Persistent Steam-ID ban list (auto-kicks banned players from your lobbies)
#    * Main-menu "Banned Users" -> view / unban
#    * Integrated voice chat (top-right mute / deafen, in-lobby device settings)
#    * Integrated text chat (top-left, press T) - merged from Krunk's Chat mod
#    * Mid-join off  => lobby leaves the browser once the match starts or it is
#      full, and returns (on refresh) when a slot opens
#
#  Does not change base networking. Vanilla players can still join by room code.
# =============================================================================

const MOD_ID := "machineparty_plus"

# Steam lobby-data keys owned by this mod
const KEY_PUB := "mpsb_pub"
const KEY_NAME := "mpsb_name"
const KEY_MAX := "mpsb_max"
const KEY_VER := "mpsb_ver"
const KEY_HOST := "mpsb_host"
const KEY_JOIN := "mpsb_join"     # "1" only while joinable (public, not full, lobby/mid-join)
const KEY_MID := "mpsb_mid"       # "1" if mid-join allowed
const KEY_STATE := "mpsb_state"   # "lobby" | "ingame"
const KEY_COUNT := "mpsb_count"
const KEY_BANS := "mpsb_bans"     # comma-joined banned steam ids (hides lobby from them)

const MAX_PLAYERS_CAP := 4
const MIN_PLAYERS := 1

const MAIN_MENU_PATH := "res://scenes/main_menu/scripts/main_menu.gd"
const LOBBY_SCENE_PATH := "res://scenes/lobby/scripts/lobby_scene.gd"
const LOBBY_TSCN := "res://scenes/lobby/lobby_scene.tscn"
const BANS_PATH := "user://partyfinder_bans.json"

signal lobbies_refreshed(lobbies)
signal publish_state_changed(is_public)
signal players_changed()

var _loader
var _bans: Dictionary = {}          # steam_id(String) -> display name(String)
var _pending_refresh := false
var _nm_connected := false
var _browser = null
var _voice = null                   # VoiceChat engine
var _match = null                   # MatchScore tracker (scoreboard)
var _kick_leaving := false          # guard so we only self-leave once
var _leaving := {}                  # net_id -> true while a removal is in flight (debounce)
var _case_style := "title"          # how native menu buttons are cased (upper/lower/title)
var _current_lobby = null           # weak ref to the live lobby scene (for popup checks)
var _pause_btn_added := false       # our buttons injected into the pause (Esc) menu
var _lobby_tools = null             # the corner strip node (rebuilt per lobby)
var _menu_btns := []                # [ [button, base_label], ... ] for re-localizing
var _locale_hooked := false         # connected to Globals.locale_changed yet
var _chat_hud = null                # the merged chat HUD (re-localized on lang change)
var _scoreboard = null              # the mutation scoreboard HUD (re-localized too)


# ------------------------------------------------------------------ lifecycle

func _mod_init(loader) -> void:
	_loader = loader


func _mod_ready(loader) -> void:
	_loader = loader
	_load_bans()
	_load_i18n(loader.dir_of(MOD_ID).path_join("mod_i18n.json"))
	if not Steam.lobby_match_list.is_connected(_on_lobby_match_list):
		Steam.lobby_match_list.connect(_on_lobby_match_list)
	get_tree().node_added.connect(_on_node_added)
	# catch anything already in the tree
	call_deferred("_scan_tree", get_tree().root)
	# periodically keep our public lobby's browser visibility in sync
	var t := Timer.new()
	t.wait_time = 2.0
	t.autostart = true
	t.timeout.connect(_update_joinable)
	add_child(t)
	# voice chat engine + top-right HUD (mute / deafen / settings)
	_voice = VoiceChat.new()
	_voice.mod = self
	_voice.name = "MPSB_Voice"
	add_child(_voice)
	var hud = VoiceHUD.new()
	hud.mod = self
	hud.name = "MPSB_VoiceHUD"
	get_tree().root.add_child.call_deferred(hud)
	# integrated text chat (merged from Krunk's Chat mod) - top-left, press T
	_boot_chat(loader)
	# in-match mutation scoreboard (hold Tab)
	_match = MatchScore.new()
	_match.mod = self
	_match.name = "MPSB_MatchScore"
	add_child(_match)
	var sb = ScoreboardHUD.new()
	sb.mod = self
	sb.name = "MPSB_Scoreboard"
	_scoreboard = sb
	get_tree().root.add_child.call_deferred(sb)
	# sleek host tools shown in-lobby (Banned Users always; Manage Players when a
	# custom game crowds the native row)
	var tools = LobbyTools.new()
	tools.mod = self
	tools.name = "MPSB_LobbyTools"
	_lobby_tools = tools
	get_tree().root.add_child.call_deferred(tools)
	# Arabic translation (OFF by default - just adds العربية to the language menu)
	var arabic = Arabic.new()
	arabic.mod = self
	arabic.name = "MPSB_Arabic"
	arabic.ar_json_path = loader.dir_of(MOD_ID).path_join("ar.json")
	add_child(arabic)
	# Lithuanian translation (OFF by default - just adds Lietuvių to the language menu)
	var lithuanian = Lithuanian.new()
	lithuanian.mod = self
	lithuanian.name = "MPSB_Lithuanian"
	lithuanian.lt_json_path = loader.dir_of(MOD_ID).path_join("lt.json")
	add_child(lithuanian)
	# Serbian translation (OFF by default - adds Српски + Srpski to the language menu)
	var serbian = Serbian.new()
	serbian.mod = self
	serbian.name = "MPSB_Serbian"
	serbian.sr_json_path = loader.dir_of(MOD_ID).path_join("sr.json")
	add_child(serbian)
	loader.note("MachineParty+ v1.5.0 ready")


func match_score():
	return _match


# Compile + spawn the chat manager/HUD from sibling files (they aren't on res://,
# so we load them by absolute path the way MPML intends).
func _boot_chat(loader) -> void:
	var dir: String = loader.dir_of(MOD_ID)
	if dir.is_empty():
		loader.note("chat: could not resolve mod dir")
		return
	var manager_script = loader.compile(dir.path_join("chat_manager.gd"))
	var hud_script = loader.compile(dir.path_join("chat_hud.gd"))
	if manager_script == null or hud_script == null:
		loader.note("chat: failed to compile scripts")
		return
	var manager := Node.new()
	manager.set_script(manager_script)
	manager.name = "ChatManager"
	get_tree().root.add_child.call_deferred(manager)
	var chat_hud = hud_script.new()
	chat_hud.name = "ChatHud"
	chat_hud.chat_manager = manager
	chat_hud.mp_mod = self          # so chat can follow the game language too
	_chat_hud = chat_hud
	get_tree().root.add_child.call_deferred(chat_hud)
	loader.note("chat ready (merged)")


func voice():
	return _voice


# steam ids of the OTHER connected players (for voice targeting)
func other_player_steam_ids() -> Array:
	var out: Array = []
	if NetworkManager == null or NetworkManager.active_backend == null:
		return out
	var me := int(Steam.getSteamID())
	for net_id in NetworkManager.active_backend.connected_players.keys():
		var info: Dictionary = NetworkManager.active_backend.connected_players[net_id]
		var sid := int(info.get("id", 0))
		if sid != 0 and sid != me:
			out.append(sid)
	return out


func _scan_tree(node: Node) -> void:
	_consider(node)
	for c in node.get_children():
		_scan_tree(c)


func _on_node_added(node: Node) -> void:
	_consider(node)


func _consider(node: Node) -> void:
	var s = node.get_script()
	if s == null:
		return
	var p: String = s.resource_path
	if p == MAIN_MENU_PATH:
		_setup_main_menu(node)
	elif p == LOBBY_SCENE_PATH:
		_setup_lobby(node)


# Set a duplicated native button's label in the game's own casing. Some native
# buttons draw their text through a child Label/RichTextLabel rather than
# Button.text, so set both to be sure the label actually shows.
func _set_button_label(btn, text: String, upper: bool = false) -> void:
	# upper=true forces ALL CAPS (used for the lobby strip so it matches the caps
	# lobby buttons, kept separate from the main-menu buttons' native casing).
	# English: match the game's casing. Other languages: use the translation as-is.
	var t: String
	if upper:
		t = _t(text).to_upper()
	elif _loc() == "en":
		t = _cased(text)
	else:
		t = _t(text)
	btn.text = t
	_set_child_labels(btn, t)


func _set_child_labels(node, text: String) -> void:
	for c in node.get_children():
		if c is Label or c is RichTextLabel:
			c.text = text
		_set_child_labels(c, text)


# Apply the detected native button casing (matches the rest of the menu).
func _cased(text: String) -> String:
	match _case_style:
		"upper": return text.to_upper()
		"lower": return text.to_lower()
		_: return text.capitalize()   # Title Case


# -------------------------------------------------------------- localization
# The whole mod UI follows the game's language. Common strings are translated
# below (Spanish + Arabic fully; other languages fall back to English until
# their column is filled in). We translate by string so nothing else changes.

# Mod-UI translations for every game language, loaded from mod_i18n.json (keyed
# by the English string). English is the fallback for anything missing.
var _tr_data := {}


func _loc() -> String:
	# Source of truth = the game's own saved language key (Globals.settings
	# ["language"], e.g. "ES","FR","AR"); fall back to TranslationServer. Both can
	# be UPPERCASE, so lowercase before matching.
	var key := ""
	var g = get_node_or_null("/root/Globals")
	if g:
		var s = g.get("settings")
		if typeof(s) == TYPE_DICTIONARY and s.has("language"):
			key = str(s["language"])
	if key == "":
		key = TranslationServer.get_locale()
	key = key.to_lower()
	if key.begins_with("es"):
		return "es"
	if key.begins_with("zht"):
		return "zht"
	if key.begins_with("zh"):
		return "zhs"
	if key.begins_with("sr"):
		# Serbian ships in two scripts: sr_Latn -> "srl" (Latin), else "sr" (Cyrillic)
		return "srl" if key.contains("latn") else "sr"
	return key.substr(0, 2)   # ar, fr, de, br, ru, ua, pl, sv, fi, ee, ja, ko, ...


func _load_i18n(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) == TYPE_DICTIONARY:
		_tr_data = data


# Translate one string to the current game language (English if not covered).
func _t(en: String) -> String:
	var loc := _loc()
	if _tr_data.has(loc) and _tr_data[loc].has(en):
		return str(_tr_data[loc][en])
	return en


# Walk a UI subtree and translate its labels. REVERSIBLE + RE-RUNNABLE: the
# original English is cached per-node in metadata, so calling this again after a
# language change re-translates from English (works switching to ANY language,
# including back to English).
func _localize_tree(node) -> void:
	_localize_node(node)


func _localize_node(node) -> void:
	if (node is Button or node is Label) and not (node is OptionButton):
		_apply_i18n(node, "text")
	if node is LineEdit:
		_apply_i18n(node, "placeholder_text")
	if node is Control:
		_apply_i18n(node, "tooltip_text")
	for c in node.get_children():
		_localize_node(c)


func _apply_i18n(node, prop: String) -> void:
	var meta_key := "mpsb_en_" + prop
	var en: String
	if node.has_meta(meta_key):
		en = str(node.get_meta(meta_key))
	else:
		en = str(node.get(prop))
		if en == "":
			return
		node.set_meta(meta_key, en)
	node.set(prop, _t(en))


# Learn the casing style from a real menu button (its displayed text).
func _detect_case_style(sample_button) -> void:
	if not is_instance_valid(sample_button):
		return
	var shown := tr(str(sample_button.text))
	var letters := ""
	for ch in shown:
		if ch.to_upper() != ch.to_lower():
			letters += ch
	if letters == "":
		return
	if letters == letters.to_upper():
		_case_style = "upper"
	elif letters == letters.to_lower():
		_case_style = "lower"
	else:
		_case_style = "title"


func _ensure_nm_signals() -> void:
	if _nm_connected:
		return
	_nm_connected = true
	NetworkManager.on_peer_connected.connect(_on_peer_connected)
	NetworkManager.on_peer_disconnected.connect(_on_peer_disconnected)


# ------------------------------------------------------------------ main menu

func _setup_main_menu(mm) -> void:
	if not mm.is_node_ready():
		await mm.ready
	if not is_instance_valid(mm):
		return
	# learn how the game cases its menu button labels so ours match
	var sample = mm.options_button if is_instance_valid(mm.options_button) else mm.credits_button
	_detect_case_style(sample)
	# re-apply our labels when the player switches language in the menu
	if not _locale_hooked:
		var g = get_node_or_null("/root/Globals")
		if g and g.has_signal("locale_changed"):
			g.locale_changed.connect(_relocalize)
			_locale_hooked = true
	# repurpose JOIN -> server browser
	if is_instance_valid(mm.start_join_button):
		for conn in mm.start_join_button.pressed.get_connections():
			mm.start_join_button.pressed.disconnect(conn["callable"])
		mm.start_join_button.pressed.connect(func(): _open_browser(mm))
	# add Banned Users + Voice Settings buttons to the main menu
	_add_banned_users_button(mm)
	_add_voice_settings_button(mm)
	# apply the current language to our menu/chat (covers game-started-in-X)
	_relocalize()


func _open_browser(mm) -> void:
	if not Steamworks.is_initialized:
		if is_instance_valid(mm):
			mm.set_tooltip(tr("LOC_TAG_STEAM_FAIL"), Color.CRIMSON)
		return
	if is_instance_valid(_browser):
		return
	_browser = ServerBrowserScreen.new()
	_browser.mod = self
	get_tree().root.add_child(_browser)
	_localize_tree(_browser)


func _add_banned_users_button(mm) -> void:
	# duplicate a native main-menu button so it matches the game exactly
	var template = mm.options_button
	if not is_instance_valid(template):
		template = mm.credits_button
	if not is_instance_valid(template):
		return
	var parent = template.get_parent()
	if not is_instance_valid(parent) or parent.has_node("MPSB_BannedUsers"):
		return
	var btn = template.duplicate()
	btn.name = "MPSB_BannedUsers"
	_set_button_label(btn, "BANNED USERS")
	for conn in btn.pressed.get_connections():
		btn.pressed.disconnect(conn["callable"])
	parent.add_child(btn)
	parent.move_child(btn, template.get_index() + 1)
	# The menu's intro fade runs before we inject, so the duplicate can be left
	# invisible (modulate.a == 0) on re-entry. Force it visible.
	btn.visible = true
	btn.modulate = Color(1, 1, 1, 1)
	btn.pressed.connect(_open_banned_users)
	_menu_btns.append([btn, "BANNED USERS"])


# Re-apply our menu buttons, open browser, and the chat HUD when the language
# changes (or when we re-enter the main menu).
func _relocalize() -> void:
	for pair in _menu_btns:
		if is_instance_valid(pair[0]):
			_set_button_label(pair[0], pair[1])
	if is_instance_valid(_browser):
		_localize_tree(_browser)
	if is_instance_valid(_chat_hud) and _chat_hud.has_method("relocalize"):
		_chat_hud.relocalize()
	if is_instance_valid(_scoreboard):
		_localize_tree(_scoreboard)


func _open_banned_users() -> void:
	var panel = BannedUsersPanel.new()
	panel.mod = self
	get_tree().root.add_child(panel)
	_localize_tree(panel)


func _add_voice_settings_button(mm) -> void:
	# duplicate a native main-menu button so it matches the game exactly
	var template = mm.options_button
	if not is_instance_valid(template):
		template = mm.credits_button
	if not is_instance_valid(template):
		return
	var parent = template.get_parent()
	if not is_instance_valid(parent) or parent.has_node("MPSB_VoiceSettings"):
		return
	var btn = template.duplicate()
	btn.name = "MPSB_VoiceSettings"
	_set_button_label(btn, "VOICE SETTINGS")
	for conn in btn.pressed.get_connections():
		btn.pressed.disconnect(conn["callable"])
	parent.add_child(btn)
	parent.move_child(btn, template.get_index() + 1)
	btn.visible = true
	btn.modulate = Color(1, 1, 1, 1)
	btn.pressed.connect(_open_voice_settings)
	_menu_btns.append([btn, "VOICE SETTINGS"])


func _open_voice_settings() -> void:
	var p = VoiceSettingsPanel.new()
	p.mod = self
	get_tree().root.add_child(p)
	_localize_tree(p)


# ------------------------------------------------------------------ lobby

func _setup_lobby(lobby) -> void:
	if not lobby.is_node_ready():
		await lobby.ready
	if not is_instance_valid(lobby):
		return
	_current_lobby = lobby
	_ensure_nm_signals()
	# Manage Players / Banned Users are NOT in the native button row. In the lobby
	# they are a small side strip (duplicated from a native lobby button so they
	# match Make Lobby Public); in a match they move to the Esc menu.
	var template = _lobby_template(lobby)
	if _lobby_tools and is_instance_valid(template):
		_lobby_tools.rebuild(template)
	_ensure_pause_menu_buttons()           # Manage / Banned / Mute / Deafen in Esc
	if _is_host():
		_inject_public_toggle(lobby)       # host also gets Make Lobby Public
	else:
		NetworkManager.on_server_created.connect(func(): _inject_public_toggle(lobby), CONNECT_ONE_SHOT)


# ---- menu / popup detection (so our HUD buttons get out of the way) ----------

func _menu_open() -> bool:
	var pm = get_node_or_null("/root/PauseMenu")
	if pm and pm.active:
		return true
	# lobby "playlist" popup (mini-game picker) counts as a menu too
	if is_instance_valid(_current_lobby):
		var ph = _current_lobby.get("playlist_handler")
		if ph and is_instance_valid(ph) and ph.active:
			return true
	return false


# A CanvasLayer index above the pause (Esc) menu, so our popups open ON TOP of
# it (they were rendering underneath). Read the pause menu's own layer so we are
# always just above it.
func modal_layer() -> int:
	var pm = get_node_or_null("/root/PauseMenu")
	if pm and pm is CanvasLayer:
		return pm.layer + 3
	return 55


# In a MATCH, our controls live in the pause (Esc) menu, styled like the other
# pause-menu buttons: Manage Players (everyone), Banned Users (host), Mute Mic
# and Deafen (everyone). PauseMenu is an autoload, so this is a one-time inject.
func _ensure_pause_menu_buttons() -> void:
	if _pause_btn_added:
		return
	var pm = get_node_or_null("/root/PauseMenu")
	if pm == null:
		return
	var resume = pm.get("resume_button")
	if not is_instance_valid(resume):
		return
	var parent = resume.get_parent()
	if not is_instance_valid(parent) or parent.has_node("MPSB_PauseExtras"):
		return
	var ctl = PauseExtrasController.new()
	ctl.name = "MPSB_PauseExtras"
	ctl.mod = self
	var idx: int = resume.get_index()
	ctl.manage = _add_pause_button(resume, parent, idx + 1, "Manage Players", _open_manage_players)
	ctl.banned = _add_pause_button(resume, parent, idx + 2, "Banned Users", _open_banned_users)
	ctl.mute = _add_pause_button(resume, parent, idx + 3, "Mute Mic", _pause_toggle_mute)
	ctl.deafen = _add_pause_button(resume, parent, idx + 4, "Deafen", _pause_toggle_deafen)
	parent.add_child(ctl)
	_pause_btn_added = true


func _add_pause_button(resume, parent, at_index: int, label: String, cb: Callable):
	var btn = resume.duplicate()
	btn.name = "MPSB_Pause_" + label.replace(" ", "")
	btn.disabled = false
	btn.visible = true
	_set_button_label(btn, label)
	for conn in btn.pressed.get_connections():
		btn.pressed.disconnect(conn["callable"])
	parent.add_child(btn)
	parent.move_child(btn, at_index)
	btn.modulate = Color(1, 1, 1, 1)
	btn.pressed.connect(cb)
	return btn


func _pause_toggle_mute() -> void:
	if _voice: _voice.set_self_muted(not _voice.is_self_muted())


func _pause_toggle_deafen() -> void:
	if _voice: _voice.set_deafened(not _voice.is_deafened())


func _lobby_template(lobby):
	var handler = lobby.lobby_handler
	if not is_instance_valid(handler):
		return null
	var template = handler.copy_lobby_id_button
	if not is_instance_valid(template):
		template = handler.invite_button
	return template


func _inject_public_toggle(lobby) -> void:
	if not is_instance_valid(lobby) or not _is_host():
		return
	var template = _lobby_template(lobby)
	if not is_instance_valid(template):
		return
	var parent = template.get_parent()
	if not is_instance_valid(parent) or parent.has_node("MPSB_PublicToggle"):
		return
	var toggle = template.duplicate()
	toggle.name = "MPSB_PublicToggle"
	toggle.disabled = false
	toggle.visible = true
	for conn in toggle.pressed.get_connections():
		toggle.pressed.disconnect(conn["callable"])
	parent.add_child(toggle)
	parent.move_child(toggle, template.get_index() + 2)
	toggle.modulate = Color(1, 1, 1, 1)
	var ctl = PublicToggleController.new()
	ctl.name = "MPSB_PublicCtl"
	ctl.mod = self
	toggle.add_child(ctl)
	_update_joinable()


func _open_manage_players() -> void:
	var panel = ManagePlayersPanel.new()
	panel.mod = self
	get_tree().root.add_child(panel)
	_localize_tree(panel)


# ------------------------------------------------------------------ peer events

func _on_peer_connected(net_id: int) -> void:
	# auto-kick banned players from lobbies we host, cooperatively (no hard
	# disconnect ever, which is what crashed the host).
	if _is_host():
		var info = _player_info(net_id)
		if is_banned(str(info.get("id", ""))):
			_remove_player(net_id, true)
	players_changed.emit()
	_update_joinable()


func _on_peer_disconnected(net_id: int) -> void:
	_leaving.erase(net_id)
	players_changed.emit()
	_update_joinable()


# ------------------------------------------------------------------ steam core

func _is_host() -> bool:
	return multiplayer and multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func owned_lobby_id() -> int:
	if NetworkManager == null or NetworkManager.active_backend == null:
		return 0
	var id := int(NetworkManager.active_backend.lobby_id)
	if id <= 0 or not _is_host():
		return 0
	return id


func is_owned_public() -> bool:
	var id := owned_lobby_id()
	return id > 0 and Steam.getLobbyData(id, KEY_PUB) == "1"


func _player_count() -> int:
	if NetworkManager and NetworkManager.active_backend:
		return NetworkManager.active_backend.connected_players.size()
	return 1


func _player_info(net_id: int) -> Dictionary:
	if NetworkManager and NetworkManager.active_backend:
		return NetworkManager.active_backend.connected_players.get(net_id, {})
	return {}


func _sanitize_name(n: String) -> String:
	n = n.strip_edges()
	if n.is_empty():
		n = "%s's lobby" % Steam.getFriendPersonaName(Steam.getSteamID())
	return n.substr(0, 63)


func publish(lobby_name: String, max_players: int, allow_mid_join: bool) -> bool:
	var id := owned_lobby_id()
	if id <= 0:
		return false
	max_players = clampi(max_players, MIN_PLAYERS, MAX_PLAYERS_CAP)
	Steam.setLobbyType(id, Steam.LobbyType.LOBBY_TYPE_PUBLIC)
	Steam.setLobbyJoinable(id, true)
	Steam.setLobbyMemberLimit(id, max_players)
	Steam.setLobbyData(id, KEY_PUB, "1")
	Steam.setLobbyData(id, KEY_NAME, _sanitize_name(lobby_name))
	Steam.setLobbyData(id, KEY_MAX, str(max_players))
	Steam.setLobbyData(id, KEY_VER, Globals.game_version)
	Steam.setLobbyData(id, KEY_HOST, Steam.getFriendPersonaName(Steam.getSteamID()))
	Steam.setLobbyData(id, KEY_MID, "1" if allow_mid_join else "0")
	Steam.setLobbyData(id, KEY_BANS, _bans_csv())
	NetworkManager.max_player_count = max_players
	_update_joinable()
	publish_state_changed.emit(true)
	return true


func unpublish() -> void:
	var id := owned_lobby_id()
	if id <= 0:
		return
	Steam.setLobbyType(id, Steam.LobbyType.LOBBY_TYPE_FRIENDS_ONLY)
	Steam.setLobbyData(id, KEY_PUB, "0")
	Steam.setLobbyData(id, KEY_JOIN, "0")
	publish_state_changed.emit(false)


func _update_joinable() -> void:
	var id := owned_lobby_id()
	if id <= 0 or Steam.getLobbyData(id, KEY_PUB) != "1":
		return
	var maxp := int(Steam.getLobbyData(id, KEY_MAX))
	if maxp <= 0:
		maxp = MAX_PLAYERS_CAP
	var count := _player_count()
	var mid: bool = Steam.getLobbyData(id, KEY_MID) == "1"
	var in_game: bool = GameManager.game_in_progress
	var joinable: bool = count < maxp and (mid or not in_game)
	Steam.setLobbyData(id, KEY_JOIN, "1" if joinable else "0")
	Steam.setLobbyData(id, KEY_COUNT, str(count))
	Steam.setLobbyData(id, KEY_STATE, "ingame" if in_game else "lobby")


func refresh_lobbies() -> void:
	if not Steamworks.is_initialized:
		lobbies_refreshed.emit([])
		return
	_pending_refresh = true
	Steam.addRequestLobbyListDistanceFilter(Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE)
	Steam.addRequestLobbyListStringFilter(KEY_PUB, "1", Steam.LobbyComparison.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListStringFilter(KEY_JOIN, "1", Steam.LobbyComparison.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListResultCountFilter(50)
	Steam.requestLobbyList()


func _on_lobby_match_list(lobbies: Array) -> void:
	if not _pending_refresh:
		return
	_pending_refresh = false
	var results: Array = []
	var me := str(Steam.getSteamID())
	for lobby_id in lobbies:
		var id := int(lobby_id)
		if Steam.getLobbyData(id, KEY_PUB) != "1":
			continue
		# if the host banned me, this lobby is invisible to me
		var bans_csv: String = Steam.getLobbyData(id, KEY_BANS)
		if bans_csv != "" and ("," + bans_csv + ",").contains("," + me + ","):
			continue
		var lname: String = Steam.getLobbyData(id, KEY_NAME)
		if lname.strip_edges().is_empty():
			lname = Steam.getLobbyData(id, KEY_HOST)
		if lname.strip_edges().is_empty():
			lname = "Machine Party Lobby"
		var version: String = Steam.getLobbyData(id, KEY_VER)
		var maxp := int(Steam.getLobbyData(id, KEY_MAX))
		if maxp <= 0:
			maxp = MAX_PLAYERS_CAP
		var count := int(Steam.getLobbyData(id, KEY_COUNT))
		if count <= 0:
			count = Steam.getNumLobbyMembers(id)
		if count <= 0:
			count = 1
		results.append({
			"id": id, "name": lname, "players": count, "max": maxp,
			"version": version, "host": Steam.getLobbyData(id, KEY_HOST),
			"state": Steam.getLobbyData(id, KEY_STATE),
			"joinable": count < maxp,
			"compatible": version == Globals.game_version or version.is_empty(),
		})
	results.sort_custom(func(a, b):
		if a["compatible"] != b["compatible"]:
			return a["compatible"]
		return a["players"] > b["players"]
	)
	lobbies_refreshed.emit(results)


func join_lobby(lobby_id: int) -> void:
	if lobby_id <= 0:
		return
	GameManager.join_lobby_id = lobby_id
	GameManager.host_game = false
	GameManager.custom_game = false
	if MusicManager and MusicManager.filter_controller:
		MusicManager.filter_controller.begin_shift(MusicManager.filter_controller.effect_low_pass.cutoff_hz, 300, 4, 1)
	GlobalOverlay.fade_overlay(Color.BLACK, 1.0)
	await GlobalOverlay.fade_finished
	if not is_inside_tree():
		return
	get_tree().change_scene_to_file(LOBBY_TSCN)


func join_by_code(code: String) -> String:
	code = code.strip_edges()
	if code.length() != 18 or not code.is_valid_int():
		return "LOC_TAG_NO_ROOM_ID"
	join_lobby(int(code))
	return ""


# ------------------------------------------------------------------ kick / ban

func kick(net_id: int) -> void:
	if not _is_host():
		return
	_remove_player(net_id, false)


func ban(net_id: int) -> void:
	if not _is_host():
		return
	var info := _player_info(net_id)
	var sid := str(info.get("id", ""))
	var pname := str(info.get("name", "Unknown"))
	if sid != "" and sid != "0":
		_bans[sid] = pname
		_save_bans()
		_publish_bans()          # so this lobby immediately hides from them
	_remove_player(net_id, true)


# Remove a player WITHOUT crashing the host. We NEVER call
# multiplayer_peer.disconnect_peer: a host-side hard disconnect leaves the peer
# half-open and the game's own post-disconnect RPC then fires against it -> host
# crash (the recurring "kick/ban crashes host" bug). Instead we ASK the client
# to leave through the game's own "leave lobby" path (exactly what the Leave
# button does); to the host that is an ordinary voluntary disconnect the game
# handles cleanly. The request is a reliable Steam P2P packet, resent a few
# times to cover P2P-session setup latency. Every client reachable through the
# server browser runs the mod, so this removes them reliably.
func _remove_player(net_id: int, is_ban: bool) -> void:
	if net_id <= 1 or (multiplayer and net_id == multiplayer.get_unique_id()):
		return
	if _leaving.has(net_id):          # already asked this peer to leave
		return
	_leaving[net_id] = true
	_send_leave_request(net_id, is_ban)
	_resend_leave_request(net_id, is_ban, 4)   # belt-and-suspenders; no hard disconnect


func _send_leave_request(net_id: int, is_ban: bool) -> void:
	var info := _player_info(net_id)
	var sid := int(info.get("id", 0))
	if sid != 0 and _voice:
		_voice.send_ctrl(sid, {"t": ("ban" if is_ban else "kick")})
	if _loader: _loader.note("remove: asked peer %d to leave (ban=%s)" % [net_id, str(is_ban)])


# Resend the cooperative leave request while the peer is still connected, in case
# the first reliable packet raced the Steam P2P session opening. Stops as soon as
# the peer is gone. Never force-disconnects (that is what crashed the host).
func _resend_leave_request(net_id: int, is_ban: bool, tries_left: int) -> void:
	if tries_left <= 0 or not is_inside_tree():
		return
	var t := get_tree().create_timer(0.6)
	t.timeout.connect(func():
		if _is_host() and _is_connected_peer(net_id) and _leaving.has(net_id):
			_send_leave_request(net_id, is_ban)
			_resend_leave_request(net_id, is_ban, tries_left - 1)
	)


func _is_connected_peer(net_id: int) -> bool:
	return NetworkManager != null and NetworkManager.active_backend != null \
		and NetworkManager.active_backend.connected_players.has(net_id)


# ---- Control packets (host <-> client management over Steam P2P) -------------

# Called by VoiceChat when a control packet arrives from `sender` (Steam id).
func _on_control_packet(sender: int, d: Dictionary) -> void:
	var t := str(d.get("t", ""))
	if t == "kick" or t == "ban":
		# Only obey a kick/ban from the ACTUAL lobby owner, never a spoofed one.
		if NetworkManager == null or NetworkManager.active_backend == null:
			return
		var lid := int(NetworkManager.active_backend.lobby_id)
		if lid <= 0:
			return
		if int(Steam.getLobbyOwner(lid)) != sender:
			return
		_leave_because_kicked(t == "ban")


func _leave_because_kicked(is_ban: bool) -> void:
	if _kick_leaving:
		return
	_kick_leaving = true
	var uid := 0
	if multiplayer and multiplayer.has_multiplayer_peer():
		uid = multiplayer.get_unique_id()
	# Same sequence the game's own Leave button runs.
	if NetworkManager:
		if NetworkManager.has_method("leave_lobby"):
			NetworkManager.leave_lobby()
		if NetworkManager.has_method("cancel"):
			NetworkManager.cancel(uid)
	if GameManager:
		GameManager.main_menu_dialog_message = \
			("You have been banned from this lobby." if is_ban else "You were removed from the lobby.")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu/main_menu.tscn")


func is_banned(steam_id: String) -> bool:
	return steam_id != "" and _bans.has(steam_id)


func unban(steam_id: String) -> void:
	if _bans.has(steam_id):
		_bans.erase(steam_id)
		_save_bans()
		_publish_bans()


# Comma-joined banned steam ids, written into our public lobby's data so that
# other players running the mod hide it from banned users on refresh.
func _bans_csv() -> String:
	return ",".join(PackedStringArray(_bans.keys()))


func _publish_bans() -> void:
	var id := owned_lobby_id()
	if id <= 0:
		return
	Steam.setLobbyData(id, KEY_BANS, _bans_csv())


func banned_list() -> Array:
	var out: Array = []
	for sid in _bans.keys():
		out.append({"id": sid, "name": str(_bans[sid])})
	return out


func _load_bans() -> void:
	_bans = {}
	if not FileAccess.file_exists(BANS_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(BANS_PATH))
	if typeof(data) == TYPE_DICTIONARY:
		for k in data.keys():
			_bans[str(k)] = str(data[k])


func _save_bans() -> void:
	var f := FileAccess.open(BANS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_bans))
		f.close()


# ---- Player identity helpers (used by the scoreboard) ------------------------

# Stable id for a player across a rejoin: their Steam id when known, otherwise a
# fallback keyed to the network id. Wins/losses are tracked against this so a
# returning player keeps their tally, matching how the base game restores score.
func _steam_id_for(net_id) -> String:
	var info := _player_info(int(net_id))
	var sid := str(info.get("id", ""))
	if sid == "" or sid == "0":
		return "net:%s" % str(net_id)
	return sid


func _name_for(net_id) -> String:
	var info := _player_info(int(net_id))
	var nm := str(info.get("name", ""))
	if nm != "":
		return nm
	var pm = get_node_or_null("/root/PlayerManager")
	if pm and pm.player_presences.has(int(net_id)):
		return str(pm.player_presences[int(net_id)].network_name)
	return "Player %s" % str(net_id)


# =============================================================================
#  Shared styling (green terminal look, matches the browser)
# =============================================================================

class Style:
	const HACK_GREEN := Color(0.55, 1.0, 0.55)
	const GREY_N := Color(0.55, 0.55, 0.55)
	const GREY_H := Color(0.72, 0.72, 0.72)
	const GREY_P := Color(0.40, 0.40, 0.40)
	const GREY_D := Color(0.30, 0.30, 0.30)
	static var _sym: Font = null

	static func font() -> Font:
		if ResourceLoader.exists("res://fonts/whitrabt.ttf"):
			return load("res://fonts/whitrabt.ttf")
		return null

	static func sym_font() -> Font:
		if _sym == null:
			var sf := SystemFont.new()
			sf.font_names = PackedStringArray(["Segoe UI Symbol", "Segoe UI", "Arial", "DejaVu Sans"])
			_sym = sf
		return _sym

	static func label(text: String, size: int = 20, green: bool = true) -> Label:
		var l := Label.new()
		l.text = text
		var f := font()
		if f: l.add_theme_font_override("font", f)
		if size > 0: l.add_theme_font_size_override("font_size", size)
		if green: l.add_theme_color_override("font_color", HACK_GREEN)
		return l

	static func _box(bg: Color) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = bg
		s.border_color = Color.BLACK
		s.set_border_width_all(3)
		s.set_corner_radius_all(0)
		s.content_margin_left = 10; s.content_margin_right = 10
		s.content_margin_top = 6; s.content_margin_bottom = 6
		return s

	static func button(text: String, symbol: bool = false) -> Button:
		var b := Button.new()
		b.text = text
		b.add_theme_font_override("font", sym_font() if symbol else font())
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.add_theme_stylebox_override("normal", _box(GREY_N))
		b.add_theme_stylebox_override("hover", _box(GREY_H))
		b.add_theme_stylebox_override("pressed", _box(GREY_P))
		b.add_theme_stylebox_override("focus", _box(GREY_H))
		b.add_theme_stylebox_override("disabled", _box(GREY_D))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(c, Color.BLACK)
		return b

	static func line_edit(placeholder: String) -> LineEdit:
		var e := LineEdit.new()
		e.placeholder_text = placeholder
		var f := font()
		if f: e.add_theme_font_override("font", f)
		e.add_theme_color_override("font_color", HACK_GREEN)
		e.add_theme_color_override("font_placeholder_color", Color(0.55, 1, 0.55, 0.5))
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0.02, 0.05, 0.02)
		st.border_color = Color(0.3, 0.7, 0.3)
		st.set_border_width_all(1)
		st.content_margin_left = 8; st.content_margin_right = 8
		st.content_margin_top = 6; st.content_margin_bottom = 6
		e.add_theme_stylebox_override("normal", st)
		e.add_theme_stylebox_override("focus", st)
		return e

	static func window(min_size: Vector2) -> PanelContainer:
		var w := PanelContainer.new()
		w.custom_minimum_size = min_size
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0.03, 0.07, 0.03, 0.85)
		st.border_color = HACK_GREEN
		st.set_border_width_all(2)
		w.add_theme_stylebox_override("panel", st)
		return w

	static func overlay(layer_node: CanvasLayer, lyr: int = 50) -> Control:
		layer_node.layer = lyr
		var dim := ColorRect.new()
		dim.color = Color(0, 0.02, 0, 0.6)
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_STOP
		layer_node.add_child(dim)
		var center := CenterContainer.new()
		center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		layer_node.add_child(center)
		return center


# =============================================================================
#  Up/down stepper (max players, capped 1..4)
# =============================================================================

class Stepper:
	extends HBoxContainer
	const MINV := 1
	const MAXV := 4
	signal value_changed(v)
	var value := MAXV
	var _lbl: Label
	var _up: Button
	var _dn: Button

	func _ready() -> void:
		add_theme_constant_override("separation", 10)
		alignment = BoxContainer.ALIGNMENT_CENTER
		_lbl = Style.label(str(value), 40)
		_lbl.custom_minimum_size = Vector2(48, 0)
		_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(_lbl)
		var col := VBoxContainer.new()
		add_child(col)
		_up = Style.button("▲", true); _up.custom_minimum_size = Vector2(40, 28)
		_up.pressed.connect(func(): _step(1)); col.add_child(_up)
		_dn = Style.button("▼", true); _dn.custom_minimum_size = Vector2(40, 28)
		_dn.pressed.connect(func(): _step(-1)); col.add_child(_dn)
		_refresh()

	func set_value(v: int) -> void:
		value = clampi(v, MINV, MAXV); _refresh()

	func _step(d: int) -> void:
		var nv := clampi(value + d, MINV, MAXV)
		if nv == value: return
		value = nv; _refresh(); value_changed.emit(value)

	func _refresh() -> void:
		if not is_instance_valid(_lbl): return
		_lbl.text = str(value)
		_up.disabled = value >= MAXV
		_dn.disabled = value <= MINV


# =============================================================================
#  Server browser overlay
# =============================================================================

class ServerBrowserScreen:
	extends CanvasLayer
	var mod
	var _list: VBoxContainer
	var _status: Label
	var _code: LineEdit

	func _ready() -> void:
		var center := Style.overlay(self, mod.modal_layer() if mod else 55)
		var win := Style.window(Vector2(760, 620))
		center.add_child(win)
		var m := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + s, 24)
		win.add_child(m)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 12)
		m.add_child(v)

		var title_row := HBoxContainer.new()
		title_row.add_theme_constant_override("separation", 8)
		v.add_child(title_row)
		var close := Style.button("✕", true)
		close.custom_minimum_size = Vector2(44, 44)
		close.pressed.connect(close_screen)
		title_row.add_child(close)
		var title := Style.label("SERVER BROWSER", 40)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title_row.add_child(title)
		var refresh := Style.button("REFRESH")
		refresh.custom_minimum_size = Vector2(150, 44)
		refresh.pressed.connect(_do_refresh)
		title_row.add_child(refresh)

		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		v.add_child(scroll)
		_list = VBoxContainer.new()
		_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list.add_theme_constant_override("separation", 6)
		scroll.add_child(_list)

		_status = Style.label("", 18)
		_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(_status)
		v.add_child(HSeparator.new())

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		v.add_child(row)
		row.add_child(Style.label("ROOM ID:", 18))
		_code = Style.line_edit("paste an 18-digit room code")
		_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_code)
		var paste := Style.button("PASTE")
		paste.custom_minimum_size = Vector2(110, 44)
		paste.pressed.connect(func(): _code.text = DisplayServer.clipboard_get())
		row.add_child(paste)
		var gap := Control.new(); gap.custom_minimum_size = Vector2(28, 0); row.add_child(gap)
		var joinc := Style.button("JOIN")
		joinc.custom_minimum_size = Vector2(110, 44)
		joinc.pressed.connect(_join_by_code)
		row.add_child(joinc)

		var bottom := HBoxContainer.new()
		bottom.alignment = BoxContainer.ALIGNMENT_CENTER
		v.add_child(bottom)
		var back := Style.button("BACK")
		back.custom_minimum_size = Vector2(180, 44)
		back.pressed.connect(close_screen)
		bottom.add_child(back)

		# Localize the whole browser now that it is fully built (bulletproof timing).
		if mod:
			mod._localize_tree(self)
			if mod._loader:
				var gl = get_node_or_null("/root/Globals")
				var setl = str(gl.get("settings").get("language", "?")) if (gl and typeof(gl.get("settings")) == TYPE_DICTIONARY) else "?"
				mod._loader.note("browser: settings.language=%s tsvr=%s -> _loc=%s (sample title=%s)" % [
					setl, TranslationServer.get_locale(), mod._loc(), mod._t("SERVER BROWSER")])

		if mod:
			mod.lobbies_refreshed.connect(_on_refreshed)
			mod.refresh_lobbies()
			_status.text = mod._t("Searching for lobbies...") if mod else "Searching for lobbies..."
		if CursorManager:
			CursorManager.set_active(true); CursorManager.set_locked(false)
			CursorManager.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	func _do_refresh() -> void:
		if mod:
			mod.refresh_lobbies()
			_status.text = mod._t("Searching for lobbies...") if mod else "Searching for lobbies..."

	func _join_by_code() -> void:
		if not mod: return
		var err: String = mod.join_by_code(_code.text)
		if err != "":
			_status.text = tr(err) if err.begins_with("LOC_") else err
			_status.add_theme_color_override("font_color", Color.CRIMSON)
		else:
			close_screen()

	func _on_refreshed(lobbies: Array) -> void:
		for c in _list.get_children():
			c.queue_free()
		if lobbies.is_empty():
			var e := "No public lobbies found. Host one and make it public!"
			_status.text = mod._t(e) if mod else e
			return
		_status.text = ""
		for info in lobbies:
			_list.add_child(_make_row(info))
		if mod: mod._localize_tree(_list)

	func _make_row(info: Dictionary) -> Control:
		var row := PanelContainer.new()
		var rs := StyleBoxFlat.new()
		rs.bg_color = Color(0.10, 0.20, 0.10, 0.45)
		rs.border_color = Color(0.3, 0.7, 0.3, 0.6)
		rs.set_border_width_all(1)
		row.add_theme_stylebox_override("panel", rs)
		var pad := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			pad.add_theme_constant_override("margin_" + s, 8)
		row.add_child(pad)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 12)
		pad.add_child(h)
		var nm := Style.label(String(info.get("name", "Lobby")), 22)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		h.add_child(nm)
		if String(info.get("state", "")) == "ingame":
			h.add_child(Style.label("[in game]", 14))
		if not info.get("compatible", true):
			nm.modulate = Color(1, 1, 1, 0.5)
			var vm := Style.label("v.mismatch", 14); vm.modulate = Color.CRIMSON; h.add_child(vm)
		var pl := Style.label("%d/%d" % [int(info.get("players", 1)), int(info.get("max", 4))], 22)
		pl.custom_minimum_size = Vector2(110, 0)
		pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		h.add_child(pl)
		var j := Style.button("JOIN")
		j.custom_minimum_size = Vector2(120, 44)
		j.disabled = not (bool(info.get("joinable", true)) and bool(info.get("compatible", true)))
		var lid := int(info.get("id", 0))
		j.pressed.connect(func():
			if mod:
				close_screen()
				mod.join_lobby(lid)
		)
		h.add_child(j)
		return row

	func _unhandled_input(e: InputEvent) -> void:
		if e.is_action_pressed("ui_cancel"):
			close_screen(); get_viewport().set_input_as_handled()

	func close_screen() -> void:
		if mod and mod.lobbies_refreshed.is_connected(_on_refreshed):
			mod.lobbies_refreshed.disconnect(_on_refreshed)
		if mod:
			mod._browser = null
		queue_free()


# =============================================================================
#  Make Public toggle controller (child of the duplicated lobby button)
# =============================================================================

class PublicToggleController:
	extends Node
	var mod
	var _btn: Button
	var _panel_open := false

	func _ready() -> void:
		_btn = get_parent() as Button
		if not is_instance_valid(_btn): return
		_btn.pressed.connect(_on_pressed)
		if mod:
			mod.publish_state_changed.connect(_refresh)
		_refresh(mod.is_owned_public() if mod else false)
		set_process(true)

	func _process(_dt: float) -> void:
		# Make Public/Private is host-only. Enforce every frame so a client can
		# never see it even if injection ever slipped through.
		if not is_instance_valid(_btn):
			return
		var is_host: bool = multiplayer != null and multiplayer.has_multiplayer_peer() and multiplayer.is_server()
		if _btn.visible != is_host:
			_btn.visible = is_host

	func _on_pressed() -> void:
		if not mod or mod.owned_lobby_id() <= 0: return
		if mod.is_owned_public():
			mod.unpublish()
		elif not _panel_open:
			_panel_open = true
			var p = MakePublicPanel.new()
			p.mod = mod
			get_tree().root.add_child(p)
			if mod: mod._localize_tree(p)
			p.confirmed.connect(func(n, m, mid):
				_panel_open = false
				if mod: mod.publish(n, m, mid)
			)
			p.cancelled.connect(func(): _panel_open = false)

	func _refresh(is_public: bool) -> void:
		if is_instance_valid(_btn):
			var label := "MAKE LOBBY PRIVATE" if is_public else "MAKE LOBBY PUBLIC"
			_btn.text = mod._t(label) if mod else label
			_btn.modulate = Color(0.6, 1.0, 0.6) if is_public else Color.WHITE


# =============================================================================
#  Make Public panel (name + max players + allow mid joining)
# =============================================================================

class MakePublicPanel:
	extends CanvasLayer
	var mod
	signal confirmed(lobby_name, max_players, allow_mid_join)
	signal cancelled()
	var _name: LineEdit
	var _stepper
	var _mid_check: CheckBox

	func _ready() -> void:
		layer = 60
		var center := Style.overlay(self, mod.modal_layer() if mod else 55)
		var win := Style.window(Vector2(560, 0))
		center.add_child(win)
		var m := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + s, 24)
		win.add_child(m)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 16)
		m.add_child(v)
		var title := Style.label("MAKE LOBBY PUBLIC", 32)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(title)

		v.add_child(Style.label("LOBBY NAME", 18))
		_name = Style.line_edit("Lobby name")
		_name.max_length = 63
		_name.text = "%s's lobby" % Steam.getFriendPersonaName(Steam.getSteamID())
		v.add_child(_name)

		v.add_child(Style.label("MAX PLAYERS", 18))
		_stepper = Stepper.new()
		_stepper.set_value(mod.MAX_PLAYERS_CAP if mod else 4)
		v.add_child(_stepper)

		var mid_row := HBoxContainer.new()
		mid_row.add_theme_constant_override("separation", 10)
		v.add_child(mid_row)
		_mid_check = CheckBox.new()
		_mid_check.button_pressed = true
		var cf := Style.font()
		if cf: _mid_check.add_theme_font_override("font", cf)
		_mid_check.add_theme_color_override("font_color", Style.HACK_GREEN)
		_mid_check.text = "Allow mid joining"
		mid_row.add_child(_mid_check)
		var hint := Style.label("(stay listed after the match starts)", 14)
		hint.modulate = Color(1, 1, 1, 0.7)
		mid_row.add_child(hint)

		v.add_child(HSeparator.new())
		var buttons := HBoxContainer.new()
		buttons.add_theme_constant_override("separation", 16)
		buttons.alignment = BoxContainer.ALIGNMENT_CENTER
		v.add_child(buttons)
		var ok := Style.button("CONFIRM"); ok.custom_minimum_size = Vector2(200, 44)
		ok.pressed.connect(_confirm); buttons.add_child(ok)
		var no := Style.button("CANCEL"); no.custom_minimum_size = Vector2(200, 44)
		no.pressed.connect(_cancel); buttons.add_child(no)

	func _confirm() -> void:
		confirmed.emit(_name.text, _stepper.value, _mid_check.button_pressed)
		queue_free()

	func _cancel() -> void:
		cancelled.emit(); queue_free()

	func _unhandled_input(e: InputEvent) -> void:
		if e.is_action_pressed("ui_cancel"):
			_cancel(); get_viewport().set_input_as_handled()


# =============================================================================
#  Manage Players panel (live list, per-player kick/ban)
# =============================================================================

class ManagePlayersPanel:
	extends CanvasLayer
	var mod
	var _list: VBoxContainer
	var _title: Label

	func _ready() -> void:
		layer = 60
		var center := Style.overlay(self, mod.modal_layer() if mod else 55)
		var win := Style.window(Vector2(600, 500))
		center.add_child(win)
		var m := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + s, 24)
		win.add_child(m)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 12)
		m.add_child(v)
		var tr_row := HBoxContainer.new()
		v.add_child(tr_row)
		_title = Style.label("PLAYERS IN LOBBY", 32)
		_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tr_row.add_child(_title)
		var close := Style.button("✕", true); close.custom_minimum_size = Vector2(44, 44)
		close.pressed.connect(queue_free)
		tr_row.add_child(close)
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		v.add_child(scroll)
		_list = VBoxContainer.new()
		_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list.add_theme_constant_override("separation", 6)
		scroll.add_child(_list)
		if mod:
			mod.players_changed.connect(_rebuild)
		_rebuild()

	func _rebuild() -> void:
		if not is_instance_valid(_list): return
		for c in _list.get_children():
			c.queue_free()
		if not mod or NetworkManager == null or NetworkManager.active_backend == null:
			return
		var players: Dictionary = NetworkManager.active_backend.connected_players
		var self_id := multiplayer.get_unique_id() if multiplayer else -1
		for net_id in players.keys():
			var info: Dictionary = players[net_id]
			_list.add_child(_make_row(int(net_id), info, int(net_id) == self_id))
		if mod: mod._localize_tree(self)

	func _make_row(net_id: int, info: Dictionary, is_self: bool) -> Control:
		var row := PanelContainer.new()
		var rs := StyleBoxFlat.new()
		rs.bg_color = Color(0.10, 0.20, 0.10, 0.45)
		rs.border_color = Color(0.3, 0.7, 0.3, 0.6); rs.set_border_width_all(1)
		row.add_theme_stylebox_override("panel", rs)
		var pad := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			pad.add_theme_constant_override("margin_" + s, 8)
		row.add_child(pad)
		var h := HBoxContainer.new(); h.add_theme_constant_override("separation", 12); pad.add_child(h)
		var you_sfx: String = (mod._t(" (you)") if mod else " (you)") if is_self else ""
		var nm := Style.label(str(info.get("name", "Player")) + you_sfx, 22)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(nm)
		if is_self:
			return row
		var sid := str(info.get("id", ""))
		var v = mod.voice() if mod else null
		# per-player voice mute (everyone)
		var mute_btn := Style.button("UNMUTE" if (v and v.is_player_muted(sid)) else "MUTE")
		mute_btn.custom_minimum_size = Vector2(110, 40)
		mute_btn.pressed.connect(func():
			if v:
				var nm2: bool = not v.is_player_muted(sid)
				v.set_player_muted(sid, nm2)
				mute_btn.text = (mod._t("UNMUTE") if nm2 else mod._t("MUTE")) if mod else ("UNMUTE" if nm2 else "MUTE")
		)
		h.add_child(mute_btn)
		# per-player voice volume (everyone)
		var sld := HSlider.new()
		sld.min_value = 0.0; sld.max_value = 1.0; sld.step = 0.05
		sld.value = (v.get_player_volume(sid) if v else 1.0)
		sld.custom_minimum_size = Vector2(120, 0)
		sld.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sld.value_changed.connect(func(val):
			if v: v.set_player_volume(sid, val)
		)
		h.add_child(sld)
		# host-only kick / ban
		if multiplayer and multiplayer.is_server():
			var manage := Style.button("MANAGE")
			manage.custom_minimum_size = Vector2(110, 40)
			manage.pressed.connect(func(): _open_manage(net_id, info))
			h.add_child(manage)
		return row

	func _open_manage(net_id: int, info: Dictionary) -> void:
		var dlg = ManageOne.new()
		dlg.mod = mod
		dlg.net_id = net_id
		dlg.pname = str(info.get("name", "Player"))
		get_tree().root.add_child(dlg)
		if mod: mod._localize_tree(dlg)

	func _unhandled_input(e: InputEvent) -> void:
		if e.is_action_pressed("ui_cancel"):
			queue_free(); get_viewport().set_input_as_handled()


# --- per-player manage dialog (Kick / Ban / Back) ---
class ManageOne:
	extends CanvasLayer
	var mod
	var net_id := 0
	var pname := "Player"

	func _ready() -> void:
		layer = 61
		var center := Style.overlay(self, mod.modal_layer() if mod else 55)
		var win := Style.window(Vector2(440, 0))
		center.add_child(win)
		var m := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + s, 24)
		win.add_child(m)
		var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 14); m.add_child(v)
		var t := Style.label(pname, 28); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(t)
		var kick := Style.button("KICK"); kick.custom_minimum_size = Vector2(0, 44)
		kick.pressed.connect(func():
			_ask("Kick this player?", "KICK", func():
				if mod: mod.kick(net_id)
				queue_free()
			)
		)
		v.add_child(kick)
		var ban := Style.button("BAN"); ban.custom_minimum_size = Vector2(0, 44)
		ban.add_theme_color_override("font_color", Color.CRIMSON)
		ban.pressed.connect(func():
			_ask("Ban this player? They cannot rejoin.", "BAN", func():
				if mod: mod.ban(net_id)
				queue_free()
			)
		)
		v.add_child(ban)
		v.add_child(HSeparator.new())
		var back := Style.button("BACK"); back.custom_minimum_size = Vector2(0, 44)
		back.pressed.connect(queue_free)
		v.add_child(back)

	# Show a translated confirmation before actually kicking/banning.
	func _ask(msg_key: String, action_key: String, action: Callable) -> void:
		var dlg = ConfirmDialog.new()
		dlg.mod = mod
		dlg.title_text = pname
		dlg.msg_key = msg_key
		dlg.confirm_key = action_key
		get_tree().root.add_child(dlg)
		dlg.confirmed.connect(action)

	func _unhandled_input(e: InputEvent) -> void:
		if e.is_action_pressed("ui_cancel"):
			queue_free(); get_viewport().set_input_as_handled()


# =============================================================================
#  Confirmation dialog (kick / ban). Title = player name, message + buttons are
#  translated to the game language.
# =============================================================================

class ConfirmDialog:
	extends CanvasLayer
	var mod
	var title_text := ""
	var msg_key := ""
	var confirm_key := "CONFIRM"
	signal confirmed()

	func _ready() -> void:
		var lyr: int = (mod.modal_layer() + 4) if mod else 90
		var center := Style.overlay(self, lyr)
		var win := Style.window(Vector2(470, 0))
		center.add_child(win)
		var m := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + s, 24)
		win.add_child(m)
		var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 16); m.add_child(v)
		if title_text != "":
			var t := Style.label(title_text, 26); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			v.add_child(t)
		var msg := Style.label(mod._t(msg_key) if mod else msg_key, 20)
		msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(msg)
		v.add_child(HSeparator.new())
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		v.add_child(row)
		var yes := Style.button(mod._t(confirm_key) if mod else confirm_key)
		yes.custom_minimum_size = Vector2(180, 44)
		yes.add_theme_color_override("font_color", Color.CRIMSON)
		yes.pressed.connect(func():
			confirmed.emit()
			queue_free()
		)
		row.add_child(yes)
		var no := Style.button(mod._t("CANCEL") if mod else "CANCEL")
		no.custom_minimum_size = Vector2(180, 44)
		no.pressed.connect(queue_free)
		row.add_child(no)

	func _unhandled_input(e: InputEvent) -> void:
		if e.is_action_pressed("ui_cancel"):
			queue_free(); get_viewport().set_input_as_handled()


# =============================================================================
#  Banned Users panel (view / unban)
# =============================================================================

class BannedUsersPanel:
	extends CanvasLayer
	var mod
	var _list: VBoxContainer

	func _ready() -> void:
		layer = 60
		var center := Style.overlay(self, mod.modal_layer() if mod else 55)
		var win := Style.window(Vector2(600, 500))
		center.add_child(win)
		var m := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + s, 24)
		win.add_child(m)
		var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 12); m.add_child(v)
		var tr_row := HBoxContainer.new(); v.add_child(tr_row)
		var t := Style.label("BANNED USERS", 32); t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tr_row.add_child(t)
		var close := Style.button("✕", true); close.custom_minimum_size = Vector2(44, 44)
		close.pressed.connect(queue_free); tr_row.add_child(close)
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		v.add_child(scroll)
		_list = VBoxContainer.new()
		_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list.add_theme_constant_override("separation", 6)
		scroll.add_child(_list)
		_rebuild()

	func _rebuild() -> void:
		for c in _list.get_children():
			c.queue_free()
		if not mod: return
		var bans: Array = mod.banned_list()
		if bans.is_empty():
			_list.add_child(Style.label(mod._t("No banned users."), 18))
			return
		for b in bans:
			_list.add_child(_make_row(b))
		mod._localize_tree(self)

	func _make_row(b: Dictionary) -> Control:
		var row := PanelContainer.new()
		var rs := StyleBoxFlat.new()
		rs.bg_color = Color(0.10, 0.20, 0.10, 0.45)
		rs.border_color = Color(0.3, 0.7, 0.3, 0.6); rs.set_border_width_all(1)
		row.add_theme_stylebox_override("panel", rs)
		var pad := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			pad.add_theme_constant_override("margin_" + s, 8)
		row.add_child(pad)
		var h := HBoxContainer.new(); h.add_theme_constant_override("separation", 12); pad.add_child(h)
		var col := VBoxContainer.new(); col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(col)
		col.add_child(Style.label(str(b.get("name", "Unknown")), 22))
		var idl := Style.label(str(b.get("id", "")), 14); idl.modulate = Color(1, 1, 1, 0.6)
		col.add_child(idl)
		var un := Style.button("UNBAN"); un.custom_minimum_size = Vector2(130, 40)
		var sid := str(b.get("id", ""))
		un.pressed.connect(func():
			if mod: mod.unban(sid)
			_rebuild()
		)
		h.add_child(un)
		return row

	func _unhandled_input(e: InputEvent) -> void:
		if e.is_action_pressed("ui_cancel"):
			queue_free(); get_viewport().set_input_as_handled()


# =============================================================================
#  Voice chat engine (Godot mic capture -> Steam P2P -> generator playback)
# =============================================================================

class VoiceChat:
	extends Node
	var mod
	const CHANNEL := 10           # raw voice PCM
	const CTRL_CHANNEL := 11      # host<->client management (kick/ban) as JSON
	const TARGET_RATE := 15000.0
	const BOOST_DB := 22.0        # playback gain so max slider is nice and loud
	const DEVICES_CFG := "user://machineparty_plus_voice.cfg"
	var _cap: AudioEffectCapture = null
	var _mic: AudioStreamPlayer = null
	var _bus := -1
	var _mix := 44100.0
	var _decim := 3
	var _pb := {}                 # sid(String) -> {player, pbk}
	var self_muted := false
	var deafened := false
	var _muted := {}              # sid -> bool
	var _vol := {}                # sid -> float

	func _ready() -> void:
		_mix = AudioServer.get_mix_rate()
		_decim = max(1, int(round(_mix / TARGET_RATE)))
		_setup_capture()
		_load_devices()
		if Steam.has_signal("p2p_session_request") and not Steam.p2p_session_request.is_connected(_on_p2p_req):
			Steam.p2p_session_request.connect(_on_p2p_req)

	func _setup_capture() -> void:
		_bus = AudioServer.bus_count
		AudioServer.add_bus(_bus)
		AudioServer.set_bus_name(_bus, "MPSB_Mic")
		AudioServer.set_bus_mute(_bus, true)     # capture without hearing yourself
		_cap = AudioEffectCapture.new()
		AudioServer.add_bus_effect(_bus, _cap)
		_mic = AudioStreamPlayer.new()
		_mic.stream = AudioStreamMicrophone.new()
		_mic.bus = "MPSB_Mic"
		add_child(_mic)
		_mic.play()

	func _process(_dt: float) -> void:
		if multiplayer == null or not multiplayer.has_multiplayer_peer():
			return
		_capture_send()
		_receive()
		_receive_ctrl()

	# Send a small JSON control message to one player over Steam P2P (reliable).
	func send_ctrl(steam_id: int, data: Dictionary) -> void:
		if steam_id == 0 or not Steam.has_method("sendP2PPacket"):
			return
		var bytes := JSON.stringify(data).to_utf8_buffer()
		Steam.sendP2PPacket(steam_id, bytes, 2, CTRL_CHANNEL)   # 2 = reliable

	func _receive_ctrl() -> void:
		if not Steam.has_method("getAvailableP2PPacketSize"):
			return
		var size := int(Steam.getAvailableP2PPacketSize(CTRL_CHANNEL))
		var guard := 0
		while size > 0 and guard < 32:
			guard += 1
			var pkt = Steam.readP2PPacket(size, CTRL_CHANNEL)
			if typeof(pkt) == TYPE_DICTIONARY and pkt.has("data"):
				var sender := int(pkt.get("steam_id_remote", pkt.get("remote_steam_id", 0)))
				var txt: String = (pkt["data"] as PackedByteArray).get_string_from_utf8()
				var d = JSON.parse_string(txt)
				if typeof(d) == TYPE_DICTIONARY and mod and mod.has_method("_on_control_packet"):
					mod._on_control_packet(sender, d)
			size = int(Steam.getAvailableP2PPacketSize(CTRL_CHANNEL))

	func _capture_send() -> void:
		if _cap == null:
			return
		var avail := _cap.get_frames_available()
		if avail <= 0:
			return
		var frames := _cap.get_buffer(avail)      # drains buffer
		if self_muted or deafened:
			return
		var pcm := PackedByteArray()
		var i := 0
		while i < frames.size():
			var f: Vector2 = frames[i]
			var s := clampf((f.x + f.y) * 0.5, -1.0, 1.0)
			var val := int(s * 32767.0)
			pcm.append(val & 0xFF)
			pcm.append((val >> 8) & 0xFF)
			i += _decim
		if pcm.is_empty() or not Steam.has_method("sendP2PPacket"):
			return
		for sid in mod.other_player_steam_ids():
			Steam.sendP2PPacket(sid, pcm, 0, CHANNEL)

	func _receive() -> void:
		if not Steam.has_method("getAvailableP2PPacketSize"):
			return
		var size := int(Steam.getAvailableP2PPacketSize(CHANNEL))
		var guard := 0
		while size > 0 and guard < 128:
			guard += 1
			var pkt = Steam.readP2PPacket(size, CHANNEL)
			if typeof(pkt) == TYPE_DICTIONARY and pkt.has("data"):
				var sender := int(pkt.get("steam_id_remote", pkt.get("remote_steam_id", 0)))
				_play(str(sender), pkt["data"])
			size = int(Steam.getAvailableP2PPacketSize(CHANNEL))

	func _play(sid: String, data: PackedByteArray) -> void:
		if deafened or _muted.get(sid, false):
			return
		var pbk = _get_pb(sid)
		if pbk == null:
			return
		var n := int(data.size() / 2)
		var i := 0
		while i < n:
			var lo := data[i * 2]
			var hi := data[i * 2 + 1]
			var val := (hi << 8) | lo
			if val >= 32768:
				val -= 65536
			var s := float(val) / 32767.0
			if pbk.can_push_buffer(1):
				pbk.push_frame(Vector2(s, s))
			i += 1

	func _get_pb(sid: String):
		if _pb.has(sid) and is_instance_valid(_pb[sid].player):
			return _pb[sid].pbk
		var p := AudioStreamPlayer.new()
		var g := AudioStreamGenerator.new()
		g.mix_rate = _mix / float(_decim)
		g.buffer_length = 0.25
		p.stream = g
		add_child(p)
		p.play()
		var pbk = p.get_stream_playback()
		p.volume_db = linear_to_db(clampf(_vol.get(sid, 1.0), 0.0001, 1.0)) + BOOST_DB
		_pb[sid] = {"player": p, "pbk": pbk}
		return pbk

	func _on_p2p_req(remote_id) -> void:
		if Steam.has_method("acceptP2PSessionWithUser"):
			Steam.acceptP2PSessionWithUser(remote_id)

	func set_self_muted(m: bool) -> void: self_muted = m
	func is_self_muted() -> bool: return self_muted
	func set_deafened(d: bool) -> void: deafened = d
	func is_deafened() -> bool: return deafened
	func set_player_muted(sid: String, m: bool) -> void: _muted[sid] = m
	func is_player_muted(sid: String) -> bool: return _muted.get(sid, false)
	func get_player_volume(sid: String) -> float: return _vol.get(sid, 1.0)
	func set_player_volume(sid: String, v: float) -> void:
		_vol[sid] = v
		if _pb.has(sid) and is_instance_valid(_pb[sid].player):
			_pb[sid].player.volume_db = linear_to_db(clampf(v, 0.0001, 1.0)) + BOOST_DB
	var _want_in := ""
	var _want_out := ""
	func input_devices() -> PackedStringArray: return AudioServer.get_input_device_list()
	func output_devices() -> PackedStringArray: return AudioServer.get_output_device_list()
	func set_input_device(n: String) -> void:
		_want_in = n
		AudioServer.input_device = n
		save_devices()
	func set_output_device(n: String) -> void:
		_want_out = n
		AudioServer.output_device = n
		save_devices()
	# Return the user's intent (AudioServer.output_device can silently revert to
	# "Default" when the name isn't applied yet, which is why output "wasn't saved").
	func get_input_device() -> String:
		return _want_in if _want_in != "" else AudioServer.input_device
	func get_output_device() -> String:
		return _want_out if _want_out != "" else AudioServer.output_device

	# Persist the user's CHOICE (not AudioServer's possibly-reverted value).
	func save_devices() -> void:
		var cfg := ConfigFile.new()
		cfg.set_value("voice", "input_device", _want_in)
		cfg.set_value("voice", "output_device", _want_out)
		cfg.save(DEVICES_CFG)

	func _load_devices() -> void:
		var cfg := ConfigFile.new()
		if cfg.load(DEVICES_CFG) != OK:
			return
		_want_in = cfg.get_value("voice", "input_device", "")
		_want_out = cfg.get_value("voice", "output_device", "")
		_apply_devices()
		# The OUTPUT device list isn't ready this early, so setting it now can be
		# ignored (that's why the speaker didn't restore). Re-apply a few times.
		if is_inside_tree():
			for delay in [0.5, 1.5, 3.0]:
				get_tree().create_timer(delay).timeout.connect(_apply_devices)

	func _apply_devices() -> void:
		if _want_in != "":
			AudioServer.input_device = _want_in
		if _want_out != "":
			AudioServer.output_device = _want_out


# =============================================================================
#  Voice HUD (top-right: mute / deafen in a session; settings live in the menu)
# =============================================================================

class VoiceHUD:
	extends CanvasLayer
	var mod
	var _mute: Button
	var _deafen: Button

	func _ready() -> void:
		layer = 45
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 6)
		v.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		v.offset_left = -230
		v.offset_right = -12
		v.offset_top = 12
		add_child(v)
		_mute = Style.button("MUTE MIC")
		_mute.size_flags_horizontal = Control.SIZE_SHRINK_END   # only as wide as its text
		_mute.pressed.connect(_toggle_mute)
		v.add_child(_mute)
		_deafen = Style.button("DEAFEN")
		_deafen.size_flags_horizontal = Control.SIZE_SHRINK_END
		_deafen.pressed.connect(_toggle_deafen)
		v.add_child(_deafen)
		set_process(true)

	func _process(_dt: float) -> void:
		var active: bool = multiplayer != null and multiplayer.has_multiplayer_peer()
		# in_lobby stays true in a match, so also require NOT in_game.
		var lobby_only: bool = GameManager.in_lobby and not GameManager.in_game
		var menu: bool = mod != null and mod._menu_open()
		# Float only in the lobby (hidden behind any menu). In a match, mute/deafen
		# live in the Esc menu instead.
		visible = active and lobby_only and not menu
		var vc = mod.voice() if mod else null
		if vc:
			var mt := "UNMUTE MIC" if vc.is_self_muted() else "MUTE MIC"
			var dt2 := "UNDEAFEN" if vc.is_deafened() else "DEAFEN"
			_mute.text = mod._t(mt) if mod else mt
			_deafen.text = mod._t(dt2) if mod else dt2

	func _toggle_mute() -> void:
		var vc = mod.voice() if mod else null
		if vc: vc.set_self_muted(not vc.is_self_muted())

	func _toggle_deafen() -> void:
		var vc = mod.voice() if mod else null
		if vc: vc.set_deafened(not vc.is_deafened())


# =============================================================================
#  Voice settings popup (pick mic input + speaker output)
# =============================================================================

class VoiceSettingsPanel:
	extends CanvasLayer
	var mod

	func _ready() -> void:
		layer = 62
		var center := Style.overlay(self, mod.modal_layer() if mod else 55)
		var win := Style.window(Vector2(520, 0))
		center.add_child(win)
		var m := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + s, 24)
		win.add_child(m)
		var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 14); m.add_child(v)
		var t := Style.label("VOICE CHAT SETTINGS", 30); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(t)
		var vc = mod.voice() if mod else null
		v.add_child(Style.label("MICROPHONE (INPUT)", 18))
		var inp := _make_option(vc.input_devices() if vc else PackedStringArray(), vc.get_input_device() if vc else "")
		inp.item_selected.connect(func(idx):
			if vc: vc.set_input_device(inp.get_item_text(idx))
		)
		v.add_child(inp)
		v.add_child(Style.label("SPEAKERS (OUTPUT)", 18))
		var outp := _make_option(vc.output_devices() if vc else PackedStringArray(), vc.get_output_device() if vc else "")
		outp.item_selected.connect(func(idx):
			if vc: vc.set_output_device(outp.get_item_text(idx))
		)
		v.add_child(outp)
		v.add_child(HSeparator.new())
		var close := Style.button("CLOSE"); close.custom_minimum_size = Vector2(0, 44)
		close.pressed.connect(queue_free)
		v.add_child(close)

	func _make_option(items: PackedStringArray, current: String) -> OptionButton:
		var ob := OptionButton.new()
		var f := Style.font()
		if f: ob.add_theme_font_override("font", f)
		var sel := 0
		for i in items.size():
			ob.add_item(items[i])
			if items[i] == current:
				sel = i
		if items.size() > 0:
			ob.select(sel)
		return ob


# =============================================================================
#  Mutation scoreboard - live per-match score + rounds won / lost
# -----------------------------------------------------------------------------
#  The game's own Game node (res://scripts/scenes/game/game.gd) is present on
#  every client during a match and holds `total_score_by_network_id` (the live
#  "mutation" score), kept in sync by the game. Mid-join players start at 0 and
#  rejoiners get their old score back - both handled by the base game, so we
#  just read the dictionary.
#
#  The game does NOT store rounds won/lost, so we derive them: each time totals
#  fold in at the end of a minigame we credit a win to the biggest gainer and a
#  loss to everyone else present. Tracking is keyed by Steam id and lives only
#  for the current match (cleared when a new Game node appears).
# =============================================================================

class MatchScore:
	extends Node
	var mod
	const GAME_SCRIPT := "res://scripts/scenes/game/game.gd"
	var _game: Node = null
	var _snap := {}       # steam_id(String) -> last total score seen
	var _won := {}        # steam_id -> int
	var _lost := {}       # steam_id -> int
	var _poll := 0.0

	func _process(dt: float) -> void:
		_poll += dt
		if _poll < 0.4:
			return
		_poll = 0.0
		var g := _find_game()
		if g == null:
			_game = null
			return
		if g != _game:
			# a fresh match -> per-match data resets
			_game = g
			_won.clear()
			_lost.clear()
			_snap = _totals(g)
			return
		_tick(g)

	func has_game() -> bool:
		return is_instance_valid(_game)

	func _find_game() -> Node:
		if is_instance_valid(_game):
			return _game
		return _search(get_tree().root)

	# Find the match controller by DUCK-TYPING: the node that owns a
	# `total_score_by_network_id` dictionary. This avoids depending on the exact
	# script path (which can differ once the game is exported/remapped, and was
	# why the board showed nothing).
	func _search(n: Node) -> Node:
		var d = n.get("total_score_by_network_id")
		if typeof(d) == TYPE_DICTIONARY:
			return n
		for c in n.get_children():
			var r := _search(c)
			if r != null:
				return r
		return null

	func _totals(g: Node) -> Dictionary:
		var out := {}
		var d = g.get("total_score_by_network_id")
		if typeof(d) != TYPE_DICTIONARY:
			return out
		for net_id in d.keys():
			var sid: String = mod._steam_id_for(net_id)
			out[sid] = int(d[net_id])
		return out

	func _tick(g: Node) -> void:
		var tot := _totals(g)
		# A minigame concludes when totals fold in (a positive change). Credit the
		# biggest gainer with a win and everyone else present with a loss. Players
		# missing from the previous snapshot (just joined or rejoined) are skipped
		# this tick and only re-baselined, so a rejoin score restore is never
		# mistaken for a round result.
		var present := []
		var best := 0
		for sid in tot.keys():
			if _snap.has(sid):
				var delta: int = int(tot[sid]) - int(_snap[sid])
				present.append([sid, delta])
				if delta > best:
					best = delta
		if best > 0 and present.size() >= 2:
			for pair in present:
				var psid: String = pair[0]
				var pdelta: int = pair[1]
				if pdelta == best:
					_won[psid] = int(_won.get(psid, 0)) + 1
				else:
					_lost[psid] = int(_lost.get(psid, 0)) + 1
		_snap = tot

	func won(sid: String) -> int: return int(_won.get(sid, 0))
	func lost(sid: String) -> int: return int(_lost.get(sid, 0))

	# Rows for the HUD: [{name, score, won, lost}] sorted by score desc.
	func rows() -> Array:
		var g := _find_game()
		var out := []
		var d = null
		if g != null:
			d = g.get("total_score_by_network_id")
		if typeof(d) == TYPE_DICTIONARY and not (d as Dictionary).is_empty():
			for net_id in d.keys():
				var sid: String = mod._steam_id_for(net_id)
				out.append({
					"name": mod._name_for(net_id),
					"score": int(d[net_id]),
					"won": won(sid),
					"lost": lost(sid),
				})
		else:
			# Fallback: no score node yet - at least list the players in the match.
			if NetworkManager and NetworkManager.active_backend:
				for net_id in NetworkManager.active_backend.connected_players.keys():
					var sid: String = mod._steam_id_for(net_id)
					out.append({
						"name": mod._name_for(net_id),
						"score": 0,
						"won": won(sid),
						"lost": lost(sid),
					})
		out.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
		return out


# =============================================================================
#  Scoreboard HUD - hold Tab in a match to view it (never grabs the mouse)
# =============================================================================

class ScoreboardHUD:
	extends CanvasLayer
	var mod
	var _panel: PanelContainer
	var _rows_box: VBoxContainer
	var _shown := false
	var _refresh := 0.0

	func _ready() -> void:
		layer = 100                     # above the game's in-match UI
		var center := CenterContainer.new()
		center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(center)
		_panel = Style.window(Vector2(620, 0))
		_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		center.add_child(_panel)
		var m := MarginContainer.new()
		for s in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + s, 22)
		_panel.add_child(m)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 10)
		m.add_child(v)
		var title := Style.label("MUTATION SCOREBOARD", 30)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(title)
		v.add_child(_make_row(["PLAYER", "MUTATION", "WON", "LOST"], true))
		_rows_box = VBoxContainer.new()
		_rows_box.add_theme_constant_override("separation", 6)
		v.add_child(_rows_box)
		if mod: mod._localize_tree(_panel)
		visible = false
		set_process(true)

	func _in_match() -> bool:
		# in_game is set true by the game's own match controller (game.gd), so it's
		# the most reliable "a match is running" signal.
		if GameManager.in_game:
			return true
		return mod != null and mod.match_score() != null and mod.match_score().has_game()

	func _tab_held() -> bool:
		return Input.is_key_pressed(KEY_TAB) or Input.is_physical_key_pressed(KEY_TAB)

	func _process(dt: float) -> void:
		var want: bool = _in_match() and _tab_held()
		if want != _shown:
			_shown = want
			visible = want
			if want:
				_rebuild()
				if mod and mod._loader:
					var n := 0
					if mod.match_score(): n = mod.match_score().rows().size()
					mod._loader.note("scoreboard: shown (in_game=%s, has_game=%s, rows=%d)" % [
						str(GameManager.in_game), str(mod.match_score() != null and mod.match_score().has_game()), n])
		if want:
			_refresh += dt
			if _refresh >= 0.25:
				_refresh = 0.0
				_rebuild()

	func _rebuild() -> void:
		for c in _rows_box.get_children():
			c.queue_free()
		if mod == null or mod.match_score() == null:
			return
		var rows: Array = mod.match_score().rows()
		if rows.is_empty():
			_rows_box.add_child(Style.label(mod._t("Waiting for scores..."), 18))
			return
		for r in rows:
			_rows_box.add_child(_make_row([
				str(r.get("name", "Player")),
				str(r.get("score", 0)),
				str(r.get("won", 0)),
				str(r.get("lost", 0)),
			], false))

	# One boxed row (header or data). Columns: player | mutation | won | lost.
	func _make_row(cols: Array, header: bool) -> Control:
		var box := PanelContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_theme_stylebox_override("panel", _row_style(header))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 12)
		box.add_child(h)
		var widths := [250, 140, 70, 70]
		var aligns := [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_CENTER]
		for i in cols.size():
			var l := Style.label(str(cols[i]), 20 if header else 22)
			l.custom_minimum_size = Vector2(widths[i], 0)
			l.horizontal_alignment = aligns[i]
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if header:
				l.add_theme_color_override("font_color", Color(0.45, 0.85, 0.45))
			h.add_child(l)
		return box

	func _row_style(header: bool) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0.05, 0.12, 0.05, 0.55) if header else Color(0.02, 0.06, 0.02, 0.45)
		s.border_color = Style.HACK_GREEN if header else Color(0.3, 0.6, 0.3)
		s.set_border_width_all(1)
		s.content_margin_left = 12
		s.content_margin_right = 12
		s.content_margin_top = 6
		s.content_margin_bottom = 6
		return s


# =============================================================================
#  Lobby tools - a small strip on the left, LOBBY only. The buttons are cloned
#  from a real lobby button (like Make Lobby Public) so they match exactly, just
#  smaller. Manage Players for everyone; Banned Users for the host. In a match
#  these move to the Esc menu instead.
# =============================================================================

class LobbyTools:
	extends CanvasLayer
	var mod
	var _box: VBoxContainer
	var _manage = null
	var _banned = null

	func _ready() -> void:
		layer = 46
		_box = VBoxContainer.new()
		_box.add_theme_constant_override("separation", 6)
		_box.set_anchors_preset(Control.PRESET_CENTER_LEFT)
		_box.offset_left = 18
		_box.grow_vertical = Control.GROW_DIRECTION_BOTH
		add_child(_box)
		set_process(true)

	# (Re)build the strip from a native lobby button so it matches the game.
	func rebuild(template) -> void:
		for c in _box.get_children():
			c.queue_free()
		_manage = null
		_banned = null
		if not is_instance_valid(template):
			return
		_manage = _clone(template, "Manage Players", _open_manage)
		_banned = _clone(template, "Banned Users", _open_banned)

	func _clone(template, label: String, cb: Callable):
		var b = template.duplicate()
		b.name = "MPSB_Side_" + label.replace(" ", "")
		b.disabled = false
		b.visible = true
		if mod: mod._set_button_label(b, label, true)   # caps, matching lobby buttons
		for conn in b.pressed.get_connections():
			b.pressed.disconnect(conn["callable"])
		b.add_theme_font_size_override("font_size", 16)   # smaller than the row
		b.custom_minimum_size = Vector2(0, 0)
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.focus_mode = Control.FOCUS_NONE
		b.modulate = Color(1, 1, 1, 1)
		b.pressed.connect(cb)
		_box.add_child(b)
		return b

	func _process(_dt: float) -> void:
		var host: bool = multiplayer != null and multiplayer.has_multiplayer_peer() and multiplayer.is_server()
		# in_lobby isn't reset when a match starts, so also require NOT in_game.
		var lobby_only: bool = GameManager.in_lobby and not GameManager.in_game
		var menu: bool = mod != null and mod._menu_open()
		visible = lobby_only and not menu      # lobby only; hidden behind any menu
		if is_instance_valid(_manage):
			_manage.visible = true             # everyone can mute/volume
		if is_instance_valid(_banned):
			_banned.visible = host             # bans are host-only

	func _open_banned() -> void:
		if mod: mod._open_banned_users()

	func _open_manage() -> void:
		if mod: mod._open_manage_players()


# Drives our pause-menu buttons: Manage (everyone), Banned (host), Mute/Deafen.
class PauseExtrasController:
	extends Node
	var mod
	var manage = null
	var banned = null
	var mute = null
	var deafen = null
	var _lm := -1
	var _ld := -1

	func _ready() -> void:
		set_process(true)

	func _process(_dt: float) -> void:
		var host: bool = multiplayer != null and multiplayer.has_multiplayer_peer() and multiplayer.is_server()
		var in_game: bool = GameManager.in_game
		if is_instance_valid(manage):
			manage.visible = in_game
		if is_instance_valid(banned):
			banned.visible = in_game and host
		var vc = mod.voice() if mod else null
		if is_instance_valid(mute):
			mute.visible = in_game
			if vc:
				var m := 1 if vc.is_self_muted() else 0
				if m != _lm:
					_lm = m
					mod._set_button_label(mute, "Unmute Mic" if m == 1 else "Mute Mic")
		if is_instance_valid(deafen):
			deafen.visible = in_game
			if vc:
				var d := 1 if vc.is_deafened() else 0
				if d != _ld:
					_ld = d
					mod._set_button_label(deafen, "Undeafen" if d == 1 else "Deafen")


# =============================================================================
#  Arabic translation - merged in, OFF by default. Adds العربية to the language
#  menu; only when the player picks it does anything change. Keeps every label's
#  styling (font-fallback approach) and forces LTR so the screen is not mirrored.
# =============================================================================

class Arabic:
	extends Node
	var mod
	var ar_json_path := ""
	const LOCALE := "ar"
	const AR_LABEL := "العربية"
	const AR_BTN_NAME := "MPSB_ArabicLang"
	const LANG_HANDLER := "res://scenes/main_menu/scripts/language_handler.gd"
	const GAME_FONTS := [
		"res://fonts/whitrabt.ttf", "res://fonts/Terminal F4.ttf",
		"res://fonts/Hack-Regular.ttf", "res://fonts/alarm clock.ttf",
	]
	const ARABIC_FONTS := [
		"Segoe UI", "Tahoma", "Arial", "Simplified Arabic", "Sakkal Majalla", "Noto Sans Arabic",
	]

	func _ready() -> void:
		_register_translation()
		_add_font_fallback()
		get_tree().node_added.connect(_on_node_added)
		call_deferred("_scan", get_tree().root)
		var g = get_node_or_null("/root/Globals")
		if g and g.has_signal("locale_changed") and not g.locale_changed.is_connected(_on_locale_changed):
			g.locale_changed.connect(_on_locale_changed)

	func _is_arabic() -> bool:
		return TranslationServer.get_locale().begins_with("ar")

	func _on_locale_changed() -> void:
		if _is_arabic():
			_force_ltr(get_tree().root)

	func _scan(node) -> void:
		_on_node_added(node)
		for c in node.get_children():
			_scan(c)

	func _on_node_added(node) -> void:
		# Arabic is RTL, which makes Godot mirror the whole layout. We want Arabic
		# text but a normal (LTR) layout, so pin every control to LTR while Arabic
		# is active. Per-label RTL shaping is separate and stays correct.
		if _is_arabic() and node is Control:
			node.layout_direction = Control.LAYOUT_DIRECTION_LTR
		var s = node.get_script()
		if s != null and s.resource_path == LANG_HANDLER:
			_inject_arabic(node)

	func _force_ltr(node) -> void:
		if node is Control:
			node.layout_direction = Control.LAYOUT_DIRECTION_LTR
		for c in node.get_children():
			_force_ltr(c)

	func _register_translation() -> void:
		if ar_json_path == "" or not FileAccess.file_exists(ar_json_path):
			if mod and mod._loader: mod._loader.note("arabic: ar.json not found at " + ar_json_path)
			return
		var data = JSON.parse_string(FileAccess.get_file_as_string(ar_json_path))
		if typeof(data) != TYPE_DICTIONARY:
			return
		var t := Translation.new()
		t.locale = LOCALE
		var count := 0
		for key in data.keys():
			var entry = data[key]
			var ar := ""
			if typeof(entry) == TYPE_DICTIONARY:
				ar = str(entry.get("ar", ""))
			else:
				ar = str(entry)
			if ar != "":
				t.add_message(key, ar)
				count += 1
		TranslationServer.add_translation(t)
		if mod and mod._loader: mod._loader.note("arabic: registered %d strings" % count)

	func _add_font_fallback() -> void:
		var arf := SystemFont.new()
		arf.font_names = PackedStringArray(ARABIC_FONTS)
		arf.allow_system_fallback = true
		for path in GAME_FONTS:
			if not ResourceLoader.exists(path):
				continue
			var f = load(path)
			if f is FontFile:
				var fbs: Array = f.fallbacks
				var has_sys := false
				for e in fbs:
					if e is SystemFont:
						has_sys = true
						break
				if not has_sys:
					fbs.append(arf)
					f.fallbacks = fbs

	func _inject_arabic(handler) -> void:
		if not is_instance_valid(handler):
			return
		var vbox = handler.get("language_list_vbox")
		if vbox == null or not is_instance_valid(vbox):
			return
		# the language list is populated asynchronously; wait until it settles
		var last := -1
		for i in range(240):
			await get_tree().process_frame
			if not is_instance_valid(vbox):
				return
			if vbox.has_node(AR_BTN_NAME):
				return
			var n: int = vbox.get_child_count()
			if n > 0 and n == last:
				break
			last = n
		if not is_instance_valid(vbox) or vbox.has_node(AR_BTN_NAME):
			return
		var kids = vbox.get_children()
		if kids.is_empty():
			return
		# duplicate a real language button so font / theme / sounds match exactly
		var btn = kids[0].duplicate()
		btn.name = AR_BTN_NAME
		btn.text = AR_LABEL
		if "lang" in btn:
			btn.lang = LOCALE
		btn.modulate.a = 1.0
		vbox.add_child(btn)
		if btn.has_signal("language_button_pressed") and handler.has_method("_on_language_button_pressed"):
			if not btn.language_button_pressed.is_connected(handler._on_language_button_pressed):
				btn.language_button_pressed.connect(handler._on_language_button_pressed)
		if mod and mod._loader: mod._loader.note("arabic: language option injected")


# =============================================================================
#  Lithuanian translation - merged in, OFF by default. Adds "Lietuvių" to the
#  language menu; only when the player picks it does anything change. Lithuanian
#  is a left-to-right, Latin-script language, so (unlike Arabic) no layout
#  mirroring is needed. We register a "lt" Translation for every LOC key from
#  lt.json and add a system-font fallback so Lithuanian diacritics (ą č ę ė į š
#  ų ū ž) always render even if a game font lacks those glyphs.
# =============================================================================

class Lithuanian:
	extends Node
	var mod
	var lt_json_path := ""
	const LOCALE := "lt"
	const LT_LABEL := "Lietuvių"
	const LT_BTN_NAME := "MPSB_LithuanianLang"
	const LANG_HANDLER := "res://scenes/main_menu/scripts/language_handler.gd"
	const GAME_FONTS := [
		"res://fonts/whitrabt.ttf", "res://fonts/Terminal F4.ttf",
		"res://fonts/Hack-Regular.ttf", "res://fonts/alarm clock.ttf",
	]
	# Fonts with full Lithuanian coverage; allow_system_fallback picks whatever the
	# OS has if none of these are installed.
	const LT_FONTS := [
		"Noto Sans", "Segoe UI", "Arial", "Tahoma", "DejaVu Sans",
	]

	func _ready() -> void:
		_register_translation()
		_add_font_fallback()
		get_tree().node_added.connect(_on_node_added)
		call_deferred("_scan", get_tree().root)

	func _scan(node) -> void:
		_on_node_added(node)
		for c in node.get_children():
			_scan(c)

	func _on_node_added(node) -> void:
		var s = node.get_script()
		if s != null and s.resource_path == LANG_HANDLER:
			_inject_lithuanian(node)

	func _register_translation() -> void:
		if lt_json_path == "" or not FileAccess.file_exists(lt_json_path):
			if mod and mod._loader: mod._loader.note("lithuanian: lt.json not found at " + lt_json_path)
			return
		var data = JSON.parse_string(FileAccess.get_file_as_string(lt_json_path))
		if typeof(data) != TYPE_DICTIONARY:
			return
		var t := Translation.new()
		t.locale = LOCALE
		var count := 0
		for key in data.keys():
			var entry = data[key]
			var lt := ""
			if typeof(entry) == TYPE_DICTIONARY:
				lt = str(entry.get("lt", ""))
			else:
				lt = str(entry)
			if lt != "":
				t.add_message(key, lt)
				count += 1
		TranslationServer.add_translation(t)
		if mod and mod._loader: mod._loader.note("lithuanian: registered %d strings" % count)

	func _add_font_fallback() -> void:
		var ltf := SystemFont.new()
		ltf.font_names = PackedStringArray(LT_FONTS)
		ltf.allow_system_fallback = true
		for path in GAME_FONTS:
			if not ResourceLoader.exists(path):
				continue
			var f = load(path)
			if f is FontFile:
				var fbs: Array = f.fallbacks
				var has_sys := false
				for e in fbs:
					if e is SystemFont:
						has_sys = true
						break
				if not has_sys:
					fbs.append(ltf)
					f.fallbacks = fbs

	func _inject_lithuanian(handler) -> void:
		if not is_instance_valid(handler):
			return
		var vbox = handler.get("language_list_vbox")
		if vbox == null or not is_instance_valid(vbox):
			return
		# the language list is populated asynchronously; wait until it settles
		var last := -1
		for i in range(240):
			await get_tree().process_frame
			if not is_instance_valid(vbox):
				return
			if vbox.has_node(LT_BTN_NAME):
				return
			var n: int = vbox.get_child_count()
			if n > 0 and n == last:
				break
			last = n
		if not is_instance_valid(vbox) or vbox.has_node(LT_BTN_NAME):
			return
		var kids = vbox.get_children()
		if kids.is_empty():
			return
		# duplicate a real language button so font / theme / sounds match exactly
		var btn = kids[0].duplicate()
		btn.name = LT_BTN_NAME
		btn.text = LT_LABEL
		if "lang" in btn:
			btn.lang = LOCALE
		btn.modulate.a = 1.0
		vbox.add_child(btn)
		if btn.has_signal("language_button_pressed") and handler.has_method("_on_language_button_pressed"):
			if not btn.language_button_pressed.is_connected(handler._on_language_button_pressed):
				btn.language_button_pressed.connect(handler._on_language_button_pressed)
		if mod and mod._loader: mod._loader.note("lithuanian: language option injected")


# =============================================================================
#  Serbian translation - merged in, OFF by default. Serbian is digraphic, so we
#  add BOTH scripts as separate options: "Српски" (Cyrillic, locale sr) and
#  "Srpski" (Latin, locale sr_Latn). Both are registered from sr.json (fields
#  "sr" = Cyrillic, "srl" = Latin, a deterministic transliteration). Latin uses
#  the same glyphs as the game fonts; the system-font fallback added below also
#  covers the Cyrillic script (ђ ј љ њ ћ џ).
# =============================================================================

class Serbian:
	extends Node
	var mod
	var sr_json_path := ""
	const LOCALE_CYR := "sr"
	const LOCALE_LAT := "sr_Latn"
	const LABEL_CYR := "Српски"
	const LABEL_LAT := "Srpski"
	const BTN_CYR := "MPSB_SerbianCyrLang"
	const BTN_LAT := "MPSB_SerbianLatLang"
	const LANG_HANDLER := "res://scenes/main_menu/scripts/language_handler.gd"
	const GAME_FONTS := [
		"res://fonts/whitrabt.ttf", "res://fonts/Terminal F4.ttf",
		"res://fonts/Hack-Regular.ttf", "res://fonts/alarm clock.ttf",
	]
	# Fonts covering Serbian Cyrillic + Latin; allow_system_fallback picks whatever
	# the OS has if none are installed.
	const SR_FONTS := [
		"Noto Sans", "Segoe UI", "Arial", "Tahoma", "DejaVu Sans",
	]

	func _ready() -> void:
		_register_translations()
		_add_font_fallback()
		get_tree().node_added.connect(_on_node_added)
		call_deferred("_scan", get_tree().root)

	func _scan(node) -> void:
		_on_node_added(node)
		for c in node.get_children():
			_scan(c)

	func _on_node_added(node) -> void:
		var s = node.get_script()
		if s != null and s.resource_path == LANG_HANDLER:
			_inject_serbian(node)

	func _register_translations() -> void:
		if sr_json_path == "" or not FileAccess.file_exists(sr_json_path):
			if mod and mod._loader: mod._loader.note("serbian: sr.json not found at " + sr_json_path)
			return
		var data = JSON.parse_string(FileAccess.get_file_as_string(sr_json_path))
		if typeof(data) != TYPE_DICTIONARY:
			return
		var t_cyr := Translation.new(); t_cyr.locale = LOCALE_CYR
		var t_lat := Translation.new(); t_lat.locale = LOCALE_LAT
		var count := 0
		for key in data.keys():
			var entry = data[key]
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var cyr := str(entry.get("sr", ""))
			var lat := str(entry.get("srl", ""))
			if cyr != "": t_cyr.add_message(key, cyr)
			if lat != "": t_lat.add_message(key, lat)
			count += 1
		TranslationServer.add_translation(t_cyr)
		TranslationServer.add_translation(t_lat)
		if mod and mod._loader: mod._loader.note("serbian: registered %d strings (Cyrillic + Latin)" % count)

	func _add_font_fallback() -> void:
		var srf := SystemFont.new()
		srf.font_names = PackedStringArray(SR_FONTS)
		srf.allow_system_fallback = true
		for path in GAME_FONTS:
			if not ResourceLoader.exists(path):
				continue
			var f = load(path)
			if f is FontFile:
				var fbs: Array = f.fallbacks
				var has_sys := false
				for e in fbs:
					if e is SystemFont:
						has_sys = true
						break
				if not has_sys:
					fbs.append(srf)
					f.fallbacks = fbs

	func _inject_serbian(handler) -> void:
		if not is_instance_valid(handler):
			return
		var vbox = handler.get("language_list_vbox")
		if vbox == null or not is_instance_valid(vbox):
			return
		# the language list is populated asynchronously; wait until it settles
		var last := -1
		for i in range(240):
			await get_tree().process_frame
			if not is_instance_valid(vbox):
				return
			if vbox.has_node(BTN_CYR):
				return
			var n: int = vbox.get_child_count()
			if n > 0 and n == last:
				break
			last = n
		if not is_instance_valid(vbox) or vbox.has_node(BTN_CYR):
			return
		_add_button(vbox, handler, BTN_CYR, LABEL_CYR, LOCALE_CYR)
		_add_button(vbox, handler, BTN_LAT, LABEL_LAT, LOCALE_LAT)
		if mod and mod._loader: mod._loader.note("serbian: language options injected (Српски + Srpski)")

	func _add_button(vbox, handler, node_name: String, label: String, locale: String) -> void:
		if not is_instance_valid(vbox) or vbox.has_node(node_name):
			return
		var kids = vbox.get_children()
		if kids.is_empty():
			return
		# duplicate a real language button so font / theme / sounds match exactly
		var btn = kids[0].duplicate()
		btn.name = node_name
		btn.text = label
		if "lang" in btn:
			btn.lang = locale
		btn.modulate.a = 1.0
		vbox.add_child(btn)
		if btn.has_signal("language_button_pressed") and handler.has_method("_on_language_button_pressed"):
			if not btn.language_button_pressed.is_connected(handler._on_language_button_pressed):
				btn.language_button_pressed.connect(handler._on_language_button_pressed)
