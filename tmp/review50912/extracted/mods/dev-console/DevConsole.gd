extends CanvasLayer

@onready var ConsoleWindow : Window = $"Window"
@onready var ConsoleOutput : TextEdit = $"Window/CanvasLayer/BoxContainer/VBoxContainer/ConsoleOutput"
@onready var ConsoleInput : LineEdit = $"Window/CanvasLayer/BoxContainer/VBoxContainer/ConsoleInput"
@onready var ConsoleAutocomplete : LineEdit = $"Window/CanvasLayer/BoxContainer/VBoxContainer/ConsoleAutocomplete"

var gameData : Resource = preload("res://Resources/GameData.tres")
var console_font: FontFile = preload("res://Fonts/SourceCodePro-Regular.ttf")

# TODO: spawn, give, save? Make this a seperate mod with config option 'cheats:bool'
# TODO: exec? autoexec; user command line +exec autoexec; each line in file a command
# TODO: rework config system. Make load/save config more generic and allow mods to have their own config file

# Font: Ivrit (https://patorjk.com/software/taag/#p=display&f=Ivrit&t=Console%20v0.3.3)
var logo = "" \
+ r"   ____                      _               ___   _____  _____ " + "\n" \
+ r"  / ___|___  _ __  ___  ___ | | ___  __   __/ _ \ |___ / |___ / " + "\n" \
+ r" | |   / _ \| '_ \/ __|/ _ \| |/ _ \ \ \ / / | | |  |_ \   |_ \ " + "\n" \
+ r" | |__| (_) | | | \__ \ (_) | |  __/  \ V /| |_| | ___) | ___) |" + "\n" \
+ r"  \____\___/|_| |_|___/\___/|_|\___|   \_/  \___(_)____(_)____/ " + "\n"

const VERSION = [0, 3, 3]
const VERSION_STRING = "%d.%d.%d" % VERSION

const PREFIX = '> '
var commands = {}
var print_quietly : bool = false

var history = []
var history_index = 0
var history_count = 0

var command_tri = {}

class ConfigBase:
	var allowEval : bool = false
	var allowScript : bool = false
	var showConsoleOnStart: bool = true
	var showMinimap : bool = true
	var minimapWidth : int = 120
	var fontSizeInPx: int = 16
	var fontColorHex: String = "#DFDFDF"
	var rememberConsole: bool = false
	var consoleX: int = 480
	var consoleY: int = 815
	var consoleWidth : int = 960
	var consoleHeight : int = 240

var config : ConfigBase
var config_path : String
var GAME_DIR : String
var MODS_DIR : String
var SCRIPTS_DIR : String
var CONFIG_DIR : String

var avis_mode = false

enum DevConsoleError {
	FAILED 								= -1, 
	OK 									= 0, 
	PARSING_FAILED 						= 1, 
	PARSING_EMPTY_INPUT 				= 2,
	PARSING_INVALID_FORMAT 				= 3,
	PARSING_INVALID_INPUT 				= 4,
	PARSING_INVALID_TYPE 				= 5,
	PARSING_EMPTY_WORDS 				= 6,
	COMMAND_NOT_FOUND 					= 7,
	COMMAND_EXISTS 						= 8,
	COMMAND_NO_NAME 					= 9,
	COMMAND_ARGS_NULL 					= 10,
	COMMAND_DISCRIPTION_NULL 			= 11,
	COMMAND_FUNCTION_NULL 				= 12,
	COMMAND_FUNCTION_INVALID_NUM_ARGS 	= 13
}

