## MapDownloader.gd — Auto-download missing maps from pr_downloads, sv_maplist, or moh-db.com.
##
## Three download sources, checked in priority order:
##
##   1. **pr_downloads (PakRadar)** — Server sets:
##        sets pr_downloads "https://example.com/filelist.txt"
##      Filelist format:
##        map { alias "name" md5 "hex" url "https://example.com/file.pk3" }
##      Downloads ALL listed files with MD5 verification. Server-authoritative:
##      if a local file has a different MD5, it is re-downloaded.
##
##   2. **sv_maplist** — Server's map rotation list (CVAR_SERVERINFO).
##      Parsed after connecting — contains space/comma-separated map names.
##      Any map not already installed locally is searched on moh-db.com and
##      downloaded, so map rotations work without repeated disconnects.
##
##   3. **moh-db.com API** — Fallback for individual missing maps.
##      When a "Couldn't load <bsp>" error fires and the map wasn't covered
##      by pr_downloads or sv_maplist, queries the moh-db.com database.
##
## All sources feed into a unified download queue with a proper GUI showing:
##   - Overall progress (X / Y files)
##   - Per-file status list (pending / downloading / complete / error)
##   - Current file progress bar with speed and size
##   - Source label (pr_downloads / sv_maplist / moh-db.com)
##
## UT-style isolation:
##   - Files are cached once and shared across servers (CacheManager).
##   - Each server session tracks its own file associations (ServerSessionManager).
##   - ALL downloaded content is server-specific — removed on disconnect.
##   - If you already have a file from another server, it is reused from cache.
extends Node

## Emitted when downloads begin.
signal download_started(map_name: String)
## Emitted periodically with download progress (0.0–100.0).
signal download_progress(map_name: String, percent: float)
## Emitted when all downloads finish and maps are installed.
signal download_completed(map_name: String)
## Emitted on any failure during the search or download.
signal download_failed(map_name: String, reason: String)

## moh-db.com API base URL.
const API_BASE_URL := "https://api.moh-db.com"
var _api_key: String = ""
const API_PAGE_SIZE := 20
const RECONNECT_DELAY := 2.0
const DOWNLOAD_TIMEOUT := 300.0
const PROGRESS_INTERVAL := 0.15
const MAX_RETRIES := 2
const MAX_DOWNLOAD_RETRIES := 1
const ERROR_DISPLAY_TIME := 12.0
const MAX_QUEUE_ENTRIES := 100
const FAILED_MAP_COOLDOWN := 60.0  # seconds before retrying a failed map

# -- HTTP nodes --
var _http_search: HTTPRequest = null       # moh-db.com API search
var _http_download: HTTPRequest = null     # moh-db.com / sv_maplist file download
var _http_pr_filelist: HTTPRequest = null  # pr_downloads filelist fetch
var _http_pr_download: HTTPRequest = null  # pr_downloads file download

# -- Engine references --
var _runner: Node = null
var _cache_manager: Node = null
var _session_manager: Node = null

# -- State --
var _current_map_bsp: String = ""   # e.g. "maps/dm/mohdm6.bsp"
var _current_map_name: String = ""  # e.g. "dm/mohdm6"
var _busy: bool = false
var _downloading: bool = false      # moh-db.com download active
var _downloading_pr: bool = false   # pr_downloads download active
var _download_path: String = ""
var _retry_count: int = 0
var _progress_timer: float = 0.0
var _last_server_address: String = ""
var _showing_error: bool = false
var _failed_maps: Dictionary = {}  # map_bsp → timestamp of last failure

# -- Unified download queue --
# Each entry: {filename:String, url:String, md5:String, alias:String,
#              source:String, status:String, size:int}
# source: "pr_downloads", "sv_maplist", "moh-db.com"
# status: "pending", "downloading", "complete", "cached", "error", "skipped"
var _queue: Array = []
var _queue_index: int = 0
var _had_downloads: bool = false
var _current_source: String = ""

# -- sv_maplist batch search state --
var _maplist_search_queue: Array = []
var _maplist_search_index: int = 0
var _whitespace_regex: RegEx = RegEx.new()

# -- UI nodes --
var _overlay: CanvasLayer = null
var _bg: ColorRect = null
var _panel: PanelContainer = null
var _title_label: Label = null
var _source_label: Label = null
var _overall_label: Label = null
var _overall_progress: ProgressBar = null
var _file_list_container: VBoxContainer = null
var _file_scroll: ScrollContainer = null
var _current_file_label: Label = null
var _current_progress: ProgressBar = null
var _current_detail: Label = null
var _disconnect_btn: Button = null
var _file_item_nodes: Array = []  # [{label:Label, icon:Label}] parallel to _queue


func _ready() -> void:
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

	_http_pr_filelist = HTTPRequest.new()
	_http_pr_filelist.timeout = 30.0
	_http_pr_filelist.use_threads = not OS.has_feature("web")
	add_child(_http_pr_filelist)
	_http_pr_filelist.request_completed.connect(_on_pr_filelist_completed)

	_http_pr_download = HTTPRequest.new()
	_http_pr_download.timeout = DOWNLOAD_TIMEOUT
	_http_pr_download.use_threads = not OS.has_feature("web")
	_http_pr_download.download_chunk_size = 65536
	add_child(_http_pr_download)
	_http_pr_download.request_completed.connect(_on_pr_download_completed)

	_cache_manager = get_node_or_null("/root/CacheManager")
	_session_manager = get_node_or_null("/root/ServerSessionManager")

	_build_overlay_ui()
	_hide_ui()
	_whitespace_regex.compile("[\\s,]+")
	set_process(false)
	call_deferred("_try_connect_runner")


func _process(delta: float) -> void:
	if _downloading or _downloading_pr:
		_progress_timer += delta
		if _progress_timer >= PROGRESS_INTERVAL:
			_progress_timer = 0.0
			_update_current_progress()
	else:
		set_process(false)


