## CacheManager.gd — Content-addressed cache for downloaded map/mod files.
##
## UT-style shared cache: files stored in user://cache/ using their SHA-256
## hash as the filename (e.g. user://cache/a1b2c3d4.pk3).  A JSON registry
## maps hashes back to original filenames and metadata.
##
## The cache is **shared across all servers** — if two servers need the same
## map (same hash), it is stored only once.  Per-server isolation is handled
## by ServerSessionManager, not here.
##
## OpenMoHAA VFS note: pk3 files must be placed in the top-level game
## directory (e.g. main/).  The engine does NOT recurse into subdirectories
## to find pk3 files (it only scans top-level .pk3 and .pk3dir entries
## during FS_AddGameDirectory).  Files are installed via install_to_game_dir()
## which copies them to the game directory root.
##
## Usage (autoload singleton "CacheManager"):
##   CacheManager.has_file(sha256_hex)         -> bool
##   CacheManager.get_cached_path(sha256_hex)   -> String
##   CacheManager.register_file(sha256_hex, original_name, size_bytes)
##   CacheManager.install_to_game_dir(sha256_hex, game_dir) -> bool
extends Node

const CACHE_DIR := "user://cache/"
const REGISTRY_PATH := "user://cache/cache_registry.json"

## { "sha256_hex": { "original_name": String, "size": int, "added_utc": String } }
var _registry: Dictionary = {}
var _registry_dirty: bool = false


func _ready() -> void:
	_ensure_cache_dir()
	_load_registry()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_save_registry()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Returns true when a file with the given hash is present and recorded.
func has_file(sha256_hex: String) -> bool:
	var key := sha256_hex.to_lower()
	if not _registry.has(key):
		return false
	return FileAccess.file_exists(_path_for(key))


## Absolute user:// path for the cached file (may not exist yet).
func get_cached_path(sha256_hex: String) -> String:
	return _path_for(sha256_hex.to_lower())


## Register a newly-downloaded file in the cache registry.
func register_file(sha256_hex: String, original_name: String, size_bytes: int) -> void:
	var key := sha256_hex.to_lower()
	_registry[key] = {
		"original_name": original_name,
		"size": size_bytes,
		"added_utc": Time.get_datetime_string_from_system(true),
	}
	_registry_dirty = true
	_save_registry()
	print("CacheManager: Registered ", original_name, " (", _human_size(size_bytes), ") hash=", key.left(12), "…")


## Get the original filename for a cached hash.
func get_original_name(sha256_hex: String) -> String:
	var key := sha256_hex.to_lower()
	if _registry.has(key):
		return _registry[key].get("original_name", "")
	return ""


## Search the cache for a file whose original name matches the given map name.
## Returns the hash key if found, or "" if not.
## Matches case-insensitively, stripping .pk3/.zip extensions.
func find_cached_file_by_name(map_name: String) -> String:
	var search_lower := map_name.to_lower()
	for hash_key in _registry:
		var entry: Dictionary = _registry[hash_key]
		var orig_name: String = entry.get("original_name", "")
		var name_lower := orig_name.to_lower().trim_suffix(".pk3").trim_suffix(".zip")
		# Exact match only — ends_with could false-positive on partial names.
		if name_lower == search_lower:
			return hash_key
	return ""


