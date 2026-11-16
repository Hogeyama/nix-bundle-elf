import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createTarGz, createZip, makeBundleDirectoriesWritable, normalizeMode } from "./archive.ts";

test("createTarGz is byte-identical regardless of mtime and creation order", () => {
  const root = mkdtempSync(join(tmpdir(), "bundle-archive-"));
  try {
    const build = (dir: string, names: string[], mtime: number): Buffer => {
      mkdirSync(join(root, dir, "lib"), { recursive: true });
      for (const name of names) writeFileSync(join(root, dir, "lib", name), name);
      for (const path of [...names.map((n) => join("lib", n)), "lib", "."])
        utimesSync(join(root, dir, path), mtime, mtime);
      const archive = join(root, `${dir}.tar.gz`);
      createTarGz(join(root, dir), archive);
      return readFileSync(archive);
    };
    const a = build("a", ["libx.so", "liba.so", "libm.so"], 1_000_000);
    const b = build("b", ["libm.so", "libx.so", "liba.so"], 2_000_000);
    expect(a.equals(b)).toBe(true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test.skipIf(!Bun.which("zip"))(
  "createZip is byte-identical regardless of mtime, creation order and symlink targets",
  () => {
    const root = mkdtempSync(join(tmpdir(), "bundle-archive-"));
    try {
      const build = (dir: string, names: string[], mtime: number): Buffer => {
        mkdirSync(join(root, dir, "lib"), { recursive: true });
        for (const name of names) writeFileSync(join(root, dir, "lib", name), name);
        // A symlink leaving the tree: zip follows it and would record the target's mtime.
        const outside = join(root, `${dir}-outside`);
        writeFileSync(outside, "outside");
        utimesSync(outside, mtime, mtime);
        symlinkSync(outside, join(root, dir, "link"));
        for (const path of [...names.map((n) => join("lib", n)), "lib", "."])
          utimesSync(join(root, dir, path), mtime, mtime);
        const archive = join(root, `${dir}.zip`);
        createZip(join(root, dir), archive);
        return readFileSync(archive);
      };
      const a = build("a", ["libx.so", "liba.so", "libm.so"], 1_000_000_000);
      const b = build("b", ["libm.so", "libx.so", "liba.so"], 1_500_000_000);
      expect(a.equals(b)).toBe(true);
      const list = Bun.spawnSync(["unzip", "-Z1", join(root, "a.zip")]);
      if (list.exitCode === 0)
        expect(list.stdout.toString().trim().split("\n")).toEqual([
          "lib/",
          "lib/liba.so",
          "lib/libm.so",
          "lib/libx.so",
          "link",
        ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  },
);

test("normalizeMode derives group/other from owner and drops special bits", () => {
  expect(normalizeMode(0o40700)).toBe(0o755);
  expect(normalizeMode(0o600)).toBe(0o644);
  expect(normalizeMode(0o555)).toBe(0o555);
  expect(normalizeMode(0o400)).toBe(0o444);
  expect(normalizeMode(0o2775)).toBe(0o755);
  expect(normalizeMode(0o4755)).toBe(0o755);
});

describe("archives do not depend on umask-derived permissions", () => {
  // Same owner bits, different group/other bits and an inherited setgid dir.
  const build = (root: string, dir: string, loose: boolean): string => {
    const base = join(root, dir);
    mkdirSync(join(base, "lib"), { recursive: true });
    writeFileSync(join(base, "lib", "libx.so"), "x");
    writeFileSync(join(base, "data"), "d");
    chmodSync(join(base, "lib", "libx.so"), loose ? 0o775 : 0o700);
    chmodSync(join(base, "data"), loose ? 0o664 : 0o600);
    chmodSync(join(base, "lib"), loose ? 0o2775 : 0o700);
    chmodSync(base, loose ? 0o775 : 0o700);
    return base;
  };
  const cases: [string, (src: string, dest: string) => void, boolean][] = [
    ["tar.gz", createTarGz, true],
    ["zip", createZip, Boolean(Bun.which("zip"))],
  ];
  for (const [ext, create, available] of cases) {
    test.skipIf(!available)(ext, () => {
      const root = mkdtempSync(join(tmpdir(), "bundle-archive-"));
      try {
        const [a, b] = [build(root, "a", false), build(root, "b", true)];
        create(a, `${a}.${ext}`);
        create(b, `${b}.${ext}`);
        expect(readFileSync(`${a}.${ext}`).equals(readFileSync(`${b}.${ext}`))).toBe(true);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    });
  }
});

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
    // Bun's cpSync does not preserve directory modes, so force the copied
    // assets read-only to mirror a nix-store-style payload.
    chmodSync(join(copied, "assets"), 0o555);
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
    if (existsSync(copied)) makeBundleDirectoriesWritable(copied);
    if (existsSync(extracted)) makeBundleDirectoriesWritable(extracted);
    rmSync(root, { recursive: true, force: true });
  }
});
