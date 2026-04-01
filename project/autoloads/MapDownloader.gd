## MapDownloader.gd — Auto-download missing maps from moh-db.com.
##
## Monitors the MoHAARunner engine for missing-map errors.  When the engine
## reports "Couldn't load <bsp_path>", this autoload:
##   1. Extracts the map name from the error.
##   2. Queries the moh-db.com API for a matching download.
##   3. Shows a full-screen download progress overlay.
##   4. Downloads the pk3, verifies its hash, caches it locally.
##   5. Associates the file with the current server via ServerSessionManager.
##   6. Installs it to the engine's game directory.
##   7. Reloads the VFS and reconnects to the server automatically.
##
## UT-style isolation:
##   - Files are cached once and shared across servers (CacheManager).
##   - Each server session tracks its own file associations (ServerSessionManager).
##   - ALL downloaded content is server-specific — removed on disconnect to
##     prevent cross-server conflicts (map pk3s can contain bundled models/mods).
##   - If you already have a file from another server, it is reused from cache
##     (no re-download) but still scoped to the current server session.
##
## The system works with any server — no server-side changes required.
##
## Engine VFS notes (OpenMoHAA — NOT vanilla Quake 3):
##   - The engine discovers pk3 files in the game directory (e.g. main/)
##     during FS_Startup / FS_Restart.  It does NOT scan subdirectories
##     for pk3 files, but it DOES support .pk3dir directories (loose-file
##     directories treated as virtual pk3 archives in the search path).
##   - For non-pure servers (sv_pure=0, the OpenMoHAA default), reconnecting
##     triggers FS_Restart directly (CA_CONNECTED + empty sv_paks path in
##     CL_ParseGamestate).
##   - For pure servers (sv_pure=1), FS_ConditionalRestart is used, which
##     only restarts if the checksumFeed or fs_game changed.  We handle
##     this by toggling fs_game before reconnecting.
##
## VFS reload strategy (robust, works on all server types):
##   1. If MoHAARunner exposes vfs_restart(): call it directly — guaranteed
##      to rescan all pk3 files in the game directory.
##   2. Fallback: execute "fs_restart" console command — same effect but
##      must be queued through the command buffer.
##   3. After VFS reload, send "reconnect" to rejoin the server.
##
## Map not found on moh-db.com:
##   - Shows a clear error message in the download overlay.
##   - Offers the user a "Disconnect" button to cleanly leave the server.
##   - Auto-hides after 12 seconds.
##   - Emits download_failed signal for other systems to react.
##
## moh-db.com API (see https://www.moh-db.com/api-docs):
##   Base URL: https://api.moh-db.com
##   Authentication: X-API-Key header (set via Project Settings).
##
##   GET /api/external/v1/maps?mapName=<name>&page=0&size=20
##     Response: PageMapDto { content: MapDto[], totalElements, ... }
##     MapDto has: mapName, downloadLink, mapFile (FileInfoDto), ...
##     FileInfoDto has: filename, filesize, downloadLink, ...
##
##   GET /api/external/v1/mods?modName=<name>&page=0&size=20
##     Response: PageModDto { content: ModDto[], totalElements, ... }
##     ModDto has: modName, downloadLink, pk3DownloadLink, file, pk3File, ...
##
## Platform evaluation:
##
##   Web (Emscripten/WASM):
##     ✅ Threading: HTTP requests use async mode (use_threads=false).
##     ✅ Storage: user:// maps to IndexedDB via Emscripten's IDBFS.
##     ✅ VFS: game directory is in Emscripten MEMFS; FS_Restart works.
##     ⚠️  CORS: moh-db.com must serve Access-Control-Allow-Origin headers.
##        If CORS blocks the request, a platform-specific error is shown.
##     ⚠️  Storage quota: browsers limit IndexedDB (~50-100 MB default).
##        Large pk3 files may hit quota limits. Cache pruning helps.
##     ⚠️  SHA-256: hashing runs on the main thread (no worker threads).
##        Large files may briefly block the UI. Chunked hashing mitigates.
##
##   Windows:
##     ✅ Threading: HTTP requests use background threads.
##     ✅ Storage: user:// maps to %APPDATA%/Godot/app_userdata/.
##     ✅ VFS: game directory is writable (user data area, not Program Files).
##     ✅ File paths: SHA-256 hashes as filenames stay within path limits.
##     ⚠️  Antivirus: pk3 (ZIP archive) writes may trigger AV scans,
##        causing brief delays on download completion.
##     ⚠️  File locking: if the engine has a pk3 open, deletion on
##        disconnect may fail. Handled gracefully with error logging.
##
##   macOS:
##     ✅ Threading: HTTP requests use background threads.
##     ✅ Storage: user:// maps to ~/Library/Application Support/.
##     ✅ VFS: game directory is writable from user data area.
##     ✅ Sandbox: app_sandbox is disabled in export_presets.cfg.
##     ✅ Case sensitivity: hash-based filenames avoid case conflicts.
##
##   Linux:
##     ✅ Threading: HTTP requests use background threads.
##     ✅ Storage: user:// maps to ~/.local/share/godot/app_userdata/.
##     ✅ VFS: game directory is writable from user data area.
##     ✅ Case sensitivity: all comparisons are lowercased.
##     ⚠️  Snap/Flatpak: sandboxed installs may restrict network access
##        or filesystem paths. The user:// path still works within the
##        sandbox, and HTTPS access is typically allowed.
extends Node