## Copy a cached file to the game directory so the engine VFS can find it.
## Returns true on success.  If the destination file already exists, the copy
## is skipped to protect vanilla game files from being overwritten.
func install_to_game_dir(sha256_hex: String, game_dir: String) -> bool:
	var key := sha256_hex.to_lower()
	var cache_path := _path_for(key)
	if not FileAccess.file_exists(cache_path):
		push_warning("CacheManager: Cannot install — cached file not found: ", cache_path)
		return false

	var original_name := get_original_name(key)
	if original_name == "":
		original_name = key + ".pk3"

	# Sanitise filename to prevent path traversal from malicious API responses.
	original_name = _sanitize_filename(original_name)

	# Ensure game_dir ends with /
	if not game_dir.ends_with("/"):
		game_dir += "/"

	var dest_path := game_dir + original_name

	# Safety: never overwrite a file already present in the game directory.
	# It may be a vanilla game pk3 or content from another source.
	if FileAccess.file_exists(dest_path):
		print("CacheManager: File already present in game dir, skipping: ", original_name)
		return true

	# Read from cache and write to game directory.
	var src := FileAccess.open(cache_path, FileAccess.READ)
	if src == null:
		push_warning("CacheManager: Cannot read cache file: ", FileAccess.get_open_error())
		return false

	var dst := FileAccess.open(dest_path, FileAccess.WRITE)
	if dst == null:
		src.close()
		var err_code := FileAccess.get_open_error()
		var hint := ""
		if err_code == ERR_FILE_NO_PERMISSION:
			if OS.has_feature("web"):
				hint = " (Web: IndexedDB storage quota may be exceeded)"
			elif OS.has_feature("windows"):
				hint = " (Windows: the game directory may be read-only or blocked by antivirus)"
			elif OS.has_feature("linux"):
				hint = " (Linux: check file permissions on the game directory)"
			elif OS.has_feature("macos"):
				hint = " (macOS: check file permissions or Gatekeeper restrictions)"
		elif OS.has_feature("web"):
			hint = " (Web: IndexedDB storage quota may be exceeded)"
		push_warning("CacheManager: Cannot write to game dir: ", dest_path, " error=", err_code, hint)
		return false

	while src.get_position() < src.get_length():
		var chunk := src.get_buffer(65536)
		if chunk.size() == 0:
			break
		dst.store_buffer(chunk)

	src.close()
	dst.close()
	print("CacheManager: Installed ", original_name, " -> ", dest_path)
	return true


## Remove a single entry from the cache (file + registry).
func remove_file(sha256_hex: String) -> void:
	var key := sha256_hex.to_lower()
	var path := _path_for(key)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if _registry.has(key):
		_registry.erase(key)
		_registry_dirty = true
		_save_registry()


## Prune oldest entries until total cache size is <= max_bytes.
## Returns the number of bytes freed.
func prune_cache(max_bytes: int) -> int:
	var entries: Array = []
	for key in _registry:
		var entry: Dictionary = _registry[key]
		entries.append({"key": key, "size": entry.get("size", 0), "added_utc": entry.get("added_utc", "")})

	# Sort oldest first.
	entries.sort_custom(func(a, b): return a["added_utc"] < b["added_utc"])

	var total := _total_cache_size()
	var freed := 0
	for e in entries:
		if total <= max_bytes:
			break
		var sz: int = e["size"]
		remove_file(e["key"])
		total -= sz
		freed += sz

	return freed


## Total bytes used by all cached files.
func get_total_size() -> int:
	return _total_cache_size()


## Compute the SHA-256 hex digest of a file on disk.
static func sha256_of_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		var chunk := f.get_buffer(65536)
		if chunk.size() == 0:
			break
		ctx.update(chunk)
	f.close()
	return ctx.finish().hex_encode()


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _ensure_cache_dir() -> void:
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)


func _path_for(key: String) -> String:
	return CACHE_DIR + key + ".pk3"


func _load_registry() -> void:
	if not FileAccess.file_exists(REGISTRY_PATH):
		_registry = {}
		return
	var f := FileAccess.open(REGISTRY_PATH, FileAccess.READ)
	if f == null:
		push_warning("CacheManager: Could not open registry: ", FileAccess.get_open_error())
		_registry = {}
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		_registry = parsed
	else:
		push_warning("CacheManager: Registry parse failed, starting fresh.")
		_registry = {}


func _save_registry() -> void:
	if not _registry_dirty:
		return
	_ensure_cache_dir()
	var f := FileAccess.open(REGISTRY_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("CacheManager: Could not write registry: ", FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify(_registry, "\t"))
	f.close()
	_registry_dirty = false


func _total_cache_size() -> int:
	var total := 0
	for key in _registry:
		var entry: Dictionary = _registry[key]
		total += entry.get("size", 0)
	return total


func _human_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	if bytes < 1048576:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / 1048576.0)


## Sanitise a filename to prevent path traversal attacks.
## Strips directory components (../, /, \) from filenames that come from
## external sources (API responses, server-provided file lists).
static func _sanitize_filename(name: String) -> String:
	# Use only the final component — strip any directory path.
	var sanitized := name.get_file()
	# Remove any remaining traversal sequences.
	sanitized = sanitized.replace("..", "").replace("/", "").replace("\\", "")
	if sanitized.strip_edges() == "" or sanitized == ".pk3":
		sanitized = "unknown.pk3"
	return sanitized