func _ready():
	# This is a temporary fix for an issue where mods load after the Menu scene on boot
	# and therefore appear at the bottom of the scene tree.
	# Loader.LoadScene("Menu") # this has artificial delay so the method below will be used
	get_tree().change_scene_to_file("res://Scenes/Menu.tscn")

	GAME_DIR = OS.get_executable_path().get_base_dir()
	MODS_DIR = GAME_DIR.path_join("mods")
	SCRIPTS_DIR = GAME_DIR.path_join("scripts")
	CONFIG_DIR = GAME_DIR.path_join("config")
	
	command_clear()
	print_console(logo)

	ensure_folder(CONFIG_DIR)
	ensure_folder(SCRIPTS_DIR)

	# Config
	config = ConfigBase.new()
	config_path = CONFIG_DIR.path_join("dev-console.cfg")
	load_config()

	var ui_toggle_console_event = InputEventKey.new()
	ui_toggle_console_event.keycode = KEY_QUOTELEFT
	ProjectSettings.set_setting("input/ui_toggle_console", {"deadzone": 0.5, "events": [ui_toggle_console_event]})

	# Styles
	if config.showMinimap:
		ConsoleOutput.minimap_draw = true
		ConsoleOutput.minimap_width = clamp(config.minimapWidth, 0, 600)
	
	ConsoleWindow.add_theme_font_override("font", console_font)
	ConsoleOutput.add_theme_font_override("font", console_font)
	ConsoleInput.add_theme_font_override("font", console_font)

	ConsoleOutput.add_theme_font_size_override("font_size", config.fontSizeInPx)
	ConsoleInput.add_theme_font_size_override("font_size", config.fontSizeInPx)
	ConsoleAutocomplete.add_theme_font_size_override("normal_font_size", config.fontSizeInPx)

	if not Color.html_is_valid(config.fontColorHex):
		print_console("Invalid value for 'font_color' in config file. Make sure it is a valid hex string (e.g., #DFDFDF). The bash character is optional.")
		config.fontColorHex = "#DFDFDF"

	ConsoleOutput.add_theme_color_override("font_readonly_color", Color.html(config.fontColorHex))
	ConsoleInput.add_theme_color_override("font_color", Color.html(config.fontColorHex))
	ConsoleAutocomplete.add_theme_color_override("default_color", Color.html(config.fontColorHex))

	if config.rememberConsole:
		ConsoleWindow.position.x = config.consoleX
		ConsoleWindow.position.y = config.consoleY
		ConsoleWindow.size.x = config.consoleWidth
		ConsoleWindow.size.y = config.consoleHeight

	# Register
	register_command("help", 	["command:String:*"], 		"Find help about console commands.", command_help)
	register_command("list", 	[], 						"List of all available commands.", command_list)
	register_command("clear", 	[], 						"Clear the output.", command_clear)
	register_command("print", 	["text:String"], 			"Print text to console.", command_print)
	register_command("clearh", 	[], 						"Clear input history.", clear_history)
	register_command("printh", 	[], 						"Print input history.", command_print_history)
	register_command("exit", 	[], 						"Exit the game.", command_exit)
	register_command("quit", 	[], 						"Quit the game.", command_exit)
	register_command("restart", [], 						"Restart the game.", command_restart)	
	
	register_command("log", 	[], 						"Open godot.log file.", command_log)
	register_command("logsf", 	[], 						"Open logs folder.", command_logsf)
	register_command("mods", 	[], 						"List all installed mods.", command_mods)
	register_command("modsf", 	[], 						"Open mods folder.", command_modsf)
	register_command("hide", 	[], 						"Hide console window.", hide_console)
	register_command("flush", 	[], 						"Trigger flushing to log file.", command_flush)
	register_command("tree", 	[], 						"Print entire scene tree.", command_tree)
	register_command("top", 	[], 						"Scoll the output to the begining.", command_top)
	register_command("logo", 	[], 						"Print console logo.", func(): print_console(logo))
	register_command("version", [], 						"Print console version.", command_version)
	
	register_command("menu", 	[], 						"Load Menu map.", func(): command_load_scene("Menu"))
	register_command("config", 		["operation:String", "variable:String:*", "value:String:*"], 	"Used to get/set config variables.", command_config)
	register_command("gameData", 	["operation:String", "variable:String", "value:String:*"], 		"Used to get/set gameData variables.", command_gamedata)
	register_command("load", 		["mapPath:String", "isMenu:bool:*", "isShelter:bool:*", "isTutorial:bool:*", "hasPerma:bool:*"], "Load any valid scene.", command_load)
	register_command("LoadScene", 	["mapName:String"], "Load one of the games known maps (Menu, Death, Tutorial, Village, Attic, Shipyard, Hightway, Minefield, Radar)", command_load_scene)
	
	if config.allowEval:
		register_command("eval", ["code:String"], "Evaluate an expression.", command_eval)
	
	if config.allowScript:
		register_command("script", 	["code:String"], "Execute code.", command_script)
		register_command("scriptr", ["code:String"], "Exectue code and return.", command_scriptr)
		register_command("scriptf", ["file:String"], "Execute script file.", command_scriptf)

	generate_cl_commands()
	
	if config.showConsoleOnStart:
		show_console()

func _process(_delta):
	if !InputMap.has_action(("ui_toggle_console")):
		return
	
	if Input.is_action_just_pressed(("ui_toggle_console")):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			show_console()
		else:
			toggle_console()

	if history_count != 0 and ConsoleWindow.visible and ConsoleInput.has_focus():
		if Input.is_action_just_pressed("ui_up"):
			clear_input(get_prev_in_history())

		if Input.is_action_just_pressed("ui_down"):
			clear_input(get_next_in_history())

	if ConsoleOutput.has_focus():
		if Input.is_action_just_pressed(("ui_copy")):
			DisplayServer.clipboard_set(ConsoleOutput.get_selected_text())

