# ivoyager_support_us.gd
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
# GUI widget. A hyperlink to our Support Us page!
#
# Note: I plan to create an I, Voyager organization sponsors page and shut down
# my personal sponsors page sometime in 2021. I'll update link at that time.

extends RichTextLabel

func _ready() -> void:
	connect("meta_clicked", self, "_on_meta_clicked")

func _on_meta_clicked(_meta: String) -> void:
	OS.shell_open("https://github.com/sponsors/charliewhitfield")
