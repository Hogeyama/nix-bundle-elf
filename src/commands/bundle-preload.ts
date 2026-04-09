// bundle-preload: Bundle an ELF binary using LD_PRELOAD.

import {
  appendFileSync,
  chmodSync,
  copyFileSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { basename } from "node:path";
import { createTarGz } from "../lib/archive.ts";
import {
  copyIncludes,
  gatherAllDeps,
  INTERP_PLACEHOLDER_LEN,
  isElfBinary,
  parseArgs,
  setPlaceholderInterpreter,
} from "../lib/bundle-common.ts";
import { CLEANUP_ENV_C } from "../lib/cleanup-env-source.ts";
import * as patchelf from "../lib/patchelf.ts";
import { resolveTool } from "../lib/resolve-tool.ts";
import { generateScript } from "../lib/shell-template.ts";

function log(msg: string): void {
  console.error(msg);
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
      const stat = lstatSync(fullPath);
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
    // Write the embedded source to a temp file for gcc.
    const cleanupEnvSrc = `${tmpdir}/cleanup_env.c`;
    writeFileSync(cleanupEnvSrc, CLEANUP_ENV_C);

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
    const script = generateScript({
      name,
      type: "preload",
      binaries: [
        { name, interpreterBasename: deps.interpreterBasename, interpOffset, libDir: "lib" },
      ],
      interpPlaceholderLen: INTERP_PLACEHOLDER_LEN,
      envDirectives: config.envDirectives,
      entry: { kind: "binary", addFlags: config.addFlags },
    });

    // Write output: script + tar
    writeFileSync(config.output, Buffer.from(script));
    const tarContent = readFileSync(tarPath);
    appendFileSync(config.output, tarContent);
    chmodSync(config.output, 0o755);

    log("");
    log(`Done: ${config.output}`);
  } finally {
    Bun.spawnSync(["rm", "-rf", tmpdir]);
  }
}