func _input(event):
	if gameData.isCaching:
		return
	if gameData.menu or gameData.isDead:
		return
	if  gameData.interface or gameData.settings or gameData.isInspecting:
		return

	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _notification(what: int):
	# if DevConsole gets removed/unparented from the root (exit)
	if what == NOTIFICATION_UNPARENTED:
		if config.rememberConsole:
			config.consoleX = ConsoleWindow.position.x
			config.consoleY = ConsoleWindow.position.y
			config.consoleWidth = ConsoleWindow.size.x
			config.consoleHeight = ConsoleWindow.size.y
		save_config()

func ToAvisDurgan(t: String) -> String:
	var p = "Avis Durgan"; var r = ""
	for i in range(t.length()): 
		var s = (p[i % 10]).unicode_at(0)
		var n = t[i].unicode_at(0) + s
		if n > 126: n = n % 126
		if n < 32: n = 32
		r += String.chr(n)
	return r

func _on_line_edit_input_text_submitted(content: String):
	ConsoleAutocomplete.hide()
	
	if content == "Avis Durgan":
		avis_mode = !avis_mode
	
	if content.is_empty():
		print_console(PREFIX) # echo
		return
	
	print_console("%s%s" % [PREFIX, content]) # echo
	if history_count == 0:
		add_to_history(content)
	elif history_count > 0 and not (content == history[-1]):
		add_to_history(content)

	clear_input()
	
	var parsed : Dictionary = parse_input(content)
	var status : DevConsoleError = parsed.get("status")
	if status != DevConsoleError.OK:
		if status != DevConsoleError.PARSING_EMPTY_WORDS:
			warning("Parsing input caused an error. Returned with status: %s\nInput: '%s'" % [DevConsoleError.keys()[status], content])
		return
	
	execute_command(parsed.get("command_name"), parsed.get("command_args"))

func _on_line_edit_input_text_changed(content: String):
	content = content.strip_edges()
	ConsoleAutocomplete.text = ""

	if content.is_empty():
		ConsoleAutocomplete.hide()
	else:
		var prefixed_words = starts_with(command_tri, content)
		if prefixed_words:
			ConsoleAutocomplete.show()
			for word in prefixed_words:
				ConsoleAutocomplete.text += "[color=green]%s[/color]%s " % [content, word]
		else:
			ConsoleAutocomplete.hide()

func _on_window_close_requested():
	hide_console()

# -----------------------------------------------

## Command

func parse_input(input: String = "") -> Dictionary:
	var result = {"command_name": "", "command_args": [], "status": DevConsoleError.OK}

	if input.is_empty():
		result["status"] = DevConsoleError.PARSING_EMPTY_INPUT
		return result
	
	var words = get_list_of_words(input)

	if words.is_empty():
		result["status"] = DevConsoleError.PARSING_EMPTY_WORDS
		return result
	
	var command_name : String = words.pop_at(0)
	result["command_name"] = command_name

	if not commands.has(command_name):
		result["status"] = DevConsoleError.COMMAND_NOT_FOUND
		print_console("Command '%s' does not exists" % command_name)
		return result

	var wanted_arguments = commands[command_name].get("args")
	var optional_args = 0
	for wanted in wanted_arguments:
		if wanted.ends_with("*"):
			optional_args += 1

	var num_wanted_arguments = wanted_arguments.size()
	var num_words_got = words.size()
	
	if num_words_got < (num_wanted_arguments - optional_args):
		print_console("Not enough arguments were given to '%s'" % command_name)
		result["status"] = DevConsoleError.PARSING_INVALID_FORMAT
		return result

	var commnad_args : Array = []
	
	for i in range(min(num_words_got, num_wanted_arguments)):
		var wanted_arg: String = wanted_arguments[i]
		var word: String = str(words[i])
		
		var arg_structure : Array = wanted_arg.split(':')
		if arg_structure.size() < 2:
			result["status"] = DevConsoleError.PARSING_INVALID_FORMAT
			error("Got an invalid argument format for '%s'. Expacted argName:argType:optional but got '%s'" % [command_name, wanted_arg])
			break

		var arg_name : String = arg_structure[0]
		var arg_type : String = arg_structure[1]

		if arg_type == "String":
			commnad_args.append(word)
		
		elif arg_type == "int":
			if not word.is_valid_int():
				print_console("An Invalid argument was given to '%s'. Argument '%s' expacted to be of type '%s' but got '%s'" % [command_name, arg_name, arg_type, wanted_arg])
				result["status"] = DevConsoleError.PARSING_INVALID_TYPE
				break
			commnad_args.append(word.to_int())
		
		elif arg_type == "float":
			if not word.is_valid_float():
				print_console("An invalid argument was given to '%s'. Argument '%s' expacted to be of type '%s' but got '%s'" % [command_name, arg_name, arg_type, wanted_arg])
				result["status"] = DevConsoleError.PARSING_INVALID_TYPE
				break
			commnad_args.append(word.to_float())
		
		elif arg_type == "bool":
			if word.is_valid_int():
				commnad_args.append(false if word.to_int() == 0 else true)
			elif word == "false":
				commnad_args.append(false)
			elif word == "true":
				commnad_args.append(true)
			else:
				print_console("An invalid argument was given to '%s'. Argument '%s' expacted one of [false, true] but got '%s'" % [command_name, arg_name, word])
				result["status"] = DevConsoleError.PARSING_INVALID_TYPE
				break
		
		else:
			result["status"] = DevConsoleError.PARSING_INVALID_TYPE
			error("An invalid argument type was given to '%s'. Expacted was one of [String, int, float, bool] but got '%s'" % [command_name, wanted_arg])
			break
	
	result["command_args"] = commnad_args
	return result