# ---------------------------------------------------------------------------
# Runner discovery
# ---------------------------------------------------------------------------

func _try_connect_runner() -> void:
	var runners := get_tree().get_nodes_in_group("mohaa_runner")
	if runners.size() > 0:
		_runner = runners[0]
		_runner.engine_error.connect(_on_engine_error)
		print("MapDownloader: Connected to MoHAARunner.")
		return
	var root := get_tree().root
	for child in root.get_children():
		for grandchild in child.get_children():
			if grandchild.get_class() == "MoHAARunner":
				_runner = grandchild
				_runner.engine_error.connect(_on_engine_error)
				print("MapDownloader: Connected to MoHAARunner.")
				return
	call_deferred("_try_connect_runner")


# ---------------------------------------------------------------------------
# Engine error interception
# ---------------------------------------------------------------------------

func _on_engine_error(message: String) -> void:
	if not message.begins_with("Couldn't load "):
		return
	if _busy or _showing_error:
		return

	var bsp_path := message.substr("Couldn't load ".length()).strip_edges()
	if not bsp_path.ends_with(".bsp"):
		return

	# Prevent infinite reconnect loops — skip maps that recently failed.
	if _failed_maps.has(bsp_path):
		var elapsed: float = (Time.get_ticks_msec() / 1000.0) - _failed_maps[bsp_path]
		if elapsed < FAILED_MAP_COOLDOWN:
			push_warning("MapDownloader: Skipping recently-failed map ", bsp_path,
				" (failed %.0fs ago, cooldown %ds)" % [elapsed, int(FAILED_MAP_COOLDOWN)])
			return

	_busy = true
	_current_map_bsp = bsp_path
	_last_server_address = _detect_server_address()

	var map_name := bsp_path
	if map_name.begins_with("maps/"):
		map_name = map_name.substr("maps/".length())
	map_name = map_name.trim_suffix(".bsp")
	_current_map_name = map_name

	print("MapDownloader: Missing map — ", map_name, " (", bsp_path, ")")
	_ensure_server_session()

	# Reset queue.
	_queue.clear()
	_queue_index = 0
	_had_downloads = false
	_file_item_nodes.clear()

	# Priority 1: pr_downloads — server provides its own file list with URLs + MD5.
	if _try_pr_downloads():
		return

	# Priority 2: sv_maplist — download all maps in the rotation via moh-db.com.
	if _try_sv_maplist():
		return

	# Priority 3: moh-db.com for the specific missing map.
	_try_install_from_cache_or_search(map_name)


# ---------------------------------------------------------------------------
# Session & address helpers
# ---------------------------------------------------------------------------

func _ensure_server_session() -> void:
	var session_mgr: Node = _session_manager
	if session_mgr == null or session_mgr.is_session_active():
		return
	var server_addr := ""
	if _runner and _runner.has_method("get_cvar_string"):
		for cvar_name in ServerSessionManager.SERVER_ADDRESS_CVARS:
			var val: String = _runner.get_cvar_string(cvar_name)
			if val != "" and val != "0.0.0.0":
				server_addr = val
				break
	if server_addr == "":
		server_addr = "unknown_server"
	session_mgr.begin_session(server_addr)


func _detect_server_address() -> String:
	if _runner == null or not _runner.has_method("get_cvar_string"):
		return ""
	for cvar_name in ServerSessionManager.SERVER_ADDRESS_CVARS:
		var val: String = _runner.get_cvar_string(cvar_name)
		if val != "" and val != "0.0.0.0" and val != "localhost":
			return val
	return ""


# ---------------------------------------------------------------------------
# Source 1: pr_downloads (PakRadar)
# ---------------------------------------------------------------------------

func _try_pr_downloads() -> bool:
	if _runner == null or not _runner.has_method("get_cvar_string"):
		return false
	var url: String = _runner.get_cvar_string("pr_downloads")
	if url.strip_edges() == "":
		return false
	if not url.begins_with("http://") and not url.begins_with("https://"):
		push_warning("MapDownloader: pr_downloads URL is not HTTP(S): ", url)
		return false

	_current_source = "pr_downloads"
	print("MapDownloader: pr_downloads — fetching file list: ", url)
	_show_ui_fetching("pr_downloads", "Fetching server file list…")
	download_started.emit(_current_map_name)

	var err := _http_pr_filelist.request(url)
	if err != OK:
		push_warning("MapDownloader: Failed to request pr_downloads filelist: error ", err)
		return false
	return true


