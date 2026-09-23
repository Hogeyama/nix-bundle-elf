// Archive helpers: tar.gz and zip creation.

import { chmodSync, lstatSync, readdirSync } from "node:fs";
import { join } from "node:path";

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

/** Create a tar.gz archive of the contents of srcDir. */
export function createTarGz(srcDir: string, destPath: string): void {
  spawnOrThrow(["tar", "-C", srcDir, "-czf", destPath, "."], "tar failed");
}

/** Create a zip archive of the contents of srcDir. */
export function createZip(srcDir: string, destPath: string): void {
  spawnOrThrow(["zip", "-qr", destPath, "."], `zip failed (cwd: ${srcDir})`);
}
