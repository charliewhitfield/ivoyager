# body_builder.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright (c) 2017-2021 Charlie Whitfield
# I, Voyager is a registered trademark of Charlie Whitfield
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
# TODO: We need API to assist building Body not from table data.
#
# Note: below the huge build_from_table() function, we have functions that
# build unpersisted parts of Body as they are added to the SceneTree, including
# I/O threaded resource loading. These are rate-limiting for building the solar
# system. Hence, we use these to determine and signal "system_ready" and to
# run the progress bar.

extends Reference
class_name BodyBuilder

const math := preload("res://ivoyager/static/math.gd") # =Math when issue #37529 fixed
const file_utils := preload("res://ivoyager/static/file_utils.gd")

const DPRINT := false
const ECLIPTIC_Z := Vector3(0.0, 0.0, 1.0)
const G := UnitDefs.GRAVITATIONAL_CONSTANT
const BodyFlags := Enums.BodyFlags

# project vars
var keep_real_precisions := true
var min_click_radius := 20.0
var max_hud_dist_orbit_radius_multiplier := 100.0
var min_hud_dist_radius_multiplier := 500.0
var min_hud_dist_star_multiplier := 20.0 # combines w/ above

var characteristics_fields := [
	"symbol", "class_type", "model_type", "light_type", "file_prefix",
	"rings_file_prefix", "rings_radius",
	"n_kn_planets", "n_kn_dwf_planets", "n_kn_minor_planets", "n_kn_comets",
	"n_nat_satellites", "n_kn_nat_satellites", "n_kn_quasi_satellites",
	"GM", "mass", "surface_gravity",
	"esc_vel", "m_radius", "e_radius", "right_ascension", "declination", "longitude_at_epoch",
	"rotation_period",
	"mean_density", "hydrostatic_equilibrium", "albedo", "surf_t", "min_t", "max_t",
	"temp_center", "temp_photosphere", "temp_corona",
	"surf_pres", "trace_pres", "trace_pres_low", "trace_pres_high", "one_bar_t", "half_bar_t",
	"tenth_bar_t",
	"galactic_orbital_speed", "velocity_vs_cmb", "velocity_vs_near_stars",
	"dist_galactic_core", "galactic_period", "stellar_classification", "absolute_magnitude",
	"luminosity", "color_b_v", "metallicity", "age"
]
var flag_fields := {
	BodyFlags.IS_DWARF_PLANET : "dwarf",
	BodyFlags.IS_TIDALLY_LOCKED : "tidally_locked",
	BodyFlags.IS_AXIS_LOCKED : "axis_locked",
	BodyFlags.TUMBLES_CHAOTICALLY : "tumbles_chaotically",
	BodyFlags.HAS_ATMOSPHERE : "atmosphere",
}

# read-only
var progress := 0 # for external progress bar

# private
var _ecliptic_rotation: Basis = Global.ecliptic_rotation
var _settings: Dictionary = Global.settings
var _bodies_2d_search: Array = Global.bodies_2d_search
var _times: Array = Global.times
var _body_registry: BodyRegistry
var _model_builder: ModelBuilder
var _rings_builder: RingsBuilder
var _light_builder: LightBuilder
var _huds_builder: HUDsBuilder
var _orbit_builder: OrbitBuilder
var _composition_builder: CompositionBuilder
var _io_manager: IOManager
var _scheduler: Scheduler
var _table_reader: TableReader
var _main_prog_bar: MainProgBar
var _Body_: Script
var _ModelController_: Script
var _fallback_body_2d: Texture
# system build in progress
var _is_building_system := false
var _system_build_count: int
var _system_finished_count: int
var _system_build_start_msec := 0
# body build in progress
var _table_name: String
var _row: int
var _real_precisions := {}

func init_system_build() -> void:
	# Track when Bodies are completely finished (including I/O threaded
	# resource loading) to signal "system_ready" and run the progress bar.
	progress = 0
	_is_building_system = true
	_system_build_count = 0
	_system_finished_count = 0
	_io_manager.callback(self, "_start_system_build_msec") # after existing I/O jobs
	if _main_prog_bar:
		_main_prog_bar.start(self)

