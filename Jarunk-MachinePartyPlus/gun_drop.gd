extends Node

# =============================================================================
#  MachineParty+ - Firearm Factory: drop & pick up the fully built gun
# -----------------------------------------------------------------------------
#  Base game: once you assemble the gun you take it off YOUR OWN workstation
#  (owner-only) and can only shoot with it - you can never put it down.
#
#  This adds: while holding the gun, press DROP (action_2) to drop it on the
#  floor as a world pickup (like a Firearm Factory item drops). ANYONE can then
#  walk up and press PICK UP (action_1) to grab it; it then works exactly like a
#  gun taken from the table (has_gun = shoot). The workstation itself stays
#  owner-only, exactly like the base game.
#
#  Networking: dropped-gun objects are host-authoritative and synced over the
#  mod's own reliable Steam P2P control channel (the same one kick/ban uses), so
#  no game RPCs are added. Player gun-holding state is mirrored to every modded
#  client with an "mg_hold" message (the base set_has_gun_rpc can only SHOW the
#  gun, never hide it, so we drive the visual ourselves).
#
#  All players reachable through the server browser run the mod, so drop/pickup
#  is consistent for them. A non-mod client would not see dropped guns.
# =============================================================================

var mod                                  # MachineParty+ main (set before _ready)

const PLAYER_SCRIPT := "res://minigames/manufacture_gun/components/player/scripts/manufacture_gun_player.gd"
const GAME_SCRIPT := "res://minigames/manufacture_gun/scripts/manufacture_gun.gd"
const PICKUP_RADIUS := 2.2               # how close you must be to grab a dropped gun

var game_node                            # current ManufactureGun instance (or null)
var players: Array = []                  # tracked ManufactureGunPlayer nodes
var guns: Dictionary = {}                # id -> {x,y,z,ry}   (host = source of truth)
var visuals: Dictionary = {}             # id -> Node3D (local gun visual)
var _next_id: int = 1                    # host only
var _hb: float = 0.0                     # host heartbeat timer


func _ready() -> void:
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	call_deferred("_scan", get_tree().root)


func _scan(node) -> void:
	_on_node_added(node)
	for c in node.get_children():
		_scan(c)


func _on_node_added(node) -> void:
	var s = node.get_script()
	if s == null:
		return
	var p: String = s.resource_path
	if p == GAME_SCRIPT:
		_on_game_started(node)
	elif p == PLAYER_SCRIPT:
		if not players.has(node):
			players.append(node)


func _on_game_started(node) -> void:
	game_node = node
	guns.clear()
	visuals.clear()
	players = players.filter(func(x): return is_instance_valid(x))
	_next_id = 1
	_hb = 0.0
	# not the host? ask the host for the current dropped-gun state
	if not _is_host():
		_send_host({"t": "mg_hello"})


func _process(delta: float) -> void:
	if game_node == null or not is_instance_valid(game_node):
		if not guns.is_empty() or not visuals.is_empty():
			guns.clear()
			visuals.clear()   # visuals were children of the freed minigame, already gone
		return

	# host rebroadcasts state as a light heartbeat so late joiners catch up
	if _is_host() and not guns.is_empty():
		_hb += delta
		if _hb >= 1.0:
			_hb = 0.0
			_broadcast(_state_msg())

	var lp = _local_player()
	if lp == null or not is_instance_valid(lp):
		return
	if PauseMenu.active or not GameManager.game_focused:
		return
	if not lp.active or lp.finished:
		return

	if lp.has_gun:
		# holding the gun -> DROP with action_2 (action_1 shoots, base game)
		if Input.is_action_just_pressed("action_2"):
			_try_drop(lp)
		return

	# not holding the gun and hands free -> try to PICK UP a dropped gun with
	# action_1. Defer the decision to end-of-frame: the game's own pickup runs in
	# the player's _process and sets held_item_variation / has_gun first, so we
	# only take the dropped gun if our hands are STILL empty. This stops you
	# grabbing the gun and a part on the same press - it acts like any other item.
	if lp.held_item_variation == 0 and Input.is_action_just_pressed("action_1"):
		call_deferred("_pickup_deferred")


