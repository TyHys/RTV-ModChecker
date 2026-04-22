# dotFabian's DevConsole

[YouTube](https://www.youtube.com/@dotFabian) | 
[Discord Profile](https://discordapp.com/users/121671354977222657) | 
[ModWorkshop](https://modworkshop.net/user/dotfabian) | 
[X](https://x.com/dotFabianTTV)

### Mod Description
Made by me for my own use. Use it if you want or leave it. Feel free to leave some feedback or suggestions. I won't promise anything. If you are not sure then ask for permissions. Otherwise see [LICENCE.md](LICENCE.md). Use on your own risk I cannot give any guarantee. It is recommended to take a look at the code for better understanding.

This mod does not modify any existing resources.

### Features
- adds a config folder and file to the games base directory
- adds a scripts folder to the games base directory
- at least 23 pre-build commands (e.g., list, tree, clear, mods, log, gameData, restart, exit)
- gives mods the ability to register and unregister commands (make sure your mod loads after DevConsole)
- offers command suggestion (press 'TAB' to complete)
- input history (press arrow-up or arrow-down while the input field is focused)
- ability to execute code via commands 'script', 'scriptr' and 'scriptf'
- exposes the ability to load any scene via 'load' command
- exposes the Loader.LoadScene function via 'LoadScene' command

### User Manual
The default console key bind is '`' (Quote-left).

#### > print, help, list, clear, exit, restart
Your first set of tools.

#### > script, scriptr, and scriptf
These commands need to be enabled via config before being used. It is recommended to look at each commands implementation. All commands add a new Node to the scene tree (DevConsole as parent) and have a generated script attached to them. 

The 'scriptf' command will attach any script file that matches the given name if found relative to the scripts directory. In this case it is up to the script itself to queue free the Node when done.

The other two commands 'script' and 'scriptr' work by adding the given code string into their own template code. Both escape characters '\n' and '\t' can be used in the give code string. The 'scriptr' command is straight forward, it prints the return value of the given code string: "scriptr 1+1" will print "Result: 2". In this case Nodes will always be queued to be freed. Note: 'scriptr' is a one liner and new lines may not be used here.

Finally the 'script' command which has a more complex code templete. By default this one will not print any result. Because error checking isn't possible as in the 'eval' command, this code template automatically queues free and returns OK status when successfully executed which gets checked by the command itself. Should the return value not match OK a warning message will be printed along the returned value. As long as the code string manually queues free the node this method can also be used to return any desired value. In this case it allows for a far more complex code than 'scriptr' hence the ability to use new lines and tabs.

### For Mod Developer
- register_command
	- command args is an Array of strings in format "varName:varType". The ':' acts as a separator when parsing. varName cannot include any white-space characters. If you want to make an argument optional then append ':*' after the varType. See the 'help' command source code.
- unregister_command
- execute_command
	- has the option to call a registered command quietly (without printing to console)
- print_console

### Credits
- Font 'Source Code Pro' see [OFL.txt](Fonts/OFL.txt)

###### If you have read this far I do much appreciate your interest in this mod. Thank you and good luck on your journey!
