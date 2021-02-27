# properties.gd
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
# For float, NAN means not applicable (or don't display) and INF means unknown.
# For int, -1 means not applicable. All physical bodies have mass & m_radius
# (although possibly unknown). Other properties may apply by body type.

class_name Properties

var mass := INF
var m_radius := INF # some value required for game mechanics
var gm := NAN
var surface_gravity := NAN
var esc_vel := NAN
var e_radius := NAN
var p_radius := NAN
var hydrostatic_equilibrium := -1 # Enums.ConfidenceType
var mean_density := INF
var albedo := NAN
var surf_pres := NAN
var surf_t := NAN # NA for gas giants
var min_t := NAN
var max_t := NAN
var one_bar_t := NAN # venus, gas giants
var half_bar_t := NAN # earth, venus, gas giants
var tenth_bar_t := NAN # gas giants

const PERSIST_AS_PROCEDURAL_OBJECT := true
const PERSIST_PROPERTIES := ["mass", "m_radius",
	"gm", "surface_gravity", "esc_vel", "e_radius", "p_radius",
	"hydrostatic_equilibrium", "mean_density", "albedo", "surf_pres",
	"surf_t", "min_t", "max_t", "one_bar_t", "half_bar_t", "tenth_bar_t"]

