# b_camera.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# Copyright (c) 2017-2020 Charlie Whitfield
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *****************************************************************************
# This camera is always locked to a Body and constantly orients itself based on
# that Body's orbit around its parent. You can replace this with another Camera
# class, but see:
#    Global signals (singletons/globa.gd)
#    ViewportInput (program_nodes/viewport_input.gd)
#    TreeManager (program_nodes/tree_manager.gd)
#    SelectionManager (tree_refs/selection_manager.gd)
# (You'll need to either match some BCamera API or modify/replace the latter
# three classes.)
#
# The camera stays "in place" by maintaining view_position & view_orientation.
# Both are spherical coordinates. The first is position relative to a vector
# from the parent body to the grandparent body (reversed at star orbiting
# bodies). The second is rotation relative to pointing at parent.

extends Camera
class_name BCamera

const math := preload("res://ivoyager/static/math.gd") # =Math when issue #37529 fixed

# ********************************* SIGNALS ***********************************

signal move_started(to_body, is_camera_lock)
signal parent_changed(new_body)
signal range_changed(new_range)
signal focal_length_changed(focal_length)
signal camera_lock_changed(is_camera_lock)
signal view_type_changed(view_type)

# ***************************** ENUMS & CONSTANTS *****************************

const VIEW_ZOOM = Enums.VIEW_ZOOM
const VIEW_45 = Enums.VIEW_45
const VIEW_TOP = Enums.VIEW_TOP
const VIEW_CENTERED = Enums.VIEW_CENTERED
const VIEW_UNCENTERED = Enums.VIEW_UNCENTERED

# TODO: Different pathings...
enum {
	INTERPOLATE_SPHERICAL, # looks better w/in systems among ecliptic/equatorial orbits
	INTERPOLATE_CARTESIAN, # looks better otherwise
}

enum {
	LONGITUDE_REMAP_INIT,
	LONGITUDE_REMAP_NONE,
	LONGITUDE_REMAP_FROM,
	LONGITUDE_REMAP_TO
}

const ECLIPTIC_NORTH := Vector3(0.0, 0.0, 1.0)
const Y_DIRECTION := Vector3(0.0, 1.0, 0.0)
const X_DIRECTION := Vector3(1.0, 0.0, 0.0)
const NULL_ROTATION := Vector3(-INF, -INF, -INF)
const VECTOR3_ZERO := Vector3.ZERO

const DPRINT := false
const CENTER_ORIGIN_SHIFTING := true # prevents "shakes" at high translation
const NEAR_DIST_MULTIPLIER := 0.1 
const FAR_DIST_MULTIPLIER := 1e9 # far/near seems to allow ~10 orders-of-magnitude

# ******************************* PERSISTED ***********************************

# public - read only except project init
var is_camera_lock := true

# public - read only! (these are "to" during camera move)
var selection_item: SelectionItem
var view_type := VIEW_ZOOM
var view_position := VECTOR3_ZERO # longitude, latitude, radius
var view_orientation := VECTOR3_ZERO # relative to pointing at parent, north up
var focal_length: float
var focal_length_index: int # use init_focal_length_index below

# private
var _transform := Transform(Basis(), Vector3.ONE) # "working" value
var _view_type_memory := view_type

# persistence
const PERSIST_AS_PROCEDURAL_OBJECT := true
const PERSIST_PROPERTIES := ["name", "is_camera_lock", "view_type", "view_position",
	"view_orientation", "focal_length", "focal_length_index", "_transform", "_view_type_memory"]
const PERSIST_OBJ_PROPERTIES := ["selection_item"]

# ****************************** UNPERSISTED **********************************

# public - project init vars
var focal_lengths := [6.0, 15.0, 24.0, 35.0, 50.0] # ~fov 125.6, 75.8, 51.9, 36.9, 26.3
var init_focal_length_index := 2
var ease_exponent := 5.0
var follow_orbit: float = 4e7 * UnitDefs.KM # km after dividing by fov
var orient_to_local_pole: float = 5e7 * UnitDefs.KM # must be > follow_orbit
var orient_to_ecliptic: float = 5e10 * UnitDefs.KM # must be > orient_to_local_pole
var action_rate := 10.0 # how fast we use up the accumulators
var min_action := 0.002 # use all below this

