extends Node

var runner = null
var screenshot_pending = false
var screenshot_timer = 0.0
const SCREENSHOT_DELAY = 1.5 # seconds after map load to take screenshot
var status_log_timer = 0.0
var launch_dedicated = false
# launch_map: empty = start at main menu; set via --map= or ?map= URL param
var launch_map = ""
# exec_cfg: exec this config at startup (e.g. "server.cfg" loads its map)
var exec_cfg = ""
var last_state_logged = -999
var web_net_tweaks_applied = false
var last_web_reported_map = ""

# -- Cached platform checks (avoid per-frame string lookups) --
var _is_web := false
var _js: Object = null # JavaScriptBridge singleton, cached once

# -- JS bridge throttle (web) --
# Batching JS eval calls and running them at a fixed interval instead of every
# frame avoids the overhead of crossing the WASM↔JS boundary 4+ times per
# rendered frame.  At 60 fps the unthrottled path would issue ~240 bridge
# calls/sec; 250 ms throttle reduces that to ~16/sec — a 15× reduction.
const _JS_POLL_INTERVAL := 0.25 # seconds between JS bridge batches
var _js_poll_timer := 0.0

# -- FPS counter --
var _fps_label: Label = null
var _fps_visible := false
var _fps_update_timer := 0.0
const _FPS_UPDATE_INTERVAL := 0.5 # refresh every 500 ms to avoid per-frame text allocation