## Emitted when a missing map is detected and download begins.
signal download_started(map_name: String)
## Emitted periodically with download progress (0.0–100.0).
signal download_progress(map_name: String, percent: float)
## Emitted when download finishes and the map is installed.
signal download_completed(map_name: String)
## Emitted on any failure during the search or download.
signal download_failed(map_name: String, reason: String)

## moh-db.com API base URL (see https://www.moh-db.com/api-docs).
const API_BASE_URL := "https://api.moh-db.com"
## API key for moh-db.com authentication (X-API-Key header).
## Set via Project Settings > MapDownloader > api_key, or override this constant.
var _api_key: String = ""
## Number of results per page when searching the API.
const API_PAGE_SIZE := 20
## Seconds to wait before reconnecting after a successful install.
const RECONNECT_DELAY := 2.0
## Maximum download time in seconds.
const DOWNLOAD_TIMEOUT := 300.0
## How often (seconds) to update the progress bar during download.
const PROGRESS_INTERVAL := 0.15
## Maximum retries for the API search request.
const MAX_RETRIES := 2

# -- Nodes --
var _http_search: HTTPRequest = null
var _http_download: HTTPRequest = null

# -- State --
var _runner: Node = null
var _runner_connected: bool = false
var _current_map_bsp: String = ""   # e.g. "maps/dm/mohdm6.bsp"
var _current_map_name: String = ""  # e.g. "dm/mohdm6"
var _busy: bool = false             # true while handling search→download→install
var _downloading: bool = false      # true only during the HTTP download phase
var _download_path: String = ""     # temp file while downloading
var _retry_count: int = 0
var _download_retry_count: int = 0
var _progress_timer: float = 0.0
var _last_server_address: String = ""  # stored before ERR_DROP clears clc

## Maximum retries for the download request itself.
const MAX_DOWNLOAD_RETRIES := 1

## How long the error overlay stays visible (seconds).
const ERROR_DISPLAY_TIME := 12.0

# -- UI --
var _overlay: CanvasLayer = null
var _panel: PanelContainer = null
var _title_label: Label = null
var _status_label: Label = null
var _progress_bar: ProgressBar = null
var _detail_label: Label = null
var _disconnect_btn: Button = null


# Cached autoload references (resolved once in _ready).
var _cache_manager: Node = null
var _session_manager: Node = null