# ---------------------------------------------------------------- drop / pickup

func _try_drop(lp) -> void:
	var dc = lp.dropcast
	if dc == null or not dc.is_colliding():
		return
	var wc = lp.wall_cast
	if wc != null and wc.is_colliding():
		return
	var pos: Vector3 = dc.get_collision_point()
	var ry: float = lp.visuals.global_rotation.y

	# drop it from our hands locally and tell everyone
	_set_hold(lp, false)
	_broadcast({"t": "mg_hold", "net": _net_of(lp), "has": false})

	if _is_host():
		_host_add_gun(pos, ry)
	else:
		_send_host({"t": "mg_drop", "x": pos.x, "y": pos.y, "z": pos.z, "ry": ry})


# Runs at end-of-frame after the game's own pickup logic. Only grab the dropped
# gun if our hands are still empty (didn't pick up a part or take a table gun).
func _pickup_deferred() -> void:
	var lp = _local_player()
	if lp == null or not is_instance_valid(lp):
		return
	if not lp.active or lp.finished:
		return
	if lp.has_gun:                      # took a table gun this frame
		return
	if lp.held_item_variation != 0:     # picked up a part this frame
		return
	_try_pickup(lp)


func _try_pickup(lp) -> void:
	var id: int = _nearest_gun(lp.global_position)
	if id == 0:
		return
	if _is_host():
		# host is the picker: grant immediately
		if guns.has(id):
			guns.erase(id)
			_broadcast(_state_msg())
			_apply_state()
			# defer the grant so has_gun turns on AFTER this input frame - otherwise
			# the same action_1 press that picks the gun up is also seen by the
			# player's shoot check and fires a shot on pickup.
			call_deferred("_grant_self", lp)
	else:
		_send_host({"t": "mg_pick", "id": id})


func _grant_self(lp) -> void:
	if lp == null or not is_instance_valid(lp):
		return
	_set_hold(lp, true)
	_broadcast({"t": "mg_hold", "net": _net_of(lp), "has": true})
	if lp.has_method("play_pickup_gun_sound"):
		lp.play_pickup_gun_sound()   # one positional sound, RPC'd to everyone


func _host_add_gun(pos: Vector3, ry: float) -> void:
	var id := _next_id
	_next_id += 1
	guns[id] = {"x": pos.x, "y": pos.y, "z": pos.z, "ry": ry}
	_broadcast(_state_msg())
	_apply_state()


# -------------------------------------------------------- gun-holding visual

# has=true shows the gun exactly like taking it off the table; has=false hides it
# (the base game only ever shows it, so we drive the hide ourselves).
func _set_hold(p, has: bool) -> void:
	if p == null or not is_instance_valid(p):
		return
	p.has_gun = has
	var ah = p.anim_handler
	if ah == null or not is_instance_valid(ah):
		return
	if has:
		if ah.has_method("gun_picked_up"):
			ah.gun_picked_up()
	else:
		if ah.gun_parent != null and is_instance_valid(ah.gun_parent):
			ah.gun_parent.visible = false
		if ah.ik_L != null:
			ah.ik_L.stop()
		if ah.ik_R != null:
			ah.ik_R.stop()


# --------------------------------------------------------------- net dispatch

