// bundle-preload: Bundle an ELF binary using LD_PRELOAD.

import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname } from "node:path";
import { createTarGz } from "../lib/archive.ts";
import {
  copyIncludes,
  gatherAllDeps,
  INTERP_PLACEHOLDER_LEN,
  parseArgs,
  setPlaceholderInterpreter,
} from "../lib/bundle-common.ts";
import * as patchelf from "../lib/patchelf.ts";
import { resolveTool } from "../lib/resolve-tool.ts";
import { generatePreloadScript } from "../lib/shell-template.ts";

function log(msg: string): void {
  console.error(msg);
}

function isElfBinary(path: string): boolean {
  const magic = readFileSync(path).subarray(0, 4);
  return (
    magic.length === 4 &&
    magic[0] === 0x7f &&
    magic[1] === 0x45 &&
    magic[2] === 0x4c &&
    magic[3] === 0x46
  );
}

export function bundlePreload(argv: string[]): void {
  const config = parseArgs(argv, false);
  const name = basename(config.output);

  // Create workdir
  const tmpdir = `${Bun.env.TMPDIR ?? "/tmp"}/nix-bundle-elf-${process.pid}`;
  mkdirSync(tmpdir, { recursive: true });
  const outDir = `${tmpdir}/out`;
  mkdirSync(`${outDir}/orig`, { recursive: true });
  mkdirSync(`${outDir}/lib`, { recursive: true });

  try {
    // Gather dependencies
    const deps = gatherAllDeps(config, tmpdir);

    // Copy interpreter
    copyFileSync(deps.interpreterPath, `${outDir}/lib/${deps.interpreterBasename}`);

    // Copy libraries (without RPATH patching on the binary itself — preload uses LD_LIBRARY_PATH)
    if (deps.libs.length > 0) {
      // Check if this was a foreign binary resolution (libs come from store paths)
      // For RPATH-resolved deps, copy individual files
      for (const libfile of deps.libs) {
        if (!libfile) continue;
        const libb = basename(libfile);
        copyFileSync(libfile, `${outDir}/lib/${libb}`);
      }
    }

    // Patch RUNPATH of bundled libraries so they find siblings
    log("==> Bundling");
    log("  Patching library RUNPATH");
    const libDir = `${outDir}/lib`;
    for (const entry of readdirSync(libDir)) {
      const fullPath = `${libDir}/${entry}`;
      // Skip symlinks and non-files
      const stat = require("node:fs").lstatSync(fullPath);
      if (!stat.isFile()) continue;
      // Skip the dynamic linker — patchelf corrupts it
      if (/^ld-linux/.test(entry)) continue;
      if (!/\.so/.test(entry)) continue;
      if (!isElfBinary(fullPath)) continue;

      chmodSync(fullPath, 0o755);
      patchelf.setRpath(fullPath, "$ORIGIN");
      chmodSync(fullPath, 0o555);
    }

    // Compile cleanup_env.so
    const scriptDir = dirname(dirname(__dirname));
    const cleanupEnvSrc = `${scriptDir}/cleanup_env.c`;
    if (!existsSync(cleanupEnvSrc)) {
      throw new Error(`cleanup_env.c not found at ${cleanupEnvSrc}`);
    }

    log("  Compiling cleanup_env.so");
    const gcc = resolveTool("", "gcc", "gcc");
    const gccResult = Bun.spawnSync([
      gcc,
      "-shared",
      "-fPIC",
      "-O2",
      "-o",
      `${outDir}/lib/cleanup_env.so`,
      cleanupEnvSrc,
      "-ldl",
    ]);
    if (gccResult.exitCode !== 0) {
      throw new Error(`gcc failed: ${gccResult.stderr.toString().trim()}`);
    }

    // Copy binary and set placeholder interpreter (no --set-rpath for preload)
    copyFileSync(config.target, `${outDir}/orig/${name}`);
    chmodSync(`${outDir}/orig/${name}`, 0o755);

    const interpOffset = setPlaceholderInterpreter(`${outDir}/orig/${name}`);
    chmodSync(`${outDir}/orig/${name}`, 0o555);

    // Copy includes
    copyIncludes(config.includes, outDir);

    // Create tar.gz
    const tarPath = `${tmpdir}/bundle.tar.gz`;
    createTarGz(outDir, tarPath);

    // Generate self-extracting script
    const script = generatePreloadScript({
      name,
      interpBasename: deps.interpreterBasename,
      interpOffset,
      interpPlaceholderLen: INTERP_PLACEHOLDER_LEN,
      addFlags: config.addFlags,
    });

    // Write output: script + tar
    writeFileSync(config.output, Buffer.from(script));
    const tarContent = require("node:fs").readFileSync(tarPath);
    require("node:fs").appendFileSync(config.output, tarContent);
    chmodSync(config.output, 0o755);

    log("");
    log(`Done: ${config.output}`);
  } finally {
    Bun.spawnSync(["rm", "-rf", tmpdir]);
  }
}