func build_from_table(table_name: String, row: int, parent: Body) -> Body: # Main thread!
	_table_name = table_name
	_row = row
	var body: Body = _Body_.new()
	body.name = _table_reader.get_string(table_name, "name", row)
	_set_flags_from_table(body, parent)
	_set_orbit_from_table(body, parent)
	_set_characteristics_from_table(body)
	body.m_radius = body.characteristics.m_radius
	_set_compositions_from_table(body)
	_register(body, parent)
	if keep_real_precisions:
		# SelectionBuilder will grab temp dict, then erase from characteristics
		body.characteristics.temp_real_precisions = _real_precisions
		_real_precisions = {}
	return body

func _set_flags_from_table(body: Body, parent: Body) -> void:
	# flags
	var flags := _table_reader.build_flags(0, flag_fields, _table_name, _row)
	if !parent:
		flags |= BodyFlags.IS_TOP # must be in BodyRegistry.top_bodies
		flags |= BodyFlags.PROXY_STAR_SYSTEM
	var hydrostatic_equilibrium: int = _table_reader.get_enum(_table_name, "hydrostatic_equilibrium", _row)
	if hydrostatic_equilibrium >= Enums.ConfidenceType.PROBABLY:
		flags |= BodyFlags.LIKELY_HYDROSTATIC_EQUILIBRIUM
	match _table_name:
		"stars":
			flags |= BodyFlags.IS_STAR
			if flags & BodyFlags.IS_TOP:
				flags |= BodyFlags.IS_PRIMARY_STAR
			flags |= BodyFlags.NEVER_SLEEP
		"planets":
			flags |= BodyFlags.IS_STAR_ORBITING
			if not flags & BodyFlags.IS_DWARF_PLANET:
				flags |= BodyFlags.IS_TRUE_PLANET
			flags |= BodyFlags.NEVER_SLEEP
		"moons":
			flags |= BodyFlags.IS_MOON
			if flags & BodyFlags.LIKELY_HYDROSTATIC_EQUILIBRIUM \
					or _table_reader.get_bool(_table_name, "force_navigator", _row):
				flags |= BodyFlags.IS_NAVIGATOR_MOON
	body.flags = flags

func _set_orbit_from_table(body: Body, parent: Body) -> void:
	if body.flags & BodyFlags.IS_TOP:
		return
	var orbit := _orbit_builder.make_orbit_from_data(_table_name, _row, parent)
	body.set_orbit(orbit)