# input control - these are accumulators
var move_action := VECTOR3_ZERO
var rotate_action := VECTOR3_ZERO

# public read-only
var parent: Spatial # always current
var is_moving := false

# private
var _settings: Dictionary = Global.settings
var _registrar: Registrar = Global.program.Registrar
var _max_dist: float = Global.max_camera_distance
var _min_dist := 0.1 # set for parent body
var _follow_orbit_dist: float
var _orient_to_local_pole: float
var _orient_to_ecliptic: float

# move
var _move_progress: float
var _to_spatial: Spatial
var _from_spatial: Spatial
var _move_spatial: Spatial
var _move_north := ECLIPTIC_NORTH
var _from_selection_item: SelectionItem
var _from_view_type := VIEW_ZOOM
var _from_view_position := Vector3.ONE
var _from_view_orientation := VECTOR3_ZERO
var _last_anomaly := -INF # -INF is used as null value
var _move_longitude_remap := LONGITUDE_REMAP_INIT
var _last_dist := 0.0


onready var _top_body: Body = _registrar.top_body
onready var _viewport := get_viewport()
onready var _tree := get_tree()
# settings
onready var _transition_time: float = _settings.camera_transition_time

# **************************** PUBLIC FUNCTIONS *******************************

static func get_view_position(translation_: Vector3, north: Vector3,
		ref_longitude := 0.0) -> Vector3:
	# FIXME: This should be way simpler than the way I did it here!
	#
	# "view_position_" is a standardized Vector3 where:
	#    x is longitude angle relative to ref_longitude
	#    y is latitude angle
	#    z is radius distance
	# (ref_longitude is used here to track orbital motion when close; -INF, ok)
	assert(north.is_normalized())
	if ref_longitude == -INF:
		ref_longitude = 0.0
	
	# TODO: Use spherical coordinate conversions
#	translation_ = _math.rotate_vector_pole(translation_, north)
#	var spherical := _math.cartesian2spherical(translation_)
#	var radius := spherical[0]
#	var latitude := PI / 2.0 - spherical[1]
#	var longitude := wrapf(spherical[2] - ref_longitude, -PI, PI)
	
	var radius := translation_.length()
	var latitude := PI / 2.0 - translation_.angle_to(north)
	var axis := translation_.cross(north).normalized()
	var world_x := Y_DIRECTION.cross(north).normalized()
	var longitude := axis.angle_to(world_x)
	if axis.dot(Y_DIRECTION) < 0.0:
		longitude = -longitude
	longitude = wrapf(longitude + PI / 2.0 - ref_longitude, -PI, PI)
	return Vector3(longitude, latitude, radius)

static func convert_view_position(view_position_: Vector3, north: Vector3,
		ref_longitude: float) -> Vector3:
	# inverse of above function
	# FIXME: This should be way simpler than this!!!
	if ref_longitude == -INF:
		ref_longitude = 0.0
	var longitude := view_position_[0]
	var latitude := view_position_[1]
	var radius := view_position_[2]
	
	# TODO: Use spherical coordinate conversions
#	var spherical := Vector3(radius, PI / 2.0 - latitude, longitude - ref_longitude)
#	var translation_ := _math.spherical2cartesian(spherical)
#	translation_ = -_math.rotate_vector_pole(north, translation_)
	
	var world_x := Y_DIRECTION.cross(north).normalized()
	var axis := world_x.rotated(north, longitude - PI / 2.0 + ref_longitude)
	var translation_ = axis.cross(north)
	assert(translation_.is_normalized())
	translation_ = translation_.rotated(axis, latitude)
	translation_ *= -radius
	return translation_