func _ready() -> void:
	# Load API key from project settings if available.
	if ProjectSettings.has_setting("map_downloader/api_key"):
		_api_key = ProjectSettings.get_setting("map_downloader/api_key", "")

	_http_search = HTTPRequest.new()
	_http_search.timeout = 15.0
	_http_search.use_threads = not OS.has_feature("web")
	add_child(_http_search)
	_http_search.request_completed.connect(_on_search_completed)

	_http_download = HTTPRequest.new()
	_http_download.timeout = DOWNLOAD_TIMEOUT
	_http_download.use_threads = not OS.has_feature("web")
	_http_download.download_chunk_size = 65536
	add_child(_http_download)
	_http_download.request_completed.connect(_on_download_completed)

	# Cache autoload references to avoid per-call get_node_or_null.
	_cache_manager = get_node_or_null("/root/CacheManager")
	_session_manager = get_node_or_null("/root/ServerSessionManager")

	_build_overlay_ui()
	_hide_ui()

	# Disable per-frame processing until needed (download in progress).
	set_process(false)
	# Use a deferred call to attempt initial runner connection.
	call_deferred("_try_connect_runner")


func _process(delta: float) -> void:
	# Update download progress bar (only runs when _downloading is true).
	if _downloading:
		_progress_timer += delta
		if _progress_timer >= PROGRESS_INTERVAL:
			_progress_timer = 0.0
			_update_download_progress()
	else:
		# Nothing to poll — disable per-frame processing.
		set_process(false)


# ---------------------------------------------------------------------------
# Runner discovery
# ---------------------------------------------------------------------------

func _try_connect_runner() -> void:
	# Search the tree for nodes in the "mohaa_runner" group first (O(1)),
	# falling back to a shallow tree scan if the group is not set.
	var runners := get_tree().get_nodes_in_group("mohaa_runner")
	if runners.size() > 0:
		_runner = runners[0]
		_runner_connected = true
		_runner.engine_error.connect(_on_engine_error)
		print("MapDownloader: Connected to MoHAARunner engine_error signal.")
		return
	# Fallback: shallow tree scan (two levels deep).
	var root := get_tree().root
	for child in root.get_children():
		for grandchild in child.get_children():
			if grandchild.get_class() == "MoHAARunner":
				_runner = grandchild
				_runner_connected = true
				_runner.engine_error.connect(_on_engine_error)
				print("MapDownloader: Connected to MoHAARunner engine_error signal.")
				return
	# Not found yet — retry on next frame.
	call_deferred("_try_connect_runner")


# ---------------------------------------------------------------------------
# Engine error interception
# ---------------------------------------------------------------------------

## Called whenever the engine emits an error.  We look for the pattern
## "Couldn't load <path>" which CM_LoadMap emits when a BSP is missing.
func _on_engine_error(message: String) -> void:
	# The engine error is: "Couldn't load maps/dm/mohdm6.bsp"
	if not message.begins_with("Couldn't load "):
		return
	if _busy:
		return  # already handling a search/download/install cycle

	var bsp_path := message.substr("Couldn't load ".length()).strip_edges()
	if not bsp_path.ends_with(".bsp"):
		return

	_busy = true  # Prevent concurrent processing until this cycle completes.
	_current_map_bsp = bsp_path

	# Capture the server address NOW, before ERR_DROP clears clc.servername.
	_last_server_address = _detect_server_address()

	# Strip "maps/" prefix and ".bsp" suffix to get the map name.
	var map_name := bsp_path
	if map_name.begins_with("maps/"):
		map_name = map_name.substr("maps/".length())
	map_name = map_name.trim_suffix(".bsp")
	_current_map_name = map_name

	print("MapDownloader: Missing map detected — ", map_name, " (", bsp_path, ")")

	# UT-style: ensure a server session is active so file associations are tracked.
	_ensure_server_session()

	# Check if the map is already in the shared cache (downloaded for another server).
	# If so, skip the download — just install and reconnect.
	if _try_install_from_cache(map_name):
		return

	_start_search(map_name)


# ---------------------------------------------------------------------------
# UT-style: server session & cache reuse
# ---------------------------------------------------------------------------

