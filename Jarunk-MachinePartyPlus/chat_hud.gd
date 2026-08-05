extends CanvasLayer

const SETTINGS_PATH := "user://machineparty_plus_chat.cfg"
const THEME_PATH := "res://themes/main_menu_theme.tres"
const HACK_GREEN := Color(0.55, 1.0, 0.55)
const FEED_LIFETIME := 8.0
const FEED_MAX_LINES := 6
const LOG_MAX_ROWS := 200

# The shared menu theme defaults Button/Label (and tooltips, which fall back
# to Label) to a 32px font sized for full-screen menus. At chat-log scale
# that renders every button and tooltip absurdly oversized, so we run a
# smaller copy of it instead of the raw shared resource.
const UI_FONT_SIZE := 11
const TITLE_FONT_SIZE := 13

const ICON_CLOSE := "×"
const ICON_SETTINGS := "≡"
const ICON_MUTE := "⊘"
const ICON_UNMUTE := "↺"
const SYSTEM_COLOR := "#7fa87f"

# Root words. The matcher (see _get_regex) already handles repeats ("fuuuck"),
# leetspeak ("f0ck"), spacing ("f u c k") and trailing padding ("fuckasdf"), so
# we only list roots here, not every conjugation.
const BAD_WORDS: PackedStringArray = [
	"fuck", "motherfucker", "fuckhead", "shit", "bullshit", "bitch",
	"asshole", "ass", "arse", "arsehole", "bastard", "cunt", "dick", "dickhead",
	"piss", "slut", "whore", "faggot", "fag", "nigger", "nigga",
	"retard", "cock", "pussy", "douche", "twat", "wanker", "wank", "prick",
	"bollocks", "bugger", "jackass", "dumbass", "cum", "jizz", "dildo", "boner",
	"spastic", "chink", "spic", "kike", "gook", "wetback", "beaner", "tranny",
	"dyke", "paki", "raghead", "handjob", "blowjob", "nutsack",
]

# Innocent words that START with a bad root (or contain it via the fuzzy match).
# We never censor these. Compared after normalizing (lowercase + de-leet).
const WHITELIST: PackedStringArray = [
	"assassin", "assassinate", "assassination", "assault", "assemble", "assembly",
	"assert", "assertion", "assess", "assessment", "asset", "assets", "assign",
	"assignment", "assimilate", "assist", "assistant", "assistance", "associate",
	"association", "assort", "assortment", "assume", "assumption", "assure",
	"assurance", "assuage", "assay",
	"cockpit", "cocktail", "cockroach", "cockney", "cockatoo", "cockatiel",
	"cockle", "cocker", "cocky",
	"cumulative", "cumulus", "cumin", "cumbersome", "cumberland", "cumbria",
	"dickens", "dickinson", "dicker",
	"spice", "spicy", "spicier", "spiciest", "spick",
	"shiitake",
	"arsenal", "arsenic", "arsenide",
	"prickle", "prickly", "prickles",
]

var chat_manager
var mp_mod = null                 # MachineParty+ main mod, for shared localization

var _filter_enabled := true
var _muted_steam_ids: Array = []
var _custom_words: Array = []
var _expanded := false
var _session_active := false
var _roster_synced := false
var _known_peer_ids: Dictionary = {}
var _prev_mouse_mode := Input.MOUSE_MODE_VISIBLE

var _feed_panel: Control
var _feed_label: RichTextLabel
var _feed_lines: Array = []
var _feed_timer := 0.0

var _window: Control
var _settings_panel: Control
var _log_container: VBoxContainer
var _scroll: ScrollContainer
var _input: LineEdit


func _tr(s: String) -> String:
	return mp_mod._t(s) if mp_mod else s


# Re-apply the current game language to the whole chat UI (called on language
# change). Reversible thanks to the mod's metadata-based localizer.
func relocalize() -> void:
	if mp_mod:
		mp_mod._localize_tree(self)