func _on_pr_filelist_completed(result: int, response_code: int,
_headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		push_warning("MapDownloader: pr_downloads filelist failed — falling back")
		_pr_fallback()
		return

	var text := body.get_string_from_utf8()
	if text.strip_edges() == "":
		push_warning("MapDownloader: pr_downloads filelist empty — falling back")
		_pr_fallback()
		return

	var entries := _parse_pr_filelist(text)
	if entries.is_empty():
		push_warning("MapDownloader: No entries in pr_downloads — falling back")
		_pr_fallback()
		return

	var game_dir := _get_game_dir()

	# Build the unified queue from pr_downloads entries.
	for entry in entries:
		var needs_dl := _pr_file_needs_download(entry, game_dir)
		var status := "pending" if needs_dl else "skipped"

		# Check cache.
		if needs_dl:
			var cached_hash := _pr_check_cache(entry)
			if cached_hash != "":
				_pr_install_from_cache(cached_hash, entry)
				status = "cached"
				_had_downloads = true

		_queue.append({
"filename": entry.get("filename", ""),
"url": entry.get("url", ""),
"md5": entry.get("md5", ""),
"alias": entry.get("alias", ""),
"source": "pr_downloads",
"status": status,
"size": 0,
})

	_show_queue_ui()
	_start_next_queue_download()


func _pr_fallback() -> void:
	if _try_sv_maplist():
		return
	_try_install_from_cache_or_search(_current_map_name)


## Parse pr_downloads filelist text into entries.
func _parse_pr_filelist(text: String) -> Array:
	var entries: Array = []
	var pos := 0
	while true:
		if entries.size() >= MAX_QUEUE_ENTRIES:
			push_warning("MapDownloader: pr_downloads filelist truncated at ", MAX_QUEUE_ENTRIES, " entries")
			break
		var block_start := text.find("map {", pos)
		if block_start < 0:
			break
		var block_end := text.find("}", block_start + 5)
		if block_end < 0:
			break
		var block := text.substr(block_start + 5, block_end - block_start - 5)
		pos = block_end + 1

		var alias := _extract_quoted_field(block, "alias")
		var md5 := _extract_quoted_field(block, "md5")
		var url := _extract_quoted_field(block, "url")
		if url == "":
			continue
		if not url.begins_with("http://") and not url.begins_with("https://"):
			continue

		var filename := url.get_file()
		if filename == "":
			filename = (alias + ".pk3") if alias != "" else "unknown.pk3"
		filename = _sanitize_filename(filename)

		entries.append({
"alias": alias,
"md5": md5.to_lower(),
			"url": url,
			"filename": filename,
		})
	return entries


func _pr_file_needs_download(entry: Dictionary, game_dir: String) -> bool:
	var filename: String = entry.get("filename", "")
	if filename == "" or game_dir == "":
		return true
	var full_path := game_dir.path_join(filename)
	if not FileAccess.file_exists(full_path):
		return true
	var md5: String = entry.get("md5", "")
	if md5 == "":
		return false
	# pr_downloads is authoritative — always verify MD5.
	var actual_md5 := _md5_of_file(full_path)
	return actual_md5 != md5


func _pr_check_cache(entry: Dictionary) -> String:
	var cache: Node = _cache_manager
	if cache == null:
		return ""
	var name_base := entry.get("filename", "").to_lower().trim_suffix(".pk3").trim_suffix(".zip")
	if name_base == "":
		return ""
	var hash_key := cache.find_cached_file_by_name(name_base)
	if hash_key == "":
		return ""
	# Verify MD5 matches if pr_downloads specifies one.
	var expected_md5: String = entry.get("md5", "")
	if expected_md5 != "":
		var cached_path: String = cache.get_cached_path(hash_key)
		if cached_path != "" and FileAccess.file_exists(cached_path):
			var actual_md5 := _md5_of_file(cached_path)
			if actual_md5 != expected_md5:
				push_warning("MapDownloader: Cached file MD5 mismatch for ", name_base,
					" (cached=", actual_md5, " expected=", expected_md5, ") — re-downloading")
				return ""
	return hash_key


func _pr_install_from_cache(hash_key: String, entry: Dictionary) -> void:
	var cache: Node = _cache_manager
	var session_mgr: Node = _session_manager
	if cache == null:
		return
	var orig_name: String = entry.get("filename", cache.get_original_name(hash_key))
	if session_mgr and session_mgr.is_session_active():
		session_mgr.associate_file(hash_key, orig_name, ServerSessionManager.TYPE_MAP)
		if session_mgr.install_file_for_session(hash_key, orig_name, ServerSessionManager.TYPE_MAP):
			return
	var game_dir := _get_game_dir()
	if game_dir != "":
		cache.install_to_game_dir(hash_key, game_dir)


# ---------------------------------------------------------------------------
# Source 2: sv_maplist
# ---------------------------------------------------------------------------

func _try_sv_maplist() -> bool:
	if _runner == null or not _runner.has_method("get_cvar_string"):
		return false
	var maplist: String = _runner.get_cvar_string("sv_maplist")
	if maplist.strip_edges() == "":
		return false

	# Parse space/comma/newline-separated map names.
	var map_names := _whitespace_regex.sub(maplist.strip_edges(), " ", true).split(" ")
	if map_names.is_empty():
		return false

	var maps_to_search: Array = []

	for mname in map_names:
		var mn: String = mname.strip_edges()
		if mn == "":
			continue
		# Check if this map's BSP already exists in the VFS.
		if _map_bsp_exists(mn):
			continue
		# Check cache.
		var map_base := mn.get_file().to_lower()
		if _cache_manager:
			var cached := _cache_manager.find_cached_file_by_name(map_base)
			if cached != "":
				_install_from_cache_silent(cached, map_base + ".pk3")
				_had_downloads = true
				_queue.append({
"filename": map_base + ".pk3",
"url": "",
"md5": "",
"alias": mn,
"source": "sv_maplist",
"status": "cached",
"size": 0,
})
				continue
		maps_to_search.append(mn)

	if maps_to_search.is_empty():
		if _had_downloads:
			_all_downloads_complete()
			return true
		return false

	_current_source = "sv_maplist"
	print("MapDownloader: sv_maplist — ", maps_to_search.size(), " maps to search on moh-db.com")

	# Add pending entries for each map to the queue.
	for mn in maps_to_search:
		_queue.append({
"filename": mn.get_file() + ".pk3",
			"url": "",
			"md5": "",
			"alias": mn,
			"source": "sv_maplist",
			"status": "pending",
			"size": 0,
		})

	_maplist_search_queue = maps_to_search
	_maplist_search_index = 0

	_show_queue_ui()
	download_started.emit(_current_map_name)

	# Start searching for each map sequentially.
	_search_next_maplist_entry()
	return true


func _map_bsp_exists(map_name: String) -> bool:
	if _runner == null or not _runner.has_method("vfs_file_exists"):
		return false
	var bsp_path := "maps/" + map_name + ".bsp"
	return _runner.vfs_file_exists(bsp_path)


func _search_next_maplist_entry() -> void:
	if _maplist_search_index >= _maplist_search_queue.size():
		# All searches done — start downloading queued entries.
		_start_next_queue_download()
		return

	var map_name: String = _maplist_search_queue[_maplist_search_index]
	var search_term := map_name.get_file()

	# Find the queue entry for this map.
	var qi := _find_queue_index_for_maplist(map_name)
	if qi >= 0:
		_queue[qi]["status"] = "searching"
		_update_file_item_status(qi)

	_current_file_label.text = "Searching: " + search_term
	_current_progress.value = 0.0
	_current_detail.text = "Querying moh-db.com…"

	var url := API_BASE_URL + "/api/external/v1/maps?mapName=" + search_term.uri_encode() \
		+ "&page=0&size=" + str(API_PAGE_SIZE)

	var headers: PackedStringArray = []
	if _api_key != "":
		headers.append("X-API-Key: " + _api_key)

	set_meta("maplist_search_name", map_name)

	var err := _http_search.request(url, headers)
	if err != OK:
		push_warning("MapDownloader: sv_maplist search failed for ", map_name)
		if qi >= 0:
			_queue[qi]["status"] = "error"
			_update_file_item_status(qi)
		_maplist_search_index += 1
		_search_next_maplist_entry()


func _find_queue_index_for_maplist(map_name: String) -> int:
	var search_base := map_name.get_file().to_lower()
	for i in range(_queue.size()):
		if _queue[i]["source"] == "sv_maplist" and (_queue[i]["status"] == "pending" or _queue[i]["status"] == "searching"):
			var entry_base: String = _queue[i]["alias"].get_file().to_lower()
			if entry_base == search_base:
				return i
	return -1


# ---------------------------------------------------------------------------
# Source 3: moh-db.com single map search (fallback)
# ---------------------------------------------------------------------------

func _try_install_from_cache_or_search(map_name: String) -> void:
	# Check cache first.
	if _cache_manager:
		var map_base := map_name.get_file().to_lower()
		var hash_key: String = _cache_manager.find_cached_file_by_name(map_base)
		if hash_key != "":
			var orig_name: String = _cache_manager.get_original_name(hash_key)
			print("MapDownloader: Found in cache — ", orig_name)
			if _session_manager and _session_manager.is_session_active():
				_session_manager.associate_file(hash_key, orig_name, ServerSessionManager.TYPE_MAP)
			_install_and_reconnect(hash_key)
			return

	# Single map search on moh-db.com.
	_current_source = "moh-db.com"
	_queue.append({
"filename": map_name.get_file() + ".pk3",
		"url": "",
		"md5": "",
		"alias": map_name,
		"source": "moh-db.com",
		"status": "searching",
		"size": 0,
	})
	_show_queue_ui()
	download_started.emit(map_name)
	_start_mohdb_search(map_name)


func _start_mohdb_search(map_name: String) -> void:
	_retry_count = 0
	var search_term := map_name.get_file()

	_current_file_label.text = "Searching: " + search_term
	_current_progress.value = 0.0
	_current_detail.text = "Querying moh-db.com…"

	var url := API_BASE_URL + "/api/external/v1/maps?mapName=" + search_term.uri_encode() \
		+ "&page=0&size=" + str(API_PAGE_SIZE)

	var headers: PackedStringArray = []
	if _api_key != "":
		headers.append("X-API-Key: " + _api_key)

	set_meta("maplist_search_name", "")

	var err := _http_search.request(url, headers)
	if err != OK:
		_fail("API search request failed: error %d" % err)


# ---------------------------------------------------------------------------
# moh-db.com search completion (shared by sv_maplist + single-map)
# ---------------------------------------------------------------------------

func _on_search_completed(result: int, response_code: int,
_headers: PackedStringArray, body: PackedByteArray) -> void:
	var maplist_name: String = get_meta("maplist_search_name", "")
	var is_maplist_search := (maplist_name != "")

	if result != HTTPRequest.RESULT_SUCCESS:
		_retry_count += 1
		if _retry_count <= MAX_RETRIES:
			var retry_name := maplist_name if is_maplist_search else _current_map_name
			get_tree().create_timer(1.0 * _retry_count).timeout.connect(
func():
					if is_maplist_search:
						_search_next_maplist_entry()
					else:
						_start_mohdb_search(retry_name))
			return
		if is_maplist_search:
			var qi := _find_queue_index_for_maplist(maplist_name)
			if qi >= 0:
				_queue[qi]["status"] = "error"
				_update_file_item_status(qi)
			_maplist_search_index += 1
			_search_next_maplist_entry()
			return
		_fail("API unreachable after %d retries" % MAX_RETRIES)
		return

	if response_code < 200 or response_code >= 300:
		if is_maplist_search:
			var qi := _find_queue_index_for_maplist(maplist_name)
			if qi >= 0:
				_queue[qi]["status"] = "error"
				_update_file_item_status(qi)
			_maplist_search_index += 1
			_search_next_maplist_entry()
			return
		_fail("moh-db.com returned HTTP %d" % response_code)
		return

	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if parsed == null:
		if is_maplist_search:
			_maplist_search_index += 1
			_search_next_maplist_entry()
			return
		_fail("Invalid JSON from moh-db.com API")
		return

	var results: Array = []
	if parsed is Dictionary and parsed.has("content") and parsed["content"] is Array:
		results = parsed["content"]
	elif parsed is Array:
		results = parsed

	var search_name := maplist_name if is_maplist_search else _current_map_name

	if results.is_empty():
		if is_maplist_search:
			var qi := _find_queue_index_for_maplist(maplist_name)
			if qi >= 0:
				_queue[qi]["status"] = "error"
				_update_file_item_status(qi)
			_maplist_search_index += 1
			_search_next_maplist_entry()
			return
		_fail("Map '%s' not found on moh-db.com" % _current_map_name, true)
		return

	# Pick best match.
	var best: Dictionary = results[0]
	var search_lower := search_name.get_file().to_lower()
	for entry in results:
		if not entry is Dictionary:
			continue
		var en: Variant = entry.get("mapName", "")
		if en == null:
			en = ""
		var enl: String = String(en).to_lower().trim_suffix(".pk3").trim_suffix(".zip")
		if enl == search_lower:
			best = entry
			break

	# Extract download URL.
	var download_url: String = ""
	var map_file: Variant = best.get("mapFile")
	if map_file is Dictionary and map_file.get("downloadLink", "") != "":
		download_url = map_file["downloadLink"]
	if download_url == "":
		var top_link: Variant = best.get("downloadLink", "")
		if top_link != null:
			download_url = String(top_link)

	if download_url == "":
		if is_maplist_search:
			var qi := _find_queue_index_for_maplist(maplist_name)
			if qi >= 0:
				_queue[qi]["status"] = "error"
				_update_file_item_status(qi)
			_maplist_search_index += 1
			_search_next_maplist_entry()
			return
		_fail("No download URL for '%s'" % _current_map_name, true)
		return

	# Extract file name and size.
	var file_name: String = ""
	var file_size: int = 0
	if map_file is Dictionary:
		var fn: Variant = map_file.get("filename", "")
		if fn != null:
			file_name = String(fn)
		file_size = int(map_file.get("filesize", 0))
	if file_name == "":
		var mn: Variant = best.get("mapName", "")
		if mn != null and String(mn) != "":
			file_name = String(mn)
		else:
			file_name = search_name
	if not file_name.to_lower().ends_with(".pk3") and not file_name.to_lower().ends_with(".zip"):
		file_name += ".pk3"
	file_name = _sanitize_filename(file_name)

	if is_maplist_search:
		var qi := _find_queue_index_for_maplist(maplist_name)
		if qi >= 0:
			_queue[qi]["url"] = download_url
			_queue[qi]["filename"] = file_name
			_queue[qi]["size"] = file_size
			_queue[qi]["status"] = "pending"
			_update_file_item_status(qi)
		_maplist_search_index += 1
		_search_next_maplist_entry()
	else:
		if _queue.size() > 0:
			_queue[0]["url"] = download_url
			_queue[0]["filename"] = file_name
			_queue[0]["size"] = file_size
			_queue[0]["status"] = "pending"
			_update_file_item_status(0)
		_queue_index = 0
		_start_next_queue_download()


# ---------------------------------------------------------------------------
# Unified download queue execution
# ---------------------------------------------------------------------------

func _start_next_queue_download() -> void:
	# Find next pending entry with a URL.
	while _queue_index < _queue.size():
		var entry: Dictionary = _queue[_queue_index]
		if entry["status"] == "pending" and entry["url"] != "":
			break
		if entry["status"] == "pending" and entry["url"] == "":
			entry["status"] = "error"
			_update_file_item_status(_queue_index)
		_queue_index += 1

	if _queue_index >= _queue.size():
		_all_downloads_complete()
		return

	var entry: Dictionary = _queue[_queue_index]
	var filename: String = entry.get("filename", "unknown.pk3")
	var url: String = entry.get("url", "")
	var source: String = entry.get("source", "")

	entry["status"] = "downloading"
	_update_file_item_status(_queue_index)
	_update_overall_progress()

	_current_file_label.text = filename
	_current_progress.value = 0.0
	_current_progress.modulate = Color.WHITE
	_current_detail.text = "Starting download…"

	_download_path = "user://cache/_downloading.tmp"
	if not DirAccess.dir_exists_absolute("user://cache/"):
		DirAccess.make_dir_recursive_absolute("user://cache/")

	set_meta("q_entry_index", _queue_index)
	_progress_timer = 0.0

	var pending_count := _count_pending()
	print("MapDownloader: Downloading ", _queue_index + 1, "/", _queue.size(),
		" (", pending_count, " remaining): ", filename, " [", source, "]")

	if source == "pr_downloads":
		_downloading_pr = true
		set_process(true)
		_http_pr_download.download_file = _download_path
		var err := _http_pr_download.request(url)
		if err != OK:
			_downloading_pr = false
			entry["status"] = "error"
			_update_file_item_status(_queue_index)
			_queue_index += 1
			_start_next_queue_download()
	else:
		_downloading = true
		set_process(true)
		_http_download.download_file = _download_path
		var err := _http_download.request(url)
		if err != OK:
			_downloading = false
			entry["status"] = "error"
			_update_file_item_status(_queue_index)
			_queue_index += 1
			_start_next_queue_download()


func _on_queue_download_done(result: int, response_code: int, source: String) -> void:
	var qi: int = get_meta("q_entry_index", -1)
	if qi < 0 or qi >= _queue.size():
		_cleanup_temp()
		return

	var entry: Dictionary = _queue[qi]
	var filename: String = entry.get("filename", "unknown.pk3")

	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_cleanup_temp()
		entry["status"] = "error"
		_update_file_item_status(qi)
		push_warning("MapDownloader: Download failed for ", filename,
" (result=", result, " http=", response_code, ")")
		_queue_index += 1
		_start_next_queue_download()
		return

	# Verify MD5 if provided (pr_downloads).
	var expected_md5: String = entry.get("md5", "")
	if expected_md5 != "":
		var actual_md5 := _md5_of_file(_download_path)
		if actual_md5 != expected_md5:
			push_warning("MapDownloader: MD5 mismatch for ", filename,
": expected ", expected_md5, ", got ", actual_md5)

	# Compute SHA-256 for CacheManager.
	var sha256 := CacheManager.sha256_of_file(_download_path)
	if sha256 == "":
		_cleanup_temp()
		entry["status"] = "error"
		_update_file_item_status(qi)
		_queue_index += 1
		_start_next_queue_download()
		return

	# Move to cache.
	var cache: Node = _cache_manager
	if cache == null:
		_cleanup_temp()
		_fail("CacheManager not available")
		return

	var final_path: String = cache.get_cached_path(sha256)
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(final_path)
	var mv_err := DirAccess.rename_absolute(_download_path, final_path)
	if mv_err != OK:
		_cleanup_temp()
		entry["status"] = "error"
		_update_file_item_status(qi)
		_queue_index += 1
		_start_next_queue_download()
		return

	var file_size := 0
	var f := FileAccess.open(final_path, FileAccess.READ)
	if f:
		file_size = f.get_length()
		f.close()

	cache.register_file(sha256, filename, file_size)

	var session_mgr: Node = _session_manager
	if session_mgr and session_mgr.is_session_active():
		session_mgr.associate_file(sha256, filename, ServerSessionManager.TYPE_MAP)

	if session_mgr and session_mgr.is_session_active():
		session_mgr.install_file_for_session(sha256, filename, ServerSessionManager.TYPE_MAP)
	else:
		var game_dir := _get_game_dir()
		if game_dir != "":
			cache.install_to_game_dir(sha256, game_dir)

	entry["status"] = "complete"
	entry["size"] = file_size
	_update_file_item_status(qi)
	_had_downloads = true
	# Clear failed map cooldown on successful download.
	_failed_maps.erase(_current_map_bsp)

	print("MapDownloader: Installed ", filename, " (", _human_size(file_size), ")")

	_queue_index += 1
	_start_next_queue_download()


func _on_pr_download_completed(result: int, response_code: int,
_headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http_pr_download.download_file = ""
	_downloading_pr = false
	_on_queue_download_done(result, response_code, "pr_downloads")


func _on_download_completed(result: int, response_code: int,
_headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http_download.download_file = ""
	_downloading = false
	_on_queue_download_done(result, response_code, "moh-db.com")


# ---------------------------------------------------------------------------
# Completion / reconnect
# ---------------------------------------------------------------------------

func _all_downloads_complete() -> void:
	_downloading = false
	_downloading_pr = false

	var errors := _count_status("error")
	var completed := _count_status("complete") + _count_status("cached")
	var map_name := _current_map_name
	var server_addr := _last_server_address

	if completed == 0 and not _had_downloads:
		_fail("No files could be downloaded for this server")
		return

	_show_ui_reconnecting(completed, errors)
	print("MapDownloader: All downloads done (", completed, " installed, ", errors, " errors) — reconnecting in ", RECONNECT_DELAY, "s…")
	download_completed.emit(map_name)

	await get_tree().create_timer(RECONNECT_DELAY).timeout
	_busy = false
	_hide_ui()

	if _runner and _runner.has_method("execute_command"):
		if _runner.has_method("vfs_restart"):
			_runner.vfs_restart()
		else:
			_runner.execute_command("fs_restart")

		if server_addr != "":
			_runner.execute_command("connect " + server_addr)
		else:
			_runner.execute_command("reconnect")


func _install_and_reconnect(file_hash: String) -> void:
	var cache: Node = _cache_manager
	if cache == null:
		_fail("CacheManager not available for install")
		return

	var session_mgr: Node = _session_manager
	if session_mgr and session_mgr.is_session_active():
		var file_name: String = cache.get_original_name(file_hash)
		if file_name == "":
			file_name = file_hash.left(12) + ".pk3"
		if session_mgr.install_file_for_session(file_hash, file_name, ServerSessionManager.TYPE_MAP):
			_show_ui_reconnecting(1, 0)
			_finish_reconnect()
			return

	var game_dir := _get_game_dir()
	if game_dir == "":
		_fail("Cannot determine game directory")
		return

	cache.install_to_game_dir(file_hash, game_dir)
	_show_ui_reconnecting(1, 0)
	_finish_reconnect()


func _finish_reconnect() -> void:
	var server_addr := _last_server_address
	download_completed.emit(_current_map_name)

	await get_tree().create_timer(RECONNECT_DELAY).timeout
	_busy = false
	_hide_ui()

	if _runner and _runner.has_method("execute_command"):
		if _runner.has_method("vfs_restart"):
			_runner.vfs_restart()
		else:
			_runner.execute_command("fs_restart")

		if server_addr != "":
			_runner.execute_command("connect " + server_addr)
		else:
			_runner.execute_command("reconnect")


func _install_from_cache_silent(hash_key: String, file_name: String) -> void:
	var cache: Node = _cache_manager
	var session_mgr: Node = _session_manager
	if cache == null:
		return
	if session_mgr and session_mgr.is_session_active():
		session_mgr.associate_file(hash_key, file_name, ServerSessionManager.TYPE_MAP)
		if session_mgr.install_file_for_session(hash_key, file_name, ServerSessionManager.TYPE_MAP):
			return
	var game_dir := _get_game_dir()
	if game_dir != "":
		cache.install_to_game_dir(hash_key, game_dir)


# ---------------------------------------------------------------------------
# Failure
# ---------------------------------------------------------------------------

func _fail(reason: String, is_not_found: bool = false) -> void:
	_cancel_all_http()
	_downloading = false
	_downloading_pr = false
	_cleanup_temp()
	# Record this map as failed to prevent infinite reconnect loops.
	if _current_map_bsp != "":
		_failed_maps[_current_map_bsp] = Time.get_ticks_msec() / 1000.0
	push_warning("MapDownloader: FAILED — ", reason)
	_show_ui_error(reason, is_not_found)
	download_failed.emit(_current_map_name, reason)
	# Keep _busy true and set _showing_error to block re-entry during the await.
	_showing_error = true
	await get_tree().create_timer(ERROR_DISPLAY_TIME).timeout
	_showing_error = false
	_busy = false
	_hide_ui()


func _cleanup_temp() -> void:
	if _download_path != "" and FileAccess.file_exists(_download_path):
		DirAccess.remove_absolute(_download_path)
	_download_path = ""


# ---------------------------------------------------------------------------
# Overlay UI — download dashboard
# ---------------------------------------------------------------------------

func _build_overlay_ui() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 200
	add_child(_overlay)

	# Full-screen dark background.
	_bg = ColorRect.new()
	_bg.color = Color(0.05, 0.05, 0.08, 0.92)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(_bg)

	# Centre panel.
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(620, 420)
	_panel.position = Vector2(-310, -210)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.1, 0.1, 0.14, 0.95)
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_color = Color(0.3, 0.4, 0.6, 0.6)
	panel_style.content_margin_left = 20
	panel_style.content_margin_right = 20
	panel_style.content_margin_top = 16
	panel_style.content_margin_bottom = 16
	_panel.add_theme_stylebox_override("panel", panel_style)
	_overlay.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	# Title.
	_title_label = Label.new()
	_title_label.text = "Downloading Server Content"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", Color(0.9, 0.92, 1.0))
	vbox.add_child(_title_label)

	# Source label.
	_source_label = Label.new()
	_source_label.text = ""
	_source_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_source_label.add_theme_font_size_override("font_size", 12)
	_source_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.8))
	vbox.add_child(_source_label)

	# Overall progress label.
	_overall_label = Label.new()
	_overall_label.text = ""
	_overall_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overall_label.add_theme_font_size_override("font_size", 13)
	_overall_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.9))
	vbox.add_child(_overall_label)

	# Overall progress bar.
	_overall_progress = ProgressBar.new()
	_overall_progress.min_value = 0.0
	_overall_progress.max_value = 100.0
	_overall_progress.value = 0.0
	_overall_progress.custom_minimum_size = Vector2(0, 18)
	_overall_progress.show_percentage = false
	vbox.add_child(_overall_progress)

	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 6)
	vbox.add_child(sep)

	# File list scroll area.
	_file_scroll = ScrollContainer.new()
	_file_scroll.custom_minimum_size = Vector2(0, 140)
	_file_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_file_scroll)

	_file_list_container = VBoxContainer.new()
	_file_list_container.add_theme_constant_override("separation", 2)
	_file_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_file_scroll.add_child(_file_list_container)

	var sep2 := HSeparator.new()
	sep2.add_theme_constant_override("separation", 6)
	vbox.add_child(sep2)

	# Current file label.
	_current_file_label = Label.new()
	_current_file_label.text = ""
	_current_file_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_current_file_label.add_theme_font_size_override("font_size", 13)
	_current_file_label.add_theme_color_override("font_color", Color(0.85, 0.88, 1.0))
	vbox.add_child(_current_file_label)

	# Current file progress bar.
	_current_progress = ProgressBar.new()
	_current_progress.min_value = 0.0
	_current_progress.max_value = 100.0
	_current_progress.value = 0.0
	_current_progress.custom_minimum_size = Vector2(0, 22)
	_current_progress.show_percentage = false
	vbox.add_child(_current_progress)

	# Current file detail.
	_current_detail = Label.new()
	_current_detail.text = ""
	_current_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_current_detail.add_theme_font_size_override("font_size", 12)
	_current_detail.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	vbox.add_child(_current_detail)

	# Disconnect button.
	_disconnect_btn = Button.new()
	_disconnect_btn.text = "Disconnect"
	_disconnect_btn.custom_minimum_size = Vector2(140, 34)
	_disconnect_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_disconnect_btn.visible = false
	_disconnect_btn.pressed.connect(_on_disconnect_pressed)
	vbox.add_child(_disconnect_btn)


