#!/usr/bin/env bash
set -euo pipefail

# nix-portable-bundle: Bundle a foreign ELF binary with its Nix-provided
# libraries into a portable, self-contained directory.
#
# Unlike patchelf --set-rpath (which can corrupt NOTE segments and break
# Node.js SEA binaries), this script uses:
#   - patchelf --set-interpreter with a fixed-length placeholder
#   - A wrapper script that patches the interpreter at runtime via dd
#   - LD_LIBRARY_PATH + LD_PRELOAD cleanup trick for library resolution
#
# The cleanup_env.so (loaded via LD_PRELOAD):
#   - Constructor: saves LD_LIBRARY_PATH/LD_PRELOAD, removes from environ
#   - Intercepts exec*(): restores LD vars for self re-exec (Node.js SEA),
#     strips them for child processes (prevents glibc version mismatch)
#
# This preserves /proc/self/exe, avoids NOTE segment corruption, and
# keeps child process environments clean.
#
# Requirements:
#   - nix
#   - nix-locate database (~/.cache/nix-index/files)
#   - patchelf, nix-locate, and gcc are auto-fetched via nix if not in PATH

INTERP_PLACEHOLDER_LEN=256
INTERP_PLACEHOLDER_TAG="NIXBUNDLEELF_INTERP_PLACEHOLDER"

usage() {
	cat >&2 <<-EOF
		Usage: $(basename "$0") <binary> [options]

		Bundles a foreign ELF binary into a portable directory with all
		needed libraries from nixpkgs.

		Output: <name>.bundle/
		  bin/<name>    wrapper script (use this to run)
		  orig/<name>   binary with placeholder interpreter
		  lib/          shared libraries (glibc, libstdc++, etc.)

		Options:
		  -o, --output <dir>       Output directory (default: <binary>.bundle)
		  -n, --name <name>        Binary name in bundle (default: basename of input)
		  --dry-run                Show what would be done without bundling
		  --patchelf-bin <path>    Use this patchelf binary
		  --nix-locate-bin <path>  Use this nix-locate binary
		  -h, --help               Show this help
	EOF
	exit 1
}

# --- argument parsing ---

target=""
output=""
name=""
dry_run=false
patchelf_bin=""
nix_locate_bin=""

while (($# > 0)); do
	case "$1" in
	-h | --help) usage ;;
	-o | --output)
		output="${2:?--output requires an argument}"
		shift
		;;
	-n | --name)
		name="${2:?--name requires an argument}"
		shift
		;;
	--dry-run) dry_run=true ;;
	--patchelf-bin)
		patchelf_bin="${2:?--patchelf-bin requires an argument}"
		shift
		;;
	--nix-locate-bin)
		nix_locate_bin="${2:?--nix-locate-bin requires an argument}"
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

if [[ -z "$name" ]]; then
	name=$(basename "$target")
fi

if [[ -z "$output" ]]; then
	output="$(dirname "$target")/${name}.bundle"
fi

if [[ -e "$output" ]]; then
	echo "Error: $output already exists" >&2
	exit 1
fi

# --- resolve tool paths ---

resolve_tool() {
	local explicit="$1" cmd="$2" nix_pkg="$3"
	if [[ -n "$explicit" ]]; then
		echo "$explicit"
	elif command -v "$cmd" >/dev/null 2>&1; then
		command -v "$cmd"
	else
		local wrapper
		wrapper=$(mktemp)
		cat >"$wrapper" <<-EOF
			#!/usr/bin/env bash
			exec nix shell nixpkgs#${nix_pkg} -c ${cmd} "\$@"
		EOF
		chmod +x "$wrapper"
		echo "$wrapper"
	fi
}

PATCHELF=$(resolve_tool "$patchelf_bin" patchelf patchelf)
NIX_LOCATE=$(resolve_tool "$nix_locate_bin" nix-locate nix-index)

# --- helpers ---

log() { echo "$*" >&2; }

PREFERRED_ATTRS='^\(glibc\|libgcc\|gcc\|zlib\|openssl\|curl\|xorg\.\|libGL\|libglvnd\|glib\|gtk[34]\|cairo\|pango\|gdk-pixbuf\|dbus\|fontconfig\|freetype\|expat\|libffi\|sqlite\|ncurses\|readline\|xz\|zstd\|bzip2\|pcre2\)\.'

regex_escape() {
	sed 's/[.+*?^${}()|\\]/\\&/g' <<<"$1"
}

find_lib_attr() {
	local libname="$1"
	local escaped
	escaped=$(regex_escape "$libname")
	local results
	results=$("$NIX_LOCATE" --minimal --at-root --regex "/lib/${escaped}$" 2>/dev/null)
	local result
	result=$(echo "$results" | grep -m1 "$PREFERRED_ATTRS" || echo "$results" | head -1)
	echo "$result"
}

