// Generate self-extracting shell scripts for bundles.

import { quoteShLiteral, serializeAddFlagWordsSh, serializeEnvDirectivesSh } from "./add-flags.ts";
import type { EnvDirective } from "./types.ts";

/** Per-binary metadata embedded in the generated shell script. */
export interface BinaryInfo {
  name: string;
  interpreterBasename: string;
  interpOffset: number;
  /** Library directory name relative to bundle root (e.g. "lib" or "lib-yq"). */
  libDir: string;
}

/** How the bundle's main entry point is invoked. */
export type EntryConfig = { kind: "binary"; addFlags: string[] } | { kind: "script" };

export interface TemplateParams {
  /** Bundle name (temp dir, extract wrapper, etc.). */
  name: string;
  type: "rpath" | "preload";
  binaries: BinaryInfo[];
  interpPlaceholderLen: number;
  envDirectives: EnvDirective[];
  entry: EntryConfig;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sanitizeTag(name: string): string {
  return name.replace(/[^a-zA-Z0-9_]/g, "_");
}

function indentStr(s: string, tabs: number): string {
  if (!s) return "";
  const prefix = "\t".repeat(tabs);
  return s
    .split("\n")
    .map((l) => `${prefix}${l}`)
    .join("\n");
}

/**
 * Tagged template literal that strips common leading whitespace (spaces
 * only) from template literal fragments, leaving interpolated values
 * untouched.  Tabs in the content are preserved.
 *
 * NOTE: This is a minimal implementation tailored to this file's usage.
 * Known limitations:
 * - Only counts spaces for indent (tabs are treated as content).
 * - Interpolated values that start a new line can confuse indent detection
 *   if the fragment boundary falls mid-line in an unexpected way.
 */
function dedent(strings: TemplateStringsArray, ...values: unknown[]): string {
  // Compute common indent from the literal fragments only.
  // Skip the first line of each fragment (index > 0) since it continues the previous line.
  const allLines = strings.flatMap((s, si) => {
    const lines = s.split("\n");
    return si === 0 ? lines : lines.slice(1);
  });
  const indent = Math.min(
    ...allLines.filter((l) => l.trim()).map((l) => l.match(/^ */)?.[0].length ?? 0),
  );
  // Strip that indent from each fragment, then reassemble with values.
  const stripped = strings.map((s) =>
    s
      .split("\n")
      .map((line) => (line.startsWith(" ".repeat(indent)) ? line.slice(indent) : line))
      .join("\n"),
  );
  let result = stripped[0];
  for (let i = 0; i < values.length; i++) {
    result += String(values[i]) + stripped[i + 1];
  }
  return result.replace(/^\n/, "").replace(/\n[ \t]*$/, "");
}

/** Generate the patch_interp shell function (offset as parameter). */
function patchInterpFunc(placeholderLen: number): string {
  return dedent`\
    patch_interp() {
    \tlocal binary="$1" real_interp="$2" offset="$3"
    \tif [ \${#real_interp} -ge ${placeholderLen} ]; then
    \t\techo "Error: interpreter path too long (\${#real_interp} >= ${placeholderLen})" >&2
    \t\treturn 1
    \tfi
    \tchmod +w "$binary"
    \t{
    \t\tprintf '%s' "$real_interp"
    \t\tdd if=/dev/zero bs=1 count=$((${placeholderLen} - \${#real_interp})) 2>/dev/null
    \t} | dd of="$binary" bs=1 seek="$offset" count=${placeholderLen} conv=notrunc 2>/dev/null
    \tchmod -w "$binary"
    }`;
}

/** Generate patch_interp calls for every binary. */
function generatePatchLines(binaries: BinaryInfo[], rootExpr: string): string {
  return binaries
    .map((b) => {
      const bn = quoteShLiteral(b.name);
      const ld = quoteShLiteral(b.libDir);
      const il = quoteShLiteral(b.interpreterBasename);
      return `\tpatch_interp "${rootExpr}/orig/"${bn} "${rootExpr}/"${ld}/${il} ${b.interpOffset}`;
    })
    .join("\n");
}

/**
 * Generate a shell exec line for a binary.
 * rpath: exec directly. preload: prefix with LD_LIBRARY_PATH + LD_PRELOAD.
 * @param ds - dollar sign expression ("$" for inline, "\\$" for heredoc)
 * @param suffix - trailing args (e.g. addFlags + '"$@"')
 */
function binaryExecLine(
  type: "rpath" | "preload",
  b: BinaryInfo,
  rootExpr: string,
  ds: string,
  suffix: string,
): string {
  const bn = quoteShLiteral(b.name);
  const cmd = `exec "${rootExpr}/orig/"${bn} ${suffix}`;
  if (type === "rpath") return cmd;
  const ld = quoteShLiteral(b.libDir);
  return `LD_LIBRARY_PATH="${rootExpr}/"${ld}"${ds}{LD_LIBRARY_PATH:+:${ds}LD_LIBRARY_PATH}" LD_PRELOAD="${rootExpr}/"${ld}"/cleanup_env.so${ds}{LD_PRELOAD:+:${ds}LD_PRELOAD}" ${cmd}`;
}

// ---------------------------------------------------------------------------
// Unified template
// ---------------------------------------------------------------------------

function assertNever(x: never): never {
  throw new Error(`unexpected entry kind: ${(x as EntryConfig).kind}`);
}

/** Generate extract-mode bin/ wrappers. */
function generateExtractWrappers(
  p: TemplateParams,
  nameLiteral: string,
  envExtractBlock: string,
): string {
  switch (p.entry.kind) {
    case "binary": {
      const b = p.binaries[0];
      const bn = quoteShLiteral(b.name);
      const addFlagsExtract = serializeAddFlagWordsSh(p.entry.addFlags, "$TARGET");
      const execLine = binaryExecLine(p.type, b, "$TARGET", "\\$", `${addFlagsExtract} "\\$@"`);
      return dedent`\
        \tmkdir -p "$TARGET/bin"
        \tcat - >"$TARGET/bin/"${bn} <<-EOF2
        \t\t#!/bin/sh
        ${envExtractBlock}\t\t${execLine}
        \tEOF2
        \tchmod +x "$TARGET/bin/"${bn}`;
    }
    case "script": {
      const perBin = p.binaries
        .map((b) => {
          const bn = quoteShLiteral(b.name);
          const tag = sanitizeTag(b.name);
          const execLine = binaryExecLine(p.type, b, "$TARGET", "\\$", '"\\$@"');
          return dedent`\
            \tcat - >"$TARGET/bin/"${bn} <<-EOF_BIN_${tag}
            \t\t#!/bin/sh
            \t\t${execLine}
            \tEOF_BIN_${tag}
            \tchmod +x "$TARGET/bin/"${bn}`;
        })
        .join("\n");
      return dedent`\
        \tmkdir -p "$TARGET/bin"
        ${perBin}
        \tcat - >"$TARGET/bin/"${nameLiteral} <<-EOF_ENTRY
        \t\t#!/bin/sh
        ${envExtractBlock}\t\texport PATH="$TARGET/bin\${PATH:+:\\$PATH}"
        \t\texec "$TARGET/"'entry.sh' "\\$@"
        \tEOF_ENTRY
        \tchmod +x "$TARGET/bin/"${nameLiteral}`;
    }
    default:
      return assertNever(p.entry);
  }
}

/** Generate execute-mode invocation lines. */
function generateExecLines(p: TemplateParams, envExecBlock: string): string {
  switch (p.entry.kind) {
    case "binary": {
      const b = p.binaries[0];
      const bn = quoteShLiteral(b.name);
      const addFlagsExec = serializeAddFlagWordsSh(p.entry.addFlags, "$TEMP");
      if (p.type === "rpath") {
        return `${envExecBlock}\t"$TEMP/orig/"${bn} ${addFlagsExec} "$@"`;
      }
      const ld = quoteShLiteral(b.libDir);
      return `${envExecBlock}\tLD_LIBRARY_PATH="$TEMP/"${ld}"\${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" LD_PRELOAD="$TEMP/"${ld}"/cleanup_env.so\${LD_PRELOAD:+:$LD_PRELOAD}" "$TEMP/orig/"${bn} ${addFlagsExec} "$@"`;
    }
    case "script": {
      if (p.type === "rpath") {
        return dedent`\
          ${envExecBlock}\texport PATH="$TEMP/orig\${PATH:+:$PATH}"
          \t"$TEMP/"'entry.sh' "$@"`;
      }
      // preload script: need bin/ wrappers for per-binary LD_
      const binWrappers = p.binaries
        .map((b) => {
          const bn = quoteShLiteral(b.name);
          const tag = sanitizeTag(b.name);
          const execLine = binaryExecLine(p.type, b, "$TEMP", "\\$", '"\\$@"');
          return dedent`\
            \tcat - >"$TEMP/bin/"${bn} <<-EOF_EBIN_${tag}
            \t\t#!/bin/sh
            \t\t${execLine}
            \tEOF_EBIN_${tag}
            \tchmod +x "$TEMP/bin/"${bn}`;
        })
        .join("\n");
      return dedent`\
        \tmkdir -p "$TEMP/bin"
        ${binWrappers}
        ${envExecBlock}\texport PATH="$TEMP/bin\${PATH:+:$PATH}"
        \t"$TEMP/"'entry.sh' "$@"`;
    }
    default:
      return assertNever(p.entry);
  }
}

/** Generate a self-extracting shell script for any bundle configuration. */
export function generateScript(p: TemplateParams): string {
  const nameLiteral = quoteShLiteral(p.name);
  const envExec = serializeEnvDirectivesSh(p.envDirectives, "$TEMP");
  const envExtract = serializeEnvDirectivesSh(p.envDirectives, "$TARGET", { heredoc: true });
  const envExecBlock = envExec ? `${envExec}\n` : "";
  const envExtractBlock = envExtract ? `${indentStr(envExtract, 2)}\n` : "";

  const patchExecLines = generatePatchLines(p.binaries, "$TEMP");
  const patchExtractLines = generatePatchLines(p.binaries, "$TARGET");
  const extractBinWrappers = generateExtractWrappers(p, nameLiteral, envExtractBlock);
  const execLines = generateExecLines(p, envExecBlock);

  // Keep the trailing newline so the appended tar payload starts on the next line.
  return `${dedent`\
      #!/bin/sh
      set -u
      TEMP="$(mktemp -d "\${TMPDIR:-/tmp}"/${nameLiteral}.XXXXXX)"
      N=$(grep -an "^#START_OF_TAR#" "$0" | cut -d: -f1)
      tail -n +"$((N + 1))" <"$0" > "$TEMP/self.tar.gz" || exit 1
      ${patchInterpFunc(p.interpPlaceholderLen)}
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
      ${patchExtractLines}
      ${extractBinWrappers}
      \trm -rf "$TEMP"
      \techo "successfully extracted to $2"
      \texit 0
      else
      \tif [ "\${1:-}" = "--" ]; then
      \t\tshift
      \tfi
      \ttar -C "$TEMP" -xzf "$TEMP/self.tar.gz" || exit 1
      \ttrap 'rm -rf "$TEMP"' EXIT
      ${patchExecLines}
      ${execLines}
      \texit $?
      fi
      #START_OF_TAR#
      `}\n`;
}
