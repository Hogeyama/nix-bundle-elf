#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

TMPDIR_BUNDLE=""

cleanup() {
	if [[ -n "$TMPDIR_BUNDLE" ]]; then
		rm -rf "$TMPDIR_BUNDLE"
	fi
}
trap cleanup EXIT

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
# Handles package names with output suffixes (e.g., "libgcc.lib", "gccNGPackages_15.libstdcxx.out").
# nix-alien returns names as "<attr-path>.<output>" where the last segment is the output name.
build_package() {
	local pkg=$1
	local nixpkgs_ref=$2

	# Known Nix output names (last segment after final dot)
	local known_outputs="out dev lib doc man bin static debug info headers"
	local last_segment="${pkg##*.}"

	if [[ "$pkg" == *.* ]] && [[ " ${known_outputs} " == *" ${last_segment} "* ]]; then
		local attr_path="${pkg%.*}"
		nix build "${nixpkgs_ref}#${attr_path}^${last_segment}" --no-link --print-out-paths
	else
		nix build "${nixpkgs_ref}#${pkg}" --no-link --print-out-paths
	fi
}

main() {
	parse_args "$@"

	# Use the user's nixpkgs (flake registry) for lib resolution.
	# nix-alien-find-libs returns package names from the user's nix-index, which is
	# indexed against their current nixpkgs -- not necessarily the pinned flake.lock rev.
	local nixpkgs_ref="nixpkgs"
	echo "Using nixpkgs: ${nixpkgs_ref} (from flake registry)" >&2

	# Ensure patchelf is available (may not be on non-NixOS systems)
	if ! command -v patchelf &>/dev/null; then
		local patchelf_path
		patchelf_path=$(nix build "${nixpkgs_ref}#patchelf" --no-link --print-out-paths 2>/dev/null)
		export PATH="${patchelf_path}/bin:${PATH}"
		echo "Using patchelf from Nix store: ${patchelf_path}/bin/patchelf" >&2
	fi

	# Run nix-alien-find-libs
	local alien_args=(--json)
	if [[ "$auto" == true ]]; then
		alien_args+=(--select-candidates '.*')
	fi
	alien_args+=("$target")

	echo "Finding library dependencies with nix-alien-find-libs..." >&2
	local libs_json
	libs_json=$(nix run "github:thiagokokada/nix-alien#nix-alien-find-libs" -- "${alien_args[@]}")

	# Extract unique package names (filter out null/unfound libs).
	# Always include glibc (libdl, libm, libpthread, libc) and gcc-unwrapped^lib
	# (libgcc_s.so.1) as baseline C/C++ runtime packages -- nix-alien-find-libs
	# often omits these because they appear in nix-index as system-level libs.
	local -a packages
	mapfile -t packages < <(echo "$libs_json" | jq -r '
		to_entries
		| map(select(.value != null))
		| map(.value)
		| . + ["gcc-unwrapped^lib"]
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
	TMPDIR_BUNDLE=$(mktemp -d)

	cp "$target" "$TMPDIR_BUNDLE/${name}"
	chmod +w "$TMPDIR_BUNDLE/${name}"
	patchelf --set-rpath "$rpath" "$TMPDIR_BUNDLE/${name}"

	echo "Calling bundle.bash..." >&2

	bash "$SCRIPT_DIR/bundle.bash" \
		"$TMPDIR_BUNDLE/${name}" \
		--format "$format" \
		--use-global-interpreter \
		--use-system-glibc \
		"$name"
}

main "$@"
