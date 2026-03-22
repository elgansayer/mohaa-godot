## ServerSessionManager.gd — UT-style per-server content isolation.
##
## Implements Unreal Tournament's approach to downloaded content:
##
##   1. **Shared cache** — Files are stored once in CacheManager (hash-addressed).
##      If two servers need the same map, it is downloaded once and shared.
##
##   2. **Per-server associations** — A persistent registry tracks which files
##      belong to which server (by address).  When you connect to a server,
##      only that server's files are installed into the engine VFS.
##
##   3. **All content is server-specific** — ALL downloaded files (maps and mods
##      alike) are removed from the game directory on disconnect.  This prevents
##      cross-server conflicts, since map pk3s can contain bundled models,
##      textures, or gameplay mods that would affect other servers.  The shared
##      cache still deduplicates storage — a file is only downloaded once even
##      if multiple servers use it.
##
##   4. **Session lifecycle** —
##        begin_session(server_addr)   → install server's cached files
##        end_session()                → remove ALL session files from VFS
##        associate_file(hash, type)   → link a file to the current server
##
## Persistent data lives in user://servers/server_registry.json
##
## Usage (autoload singleton "ServerSessionManager"):
##   ServerSessionManager.begin_session("192.168.1.100:12203")
##   ServerSessionManager.associate_file(hash, "map")
##   ServerSessionManager.end_session()
extends Node

## Emitted when a session begins for a server.
signal session_started(server_id: String)
## Emitted when a session ends and server-specific mods are cleaned up.
signal session_ended(server_id: String)

const SERVERS_DIR := "user://servers/"
const REGISTRY_PATH := "user://servers/server_registry.json"

## Content type constants — kept for metadata/categorization in the registry.
## Both types are treated identically: removed from game dir on disconnect.
## The distinction is informational only (e.g. for UI or cache management).
const TYPE_MAP := "map"
const TYPE_MOD := "mod"

## Engine cvar names to try when detecting the current server address.
const SERVER_ADDRESS_CVARS := ["cl_currentServerAddress", "cl_currentServerIP"]

## Registry structure:
## {
##   "<server_id>": {
##     "address": "192.168.1.100:12203",
##     "last_connected_utc": "2024-01-15T10:30:00",
##     "files": {
##       "<sha256>": {
##         "file_name": "cool_map.pk3",
##         "content_type": "map",      # "map" or "mod"
##         "added_utc": "2024-01-15T10:30:00"
##       }
##     }
##   }
## }
var _registry: Dictionary = {}
var _registry_dirty: bool = false

## Currently active session.
var _active_server_id: String = ""
## Files installed into the game dir during this session (for cleanup).
## Maps file_name → content_type.
var _session_installed: Dictionary = {}
## The game directory where pk3 files are installed.
var _game_dir: String = ""
## Reference to the MoHAARunner (discovered lazily).
var _runner: Node = null
var _runner_connected: bool = false


func _ready() -> void:
	_ensure_dirs()
	_load_registry()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_save_registry()


func _process(_delta: float) -> void:
	if not _runner_connected:
		_try_connect_runner()


# ---------------------------------------------------------------------------
# Public API — Session lifecycle
# ---------------------------------------------------------------------------

## Start a session for a server identified by its address (e.g. "192.168.1.100:12203").
## This installs any previously-cached files for this server into the game directory.
func begin_session(server_address: String) -> void:
	# End any existing session first.
	if _active_server_id != "":
		end_session()

	var server_id := _server_id_from_address(server_address)
	_active_server_id = server_id

	# Ensure server entry exists in registry.
	if not _registry.has(server_id):
		_registry[server_id] = {
			"address": server_address,
			"last_connected_utc": _utc_now(),
			"files": {},
		}
	else:
		_registry[server_id]["last_connected_utc"] = _utc_now()
	_registry_dirty = true

	# Install all cached files for this server.
	var game_dir := _get_game_dir()
	if game_dir == "":
		push_warning("ServerSessionManager: Cannot determine game directory")
	else:
		_install_server_files(server_id, game_dir)

	_save_registry()
	session_started.emit(server_id)
	print("ServerSessionManager: Session started for ", server_address, " (id=", server_id, ")")


## End the current session.  Removes ALL session files from the game
## directory to prevent cross-server content conflicts (map pk3s can contain
## bundled models or mods that would affect other servers).
func end_session() -> void:
	if _active_server_id == "":
		return

	var ended_id := _active_server_id
	_active_server_id = ""

	# Remove all session files (maps AND mods) to prevent cross-server conflicts.
	var game_dir := _get_game_dir()
	if game_dir != "":
		_cleanup_session_files(game_dir)

	_session_installed.clear()
	session_ended.emit(ended_id)
	print("ServerSessionManager: Session ended for ", ended_id)


## Returns true if a session is currently active.
func is_session_active() -> bool:
	return _active_server_id != ""