func move(to_selection_item: SelectionItem, to_view_type := -1, to_view_position := VECTOR3_ZERO,
		to_rotations := NULL_ROTATION, is_instant_move := false) -> void:
	# Null or null-equivilant args tell the camera to keep its current value.
	# Most view_type values override view_position & view_orientation.
	assert(DPRINT and prints("move", to_selection_item, to_view_type, to_view_position,
			to_rotations, is_instant_move) or true)
	_from_selection_item = selection_item
	_from_spatial = parent
	_from_view_type = view_type
	_from_view_position = view_position
	_from_view_orientation = view_orientation
	if to_selection_item and to_selection_item.spatial:
		selection_item = to_selection_item
		_to_spatial = to_selection_item.spatial
		_min_dist = selection_item.view_min_distance * 50.0 / fov
	if to_view_type != -1:
		view_type = to_view_type
	match view_type:
		VIEW_ZOOM, VIEW_45, VIEW_TOP:
			view_position = selection_item.camera_view_positions[view_type]
			view_position[2] /= fov
			view_orientation = VECTOR3_ZERO
		VIEW_CENTERED:
			if to_view_position != VECTOR3_ZERO:
				view_position = to_view_position
			view_orientation = VECTOR3_ZERO
		VIEW_UNCENTERED:
			if to_view_position != VECTOR3_ZERO:
				view_position = to_view_position
			if to_rotations != NULL_ROTATION:
				view_orientation = to_rotations
		_:
			assert(false)
	var min_dist := selection_item.view_min_distance * sqrt(50.0 / fov)
	if view_position.z < min_dist:
		view_position.z = min_dist

	if is_instant_move:
		_move_progress = _transition_time # finishes move on next frame
	elif !is_moving:
		_move_progress = 0.0 # starts move on next frame
	else:
		_move_progress = _transition_time / 2.0 # move was in progress; user is in a hurry!
	_move_spatial = _get_common_spatial(_from_spatial, _to_spatial)
	var from_north: Vector3 = _from_spatial.north_pole if "north_pole" in _from_spatial else ECLIPTIC_NORTH
	var to_north: Vector3 = _to_spatial.north_pole if "north_pole" in _to_spatial else ECLIPTIC_NORTH
	_move_north = (from_north + to_north).normalized()
	is_moving = true
	move_action = VECTOR3_ZERO
	rotate_action = VECTOR3_ZERO
	_move_longitude_remap = LONGITUDE_REMAP_INIT
	emit_signal("move_started", _to_spatial, is_camera_lock)
	emit_signal("view_type_changed", view_type)

func move_to_body(to_body: Body, to_view_type := -1, to_view_position := VECTOR3_ZERO,
		to_rotations := NULL_ROTATION, is_instant_move := false) -> void:
	assert(DPRINT and prints("move_to_body", to_body, to_view_type, is_instant_move) or true)
	var to_selection_item := _registrar.get_selection_for_body(to_body)
	move(to_selection_item, to_view_type, to_view_position, to_rotations, is_instant_move)

func increment_focal_length(increment: int) -> void:
	var new_fl_index = focal_length_index + increment
	if new_fl_index < 0:
		new_fl_index = 0
	elif new_fl_index >= focal_lengths.size():
		new_fl_index = focal_lengths.size() - 1
	if new_fl_index != focal_length_index:
		set_focal_length_index(new_fl_index, false)

func set_focal_length_index(new_fl_index, suppress_move := false) -> void:
	focal_length_index = new_fl_index
	focal_length = focal_lengths[focal_length_index]
	fov = math.get_fov_from_focal_length(focal_length)
	_orient_to_local_pole = orient_to_local_pole / fov
	_orient_to_ecliptic = orient_to_ecliptic / fov
	_follow_orbit_dist = follow_orbit / fov
	_min_dist = selection_item.view_min_distance * 50.0 / fov
	if !suppress_move:
		move(null, -1, VECTOR3_ZERO, NULL_ROTATION, true)
	emit_signal("focal_length_changed", focal_length)

func change_camera_lock(new_lock: bool) -> void:
	if is_camera_lock != new_lock:
		is_camera_lock = new_lock
		emit_signal("camera_lock_changed", new_lock)
		if new_lock:
			if view_type > VIEW_TOP:
				view_type = _view_type_memory