func get_list_of_words(text: String):
	var words = []
	
	var in_quote = false
	var in_single_quote = false
	var is_space = false
	var is_word = false
	var is_escaped = false
	var end_of_word = false

	var chr : String = ''
	var word : String = ""
	var text_len : int = text.length()
	for i in range(text_len):
		chr = text[i]

		# SPACE
		if chr == ' ':
			if is_escaped or in_quote or in_single_quote:
				is_word = true
				word += chr
				is_escaped = false
			else:
				is_space = true
		
		# DOUBLE QUOTE
		elif chr == '"':
			if is_escaped or in_single_quote or (is_word and not in_quote):
				is_word = true
				word += chr
				is_escaped = false
			else:
				if in_quote:
					in_quote = false
					end_of_word = true
				else:
					in_quote = true
		
		# SINGLE QUOTE
		elif chr == "'":
			if is_escaped or in_quote or (is_word and not in_single_quote):
				is_word = true
				word += chr
				is_escaped = false
			else:
				if in_single_quote:
					in_single_quote = false
					end_of_word = true
				else:
					in_single_quote = true
		
		# ESCAPE
		elif chr == '\\':
			if is_escaped:
				is_word = true
				word += chr
				is_escaped = false
			else:
				is_escaped = true

		# NEWLINE
		elif chr == 'n':
			is_word = true
			if is_escaped:
				word += '\n'
				is_escaped = false
			else:
				word += chr

		# TAB
		elif chr == 't':
			is_word = true
			if is_escaped:
				word += '\t'
				is_escaped = false
			else:
				word += chr

		# ELSE
		else:
			is_word = true
			word += chr

		if is_space or (i == (text_len - 1)):
			if is_word:
				end_of_word = true
			else:
				is_space = false

		# END
		if end_of_word:
			words.append(word)
			word = ""
			in_quote = false
			in_single_quote = false
			is_space = false
			is_word = false
			is_escaped = false
			end_of_word = false

	return words

func execute_command(command_name: String, command_args: Array, quietly: bool = false) -> int:
	if not commands.has(command_name):
		warning("Cannot execute command '%s' does not exist." % command_name)
		return DevConsoleError.COMMAND_NOT_FOUND
	
	if quietly:
		print_quietly = true
		set_deferred("print_quietly", false)
	commands[command_name].get("func").callv(command_args)
	return DevConsoleError.OK

func register_command(command_name: String, command_args: Array[String], command_description: String, function: Callable) -> int:
	if command_name.is_empty():
		error("Cannot register command '' (empty string)")
		return DevConsoleError.COMMAND_NO_NAME

	if commands.has(command_name):
		error("Cannot register command '%s'. It already exist" % command_name)
		return DevConsoleError.COMMAND_EXISTS
	
	if command_args == null:
		error("Cannot register command '%s' because NULL was passed as command_args" % command_name)
		return DevConsoleError.COMMAND_ARGS_NULL
	var num_command_args = command_args.size()

	if command_description == null:
		error("Cannot register command '%s' because NULL was passed description" % command_name)
		return DevConsoleError.COMMAND_DISCRIPTION_NULL

	if function == null:
		error("Cannot register command '%s' because NULL was passed as function" % command_name)
		return DevConsoleError.COMMAND_FUNCTION_NULL
	var num_function_args = function.get_argument_count()

	if num_function_args != num_command_args:
		error("Cannot register command '%s' because passed function takes %d parameters and %d were given" % [command_name, function.get_argument_count(), command_args.size()])
		return DevConsoleError.COMMAND_FUNCTION_INVALID_NUM_ARGS
	
	info("Register command: %s" % command_name)
	
	commands[command_name] = \
	{
		"args": command_args,
		"description": command_description,
		"func": function,
	}

	# Autocomplete
	insert_word(command_tri, command_name)
	return DevConsoleError.OK