func _show_ui_fetching(source: String, message: String) -> void:
	_title_label.text = "Downloading Server Content"
	_source_label.text = "Source: " + source
	_overall_label.text = message
	_overall_progress.value = 0.0
	_overall_progress.modulate = Color.WHITE
	_current_file_label.text = ""
	_current_progress.value = 0.0
	_current_detail.text = ""
	_disconnect_btn.visible = false
	for child in _file_list_container.get_children():
		child.queue_free()
	_file_item_nodes.clear()
	_overlay.visible = true


func _show_queue_ui() -> void:
	_title_label.text = "Downloading Server Content"
	_source_label.text = "Source: " + _current_source
	_disconnect_btn.visible = false
	_overlay.visible = true

	for child in _file_list_container.get_children():
		child.queue_free()
	_file_item_nodes.clear()

	for i in range(_queue.size()):
		var entry: Dictionary = _queue[i]
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		_file_list_container.add_child(hbox)

		var icon_label := Label.new()
		icon_label.custom_minimum_size = Vector2(20, 0)
		icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		icon_label.add_theme_font_size_override("font_size", 13)
		hbox.add_child(icon_label)

		var name_label := Label.new()
		var display_name: String = entry.get("alias", entry.get("filename", ""))
		if display_name == "":
			display_name = entry.get("filename", "???")
		name_label.text = display_name
		name_label.add_theme_font_size_override("font_size", 12)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		hbox.add_child(name_label)

		_file_item_nodes.append({"icon": icon_label, "label": name_label, "hbox": hbox})
		_update_file_item_status(i)

	_update_overall_progress()


