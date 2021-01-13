# main_menu_manager.gd
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
# Admin GUI's should call make_button() in their project_init().

extends Reference
class_name MainMenuManager

signal button_added()
signal button_state_changed()

enum {ACTIVE, DISABLED, HIDDEN} # button_state

var button_infos := [] # read-only

func make_button(text: String, priority: int, is_splash_button: bool, is_running_button: bool,
		target_object: Object, target_method: String, target_args := [],
		button_state := ACTIVE) -> void:
	# Highest priority will be top menu item; target_object cannot be a
	# procedural object!
	button_infos.append([text, priority, is_splash_button, is_running_button,
			target_object, target_method, target_args, button_state])
	button_infos.sort_custom(self, "_sort_button_infos")
	emit_signal("button_added")

func change_button_state(text: String, button_state: int) -> void:
	for button_info in button_infos:
		if text == button_info[0]:
			button_info[7] = button_state
			break
	emit_signal("button_state_changed")

func project_init():
	var state_manager: StateManager = Global.program.StateManager
	if !Global.skip_splash_screen:
		make_button("BUTTON_START", 1000, true, false, state_manager, "build_system_tree")
		make_button("BUTTON_EXIT", 300, false, true, state_manager, "exit", [false])
	if !Global.disable_quit:
		make_button("BUTTON_QUIT", 200, true, true, state_manager, "quit", [false])

func _sort_button_infos(a: Array, b: Array) -> bool:
	return a[1] > b[1] # priority