func unregister_command(command_name: String) -> int:
	if not commands.has(command_name):
		warning("Cannot unregister command '%s'. It was not found" % command_name)
		return DevConsoleError.COMMAND_NOT_FOUND
	
	info("Unregister command: %s" % command_name)
	commands.erase(command_name)

	# Autocomplete
	remove_word(command_tri, command_name)
	return DevConsoleError.OK

## History

func add_to_history(input: String):
	history.append(input)
	history_count += 1
	history_index = history_count - 1

func clear_history():
	history.clear()
	history_count = 0
	history_index = 0

func get_next_in_history() -> String:
	var result = history[history_index]
	history_index += 1
	
	if history_index > history_count - 1:
		history_index = 0
	
	return result

func get_prev_in_history() -> String:
	var result = history[history_index]
	history_index -= 1
	
	if history_index < 0:
		history_index = history_count - 1
	
	return result

# Autocomplete

func insert_word(root: Dictionary, word: String):
	var current = root
	for chr in word:
		if not current.has(chr):
			current[chr] = {"end": false}
		current = current[chr]
	current["end"] = true

func remove_word(root: Dictionary, word: String):
	remove_word_recursive(root, word, 0)
	
func remove_word_recursive(current: Dictionary, word: String, index: int):
	if index == (word.length()):
		if not current["end"]:
			return false
		current["end"] = false
		return (current.keys().size() == 1)
	
	var chr = word[index]
	var next = current.get(chr)
	if next == null:
		return false

	var delete_node = remove_word_recursive(next, word, index+1)
	if delete_node:
		current.erase(chr)

func starts_with(root: Dictionary, prefix: String):
	var words = []
	
	var current = root
	for chr in prefix:
		if not current.has(chr):
			return words
		current = current[chr]
		
	start_with_recursvie(current, [], words)
	
	return words
	
func start_with_recursvie(current: Dictionary, path: Array, words: Array):
	if current.has("end") and current["end"]:
		words.append("".join(path))
	
	for chr in current.keys():
		if chr == 'end': 
			continue
		var node = current[chr]
		start_with_recursvie(node, path + [chr], words)

# -----------------------------------------------

func command_help(command_name: String = ""):
	if command_name.is_empty():
		print_console("Usage: help [command]")
		print_console("")
		print_console("When [command] is ommitted then prints this message")
		print_console("otherwise it shows extended information. Use the list")
		print_console("command to get an overview of all the available commands.")
		return
	
	if not commands.has(command_name):
		print_console("Command '%s' could not be found. See 'list' for all available commands" % command_name)
		return

	var expacted = ""
	var command_description = commands[command_name].get("description")
	for a in commands[command_name].get("args"):
		expacted += " %s" % a
	print_console("Usage: %s%s" % [command_name, expacted])
	if not command_description.is_empty():
		print_console("")
		print_console(commands[command_name].get("description"))

func command_list():
	print_console("List of commands:")
	for command_name: String in commands:
		print_console("    %-16s : %s" % [command_name, commands[command_name].get("description")])
	print_console(" ")

func command_clear():
	ConsoleOutput.text = ""

func command_print(text: String = ""):
	print("Echo: %s" % text)
	print_console(text)

func command_exit():
	get_tree().quit()

func command_log():
	var log_file_path : String = OS.get_user_data_dir().path_join("logs").path_join("godot.log")

	var err = OS.shell_open(log_file_path)
	if err != OK:
		print_console("Could not open log file: " % error_string(err))

func command_logsf():
	var logs_folder : String = OS.get_user_data_dir().path_join("logs")

	var err = OS.shell_open(logs_folder)
	if err != OK:
		print_console("Could not open logs folder: " % error_string(err))

func command_mods():
	print_console("Installed Mods:")
	
	for file_name in DirAccess.get_files_at(MODS_DIR):
		var extension = file_name.get_extension()
		if extension not in ["zip", "disabled"]:
			continue
		
		if extension == "disabled":
			print_console("    [ ] %s" % file_name)
		else:
			print_console("    [X] %s" % file_name)

func command_modsf():
	var err = OS.shell_open(MODS_DIR)
	if err != OK:
		print_console("Could not open mods folder: " % error_string(err))

func command_flush():
	push_error("forced flush")

func command_tree():
	print_console("SceneTree")
	print_console(get_tree().root.get_tree_string_pretty())

func command_top():
	ConsoleOutput.set_deferred("scroll_vertical", 0)

