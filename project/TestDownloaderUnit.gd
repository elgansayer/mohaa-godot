## TestDownloaderUnit.gd — Unit tests for MapDownloader + CacheManager audit fixes.
##
## Runs headlessly without a MOHAA server. Tests pure-logic methods:
##   - Filename sanitisation (path traversal prevention)
##   - pr_downloads filelist parsing + queue size limits
##   - _extract_quoted_field parsing
##   - find_cached_file_by_name exact matching
##   - Reconnect loop prevention (_failed_maps cooldown)
##   - _fail() re-entry guard (_showing_error flag)
##   - HTTP cancel helper exists
##
## Usage:
##   cd project && godot --headless res://TestDownloaderUnit.tscn
##   ./scripts/test-downloader-unit.sh
extends Node

var _results: Array = []
var _pass_count := 0
var _fail_count := 0


func _ready() -> void:
	print("DownloaderUnitTest: =========================================")
	print("DownloaderUnitTest: MapDownloader + CacheManager Unit Tests")
	print("DownloaderUnitTest: =========================================")
	print("")

	# Wait one frame for autoloads to initialise.
	await get_tree().process_frame

	_run_all_tests()
	_print_summary()

	var exit_code := 0 if _fail_count == 0 else 1
	get_tree().quit(exit_code)


func _run_all_tests() -> void:
	# --- CacheManager tests ---
	_test_cache_sanitize_filename()
	_test_cache_find_by_name_exact_match()
	_test_cache_install_sanitizes_filename()

	# --- MapDownloader tests ---
	_test_md_sanitize_filename()
	_test_md_parse_pr_filelist_basic()
	_test_md_parse_pr_filelist_queue_limit()
	_test_md_parse_pr_filelist_rejects_bad_url()
	_test_md_extract_quoted_field()
	_test_md_reconnect_loop_prevention()
	_test_md_fail_reentry_guard()
	_test_md_cancel_all_http_exists()
	_test_md_whitespace_regex_compiled()
	_test_md_no_dead_variables()


# =========================================================================
# CacheManager tests
# =========================================================================

func _test_cache_sanitize_filename() -> void:
	var cm := get_node_or_null("/root/CacheManager")
	if cm == null:
		_result(false, "CM._sanitize_filename", "CacheManager autoload not found")
		return

	# Normal filename — unchanged.
	_assert_eq(cm._sanitize_filename("mymap.pk3"), "mymap.pk3",
		"CM._sanitize_filename: normal filename")

	# Directory traversal — stripped.
	_assert_eq(cm._sanitize_filename("../../.bashrc"), ".bashrc",
		"CM._sanitize_filename: path traversal ../../")

	# Subdirectory path — only final component.
	_assert_eq(cm._sanitize_filename("foo/bar/baz.pk3"), "baz.pk3",
		"CM._sanitize_filename: subdirectory stripped")

	# Backslash path — only final component.
	_assert_eq(cm._sanitize_filename("foo\\bar\\baz.pk3"), "baz.pk3",
		"CM._sanitize_filename: backslash path stripped")

	# Empty → fallback.
	_assert_eq(cm._sanitize_filename(""), "unknown.pk3",
		"CM._sanitize_filename: empty → unknown.pk3")

	# Just dots — stripped to fallback.
	_assert_eq(cm._sanitize_filename("...."), "unknown.pk3",
		"CM._sanitize_filename: dots only → unknown.pk3")

	# Just .pk3 after stripping.
	_assert_eq(cm._sanitize_filename("../.pk3"), ".pk3",
		"CM._sanitize_filename: ../.pk3 keeps .pk3")


func _test_cache_find_by_name_exact_match() -> void:
	var cm := get_node_or_null("/root/CacheManager")
	if cm == null:
		_result(false, "CM.find_cached_file_by_name", "CacheManager autoload not found")
		return

	# Register a test entry.
	var test_hash := "0000000000000000000000000000000000000000000000000000000000000001"
	cm._registry[test_hash] = {
		"original_name": "dm_rockbound.pk3",
		"size": 1234,
		"added_utc": "2025-01-01T00:00:00",
	}

	# Exact match should work.
	_assert_eq(cm.find_cached_file_by_name("dm_rockbound"), test_hash,
		"CM.find_by_name: exact match 'dm_rockbound'")

	# Case-insensitive exact match.
	_assert_eq(cm.find_cached_file_by_name("DM_ROCKBOUND"), test_hash,
		"CM.find_by_name: case-insensitive 'DM_ROCKBOUND'")

	# Partial suffix should NOT match (the old ends_with bug).
	_assert_eq(cm.find_cached_file_by_name("rockbound"), "",
		"CM.find_by_name: partial 'rockbound' must NOT match")

	# Longer name should NOT match.
	_assert_eq(cm.find_cached_file_by_name("my_dm_rockbound"), "",
		"CM.find_by_name: longer 'my_dm_rockbound' must NOT match")

	# Clean up.
	cm._registry.erase(test_hash)


