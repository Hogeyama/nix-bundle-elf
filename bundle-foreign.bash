#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

target=""
name=""
format=""
auto=false

parse_args() {
	while (($# > 0)); do
		case "$1" in
		--help)
			echo "Usage: $0 <target> --format <exe|lambda> [--auto] [name]"
			echo ""
			echo "Bundle a non-Nix ELF binary with its library dependencies from nixpkgs."
			echo "Uses nix-alien-find-libs to discover which nixpkgs packages provide"
			echo "the required shared libraries."
			echo ""
			echo "Options:"
			echo "  --format <exe|lambda>  Output format (same as bundle.bash)"
			echo "  --auto                 Auto-select library candidates (non-interactive)"
			echo "  --help                 Show this help"
			echo ""
			echo "Prerequisites: nix, patchelf, jq, nix-index database"
			exit 0
			;;
		--format)
			if [[ -z "${2:-}" ]]; then
				echo "Error: format is not specified" >&2
				exit 1
			fi
			if [[ "$2" != "exe" && "$2" != "lambda" ]]; then
				echo "Error: invalid format: $2" >&2
				exit 1
			fi
			format=$2
			shift
			;;
		--auto)
			auto=true
			;;
		*)
			if [[ -z "$target" ]]; then
				target=$(realpath "$1")
			elif [[ -z "$name" ]]; then
				name=$1
			else
				echo "Error: too many arguments" >&2
				exit 1
			fi
			;;
		esac
		shift
	done

	if [[ -z "$target" ]]; then
		echo "Error: target is not specified" >&2
		exit 1
	fi

	if ! [[ -e "$target" ]]; then
		echo "Error: target does not exist" >&2
		exit 1
	fi

	if [[ -z "$format" ]]; then
		echo "Error: format is not specified" >&2
		exit 1
	fi

	if [[ -z "$name" ]]; then
		name=$(basename "$target")
	fi
}

# Build a nixpkgs package and print output paths.
# Handles package names with output suffixes (e.g., "gcc-unwrapped.lib")
build_package() {
	local pkg=$1
	local nixpkgs_ref=$2

	if [[ "$pkg" == *.* ]]; then
		local pkg_name="${pkg%%.*}"
		local output="${pkg#*.}"
		nix build "${nixpkgs_ref}#${pkg_name}^${output}" --no-link --print-out-paths
	else
		nix build "${nixpkgs_ref}#${pkg}" --no-link --print-out-paths
	fi
}

main() {
	parse_args "$@"

	# Get nixpkgs rev from flake.lock
	local nixpkgs_rev
	nixpkgs_rev=$(jq -r '.nodes.nixpkgs.locked.rev' "$SCRIPT_DIR/flake.lock")
	local nixpkgs_ref="github:NixOS/nixpkgs/${nixpkgs_rev}"
	echo "Using nixpkgs: ${nixpkgs_ref}" >&2

	# Run nix-alien-find-libs
	local alien_args=(--json)
	if [[ "$auto" == true ]]; then
		alien_args+=(--select-candidates '.*')
	fi
	alien_args+=("$target")

	echo "Finding library dependencies with nix-alien-find-libs..." >&2
	local libs_json
	libs_json=$(nix run "github:thiagokokada/nix-alien#nix-alien-find-libs" -- "${alien_args[@]}")

	# Extract unique package names (filter out null/unfound libs)
	local -a packages
	mapfile -t packages < <(echo "$libs_json" | jq -r '
		to_entries
		| map(select(.value != null))
		| map(.value)
		| unique
		| .[]
	')

	if [[ ${#packages[@]} -eq 0 ]]; then
		echo "Error: no packages found for library dependencies" >&2
		exit 1
	fi

	echo "Resolved packages: ${packages[*]}" >&2

	# Resolve store paths and find lib directories
	local -a lib_dirs=()
	for pkg in "${packages[@]}"; do
		echo "Building ${pkg}..." >&2
		local -a store_paths
		mapfile -t store_paths < <(build_package "$pkg" "$nixpkgs_ref" 2>/dev/null || true)

		local found_lib=false
		for sp in "${store_paths[@]}"; do
			if [[ -n "$sp" && -d "${sp}/lib" ]]; then
				lib_dirs+=("${sp}/lib")
				found_lib=true
			fi
		done

		# If default outputs don't have lib/, try all outputs
		if [[ "$found_lib" == false ]]; then
			mapfile -t store_paths < <(nix build "${nixpkgs_ref}#${pkg%%.*}^*" --no-link --print-out-paths 2>/dev/null || true)
			for sp in "${store_paths[@]}"; do
				if [[ -n "$sp" && -d "${sp}/lib" ]]; then
					lib_dirs+=("${sp}/lib")
				fi
			done
		fi
	done

	if [[ ${#lib_dirs[@]} -eq 0 ]]; then
		echo "Error: no lib directories found in resolved packages" >&2
		exit 1
	fi

	echo "Found lib directories:" >&2
	printf "  %s\n" "${lib_dirs[@]}" >&2

	# Build RPATH from lib directories
	local rpath
	rpath=$(IFS=:; echo "${lib_dirs[*]}")

	# Patch a copy of the binary with Nix store RPATHs
	local tmpdir
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT

	cp "$target" "$tmpdir/${name}"
	chmod +w "$tmpdir/${name}"
	patchelf --set-rpath "$rpath" "$tmpdir/${name}"

	echo "Calling bundle.bash..." >&2

	bash "$SCRIPT_DIR/bundle.bash" \
		"$tmpdir/${name}" \
		--format "$format" \
		--use-global-interpreter \
		"$name"
}

main "$@"
