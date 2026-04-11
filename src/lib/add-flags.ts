// Serialize --add-flag values into POSIX-sh-safe inline word lists.
// %ROOT in flag values is replaced with a shell expression (e.g. '$TEMP').
// %ORIG, when enabled by callers, is replaced with a shell expression that
// evaluates to the outermost script's resolved path at runtime (e.g. '$ORIG').
// %% is an escaped literal %.

import type { EnvDirective } from "./types.ts";

/** Quote a string as a POSIX sh single-quoted literal. */
export function quoteShLiteral(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

/**
 * Per-serialization context controlling placeholder expansion.
 * - `rootExpr` is always used for `%ROOT` and must be a POSIX-sh expression
 *   (e.g. `$TEMP`, `$TARGET`, or the heredoc-escaped `\$TARGET`).
 * - `origExpr`, when provided, enables `%ORIG` expansion. In exec context
 *   it is typically `$ORIG`; in heredoc context it is `\$ORIG` so that the
 *   wrapper evaluates it at its own runtime, not at extract time.
 */
export interface ExpansionContext {
  rootExpr: string;
  origExpr?: string;
}

/**
 * Expand %ROOT / %ORIG / %% placeholders in a value, producing a shell
 * expression with quoting. Unknown %NAME tokens are preserved literally
 * (backward-compatible fallback).
 */
function expandPlaceholders(value: string, ctx: ExpansionContext): string {
  const SENTINEL = "\x01";
  const expanded = value.replaceAll("%%", SENTINEL);
  const parts: string[] = [];
  let lastEnd = 0;
  const re = /%([A-Z]+)/g;
  let match: RegExpExecArray | null;

  // biome-ignore lint/suspicious/noAssignInExpressions: standard regex exec loop
  while ((match = re.exec(expanded)) !== null) {
    let shellExpr: string | null = null;
    if (match[1] === "ROOT") {
      shellExpr = ctx.rootExpr;
    } else if (match[1] === "ORIG" && ctx.origExpr !== undefined) {
      shellExpr = ctx.origExpr;
    }
    if (shellExpr === null) {
      // Unknown / disabled placeholder — leave literal by NOT advancing lastEnd.
      continue;
    }
    const prefix = expanded.slice(lastEnd, match.index).replaceAll(SENTINEL, "%");
    if (prefix) {
      parts.push(quoteShLiteral(prefix));
    }
    parts.push(`"${shellExpr}"`);
    lastEnd = match.index + match[0].length;
  }

  const suffix = expanded.slice(lastEnd).replaceAll(SENTINEL, "%");
  if (suffix) {
    parts.push(quoteShLiteral(suffix));
  }

  return parts.join("") || "''";
}

/**
 * Produce a POSIX-sh-safe inline word list from addFlags.
 * %ROOT is replaced by the shell expression given as rootExpr (e.g. '$TEMP').
 * %ORIG — when `opts.origExpr` is supplied — is replaced by that expression
 * (typically `$ORIG` in exec context or `\$ORIG` in a heredoc body).
 * Output example: '--verbose' '--config='"$TEMP"'/app.cfg'
 */
export function serializeAddFlagWordsSh(
  addFlags: string[],
  rootExpr: string,
  opts: { origExpr?: string } = {},
): string {
  const ctx: ExpansionContext = { rootExpr, origExpr: opts.origExpr };
  return addFlags.map((flag) => expandPlaceholders(flag, ctx)).join(" ");
}

/**
 * Produce POSIX-sh export lines from env directives.
 * %ROOT is replaced by the shell expression given as rootExpr.
 * %ORIG (when `opts.origExpr` is supplied) is replaced by that expression.
 *
 * Output example for --env-prefix PATH : /extra:
 *   PATH='/extra'"${PATH:+:${PATH}}"
 *   export PATH
 */
export function serializeEnvDirectivesSh(
  directives: EnvDirective[],
  rootExpr: string,
  opts: { heredoc?: boolean; origExpr?: string } = {},
): string {
  const lines: string[] = [];
  const ctx: ExpansionContext = { rootExpr, origExpr: opts.origExpr };
  // When embedded in an unquoted heredoc (<<-EOF), env var references must be
  // escaped with \$ so they expand at wrapper runtime, not at heredoc creation time.
  // The rootExpr (e.g. $TARGET) intentionally remains unescaped to expand in the heredoc.
  const ds = opts.heredoc ? "\\$" : "$";

  for (const d of directives) {
    switch (d.kind) {
      case "set": {
        const valExpr = expandPlaceholders(d.value, ctx);
        lines.push(`${d.name}=${valExpr}`);
        lines.push(`export ${d.name}`);
        break;
      }
      case "prefix": {
        const valExpr = expandPlaceholders(d.value, ctx);
        const sepLiteral = quoteShLiteral(d.sep);
        // No double-quotes around ${:+} — assignment context is safe from word splitting,
        // and single-quoted separator must not be inside double-quotes (they'd be literal).
        lines.push(`${d.name}=${valExpr}${ds}{${d.name}:+${sepLiteral}${ds}{${d.name}}}`);
        lines.push(`export ${d.name}`);
        break;
      }
      case "suffix": {
        const valExpr = expandPlaceholders(d.value, ctx);
        const sepLiteral = quoteShLiteral(d.sep);
        lines.push(`${d.name}=${ds}{${d.name}:+${ds}{${d.name}}${sepLiteral}}${valExpr}`);
        lines.push(`export ${d.name}`);
        break;
      }
    }
  }

  return lines.join("\n");
}

/**
 * Return true iff a string references `%ORIG` as a substitution (not
 * escaped as `%%ORIG`). Shell-template uses this to decide whether to
 * emit the ORIG resolution block in generated scripts.
 */
export function usesOrigPlaceholder(value: string): boolean {
  const sanitized = value.replaceAll("%%", "\x01");
  return /%ORIG(?![A-Z])/.test(sanitized);
}