func _ready() -> void:
	layer = 40
	_load_settings()
	_build_ui()
	relocalize()
	if is_instance_valid(chat_manager):
		chat_manager.message_received.connect(_on_message_received)
		chat_manager.notice_received.connect(_on_notice_received)
		chat_manager.history_received.connect(_on_history_received)
	NetworkManager.on_peer_connected.connect(_on_peer_connected)
	NetworkManager.on_peer_disconnected.connect(_on_peer_disconnected)
	# Joining a lobby delivers the whole existing roster as a burst of
	# on_peer_connected events (that's how we learn who's already there) —
	# join_allowed only fires once that catch-up is done, so anything after
	# it is a real, individual join worth announcing. Hosting has no such
	# burst, so on_server_created marks it synced immediately.
	NetworkManager.on_server_created.connect(_on_roster_synced)
	NetworkManager.join_allowed.connect(func(_reconnect: bool, _game_in_progress: bool, _debug_only: bool): _on_roster_synced())


func _process(delta: float) -> void:
	_check_session_state()

	if _expanded or _feed_timer <= 0.0:
		return
	_feed_timer -= delta
	if _feed_timer <= 0.0:
		_feed_panel.visible = false


# ---------------------------------------------------------------- session

func _check_session_state() -> void:
	var active: bool = GameManager.in_lobby or GameManager.in_game
	if active == _session_active:
		return
	_session_active = active
	if active:
		_roster_synced = false
		_known_peer_ids.clear()
	if not active and _expanded:
		_collapse()
	_clear_all(true)


func _on_roster_synced() -> void:
	_roster_synced = true


# ---------------------------------------------------------------- settings

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	_filter_enabled = cfg.get_value("chat", "filter_enabled", true)
	_muted_steam_ids = cfg.get_value("chat", "muted_steam_ids", [])
	_custom_words = cfg.get_value("chat", "custom_words", [])


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("chat", "filter_enabled", _filter_enabled)
	cfg.set_value("chat", "muted_steam_ids", _muted_steam_ids)
	cfg.set_value("chat", "custom_words", _custom_words)
	cfg.save(SETTINGS_PATH)


# ---------------------------------------------------------------- filter

func _filter_text(text: String) -> String:
	var result := _apply_word_list(text, BAD_WORDS)
	if not _custom_words.is_empty():
		var extras := PackedStringArray()
		for w in _custom_words:
			extras.append(String(w))
		result = _apply_word_list(result, extras)
	return result


var _re_cache := {}
var _wl := {}                          # whitelist as a set for O(1) lookup

func _apply_word_list(text: String, words: PackedStringArray) -> String:
	if _wl.is_empty():
		for w in WHITELIST:
			_wl[String(w)] = true
	var result := text
	for w in words:
		var word := String(w).strip_edges().to_lower()
		if word.length() < 3:              # skip 1-2 letter words (false positives)
			continue
		var re = _get_regex(word)
		if re == null:
			continue
		var matches: Array = re.search_all(result)
		# Back-to-front so earlier indices stay valid.
		for i in range(matches.size() - 1, -1, -1):
			var m: RegExMatch = matches[i]
			var s := m.get_start()
			var e := m.get_end()
			# Extend over trailing letters/digits so "fuckasdf" censors the whole
			# token, then skip it if that whole word is on the whitelist.
			while e < result.length() and _is_wordish(result[e]):
				e += 1
			var token := result.substr(s, e - s)
			if _wl.has(_norm(token)):
				continue
			result = result.substr(0, s) + "*".repeat(e - s) + result.substr(e)
	return result


func _is_wordish(c: String) -> bool:
	# letter (case differs) or digit
	return c.to_upper() != c.to_lower() or (c >= "0" and c <= "9")