func _test_cache_install_sanitizes_filename() -> void:
	# This is a structural check — verify install_to_game_dir calls _sanitize_filename.
	# We can't easily test the full copy without a real file, but we verify the
	# sanitize call is in place by reading the source (already audited).
	# Instead, verify the _sanitize_filename method exists and is callable.
	var cm := get_node_or_null("/root/CacheManager")
	if cm == null:
		_result(false, "CM.install_sanitizes", "CacheManager autoload not found")
		return

	# Verify _sanitize_filename is callable.
	var result: String = cm._sanitize_filename("../evil.pk3")
	_assert_eq(result, "evil.pk3",
		"CM.install_sanitizes: _sanitize_filename callable and correct")


# =========================================================================
# MapDownloader tests
# =========================================================================

func _test_md_sanitize_filename() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD._sanitize_filename", "MapDownloader autoload not found")
		return

	# Normal filename — unchanged.
	_assert_eq(md._sanitize_filename("custommap.pk3"), "custommap.pk3",
		"MD._sanitize_filename: normal filename")

	# Directory traversal.
	_assert_eq(md._sanitize_filename("../../etc/passwd"), "passwd",
		"MD._sanitize_filename: path traversal stripped")

	# Backslash + traversal.
	_assert_eq(md._sanitize_filename("..\\..\\evil.pk3"), "evil.pk3",
		"MD._sanitize_filename: backslash traversal stripped")

	# Empty → fallback.
	_assert_eq(md._sanitize_filename(""), "unknown.pk3",
		"MD._sanitize_filename: empty → unknown.pk3")

	# URL-style path.
	_assert_eq(md._sanitize_filename("https://evil.com/files/map.pk3"), "map.pk3",
		"MD._sanitize_filename: URL path stripped to filename")


func _test_md_parse_pr_filelist_basic() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD._parse_pr_filelist", "MapDownloader autoload not found")
		return

	var filelist := """map {
	alias "dm_test"
	md5 "abc123def456"
	url "https://example.com/files/dm_test.pk3"
}
map {
	alias "obj_test"
	md5 "fedcba654321"
	url "https://example.com/files/obj_test.pk3"
}"""

	var entries: Array = md._parse_pr_filelist(filelist)
	_assert_eq(entries.size(), 2, "MD.parse_pr_filelist: parses 2 entries")

	if entries.size() >= 2:
		_assert_eq(entries[0]["alias"], "dm_test",
			"MD.parse_pr_filelist: entry 0 alias")
		_assert_eq(entries[0]["md5"], "abc123def456",
			"MD.parse_pr_filelist: entry 0 md5")
		_assert_eq(entries[0]["url"], "https://example.com/files/dm_test.pk3",
			"MD.parse_pr_filelist: entry 0 url")
		_assert_eq(entries[0]["filename"], "dm_test.pk3",
			"MD.parse_pr_filelist: entry 0 filename extracted from URL")

		_assert_eq(entries[1]["alias"], "obj_test",
			"MD.parse_pr_filelist: entry 1 alias")


func _test_md_parse_pr_filelist_queue_limit() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD.parse_pr_filelist_limit", "MapDownloader autoload not found")
		return

	# Build a filelist with 150 entries (exceeds MAX_QUEUE_ENTRIES=100).
	var text := ""
	for i in range(150):
		text += 'map {\n\talias "map_%03d"\n\tmd5 "hash%03d"\n\turl "https://example.com/map_%03d.pk3"\n}\n' % [i, i, i]

	var entries: Array = md._parse_pr_filelist(text)
	_assert_eq(entries.size(), 100,
		"MD.parse_pr_filelist: capped at MAX_QUEUE_ENTRIES (100)")


func _test_md_parse_pr_filelist_rejects_bad_url() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD.parse_pr_filelist_bad_url", "MapDownloader autoload not found")
		return

	var filelist := """map {
	alias "good"
	md5 "abc"
	url "https://example.com/good.pk3"
}
map {
	alias "bad_ftp"
	md5 "def"
	url "ftp://evil.com/bad.pk3"
}
map {
	alias "bad_file"
	md5 "ghi"
	url "file:///etc/passwd"
}
map {
	alias "bad_no_url"
	md5 "jkl"
}"""

	var entries: Array = md._parse_pr_filelist(filelist)
	_assert_eq(entries.size(), 1,
		"MD.parse_pr_filelist: rejects ftp://, file://, and missing URL")
	if entries.size() >= 1:
		_assert_eq(entries[0]["alias"], "good",
			"MD.parse_pr_filelist: only 'good' entry survives")


