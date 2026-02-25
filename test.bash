#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${SCRIPT_DIR}/bundle.bash"

TESTDIR=""
passed=0
failed=0
errors=()

setup() {
	TESTDIR=$(mktemp -d)
	# Create a shared library
	cat >"$TESTDIR/mylib.c" <<-'EOF'
		#include <stdio.h>
		void mylib_hello() { printf("hello from mylib\n"); }
	EOF
	gcc -shared -fPIC -o "$TESTDIR/libmylib.so" "$TESTDIR/mylib.c"

	# Create a binary linked against the shared library (also prints args)
	cat >"$TESTDIR/main.c" <<-'EOF'
		#include <stdio.h>
		extern void mylib_hello();
		int main(int argc, char *argv[]) {
		    mylib_hello();
		    for (int i = 1; i < argc; i++) printf("argv[%d]=%s\n", i, argv[i]);
		    return 0;
		}
	EOF
	gcc -o "$TESTDIR/test_bin" "$TESTDIR/main.c" \
		-L"$TESTDIR" -lmylib -Wl,-rpath,"$TESTDIR"
}

cleanup() {
	if [[ -n "$TESTDIR" && -d "$TESTDIR" ]]; then
		rm -rf "$TESTDIR"
	fi
}

run_test() {
	local name=$1
	shift
	if "$@"; then
		passed=$((passed + 1))
		echo "  PASS: $name"
	else
		failed=$((failed + 1))
		errors+=("$name")
		echo "  FAIL: $name"
	fi
}

# ---------- parse_args tests ----------

test_parse_args_missing_target() {
	local out
	out=$(bash "$BUNDLE" --format exe 2>&1) && return 1
	[[ "$out" == *"target is not specified"* ]]
}

test_parse_args_missing_format() {
	local out
	out=$(bash "$BUNDLE" "$TESTDIR/test_bin" 2>&1) && return 1
	[[ "$out" == *"format is not specified"* ]]
}

test_parse_args_invalid_format() {
	local out
	out=$(bash "$BUNDLE" --format invalid "$TESTDIR/test_bin" 2>&1) && return 1
	[[ "$out" == *"invalid format"* ]]
}

test_parse_args_too_many_arguments() {
	local out
	out=$(bash "$BUNDLE" --format exe "$TESTDIR/test_bin" name1 extra 2>&1) && return 1
	[[ "$out" == *"too many arguments"* ]]
}

test_parse_args_target_not_exist() {
	# The script fails for non-existent targets (realpath error or explicit check)
	! bash "$BUNDLE" --format exe /nonexistent/path >/dev/null 2>&1
}

test_parse_args_help() {
	local out
	out=$(bash "$BUNDLE" --help 2>&1)
	[[ "$out" == *"Usage:"* ]]
}

# ---------- bundle_exe tests ----------

test_bundle_exe_creates_file() {
	local workdir
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary) >/dev/null
	[[ -f "$workdir/mybinary" ]]
	rm -rf "$workdir"
}

test_bundle_exe_is_executable() {
	local workdir
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary) >/dev/null
	[[ -x "$workdir/mybinary" ]]
	rm -rf "$workdir"
}

test_bundle_exe_runs_correctly() {
	local workdir out
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary) >/dev/null
	out=$("$workdir/mybinary")
	rm -rf "$workdir"
	[[ "$out" == "hello from mylib" ]]
}

test_bundle_exe_default_name() {
	local workdir
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin") >/dev/null
	# default name should be the basename of the target
	[[ -f "$workdir/test_bin" ]]
	rm -rf "$workdir"
}

test_bundle_exe_passes_arguments() {
	local workdir out
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybin) >/dev/null
	out=$("$workdir/mybin" -- foo bar)
	rm -rf "$workdir"
	[[ "$out" == *"hello from mylib"* ]] && [[ "$out" == *"argv[1]=foo"* ]] && [[ "$out" == *"argv[2]=bar"* ]]
}

test_bundle_exe_extract_mode() {
	local workdir extractdir out
	workdir=$(mktemp -d)
	extractdir=$(mktemp -d)
	rm -rf "$extractdir/extracted"
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary) >/dev/null
	out=$("$workdir/mybinary" --extract "$extractdir/extracted")
	[[ "$out" == *"successfully extracted"* ]]
	[[ -d "$extractdir/extracted/lib" ]]
	[[ -d "$extractdir/extracted/orig" ]]
	[[ -f "$extractdir/extracted/bin/mybinary" ]]
	# extracted binary should also run correctly
	out=$("$extractdir/extracted/bin/mybinary")
	rm -rf "$workdir" "$extractdir"
	[[ "$out" == "hello from mylib" ]]
}

test_bundle_exe_extract_refuses_existing_path() {
	local workdir out
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary) >/dev/null
	mkdir -p "$workdir/existing"
	out=$("$workdir/mybinary" --extract "$workdir/existing" 2>&1) && {
		rm -rf "$workdir"
		return 1
	}
	rm -rf "$workdir"
	[[ "$out" == *"already exists"* ]]
}

test_bundle_exe_refuses_overwrite() {
	local workdir out
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary) >/dev/null
	# try to bundle again to same location
	out=$(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary 2>&1) && {
		rm -rf "$workdir"
		return 1
	}
	rm -rf "$workdir"
	[[ "$out" == *"already exists"* ]]
}

