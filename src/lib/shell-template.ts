// Generate self-extracting shell scripts for rpath and preload bundles.

import { quoteShLiteral, serializeAddFlagWordsSh, serializeEnvDirectivesSh } from "./add-flags.ts";
import type { EnvDirective } from "./types.ts";

interface RpathTemplateParams {
  name: string;
  interpreterBasename: string;
  interpOffset: number;
  interpPlaceholderLen: number;
  addFlags: string[];
  envDirectives: EnvDirective[];
}

interface PreloadTemplateParams {
  name: string;
  interpBasename: string;
  interpOffset: number;
  interpPlaceholderLen: number;
  addFlags: string[];
  envDirectives: EnvDirective[];
}

/** Generate the self-extracting script for rpath bundles. */
export function generateRpathScript(p: RpathTemplateParams): string {
  const addFlagsExec = serializeAddFlagWordsSh(p.addFlags, "$TEMP");
  const addFlagsExtract = serializeAddFlagWordsSh(p.addFlags, "$TARGET");
  const envExec = serializeEnvDirectivesSh(p.envDirectives, "$TEMP");
  const envExtract = serializeEnvDirectivesSh(p.envDirectives, "$TARGET", { heredoc: true });
  const nameLiteral = quoteShLiteral(p.name);
  const interpreterLiteral = quoteShLiteral(p.interpreterBasename);

  // Helper: indent each line of a multi-line string with tabs
  const indent = (s: string, tabs: number): string => {
    if (!s) return "";
    const prefix = "\t".repeat(tabs);
    return s
      .split("\n")
      .map((l) => `${prefix}${l}`)
      .join("\n");
  };

  const envExecBlock = envExec ? `${envExec}\n` : "";
  const envExtractBlock = envExtract ? `${indent(envExtract, 2)}\n` : "";

  return `#!/bin/sh
set -u
TEMP="$(mktemp -d "\${TMPDIR:-/tmp}"/${nameLiteral}.XXXXXX)"
N=$(grep -an "^#START_OF_TAR#" "$0" | cut -d: -f1)
tail -n +"$((N + 1))" <"$0" > "$TEMP/self.tar.gz" || exit 1
# Patch the interpreter placeholder in the binary with the actual
# absolute path to the bundled ld-linux. The byte offset was
# determined at bundle time to avoid runtime binary searching.
patch_interp() {
\tlocal binary="$1" real_interp="$2"
\tif [ \${#real_interp} -ge ${p.interpPlaceholderLen} ]; then
\t\techo "Error: interpreter path too long (\${#real_interp} >= ${p.interpPlaceholderLen})" >&2
\t\treturn 1
\tfi
\tchmod +w "$binary"
\t{
\t\tprintf '%s' "$real_interp"
\t\tdd if=/dev/zero bs=1 count=$((${p.interpPlaceholderLen} - \${#real_interp})) 2>/dev/null
\t} | dd of="$binary" bs=1 seek=${p.interpOffset} count=${p.interpPlaceholderLen} conv=notrunc 2>/dev/null
\tchmod -w "$binary"
}
if [ "\${1:-}" = "--extract" ]; then
\t# extract mode
\tif [ -z "\${2:-}" ]; then
\t\techo "Usage: $0 --extract <path>"
\t\texit 1
\tfi
\tif [ -e "$2" ]; then
\t\techo "Error: $2 already exists"
\t\texit 1
\tfi
\tmkdir -p "$2"
\tTARGET=$(cd "$2" && pwd)
\ttar -C "$TARGET" -xzf "$TEMP/self.tar.gz" || exit 1
\tpatch_interp "$TARGET/orig/"${nameLiteral} "$TARGET/lib/"${interpreterLiteral}
\tmkdir -p "$TARGET/bin"
\tcat - >"$TARGET/bin/"${nameLiteral} <<-EOF2
\t\t#!/bin/sh
${envExtractBlock}\t\texec "$TARGET/orig/"${nameLiteral} ${addFlagsExtract} "\\$@"
\tEOF2
\tchmod +x "$TARGET/bin/"${nameLiteral}
\techo "successfully extracted to $2"
\texit 0
else
\t# execute mode
\tif [ "\${1:-}" = "--" ]; then
\t\tshift
\tfi
\ttar -C "$TEMP" -xzf "$TEMP/self.tar.gz" || exit 1
\ttrap 'rm -rf $TEMP' EXIT
\tpatch_interp "$TEMP/orig/"${nameLiteral} "$TEMP/lib/"${interpreterLiteral}
${envExecBlock}\t"$TEMP/orig/"${nameLiteral} ${addFlagsExec} "$@"
\texit $?
fi
#START_OF_TAR#
`;
}

