#!/usr/bin/env bash
# lib/resolve-foreign-deps.bash — shared functions for resolving
# foreign (non-Nix) ELF binary dependencies via nix-locate.
#
# Source this file; do not execute directly.
#
# Before calling these functions, set:
#   PATCHELF  — path to patchelf binary
#   NIX_LOCATE — path to nix-locate binary
# (use resolve_tool from lib/resolve-tool.bash to obtain these)

RESOLVE_FOREIGN_DEPS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$RESOLVE_FOREIGN_DEPS_DIR/resolve-tool.bash"

# --- logging ---

log() { echo "$*" >&2; }

# --- nix-locate helpers ---

# Preferred package prefixes for nix-locate results.
# When multiple packages provide the same library, prefer these well-known
# system packages over random bundled ones.
PREFERRED_ATTRS='^\(glibc\|libgcc\|gcc\|zlib\|openssl\|curl\|xorg\.\|libGL\|libglvnd\|glib\|gtk[34]\|cairo\|pango\|gdk-pixbuf\|dbus\|fontconfig\|freetype\|expat\|libffi\|sqlite\|ncurses\|readline\|xz\|zstd\|bzip2\|pcre2\)\.'

regex_escape() {
	sed 's/[.+*?^${}()|\\]/\\&/g' <<<"$1"
}

# Find the nixpkgs attribute that provides a given library.
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

# --- dependency scanning ---

# Scan a binary's dynamic dependencies.
# Sets global: real_needed (array), interp_needed (string)
scan_needed() {
	local target="$1"
	local needed_s
	needed_s=$("$PATCHELF" --print-needed "$target")
	local needed
	mapfile -t needed <<<"$needed_s"

	real_needed=()
	interp_needed=""
	local lib
	for lib in "${needed[@]}"; do
		[[ -z "$lib" ]] && continue
		if [[ "$lib" =~ ^ld-linux ]]; then
			interp_needed="$lib"
			continue
		fi
		real_needed+=("$lib")
	done
}

# --- library resolution ---

# Resolve needed libraries to nixpkgs attributes via nix-locate.
# Uses global: real_needed, interp_needed
# Sets global: lib_to_attr (assoc), attrs (assoc), interp_attr (string), not_found (array)
resolve_libs() {
	declare -gA lib_to_attr=()
	declare -gA attrs=()
	interp_attr=""
	not_found=()

	local lib attr
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
}

# --- package building ---

# Build resolved nixpkgs attributes and record store paths.
# Uses global: attrs
# Sets global: attr_to_storepath (assoc)
build_packages() {
	declare -gA attr_to_storepath=()
	local attr store_path
	for attr in "${!attrs[@]}"; do
		log "  nix build nixpkgs#$attr"
		store_path=$(nix build --no-link --print-out-paths "nixpkgs#$attr")
		attr_to_storepath["$attr"]="$store_path"
	done
}

# --- interpreter search ---

# Find the dynamic linker (ld-linux) from resolved packages.
# Uses global: interp_attr, attr_to_storepath, real_needed, lib_to_attr
# Sets global: new_interp, interp_basename, interp_extra_storepath
find_interpreter() {
	new_interp=""
	interp_basename=""
	interp_extra_storepath=""

	local sp interp

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
		local lib attr
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

	# Strategy 3: search dependencies of resolved packages
	if [[ -z "$new_interp" ]]; then
		log "Warning: could not find interpreter directly; searching package dependencies..."
		local attr dep
		for attr in "${!attr_to_storepath[@]}"; do
			sp="${attr_to_storepath[$attr]}"
			for dep in $(nix-store -q --references "$sp" 2>/dev/null); do
				interp=$(find "$dep/lib" -name 'ld-linux-*.so.*' -not -type d 2>/dev/null | head -1)
				if [[ -n "$interp" ]]; then
					new_interp="$interp"
					interp_basename=$(basename "$interp")
					interp_extra_storepath="$dep"
					break 2
				fi
			done
		done
	fi
}
