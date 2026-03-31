#!/usr/bin/env bash
# lib/resolve-tool.bash — resolve external tool paths.
#
# Source this file; do not execute directly.

# Resolve a tool: explicit path > PATH > nix shell fallback
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
