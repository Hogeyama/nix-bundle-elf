import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { digest, type FileOrigins, recordFile, recordInclude } from "./provenance.ts";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});
test("records the original bytes before a copied ELF is changed", () => {
  const root = mkdtempSync(join(tmpdir(), "bundle-provenance-"));
  roots.push(root);
  const source = join(root, "original");
  writeFileSync(source, "original bytes");
  const origins: FileOrigins = {};
  recordFile(origins, "orig/program", source, ["set-interpreter-on-extraction"]);
  writeFileSync(source, "later bytes");
  expect(origins["orig/program"].sourceSha256).toBe(digest("original bytes"));
  expect(origins["orig/program"].source).toBe(source);
});
test("records included nested files and resolves source symlinks", () => {
  const root = mkdtempSync(join(tmpdir(), "bundle-provenance-"));
  roots.push(root);
  const dir = join(root, "assets");
  mkdirSync(dir);
  mkdirSync(join(dir, "sub"));
  writeFileSync(join(dir, "sub", "file"), "payload");
  symlinkSync(join(dir, "sub", "file"), join(dir, "alias"));
  const origins: FileOrigins = {};
  recordInclude(origins, "share/assets", dir);
  expect(Object.keys(origins).sort()).toEqual(["share/assets/alias", "share/assets/sub/file"]);
  expect(origins["share/assets/alias"].sourceSha256).toBe(digest("payload"));
});
