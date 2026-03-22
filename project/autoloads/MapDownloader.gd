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
##   7. Reconnects to the server automatically.
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
## moh-db.com API (see https://www.moh-db.com/api-docs):
##   GET /api/maps?search=<name>  → search for map files
##   Response contains download URLs and file metadata.
extends Node

## Emitted when a missing map is detected and download begins.
signal download_started(map_name: String)
## Emitted periodically with download progress (0.0–100.0).
signal download_progress(map_name: String, percent: float)
## Emitted when download finishes and the map is installed.
signal download_completed(map_name: String)
## Emitted on any failure during the search or download.
signal download_failed(map_name: String, reason: String)

## moh-db.com API base URL.  Change this only if the API moves.
const API_BASE_URL := "https://www.moh-db.com/api"
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

## Maximum retries for the download request itself.
const MAX_DOWNLOAD_RETRIES := 1

# -- UI --
var _overlay: CanvasLayer = null
var _panel: PanelContainer = null
var _title_label: Label = null
var _status_label: Label = null
var _progress_bar: ProgressBar = null
var _detail_label: Label = null


func _ready() -> void:
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

	_build_overlay_ui()
	_hide_ui()


func _process(delta: float) -> void:
	# Lazily discover the MoHAARunner once it is added to the tree.
	if not _runner_connected:
		_try_connect_runner()

	# Update download progress bar.
	if _downloading:
		_progress_timer += delta
		if _progress_timer >= PROGRESS_INTERVAL:
			_progress_timer = 0.0
			_update_download_progress()


# ---------------------------------------------------------------------------
# Runner discovery
# ---------------------------------------------------------------------------

func _try_connect_runner() -> void:
	# Search the tree for the MoHAARunner node — avoids hard-coding a path.
	var root := get_tree().root
	for child in root.get_children():
		for grandchild in child.get_children():
			if grandchild.get_class() == "MoHAARunner":
				_runner = grandchild
				_runner_connected = true
				_runner.engine_error.connect(_on_engine_error)
				print("MapDownloader: Connected to MoHAARunner engine_error signal.")
				return


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
	var session_mgr: Node = get_node_or_null("/root/ServerSessionManager")
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


## Check if the map is already in the shared cache (downloaded for any server).
## If found, install it for the current session and reconnect — no download needed.
func _try_install_from_cache(map_name: String) -> bool:
	var cache: Node = get_node_or_null("/root/CacheManager")
	var session_mgr: Node = get_node_or_null("/root/ServerSessionManager")
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

	var url := API_BASE_URL + "/maps?search=" + search_term.uri_encode()
	print("MapDownloader: Searching moh-db.com — ", url)

	var err := _http_search.request(url)
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
		_fail("API unreachable after %d retries (result %d)" % [MAX_RETRIES, result])
		return

	if response_code < 200 or response_code >= 300:
		_fail("moh-db.com returned HTTP %d" % response_code)
		return

	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if parsed == null:
		_fail("Invalid JSON from moh-db.com API")
		return

	# The API may return results in various wrapper formats.
	# We support: { "data": [...] }, { "results": [...] }, or a bare [...].
	var results: Array = []
	if parsed is Array:
		results = parsed
	elif parsed is Dictionary:
		if parsed.has("data") and parsed["data"] is Array:
			results = parsed["data"]
		elif parsed.has("results") and parsed["results"] is Array:
			results = parsed["results"]

	if results.is_empty():
		_fail("Map '%s' not found on moh-db.com" % _current_map_name)
		return

	# Pick the best match.  Prefer an entry whose name matches exactly.
	var best: Dictionary = results[0]
	var search_lower := _current_map_name.get_file().to_lower()
	for entry in results:
		if not entry is Dictionary:
			continue
		var entry_name: String = entry.get("name", entry.get("file_name", "")).to_lower()
		entry_name = entry_name.trim_suffix(".pk3").trim_suffix(".zip")
		if entry_name == search_lower:
			best = entry
			break

	# Extract download URL from the result.
	var download_url: String = best.get("download_url",
		best.get("downloadUrl",
			best.get("url",
				best.get("file_url", ""))))
	if download_url == "":
		# Some APIs require constructing the URL from an ID.
		var entry_id = best.get("id", "")
		if entry_id != "":
			download_url = API_BASE_URL + "/maps/" + str(entry_id) + "/download"

	if download_url == "":
		_fail("No download URL found for '%s'" % _current_map_name)
		return

	var file_name: String = best.get("file_name",
		best.get("fileName",
			best.get("name", _current_map_name)))
	# Strip any existing archive extension before normalizing.
	for ext in [".pk3", ".zip"]:
		if file_name.to_lower().ends_with(ext):
			file_name = file_name.substr(0, file_name.length() - ext.length())
			break
	file_name += ".pk3"

	var file_size: int = best.get("file_size", best.get("fileSize", best.get("size", 0)))
	var file_hash: String = best.get("sha256", best.get("hash", best.get("md5", "")))

	print("MapDownloader: Found — ", file_name,
		" size=", _human_size(file_size) if file_size > 0 else "unknown",
		" url=", download_url)

	_begin_download(download_url, file_name, file_size, file_hash)


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

