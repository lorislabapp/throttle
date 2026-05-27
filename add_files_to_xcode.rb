#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'Throttle.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Get the main target
target = project.targets.find { |t| t.name == 'Throttle' }

# Find the groups
ui_settings_group = project.main_group.find_subpath('Throttle/UI/Settings', true)
services_group = project.main_group.find_subpath('Throttle/Services', true)

# Add AssistantPane.swift
assistant_pane_file = ui_settings_group.new_file('AssistantPane.swift')
target.add_file_references([assistant_pane_file])

# Add CcusageImporter.swift
ccusage_importer_file = services_group.new_file('CcusageImporter.swift')
target.add_file_references([ccusage_importer_file])

# Save the project
project.save

puts "✅ Successfully added files to Xcode project:"
puts "   • Throttle/UI/Settings/AssistantPane.swift"
puts "   • Throttle/Services/CcusageImporter.swift"
