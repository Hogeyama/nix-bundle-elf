#!/usr/bin/env bash
set -euo pipefail

# bundle-preload: Bundle an ELF binary with its shared libraries into a
# portable, self-extracting executable using LD_PRELOAD.
#
# Unlike patchelf --set-rpath (which can corrupt NOTE segments and break
# Node.js SEA binaries), this script uses:
#   - patchelf --set-interpreter with a fixed-length placeholder
#   - LD_LIBRARY_PATH + LD_PRELOAD for library resolution
#
# The cleanup_env.so (loaded via LD_PRELOAD):
#   - Constructor: saves LD_LIBRARY_PATH/LD_PRELOAD, removes from environ
#   - Intercepts exec*(): restores LD vars for self re-exec (Node.js SEA),
#     strips them for child processes (prevents glibc version mismatch)
#
# This preserves /proc/self/exe, avoids NOTE segment corruption, and
# keeps child process environments clean.
#
# Supports both Nix-built binaries (deps gathered via RPATH traversal)
# and foreign binaries (deps resolved via nix-locate).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib/resolve-tool.bash"
source "$SCRIPT_DIR/lib/gather-nix-deps.bash"

PATCHELF=$(resolve_tool "" patchelf patchelf)
GCC=$(resolve_tool "" gcc gcc)

INTERP_PLACEHOLDER_LEN=256
INTERP_PLACEHOLDER_TAG="NIXBUNDLEELF_INTERP_PLACEHOLDER"

log() { echo "$*" >&2; }

usage() {
	cat >&2 <<-EOF
		Usage: $(basename "$0") <binary> [options]

		Bundles an ELF binary into a self-extracting executable with all
		needed libraries, using LD_PRELOAD for library resolution.

		The generated executable supports:
		  <result> [--] ARGS       Extract to temp dir and run with ARGS
		  <result> --extract DIR   Extract permanently to DIR

		Options:
		  -o, --output <path>      Output file (default: ./<basename of input>)
		  --no-nix-locate          Disable nix-locate (error if binary is foreign)
		  --include <src>:<dest>   Include a file in the bundle (repeatable)
		  --add-flag <arg>         Add a runtime argument before user args
		  -h, --help               Show this help
	EOF
	exit 1
}

# --- argument parsing ---

target=""
output=""
use_nix_locate=true
add_flags=()
includes=()

while (($# > 0)); do
	case "$1" in
	-h | --help) usage ;;
	-o | --output)
		output="${2:?--output requires an argument}"
		shift
		;;
	--no-nix-locate) use_nix_locate=false ;;
	--add-flag)
		add_flags+=("${2:?--add-flag requires an argument}")
		shift
		;;
	--include)
		includes+=("${2:?--include requires an argument}")
		shift
		;;
	-*)
		echo "Error: unknown option: $1" >&2
		exit 1
		;;
	*)
		if [[ -z "$target" ]]; then
			target="$1"
		else
			echo "Error: unexpected argument: $1" >&2
			exit 1
		fi
		;;
	esac
	shift
done

if [[ -z "$target" ]]; then
	usage
fi

target=$(realpath "$target")

if [[ ! -f "$target" ]]; then
	echo "Error: $target is not a file" >&2
	exit 1
fi

if [[ -z "$output" ]]; then
	output="$(pwd)/$(basename "$target")"
fi

name=$(basename "$output")

if [[ -e "$output" ]]; then
	echo "Error: $output already exists" >&2
	exit 1
fi

# --- detect dependency resolution strategy ---

interpreter=$("$PATCHELF" --print-interpreter "$target")
interpreterb=$(basename "$interpreter")

# --- gather dependencies ---

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/out"/{orig,lib}

log "==> Gathering dependencies via RPATH"
libs=()
if libs_s=$(gather_deps "$target" "$interpreterb"); then
	mapfile -t libs <<<"$libs_s"

	# Copy interpreter
	cp "$interpreter" "$tmpdir/out/lib/"

	# Copy libraries
	for libfile in "${libs[@]}"; do
		[[ -z "$libfile" ]] && continue
		cp "$libfile" "$tmpdir/out/lib/"
	done

	interp_basename="$interpreterb"
