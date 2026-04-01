// Wrappers around nix CLI commands: nix build, nix-locate, nix-store.

import { resolveTool } from "./resolve-tool.ts";

let nixLocatePath: string | null = null;

function getNixLocate(): string {
  if (nixLocatePath === null) {
    nixLocatePath = resolveTool("", "nix-locate", "nix-index");
  }
  return nixLocatePath;
}

/** Override the nix-locate binary path. */
export function setNixLocatePath(path: string): void {
  nixLocatePath = path;
}

function spawnOrThrow(cmd: string[], errorPrefix: string): string {
  const result = Bun.spawnSync(cmd);
  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString().trim();
    throw new Error(`${errorPrefix}: ${stderr}`);
  }
  return result.stdout.toString().trim();
}

/**
 * Build a nixpkgs attribute and return its store path.
 * Equivalent to: nix build --no-link --print-out-paths "nixpkgs#$attr"
 */
export function nixBuild(attr: string): string {
  return spawnOrThrow(
    ["nix", "build", "--no-link", "--print-out-paths", `nixpkgs#${attr}`],
    `nix build nixpkgs#${attr} failed`,
  );
}

/**
 * Find nixpkgs attribute(s) providing a file path pattern via nix-locate.
 * Returns raw output lines.
 */
export function nixLocate(regex: string): string[] {
  const result = Bun.spawnSync([getNixLocate(), "--minimal", "--at-root", "--regex", regex]);
  // nix-locate returns exit 0 even with no results; non-zero is a real error
  if (result.exitCode !== 0) {
    return [];
  }
  const out = result.stdout.toString().trim();
  if (out === "") return [];
  return out.split("\n");
}

/**
 * Get store path references (runtime dependencies) of a store path.
 * Equivalent to: nix-store -q --references <path>
 */
export function nixStoreReferences(storePath: string): string[] {
  const result = Bun.spawnSync(["nix-store", "-q", "--references", storePath]);
  if (result.exitCode !== 0) {
    return [];
  }
  const out = result.stdout.toString().trim();
  if (out === "") return [];
  return out.split("\n");
}