func command_load_scene(map_name: String):
	var maps_in_loader =  ["Menu", "Death", "Tutorial", "Village", "Shipyard", "Hightway", "Minefield", "Radar", "Attic"]
	if not (map_name in maps_in_loader):
		print_console("Map '%s' could not be found in %s" % [map_name, maps_in_loader])
		return
	
	Loader.LoadScene(map_name)

func command_load(map_path: String, is_menu: bool = false, is_shelter: bool = false, is_tutorial: bool = false, is_perma: bool = false):
	if map_path.is_empty():
		print_console("Not enough arguments. Make sure to provide at a scene name or path")
		return
	
	var scene_path = "res://Scenes/".path_join(map_path)
	var file_extention = scene_path.get_extension() 
	
	if file_extention in ["tscn", "scn"]:
		if not ResourceLoader.exists(scene_path):
			print_console("Scene '%s' does not exists" % map_path)
			return
	else:
		if ResourceLoader.exists(scene_path + ".tscn"):
			scene_path = scene_path + ".tscn"
		else:
			if ResourceLoader.exists(scene_path + ".scn"):
				scene_path = scene_path + ".scn"
			else:
				print_console("Scene '%s' could not be found" % map_path)
				return
	
	gameData.freeze = true
	gameData.menu = is_menu
	gameData.shelter = is_shelter
	gameData.tutorial = is_tutorial
	gameData.permadeath = is_perma

	print_console("Loading scene '%s' (%s, %s, %s, %s)..." % [map_path, gameData.menu, gameData.shelter, gameData.tutorial, gameData.permadeath])
	
	Loader.FadeInLoading()
	await get_tree().create_timer(2).timeout
	get_tree().create_timer(7 if gameData.isCaching else 1).timeout.connect(Loader.FadeOutLoading)
	get_tree().change_scene_to_file(scene_path)

func command_restart():
	print_console("Restarting", "")
	for i in range(3):
		await get_tree().create_timer(0.5).timeout
		print_console(".", "")
	
	var pid = OS.create_instance([])
	if pid == -1:
		print_console("Failed on starting a instance of Road To Vostok. See log for more information")
		return
	get_tree().quit()

func command_gamedata(operation: String, variable: String, value: String = ""):
	if operation == "get":
		if variable in gameData:
			print_console("gameData.%s = %s" % [variable, str(gameData.get(variable))])
		else:
			print_console("gameData has no variable named '%s'" % variable)
	
	elif operation == "set":
		if not (variable in gameData):
			print_console("gameData has no variable named '%s'" % variable)
		
		var old_value = gameData.get(variable)
		var old_type = typeof(old_value)
		
		if old_value == null:
			print_console("Could not set gameData.%s. Setting NULL in gameData is not supported yet" % variable)
			return

		if old_type == TYPE_BOOL:
			if value == "true":
				gameData.set(variable, true)
				print_console("gameData.%s = %s" % [variable, str(gameData.get(variable))])
			elif value == "false":
				gameData.set(variable, false)
				print_console("gameData.%s = %s" % [variable, str(gameData.get(variable))])
			elif value.is_valid_int():
				if value != "0":
					gameData.set(variable, true)
					print_console("gameData.%s = %s" % [variable, str(gameData.get(variable))])
				else:
					gameData.set(variable, false)
					print_console("gameData.%s = %s" % [variable, str(gameData.get(variable))])
			else:
				print_console("Could not set gameData.%s. Expacted values for type bool are [false, true, 0, 1] but got '%s'" % [variable, value])
		
		elif old_type == TYPE_FLOAT:
			if value.is_valid_float():
				gameData.set(variable, value.to_float())
				print_console("gameData.%s = %s" % [variable, str(gameData.get(variable))])
			else:
				print_console("Could not set gameData.%s. Expacted type float but got '%s'" % [variable, value])
		
		elif old_type == TYPE_INT:
			if value.is_valid_int():
				gameData.set(variable, value.to_int())
				print_console("gameData.%s = %s" % [variable, str(gameData.get(variable))])
			else:
				print_console("Could not set gameData.%s. Expacted type int but got '%s'" % [variable, value])
		
		elif old_type == TYPE_STRING:
			gameData.set(variable, value)
			print_console("gameData.%s = %s" % [variable, str(gameData.get(variable))])
		
		else:
			print_console("Variable expactes to be of type '%s' but got type '%s'" % [variable, type_string(old_type)])
	
	else:
		print_console("Unknown operation. Expacted one of [get, set] but got '%s'" % operation)