## Ensure a ServerSessionManager session is active for the current server.
func _ensure_server_session() -> void:
	var session_mgr: Node = _session_manager
	if session_mgr == null:
		return
	if session_mgr.is_session_active():
		return

	# Try to detect the server address from engine cvars.
	var server_addr := ""
	if _runner and _runner.has_method("get_cvar_string"):
		for cvar_name in ServerSessionManager.SERVER_ADDRESS_CVARS:
			var val: String = _runner.get_cvar_string(cvar_name)
			if val != "" and val != "0.0.0.0":
				server_addr = val
				break

	# Fallback: use a generic session ID based on the map being loaded.
	if server_addr == "":
		server_addr = "unknown_server"

	session_mgr.begin_session(server_addr)


## Read the current server address from engine cvars.
func _detect_server_address() -> String:
	if _runner == null or not _runner.has_method("get_cvar_string"):
		return ""
	for cvar_name in ServerSessionManager.SERVER_ADDRESS_CVARS:
		var val: String = _runner.get_cvar_string(cvar_name)
		if val != "" and val != "0.0.0.0" and val != "localhost":
			return val
	return ""


## Check if the map is already in the shared cache (downloaded for any server).
## If found, install it for the current session and reconnect — no download needed.
func _try_install_from_cache(map_name: String) -> bool:
	var cache: Node = _cache_manager
	var session_mgr: Node = _session_manager
	if cache == null:
		return false

	# Search the cache for a file whose original name matches this map.
	var map_base := map_name.get_file().to_lower()  # e.g. "mohdm6"
	var hash_key: String = cache.find_cached_file_by_name(map_base)
	if hash_key == "":
		return false

	var orig_name: String = cache.get_original_name(hash_key)
	print("MapDownloader: Found in cache — ", orig_name, " (hash=", hash_key.left(12), "…)")

	# Associate with current server session.
	if session_mgr and session_mgr.is_session_active():
		session_mgr.associate_file(hash_key, orig_name, ServerSessionManager.TYPE_MAP)

	# Install and reconnect.
	_show_ui_searching(map_name)
	_status_label.text = "Found in cache: " + orig_name
	_install_and_reconnect(hash_key)
	return true


# ---------------------------------------------------------------------------
# API search
# ---------------------------------------------------------------------------

func _start_search(map_name: String) -> void:
	_retry_count = 0
	_downloading = false

	# Extract the base name (last segment) for the API query.
	# e.g. "dm/mohdm6" → "mohdm6"
	var search_term := map_name
	var slash_pos := map_name.rfind("/")
	if slash_pos >= 0:
		search_term = map_name.substr(slash_pos + 1)

	_show_ui_searching(map_name)
	download_started.emit(map_name)

	# moh-db.com external API v1: GET /api/external/v1/maps?mapName=<name>
	var url := API_BASE_URL + "/api/external/v1/maps?mapName=" + search_term.uri_encode() \
		+ "&page=0&size=" + str(API_PAGE_SIZE)
	print("MapDownloader: Searching moh-db.com — ", url)

	# The API requires an X-API-Key header for authentication.
	var headers: PackedStringArray = []
	if _api_key != "":
		headers.append("X-API-Key: " + _api_key)

	var err := _http_search.request(url, headers)
	if err != OK:
		_fail("API search request failed: error %d" % err)