func _update_file_item_status(index: int) -> void:
	if index < 0 or index >= _file_item_nodes.size() or index >= _queue.size():
		return
	var node_info: Dictionary = _file_item_nodes[index]
	var icon_label: Label = node_info["icon"]
	var name_label: Label = node_info["label"]
	var entry: Dictionary = _queue[index]
	var status: String = entry.get("status", "pending")

	match status:
		"pending":
			icon_label.text = "○"
			icon_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			name_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		"searching":
			icon_label.text = "◌"
			icon_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.3))
			name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.3))
		"downloading":
			icon_label.text = "▼"
			icon_label.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
			name_label.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0))
		"complete":
			icon_label.text = "✓"
			icon_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
			name_label.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
		"cached":
			icon_label.text = "✓"
			icon_label.add_theme_color_override("font_color", Color(0.3, 0.8, 0.5))
			name_label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5))
		"skipped":
			icon_label.text = "–"
			icon_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
			name_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
		"error":
			icon_label.text = "✗"
			icon_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			name_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))


func _update_overall_progress() -> void:
	var total := _queue.size()
	if total == 0:
		return
	var done := _count_status("complete") + _count_status("cached") + _count_status("skipped") + _count_status("error")
	_overall_label.text = "%d / %d files processed" % [done, total]
	_overall_progress.value = (float(done) / float(total)) * 100.0


