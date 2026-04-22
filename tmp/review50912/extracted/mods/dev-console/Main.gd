extends Node

#var gameData = preload("res://Resources/GameData.tres")

# auto-generated with setup.py script
func _ready():
	pass

#func _input(event):
#	if gameData.isCaching:
#		return
#	if gameData.menu or gameData.isDead:
#		return
#	if  gameData.interface or gameData.settings or gameData.isInspecting:
#		return
#
#	if event is InputEventMouseButton:
#		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
#			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
#			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func override_script(script_path: String) -> void:
	if !script_path or script_path.is_empty():
		return

	var script = load(script_path)
	script.reload()
	var parentScript = script.get_base_script()
	script.take_over_path(parentScript.resource_path)