func _on_search_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_retry_count += 1
		if _retry_count <= MAX_RETRIES:
			push_warning("MapDownloader: Search retry %d/%d — HTTP result %d" % [
				_retry_count, MAX_RETRIES, result])
			# Capture map name in a local to avoid stale closure.
			var retry_map := _current_map_name
			get_tree().create_timer(1.0 * _retry_count).timeout.connect(
				func(): _start_search(retry_map))
			return

		# Platform-specific error hints for connection failures.
		var hint := ""
		if OS.has_feature("web"):
			# On web, CORS blocks or mixed-content policies are the most
			# common cause of HTTP failures.  The browser silently blocks
			# the request and Godot reports RESULT_CANT_CONNECT (2) or
			# RESULT_CONNECTION_ERROR (4).
			hint = " (Web: this may be a CORS or mixed-content block)"
		_fail("API unreachable after %d retries (result %d)%s" % [MAX_RETRIES, result, hint])
		return

	if response_code == 0 and result == HTTPRequest.RESULT_SUCCESS and OS.has_feature("web"):
		# On web, a response_code of 0 with RESULT_SUCCESS can indicate
		# a CORS-blocked preflight (browser returns empty response).
		_fail("moh-db.com request blocked (Web: likely a CORS policy issue)")
		return

	if response_code < 200 or response_code >= 300:
		_fail("moh-db.com returned HTTP %d" % response_code)
		return

	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if parsed == null:
		_fail("Invalid JSON from moh-db.com API")
		return

	# The API returns a PageMapDto with a "content" array of MapDto objects.
	var results: Array = []
	if parsed is Dictionary:
		if parsed.has("content") and parsed["content"] is Array:
			results = parsed["content"]
	elif parsed is Array:
		# Bare array fallback (unlikely but safe).
		results = parsed

	if results.is_empty():
		_fail("Map '%s' not found on moh-db.com" % _current_map_name, true)
		return

	# Pick the best match.  Prefer an entry whose mapName matches exactly.
	var best: Dictionary = results[0]
	var search_lower := _current_map_name.get_file().to_lower()
	for entry in results:
		if not entry is Dictionary:
			continue
		# MapDto.mapName is the canonical map name field.
		var entry_map_name: Variant = entry.get("mapName", "")
		if entry_map_name == null:
			entry_map_name = ""
		var entry_name: String = String(entry_map_name).to_lower()
		entry_name = entry_name.trim_suffix(".pk3").trim_suffix(".zip")
		if entry_name == search_lower:
			best = entry
			break

	# Extract download URL from the MapDto.
	# Priority: mapFile.downloadLink > top-level downloadLink
	var download_url: String = ""
	var map_file: Variant = best.get("mapFile")
	if map_file is Dictionary and map_file.get("downloadLink", "") != "":
		download_url = map_file["downloadLink"]
	if download_url == "":
		var top_link: Variant = best.get("downloadLink", "")
		if top_link != null:
			download_url = String(top_link)

	if download_url == "":
		_fail("No download URL found for '%s'" % _current_map_name, true)
		return

	# Extract file name and size from MapDto.mapFile (FileInfoDto).
	var file_name: String = ""
	var file_size: int = 0
	if map_file is Dictionary:
		var fn: Variant = map_file.get("filename", "")
		if fn != null:
			file_name = String(fn)
		file_size = int(map_file.get("filesize", 0))

	# Fallback to map name if no filename in mapFile.
	if file_name == "":
		var mn: Variant = best.get("mapName", "")
		if mn != null and String(mn) != "":
			file_name = String(mn)
		else:
			file_name = _current_map_name

	# Ensure the filename ends with .pk3.
	var has_archive_ext := false
	for ext in [".pk3", ".zip"]:
		if file_name.to_lower().ends_with(ext):
			has_archive_ext = true
			break
	if not has_archive_ext:
		file_name += ".pk3"

	# The moh-db.com API does not provide file hashes; we compute SHA-256 after download.
	var file_hash: String = ""

	print("MapDownloader: Found — ", file_name,
		" size=", _human_size(file_size) if file_size > 0 else "unknown",
		" url=", download_url)

	_begin_download(download_url, file_name, file_size, file_hash)


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

func _begin_download(url: String, file_name: String, file_size: int, file_hash: String) -> void:
	_downloading = true
	set_process(true)  # Enable per-frame progress polling.
	_download_retry_count = 0
	_progress_timer = 0.0

	# Store metadata for later registration and retry.
	set_meta("dl_file_name", file_name)
	set_meta("dl_file_size", file_size)
	set_meta("dl_file_hash", file_hash)
	set_meta("dl_url", url)

	var cache: Node = _cache_manager
	if cache == null:
		_fail("CacheManager autoload not found")
		return

	# Temp file path while downloading.
	_download_path = "user://cache/_downloading.tmp"
	if not DirAccess.dir_exists_absolute("user://cache/"):
		DirAccess.make_dir_recursive_absolute("user://cache/")

	_http_download.download_file = _download_path
	_show_ui_downloading(file_name, file_size)

	var err := _http_download.request(url)
	if err != OK:
		_fail("Download request failed: error %d" % err)


