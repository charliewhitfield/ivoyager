# state_manager.gd
# This file is part of I, Voyager (https://ivoyager.dev)
# *****************************************************************************
# Copyright (c) 2017-2021 Charlie Whitfield
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
# Maintains high-level simulator state. Non-main threads should coordinate with
# signals and functions here (for safety when saving, exiting, quiting etc.). 

extends Node
class_name StateManager

const file_utils := preload("res://ivoyager/static/file_utils.gd")

# debug
const DPRINT := false

signal active_threads_allowed()
signal finish_threads_requested()
signal threads_finished()

# ****************************** UNPERSISTED **********************************

var _state: Dictionary = Global.state
var _settings: Dictionary = Global.settings
var _enable_save_load: bool = Global.enable_save_load
var _tree: SceneTree
var _saver_loader: SaverLoader
var _main_prog_bar: MainProgBar
var _system_builder: SystemBuilder
var _environment_builder: EnvironmentBuilder
var _timekeeper: Timekeeper
var _has_been_saved := false
var _was_paused := false
var _nodes_requiring_stop := []
var _active_threads := []

# *************************** PUBLIC FUNCTIONS ********************************
# Multithreading note: Godot's SceneTree and all I, Voyager public functions
# run in the main thread. Use call_defered() to invoke any function from
# another thread unless the function is guaranteed to be thread-safe (e.g,
# read-only). Most functions are NOT thread safe!

func project_init() -> void:
	connect("ready", self, "_on_ready")
	Global.connect("project_builder_finished", self, "_import_table_data", [], CONNECT_ONESHOT)
	Global.connect("table_data_imported", self, "_finish_init", [], CONNECT_ONESHOT)
	Global.connect("sim_stop_required", self, "require_stop")
	Global.connect("sim_run_allowed", self, "allow_run")
	_tree = Global.program.tree
	_saver_loader = Global.program.get("SaverLoader")
	if _saver_loader:
		_saver_loader.use_thread = Global.use_threads
	_main_prog_bar = Global.program.get("MainProgBar")
	_system_builder = Global.program.SystemBuilder
	_environment_builder = Global.program.EnvironmentBuilder
	_timekeeper = Global.program.Timekeeper

func add_active_thread(thread: Thread) -> void:
	# Add before thread.start() if you want certain functions (e.g., save/load)
	# to wait until these are removed.
	_active_threads.append(thread)

func remove_active_thread(thread: Thread) -> void:
	_active_threads.erase(thread)
	test_active_threads()

func test_active_threads() -> void:
	if !_active_threads:
		assert(DPRINT and prints("signal threads_finished") or true)
		emit_signal("threads_finished")

func require_stop(who: Object) -> void:
	# "Stopped" means the game is paused, the player is locked out from most
	# input, and non-main threads have finished. In many cases you should yield
	# to "threads_finished" after calling this function before proceeding.
	assert(DPRINT and prints("require_stop", who) or true)
	assert(DPRINT and prints("signal finish_threads_requested") or true)
	emit_signal("finish_threads_requested")
	if !_nodes_requiring_stop.has(who):
		_nodes_requiring_stop.append(who)
	if _state.is_running:
		_stop_simulator()
	call_deferred("test_active_threads")
	
func allow_run(who: Object) -> void:
	assert(DPRINT and prints("allow_run", who) or true)
	_nodes_requiring_stop.erase(who)
	if !_state.is_running and !_nodes_requiring_stop:
		_run_simulator()

func build_system_tree() -> void:
	_state.is_splash_screen = false
	_system_builder.build()
	yield(_system_builder, "finished")
	_state.is_system_built = true
	Global.emit_signal("system_tree_built_or_loaded", true)
	yield(_tree, "idle_frame")
	Global.emit_signal("system_tree_ready", true)
	yield(_tree, "idle_frame")
	Global.emit_signal("about_to_start_simulator", true)
	allow_run(self)
	yield(_tree, "idle_frame")
	Global.emit_signal("gui_refresh_requested")

func exit(exit_now: bool) -> void:
	if Global.disable_exit:
		return
	if !exit_now and _enable_save_load:
		OneUseConfirm.new("LABEL_EXIT_WITHOUT_SAVING", self, "exit", [true])
		return
	require_stop(self)
	yield(self, "threads_finished")
	Global.emit_signal("about_to_exit")
	Global.emit_signal("about_to_free_procedural_nodes")
	yield(_tree, "idle_frame")
	SaverLoader.free_procedural_nodes(_tree.get_root())
	_state.is_splash_screen = true
	_state.is_system_built = false
	_state.is_running = false
	_state.is_loaded_game = false
	_state.last_save_path = ""
	_was_paused = false
	Global.emit_signal("simulator_exited")

func quick_save() -> void:
	if _has_been_saved and _settings.save_base_name and file_utils.is_valid_dir(_settings.save_dir):
		Global.emit_signal("close_main_menu_requested")
		var date_string: String = _timekeeper.get_current_date_for_file() \
				if _settings.append_date_to_save else ""
		save_game(file_utils.get_save_path(_settings.save_dir, _settings.save_base_name,
				date_string, true))
	else:
		Global.emit_signal("save_dialog_requested")