# Normalize a token for whitelist comparison: lowercase, de-leet, letters only.
func _norm(s: String) -> String:
	s = s.to_lower()
	var leet := {"@":"a","4":"a","8":"b","3":"e","1":"i","!":"i","|":"i","0":"o","$":"s","5":"s","7":"t","(":"c","9":"g"}
	var out := ""
	for ch in s:
		if leet.has(ch):
			ch = leet[ch]
		if ch.to_upper() != ch.to_lower():   # keep letters only
			out += ch
	return out


# Build a fuzzy matcher for one bad word: each letter may repeat (catches
# "shiiit"/"fuckk"), accepts common leet swaps (sh1t, @ss), tolerates a little
# punctuation/spacing between letters (f.u.c.k), and allows trailing padding
# (fuckasdf). A leading word-boundary keeps it from firing inside words like
# "class"; the whitelist handles words that START with a root ("assassin").
func _get_regex(word: String):
	if _re_cache.has(word):
		return _re_cache[word]
	var parts := PackedStringArray()
	for i in word.length():
		parts.append(_leet_class(word[i]) + "+")
	var sep := "[\\s._\\-*]{0,2}"
	var pat := "(?i)(?<![a-zA-Z0-9])" + sep.join(parts)
	var re := RegEx.new()
	var out = re if re.compile(pat) == OK else null
	_re_cache[word] = out
	return out


func _leet_class(c: String) -> String:
	match c:
		"a": return "[a@4]"
		"b": return "[b8]"
		"c": return "[c(]"
		"e": return "[e3]"
		"g": return "[g69]"
		"i": return "[i1!|]"
		"l": return "[l1|]"
		"o": return "[o0]"
		"s": return "[s$5]"
		"t": return "[t7]"
		"u": return "[uv]"
		"z": return "[z2]"
		_: return c


# ---------------------------------------------------------------- ui build

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(THEME_PATH):
		var base_theme: Theme = load(THEME_PATH)
		var mod_theme: Theme = base_theme.duplicate() as Theme
		mod_theme.set_font_size("font_size", "Button", UI_FONT_SIZE)
		mod_theme.set_font_size("font_size", "Label", UI_FONT_SIZE)
		mod_theme.set_font_size("font_size", "CheckButton", UI_FONT_SIZE)
		mod_theme.set_font_size("font_size", "TooltipLabel", UI_FONT_SIZE - 1)
		root.theme = mod_theme
	add_child(root)

	# Anchored as a fraction of the viewport (not fixed pixels) so the window
	# scales with resolution instead of being a fixed pixel size.
	_feed_panel = PanelContainer.new()
	_feed_panel.anchor_left = 0
	_feed_panel.anchor_top = 0
	_feed_panel.anchor_right = 0.5
	_feed_panel.anchor_bottom = 0.17
	_feed_panel.offset_left = 16
	_feed_panel.offset_top = 16
	_feed_panel.offset_right = -8
	_feed_panel.offset_bottom = -8
	_feed_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed_panel.clip_contents = true
	var feed_style := StyleBoxFlat.new()
	feed_style.bg_color = Color(0, 0, 0, 0.35)
	feed_style.content_margin_left = 10
	feed_style.content_margin_right = 10
	feed_style.content_margin_top = 6
	feed_style.content_margin_bottom = 6
	_feed_panel.add_theme_stylebox_override("panel", feed_style)
	_feed_panel.visible = false
	root.add_child(_feed_panel)

	# Top-down: oldest line at top, newest at bottom, packed from the top of
	# the panel instead of hugging its bottom edge.
	var feed_vbox := VBoxContainer.new()
	feed_vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	feed_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed_panel.add_child(feed_vbox)

	_feed_label = RichTextLabel.new()
	_feed_label.bbcode_enabled = true
	_feed_label.fit_content = true
	_feed_label.scroll_active = false
	_feed_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feed_vbox.add_child(_feed_label)

	_window = PanelContainer.new()
	_window.anchor_left = 0
	_window.anchor_top = 0
	_window.anchor_right = 0.5
	_window.anchor_bottom = 0.3
	_window.offset_left = 16
	_window.offset_top = 16
	_window.offset_right = -8
	_window.offset_bottom = -8
	_window.clip_contents = true
	var win_style := StyleBoxFlat.new()
	win_style.bg_color = Color(0.03, 0.07, 0.03, 0.85)
	win_style.border_color = HACK_GREEN
	win_style.set_border_width_all(2)
	_window.add_theme_stylebox_override("panel", win_style)
	_window.visible = false
	root.add_child(_window)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	_window.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	var title := Label.new()
	title.text = "CHAT"
	title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", HACK_GREEN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var settings_button := Button.new()
	settings_button.text = ICON_SETTINGS
	settings_button.tooltip_text = "Chat settings"
	settings_button.custom_minimum_size = Vector2(22, 22)
	settings_button.pressed.connect(_toggle_settings)
	_style_button(settings_button)
	header.add_child(settings_button)

	var close_button := Button.new()
	close_button.text = ICON_CLOSE
	close_button.tooltip_text = "Close (Esc)"
	close_button.custom_minimum_size = Vector2(22, 22)
	close_button.pressed.connect(_collapse)
	_style_button(close_button)
	header.add_child(close_button)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, 80)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_scroll)

	# Top-down: oldest message at top, newest at bottom, packed from the top
	# of the log instead of hugging its bottom edge.
	_log_container = VBoxContainer.new()
	_log_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_container.alignment = BoxContainer.ALIGNMENT_BEGIN
	_log_container.add_theme_constant_override("separation", 2)
	_scroll.add_child(_log_container)

	_input = LineEdit.new()
	_input.placeholder_text = "Press Enter to send, Esc to cancel"
	_input.max_length = 240
	_input.text_submitted.connect(_on_text_submitted)
	vbox.add_child(_input)

	_build_settings_panel(root)