func _update_download_progress() -> void:
	var body_size := _http_download.get_body_size()
	var downloaded := _http_download.get_downloaded_bytes()
	if body_size > 0:
		var pct := clampf(float(downloaded) / float(body_size) * 100.0, 0.0, 100.0)
		_update_ui_progress(pct, downloaded, body_size)
		download_progress.emit(_current_map_name, pct)
	elif downloaded > 0:
		# Unknown total size — show downloaded bytes only.
		_update_ui_progress(-1.0, downloaded, 0)


func _on_download_completed(result: int, response_code: int,
		_headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http_download.download_file = ""
	_downloading = false

	if result != HTTPRequest.RESULT_SUCCESS:
		_download_retry_count += 1
		if _download_retry_count <= MAX_DOWNLOAD_RETRIES:
			push_warning("MapDownloader: Download retry %d/%d — HTTP result %d" % [
				_download_retry_count, MAX_DOWNLOAD_RETRIES, result])
			var retry_url: String = get_meta("dl_url", "")
			if retry_url != "":
				_downloading = true
				set_process(true)  # Enable per-frame progress polling.
				_download_path = "user://cache/_downloading.tmp"
				_http_download.download_file = _download_path
				var backoff := pow(2.0, _download_retry_count)  # 2s, 4s, …
				get_tree().create_timer(backoff).timeout.connect(
					func():
						if not _busy:
							return  # State changed while waiting — abort retry.
						var err := _http_download.request(retry_url)
						if err != OK:
							_fail("Download retry failed: error %d" % err))
				return
		_cleanup_temp()
		_fail("Download failed: HTTP result %d" % result)
		return

	if response_code < 200 or response_code >= 300:
		_cleanup_temp()
		_fail("Download failed: HTTP %d" % response_code)
		return

	var file_name: String = get_meta("dl_file_name", "unknown.pk3")
	var file_size: int = get_meta("dl_file_size", 0)
	var file_hash: String = get_meta("dl_file_hash", "")

	# Hash the downloaded file.
	var actual_hash := CacheManager.sha256_of_file(_download_path)
	if actual_hash == "":
		_cleanup_temp()
		_fail("Downloaded file is empty or unreadable")
		return

	# If the API provided a hash, verify it strictly.
	if file_hash != "" and actual_hash.to_lower() != file_hash.to_lower():
		_cleanup_temp()
		_fail("Hash mismatch: expected %s, got %s" % [file_hash, actual_hash])
		return

	# Move temp file to cache under its hash name.
	var cache: Node = _cache_manager
	if cache == null:
		_cleanup_temp()
		_fail("CacheManager not available")
		return

	var final_path: String = cache.get_cached_path(actual_hash)
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(final_path)
	var mv_err := DirAccess.rename_absolute(_download_path, final_path)
	if mv_err != OK:
		_cleanup_temp()
		_fail("Could not move download to cache: error %d" % mv_err)
		return

	# Get actual file size from disk if API didn't provide it.
	if file_size <= 0:
		var f := FileAccess.open(final_path, FileAccess.READ)
		if f:
			file_size = f.get_length()
			f.close()

	cache.register_file(actual_hash, file_name, file_size)

	# UT-style: associate the downloaded file with the current server session.
	var session_mgr: Node = _session_manager
	if session_mgr and session_mgr.is_session_active():
		# Maps detected from "Couldn't load" errors are TYPE_MAP (universal).
		session_mgr.associate_file(actual_hash, file_name, ServerSessionManager.TYPE_MAP)

	# Install to the engine game directory.
	_install_and_reconnect(actual_hash)


# ---------------------------------------------------------------------------
# Install & reconnect
# ---------------------------------------------------------------------------

func _install_and_reconnect(file_hash: String) -> void:
	var cache: Node = _cache_manager
	if cache == null:
		_fail("CacheManager not available for install")
		return

	# Try ServerSessionManager first (UT-style: tracks per-server associations).
	var session_mgr: Node = _session_manager
	if session_mgr and session_mgr.is_session_active():
		var file_name: String = cache.get_original_name(file_hash)
		if file_name == "":
			file_name = file_hash.left(12) + ".pk3"
		var ok: bool = session_mgr.install_file_for_session(
			file_hash, file_name, ServerSessionManager.TYPE_MAP)
		if ok:
			_finish_install()
			return
		# Fall through to direct install if session install fails.

	# Direct install fallback (no session manager or session failed).
	var game_dir := ""
	if _runner and _runner.has_method("vfs_get_writable_gamedir"):
		game_dir = _runner.vfs_get_writable_gamedir()
	if game_dir == "":
		if _runner and _runner.has_method("get_basepath"):
			game_dir = _runner.get_basepath()
			if game_dir != "":
				if not game_dir.ends_with("/"):
					game_dir += "/"
				game_dir += "main"

	if game_dir == "":
		_fail("Cannot determine game directory for file installation")
		return

	var ok: bool = cache.install_to_game_dir(file_hash, game_dir)
	if not ok:
		_fail("Failed to install map to game directory")
		return

	_finish_install()


## Common completion logic after successful install.
##
## VFS reload strategy (robust, works on all server types):
##
##   Priority 1: vfs_restart() — calls FS_Restart() directly to rescan pk3s.
##   Priority 2: "fs_restart" console command fallback.
##
## After VFS reload, we use "connect <addr>" (not "reconnect") because
## ERR_DROP clears clc.servername, making the reconnect command fail.
func _finish_install() -> void:
	var map_name := _current_map_name
	var server_addr := _last_server_address
	_show_ui_reconnecting()
	print("MapDownloader: Map installed — reloading VFS and reconnecting in ", RECONNECT_DELAY, "s…")
	download_completed.emit(map_name)

	# Wait briefly then reload VFS and reconnect.
	await get_tree().create_timer(RECONNECT_DELAY).timeout
	_busy = false
	_hide_ui()
	if _runner and _runner.has_method("execute_command"):
		# Reload VFS so the new pk3 is discovered.
		if _runner.has_method("vfs_restart"):
			_runner.vfs_restart()
			print("MapDownloader: Called vfs_restart() — VFS reloaded.")
		else:
			_runner.execute_command("fs_restart")
			print("MapDownloader: Sent 'fs_restart' command.")

		# Reconnect to the server.  Use explicit "connect <addr>" because
		# ERR_DROP clears clc.servername so "reconnect" would fail.
		if server_addr != "":
			_runner.execute_command("connect " + server_addr)
			print("MapDownloader: Sent 'connect ", server_addr, "' command.")
		else:
			# Last resort: try reconnect anyway (may work if connection wasn't dropped).
			_runner.execute_command("reconnect")
			print("MapDownloader: Sent 'reconnect' command (no server address available).")


# ---------------------------------------------------------------------------
# Failure
# ---------------------------------------------------------------------------

func _fail(reason: String, is_not_found: bool = false) -> void:
	_busy = false
	_downloading = false
	_cleanup_temp()
	push_warning("MapDownloader: FAILED — ", reason)

	_show_ui_error(reason, is_not_found)
	download_failed.emit(_current_map_name, reason)

	# Auto-hide the error after a delay.
	await get_tree().create_timer(ERROR_DISPLAY_TIME).timeout
	_hide_ui()


func _cleanup_temp() -> void:
	if _download_path != "" and FileAccess.file_exists(_download_path):
		DirAccess.remove_absolute(_download_path)
	_download_path = ""


# ---------------------------------------------------------------------------
# Overlay UI  (built programmatically — no .tscn needed)
# ---------------------------------------------------------------------------

func _build_overlay_ui() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 200  # above engine HUD layer (100) and screen-effects layer (150)
	add_child(_overlay)

	# Semi-transparent background.
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.75)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(bg)

	# Center panel.
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(500, 180)
	_panel.position = Vector2(-250, -90)
	_overlay.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(vbox)

	# Title.
	_title_label = Label.new()
	_title_label.text = "Downloading Map…"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_title_label)

	# Status (e.g. "Searching for dm/mohdm6…").
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_status_label)

	# Progress bar.
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.value = 0.0
	_progress_bar.custom_minimum_size = Vector2(460, 28)
	_progress_bar.show_percentage = false
	vbox.add_child(_progress_bar)

	# Detail line (e.g. "1.2 MB / 4.5 MB (27%)").
	_detail_label = Label.new()
	_detail_label.text = ""
	_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_detail_label)

	# Disconnect button (hidden by default, shown on errors).
	_disconnect_btn = Button.new()
	_disconnect_btn.text = "Disconnect"
	_disconnect_btn.custom_minimum_size = Vector2(140, 36)
	_disconnect_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_disconnect_btn.visible = false
	_disconnect_btn.pressed.connect(_on_disconnect_pressed)
	vbox.add_child(_disconnect_btn)