func command_config(operation: String, variable: String = "", value: String = ""):
	if operation == "get":
		if variable in config:
			print_console("%s = %s" % [variable, str(config.get(variable))])
		else:
			print_console("config has no variable '%s'" % variable)
	
	elif operation == "set":
		if not (variable in config):
			print_console("%s does not exist" % variable)
			return

		var var_value
		var var_type = typeof(config.get(variable))
		
		if var_type == TYPE_STRING:
			var_value = value
		
		elif var_type == TYPE_BOOL:
			if value == "true":
				var_value = true
			elif value == "false":
				var_value = false
			elif value.is_valid_int():
				if value != "0":
					var_value = true
				else:
					var_value = false
			else:
				print_console("Could not set '%s'. Expacted values for type bool are [false, true, 0, 1] but got '%s'" % [variable, value])

		elif var_type == TYPE_FLOAT:
			if value.is_valid_float():
				var_value = value.to_float()
			else:
				print_console("Could not set '%s'. Expacted type float but got '%s'" % [variable, value])
		
		elif var_type == TYPE_INT:
			if value.is_valid_int():
				var_value = value.to_int()
		
		else:
			error("Found unsupported type in config file: %s of type %s" % [variable, var_type])
			return
		
		config.set(variable, var_value)
		command_config("get", variable)
		save_config()

	elif operation == "list":
		print_console("List of config variables:")
		for entry in config.get_property_list():
			if entry["usage"] != PROPERTY_USAGE_SCRIPT_VARIABLE:
				continue
			
			print_console("    %s = %s" % [entry["name"], str(config.get(entry["name"]))])
	
	else:
		print_console("Unknown operation. Expacted one of [get, set] but got '%s'" % operation)

func command_eval(code: String):
	var expression = Expression.new()
	var err = expression.parse(code)
	if err != OK:
		print_console("Error: " + expression.get_error_text())
		return

	var result = expression.execute([], self)

	if expression.has_execute_failed():
		print_console("Result: Execution of expression has failed: %" % expression.get_error_text())
		return
	
	print_console("Result: " + str(result))

func command_script(code: String):
	var script_template : String = "" + \
		"extends Node\n" + \
		"\n\n" + \
		"@onready var DevConsole = get_parent()" + \
		"\n" + \
		"func execute():\n" + \
		"\t%s\n" +\
		"\tqueue_free()\n" + \
		"\treturn OK"
	var eval_script = GDScript.new()
	eval_script.resource_name = "DevConsole_Script"
	eval_script.set_source_code(script_template % code)
	var err = eval_script.reload()
	if err != 0:
		print_console("Error: failed while parsing script: %d" % err)
		eval_script.free()
		return
	
	var ref : Node = Node.new()
	ref.name = "DevConsole_Script"
	ref.set_script(eval_script)
	add_child(ref)
	
	# Code that is run by this command has to return the @GlobalScope.OK when the execution was succesfull.
	# Because we cannot check for errors the same way as in the eval command, every code run by this method 
	# will have '\nreturn OK' appended to it. This way we can check if something unexpacted happend and hint
	# the user for further information in the Engine's log files. This will not apply for 'scriptr' command.

	var status = ref.execute()
	if status != DevConsoleError.OK:
		print_console("Warning: Script did not return 0 (OK) and might have failed execution. See logs for more information")
		print_console("Result: %s" % status)
		error("Script did not return 0 (OK):")
		print("Stack: %s" % str(ref.get_stack()))
		print(ref.get_tree_string_pretty())
		ref.queue_free()

func command_scriptr(code: String = ""):
	var script_template : String = "" + \
		"extends Node\n" + \
		"\n\n" + \
		"@onready var DevConsole = get_parent()\n" + \
		"\n" + \
		"func execute_and_return(): return %s"
	var eval_script = GDScript.new()
	eval_script.resource_name = "DevConsole_ScriptAndReturn"
	eval_script.set_source_code(script_template % code)
	var err = eval_script.reload(true)
	if err != 0:
		print_console("Failed while parsing code. See logs for more information")
		eval_script.free()
		return
	
	var ref : Node = Node.new()
	ref.name = "DevConsole_ScriptAndReturn"
	ref.set_script(eval_script)
	add_child(ref)

	var result = ref.execute_and_return()
	print_console("Result: %s" % result)
	ref.queue_free()

func command_scriptf(script_name: String):
	if not script_name or script_name.is_empty():
		return
	
	if not script_name.ends_with(".gd"):
		script_name += ".gd"
	var script_path = SCRIPTS_DIR.path_join(script_name)

	if not FileAccess.file_exists(script_path):
		print_console("Script not found: %s" % script_path)
		return

	var script = GDScript.new()
	script.set_source_code(FileAccess.get_file_as_string(script_path))
	if FileAccess.get_open_error() != OK:
		print_console("Script could not be loaded: %s" % error_string(FileAccess.get_open_error()))
		script.free()
		return
	
	var err = script.reload()
	if err != OK:
		print_console("Script error: %s" % error_string(err))
		script.free()
		return

	var ref : Node = Node.new()
	ref.name = "DevConsole_ScripFile"
	ref.set_script(script)
	add_child(ref)

	#ref.queue_free()