func _build_settings_panel(root: Control) -> void:
	_settings_panel = PanelContainer.new()
	_settings_panel.anchor_left = 0.5
	_settings_panel.anchor_top = 0
	_settings_panel.anchor_right = 0.5
	_settings_panel.anchor_bottom = 0
	_settings_panel.offset_left = 8
	_settings_panel.offset_top = 16
	_settings_panel.offset_right = 198
	_settings_panel.offset_bottom = 166
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.03, 0.07, 0.03, 0.92)
	panel_style.border_color = HACK_GREEN
	panel_style.set_border_width_all(2)
	panel_style.content_margin_left = 10
	panel_style.content_margin_right = 10
	panel_style.content_margin_top = 10
	panel_style.content_margin_bottom = 10
	_settings_panel.add_theme_stylebox_override("panel", panel_style)
	_settings_panel.visible = false
	root.add_child(_settings_panel)

	var svbox := VBoxContainer.new()
	svbox.add_theme_constant_override("separation", 8)
	_settings_panel.add_child(svbox)

	var stitle := Label.new()
	stitle.text = "OPTIONS"
	stitle.add_theme_color_override("font_color", HACK_GREEN)
	svbox.add_child(stitle)

	var filter_check := CheckBox.new()
	filter_check.text = "Filter profanity"
	filter_check.tooltip_text = "Censor swearing (local only)"
	filter_check.button_pressed = _filter_enabled
	filter_check.add_theme_color_override("font_color", HACK_GREEN)
	filter_check.toggled.connect(_on_filter_toggled)
	svbox.add_child(filter_check)

	var clear_button := Button.new()
	clear_button.text = "Clear log"
	clear_button.tooltip_text = "Clear your local log"
	clear_button.custom_minimum_size = Vector2(0, 26)
	clear_button.pressed.connect(_on_clear_pressed)
	_style_button(clear_button)
	svbox.add_child(clear_button)