func tree_manager_process(engine_delta: float) -> void:
	# We process our working _transform, then update transform
	if is_moving:
		_move_progress += engine_delta
		if _move_progress < _transition_time:
			_process_moving()
		else: # end the move
			is_moving = false
			if parent != _to_spatial:
				_do_camera_handoff() # happened at halfway unless is_instant_move
	if !is_moving:
		_process_not_moving(engine_delta)
	if CENTER_ORIGIN_SHIFTING:
		_top_body.translation -= parent.global_transform.origin
	transform = _transform

# ********************* VIRTUAL & PRIVATE FUNCTIONS ***************************

func _ready() -> void:
	_on_ready()

func _on_ready():
	name = "BCamera"
	Global.connect("about_to_free_procedural_nodes", self, "_prepare_to_free", [], CONNECT_ONESHOT)
	Global.connect("about_to_start_simulator", self, "_start_sim", [], CONNECT_ONESHOT)
	Global.connect("gui_refresh_requested", self, "_send_gui_refresh")
	Global.connect("run_state_changed", self, "_set_run_state")
	Global.connect("move_camera_to_selection_requested", self, "move")
	Global.connect("move_camera_to_body_requested", self, "move_to_body")
	Global.connect("setting_changed", self, "_settings_listener")
	transform = _transform
	var dist := _transform.origin.length()
	near = dist * NEAR_DIST_MULTIPLIER
	far = dist * FAR_DIST_MULTIPLIER
	pause_mode = PAUSE_MODE_PROCESS
	parent = get_parent()
	_to_spatial = parent
	_from_spatial = parent
	selection_item = _registrar.get_selection_for_body(parent)
	_from_selection_item = selection_item
	focal_length_index = init_focal_length_index
	focal_length = focal_lengths[focal_length_index]
	fov = math.get_fov_from_focal_length(focal_length)
	_follow_orbit_dist = follow_orbit / fov
	_orient_to_local_pole = orient_to_local_pole / fov
	_orient_to_ecliptic = orient_to_ecliptic / fov
	_min_dist = selection_item.view_min_distance * 50.0 / fov
	_set_run_state(Global.state.is_running)
	Global.emit_signal("camera_ready", self)
	print("BCamera ready...")

func _set_run_state(is_running: bool) -> void:
	set_process(is_running)
	set_process_unhandled_input(is_running)

func _start_sim(_is_new_game: bool) -> void:
	move(null, -1, VECTOR3_ZERO, NULL_ROTATION, true)

func _prepare_to_free() -> void:
	Global.disconnect("run_state_changed", self, "_set_run_state")
	Global.disconnect("gui_refresh_requested", self, "_send_gui_refresh")
	Global.disconnect("move_camera_to_selection_requested", self, "move")
	Global.disconnect("move_camera_to_body_requested", self, "move_to_body")
	selection_item = null
	parent = null
	_to_spatial = null
	_from_spatial = null
	_move_spatial = null
	_top_body = null

func _process_moving() -> void:
	var ease_progress := ease(_move_progress / _transition_time, -ease_exponent)
	# Hand-off at halfway point avoids imprecision shakes at either end
	if parent != _to_spatial and ease_progress > 0.5:
		_do_camera_handoff()
	# We interpolate position using our "view_position_" coordinates for the
	# common parent of the move. E.g., we move around Jupiter (not through it
	# if going from Io to Europa. Basis is interpolated more straightforwardly
	# using transform.basis.
	var from_transform := _get_view_transform(_from_selection_item, _from_view_position,
			_from_view_orientation)
	var to_transform := _get_view_transform(selection_item, view_position, view_orientation)
	var global_common_translation := _move_spatial.global_transform.origin