func save_game(path: String) -> void:
	if !path:
		Global.emit_signal("save_dialog_requested")
		return
	print("Saving " + path)
	require_stop(self)
	yield(self, "threads_finished")
	assert(Debug.rprint("Node count before save: ", _tree.get_node_count()))
	assert(!print_stray_nodes())
	assert(Debug.logd("This is before save!"))
	assert(Debug.logd(_saver_loader.debug_log(_tree)))
	var save_file := File.new()
	save_file.open(path, File.WRITE)
	_state.last_save_path = path
	if _main_prog_bar:
		_main_prog_bar.start(_saver_loader)
	Global.emit_signal("game_save_started")
	_saver_loader.save_game(save_file, _tree)
	yield(_saver_loader, "finished")
	Global.emit_signal("game_save_finished")
	if _main_prog_bar:
		_main_prog_bar.stop()
	_has_been_saved = true
	allow_run(self)

func quick_load() -> void:
	if _state.last_save_path:
		Global.emit_signal("close_main_menu_requested")
		load_game(_state.last_save_path)
	else:
		Global.emit_signal("load_dialog_requested")
	
func load_game(path: String) -> void:
	if path == "":
		Global.emit_signal("load_dialog_requested")
		return
	print("Loading " + path)
	var save_file := File.new()
	if !save_file.file_exists(path):
		print("ERROR: Could not find " + path)
		return
	_state.is_splash_screen = false
	_state.is_system_built = false
	require_stop(self)
	yield(self, "threads_finished")
	_state.is_loaded_game = true
	save_file.open(path, File.READ)
	if _main_prog_bar:
		_main_prog_bar.start(_saver_loader)
	Global.emit_signal("about_to_free_procedural_nodes")
	Global.emit_signal("game_load_started")
	_saver_loader.load_game(save_file, _tree)
	yield(_saver_loader, "finished")
	_test_load_version_warning()
	Global.emit_signal("game_load_finished")
	if _main_prog_bar:
		_main_prog_bar.stop()
	_was_paused = _settings.loaded_game_is_paused or _timekeeper.is_paused
	_state.is_system_built = true
	Global.emit_signal("system_tree_built_or_loaded", false)
	yield(_tree, "idle_frame")
	Global.emit_signal("system_tree_ready", false)
	yield(_tree, "idle_frame")
	assert(Debug.logd("This is after load & system_tree_ready!"))
	assert(Debug.logd(_saver_loader.debug_log(_tree)))
	assert(Debug.rprint("Node count after load: ", _tree.get_node_count()))
	assert(!print_stray_nodes())
	Global.emit_signal("about_to_start_simulator", false)
	yield(_tree, "idle_frame")
	allow_run(self)
	Global.emit_signal("gui_refresh_requested")
	
func quit(quit_now: bool) -> void:
	if Global.disable_quit:
		return
	if !quit_now and !_state.is_splash_screen and _enable_save_load:
		OneUseConfirm.new("LABEL_QUIT_WITHOUT_SAVING", self, "quit", [true])
		return
	require_stop(self)
	yield(self, "threads_finished")
	Global.emit_signal("about_to_quit")
	assert(!print_stray_nodes())
	print("Quitting...")
	_tree.quit()
	if Global.is_html5:
		JavaScript.eval("window.close()")

func save_quit() -> void:
	Global.connect("game_save_finished", self, "quit", [true])
	quick_save()

# *********************** VIRTUAL & PRIVATE FUNCTIONS *************************

func _init() -> void:
	_on_init()

func _on_init() -> void:
	_state.is_inited = false
	_state.is_splash_screen = true
	_state.is_system_built = false
	_state.is_running = false
	_state.is_loaded_game = false
	_state.last_save_path = ""

func _on_ready() -> void:
	require_stop(self)

func _import_table_data() -> void:
	yield(_tree, "idle_frame")
	var table_importer: TableImporter = Global.program.TableImporter
	table_importer.import_table_data()
	Global.program.erase("TableImporter")
	Global.emit_signal("table_data_imported")

func _finish_init() -> void:
	_environment_builder.add_world_environment() # this is really slow!!!
	yield(_tree, "idle_frame")
	_state.is_inited = true
	print("StateManager inited...")
	Global.emit_signal("main_inited")
	if Global.skip_splash_screen:
		build_system_tree()

func _stop_simulator() -> void:
	# Project must ensure that state does not change during stop (in
	# particular, persist vars during save/load).
	print("Stop simulator")
	_was_paused = _tree.paused
	_tree.paused = true
	_state.is_running = false
	Global.emit_signal("run_state_changed", false)
	
func _run_simulator() -> void:
	print("Run simulator")
	_state.is_running = true
	Global.emit_signal("run_state_changed", true)
	_tree.paused = _was_paused
	assert(DPRINT and prints("signal active_threads_allowed") or true)
	emit_signal("active_threads_allowed")

func _test_load_version_warning() -> void:
	if Global.current_project_version != Global.project_version \
			or Global.current_ivoyager_version != Global.ivoyager_version:
		print("WARNING! Loaded game was created with a different version...")
		prints("Present running version: ", Global.current_ivoyager_version,
				Global.current_project_version)
		prints("Loaded game started as:  ", Global.ivoyager_version, Global.project_version)