else
	log "  RPATH-only resolution was insufficient"
	if ! $use_nix_locate; then
		echo "Error: dependency resolution via RPATH/RUNPATH was insufficient." >&2
		echo "  Use nix-locate to resolve dependencies (remove --no-nix-locate)." >&2
		exit 1
	fi

	# Resolve via nix-locate when RPATH is insufficient
	source "$SCRIPT_DIR/lib/resolve-foreign-deps.bash"

	# PATCHELF already set at top level
	NIX_LOCATE=$(resolve_tool "" nix-locate nix-index)

	log "==> Resolving unresolved dependencies with nix-locate"
	log "==> Scanning $target"
	scan_needed "$target"

	if [[ ${#real_needed[@]} -eq 0 && -z "$interp_needed" ]]; then
		echo "Error: no dynamic dependencies found. Is this a static binary?" >&2
		exit 1
	fi

	log "==> Resolving libraries with nix-locate"
	resolve_libs

	if [[ ${#not_found[@]} -gt 0 ]]; then
		echo "Error: could not find packages for: ${not_found[*]}" >&2
		exit 1
	fi

	log "==> Building packages"
	build_packages

	find_interpreter

	if [[ -n "$interp_extra_storepath" ]]; then
		attr_to_storepath["_glibc_dep"]="$interp_extra_storepath"
	fi

	if [[ -z "$new_interp" ]]; then
		echo "Error: could not find interpreter (ld-linux)" >&2
		exit 1
	fi

	interp_basename="$interp_basename" # set by find_interpreter

	# Copy libraries from resolved store paths
	for attr in "${!attr_to_storepath[@]}"; do
		sp="${attr_to_storepath[$attr]}"
		if [[ -d "$sp/lib" ]]; then
			cp -aL "$sp"/lib/*.so* "$tmpdir/out/lib/" 2>/dev/null || true
		fi
	done
fi

# --- serialize_add_flags ---

quote_sh_literal() {
	local value="$1"
	printf "'%s'" "${value//\'/\'\\\'\'}"
}

# Produce a POSIX-sh-safe inline word list from add_flags[].
# %ROOT is replaced by the shell expression given as $1 (e.g. '$TEMP').
# Output example: '--verbose' '--config='"$TEMP"'/app.cfg'
serialize_add_flag_words_sh() {
	local root_expr="$1"
	local flag expanded prefix suffix expr out=""
	for flag in "${add_flags[@]}"; do
		expanded="${flag//%%/$'\x01'}"
		expr=""
		while [[ "$expanded" == *%ROOT* ]]; do
			prefix="${expanded%%\%ROOT*}"
			prefix="${prefix//$'\x01'/%}"
			if [[ -n "$prefix" ]]; then
				expr+="$(quote_sh_literal "$prefix")"
			fi
			expr+="\"${root_expr}\""
			expanded="${expanded#*%ROOT}"
		done
		suffix="${expanded//$'\x01'/%}"
		if [[ -n "$suffix" ]]; then
			expr+="$(quote_sh_literal "$suffix")"
		fi
		if [[ -z "$expr" ]]; then
			expr="''"
		fi
		if [[ -n "$out" ]]; then
			out+=" "
		fi
		out+="$expr"
	done
	printf '%s' "$out"
}

# --- create bundle ---

log "==> Bundling"

# Patch RUNPATH of bundled libraries so they find siblings in lib/
log "  Patching library RUNPATH"
for so in "$tmpdir/out"/lib/*.so*; do
	[[ -f "$so" ]] || continue
	[[ -L "$so" ]] && continue
	# Skip the dynamic linker — patchelf corrupts it
	case "$(basename "$so")" in ld-linux*) continue ;; esac
	chmod u+w "$so"
	"$PATCHELF" --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
	chmod u-w "$so"
done

# Compile cleanup_env.so for LD_PRELOAD
cleanup_env_src="$SCRIPT_DIR/cleanup_env.c"
if [[ ! -f "$cleanup_env_src" ]]; then
	echo "Error: cleanup_env.c not found at $cleanup_env_src" >&2
	exit 1
fi

log "  Compiling cleanup_env.so"
"$GCC" -shared -fPIC -O2 -o "$tmpdir/out/lib/cleanup_env.so" "$cleanup_env_src" -ldl

# Copy binary and set placeholder interpreter
cp "$target" "$tmpdir/out/orig/$name"
chmod +w "$tmpdir/out/orig/$name"

placeholder="/${INTERP_PLACEHOLDER_TAG}"
while [[ ${#placeholder} -lt $INTERP_PLACEHOLDER_LEN ]]; do placeholder="${placeholder}/"; done
placeholder="${placeholder:0:$INTERP_PLACEHOLDER_LEN}"

"$PATCHELF" --set-interpreter "$placeholder" "$tmpdir/out/orig/$name"

# Record byte offset of the placeholder
match_count=$(grep -c "$INTERP_PLACEHOLDER_TAG" "$tmpdir/out/orig/$name" || true)
if [[ "$match_count" -ne 1 ]]; then
	echo "Error: interpreter placeholder found $match_count times (expected 1)" >&2
	exit 1
fi
interp_offset=$(grep -boa "$INTERP_PLACEHOLDER_TAG" "$tmpdir/out/orig/$name" | head -1 | cut -d: -f1)
interp_offset=$((interp_offset - 1)) # account for leading "/"

chmod -w "$tmpdir/out/orig/$name"

# Copy --include files into bundle
for inc in "${includes[@]}"; do
	src="${inc%%:*}" dest="${inc#*:}"
	mkdir -p "$tmpdir/out/$(dirname "$dest")"
	cp "$src" "$tmpdir/out/$dest"
done

# Serialize add_flags for embedding in heredoc
add_flags_words_exec=$(serialize_add_flag_words_sh '\$TEMP')
add_flags_words_extract=$(serialize_add_flag_words_sh '$TARGET')

# Archive
tar -C "$tmpdir/out" -czf "$tmpdir/bundle.tar.gz" .

# Create self-extracting script
cat - "$tmpdir/bundle.tar.gz" >"$output" <<-EOF
	#!/bin/sh
	set -u
	TEMP="\$(mktemp -d "\${TMPDIR:-/tmp}"/${name}.XXXXXX)"
	N=\$(grep -an "^#START_OF_TAR#" "\$0" | cut -d: -f1)
	tail -n +"\$((N + 1))" <"\$0" > "\$TEMP/self.tar.gz" || exit 1
	patch_interp() {
		local binary="\$1" real_interp="\$2"
		if [ \${#real_interp} -ge ${INTERP_PLACEHOLDER_LEN} ]; then
			echo "Error: interpreter path too long (\${#real_interp} >= ${INTERP_PLACEHOLDER_LEN})" >&2
			return 1
		fi
		chmod +w "\$binary"
		{
			printf '%s' "\$real_interp"
			dd if=/dev/zero bs=1 count=\$((${INTERP_PLACEHOLDER_LEN} - \${#real_interp})) 2>/dev/null
		} | dd of="\$binary" bs=1 seek=${interp_offset} count=${INTERP_PLACEHOLDER_LEN} conv=notrunc 2>/dev/null
		chmod -w "\$binary"
	}
	# copy_and_run: copy binary to temp, dd-patch interpreter, run with LD_PRELOAD.
	# We must NOT dd-patch orig/ in-place — that corrupts Node.js SEA binaries.
	# Instead, copy to temp and patch the copy each time.
	copy_and_run() {
		local dir="\$1"; shift
		local real_interp="\$dir/lib/${interp_basename}"
		local tmp="\$(mktemp -d "\${TMPDIR:-/tmp}"/${name}.XXXXXX)"
		trap 'rm -rf "\$tmp" "\$TEMP"' EXIT
		cp "\$dir/orig/${name}" "\$tmp/${name}"
		patch_interp "\$tmp/${name}" "\$real_interp"
		LD_LIBRARY_PATH="\$dir/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" LD_PRELOAD="\$dir/lib/cleanup_env.so\${LD_PRELOAD:+:\$LD_PRELOAD}" "\$tmp/${name}" ${add_flags_words_exec} "\$@"
		exit \$?
	}
	if [ "\${1:-}" = "--extract" ]; then
		if [ -z "\${2:-}" ]; then
			echo "Usage: \$0 --extract <path>"
			exit 1
		fi
		if [ -e "\$2" ]; then
			echo "Error: \$2 already exists"
			exit 1
		fi
		TARGET=\$(realpath "\$2")
		mkdir -p "\$TARGET"
		tar -C "\$TARGET" -xzf "\$TEMP/self.tar.gz" || exit 1
		mkdir -p "\$TARGET/bin"
		cat - >"\$TARGET/bin/${name}" <<-EOF2
			#!/bin/sh
			real_interp="\$TARGET/lib/${interp_basename}"
			tmp="\\\$(mktemp -d "\\\${TMPDIR:-/tmp}/${name}.XXXXXX")"
			trap 'rm -rf "\\\$tmp"' EXIT
			cp "\$TARGET/orig/${name}" "\\\$tmp/${name}"
			chmod +w "\\\$tmp/${name}"
			{
				printf '%s' "\\\$real_interp"
				dd if=/dev/zero bs=1 count=\\\$((${INTERP_PLACEHOLDER_LEN} - \\\${#real_interp})) 2>/dev/null
			} | dd of="\\\$tmp/${name}" bs=1 seek=${interp_offset} count=${INTERP_PLACEHOLDER_LEN} conv=notrunc 2>/dev/null
			chmod -w "\\\$tmp/${name}"
			LD_LIBRARY_PATH="\$TARGET/lib\\\${LD_LIBRARY_PATH:+:\\\$LD_LIBRARY_PATH}" LD_PRELOAD="\$TARGET/lib/cleanup_env.so\\\${LD_PRELOAD:+:\\\$LD_PRELOAD}" "\\\$tmp/${name}" ${add_flags_words_extract} "\\\$@"
			exit \\\$?
		EOF2
		chmod +x "\$TARGET/bin/${name}"
		rm -rf "\$TEMP"
		echo "successfully extracted to \$2"
		exit 0
	else
		if [ "\${1:-}" = "--" ]; then
			shift
		fi
		tar -C "\$TEMP" -xzf "\$TEMP/self.tar.gz" || exit 1
		copy_and_run "\$TEMP" "\$@"
	fi
	#START_OF_TAR#
EOF
chmod +x "$output"

log ""
log "Done: $output"