func _begin_download(url: String, file_name: String, file_size: int, file_hash: String) -> void:
	_downloading = true
	_download_retry_count = 0
	_progress_timer = 0.0

	# Store metadata for later registration and retry.
	set_meta("dl_file_name", file_name)
	set_meta("dl_file_size", file_size)
	set_meta("dl_file_hash", file_hash)
	set_meta("dl_url", url)

	var cache: Node = get_node_or_null("/root/CacheManager")
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
	var cache: Node = get_node_or_null("/root/CacheManager")
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
	var session_mgr: Node = get_node_or_null("/root/ServerSessionManager")
	if session_mgr and session_mgr.is_session_active():
		# Maps detected from "Couldn't load" errors are TYPE_MAP (universal).
		session_mgr.associate_file(actual_hash, file_name, ServerSessionManager.TYPE_MAP)

	# Install to the engine game directory.
	_install_and_reconnect(actual_hash)


# ---------------------------------------------------------------------------
# Install & reconnect
# ---------------------------------------------------------------------------

func _install_and_reconnect(file_hash: String) -> void:
	var cache: Node = get_node_or_null("/root/CacheManager")
	if cache == null:
		_fail("CacheManager not available for install")
		return

	# Try ServerSessionManager first (UT-style: tracks per-server associations).
	var session_mgr: Node = get_node_or_null("/root/ServerSessionManager")
	if session_mgr and session_mgr.is_session_active():
		var file_name := cache.get_original_name(file_hash)
		if file_name == "":
			file_name = file_hash.left(12) + ".pk3"
		var ok := session_mgr.install_file_for_session(
			file_hash, file_name, ServerSessionManager.TYPE_MAP)
		if ok:
			_finish_install()
			return
		# Fall through to direct install if session install fails.

	# Direct install fallback (no session manager or session failed).
	var game_dir := ""
	if _runner and _runner.has_method("vfs_get_gamedir"):
		game_dir = _runner.vfs_get_gamedir()
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

	var ok := cache.install_to_game_dir(file_hash, game_dir)
	if not ok:
		_fail("Failed to install map to game directory")
		return

	_finish_install()


## Common completion logic after successful install.
##
## The reconnect flow relies on the engine's FS_Restart mechanism:
##   reconnect → connect <server> → server sends gamestate
##   → CL_ParseGamestate() → FS_ConditionalRestart() or FS_Restart()
##
## For non-pure servers (sv_pure=0, the OpenMoHAA default), the engine
## takes the CA_CONNECTED + empty sv_paks path which calls FS_Restart()
## directly — guaranteed to pick up the new pk3 file.
##
## For pure servers (sv_pure=1), FS_ConditionalRestart() only restarts
## if the checksumFeed changed.  To handle both cases reliably, we
## toggle fs_game briefly to force the modified flag, ensuring
## FS_ConditionalRestart() always triggers Com_GameRestart().
func _finish_install() -> void:
	var map_name := _current_map_name
	_show_ui_reconnecting()
	print("MapDownloader: Map installed — reconnecting in ", RECONNECT_DELAY, "s…")
	download_completed.emit(map_name)

	# Wait briefly then reconnect.
	await get_tree().create_timer(RECONNECT_DELAY).timeout
	_busy = false
	_hide_ui()
	if _runner and _runner.has_method("execute_command"):
		# Force FS_Restart on reconnect for pure servers (sv_pure=1):
		# Toggle fs_game to set the ->modified flag so that
		# FS_ConditionalRestart() triggers a full Com_GameRestart().
		# For non-pure servers (OpenMoHAA default) this is redundant
		# but harmless — FS_Restart is already guaranteed.
		if _runner.has_method("get_cvar_string"):
			var current_fs_game: String = _runner.get_cvar_string("fs_game")
			# Set to a dummy value then back to force the modified flag.
			_runner.execute_command("set fs_game _dl_force_restart")
			_runner.execute_command("set fs_game " + current_fs_game)
		_runner.execute_command("reconnect")
		print("MapDownloader: Sent 'reconnect' command.")


# ---------------------------------------------------------------------------
# Failure
# ---------------------------------------------------------------------------

func _fail(reason: String) -> void:
	_busy = false
	_downloading = false
	_cleanup_temp()
	push_warning("MapDownloader: FAILED — ", reason)
	_show_ui_error(reason)
	download_failed.emit(_current_map_name, reason)

	# Auto-hide the error after 8 seconds.
	await get_tree().create_timer(8.0).timeout
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
	_overlay.layer = 100  # on top of everything
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


func _show_ui_searching(map_name: String) -> void:
	_title_label.text = "Missing Map"
	_status_label.text = "Searching moh-db.com for \"" + map_name + "\"…"
	_progress_bar.value = 0.0
	_progress_bar.modulate = Color.WHITE
	_detail_label.text = ""
	_overlay.visible = true


func _show_ui_downloading(file_name: String, file_size: int) -> void:
	_title_label.text = "Downloading Map"
	_status_label.text = file_name
	_progress_bar.value = 0.0
	_progress_bar.modulate = Color.WHITE
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
	_status_label.text = "Reconnecting to server…"
	_progress_bar.value = 100.0
	_progress_bar.modulate = Color(0.3, 1.0, 0.3)
	_detail_label.text = ""


func _show_ui_error(reason: String) -> void:
	_title_label.text = "Download Failed"
	_status_label.text = reason
	_progress_bar.value = 0.0
	_progress_bar.modulate = Color(1.0, 0.3, 0.3)
	_detail_label.text = ""
	_overlay.visible = true


func _hide_ui() -> void:
	if _overlay:
		_overlay.visible = false


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _human_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1048576:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / 1048576.0)