# --- scan dependencies ---

log "==> Scanning $target"

needed_s=$("$PATCHELF" --print-needed "$target")
mapfile -t needed <<<"$needed_s"

real_needed=()
interp_needed=""
for lib in "${needed[@]}"; do
	[[ -z "$lib" ]] && continue
	if [[ "$lib" =~ ^ld-linux ]]; then
		interp_needed="$lib"
		continue
	fi
	real_needed+=("$lib")
done

if [[ ${#real_needed[@]} -eq 0 && -z "$interp_needed" ]]; then
	log "No dynamic dependencies found. Is this a static binary?"
	exit 0
fi

log "Needed libraries:"
for lib in "${real_needed[@]}"; do
	log "  $lib"
done
if [[ -n "$interp_needed" ]]; then
	log "  $interp_needed (interpreter)"
fi

# --- resolve libraries via nix-locate ---

log ""
log "==> Resolving libraries with nix-locate"

declare -A lib_to_attr=()
declare -A attrs=()

not_found=()
for lib in "${real_needed[@]}"; do
	attr=$(find_lib_attr "$lib")
	if [[ -z "$attr" ]]; then
		not_found+=("$lib")
		log "  $lib -> NOT FOUND"
		continue
	fi
	log "  $lib -> $attr"
	lib_to_attr["$lib"]="$attr"
	attrs["$attr"]=1
done

interp_attr=""
if [[ -n "$interp_needed" ]]; then
	interp_attr=$(find_lib_attr "$interp_needed")
	if [[ -n "$interp_attr" ]]; then
		log "  $interp_needed -> $interp_attr (interpreter)"
		attrs["$interp_attr"]=1
	else
		log "  $interp_needed -> NOT FOUND (interpreter)"
		not_found+=("$interp_needed")
	fi
fi

if [[ ${#not_found[@]} -gt 0 ]]; then
	log ""
	log "Warning: could not find packages for: ${not_found[*]}"
fi

# --- build packages ---

log ""
log "==> Building packages"

declare -A attr_to_storepath=()
for attr in "${!attrs[@]}"; do
	log "  nix build nixpkgs#$attr"
	store_path=$(nix build --no-link --print-out-paths "nixpkgs#$attr")
	attr_to_storepath["$attr"]="$store_path"
done

# --- find interpreter ---

new_interp=""
interp_basename=""

# Strategy 1: ld-linux was explicitly in needed
if [[ -n "$interp_attr" && -n "${attr_to_storepath[$interp_attr]:-}" ]]; then
	sp="${attr_to_storepath[$interp_attr]}"
	interp=$(find "$sp/lib" -name 'ld-linux-*.so.*' -not -type d 2>/dev/null | head -1)
	if [[ -n "$interp" ]]; then
		new_interp="$interp"
		interp_basename=$(basename "$interp")
	fi
fi

# Strategy 2: libc.so resolved to glibc
if [[ -z "$new_interp" ]]; then
	for lib in "${real_needed[@]}"; do
		if [[ "$lib" =~ ^libc\.so\. ]]; then
			attr="${lib_to_attr[$lib]:-}"
			if [[ -n "$attr" && -n "${attr_to_storepath[$attr]:-}" ]]; then
				sp="${attr_to_storepath[$attr]}"
				interp=$(find "$sp/lib" -name 'ld-linux-*.so.*' -not -type d 2>/dev/null | head -1)
				if [[ -n "$interp" ]]; then
					new_interp="$interp"
					interp_basename=$(basename "$interp")
				fi
			fi
			break
		fi
	done
fi

# Strategy 3: search dependencies
if [[ -z "$new_interp" ]]; then
	log "Warning: could not find interpreter directly; searching package dependencies..."
	for attr in "${!attr_to_storepath[@]}"; do
		sp="${attr_to_storepath[$attr]}"
		for dep in $(nix-store -q --references "$sp" 2>/dev/null); do
			interp=$(find "$dep/lib" -name 'ld-linux-*.so.*' -not -type d 2>/dev/null | head -1)
			if [[ -n "$interp" ]]; then
				new_interp="$interp"
				interp_basename=$(basename "$interp")
				# Also remember this store path for lib copying
				attr_to_storepath["_glibc_dep"]="$dep"
				break 2
			fi
		done
	done
fi

if [[ -z "$new_interp" ]]; then
	echo "Error: could not find interpreter (ld-linux)" >&2
	exit 1
fi

# --- summary ---

log ""
log "==> Bundle plan"
log "  output: $output"
log "  interpreter: $new_interp"
log "  packages:"
for attr in "${!attr_to_storepath[@]}"; do
	[[ "$attr" == _* ]] && continue
	log "    $attr -> ${attr_to_storepath[$attr]}"
done

if $dry_run; then
	log ""
	log "(dry-run, not bundling)"
	exit 0
fi

# --- create bundle ---

log ""
log "==> Bundling"

mkdir -p "$output"/{bin,orig,lib}

# Copy libraries
for attr in "${!attr_to_storepath[@]}"; do
	sp="${attr_to_storepath[$attr]}"
	if [[ -d "$sp/lib" ]]; then
		cp -aL "$sp"/lib/*.so* "$output/lib/" 2>/dev/null || true
	fi
done

# Patch RUNPATH of bundled libraries so they find siblings in lib/
# instead of pointing to /nix/store paths that won't exist on the target system
log "  Patching library RUNPATH"
for so in "$output"/lib/*.so*; do
	[[ -f "$so" ]] || continue
	[[ -L "$so" ]] && continue
	# Skip the dynamic linker — it's loaded directly by the kernel
	# and patchelf corrupts it
	case "$(basename "$so")" in ld-linux*) continue ;; esac
	orig_mode=$(stat -c '%a' "$so")
	chmod u+w "$so"
	"$PATCHELF" --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
	chmod "$orig_mode" "$so"
done

# Compile the cleanup_env.so for LD_PRELOAD (intercepts exec* to
# restore LD_LIBRARY_PATH on self re-exec, strip it for child processes)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cleanup_env_src="$SCRIPT_DIR/cleanup_env.c"
if [[ ! -f "$cleanup_env_src" ]]; then
	echo "Error: cleanup_env.c not found at $cleanup_env_src" >&2
	rm -rf "$output"
	exit 1
fi

GCC=$(resolve_tool "" gcc gcc)
log "  Compiling cleanup_env.so"
"$GCC" -shared -fPIC -O2 -o "$output/lib/cleanup_env.so" "$cleanup_env_src" -ldl

# Copy binary and set placeholder interpreter
cp "$target" "$output/orig/$name"
chmod +w "$output/orig/$name"

placeholder="/${INTERP_PLACEHOLDER_TAG}"
while [[ ${#placeholder} -lt $INTERP_PLACEHOLDER_LEN ]]; do placeholder="${placeholder}/"; done
placeholder="${placeholder:0:$INTERP_PLACEHOLDER_LEN}"

"$PATCHELF" --set-interpreter "$placeholder" "$output/orig/$name"

# Record byte offset of the placeholder
match_count=$(grep -c "$INTERP_PLACEHOLDER_TAG" "$output/orig/$name" || true)
if [[ "$match_count" -ne 1 ]]; then
	echo "Error: interpreter placeholder found $match_count times (expected 1)" >&2
	rm -rf "$output"
	exit 1
fi
interp_offset=$(grep -boa "$INTERP_PLACEHOLDER_TAG" "$output/orig/$name" | head -1 | cut -d: -f1)
interp_offset=$((interp_offset - 1)) # account for leading "/"

chmod -w "$output/orig/$name"

# Create wrapper script
cat >"$output/bin/$name" <<WRAPPER
#!/bin/sh
dir="\$(cd "\$(dirname "\$0")/.." && pwd)"
real_interp="\$dir/lib/${interp_basename}"

if [ \${#real_interp} -ge ${INTERP_PLACEHOLDER_LEN} ]; then
  echo "Error: interpreter path too long (\${#real_interp} >= ${INTERP_PLACEHOLDER_LEN})" >&2
  exit 1
fi

tmp="\$(mktemp -d "\${TMPDIR:-/tmp}/${name}.XXXXXX")"
trap 'rm -rf "\$tmp"' EXIT
cp "\$dir/orig/${name}" "\$tmp/${name}"
chmod +w "\$tmp/${name}"
{
  printf '%s' "\$real_interp"
  dd if=/dev/zero bs=1 count=\$((${INTERP_PLACEHOLDER_LEN} - \${#real_interp})) 2>/dev/null
} | dd of="\$tmp/${name}" bs=1 seek=${interp_offset} count=${INTERP_PLACEHOLDER_LEN} conv=notrunc 2>/dev/null
chmod -w "\$tmp/${name}"

LD_LIBRARY_PATH="\$dir/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \
LD_PRELOAD="\$dir/lib/cleanup_env.so\${LD_PRELOAD:+:\$LD_PRELOAD}" \
"\$tmp/${name}" "\$@"
exit \$?
WRAPPER
chmod +x "$output/bin/$name"

log ""
log "Done: $output"
log "Run with: $output/bin/$name"
