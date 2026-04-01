#!/usr/bin/env bun
// Gather shared libraries by walking NEEDED + RPATH (BFS).
//
// Usage as CLI (for testing):
//   gather-nix-deps.ts <binary> [interpreter-basename]
// Prints one library path per line.

import { existsSync } from "node:fs";
import { basename } from "node:path";
import { printInterpreter, printNeeded, printRpath } from "./patchelf.ts";
import type { GatherResult } from "./types.ts";

/**
 * Recursively gather shared library dependencies by traversing NEEDED and RPATH.
 * Returns null if any library cannot be resolved (caller should fall back to nix-locate).
 */
export function gatherDeps(target: string, interpreterBasename: string): GatherResult | null {
  const visited = new Set<string>();
  const queue: string[] = [target];

  while (queue.length > 0) {
    const current = queue.shift() as string;
    if (visited.has(current)) continue;
    visited.add(current);

    const needed = printNeeded(current);
    const currentRpaths = printRpath(current);

    for (const libname of needed) {
      if (libname === interpreterBasename) continue;

      let found: string | null = null;
      for (const rp of currentRpaths) {
        const candidate = `${rp}/${libname}`;
        if (existsSync(candidate)) {
          found = candidate;
          break;
        }
      }

      if (found === null) {
        if (/^libc\.so\./.test(libname)) {
          // probably bootstrap case — skip
          continue;
        }
        console.error(`Notice: could not resolve ${libname} from RPATH/RUNPATH for ${current}`);
        return null;
      }

      queue.push(found);
    }
  }

  // Remove the original binary from the result
  visited.delete(target);
  return { libs: [...visited] };
}

// CLI mode
if (import.meta.main) {
  const args = process.argv.slice(2);
  if (args.length < 1 || args.length > 2) {
    console.error("Usage: gather-nix-deps.ts <binary> [interpreter-basename]");
    process.exit(1);
  }

  const [target, interpBasename] = args;
  const interp = interpBasename ?? basename(printInterpreter(target));
  const result = gatherDeps(target, interp);

  if (result === null) {
    console.error("Error: could not resolve all dependencies from RPATH");
    process.exit(1);
  }

  for (const lib of result.libs) {
    console.log(lib);
  }
}
