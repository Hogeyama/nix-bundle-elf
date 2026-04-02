// Resolve the nix-index database path.
//
// Priority:
//   1. Explicit path (--nix-index-db flag)
//   2. Local cache at ${XDG_CACHE_HOME:-$HOME/.cache}/nix-index/files
//   3. Auto-download from nix-community/nix-index-database

import { existsSync, mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

// nix-community/nix-index-database latest release.
// Update these when bumping to a newer snapshot.
const NIX_INDEX_DB_TAG = "2026-03-29-050203";
const NIX_INDEX_DB_BASE_URL = `https://github.com/nix-community/nix-index-database/releases/download/${NIX_INDEX_DB_TAG}`;
const NIX_INDEX_DB_SHA256: Record<string, string> = {
  "x86_64-linux": "e82e77f305c2782d232e9535c12aea9c819dd184e5727ca67e34d9f092814cdb",
  "aarch64-linux": "dd87b2db6cfbaa23e20cb84b6d3abb97573191627c26775a9be3c48028254083",
  "x86_64-darwin": "ca60f49ae3d1504cd04378d0ab59f655304d267f6cf3c0f2f8bb25b87a94376e",
  "aarch64-darwin": "83f46345df595889c73eefffe1ecf0ae74ce368f038bf7b0072411015e6ace19",
};

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

/** Return the default nix-index cache directory. */
function defaultCacheDir(): string {
  const xdg = Bun.env.XDG_CACHE_HOME;
  if (xdg) return `${xdg}/nix-index`;
  const home = Bun.env.HOME;
  if (home) return `${home}/.cache/nix-index`;
  return "/tmp/nix-index";
}

/** Download a file from a URL to a local path using curl, then verify SHA-256. */
function downloadFile(url: string, dest: string, expectedSha256: string): void {
  mkdirSync(dirname(dest), { recursive: true });
  const tmpDest = `${dest}.tmp.${process.pid}`;
  const result = Bun.spawnSync(["curl", "-fSL", "-o", tmpDest, url]);
  if (result.exitCode !== 0) {
    try {
      require("node:fs").unlinkSync(tmpDest);
    } catch {}
    throw new Error(`Failed to download ${url}: ${result.stderr.toString().trim()}`);
  }

  const shaResult = Bun.spawnSync(["sha256sum", tmpDest]);
  if (shaResult.exitCode !== 0) {
    try {
      require("node:fs").unlinkSync(tmpDest);
    } catch {}
    throw new Error(`sha256sum failed: ${shaResult.stderr.toString().trim()}`);
  }
  const actualSha256 = shaResult.stdout.toString().trim().split(/\s+/)[0];
  if (actualSha256 !== expectedSha256) {
    try {
      require("node:fs").unlinkSync(tmpDest);
    } catch {}
    throw new Error(
      `SHA-256 mismatch for ${url}:\n  expected: ${expectedSha256}\n  actual:   ${actualSha256}`,
    );
  }

  require("node:fs").renameSync(tmpDest, dest);
}

/**
 * Resolve the nix-index database directory.
 * Returns the directory path to pass to `nix-locate --db`.
 */
export function resolveNixIndexDb(explicitPath?: string): string {
  // 1. Explicit path
  if (explicitPath) {
    if (!existsSync(explicitPath)) {
      throw new Error(`nix-index database not found: ${explicitPath}`);
    }
    // If the user gave a path to the 'files' file itself, use its parent dir
    const stat = require("node:fs").statSync(explicitPath);
    if (stat.isFile()) {
      return dirname(explicitPath);
    }
    // It's a directory — check it contains 'files'
    if (!existsSync(`${explicitPath}/files`)) {
      throw new Error(`nix-index database directory does not contain 'files': ${explicitPath}`);
    }
    return explicitPath;
  }

  // 2. Local cache
  const cacheDir = defaultCacheDir();
  const cacheFile = `${cacheDir}/files`;
  if (existsSync(cacheFile)) {
    log(`  Using nix-index database: ${cacheFile}`);
    return cacheDir;
  }

  // Also check NIX_INDEX_DATABASE env var (nix-locate's own env)
  const envDb = Bun.env.NIX_INDEX_DATABASE;
  if (envDb && existsSync(`${envDb}/files`)) {
    log(`  Using nix-index database: ${envDb}/files`);
    return envDb;
  }

  // 3. Auto-download from nix-community/nix-index-database to a temp directory
  const system = detectSystem();
  const expectedSha256 = NIX_INDEX_DB_SHA256[system];
  if (!expectedSha256) {
    throw new Error(`No nix-index database available for system: ${system}`);
  }

  const downloadDir = mkdtempSync(join(tmpdir(), "nix-index-db-"));
  const downloadedFile = `${downloadDir}/files`;

  const url = `${NIX_INDEX_DB_BASE_URL}/index-${system}`;
  log(
    `  nix-index database not found locally, downloading from nix-community/nix-index-database...`,
  );
  log(`  URL: ${url}`);

  downloadFile(url, downloadedFile, expectedSha256);
  log(`  Downloaded to: ${downloadedFile}`);

  return downloadDir;
}
