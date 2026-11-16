// Archive helpers: tar.gz and zip creation.

import {
  chmodSync,
  cpSync,
  lstatSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  utimesSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

/** Ensure extracted bundle directories can be cleaned up by their owner. */
export function makeBundleDirectoriesWritable(directory: string): void {
  const stat = lstatSync(directory);
  if (!stat.isDirectory()) return;
  chmodSync(directory, (stat.mode & 0o777) | 0o700);
  for (const child of readdirSync(directory)) makeBundleDirectoriesWritable(join(directory, child));
}

function spawnOrThrow(cmd: string[], errorPrefix: string): void {
  const result = Bun.spawnSync(cmd);
  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString().trim();
    throw new Error(`${errorPrefix}: ${stderr}`);
  }
}

/** Timestamp stamped on archive entries: SOURCE_DATE_EPOCH if set, else the Unix epoch. */
function archiveEpoch(): string {
  const env = process.env.SOURCE_DATE_EPOCH;
  return env && /^\d+$/.test(env) ? env : "0";
}

/**
 * Permission normalization applied to archive entries, independent of umask:
 * group/other bits mirror the owner's minus write (rwx → 755, rw- → 644,
 * r-x → 555), and setuid/setgid/sticky (e.g. inherited setgid dirs) are cleared.
 */
const TAR_MODE = "go=u,go-w,ug-s,-t";

/** Numeric equivalent of TAR_MODE. */
export function normalizeMode(mode: number): number {
  const owner = (mode >> 6) & 0o7;
  const rest = owner & 0o5;
  return (owner << 6) | (rest << 3) | rest;
}

/**
 * Create a reproducible tar.gz archive of the contents of srcDir.
 * Entry order, timestamps, permissions and ownership are normalized, and gzip
 * omits its own name/mtime header, so identical inputs yield byte-identical archives.
 */
export function createTarGz(srcDir: string, destPath: string): void {
  spawnOrThrow(
    [
      "tar",
      "-C",
      srcDir,
      "--sort=name",
      `--mtime=@${archiveEpoch()}`,
      "--owner=0",
      "--group=0",
      "--numeric-owner",
      `--mode=${TAR_MODE}`,
      "--format=gnu",
      "--use-compress-program=gzip -n",
      "-cf",
      destPath,
      ".",
    ],
    "tar failed",
  );
}

/** Earliest timestamp a zip (MS-DOS) date can represent: 1980-01-01T00:00:00Z. */
const ZIP_MIN_EPOCH = 315532800;

/** List every path under root (relative, depth-first), sorted for a stable order. */
function listTree(root: string, prefix = ""): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(join(root, prefix)).sort()) {
    const rel = prefix ? `${prefix}/${entry}` : entry;
    out.push(rel);
    if (lstatSync(join(root, rel)).isDirectory()) out.push(...listTree(root, rel));
  }
  return out;
}

/**
 * Create a reproducible zip archive of the contents of srcDir.
 * Symlinks are dereferenced (as `zip -r` would) into a staging copy so every
 * entry's timestamp and permissions can be normalized; entries are added in sorted order
 * without extra attributes (uid/gid, extended timestamps), and the DOS-local
 * time is computed in UTC.
 */
export function createZip(srcDir: string, destPath: string): void {
  const dest = resolve(destPath);
  const stage = mkdtempSync(join(Bun.env.TMPDIR ?? tmpdir(), "nix-bundle-elf-zip-"));
  try {
    cpSync(srcDir, stage, { recursive: true, dereference: true });
    const epoch = Math.max(Number(archiveEpoch()), ZIP_MIN_EPOCH);
    const entries = listTree(stage);
    for (const rel of entries) {
      const path = join(stage, rel);
      chmodSync(path, normalizeMode(lstatSync(path).mode));
      utimesSync(path, epoch, epoch);
    }
    const result = Bun.spawnSync(["zip", "-q", "-X", "-@", dest], {
      cwd: stage,
      env: { ...process.env, TZ: "UTC" },
      stdin: Buffer.from(entries.map((e) => `${e}\n`).join("")),
    });
    if (result.exitCode !== 0) {
      throw new Error(`zip failed: ${result.stderr.toString().trim()}`);
    }
  } finally {
    makeBundleDirectoriesWritable(stage);
    rmSync(stage, { recursive: true, force: true });
  }
}
