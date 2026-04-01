#!/usr/bin/env bun
// Resolve external tool paths.
// Usage: resolve-tool.ts [explicit-path] <command> <nix-package>
//   - If explicit-path is non-empty, use it.
//   - Else if command is found in PATH, use that.
//   - Else create a wrapper that invokes via `nix shell`.

import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export function resolveTool(explicit: string, cmd: string, nixPkg: string): string {
  if (explicit) {
    return explicit;
  }

  const which = spawnSync("command", ["-v", cmd], { shell: true });
  if (which.status === 0) {
    return which.stdout.toString().trim();
  }

  const wrapper = join(mkdtempSync(join(tmpdir(), "resolve-tool-")), cmd);
  writeFileSync(wrapper, `#!/usr/bin/env bash\nexec nix shell nixpkgs#${nixPkg} -c ${cmd} "$@"\n`);
  chmodSync(wrapper, 0o755);
  return wrapper;
}

// CLI mode: print resolved path to stdout
if (import.meta.main) {
  const args = process.argv.slice(2);
  if (args.length < 2 || args.length > 3) {
    console.error("Usage: resolve-tool.ts [explicit-path] <command> <nix-package>");
    process.exit(1);
  }
  const [explicit, cmd, nixPkg] = args.length === 3 ? args : ["", args[0], args[1]];
  console.log(resolveTool(explicit, cmd, nixPkg));
}
