# tree_manager.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright (c) 2017-2021 Charlie Whitfield
# "I, Voyager" is a registered trademark of Charlie Whitfield
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
# Manages processing and visibility of system tree nodes. This node expects a
# lot of interface specific to VygrCamera (search '_camera' below). You can
# replace with your own Camera class but you will need to match some VygrCamera
# API or modify functios below.

extends Node
class_name TreeManager

const math := preload("res://ivoyager/static/math.gd") # =Math when issue #37529 fixed

signal show_symbols_changed(is_show)
signal show_names_changed(is_show)
signal show_orbits_changed(is_show)

const DPRINT := false
const QUAD_MESH_BASE_SIZE := Vector2(1.0, 1.0)
const IS_STAR := Enums.BodyFlags.IS_STAR
const IS_STAR_ORBITING := Enums.BodyFlags.IS_STAR_ORBITING

# public - read-only except for project init
var show_orbits := true
var show_symbols := false # exclusive w/ show_symbols
var show_names := true # exclusive w/ show_symbols

const PERSIST_AS_PROCEDURAL_OBJECT := false
const PERSIST_PROPERTIES := ["show_orbits", "show_symbols", "show_names"]

# unpersisted
var _settings: Dictionary = Global.settings
var _tree: SceneTree
var _root: Viewport
var _timekeeper: Timekeeper
var _registrar: Registrar
var _camera: Camera
var _at_local_star_orbiter: Body
var _to_local_star_orbiter: Body
var _skip_local_system := {}
var _time: float
var _camera_global_translation: Vector3
onready var _init_show_orbits := show_orbits
onready var _init_show_symbols := show_symbols
onready var _init_show_names := show_names

func project_init() -> void:
	Global.connect("about_to_free_procedural_nodes", self, "_restore_init_state")
	Global.connect("camera_ready", self, "_connect_camera")
	Global.connect("gui_refresh_requested", self, "_gui_refresh")
	_tree = Global.program.tree
	_root = Global.program.root
	_timekeeper = Global.program.Timekeeper
	_registrar = Global.program.Registrar
	_timekeeper.connect("processed", self, "_timekeeper_process")

func set_show_symbols(is_show: bool) -> void:
	show_symbols = is_show
	if is_show and show_names:
		set_show_names(false)
	assert(DPRINT and prints("set_show_symbols", is_show) or true)
	emit_signal("show_symbols_changed", is_show)
	
func set_show_names(is_show: bool) -> void:
	show_names = is_show
	if is_show and show_symbols:
		set_show_symbols(false)
	assert(DPRINT and prints("set_show_names", is_show) or true)
	emit_signal("show_names_changed", is_show)

func set_show_orbits(is_show: bool) -> void:
	show_orbits = is_show
	assert(DPRINT and prints("set_show_orbits", is_show) or true)
	emit_signal("show_orbits_changed", is_show)

func _restore_init_state() -> void:
	_disconnect_camera()
	_at_local_star_orbiter = null
	_to_local_star_orbiter = null
	_skip_local_system.clear()
	show_orbits = _init_show_orbits
	show_symbols = _init_show_symbols
	show_names = _init_show_names

func _gui_refresh() -> void:
	emit_signal("show_orbits_changed", show_orbits)
	emit_signal("show_symbols_changed", show_symbols)
	emit_signal("show_names_changed", show_names)

func _connect_camera(camera: Camera) -> void:
	if _camera != camera:
		_disconnect_camera()
		_camera = camera
		_camera.connect("move_started", self, "_camera_move_started")
		_camera.connect("parent_changed", self, "_camera_parent_changed")
		assert(DPRINT and prints("connected camera:", _camera) or true)

func _disconnect_camera() -> void:
	if _camera and is_instance_valid(_camera):
		_camera.disconnect("move_started", self, "_camera_move_started")
		_camera.disconnect("parent_changed", self, "_camera_parent_changed")
		assert(DPRINT and prints("disconnected camera:", _camera) or true)
	_camera = null

func _timekeeper_process(time: float, _e_delta: float) -> void:
	if !_camera:
		return
	_time = time
#	_camera.tree_manager_process(e_delta)
	_camera_global_translation = _camera.global_transform.origin
	for body in _registrar.top_bodies:
		_process_body_recursive(body)

func _process_body_recursive(body: Body) -> void:
	# planned barycenter mechanic will expect children processed before parent
	if body.satellites:
		# skip over planet or planetoid systems we are not at or going to
		if body.flags & IS_STAR_ORBITING and not body.flags & IS_STAR \
				and body != _at_local_star_orbiter and body != _to_local_star_orbiter:
			if !_skip_local_system.get(body):
				_skip_local_system[body] = true
				for satellite in body.satellites:
					satellite.hide_visuals()
		else: # recursive process call
			_skip_local_system[body] = false
			for satellite in body.satellites:
				_process_body_recursive(satellite)
	body.tree_manager_process(_time, _camera, _camera_global_translation, show_orbits,
			show_names or show_symbols)

func _camera_move_started(to_body: Body, _is_camera_lock: bool) -> void:
	_to_local_star_orbiter = _get_local_star_orbiter(to_body)

func _camera_parent_changed(body: Body) -> void:
	_at_local_star_orbiter = _get_local_star_orbiter(body)
	_to_local_star_orbiter = null

func _get_local_star_orbiter(body: Body) -> Body:
	if body.flags & IS_STAR_ORBITING:
		return body
	if body.flags & IS_STAR:
		return null
	return _get_local_star_orbiter(body.get_parent())