func command_print_history():
	for entry in history:
		print_console(entry)

func command_version():
	print_console("DevConsole %s" % VERSION_STRING)

# -----------------------------------------------

func toggle_console():
	if ConsoleWindow.visible:
		hide_console() 
	else:
		show_console()

func show_console():
	ConsoleWindow.visible = true
	ConsoleWindow.grab_focus()
	ConsoleInput.grab_focus()
	Loader.ShowCursor()

func hide_console():
	ConsoleWindow.visible = false
	ConsoleInput.release_focus()
	
	if gameData.isCaching:
		return
	if gameData.menu or gameData.isDead:
		return
	if  gameData.interface or gameData.settings or gameData.isInspecting:
		return
	
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func print_console(text: String = "", newline: String = "\n"):
	if print_quietly:
		return
	text = text if not avis_mode else ToAvisDurgan(text)
	
	var num_lines = ConsoleOutput.get_line_count()
	var last_line_index = max(0, num_lines - 1)

	if newline == '\n':
		ConsoleOutput.insert_line_at(last_line_index, text)
	else:
		var column = 0
		if num_lines != 0:
			column = max(0, ConsoleOutput.get_line(last_line_index).length())
		ConsoleOutput.insert_text(newline + text, last_line_index, column)

	# scroll
	ConsoleOutput.set_deferred("scroll_vertical", ConsoleOutput.get_line_count())

func clear_input(new_input: String = ""):
	ConsoleInput.text = new_input
	if not new_input.is_empty():
		ConsoleInput.caret_column = new_input.length()

func load_config():
	if not FileAccess.file_exists(config_path):
		var message = "DevConsole config file could not be found. Making new file."
		warning(message)
		save_config()
		return
	
	var file = FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		var message = "Could not open config file: %s" % error_string(FileAccess.get_open_error())
		print_console("Error: %s" % message)
		error(message)
		return
	
	var json_obj = JSON.new() 
	var err = json_obj.parse(file.get_as_text())
	file.close()
	
	if err != OK:
		var message = "Failed parsing of config file: [Line %d] : %s" % [json_obj.get_error_line(), json_obj.get_error_message()]
		print_console("Error: %s" % message)
		error(message)
		return

	if typeof(json_obj.data) != TYPE_DICTIONARY:
		var message = "Invalid config format. Expacted Dictionary but got '%s'" % type_string(typeof(json_obj.data))
		print_console("Error: %s" % message)
		error(message)
		return
	
	for key in json_obj.data:
		config.set(key, json_obj.data[key])

func save_config():
	if not DirAccess.dir_exists_absolute(config_path.get_base_dir()):
		DirAccess.make_dir_absolute(config_path.get_base_dir())
	
	var file = FileAccess.open(config_path, FileAccess.WRITE)
	if file == null:
		var message = "Could not open config file: %s" % error_string(FileAccess.get_open_error())
		print_console("Error: %s" % message)
		error(message)
		return

	var config_json = ""
	var config_data = {}

	for prop in config.get_property_list():
		var prop_name = prop["name"]
		if not prop["usage"] == PROPERTY_USAGE_SCRIPT_VARIABLE:
			continue
		if not prop["type"] in [TYPE_STRING, TYPE_BOOL, TYPE_INT, TYPE_FLOAT]:
			continue
		
		config_data[prop_name] = config.get(prop_name)

	config_json = JSON.stringify(config_data, "    ", false)
	file.store_string(config_json)
	file.flush()
	file.close()

func generate_cl_commands():
	for prop in config.get_property_list():
		var prop_name = prop["name"]
		if not prop["usage"] == PROPERTY_USAGE_SCRIPT_VARIABLE:
			continue
		if not prop["type"] in [TYPE_STRING, TYPE_BOOL, TYPE_INT, TYPE_FLOAT]:
			continue
		
		register_command("cl_%s" % prop_name, ["value:String:*"], "Auto-generated command. Can be used to either get (omit value) or set a its config value.", func(value: String=""): execute_command("config", ["get", prop_name]) if value.is_empty() else execute_command("config", ["set", prop_name, value]))

func ensure_folder(folder_path: String):
	if not DirAccess.dir_exists_absolute(folder_path):
		DirAccess.make_dir_absolute(folder_path)

func get_error_string(error_code: int) -> String:
	if error_code == -1:
		return "FAILED"
	return DevConsoleError.keys()[error_code+1]

# -----------------------------------------------

func info(text: String = ""):
	print("INFO: %s" % text)

func warning(text: String = ""):
	push_warning(text)

func error(text: String = ""):
	push_error(text)