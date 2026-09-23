import { expect, test } from "bun:test";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createTarGz, makeBundleDirectoriesWritable } from "./archive.ts";

test("read-only copied assets extract into owner-writable directories for cleanup", () => {
  const root = mkdtempSync(join(tmpdir(), "bundle-archive-"));
  const source = join(root, "source");
  const outside = join(root, "outside");
  const copied = join(root, "copied");
  const extracted = join(root, "extracted");
  try {
    mkdirSync(join(source, "assets"), { recursive: true });
    mkdirSync(outside);
    writeFileSync(join(source, "assets", "notice"), "license text");
    symlinkSync(outside, join(source, "assets", "external"));
    chmodSync(join(source, "assets"), 0o555);
    chmodSync(outside, 0o555);

    cpSync(source, copied, { recursive: true });
    expect(statSync(join(copied, "assets")).mode & 0o200).toBe(0);
    makeBundleDirectoriesWritable(copied);
    expect(statSync(outside).mode & 0o200).toBe(0);

    const archive = join(root, "payload.tar.gz");
    createTarGz(copied, archive);
    mkdirSync(extracted);
    const unpack = Bun.spawnSync(["tar", "-C", extracted, "-xzf", archive]);
    expect(unpack.exitCode).toBe(0);
    expect(statSync(join(extracted, "assets")).mode & 0o200).toBeGreaterThan(0);
    const cleanup = Bun.spawnSync(["rm", "-rf", extracted]);
    expect(cleanup.exitCode).toBe(0);
    expect(existsSync(extracted)).toBe(false);
  } finally {
    chmodSync(join(source, "assets"), 0o755);
    chmodSync(outside, 0o755);
    if (existsSync(extracted)) makeBundleDirectoriesWritable(extracted);
    rmSync(root, { recursive: true, force: true });
  }
});
