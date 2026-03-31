#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib/resolve-tool.bash"

PATCHELF=$(resolve_tool "" patchelf patchelf)

INTERP_PLACEHOLDER_LEN=256
INTERP_PLACEHOLDER_TAG="NIXBUNDLEELF_INTERP_PLACEHOLDER"

usage() {
	cat >&2 <<-EOF
		Usage: $(basename "$0") <binary> [options]

		Bundles an ELF binary into a self-extracting executable or Lambda zip
		with all needed libraries, using RPATH rewriting.

		The generated executable supports:
		  <result> [--] ARGS       Extract to temp dir and run with ARGS
		  <result> --extract DIR   Extract permanently to DIR

		Options:
		  -o, --output <path>      Output file (default: ./<basename of input>)
		  --format <exe|lambda>    Output format (default: exe)
		  --no-nix-locate          Disable nix-locate (error if binary is foreign)
		  -h, --help               Show this help
	EOF
	exit 1
}

target=""
output=""
format=""
use_nix_locate=true

parse_args() {
	while (($# > 0)); do
		case "$1" in
		-h | --help) usage ;;
		-o | --output)
			output="${2:?--output requires an argument}"
			shift
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
		--no-nix-locate)
			use_nix_locate=false
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
		echo "Error: target does not exist: $target" >&2
		exit 1
	fi

	if [[ -z "$format" ]]; then
		format=exe
	fi

	if [[ -z "$output" ]]; then
		output="$(pwd)/$(basename "$target")"
	fi

	name=$(basename "$output")
	output="$(cd "$(dirname "$output")" && pwd)/$name"

	if [[ -e "$output" ]]; then
		echo "Error: $output already exists" >&2
		exit 1
	fi
}