func _set_characteristics_from_table(body: Body) -> void:
	var characteristics := body.characteristics
	_table_reader.build_dictionary(characteristics, characteristics_fields, _table_name, _row)
	assert(characteristics.has("m_radius"))
	if keep_real_precisions:
		var precisions := _table_reader.get_real_precisions(characteristics_fields, _table_name, _row)
		var n_fields := characteristics_fields.size()
		var i := 0
		while i < n_fields:
			var precision: int = precisions[i]
			if precision != -1:
				var field: String = characteristics_fields[i]
				var index := "body/characteristics/" + field
				_real_precisions[index] = precision
			i += 1
	# Assign missing characteristics where we can
	if characteristics.has("e_radius"):
		characteristics.p_radius = 3.0 * characteristics.m_radius - 2.0 * characteristics.e_radius
		if keep_real_precisions:
			var precision := _table_reader.get_least_real_precision(_table_name, ["m_radius", "e_radius"], _row)
			_real_precisions["body/characteristics/p_radius"] = precision
	else:
		body.flags |= BodyFlags.DISPLAY_M_RADIUS
	if !characteristics.has("mass"): # moons.tsv has GM but not mass
		assert(_table_reader.has_value(_table_name, "GM", _row)) # table test
		# We could in principle calculate mass from GM, but small moon GM is poor
		# estimator. Instead use mean_density if we have it; otherwise, assign INF
		# for unknown mass.
		if characteristics.has("mean_density"):
			characteristics.mass = (PI * 4.0 / 3.0) * characteristics.mean_density * pow(characteristics.m_radius, 3.0)
			if keep_real_precisions:
				var precision := _table_reader.get_least_real_precision(_table_name, ["m_radius", "mean_density"], _row)
				_real_precisions["body/characteristics/mass"] = precision
		else:
			characteristics.mass = INF # displays "?"
	if !characteristics.has("GM"): # planets.tsv has mass, not GM
		assert(_table_reader.has_value(_table_name, "mass", _row))
		characteristics.GM = G * characteristics.mass
		if keep_real_precisions:
			var precision := _table_reader.get_real_precision(_table_name, "mass", _row)
			if precision > 6:
				precision = 6 # limited by G
			_real_precisions["body/characteristics/GM"] = precision
	if !characteristics.has("esc_vel") or !characteristics.has("surface_gravity"):
		if _table_reader.has_value(_table_name, "GM", _row):
			# Use GM to calculate missing esc_vel & surface_gravity, but only
			# if precision > 1.
			var precision := _table_reader.get_least_real_precision(_table_name, ["GM", "m_radius"], _row)
			if precision > 1:
				if !characteristics.has("esc_vel"):
					characteristics.esc_vel = sqrt(2.0 * characteristics.GM / characteristics.m_radius)
					if keep_real_precisions:
						_real_precisions["body/characteristics/esc_vel"] = precision
				if !characteristics.has("surface_gravity"):
					characteristics.surface_gravity = characteristics.GM / pow(characteristics.m_radius, 2.0)
					if keep_real_precisions:
						_real_precisions["body/characteristics/surface_gravity"] = precision
		else: # planet w/ mass
			# Use mass to calculate missing esc_vel & surface_gravity, but only
			# if precision > 1.
			var precision := _table_reader.get_least_real_precision(_table_name, ["mass", "m_radius"], _row)
			if precision > 1:
				if precision > 6:
					precision = 6 # limited by G
				if !characteristics.has("esc_vel"):
					characteristics.esc_vel = sqrt(2.0 * G * characteristics.mass / characteristics.m_radius)
					if keep_real_precisions:
						_real_precisions["body/characteristics/esc_vel"] = precision
				if !characteristics.has("surface_gravity"):
					characteristics.surface_gravity = G * characteristics.mass / pow(characteristics.m_radius, 2.0)
					if keep_real_precisions:
						_real_precisions["body/characteristics/surface_gravity"] = precision

func _set_compositions_from_table(body: Body) -> void:
	var components := body.components
	var atmosphere_composition_str := _table_reader.get_string(_table_name, "atmosphere_composition", _row)
	if atmosphere_composition_str:
		var atmosphere_composition := _composition_builder.make_from_string(atmosphere_composition_str)
		components.atmosphere = atmosphere_composition
	var trace_atmosphere_composition_str := _table_reader.get_string(_table_name, "trace_atmosphere_composition", _row)
	if trace_atmosphere_composition_str:
		var trace_atmosphere_composition := _composition_builder.make_from_string(trace_atmosphere_composition_str)
		components.trace_atmosphere = trace_atmosphere_composition
	var photosphere_composition_str := _table_reader.get_string(_table_name, "photosphere_composition", _row)
	if photosphere_composition_str:
		var photosphere_composition := _composition_builder.make_from_string(photosphere_composition_str)
		components.photosphere = photosphere_composition

func _register(body: Body, parent: Body) -> void:
	if !parent:
		_body_registry.register_top_body(body)
	_body_registry.register_body(body)

# *****************************************************************************