#	var common_north = _move_spatial.north_pole # FIXME
	var from_common_translation := from_transform.origin \
			+ _from_spatial.global_transform.origin - global_common_translation
	var to_common_translation := to_transform.origin \
			+ _to_spatial.global_transform.origin - global_common_translation
	var from_common_view_position := get_view_position(from_common_translation, _move_north, 0.0)
	var to_common_view_position := get_view_position(to_common_translation, _move_north, 0.0)
	# We can remap longitude to allow shorter travel over the PI/-PI transition.
	# However, we must commit at begining of move to a particular remapping and
	# stick to it.
	if _move_longitude_remap == LONGITUDE_REMAP_INIT:
		var view_longitude_diff := to_common_view_position[0] - from_common_view_position[0]
		if view_longitude_diff > PI:
			_move_longitude_remap = LONGITUDE_REMAP_FROM
		elif view_longitude_diff < -PI:
			_move_longitude_remap = LONGITUDE_REMAP_TO
		else:
			_move_longitude_remap = LONGITUDE_REMAP_NONE
	if _move_longitude_remap == LONGITUDE_REMAP_FROM:
		from_common_view_position[0] += TAU
	elif _move_longitude_remap == LONGITUDE_REMAP_TO:
		to_common_view_position[0] += TAU
	var interpolated_view_position := from_common_view_position.linear_interpolate(
			to_common_view_position, ease_progress)
	var interpolated_common_translation := convert_view_position(
			interpolated_view_position, _move_north, 0.0)
	_transform.origin = interpolated_common_translation + global_common_translation \
			- parent.global_transform.origin
	_transform.basis = from_transform.basis.slerp(to_transform.basis, ease_progress)
	var dist := _transform.origin.length()
	near = dist * NEAR_DIST_MULTIPLIER
	far = dist * FAR_DIST_MULTIPLIER
	if parent != _to_spatial: # use dist to target parent for GUI
		dist = (global_transform.origin - _to_spatial.global_transform.origin).length()
	emit_signal("range_changed", dist)

func _do_camera_handoff() -> void:
	parent.remove_child(self)
	_to_spatial.add_child(self)
	parent = _to_spatial
	emit_signal("parent_changed", parent)

func _process_not_moving(delta: float) -> void:
	var is_camera_bump := false
	_transform = _get_view_transform(selection_item, view_position, view_orientation)
	if move_action:
		_process_move_action(delta)
		is_camera_bump = true
	if rotate_action:
		_process_rotate_action(delta)
		is_camera_bump = true
	if is_camera_bump and view_type != VIEW_UNCENTERED:
		if view_orientation:
			view_type = VIEW_UNCENTERED
			emit_signal("view_type_changed", view_type)
		elif view_type != VIEW_CENTERED:
			view_type = VIEW_CENTERED
			emit_signal("view_type_changed", view_type)
	var dist := view_position[2]
	if !is_equal_approx(dist, _last_dist):
		_last_dist = dist
		emit_signal("range_changed", dist)
		near = dist * NEAR_DIST_MULTIPLIER
		far = dist * FAR_DIST_MULTIPLIER

func _process_move_action(delta: float) -> void:
	var move_now := move_action
	if abs(move_now.x) > min_action:
		move_now.x *= action_rate * delta
		move_action.x -= move_now.x
	else:
		move_action.x = 0.0
	if abs(move_now.y) > min_action:
		move_now.y *= action_rate * delta
		move_action.y -= move_now.y
	else:
		move_action.y = 0.0
	if abs(move_now.z) > min_action:
		move_now.z *= action_rate * delta
		move_action.z -= move_now.z
	else:
		move_action.z = 0.0
	# rotate for camera basis
	var move_vector := _transform.basis * move_now
	# get values for adjustments below
	var dist: float = view_position[2]
	var north := _get_north(selection_item, dist)
	var origin := _transform.origin
	var move_dot_origin := move_vector.dot(origin) # radial movement
	var normalized_origin := origin.normalized()
	var longitude_vector := normalized_origin.cross(north).normalized()
	# dampen "spin" as we near the poles
	var longitudinal_move := longitude_vector * longitude_vector.dot(move_vector)
	var spin_dampening := north.dot(normalized_origin)
	spin_dampening *= spin_dampening # makes positive & reduces
	spin_dampening *= spin_dampening # reduces more
	move_vector -= longitudinal_move * spin_dampening
	# add adjusted move vector scaled by distance to parent
	origin += move_vector * dist
	# test for pole traversal
	if longitude_vector.dot(origin.cross(north)) <= 0.0: # before/after comparison
		view_orientation.z = wrapf(view_orientation.z + PI, 0.0, TAU)
	# fix our distance to ignore small tangental movements
	var new_dist := dist + move_dot_origin
	new_dist = clamp(new_dist, _min_dist, _max_dist)
	origin = new_dist * origin.normalized()
	# update _transform & view_position (maintain view_orientation)
	_transform.origin = origin
	_transform = _transform.looking_at(-origin, north)
	_transform.basis *= Basis(view_orientation)
	var reference_anomaly := _get_reference_anomaly(selection_item, new_dist)
	view_position = get_view_position(origin, north, reference_anomaly)

