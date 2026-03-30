#!/usr/bin/env bash
set -euo pipefail

# nix-patch-foreign: Patch a foreign (non-Nix) ELF binary to run on NixOS
#
# Uses nix-locate to find Nix packages that provide the needed shared
# libraries, then patchelf to rewrite the interpreter and RPATH to point
# directly into /nix/store.
#
# Requirements:
#   - nix
#   - nix-locate database (~/.cache/nix-index/files)
#     Quick setup: cp $(nix build github:nix-community/nix-index-database --print-out-paths --no-link)/files ~/.cache/nix-index/
#   - patchelf and nix-locate are auto-fetched via nix if not in PATH

usage() {
	cat >&2 <<-EOF
		Usage: $(basename "$0") <binary> [options]

		Patches a foreign ELF binary to use Nix-provided libraries.
		By default, writes a patched copy next to the original (<binary>.patched).

		Options:
		  -o, --output <path>      Write patched binary to <path>
		  --inplace                Patch the binary in-place (no copy)
		  --dry-run                Show what would be done without patching
		  --patchelf-bin <path>    Use this patchelf binary
		  --nix-locate-bin <path>  Use this nix-locate binary
		  -h, --help               Show this help
	EOF
	exit 1
}

# --- argument parsing ---

target=""
output=""
inplace=false
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
	--inplace) inplace=true ;;
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

# Determine output path
if $inplace; then
	output="$target"
elif [[ -z "$output" ]]; then
	output="${target}.patched"
fi
output=$(realpath "$output")

# --- resolve tool paths ---

# Resolve a tool: explicit flag > PATH > nix shell fallback
resolve_tool() {
	local explicit="$1" cmd="$2" nix_pkg="$3"
	if [[ -n "$explicit" ]]; then
		echo "$explicit"
	elif command -v "$cmd" >/dev/null 2>&1; then
		command -v "$cmd"
	else
		# Build a wrapper that invokes via nix shell
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

# Preferred package prefixes for nix-locate results.
# When multiple packages provide the same library, prefer these over random
# bundled packages (e.g. glibc.out over saw-tools.out for libpthread.so.0).
PREFERRED_ATTRS='^\(glibc\|libgcc\|gcc\|zlib\|openssl\|curl\|xorg\.\|libGL\|libglvnd\|glib\|gtk[34]\|cairo\|pango\|gdk-pixbuf\|dbus\|fontconfig\|freetype\|expat\|libffi\|sqlite\|ncurses\|readline\|xz\|zstd\|bzip2\|pcre2\)\.'

# Escape a library name for use in a regex pattern
regex_escape() {
	sed 's/[.+*?^${}()|\\]/\\&/g' <<<"$1"
}

# Find the nixpkgs attribute that provides a given library.
# First checks KNOWN_LIBS, then falls back to nix-locate.
# Returns empty string if not found.
find_lib_attr() {
	local libname="$1"
	local escaped
	escaped=$(regex_escape "$libname")
	local results
	results=$("$NIX_LOCATE" --minimal --at-root --regex "/lib/${escaped}$" 2>/dev/null)
	# Prefer well-known system packages over random bundled ones
	local result
	result=$(echo "$results" | grep -m1 "$PREFERRED_ATTRS" || echo "$results" | head -1)
	echo "$result"
}

# --- scan dependencies ---

log "==> Scanning $target"

needed_s=$("$PATCHELF" --print-needed "$target")
mapfile -t needed <<<"$needed_s"

# Filter out empty entries and ld-linux (it's the interpreter, not a regular dep)
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

declare -A lib_to_attr=() # libname -> nixpkgs attribute
declare -A attrs=()       # unique attributes to build

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

# Also resolve the interpreter
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
	log "The patched binary may not work if these are required at runtime."
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

# --- collect RPATH entries and find interpreter ---

# Collect unique lib dirs for RPATH
declare -A rpath_set=()
for attr in "${!attr_to_storepath[@]}"; do
	sp="${attr_to_storepath[$attr]}"
	if [[ -d "$sp/lib" ]]; then
		rpath_set["$sp/lib"]=1
	fi
done

# Find the interpreter (ld-linux).
# Strategy:
#   1. If ld-linux was in the needed list and we resolved it, use that package
#   2. If libc.so was resolved, ld-linux is in the same package (glibc)
#   3. Fall back to searching dependencies of resolved packages
new_interp=""

# Strategy 1: ld-linux was explicitly in needed
if [[ -n "$interp_attr" && -n "${attr_to_storepath[$interp_attr]:-}" ]]; then
	sp="${attr_to_storepath[$interp_attr]}"
	interp=$(find "$sp/lib" -name 'ld-linux-*.so.*' -not -type d 2>/dev/null | head -1)
	if [[ -n "$interp" ]]; then
		new_interp="$interp"
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
				rpath_set["$dep/lib"]=1
				break 2
			fi
		done
	done
fi

rpath=$(
	IFS=:
	echo "${!rpath_set[*]}"
)

# --- summary ---

log ""
log "==> Patch plan"
log "  output: $output"
if [[ -n "$new_interp" ]]; then
	log "  interpreter: $new_interp"
else
	log "  interpreter: (unchanged - could not determine)"
fi
log "  rpath: $rpath"

if $dry_run; then
	log ""
	log "(dry-run, not patching)"
	exit 0
fi

# --- apply patches ---

log ""
log "==> Patching"

if [[ "$output" != "$target" ]]; then
	cp "$target" "$output"
	log "  copied to $output"
fi

chmod +w "$output"
if [[ -n "$new_interp" ]]; then
	"$PATCHELF" --set-interpreter "$new_interp" "$output"
fi
"$PATCHELF" --set-rpath "$rpath" "$output"

log ""
log "Done: $output"
