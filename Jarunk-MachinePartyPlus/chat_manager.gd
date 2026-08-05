extends Node

const MAX_MESSAGE_LEN := 240
const RATE_WINDOW_SEC := 6.0
const RATE_MAX_MSGS := 5
const REPEAT_LIMIT := 3
const MUTE_DURATION_SEC := 30.0
const VIOLATIONS_TO_MUTE := 3
const HISTORY_MAX := 50

signal message_received(entry: Dictionary)
signal notice_received(text: String)
signal history_received(entries: Array)

var _rate_stamps: Dictionary = {}
var _violations: Dictionary = {}
var _muted_until: Dictionary = {}
var _last_text: Dictionary = {}
var _repeat_count: Dictionary = {}
var _history: Array = []


func _ready() -> void:
	set_multiplayer_authority(1)
	if multiplayer and not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if multiplayer and not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)


func _on_peer_disconnected(id: int) -> void:
	_rate_stamps.erase(id)
	_violations.erase(id)
	_muted_until.erase(id)
	_last_text.erase(id)
	_repeat_count.erase(id)


func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	_send_history.rpc_id(id, _history)


func clear_history() -> void:
	_history.clear()


func get_history() -> Array:
	return _history.duplicate()


func send_message(text: String) -> void:
	if not (multiplayer and multiplayer.has_multiplayer_peer()):
		return
	text = _sanitize(text)
	if text.is_empty():
		return
	if multiplayer.is_server():
		_handle_incoming(text, 1)
	else:
		request_send_message.rpc_id(1, text)


@rpc("any_peer", "call_remote", "reliable")
func request_send_message(text: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_handle_incoming(_sanitize(text), sender_id)


func _handle_incoming(text: String, sender_id: int) -> void:
	if text.is_empty():
		return
	var reason := _spam_check(sender_id, text)
	if reason != "":
		_notify(sender_id, reason)
		return
	var entry := {
		"peer_id": sender_id,
		"steam_id": _resolve_steam_id(sender_id),
		"name": _resolve_name(sender_id),
		"text": text,
		"ts": Time.get_unix_time_from_system(),
	}
	_broadcast_message.rpc(entry)


func _spam_check(sender_id: int, text: String) -> String:
	var now := Time.get_ticks_msec() / 1000.0

	var muted_until: float = _muted_until.get(sender_id, 0.0)
	if now < muted_until:
		return "You are temporarily muted for spamming."

	var last: String = _last_text.get(sender_id, "")
	if last != "" and text.to_lower() == last.to_lower():
		_repeat_count[sender_id] = int(_repeat_count.get(sender_id, 0)) + 1
	else:
		_repeat_count[sender_id] = 0
	_last_text[sender_id] = text
	if int(_repeat_count.get(sender_id, 0)) >= REPEAT_LIMIT:
		_register_violation(sender_id, now)
		return "Stop repeating the same message."

	var stamps: Array = _rate_stamps.get(sender_id, [])
	stamps = stamps.filter(func(t): return now - t < RATE_WINDOW_SEC)
	stamps.append(now)
	_rate_stamps[sender_id] = stamps
	if stamps.size() > RATE_MAX_MSGS:
		_register_violation(sender_id, now)
		return "You're sending messages too fast."

	return ""


func _register_violation(sender_id: int, now: float) -> void:
	var v: int = int(_violations.get(sender_id, 0)) + 1
	_violations[sender_id] = v
	if v >= VIOLATIONS_TO_MUTE:
		_muted_until[sender_id] = now + MUTE_DURATION_SEC
		_violations[sender_id] = 0


@rpc("authority", "call_local", "reliable")
func _broadcast_message(entry: Dictionary) -> void:
	_history.append(entry)
	if _history.size() > HISTORY_MAX:
		_history.pop_front()
	message_received.emit(entry)


@rpc("authority", "call_remote", "reliable")
func _send_history(entries: Array) -> void:
	history_received.emit(entries)


@rpc("authority", "call_remote", "reliable")
func _receive_notice(text: String) -> void:
	notice_received.emit(text)


func _notify(sender_id: int, text: String) -> void:
	if sender_id == 1:
		notice_received.emit(text)
	else:
		_receive_notice.rpc_id(sender_id, text)


func _sanitize(text) -> String:
	if typeof(text) != TYPE_STRING:
		return ""
	text = text.strip_edges()
	if text.length() > MAX_MESSAGE_LEN:
		text = text.substr(0, MAX_MESSAGE_LEN)
	var cleaned := ""
	for c in text:
		var code: int = c.unicode_at(0)
		if code == 9 or code >= 32:
			cleaned += c
	return cleaned.strip_edges()


func _resolve_steam_id(peer_id: int) -> int:
	var mp_peer = multiplayer.multiplayer_peer
	if mp_peer and mp_peer.has_method("get_steam64_from_peer_id"):
		var sid := int(mp_peer.get_steam64_from_peer_id(peer_id))
		if sid != 0:
			return sid
	if peer_id == 1:
		return int(Steam.getSteamID())
	return 0


func _resolve_name(peer_id: int) -> String:
	var steam_id := _resolve_steam_id(peer_id)
	if steam_id != 0:
		var pname := Steam.getFriendPersonaName(steam_id)
		if not pname.strip_edges().is_empty():
			return pname
	return "Player %d" % peer_id
