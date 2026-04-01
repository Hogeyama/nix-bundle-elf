#!/usr/bin/env bash
# lib/gather-nix-deps.bash — gather shared libraries by walking RPATH/NEEDED.
#
# Source this file; do not execute directly.
# Requires: PATCHELF variable set to patchelf binary path.
# Suitable for binaries whose RPATH already points to actual library paths
# (typically Nix-built binaries with /nix/store RPATH).

# Gather shared libraries recursively by traversing NEEDED and RPATH.
# Usage: gather_deps <binary> <interpreter-basename>
# Outputs one library path per line (excluding the binary itself).
gather_deps() {
	declare -A libs=()
	declare -a runpaths=()
	local queue=("$1") interpreterb=$2

	while [[ ${#queue[@]} -gt 0 ]]; do
		local current="${queue[0]}"
		queue=("${queue[@]:1}") # dequeue

		# check if already visited
		if [[ -n "${libs["$current"]:-}" ]]; then
			continue
		fi
		libs["$current"]=1

		local needed_s
		needed_s=$("$PATCHELF" --print-needed "$current")
		local needed
		mapfile -t needed <<<"$needed_s"
		local runpaths_s
		runpaths_s=$("$PATCHELF" --print-rpath "$current")
		local cur_runpaths
		IFS=: read -ra cur_runpaths <<<"$runpaths_s"
		runpaths+=("${cur_runpaths[@]}")

		local libname
		for libname in "${needed[@]}"; do
			# skip empty entries (e.g. when patchelf --print-needed returns nothing)
			if [[ -z "$libname" ]]; then
				continue
			fi
			# ignore interpreter
			if [[ "$libname" == "$interpreterb" ]]; then
				continue
			fi

			# identify the full path of the library
			local found="" rp
			for rp in "${runpaths[@]}"; do
				if [[ -e "$rp/$libname" ]]; then
					found="$rp/$libname"
					break
				fi
			done

			if [[ -z "$found" ]]; then
				if [[ $libname =~ libc.so.* ]]; then
					# probably bootstrap case
					continue
				else
					echo "Notice: could not resolve $libname from RPATH/RUNPATH for $current" >&2
					return 1
				fi
			fi

			queue+=("$found")
		done
	done

	# remove the original binary
	unset 'libs[$1]'

	local libfile
	for libfile in "${!libs[@]}"; do
		printf "%s\n" "$libfile"
	done
}