func _ready():
	print("Main: Script started.")

	# Cache platform checks once instead of calling OS.has_feature() every frame.
	_is_web = OS.has_feature("web")
	if _is_web and Engine.has_singleton("JavaScriptBridge"):
		_js = Engine.get_singleton("JavaScriptBridge")

	# WebGL2 cannot reliably handle 8x MSAA — disable to prevent framebuffer
	# incomplete errors (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT) and black screen.
	if _is_web:
		get_viewport().msaa_3d = Viewport.MSAA_DISABLED

	_setup_fps_counter()

	if not ClassDB.class_exists("MoHAARunner"):
		printerr("Main: ERROR - Class 'MoHAARunner' not found in ClassDB. Extension might fail to load.")
		return

	print("Main: 'MoHAARunner' found in ClassDB.")
	runner = ClassDB.instantiate("MoHAARunner")

	# Parse command-line args (after --):
	#   --dedicated      Launch as dedicated server
	#   --client         Force client mode
	#   --map=<name>     Startup map override
	#   --exec=<cfg>     Exec config at startup (e.g. --exec=server.cfg)
	#   --server         Shorthand for --exec=server.cfg
	#   --dev / --nodev  Toggle developer mode
	#   +connect <ip>    Connect to a server (forwarded to engine)
	#   +<cmd> [args]    Any Quake-style +command forwarded to the engine
	var user_args = OS.get_cmdline_user_args()
	var dev_mode = true
	var extra_engine_cmds = "" # raw +command args forwarded to engine
	var in_plus_cmd = false # true while collecting args for a +command
	for arg in user_args:
		if arg == "--dedicated":
			launch_dedicated = true
			in_plus_cmd = false
		elif arg == "--client":
			launch_dedicated = false
			in_plus_cmd = false
		elif arg.begins_with("--map="):
			launch_map = arg.substr(6)
			in_plus_cmd = false
		elif arg.begins_with("--exec="):
			exec_cfg = arg.substr(7)
			in_plus_cmd = false
		elif arg == "--server":
			exec_cfg = "server.cfg"
			in_plus_cmd = false
		elif arg == "--nodev":
			dev_mode = false
			in_plus_cmd = false
		elif arg == "--dev":
			dev_mode = true
			in_plus_cmd = false
		elif arg.begins_with("+"):
			# Quake-style +command -- forward directly to engine
			# e.g. "+connect" "127.0.0.1" arrives as two separate user args
			extra_engine_cmds += " " + arg
			in_plus_cmd = true
		elif in_plus_cmd:
			# Value-arg following a +command (e.g. the IP in "+connect <ip>")
			extra_engine_cmds += " " + arg
			# A new +command resets this; bare args "consume" one token only
			in_plus_cmd = false

	# On web: also read URL query params
	# e.g. http://localhost:8086/mohaa.html\?map\=dm/mohdm1
	#       http://localhost:8086/mohaa.html\?server\=1   (exec server.cfg)
	if _is_web:
		var url_params = _parse_url_params()
		if url_params.has("map"):
			launch_map = url_params["map"]
		if url_params.has("exec"):
			exec_cfg = url_params["exec"]
		if url_params.has("server") and url_params["server"] == "1":
			exec_cfg = "server.cfg"
		if url_params.has("dedicated") and url_params["dedicated"] == "1":
			launch_dedicated = true
		if url_params.has("com_target_game"):
			var tg = url_params["com_target_game"]
			if tg in ["0", "1", "2"]:
				extra_engine_cmds += " +set com_target_game " + tg
		if url_params.has("connect"):
			extra_engine_cmds += " +connect " + url_params["connect"]
		if url_params.has("relay"):
			# WebSocket relay: strip any scheme prefix before storing.
			# NET_WS_BuildURL() re-applies the correct scheme based on
			# whether the value has a path (wss://) or is host:port (ws://).
			var relay_val = url_params["relay"].replace("ws://", "").replace("wss://", "")
			extra_engine_cmds += " +set net_ws_relay " + relay_val
		else:
			# Auto-default: relay runs on same host as web server, port 12300
			var relay_url = _auto_relay_url()
			if relay_url != "":
				extra_engine_cmds += " +set net_ws_relay " + relay_url
				print("Main: Auto-detected relay URL -> ", relay_url)

	if runner:
		var startup_args = "+set dedicated %d +set developer %d +set cheats 1 +set thereisnomonkey 1" % [
			1 if launch_dedicated else 0,
			1 if dev_mode else 0
		]
		# In non-dedicated dev mode, force single-player gametype so the
		# player spawns directly instead of entering spectator mode.
		# The user's saved config (omconfig.cfg) may have "g_gametype 1"
		# which persists and causes RF_DONTDRAW → invisible FPS model.
		if not launch_dedicated:
			startup_args += " +set g_gametype 0"
		if _is_web:
			# Web: emscripten VFS root = game data dir; GameSpy off
			startup_args += " +set fs_basepath . +set fs_homedatapath . +set fs_homepath . +set r_fullscreen 0 +set ui_gamespy 0 +set sv_gamespy 0"

		# Startup command: exec config takes priority over direct map load.
		# In debug client runs, prefer devmap so cheat-gated cvars remain writable.
		if exec_cfg != "":
			startup_args += " +exec " + exec_cfg
		elif launch_map != "":
			if dev_mode and not launch_dedicated:
				startup_args += " +devmap " + launch_map
			else:
				startup_args += " +map " + launch_map
		# else: no startup command -> engine shows main menu

		# Append any raw +command args forwarded from user args (e.g. +connect <ip>)
		if extra_engine_cmds != "":
			startup_args += extra_engine_cmds

		runner.set_startup_args(startup_args)
		if _is_web and _js:
			# Expose effective startup command line for browser-side diagnostics.
			_js.eval("window.__mohaaStartupArgs = " + JSON.stringify(startup_args) + ";")
			_js.eval("window.__mohaaLaunchMap = " + JSON.stringify(launch_map) + ";")
		runner.name = "MoHAARunnerInstance"
		add_child(runner)
		print("Main: MoHAARunner added to tree.")
		print("Main: Startup args -> ", startup_args)
		if exec_cfg != "":
			print("Main: Exec cfg -> ", exec_cfg)
		elif extra_engine_cmds != "":
			print("Main: Extra engine cmds -> ", extra_engine_cmds.strip_edges())
		elif launch_map != "":
			print("Main: Startup map -> ", launch_map)
		else:
			print("Main: Starting at main menu (no auto-map).")

		runner.engine_error.connect(_on_engine_error)
		runner.map_loaded.connect(_on_map_loaded)
		runner.map_unloaded.connect(_on_map_unloaded)
		runner.engine_shutdown_requested.connect(_on_engine_shutdown)
	else:
		print("Main: Failed to instantiate MoHAARunner.")

# Parse URL query string into a dictionary (web only).
func _parse_url_params() -> Dictionary:
	var result = {}
	if not _is_web:
		return result
	var query = ""
	if _js:
		var q = _js.eval("window.location.search")
		if typeof(q) == TYPE_STRING:
			query = q
	if query.begins_with("?"):
		query = query.substr(1)
	for pair in query.split("&"):
		var kv = pair.split("=", true, 2)
		if kv.size() == 2:
			result[kv[0].uri_decode()] = kv[1].uri_decode()
		elif kv.size() == 1 and kv[0] != "":
			result[kv[0]] = "1"
	return result

