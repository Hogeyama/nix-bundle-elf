// bundle-rpath: Bundle an ELF binary using RPATH rewriting.

import { chmodSync, copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { createTarGz } from "../lib/archive.ts";
import {
  copyAndPatchLibs,
  copyIncludes,
  gatherAllDeps,
  INTERP_PLACEHOLDER_LEN,
  parseArgs,
  setPlaceholderInterpreter,
} from "../lib/bundle-common.ts";
import * as patchelf from "../lib/patchelf.ts";
import { generateRpathScript } from "../lib/shell-template.ts";

function log(msg: string): void {
  console.error(msg);
}

export function bundleRpath(argv: string[]): void {
  const config = parseArgs(argv, true);
  const name = basename(config.output);

  // Create workdir
  const tmpdir = `${Bun.env.TMPDIR ?? "/tmp"}/nix-bundle-elf-${process.pid}`;
  mkdirSync(tmpdir, { recursive: true });
  const outDir = `${tmpdir}/out`;
  mkdirSync(outDir, { recursive: true });

  try {
    // Gather dependencies
    const deps = gatherAllDeps(config, tmpdir);

    // Copy and patch libs
    copyAndPatchLibs(deps.libs, deps.interpreterPath, outDir);

    // Copy includes
    copyIncludes(config.includes, outDir);

    if (config.format === "lambda") {
      if (config.addFlags.length > 0) {
        throw new Error("--add-flag is not supported with lambda format");
      }
      bundleLambda(deps.effectiveTarget, deps.interpreterBasename, outDir, config.output);
    } else {
      bundleExe(deps.effectiveTarget, name, deps.interpreterBasename, outDir, tmpdir, config);
    }

    log("");
    log(`Done: ${config.output}`);
  } finally {
    // Cleanup
    Bun.spawnSync(["rm", "-rf", tmpdir]);
  }
}

function bundleExe(
  target: string,
  name: string,
  interpreterBasename: string,
  outDir: string,
  tmpdir: string,
  config: { output: string; addFlags: string[] },
): void {
  // Copy binary and set RPATH + placeholder interpreter
  const origDir = `${outDir}/orig`;
  mkdirSync(origDir, { recursive: true });
  const binaryPath = `${origDir}/${name}`;
  copyFileSync(target, binaryPath);
  chmodSync(binaryPath, 0o755);

  patchelf.setRpath(binaryPath, "$ORIGIN/../lib");
  const interpOffset = setPlaceholderInterpreter(binaryPath);
  chmodSync(binaryPath, 0o555);

  // Create tar.gz
  const tarPath = `${tmpdir}/bundle.tar.gz`;
  createTarGz(outDir, tarPath);

  // Generate self-extracting script
  const script = generateRpathScript({
    name,
    interpreterBasename,
    interpOffset,
    interpPlaceholderLen: INTERP_PLACEHOLDER_LEN,
    addFlags: config.addFlags,
  });

  // Concatenate script + tar
  writeFileSync(config.output, Buffer.from(script));
  const tarContent = require("node:fs").readFileSync(tarPath);
  require("node:fs").appendFileSync(config.output, tarContent);
  chmodSync(config.output, 0o755);
}

function bundleLambda(
  target: string,
  interpreterBasename: string,
  outDir: string,
  output: string,
): void {
  // Copy as bootstrap
  copyFileSync(target, `${outDir}/bootstrap`);
  chmodSync(`${outDir}/bootstrap`, 0o755);
  patchelf.setInterpreter(`${outDir}/bootstrap`, `./lib/${interpreterBasename}`);
  patchelf.setRpath(`${outDir}/bootstrap`, "./lib");
  chmodSync(`${outDir}/bootstrap`, 0o555);

  // Create zip (strip .zip suffix if present — zip adds it automatically)
  const zipBase = output.replace(/\.zip$/, "");
  const result = Bun.spawnSync(["zip", "-qr", zipBase, "."], { cwd: outDir });
  if (result.exitCode !== 0) {
    throw new Error(`zip failed: ${result.stderr.toString().trim()}`);
  }
}