# Called by main._on_control_packet for any "mg_*" message.
func handle_net(sender: int, d: Dictionary) -> void:
	var t := str(d.get("t", ""))
	match t:
		"mg_hello":
			if _is_host():
				if mod and mod._voice:
					mod._voice.send_ctrl(sender, _state_msg())
		"mg_state":
			if _is_host():
				return   # host owns the truth
			_apply_state_from(d.get("g", []))
		"mg_drop":
			if _is_host():
				_host_add_gun(Vector3(d.get("x", 0.0), d.get("y", 0.0), d.get("z", 0.0)), float(d.get("ry", 0.0)))
		"mg_pick":
			if _is_host():
				var id := int(d.get("id", 0))
				if guns.has(id):
					guns.erase(id)
					_broadcast(_state_msg())
					_apply_state()
					if mod and mod._voice:
						mod._voice.send_ctrl(sender, {"t": "mg_grant"})
		"mg_grant":
			var lp = _local_player()
			if lp != null:
				# defer so has_gun turns on after this frame (no shot on pickup)
				call_deferred("_grant_self", lp)
		"mg_hold":
			var p = _player_by_net(int(d.get("net", 0)))
			if p != null:
				_set_hold(p, bool(d.get("has", false)))


# ------------------------------------------------------------- state / visuals

func _state_msg() -> Dictionary:
	var arr: Array = []
	for id in guns.keys():
		var g = guns[id]
		arr.append([id, g.x, g.y, g.z, g.ry])
	return {"t": "mg_state", "g": arr}


func _apply_state_from(list) -> void:
	guns.clear()
	for e in list:
		if e is Array and e.size() >= 5:
			guns[int(e[0])] = {"x": float(e[1]), "y": float(e[2]), "z": float(e[3]), "ry": float(e[4])}
	_apply_state()


# Reconcile local visuals to the current `guns` set.
func _apply_state() -> void:
	for id in visuals.keys():
		if not guns.has(id):
			if is_instance_valid(visuals[id]):
				visuals[id].queue_free()
			visuals.erase(id)
	for id in guns.keys():
		if not visuals.has(id):
			var v = _make_gun_visual()
			if v != null:
				var g = guns[id]
				game_node.add_child(v)
				v.global_position = Vector3(g.x, g.y, g.z)
				v.rotation.y = g.ry
				v.visible = true
				visuals[id] = v


func _make_gun_visual():
	if game_node == null or not is_instance_valid(game_node):
		return null
	var wsp = game_node.get_node_or_null("Workstations")
	if wsp == null:
		return null
	for ws in wsp.get_children():
		if "gun_assembled" in ws and ws.gun_assembled != null and is_instance_valid(ws.gun_assembled):
			var dup = ws.gun_assembled.duplicate()
			dup.visible = true
			return dup
	return null


# ------------------------------------------------------------------- helpers

func _nearest_gun(pos: Vector3) -> int:
	var best_id := 0
	var best_d := PICKUP_RADIUS * PICKUP_RADIUS
	for id in guns.keys():
		var g = guns[id]
		var dx: float = g.x - pos.x
		var dz: float = g.z - pos.z
		var d2: float = dx * dx + dz * dz
		if d2 <= best_d:
			best_d = d2
			best_id = id
	return best_id


func _local_player():
	var uid := multiplayer.get_unique_id()
	for p in players:
		if is_instance_valid(p) and p.get_multiplayer_authority() == uid:
			return p
	return null


func _player_by_net(net: int):
	for p in players:
		if is_instance_valid(p) and p.get_multiplayer_authority() == net:
			return p
	return null


func _net_of(p) -> int:
	return p.get_multiplayer_authority()


func _is_host() -> bool:
	return multiplayer != null and multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func _broadcast(d: Dictionary) -> void:
	if mod == null or mod._voice == null:
		return
	for sid in mod.other_player_steam_ids():
		mod._voice.send_ctrl(sid, d)


func _send_host(d: Dictionary) -> void:
	if mod == null or mod._voice == null:
		return
	var h := _host_steam_id()
	if h != 0:
		mod._voice.send_ctrl(h, d)


func _host_steam_id() -> int:
	if NetworkManager == null or NetworkManager.active_backend == null:
		return 0
	var lid := int(NetworkManager.active_backend.lobby_id)
	if lid <= 0:
		return 0
	return int(Steam.getLobbyOwner(lid))