# Auto-detect relay URL from the current page hostname (web only).
# Returns the value stored in net_ws_relay — no scheme prefix, because the
# Quake command parser treats // as a comment delimiter.
# NET_WS_BuildURL() in net_ws.c applies the correct scheme:
#   - value contains '/'  →  wss://value   (HTTPS reverse-proxy path)
#   - value is host:port  →  ws://value    (plain LAN/direct relay)
func _auto_relay_url() -> String:
	if not _js:
		return ""
	var hostname = _js.eval("window.location.hostname")
	if typeof(hostname) != TYPE_STRING or hostname == "":
		return ""
	# The relay always runs behind the nginx /relay proxy — both in Docker
	# (port 80 inside container, mapped to host 8086) and in production
	# (HTTPS reverse-proxy).  Never connect to port 12300 directly; it is
	# only exposed inside the container.
	var protocol = _js.eval("window.location.protocol")
	if typeof(protocol) == TYPE_STRING and protocol == "https:":
		# HTTPS — default port (443); scheme handled by NET_WS_BuildURL.
		return hostname + "/relay"
	# HTTP — include the explicit port so the browser connects to the
	# same origin (e.g. localhost:8086/relay, not localhost:12300).
	var port = _js.eval("window.location.port")
	if typeof(port) == TYPE_STRING and port != "" and port != "80":
		return hostname + ":" + port + "/relay"
	return hostname + "/relay"

# -- FPS counter setup --
# Lightweight overlay label on a dedicated CanvasLayer so it draws on top of
# the engine viewport.  Hidden by default; toggled with F3.
func _setup_fps_counter():
	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		return
	var layer = CanvasLayer.new()
	layer.layer = 100 # above everything
	layer.name = "FPSLayer"
	add_child(layer)

	_fps_label = Label.new()
	_fps_label.text = ""
	_fps_label.visible = false
	_fps_label.add_theme_font_size_override("font_size", 18)
	_fps_label.add_theme_color_override("font_color", Color(0.0, 1.0, 0.0))
	_fps_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.8))
	_fps_label.add_theme_constant_override("shadow_offset_x", 1)
	_fps_label.add_theme_constant_override("shadow_offset_y", 1)
	_fps_label.position = Vector2(8, 8)
	layer.add_child(_fps_label)

# -- Signal handlers --

func _on_engine_error(message: String):
	printerr("Main: ENGINE ERROR: ", message)
	if _is_web and _js:
		# Expose engine init/runtime failures to browser E2E harness.
		_js.eval("window.__mohaaEngineError = " + JSON.stringify(message) + ";")

func _on_map_loaded(map_name: String):
	print("Main: SIGNAL map_loaded -> ", map_name)
	if _is_web and _js:
		# Expose map-load state for deterministic browser E2E tests.
		_js.eval("window.__mohaaMapLoaded = " + JSON.stringify(map_name) + ";")
	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		print("Main: Headless mode detected, skipping auto screenshot.")
		return
	screenshot_pending = true
	screenshot_timer = 0.0
	print("Main: Screenshot scheduled in ", SCREENSHOT_DELAY, "s")

func _on_map_unloaded():
	print("Main: SIGNAL map_unloaded")

func _on_engine_shutdown():
	print("Main: SIGNAL engine_shutdown_requested")
	if _is_web and _js:
		_js.eval("if(typeof onEngineQuit === 'function') onEngineQuit();")
		print("Main: Called JS onEngineQuit()")
	# Quit the Godot tree. On web this stops the Emscripten main loop
	# (preventing CxxException storms); the JS onEngineQuit() handler
	# navigates back to the game selector after a short delay.
	get_tree().quit()

func _unhandled_key_input(event: InputEvent):
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	# Keep this at Main.gd level so Meta+Enter always works even if input map bindings change.
	if event.meta_pressed and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
		var is_now_fs = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		if is_now_fs:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		# Keep the engine's r_fullscreen cvar in sync with the Godot window mode
		# so that vid_restart preserves the correct fullscreen state.
		if runner and runner.is_engine_initialized():
			runner.execute_command("set r_fullscreen %d" % (0 if is_now_fs else 1))
		print("Main: Fullscreen toggled (Meta+Enter)")
		return

	if event.is_action("toggle_mouse_capture"):
		if runner:
			var captured = runner.is_mouse_captured()
			runner.set_mouse_captured(not captured)
			print("Main: Mouse capture toggled -> ", not captured)
	elif event.is_action("screenshot"):
		take_screenshot("manual")
	elif event.is_action("toggle_hud"):
		if runner:
			runner.set_hud_visible(not runner.is_hud_visible())
			print("Main: HUD toggled -> ", runner.is_hud_visible())
	elif event.is_action("toggle_fullscreen"):
		var fs_mode = DisplayServer.window_get_mode()
		var going_fs = fs_mode != DisplayServer.WINDOW_MODE_FULLSCREEN
		if going_fs:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		if runner and runner.is_engine_initialized():
			runner.execute_command("set r_fullscreen %d" % (1 if going_fs else 0))
		print("Main: Fullscreen toggled")
	elif event.keycode == KEY_F3:
		# F3 -- toggle FPS counter overlay
		_fps_visible = not _fps_visible
		if _fps_label:
			_fps_label.visible = _fps_visible
		print("Main: FPS counter -> ", "ON" if _fps_visible else "OFF")
	elif event.keycode == KEY_F10:
		# F10 -- exec server.cfg (listen server: host + play on dm/mohdm1)
		if runner and runner.is_engine_initialized():
			runner.execute_command("exec server.cfg; set ui_gamespy 0; set sv_gamespy 0")
			print("Main: Executed -> exec server.cfg; set ui_gamespy 0; set sv_gamespy 0")
	elif event.keycode == KEY_F11:
		# F11 -- connect to localhost as pure client (join local server)
		if runner and runner.is_engine_initialized():
			runner.execute_command("connect localhost")
			print("Main: Executed -> connect localhost")

