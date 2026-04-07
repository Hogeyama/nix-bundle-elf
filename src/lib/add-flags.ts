// Serialize --add-flag values into POSIX-sh-safe inline word lists.
// %ROOT in flag values is replaced with a shell expression (e.g. '$TEMP').
// %% is an escaped literal %.

import type { EnvDirective } from "./types.ts";

/** Quote a string as a POSIX sh single-quoted literal. */
export function quoteShLiteral(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

/**
 * Produce a POSIX-sh-safe inline word list from addFlags.
 * %ROOT is replaced by the shell expression given as rootExpr (e.g. '$TEMP').
 * Output example: '--verbose' '--config='"$TEMP"'/app.cfg'
 */
export function serializeAddFlagWordsSh(addFlags: string[], rootExpr: string): string {
  const words: string[] = [];

  for (const flag of addFlags) {
    // Replace %% with a sentinel to preserve literal %
    const SENTINEL = "\x01";
    const expanded = flag.replaceAll("%%", SENTINEL);
    let remaining = expanded;
    let expr = "";

    while (remaining.includes("%ROOT")) {
      const idx = remaining.indexOf("%ROOT");
      const prefix = remaining.slice(0, idx).replaceAll(SENTINEL, "%");
      if (prefix) {
        expr += quoteShLiteral(prefix);
      }
      expr += `"${rootExpr}"`;
      remaining = remaining.slice(idx + 5); // len("%ROOT") = 5
    }

    const suffix = remaining.replaceAll(SENTINEL, "%");
    if (suffix) {
      expr += quoteShLiteral(suffix);
    }

    if (expr === "") {
      expr = "''";
    }

    words.push(expr);
  }

  return words.join(" ");
}

/** Expand %ROOT in a value, producing a shell expression with quoting. */
function expandRootExpr(value: string, rootExpr: string): string {
  const SENTINEL = "\x01";
  const expanded = value.replaceAll("%%", SENTINEL);
  let remaining = expanded;
  let expr = "";

  while (remaining.includes("%ROOT")) {
    const idx = remaining.indexOf("%ROOT");
    const prefix = remaining.slice(0, idx).replaceAll(SENTINEL, "%");
    if (prefix) {
      expr += quoteShLiteral(prefix);
    }
    expr += `"${rootExpr}"`;
    remaining = remaining.slice(idx + 5);
  }

  const suffix = remaining.replaceAll(SENTINEL, "%");
  if (suffix) {
    expr += quoteShLiteral(suffix);
  }

  return expr || "''";
}

/**
 * Produce POSIX-sh export lines from env directives.
 * %ROOT is replaced by the shell expression given as rootExpr.
 *
 * Output example for --env-prefix PATH : /extra:
 *   PATH='/extra'"${PATH:+:${PATH}}"
 *   export PATH
 */
export function serializeEnvDirectivesSh(
  directives: EnvDirective[],
  rootExpr: string,
  opts: { heredoc?: boolean } = {},
): string {
  const lines: string[] = [];
  // When embedded in an unquoted heredoc (<<-EOF), env var references must be
  // escaped with \$ so they expand at wrapper runtime, not at heredoc creation time.
  // The rootExpr (e.g. $TARGET) intentionally remains unescaped to expand in the heredoc.
  const ds = opts.heredoc ? "\\$" : "$";

  for (const d of directives) {
    switch (d.kind) {
      case "set": {
        const valExpr = expandRootExpr(d.value, rootExpr);
        lines.push(`${d.name}=${valExpr}`);
        lines.push(`export ${d.name}`);
        break;
      }
      case "prefix": {
        const valExpr = expandRootExpr(d.value, rootExpr);
        const sepLiteral = quoteShLiteral(d.sep);
        // No double-quotes around ${:+} — assignment context is safe from word splitting,
        // and single-quoted separator must not be inside double-quotes (they'd be literal).
        lines.push(`${d.name}=${valExpr}${ds}{${d.name}:+${sepLiteral}${ds}{${d.name}}}`);
        lines.push(`export ${d.name}`);
        break;
      }
      case "suffix": {
        const valExpr = expandRootExpr(d.value, rootExpr);
        const sepLiteral = quoteShLiteral(d.sep);
        lines.push(`${d.name}=${ds}{${d.name}:+${ds}{${d.name}}${sepLiteral}}${valExpr}`);
        lines.push(`export ${d.name}`);
        break;
      }
    }
  }

  return lines.join("\n");
}