# ---------- bundle_lambda tests ----------

test_bundle_lambda_creates_zip() {
	local workdir
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format lambda "$TESTDIR/test_bin") >/dev/null
	[[ -f "$workdir/function.zip" ]]
	rm -rf "$workdir"
}

test_bundle_lambda_zip_contains_bootstrap() {
	local workdir contents
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format lambda "$TESTDIR/test_bin") >/dev/null
	contents=$(unzip -l "$workdir/function.zip")
	rm -rf "$workdir"
	[[ "$contents" == *"bootstrap"* ]]
}

test_bundle_lambda_zip_contains_libs() {
	local workdir contents
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format lambda "$TESTDIR/test_bin") >/dev/null
	contents=$(unzip -l "$workdir/function.zip")
	rm -rf "$workdir"
	[[ "$contents" == *"lib/"* ]] && [[ "$contents" == *"libmylib.so"* ]]
}

test_bundle_lambda_bootstrap_has_correct_interpreter() {
	local workdir interp
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format lambda "$TESTDIR/test_bin") >/dev/null
	(cd "$workdir" && unzip -qo function.zip)
	interp=$(patchelf --print-interpreter "$workdir/bootstrap")
	rm -rf "$workdir"
	[[ "$interp" == "./lib/"* ]]
}

test_bundle_lambda_bootstrap_has_correct_rpath() {
	local workdir rpath
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format lambda "$TESTDIR/test_bin") >/dev/null
	(cd "$workdir" && unzip -qo function.zip)
	rpath=$(patchelf --print-rpath "$workdir/bootstrap")
	rm -rf "$workdir"
	[[ "$rpath" == "./lib" ]]
}

test_bundle_lambda_refuses_overwrite() {
	local workdir out
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format lambda "$TESTDIR/test_bin") >/dev/null
	out=$(cd "$workdir" && bash "$BUNDLE" --format lambda "$TESTDIR/test_bin" 2>&1) && {
		rm -rf "$workdir"
		return 1
	}
	rm -rf "$workdir"
	[[ "$out" == *"already exists"* ]]
}

# ---------- gather_deps tests ----------

test_gather_deps_finds_custom_library() {
	local workdir out
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary) >/dev/null
	# The bundled file should contain libmylib.so in its tarball
	"$workdir/mybinary" --extract "$workdir/extracted"
	[[ -f "$workdir/extracted/lib/libmylib.so" ]]
	rm -rf "$workdir"
}

test_gather_deps_includes_interpreter() {
	local workdir interp_name
	workdir=$(mktemp -d)
	(cd "$workdir" && bash "$BUNDLE" --format exe "$TESTDIR/test_bin" mybinary) >/dev/null
	"$workdir/mybinary" --extract "$workdir/extracted"
	interp_name=$(basename "$(patchelf --print-interpreter "$TESTDIR/test_bin")")
	[[ -f "$workdir/extracted/lib/$interp_name" ]]
	rm -rf "$workdir"
}

# ---------- main ----------

main() {
	echo "Setting up test fixtures..."
	setup
	trap cleanup EXIT

	echo "Running tests..."
	echo ""

	echo "[parse_args]"
	run_test "missing target" test_parse_args_missing_target
	run_test "missing format" test_parse_args_missing_format
	run_test "invalid format" test_parse_args_invalid_format
	run_test "too many arguments" test_parse_args_too_many_arguments
	run_test "target does not exist" test_parse_args_target_not_exist
	run_test "help" test_parse_args_help

	echo ""
	echo "[bundle_exe]"
	run_test "creates file" test_bundle_exe_creates_file
	run_test "is executable" test_bundle_exe_is_executable
	run_test "runs correctly" test_bundle_exe_runs_correctly
	run_test "default name" test_bundle_exe_default_name
	run_test "passes arguments" test_bundle_exe_passes_arguments
	run_test "extract mode" test_bundle_exe_extract_mode
	run_test "extract refuses existing path" test_bundle_exe_extract_refuses_existing_path
	run_test "refuses overwrite" test_bundle_exe_refuses_overwrite

	echo ""
	echo "[bundle_lambda]"
	run_test "creates zip" test_bundle_lambda_creates_zip
	run_test "zip contains bootstrap" test_bundle_lambda_zip_contains_bootstrap
	run_test "zip contains libs" test_bundle_lambda_zip_contains_libs
	run_test "bootstrap has correct interpreter" test_bundle_lambda_bootstrap_has_correct_interpreter
	run_test "bootstrap has correct rpath" test_bundle_lambda_bootstrap_has_correct_rpath
	run_test "refuses overwrite" test_bundle_lambda_refuses_overwrite

	echo ""
	echo "[gather_deps]"
	run_test "finds custom library" test_gather_deps_finds_custom_library
	run_test "includes interpreter" test_gather_deps_includes_interpreter

	echo ""
	echo "========================================="
	echo "Results: $passed passed, $failed failed"
	if ((failed > 0)); then
		echo "Failed tests:"
		for e in "${errors[@]}"; do
			echo "  - $e"
		done
		exit 1
	fi
	echo "========================================="
}

main
