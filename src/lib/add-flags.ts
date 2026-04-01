// Serialize --add-flag values into POSIX-sh-safe inline word lists.
// %ROOT in flag values is replaced with a shell expression (e.g. '$TEMP').
// %% is an escaped literal %.

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