# Patch a foreign (non-Nix) binary to use /nix/store libraries.
# After this, the binary has proper RPATH and can be processed by gather_deps.
patch_foreign() {
	source "$SCRIPT_DIR/lib/resolve-foreign-deps.bash"

	NIX_LOCATE=$(resolve_tool "" nix-locate nix-index)

	scan_needed "$target"

	if [[ ${#real_needed[@]} -eq 0 && -z "$interp_needed" ]]; then
		echo "Error: no dynamic dependencies found. Is this a static binary?" >&2
		exit 1
	fi

	log "==> Resolving foreign dependencies with nix-locate"
	resolve_libs

	if [[ ${#not_found[@]} -gt 0 ]]; then
		echo "Error: could not find packages for: ${not_found[*]}" >&2
		exit 1
	fi

	log "==> Building packages"
	build_packages

	find_interpreter

	if [[ -z "$new_interp" ]]; then
		echo "Error: could not find interpreter (ld-linux)" >&2
		exit 1
	fi

	# Collect RPATH entries from store paths
	local rpath_entries=()
	for attr in "${!attr_to_storepath[@]}"; do
		local sp="${attr_to_storepath[$attr]}"
		if [[ -d "$sp/lib" ]]; then
			rpath_entries+=("$sp/lib")
		fi
	done
	if [[ -n "$interp_extra_storepath" && -d "$interp_extra_storepath/lib" ]]; then
		rpath_entries+=("$interp_extra_storepath/lib")
	fi
	local rpath
	rpath=$(IFS=:; echo "${rpath_entries[*]}")

	# Patch a copy of the binary
	local patched="$tmpdir/patched_$(basename "$target")"
	cp "$target" "$patched"
	chmod +w "$patched"
	"$PATCHELF" --set-interpreter "$new_interp" "$patched"
	"$PATCHELF" --set-rpath "$rpath" "$patched"
	chmod -w "$patched"

	log "==> Patched to use /nix/store paths, proceeding with bundling"
	target="$patched"
}

source "$SCRIPT_DIR/lib/gather-nix-deps.bash"

main() {
	parse_args "$@"

	# workdir
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	mkdir -p "$tmpdir"
	pushd "$tmpdir" >/dev/null

	# Detect foreign binary and resolve dependencies if needed
	interpreter=$("$PATCHELF" --print-interpreter "${target}")
	if [[ "$interpreter" != /nix/store/* ]]; then
		if ! $use_nix_locate; then
			echo "Error: target binary has a non-Nix interpreter ($interpreter)." >&2
			echo "  Use nix-locate to resolve dependencies (remove --no-nix-locate)," >&2
			echo "  or provide a Nix-built binary." >&2
			exit 1
		fi
		patch_foreign
	fi

	# find interpreter (may have changed after patch_foreign)
	interpreter=$("$PATCHELF" --print-interpreter "${target}")
	interpreterb=$(basename "$interpreter")

	# gather shared libraries
	libs_s=$(gather_deps "${target}" "$interpreterb")
	mapfile -t libs <<<"$libs_s"

	# copy interpreter
	mkdir -p out/lib
	cp "$interpreter" out/lib

	# copy and patchelf dynamic libraries
	for libfile in "${libs[@]}"; do
		libb=$(basename "$libfile")
		cp "$libfile" out/lib
		chmod +w "out/lib/$libb"
		"$PATCHELF" --set-rpath \$ORIGIN "out/lib/$libb"
		chmod -w "out/lib/$libb"
	done

	case "$format" in
	exe)
		bundle_exe
		;;
	lambda)
		bundle_lambda
		;;
	esac
}

bundle_exe() {
	# copy and patchelf original binary
	mkdir -p out/orig
	cp "${target}" out/orig/"${name}"
	chmod +w "out/orig/${name}"
	# Set RPATH to relative path and interpreter to a placeholder.
	# The placeholder will be replaced with the actual absolute path at
	# extraction time, allowing the binary to be executed directly (not via
	# ld-linux). This preserves /proc/self/exe, which programs like Node.js
	# SEA rely on.
	local placeholder="/${INTERP_PLACEHOLDER_TAG}"
	while [[ ${#placeholder} -lt $INTERP_PLACEHOLDER_LEN ]]; do placeholder="${placeholder}/"; done
	placeholder="${placeholder:0:$INTERP_PLACEHOLDER_LEN}"
	"$PATCHELF" \
		--set-interpreter "$placeholder" \
		--set-rpath \$ORIGIN/../lib \
		"out/orig/${name}"
	# Record the byte offset of the placeholder in the binary. This avoids
	# needing to search at runtime, eliminating any risk of matching a stray
	# occurrence elsewhere in the binary.
	local match_count
	match_count=$(grep -c "$INTERP_PLACEHOLDER_TAG" "out/orig/${name}" || true)
	if [[ "$match_count" -ne 1 ]]; then
		echo "Error: interpreter placeholder found $match_count times (expected 1)" >&2
		exit 1
	fi
	local interp_offset
	interp_offset=$(grep -boa "$INTERP_PLACEHOLDER_TAG" "out/orig/${name}" | head -1 | cut -d: -f1)
	interp_offset=$((interp_offset - 1)) # account for leading "/"
	chmod -w "out/orig/${name}"

	# archive
	tar -C "$tmpdir/out" -czf "$tmpdir/bundle.tar.gz" .

	# create self-extracting script
	cat - "$tmpdir/bundle.tar.gz" >"$output" <<-EOF
		#!/usr/bin/env bash
		set -u
		TEMP="\$(mktemp -d "\${TMPDIR:-/tmp}"/${name}.XXXXXX)"
		N=\$(grep -an "^#START_OF_TAR#" "\$0" | cut -d: -f1)
		tail -n +"\$((N + 1))" <"\$0" > "\$TEMP/self.tar.gz" || exit 1
		# Patch the interpreter placeholder in the binary with the actual
		# absolute path to the bundled ld-linux. The byte offset was
		# determined at bundle time to avoid runtime binary searching.
		patch_interp() {
			local binary="\$1" real_interp="\$2"
			if [[ \${#real_interp} -ge ${INTERP_PLACEHOLDER_LEN} ]]; then
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
		if [[ "\${1:-}" == "--extract" ]]; then
			# extract mode
			if [[ -z "\${2:-}" ]]; then
				echo "Usage: \$0 --extract <path>"
				exit 1
			fi
			if [[ -e "\$2" ]]; then
				echo "Error: \$2 already exists"
				exit 1
			fi
			TARGET=\$(realpath "\$2")
			mkdir -p "\$TARGET"
			tar -C "\$TARGET" -xzf "\$TEMP/self.tar.gz" || exit 1
			patch_interp "\$TARGET/orig/${name}" "\$TARGET/lib/${interpreterb}"
			mkdir -p "\$TARGET/bin"
			cat - >"\$TARGET/bin/${name}" <<-EOF2
				#!/usr/bin/env bash
				exec "\$TARGET/orig/${name}" "\\\$@"
			EOF2
			chmod +x "\$TARGET/bin/${name}"
			echo "successfully extracted to \$2"
			exit 0
		else
			# execute mode
			if [[ "\${1:-}" == "--" ]]; then
				shift
			fi
			tar -C "\$TEMP" -xzf "\$TEMP/self.tar.gz" || exit 1
			trap 'rm -rf \$TEMP' EXIT
			patch_interp "\$TEMP/orig/${name}" "\$TEMP/lib/${interpreterb}"
			"\$TEMP/orig/${name}" "\$@"
			exit \$?
		fi
		#START_OF_TAR#
	EOF

	chmod +x "$output"
}

bundle_lambda() {
	# patchelf executable
	cp "${target}" out/bootstrap
	chmod +w out/bootstrap
	"$PATCHELF" \
		--set-interpreter "./lib/$interpreterb" \
		--set-rpath ./lib \
		out/bootstrap
	chmod -w out/bootstrap

	# zip (strip .zip suffix if present — zip adds it automatically)
	local zip_base="${output%.zip}"
	(cd out && zip -qr "$zip_base" .)
}

main "$@"
