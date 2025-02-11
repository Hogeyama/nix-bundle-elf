#!/usr/bin/env bash
set -euo pipefail

OLDPWD="$PWD"

target="" # binary to bundle
name=""   # name after bundling
format=""
parse_args() {
	while (($# > 0)); do
		case "$1" in
		--help)
			echo "Usage: $0 <target> --format <exe|lambda> [name]"
			exit 0
			;;
		--format)
			if [[ -z "$2" ]]; then
				echo "Error: format is not specified" >&2
				exit 1
			fi
			if [[ "$2" != "exe" && "$2" != "lambda" ]]; then
				echo "Error: invalid format" >&2
				exit 1
			fi
			format=$2
			shift
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

# gather shared libraries recursively
function gather_deps() {
	declare -A libs=()
	local queue=("$1") interpreterb=$2

	while [[ ${#queue[@]} -gt 0 ]]; do
		local current="${queue[0]}"
		queue=("${queue[@]:1}") # dequeue

		# check if already visited
		if [[ -n "${libs["$current"]:-}" ]]; then
			continue
		fi
		libs["$current"]=1

		mapfile -t needed < <(patchelf --print-needed "$current")
		IFS=: read -ra runpaths < <(patchelf --print-rpath "$current")

		for libname in "${needed[@]}"; do
			# ignore interpreter
			if [[ "$libname" == "$interpreterb" ]]; then
				continue
			fi

			# identify the full path of the library
			local found=""
			for rp in "${runpaths[@]}"; do
				if [[ -e "$rp/$libname" ]]; then
					found="$rp/$libname"
					break
				fi
			done

			if [[ -z "$found" ]]; then
				if [[ $libname =~ libc.so.* ]]; then
					# probably bootstrap case
					break
				else
					echo "Error: could not find library $libname needed by $current" >&2
					exit 1
				fi
			fi

			queue+=("$found")
		done
	done

	# remove the original binary
	unset 'libs[$1]'

	for libfile in "${!libs[@]}"; do
		printf "%s\n" "$libfile"
	done
}

main() {
	parse_args "$@"

	# workdir
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	mkdir -p "$tmpdir"
	pushd "$tmpdir" >/dev/null

	# find interpreter
	interpreter=$(patchelf --print-interpreter "${target}")
	interpreterb=$(basename "$interpreter")

	# gather shared libraries
	mapfile -t libs < <(gather_deps "${target}" "$interpreterb")

	# copy interpreter
	mkdir -p out/lib
	cp "$interpreter" out/lib

	# copy and patchelf dynamic libraries
	for libfile in "${libs[@]}"; do
		libb=$(basename "$libfile")
		cp "$libfile" out/lib
		chmod +w "out/lib/$libb"
		patchelf --set-rpath \$ORIGIN --force-rpath "out/lib/$libb"
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
	patchelf --set-rpath \$ORIGIN/../lib --force-rpath "out/orig/${name}"
	chmod -w "out/orig/${name}"

	# archive
	tar -C "$tmpdir/out" -czf "$tmpdir/bundle.tar.gz" .

	# create self-extracting script
	bundled="${name}"
	touch "$bundled"
	chmod +x "$bundled"
	cat - "$tmpdir/bundle.tar.gz" >"$bundled" <<-EOF
		#!/usr/bin/env bash
		set -u
		TEMP="\$(mktemp -d "\${TMPDIR:-/tmp}"/${name}.XXXXXX)"
		N=\$(grep -an "^#START_OF_TAR#" "\$0" | cut -d: -f1)
		tail -n +"\$((N + 1))" <"\$0" > "\$TEMP/self.tar.gz" || exit 1
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
			mkdir -p "\$TARGET/bin"
			cat - >"\$TARGET/bin/${name}" <<-EOF2
				#!/usr/bin/env bash
				exec "\$TARGET/lib/$interpreterb" --argv0 "\\\$0" "\$TARGET/orig/${name}" "\\\$@"
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
			"\$TEMP/lib/$interpreterb" --argv0 "\$0" "\$TEMP/orig/${name}" "\$@"
			exit \$?
		fi
		#START_OF_TAR#
	EOF

	if [[ -e "$OLDPWD/$bundled" ]]; then
		echo "Error: $bundled already exists" >&2
		exit 1
	fi
	mv -n "$bundled" "$OLDPWD"
	realpath "$OLDPWD/$bundled"
}

bundle_lambda() {
	# patchelf executable
	cp "${target}" out/bootstrap
	chmod +w out/bootstrap
	patchelf \
		--set-interpreter "./lib/$interpreterb" \
		--set-rpath ./lib \
		--force-rpath \
		out/bootstrap
	chmod -w out/bootstrap

	# zip
	(cd out && zip -qr function.zip .)

	if [[ -e "$OLDPWD/function.zip" ]]; then
		echo "Error: function.zip already exists" >&2
		exit 1
	fi
	mv -n "$tmpdir/out/function.zip" "$OLDPWD"
	realpath "$OLDPWD/function.zip"
}

main "$@"