func _process(delta):
	# -- FPS counter update (throttled) --
	if _fps_visible and _fps_label:
		_fps_update_timer += delta
		if _fps_update_timer >= _FPS_UPDATE_INTERVAL:
			_fps_update_timer = 0.0
			_fps_label.text = "%d FPS" % Engine.get_frames_per_second()

	# One-time GameSpy re-disable for web (in case engine reset the cvars)
	if _is_web and runner and runner.is_engine_initialized() and not web_net_tweaks_applied:
		web_net_tweaks_applied = true
		runner.execute_command("set ui_gamespy 0; set sv_gamespy 0")
		print("Main: Web tweaks applied -> ui_gamespy=0 sv_gamespy=0")

	# -- Web JS bridge (throttled) --
	# All JS↔WASM bridge calls are batched into a single interval instead of
	# running every frame.  This avoids 4+ js.eval() calls per rendered frame
	# which are expensive cross-boundary calls on Emscripten.
	if _is_web and _js and runner and runner.is_engine_initialized():
		_js_poll_timer += delta
		if _js_poll_timer >= _JS_POLL_INTERVAL:
			_js_poll_timer = 0.0
			# Poll for pending commands from browser E2E tests.
			var cmd = _js.eval("(function(){ var c = window.__mohaaPendingCommand; if(typeof c === 'string' && c.length > 0){ window.__mohaaPendingCommand = ''; return c; } return ''; })()")
			if typeof(cmd) == TYPE_STRING and cmd != "":
				print("Main: JS command bridge -> ", cmd)
				runner.execute_command(cmd)

			# Expose engine state for E2E diagnostics — single batched eval
			# instead of three separate calls.
			var server_state = runner.get_server_state()
			var current_map = runner.get_current_map()
			_js.eval(
				"window.__mohaaServerState=%d;"
				% server_state
				+ "window.__mohaaCurrentMap=%s;"
				% JSON.stringify(current_map)
				+ "window.__mohaaEngineInit=true;"
			)

			# Map-loaded fallback for startup maps already active before
			# the signal path fires.
			if current_map != "" and server_state == 3 and current_map != last_web_reported_map:
				last_web_reported_map = current_map
				_js.eval(
					"window.__mohaaMapLoaded=%s;"
					% JSON.stringify(current_map)
					+ "window.__mohaaMapLoadedLog=%s;"
					% JSON.stringify("Main: POLL map_loaded -> " + current_map)
				)
				print("Main: POLL map_loaded -> ", current_map)

	if screenshot_pending:
		screenshot_timer += delta
		if screenshot_timer >= SCREENSHOT_DELAY:
			screenshot_pending = false
			take_screenshot("auto")

	if runner and runner.is_engine_initialized():
		var server_state = runner.get_server_state()
		var current_map = runner.get_current_map()
		if server_state != last_state_logged:
			last_state_logged = server_state
			print("Main: server_state -> ", runner.get_server_state_string(),
				" (", server_state, ")")

		status_log_timer += delta
		if status_log_timer >= 5.0:
			status_log_timer = 0.0
			print("Main: Status state=", runner.get_server_state_string(),
				" map=", current_map,
				" players=", runner.get_player_count())

func take_screenshot(label: String):
	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		print("Main: Screenshot skipped in headless mode.")
		return
	var tex = get_viewport().get_texture()
	if tex == null:
		printerr("Main: Screenshot skipped, viewport texture unavailable")
		return
	var img = tex.get_image()
	if img:
		var path = "/tmp/godot_screenshot_" + label + ".png"
		var err = img.save_png(path)
		if err == OK:
			print("Main: Screenshot saved -> ", path,
" (", img.get_width(), "x", img.get_height(), ")")
		else:
			printerr("Main: Screenshot save failed: ", err)
	else:
		printerr("Main: Could not get viewport image")