func _style_button(b: Button) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.08, 0.18, 0.08, 0.9)
	box.border_color = HACK_GREEN
	box.set_border_width_all(1)
	box.content_margin_left = 6
	box.content_margin_right = 6
	box.content_margin_top = 2
	box.content_margin_bottom = 2
	b.add_theme_stylebox_override("normal", box)
	b.add_theme_color_override("font_color", HACK_GREEN)


func _toggle_settings() -> void:
	_settings_panel.visible = not _settings_panel.visible


func expand() -> void:
	_expanded = true
	_feed_panel.visible = false
	_window.visible = true
	_prev_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_input.text = ""
	_input.grab_focus()
	_scroll_to_bottom()


func _collapse() -> void:
	_expanded = false
	_window.visible = false
	_settings_panel.visible = false
	_input.release_focus()
	Input.mouse_mode = _prev_mouse_mode


func _unhandled_input(event: InputEvent) -> void:
	if not _expanded:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
			var focus := get_viewport().gui_get_focus_owner()
			if focus is LineEdit or focus is TextEdit:
				return
			if not (multiplayer and multiplayer.has_multiplayer_peer()):
				return
			if not (GameManager.in_lobby or GameManager.in_game):
				return
			expand()
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel"):
		_collapse()
		get_viewport().set_input_as_handled()


func _on_text_submitted(text: String) -> void:
	text = text.strip_edges()
	if not text.is_empty() and is_instance_valid(chat_manager):
		chat_manager.send_message(text)
	_input.text = ""
	_collapse()


func _on_filter_toggled(pressed: bool) -> void:
	_filter_enabled = pressed
	_save_settings()


func _on_clear_pressed() -> void:
	_clear_all(false)


func _clear_all(also_history: bool) -> void:
	for c in _log_container.get_children():
		c.queue_free()
	_feed_lines.clear()
	_feed_label.text = ""
	_feed_panel.visible = false
	if also_history and is_instance_valid(chat_manager):
		chat_manager.clear_history()


# ---------------------------------------------------------------- messages

func _on_message_received(entry: Dictionary) -> void:
	var steam_id := int(entry.get("steam_id", 0))
	if steam_id != 0 and _muted_steam_ids.has(steam_id):
		_append_muted_row(entry, steam_id)
	else:
		_append_row(entry, steam_id)
		_push_feed(entry)


func _on_notice_received(text: String) -> void:
	_append_system_row(text, "#ff5555")


func _on_history_received(entries: Array) -> void:
	_render_entries(entries)


func _render_entries(entries: Array) -> void:
	for c in _log_container.get_children():
		c.queue_free()
	for entry in entries:
		var steam_id := int(entry.get("steam_id", 0))
		if steam_id != 0 and _muted_steam_ids.has(steam_id):
			_append_muted_row(entry, steam_id)
		else:
			_append_row(entry, steam_id)
	if _expanded:
		_scroll_to_bottom()


func _rebuild_log() -> void:
	if is_instance_valid(chat_manager):
		_render_entries(chat_manager.get_history())


func _on_peer_connected(id: int) -> void:
	if not multiplayer or id == multiplayer.get_unique_id():
		return
	if _known_peer_ids.has(id):
		return
	_known_peer_ids[id] = true
	if not _roster_synced:
		# Part of the initial roster catch-up, not a fresh join — record
		# them as already-present and stay quiet about it.
		return
	var pname := _resolve_player_name(id)
	_append_system_row(pname + _tr(" joined"), SYSTEM_COLOR)
	_push_feed_line("[color=%s]%s%s[/color]" % [SYSTEM_COLOR, _escape_bbcode(pname), _tr(" joined")])


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer or id == multiplayer.get_unique_id():
		return
	_known_peer_ids.erase(id)
	var pname := _resolve_player_name(id)
	_append_system_row(pname + _tr(" left"), SYSTEM_COLOR)
	_push_feed_line("[color=%s]%s%s[/color]" % [SYSTEM_COLOR, _escape_bbcode(pname), _tr(" left")])