## Returns the active server ID, or "" if no session.
func get_active_server_id() -> String:
	return _active_server_id


# ---------------------------------------------------------------------------
# Public API — File associations
# ---------------------------------------------------------------------------

## Associate a cached file (by hash) with the current server session.
## content_type is TYPE_MAP or TYPE_MOD.
## file_name is the original filename (e.g. "cool_map.pk3").
func associate_file(sha256_hex: String, file_name: String, content_type: String) -> void:
	if _active_server_id == "":
		push_warning("ServerSessionManager: Cannot associate file — no active session")
		return

	var key := sha256_hex.to_lower()
	var server_data: Dictionary = _registry.get(_active_server_id, {})
	var files: Dictionary = server_data.get("files", {})

	files[key] = {
		"file_name": file_name,
		"content_type": content_type,
		"added_utc": _utc_now(),
	}

	server_data["files"] = files
	_registry[_active_server_id] = server_data
	_registry_dirty = true
	_save_registry()

	print("ServerSessionManager: Associated ", file_name, " (", content_type, ") with server ", _active_server_id)


## Check if a file (by hash) is already associated with ANY server.
## Returns true if any server has this file — used for deduplication.
func is_file_known(sha256_hex: String) -> bool:
	var key := sha256_hex.to_lower()
	for server_id in _registry:
		var server_data: Dictionary = _registry[server_id]
		var files: Dictionary = server_data.get("files", {})
		if files.has(key):
			return true
	return false


## Check if a file (by hash) is associated with the current server session.
func is_file_in_session(sha256_hex: String) -> bool:
	if _active_server_id == "":
		return false
	var key := sha256_hex.to_lower()
	var server_data: Dictionary = _registry.get(_active_server_id, {})
	var files: Dictionary = server_data.get("files", {})
	return files.has(key)


## Get all servers that have a particular file associated.
func get_servers_for_file(sha256_hex: String) -> Array:
	var key := sha256_hex.to_lower()
	var result: Array = []
	for server_id in _registry:
		var server_data: Dictionary = _registry[server_id]
		var files: Dictionary = server_data.get("files", {})
		if files.has(key):
			result.append(server_id)
	return result


## Get all file hashes associated with a server.
func get_server_files(server_id: String) -> Dictionary:
	var server_data: Dictionary = _registry.get(server_id, {})
	return server_data.get("files", {})


## Get all known server IDs.
func get_known_servers() -> Array:
	return _registry.keys()


# ---------------------------------------------------------------------------
# Public API — Install / Uninstall
# ---------------------------------------------------------------------------

## Install a specific cached file to the game directory for the current session.
## Returns true on success.
func install_file_for_session(sha256_hex: String, file_name: String, content_type: String) -> bool:
	var game_dir := _get_game_dir()
	if game_dir == "":
		push_warning("ServerSessionManager: Cannot install — no game directory")
		return false

	var cache: Node = get_node_or_null("/root/CacheManager")
	if cache == null:
		push_warning("ServerSessionManager: CacheManager not available")
		return false

	if not cache.has_file(sha256_hex):
		push_warning("ServerSessionManager: File not in cache: ", sha256_hex.left(12), "…")
		return false

	# Check if already installed in game dir.
	var dest_path := _ensure_trailing_slash(game_dir) + file_name
	if FileAccess.file_exists(dest_path):
		# File already exists — do NOT track for cleanup.
		# It may be a vanilla game file or leftover from a previous session.
		return true

	var ok := cache.install_to_game_dir(sha256_hex, game_dir)
	if ok:
		_session_installed[file_name] = content_type
	return ok


# ---------------------------------------------------------------------------
# Runner discovery & server state tracking
# ---------------------------------------------------------------------------

func _try_connect_runner() -> void:
	var root := get_tree().root
	for child in root.get_children():
		for grandchild in child.get_children():
			if grandchild.has_method("vfs_get_gamedir") and grandchild.has_signal("map_loaded"):
				_runner = grandchild
				_runner_connected = true
				_runner.map_loaded.connect(_on_map_loaded)
				if _runner.has_signal("map_unloaded"):
					_runner.map_unloaded.connect(_on_map_unloaded)
				print("ServerSessionManager: Connected to MoHAARunner.")
				return


func _on_map_loaded(_map_name: String) -> void:
	# When a map loads and we don't have an active session, try to auto-start one.
	if _active_server_id == "" and _runner:
		var server_addr := _detect_server_address()
		if server_addr != "":
			begin_session(server_addr)


func _on_map_unloaded() -> void:
	# When the map unloads (disconnect), end the session to clean up files.
	if _active_server_id != "":
		if _runner and _runner.has_method("get_server_state"):
			# Check if we're truly disconnected (server_state == 0 = SS_DEAD).
			var state: int = _runner.get_server_state()
			if state == 0:
				end_session()
		else:
			# Cannot determine server state — conservatively end session
			# to prevent cross-server content leaking.
			end_session()