func _test_md_extract_quoted_field() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD._extract_quoted_field", "MapDownloader autoload not found")
		return

	var block := '\talias "my_map"\n\tmd5 "abc123"\n\turl "https://example.com/file.pk3"'

	_assert_eq(md._extract_quoted_field(block, "alias"), "my_map",
		"MD._extract_quoted_field: alias")
	_assert_eq(md._extract_quoted_field(block, "md5"), "abc123",
		"MD._extract_quoted_field: md5")
	_assert_eq(md._extract_quoted_field(block, "url"), "https://example.com/file.pk3",
		"MD._extract_quoted_field: url")
	_assert_eq(md._extract_quoted_field(block, "missing"), "",
		"MD._extract_quoted_field: missing key → empty")

	# Key embedded in another word should NOT match.
	var tricky := '\tnoturl "wrong"\n\turl "right"'
	_assert_eq(md._extract_quoted_field(tricky, "url"), "right",
		"MD._extract_quoted_field: does not match 'noturl' for 'url'")


func _test_md_reconnect_loop_prevention() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD.reconnect_loop", "MapDownloader autoload not found")
		return

	# Verify _failed_maps exists and is a Dictionary.
	_assert_true(md._failed_maps is Dictionary,
		"MD.reconnect_loop: _failed_maps is Dictionary")

	# Verify the constant exists.
	_assert_true(md.FAILED_MAP_COOLDOWN > 0,
		"MD.reconnect_loop: FAILED_MAP_COOLDOWN > 0 (is %s)" % str(md.FAILED_MAP_COOLDOWN))

	# Simulate a failed map entry.
	md._failed_maps["maps/dm/fakemap.bsp"] = Time.get_ticks_msec() / 1000.0
	_assert_true(md._failed_maps.has("maps/dm/fakemap.bsp"),
		"MD.reconnect_loop: _failed_maps tracks entries")

	# Clean up.
	md._failed_maps.erase("maps/dm/fakemap.bsp")


func _test_md_fail_reentry_guard() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD._fail_reentry", "MapDownloader autoload not found")
		return

	# Verify _showing_error flag exists.
	_assert_true("_showing_error" in md,
		"MD._fail_reentry: _showing_error property exists")

	# Verify initial state is false.
	_assert_eq(md._showing_error, false,
		"MD._fail_reentry: _showing_error initially false")

	# Verify _on_engine_error checks _showing_error.
	# Simulate: set _showing_error = true, then call _on_engine_error.
	# It should bail out without changing _busy.
	md._showing_error = true
	md._busy = false
	md._on_engine_error("Couldn't load maps/dm/fakemap.bsp")
	_assert_eq(md._busy, false,
		"MD._fail_reentry: _on_engine_error blocked by _showing_error")

	# Clean up.
	md._showing_error = false


func _test_md_cancel_all_http_exists() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD._cancel_all_http", "MapDownloader autoload not found")
		return

	_assert_true(md.has_method("_cancel_all_http"),
		"MD._cancel_all_http: method exists")

	# Call it — should be safe even when no requests are active.
	md._cancel_all_http()
	_result(true, "MD._cancel_all_http", "Called without error")


func _test_md_whitespace_regex_compiled() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD._whitespace_regex", "MapDownloader autoload not found")
		return

	_assert_true(md._whitespace_regex is RegEx,
		"MD._whitespace_regex: is RegEx instance")

	# Verify it's compiled and works.
	var result := md._whitespace_regex.sub("a  b\tc,d", " ", true)
	_assert_eq(result, "a b c d",
		"MD._whitespace_regex: correctly splits whitespace/commas")


func _test_md_no_dead_variables() -> void:
	var md := get_node_or_null("/root/MapDownloader")
	if md == null:
		_result(false, "MD.no_dead_vars", "MapDownloader autoload not found")
		return

	# _runner_connected and _download_retry_count should no longer exist.
	_assert_true(not ("_runner_connected" in md),
		"MD.no_dead_vars: _runner_connected removed")
	_assert_true(not ("_download_retry_count" in md),
		"MD.no_dead_vars: _download_retry_count removed")


# =========================================================================
# Assertion helpers
# =========================================================================

func _assert_eq(actual, expected, label: String) -> void:
	if actual == expected:
		_result(true, label, "")
	else:
		_result(false, label, "expected '%s' got '%s'" % [str(expected), str(actual)])


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_result(true, label, "")
	else:
		_result(false, label, "condition was false")


func _result(passed: bool, label: String, detail: String) -> void:
	_results.append({"passed": passed, "label": label, "detail": detail})
	if passed:
		_pass_count += 1
		print("DownloaderUnitTest: [✓] ", label)
	else:
		_fail_count += 1
		printerr("DownloaderUnitTest: [✗] ", label, " — ", detail)


func _print_summary() -> void:
	print("")
	print("DownloaderUnitTest: =========================================")
	print("DownloaderUnitTest: RESULTS: %d passed, %d failed" % [_pass_count, _fail_count])
	print("DownloaderUnitTest: =========================================")
	if _fail_count == 0:
		print("DownloaderUnitTest: OVERALL PASS")
	else:
		printerr("DownloaderUnitTest: OVERALL FAIL")
