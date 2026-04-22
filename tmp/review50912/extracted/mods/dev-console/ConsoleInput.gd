extends LineEdit

@onready var DevConsole = $"/root/DevConsole"

func _input(_event):
	if not InputMap.has_action(("ui_toggle_console")):
		return
	
	if Input.is_action_just_pressed("ui_toggle_console"):
		if has_focus():
			accept_event()
			release_focus()

	if Input.is_action_just_pressed(("ui_text_indent")):
		var content = text.strip_edges()
		if content.is_empty():
			DevConsole.ConsoleAutocomplete.hide()
		
		else:
			var prefixed_words = DevConsole.starts_with(DevConsole.command_tri, content)
			if prefixed_words and not content.ends_with(prefixed_words[0]):
				text += prefixed_words[0]
			call_deferred("emit_signal", "text_changed", text)
			call_deferred("grab_focus")

		set_deferred("caret_column", text.length())

	if Input.is_action_pressed(("ui_text_indent")):
		accept_event()