/** Generate the self-extracting script for preload bundles. */
export function generatePreloadScript(p: PreloadTemplateParams): string {
  const addFlagsExec = serializeAddFlagWordsSh(p.addFlags, "$TEMP");
  const addFlagsExtract = serializeAddFlagWordsSh(p.addFlags, "$TARGET");
  const envExec = serializeEnvDirectivesSh(p.envDirectives, "$TEMP");
  const envExtract = serializeEnvDirectivesSh(p.envDirectives, "$TARGET", { heredoc: true });
  const nameLiteral = quoteShLiteral(p.name);
  const interpreterLiteral = quoteShLiteral(p.interpBasename);

  const indent = (s: string, tabs: number): string => {
    if (!s) return "";
    const prefix = "\t".repeat(tabs);
    return s
      .split("\n")
      .map((l) => `${prefix}${l}`)
      .join("\n");
  };

  const envExecBlock = envExec ? `${indent(envExec, 1)}\n` : "";
  const envExtractBlock = envExtract ? `${indent(envExtract, 2)}\n` : "";

  return `#!/bin/sh
set -u
TEMP="$(mktemp -d "\${TMPDIR:-/tmp}"/${nameLiteral}.XXXXXX)"
N=$(grep -an "^#START_OF_TAR#" "$0" | cut -d: -f1)
tail -n +"$((N + 1))" <"$0" > "$TEMP/self.tar.gz" || exit 1
patch_interp() {
\tlocal binary="$1" real_interp="$2"
\tif [ \${#real_interp} -ge ${p.interpPlaceholderLen} ]; then
\t\techo "Error: interpreter path too long (\${#real_interp} >= ${p.interpPlaceholderLen})" >&2
\t\treturn 1
\tfi
\tchmod +w "$binary"
\t{
\t\tprintf '%s' "$real_interp"
\t\tdd if=/dev/zero bs=1 count=$((${p.interpPlaceholderLen} - \${#real_interp})) 2>/dev/null
\t} | dd of="$binary" bs=1 seek=${p.interpOffset} count=${p.interpPlaceholderLen} conv=notrunc 2>/dev/null
\tchmod -w "$binary"
}
if [ "\${1:-}" = "--extract" ]; then
\tif [ -z "\${2:-}" ]; then
\t\techo "Usage: $0 --extract <path>"
\t\texit 1
\tfi
\tif [ -e "$2" ]; then
\t\techo "Error: $2 already exists"
\t\texit 1
\tfi
\tmkdir -p "$2"
\tTARGET=$(cd "$2" && pwd)
\ttar -C "$TARGET" -xzf "$TEMP/self.tar.gz" || exit 1
\tpatch_interp "$TARGET/orig/"${nameLiteral} "$TARGET/lib/"${interpreterLiteral}
\tmkdir -p "$TARGET/bin"
\tcat - >"$TARGET/bin/"${nameLiteral} <<-EOF2
\t\t#!/bin/sh
${envExtractBlock}\t\tLD_LIBRARY_PATH="$TARGET/lib\\$\{LD_LIBRARY_PATH:+:\\$LD_LIBRARY_PATH}" LD_PRELOAD="$TARGET/lib/cleanup_env.so\\$\{LD_PRELOAD:+:\\$LD_PRELOAD}" exec "$TARGET/orig/"${nameLiteral} ${addFlagsExtract} "\\$@"
\tEOF2
\tchmod +x "$TARGET/bin/"${nameLiteral}
\trm -rf "$TEMP"
\techo "successfully extracted to $2"
\texit 0
else
\tif [ "\${1:-}" = "--" ]; then
\t\tshift
\tfi
\ttar -C "$TEMP" -xzf "$TEMP/self.tar.gz" || exit 1
\ttrap 'rm -rf "$TEMP"' EXIT
\tpatch_interp "$TEMP/orig/"${nameLiteral} "$TEMP/lib/"${interpreterLiteral}
${envExecBlock}\tLD_LIBRARY_PATH="$TEMP/lib\${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" LD_PRELOAD="$TEMP/lib/cleanup_env.so\${LD_PRELOAD:+:$LD_PRELOAD}" "$TEMP/orig/"${nameLiteral} ${addFlagsExec} "$@"
\texit $?
fi
#START_OF_TAR#
`;
}