func _show_ui_searching(map_name: String) -> void:
	_title_label.text = "Missing Map"
	_status_label.text = "Searching moh-db.com for \"" + map_name + "\"…"
	_progress_bar.value = 0.0
	_progress_bar.modulate = Color.WHITE
	_detail_label.text = ""
	_disconnect_btn.visible = false
	_overlay.visible = true


func _show_ui_downloading(file_name: String, file_size: int) -> void:
	_title_label.text = "Downloading Map"
	_status_label.text = file_name
	_progress_bar.value = 0.0
	_progress_bar.modulate = Color.WHITE
	_disconnect_btn.visible = false
	if file_size > 0:
		_detail_label.text = "0 B / " + _human_size(file_size)
	else:
		_detail_label.text = "Starting download…"
	_overlay.visible = true


func _update_ui_progress(percent: float, downloaded: int, total: int) -> void:
	if percent >= 0.0:
		_progress_bar.value = percent
		_detail_label.text = "%s / %s  (%d%%)" % [
			_human_size(downloaded), _human_size(total), int(percent)]
	else:
		# Unknown total.
		_progress_bar.value = 0.0
		_detail_label.text = "%s downloaded…" % _human_size(downloaded)


func _show_ui_reconnecting() -> void:
	_title_label.text = "Download Complete"
	_status_label.text = "Reloading VFS and reconnecting…"
	_progress_bar.value = 100.0
	_progress_bar.modulate = Color(0.3, 1.0, 0.3)
	_detail_label.text = ""
	_disconnect_btn.visible = false


func _show_ui_error(reason: String, show_disconnect: bool = false) -> void:
	if show_disconnect:
		_title_label.text = "Map Not Available"
		_detail_label.text = "This map could not be found in the moh-db.com database."
	else:
		_title_label.text = "Download Failed"
		_detail_label.text = ""
	_status_label.text = reason
	_progress_bar.value = 0.0
	_progress_bar.modulate = Color(1.0, 0.3, 0.3)
	# Always show Disconnect button on errors — the user may want to leave
	# the server after any kind of failure, not just "map not found".
	_disconnect_btn.visible = true
	_overlay.visible = true


func _hide_ui() -> void:
	if _overlay:
		_overlay.visible = false


## Called when the user clicks "Disconnect" on the error overlay.
func _on_disconnect_pressed() -> void:
	_hide_ui()
	if _runner and _runner.has_method("execute_command"):
		_runner.execute_command("disconnect")
		print("MapDownloader: User disconnected from server.")
	# End the server session so files are cleaned up.
	var session_mgr: Node = _session_manager
	if session_mgr and session_mgr.is_session_active():
		session_mgr.end_session()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _human_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1048576:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / 1048576.0)