func _project_init() -> void:
	Global.connect("game_load_started", self, "init_system_build")
	Global.get_tree().connect("node_added", self, "_on_node_added")
	_body_registry = Global.program.BodyRegistry
	_model_builder = Global.program.ModelBuilder
	_rings_builder = Global.program.RingsBuilder
	_light_builder = Global.program.LightBuilder
	_huds_builder = Global.program.HUDsBuilder
	_orbit_builder = Global.program.OrbitBuilder
	_composition_builder = Global.program.CompositionBuilder
	_io_manager = Global.program.IOManager
	_scheduler = Global.program.Scheduler
	_table_reader = Global.program.TableReader
	_main_prog_bar = Global.program.get("MainProgBar") # safe if doesn't exist
	_Body_ = Global.script_classes._Body_
	_ModelController_ = Global.script_classes._ModelController_
	_fallback_body_2d = Global.assets.fallback_body_2d

# *****************************************************************************
# Build non-persisted after added to tree

func _on_node_added(node: Node) -> void:
	var body := node as Body
	if body:
		_build_unpersisted(body)

func _build_unpersisted(body: Body) -> void: # Main thread
	# This is after Body._enter_tree(), but before Body._ready()
	body.min_click_radius = min_click_radius
	body.max_hud_dist_orbit_radius_multiplier = max_hud_dist_orbit_radius_multiplier
	body.min_hud_dist_radius_multiplier = min_hud_dist_radius_multiplier
	body.min_hud_dist_star_multiplier = min_hud_dist_star_multiplier
	
	# Note: many builders called here ask for IOManager.callback. These are
	# processed in order, so the last callback at the end of this function will
	# have the last "finish" callback.
	if body.get_model_type() != -1:
		body.model_controller = _ModelController_.new()
		body.reset_orientation_and_rotation()
		var lazy_init: bool = body.flags & BodyFlags.IS_MOON  \
				and not body.flags & BodyFlags.IS_NAVIGATOR_MOON
		_model_builder.add_model(body, lazy_init)
	if body.has_rings():
		_rings_builder.add_rings(body)
	if body.get_light_type() != -1:
		_light_builder.add_omni_light(body)
	if body.orbit:
		_huds_builder.add_orbit(body)
	_huds_builder.add_label(body)
	body.set_hide_hud_when_close(_settings.hide_hud_when_close)
	var file_prefix := body.get_file_prefix()
	var is_star := bool(body.flags & BodyFlags.IS_STAR)
	if _is_building_system:
		_system_build_count += 1
	var array := [body, file_prefix, is_star]
	_io_manager.callback(self, "_load_textures_on_io_thread", "_io_finish", array)

func _load_textures_on_io_thread(array: Array) -> void: # I/O thread
	var file_prefix: String = array[1]
	var is_star: bool = array[2]
	var texture_2d: Texture = file_utils.find_and_load_resource(_bodies_2d_search, file_prefix)
	if !texture_2d:
		texture_2d = _fallback_body_2d
	array.append(texture_2d)
	if is_star:
		var slice_name = file_prefix + "_slice"
		var texture_slice_2d: Texture = file_utils.find_and_load_resource(_bodies_2d_search, slice_name)
		array.append(texture_slice_2d)

func _io_finish(array: Array) -> void: # Main thread
	var body: Body = array[0]
	var is_star: bool = array[2]
	var texture_2d: Texture = array[3]
	body.texture_2d = texture_2d
	if is_star:
		var texture_slice_2d: Texture = array[4]
		body.texture_slice_2d = texture_slice_2d
	if _is_building_system:
		_system_finished_count += 1
		# warning-ignore:integer_division
		progress = 100 * _system_finished_count / _system_build_count
		if _system_finished_count == _system_build_count:
			_finish_system_build()

func _start_system_build_msec(_array: Array) -> void: # I/O thread
	_system_build_start_msec = OS.get_system_time_msecs()

func _finish_system_build() -> void: # Main thread
		_is_building_system = false
		var msec :=  OS.get_system_time_msecs() - _system_build_start_msec
		print("Built %s solar system bodies in %s msec" % [_system_build_count, msec])
		var is_new_game: bool = !Global.state.is_loaded_game
		Global.emit_signal("system_tree_ready", is_new_game)
		if _main_prog_bar:
			_main_prog_bar.stop()