func _update_current_progress() -> void:
	var http: HTTPRequest = _http_pr_download if _downloading_pr else _http_download
	var body_size := http.get_body_size()
	var downloaded := http.get_downloaded_bytes()
	if body_size > 0:
		var pct := clampf(float(downloaded) / float(body_size) * 100.0, 0.0, 100.0)
		_current_progress.value = pct
		_current_detail.text = "%s / %s  (%d%%)" % [
			_human_size(downloaded), _human_size(body_size), int(pct)]
		download_progress.emit(_current_map_name, pct)
	elif downloaded > 0:
		_current_progress.value = 0.0
		_current_detail.text = "%s downloaded…" % _human_size(downloaded)


func _show_ui_reconnecting(completed: int, errors: int) -> void:
	_title_label.text = "Downloads Complete"
	if errors > 0:
		_source_label.text = "%d installed, %d failed" % [completed, errors]
	else:
		_source_label.text = "%d file(s) installed" % completed
	_overall_label.text = "Reloading VFS and reconnecting…"
	_overall_progress.value = 100.0
	_overall_progress.modulate = Color(0.3, 1.0, 0.3)
	_current_file_label.text = ""
	_current_progress.value = 100.0
	_current_progress.modulate = Color(0.3, 1.0, 0.3)
	_current_detail.text = ""
	_disconnect_btn.visible = false


