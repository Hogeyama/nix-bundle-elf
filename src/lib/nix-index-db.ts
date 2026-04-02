// Resolve the nix-index database from nix-community/nix-index-database.
//
// Downloads the database from a GitHub release and resolves the nixpkgs
// revision from the repository's flake.lock at the same tag.

import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

// nix-community/nix-index-database default release tag.
// Update this when bumping to a newer snapshot.
const NIX_INDEX_DB_DEFAULT_TAG = "2026-03-29-050203";

function log(msg: string): void {
  console.error(msg);
}

/** Detect the current system identifier (e.g. "x86_64-linux"). */
function detectSystem(): string {
  const arch =
    process.arch === "x64" ? "x86_64" : process.arch === "arm64" ? "aarch64" : process.arch;
  const os =
    process.platform === "linux"
      ? "linux"
      : process.platform === "darwin"
        ? "darwin"
        : process.platform;
  return `${arch}-${os}`;
}

/** Download a file from a URL to a local path using curl. */
function downloadFile(url: string, dest: string): void {
  mkdirSync(dirname(dest), { recursive: true });
  const tmpDest = `${dest}.tmp.${process.pid}`;
  const result = Bun.spawnSync(["curl", "-fSL", "-o", tmpDest, url]);
  if (result.exitCode !== 0) {
    try {
      require("node:fs").unlinkSync(tmpDest);
    } catch {}
    throw new Error(`Failed to download ${url}: ${result.stderr.toString().trim()}`);
  }
  require("node:fs").renameSync(tmpDest, dest);
}

/** Fetch a URL and return its body as a string. */
function fetchText(url: string): string {
  const result = Bun.spawnSync(["curl", "-fsSL", url]);
  if (result.exitCode !== 0) {
    throw new Error(`Failed to fetch ${url}: ${result.stderr.toString().trim()}`);
  }
  return result.stdout.toString();
}

export interface NixIndexDbInfo {
  /** Directory containing the nix-index 'files' database. */
  dbDir: string;
  /** The nixpkgs revision (commit hash) corresponding to the database. */
  nixpkgsRev: string;
}

/**
 * Resolve the nix-index database and corresponding nixpkgs revision.
 *
 * Downloads the database from nix-community/nix-index-database and reads the
 * nixpkgs revision from the repository's flake.lock at the same tag.
 */
export function resolveNixIndexDb(tagOverride?: string): NixIndexDbInfo {
  const tag = tagOverride ?? NIX_INDEX_DB_DEFAULT_TAG;
  const baseUrl = `https://github.com/nix-community/nix-index-database/releases/download/${tag}`;
  const system = detectSystem();

  // Download the database
  const downloadDir = mkdtempSync(join(tmpdir(), "nix-index-db-"));
  const downloadedFile = `${downloadDir}/files`;
  const url = `${baseUrl}/index-${system}`;

  log(`  Downloading nix-index database (${tag})...`);
  log(`  URL: ${url}`);
  downloadFile(url, downloadedFile);
  log(`  Downloaded to: ${downloadedFile}`);

  // Resolve nixpkgs revision from flake.lock at the same tag
  const flakeLockUrl = `https://raw.githubusercontent.com/nix-community/nix-index-database/${tag}/flake.lock`;
  log(`  Resolving nixpkgs revision from ${tag}...`);
  const flakeLockText = fetchText(flakeLockUrl);
  const flakeLock = JSON.parse(flakeLockText);
  const nixpkgsRev: string | undefined = flakeLock?.nodes?.nixpkgs?.locked?.rev;
  if (!nixpkgsRev) {
    throw new Error(
      `Could not find nixpkgs revision in flake.lock for tag ${tag}. ` +
        `The nix-community/nix-index-database repository format may have changed.`,
    );
  }
  log(`  nixpkgs revision: ${nixpkgsRev}`);

  return { dbDir: downloadDir, nixpkgsRev };
}