func _process_rotate_action(delta: float) -> void:
	var rotate_now := rotate_action
	if abs(rotate_now.x) > min_action:
		rotate_now.x *= action_rate * delta
		rotate_action.x -= rotate_now.x
	else:
		rotate_action.x = 0.0
	if abs(rotate_now.y) > min_action:
		rotate_now.y *= action_rate * delta
		rotate_action.y -= rotate_now.y
	else:
		rotate_action.y = 0.0
	if abs(rotate_now.z) > min_action:
		rotate_now.z *= action_rate * delta
		rotate_action.z -= rotate_now.z
	else:
		rotate_action.z = 0.0
	var basis := Basis(view_orientation)
	basis = basis.rotated(basis.x, rotate_now.x)
	basis = basis.rotated(basis.y, rotate_now.y)
	basis = basis.rotated(basis.z, rotate_now.z)
	view_orientation = basis.get_euler()
	var dist: float = view_position[2]
	var north := _get_north(selection_item, dist)
	_transform = _transform.looking_at(-_transform.origin, north)
	_transform.basis *= Basis(view_orientation)

func _get_view_transform(selection_item_: SelectionItem, view_position_: Vector3,
		view_orientation_: Vector3) -> Transform:
	var dist := view_position_[2]
	var north := _get_north(selection_item_, dist)
	var reference_anomaly := _get_reference_anomaly(selection_item_, dist)
	var view_type_translation := convert_view_position(view_position_, north, reference_anomaly)
	_last_anomaly = reference_anomaly
	var view_type_transform := Transform(Basis(), view_type_translation).looking_at(-view_type_translation, north)
	view_type_transform.basis *= Basis(view_orientation_)
	return view_type_transform

func _get_reference_anomaly(selection_item_: SelectionItem, dist: float) -> float:
	if dist < _follow_orbit_dist:
		return selection_item_.get_orbit_anomaly_for_camera()
	return 0.0

func _get_north(selection_item_: SelectionItem, dist: float) -> Vector3:
	if !selection_item_.is_body:
		return ECLIPTIC_NORTH
	var local_north := selection_item_.get_north()
	if dist <= _orient_to_local_pole:
		return local_north
	elif dist >= _orient_to_ecliptic:
		return ECLIPTIC_NORTH
	else:
		var proportion := log(dist / _orient_to_local_pole) / log(_orient_to_ecliptic / _orient_to_local_pole)
		proportion = ease(proportion, -ease_exponent)
		var diff_vector := local_north - ECLIPTIC_NORTH
		return (local_north - diff_vector * proportion).normalized()

func _get_common_spatial(spatial1: Spatial, spatial2: Spatial) -> Spatial:
	assert(spatial1 and spatial2)
	while spatial1:
		var test_spatial = spatial2
		while test_spatial:
			if spatial1 == test_spatial:
				return spatial1
			test_spatial = test_spatial.get_parent_spatial()
		spatial1 = spatial1.get_parent_spatial()
	assert(false)
	return null

func _send_gui_refresh() -> void:
	if parent:
		emit_signal("parent_changed", parent)
	emit_signal("range_changed", translation.length())
	emit_signal("focal_length_changed", focal_length)
	emit_signal("camera_lock_changed", is_camera_lock)
	emit_signal("view_type_changed", view_type)

func _settings_listener(setting: String, value) -> void:
	match setting:
		"camera_transition_time":
			_transition_time = value