func _show_ui_error(reason: String, is_not_found: bool = false) -> void:
	if is_not_found:
		_title_label.text = "Map Not Available"
		_source_label.text = "This map could not be found in the moh-db.com database."
	else:
		_title_label.text = "Download Failed"
		_source_label.text = ""
	_overall_label.text = reason
	_overall_progress.value = 0.0
	_overall_progress.modulate = Color(1.0, 0.3, 0.3)
	_current_file_label.text = ""
	_current_progress.value = 0.0
	_current_detail.text = ""
	_disconnect_btn.visible = true
	_overlay.visible = true


func _hide_ui() -> void:
	if _overlay:
		_overlay.visible = false


func _on_disconnect_pressed() -> void:
	_cancel_all_http()
	_cleanup_temp()
	_hide_ui()
	_busy = false
	_showing_error = false
	_downloading = false
	_downloading_pr = false
	if _runner and _runner.has_method("execute_command"):
		_runner.execute_command("disconnect")
	var session_mgr: Node = _session_manager
	if session_mgr and session_mgr.is_session_active():
		session_mgr.end_session()


func _cancel_all_http() -> void:
	if _http_search:
		_http_search.cancel_request()
	if _http_download:
		_http_download.cancel_request()
		_http_download.download_file = ""
	if _http_pr_filelist:
		_http_pr_filelist.cancel_request()
	if _http_pr_download:
		_http_pr_download.cancel_request()
		_http_pr_download.download_file = ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _get_game_dir() -> String:
	if _runner and _runner.has_method("vfs_get_writable_gamedir"):
		var gd: String = _runner.vfs_get_writable_gamedir()
		if gd != "":
			return gd
	if _runner and _runner.has_method("get_basepath"):
		var bp: String = _runner.get_basepath()
		if bp != "":
			if not bp.ends_with("/"):
				bp += "/"
			return bp + "main"
	return ""