## Try to detect the current server address from engine cvars.
func _detect_server_address() -> String:
	if _runner == null or not _runner.has_method("get_cvar_string"):
		return ""

	for cvar_name in SERVER_ADDRESS_CVARS:
		var val: String = _runner.get_cvar_string(cvar_name)
		if val != "" and val != "0.0.0.0" and val != "localhost":
			return val

	return ""


# ---------------------------------------------------------------------------
# Internal — File installation
# ---------------------------------------------------------------------------

## Install all cached files associated with a server.
func _install_server_files(server_id: String, game_dir: String) -> void:
	var cache: Node = get_node_or_null("/root/CacheManager")
	if cache == null:
		return

	var server_data: Dictionary = _registry.get(server_id, {})
	var files: Dictionary = server_data.get("files", {})

	for hash_key in files:
		var file_info: Dictionary = files[hash_key]
		var file_name: String = file_info.get("file_name", hash_key + ".pk3")
		var content_type: String = file_info.get("content_type", TYPE_MAP)

		if not cache.has_file(hash_key):
			# File was pruned from cache — skip it.
			continue

		var dest_path := _ensure_trailing_slash(game_dir) + file_name
		if FileAccess.file_exists(dest_path):
			# File already exists — do NOT track for cleanup.
			# It may be a vanilla game file we must not remove.
			continue

		var ok := cache.install_to_game_dir(hash_key, game_dir)
		if ok:
			_session_installed[file_name] = content_type
			print("ServerSessionManager: Pre-installed ", file_name, " for server ", server_id)


## Remove ALL session files from the game directory.
## Both maps and mods are removed to prevent cross-server content conflicts
## (map pk3s can contain bundled models, textures, or gameplay mods).
func _cleanup_session_files(game_dir: String) -> void:
	var dir_path := _ensure_trailing_slash(game_dir)
	for file_name in _session_installed:
		var full_path := dir_path + file_name
		if FileAccess.file_exists(full_path):
			var err := DirAccess.remove_absolute(full_path)
			if err == OK:
				print("ServerSessionManager: Removed session file ", file_name)
			else:
				# On Windows, the engine may still have the pk3 file open
				# (file locking).  On Linux/macOS, this is less common but
				# can happen if permissions changed.  Log the error but
				# continue cleaning up other files — the orphaned file will
				# be harmless (it's from the current session's server).
				var hint := ""
				if OS.has_feature("windows") and err == ERR_FILE_CANT_OPEN:
					hint = " (Windows: file may be locked by the engine)"
				push_warning("ServerSessionManager: Failed to remove ", file_name, " error=", err, hint)


# ---------------------------------------------------------------------------
# Internal — Registry persistence
# ---------------------------------------------------------------------------

func _ensure_dirs() -> void:
	if not DirAccess.dir_exists_absolute(SERVERS_DIR):
		DirAccess.make_dir_recursive_absolute(SERVERS_DIR)


func _load_registry() -> void:
	if not FileAccess.file_exists(REGISTRY_PATH):
		_registry = {}
		return
	var f := FileAccess.open(REGISTRY_PATH, FileAccess.READ)
	if f == null:
		push_warning("ServerSessionManager: Could not open registry: ", FileAccess.get_open_error())
		_registry = {}
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		_registry = parsed
	else:
		push_warning("ServerSessionManager: Registry parse failed, starting fresh.")
		_registry = {}


func _save_registry() -> void:
	if not _registry_dirty:
		return
	_ensure_dirs()
	var f := FileAccess.open(REGISTRY_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("ServerSessionManager: Could not write registry: ", FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify(_registry, "\t"))
	f.close()
	_registry_dirty = false


# ---------------------------------------------------------------------------
# Internal — Helpers
# ---------------------------------------------------------------------------

## UTC timestamp string for registry entries.
func _utc_now() -> String:
	return Time.get_datetime_string_from_system(true)

## Generate a stable server ID from an address string.
## Uses a simple hash to avoid filesystem-unsafe characters.
func _server_id_from_address(address: String) -> String:
	# Use the address directly if it's filesystem-safe, otherwise hash it.
	var safe := address.replace(":", "_").replace("/", "_").replace("\\", "_")
	if safe.length() > 64:
		return safe.left(64)
	return safe


func _get_game_dir() -> String:
	if _game_dir != "":
		return _game_dir

	if _runner and _runner.has_method("vfs_get_gamedir"):
		_game_dir = _runner.vfs_get_gamedir()
	if _game_dir == "":
		if _runner and _runner.has_method("get_basepath"):
			var base: String = _runner.get_basepath()
			if base != "":
				_game_dir = _ensure_trailing_slash(base) + "main"

	return _game_dir


func _ensure_trailing_slash(path: String) -> String:
	if path.ends_with("/"):
		return path
	return path + "/"