func _resolve_player_name(id: int) -> String:
	if NetworkManager.active_backend and NetworkManager.active_backend.connected_players.has(id):
		return String(NetworkManager.active_backend.connected_players[id].get("name", "Player"))
	return "Player %d" % id


func _append_system_row(text: String, color: String) -> void:
	if _log_container.get_child_count() >= LOG_MAX_ROWS:
		_log_container.get_child(0).queue_free()

	var line := RichTextLabel.new()
	line.bbcode_enabled = true
	line.fit_content = true
	line.scroll_active = false
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.text = "[color=%s]%s[/color]" % [color, _escape_bbcode(text)]
	_log_container.add_child(line)

	if _expanded:
		_scroll_to_bottom()


func _append_row(entry: Dictionary, steam_id: int) -> void:
	if _log_container.get_child_count() >= LOG_MAX_ROWS:
		_log_container.get_child(0).queue_free()

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var is_self := steam_id != 0 and steam_id == _local_steam_id()
	if steam_id != 0 and not is_self:
		var mute_btn := Button.new()
		mute_btn.text = ICON_MUTE
		mute_btn.custom_minimum_size = Vector2(22, 22)
		mute_btn.tooltip_text = _tr("Mute ") + String(entry.get("name", "player"))
		mute_btn.pressed.connect(_toggle_mute.bind(steam_id))
		_style_button(mute_btn)
		row.add_child(mute_btn)

	var line := RichTextLabel.new()
	line.bbcode_enabled = true
	line.fit_content = true
	line.scroll_active = false
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var display_text: String = String(entry.get("text", ""))
	if _filter_enabled:
		display_text = _filter_text(display_text)

	line.text = "[color=#8cffb0][b]%s[/b][/color]: %s" % [
		_escape_bbcode(String(entry.get("name", "Player"))),
		_escape_bbcode(display_text),
	]
	row.add_child(line)

	_log_container.add_child(row)
	if _expanded:
		_scroll_to_bottom()


func _append_muted_row(entry: Dictionary, steam_id: int) -> void:
	if _log_container.get_child_count() >= LOG_MAX_ROWS:
		_log_container.get_child(0).queue_free()

	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "[muted] %s" % String(entry.get("name", "player"))
	label.modulate = Color(1, 1, 1, 0.4)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var unmute_btn := Button.new()
	unmute_btn.text = ICON_UNMUTE
	unmute_btn.custom_minimum_size = Vector2(22, 22)
	unmute_btn.tooltip_text = _tr("Unmute ") + String(entry.get("name", "player"))
	unmute_btn.pressed.connect(_toggle_mute.bind(steam_id))
	_style_button(unmute_btn)
	row.add_child(unmute_btn)

	_log_container.add_child(row)


func _toggle_mute(steam_id: int) -> void:
	if _muted_steam_ids.has(steam_id):
		_muted_steam_ids.erase(steam_id)
	else:
		_muted_steam_ids.append(steam_id)
	_save_settings()
	_rebuild_log()


func _push_feed(entry: Dictionary) -> void:
	var display_text: String = String(entry.get("text", ""))
	if _filter_enabled:
		display_text = _filter_text(display_text)
	_push_feed_line("[color=#8cffb0][b]%s[/b][/color]: %s" % [
		_escape_bbcode(String(entry.get("name", "Player"))),
		_escape_bbcode(display_text),
	])


func _push_feed_line(bbcode_line: String) -> void:
	_feed_lines.append(bbcode_line)
	if _feed_lines.size() > FEED_MAX_LINES:
		_feed_lines.pop_front()
	_feed_label.text = "\n".join(_feed_lines)
	_feed_panel.visible = true
	_feed_timer = FEED_LIFETIME


func _local_steam_id() -> int:
	return int(Steam.getSteamID())


func _escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]").replace("]", "[rb]")


func _scroll_to_bottom() -> void:
	# One frame isn't always enough for the container to recompute its
	# size after a new row is added, so wait for it to settle.
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