func _count_pending() -> int:
	var c := 0
	for e in _queue:
		if e["status"] == "pending":
			c += 1
	return c


func _count_status(status: String) -> int:
	var c := 0
	for e in _queue:
		if e["status"] == status:
			c += 1
	return c


func _human_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1048576:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / 1048576.0)


func _extract_quoted_field(block: String, key: String) -> String:
	var key_pos := block.find(key)
	while key_pos >= 0:
		if key_pos > 0:
			var prev_char := block[key_pos - 1]
			if prev_char != " " and prev_char != "\t" and prev_char != "\n" and prev_char != "\r":
				key_pos = block.find(key, key_pos + 1)
				continue
		var after_key := key_pos + key.length()
		while after_key < block.length() and (block[after_key] == " " or block[after_key] == "\t"):
			after_key += 1
		if after_key >= block.length() or block[after_key] != "\"":
			key_pos = block.find(key, key_pos + 1)
			continue
		var quote_start := after_key + 1
		var quote_end := block.find("\"", quote_start)
		if quote_end < 0:
			break
		return block.substr(quote_start, quote_end - quote_start)
	return ""


static func _md5_of_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	while f.get_position() < f.get_length():
		var chunk := f.get_buffer(65536)
		ctx.update(chunk)
	f.close()
	return ctx.finish().hex_encode()


## Sanitise a filename to prevent path traversal. Strips directory components
## and removes any characters that could escape the target directory.
static func _sanitize_filename(name: String) -> String:
	var clean := name.get_file()  # strip directory components
	clean = clean.replace("..", "").replace("/", "").replace("\\", "")
	clean = clean.strip_edges()
	if clean == "":
		clean = "unknown.pk3"
	return clean
