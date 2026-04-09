// bundle-script: Bundle a shell script with multiple ELF binaries.

import {
  appendFileSync,
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";
import { createTarGz } from "../lib/archive.ts";
import {
  copyAndPatchLibsNamed,
  copyIncludes,
  gatherAllDeps,
  INTERP_PLACEHOLDER_LEN,
  setPlaceholderInterpreter,
} from "../lib/bundle-common.ts";
import { CLEANUP_ENV_C } from "../lib/cleanup-env-source.ts";
import * as patchelf from "../lib/patchelf.ts";
import { resolveTool } from "../lib/resolve-tool.ts";
import { generateScript } from "../lib/shell-template.ts";
import type { BundleConfig, BundledBinaryInfo, ScriptBundleConfig } from "../lib/types.ts";

function log(msg: string): void {
  console.error(msg);
}

const ENV_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

function validateEnvName(name: string): void {
  if (!ENV_NAME_RE.test(name)) {
    throw new Error(`invalid environment variable name: ${name}`);
  }
}

function printUsage(): void {
  const prog = "nix-bundle-elf";
  console.error(`Usage: ${prog} script [options] <script-file>

Bundle a shell script with multiple ELF binaries into a self-contained package.

Options:
  --bundle-bin <name>:<path>   Add an ELF binary to bundle (repeatable, required)
  --type <rpath|preload>       Bundling strategy (default: rpath)
  -o, --output <path>          Output path (default: ./<script-basename>)
  --include <src>:<dest>       Include a file or directory in the bundle (repeatable)
  --extra-lib <soname>         Bundle a library not in ELF NEEDED (preload only, repeatable)
  --resolve-with <file>        Provide a .so file as fallback when RPATH resolution fails (repeatable)
  --env <name> <value>         Set an environment variable (repeatable, supports %ROOT)
  --env-prefix <name> <sep> <value>  Prepend to an environment variable (repeatable)
  --env-suffix <name> <sep> <value>  Append to an environment variable (repeatable)
  --prefer-pkg <prefix>        Prefer this package prefix in nix-locate resolution (repeatable)
  --no-nix-locate              Disable nix-locate for dependency resolution
  --nix-index-db-ref <ref>     Git ref for nix-index-database
  -h, --help                   Show this help message`);
}

function parseScriptArgs(argv: string[]): ScriptBundleConfig {
  const config: ScriptBundleConfig = {
    scriptPath: "",
    output: "",
    type: "rpath",
    binaries: [],
    useNixLocate: true,
    includes: [],
    extraLibs: [],
    libPaths: [],
    preferPkgs: [],
    envDirectives: [],
  };

  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    switch (arg) {
      case "-h":
      // biome-ignore lint/suspicious/noFallthroughSwitchClause: exits immediately
      case "--help":
        printUsage();
        process.exit(0);
      case "-o":
      case "--output":
        config.output = argv[++i] ?? "";
        if (!config.output) throw new Error("--output requires an argument");
        break;
      case "--type": {
        const t = argv[++i];
        if (t !== "rpath" && t !== "preload") throw new Error(`invalid type: ${t}`);
        config.type = t;
        break;
      }
      case "--no-nix-locate":
        config.useNixLocate = false;
        break;
      case "--bundle-bin": {
        const spec = argv[++i];
        if (spec === undefined) throw new Error("--bundle-bin requires an argument");
        const colonIdx = spec.indexOf(":");
        if (colonIdx === -1) throw new Error(`--bundle-bin format must be name:path, got: ${spec}`);
        const name = spec.slice(0, colonIdx);
        const target = spec.slice(colonIdx + 1);
        if (!name) throw new Error("--bundle-bin name must not be empty");
        if (!target) throw new Error("--bundle-bin path must not be empty");
        config.binaries.push({ name, target });
        break;
      }
      case "--env": {
        const name = argv[++i];
        const value = argv[++i];
        if (name === undefined || value === undefined)
          throw new Error("--env requires two arguments: <name> <value>");
        validateEnvName(name);
        config.envDirectives.push({ kind: "set", name, value });
        break;
      }
      case "--env-prefix": {
        const name = argv[++i];
        const sep = argv[++i];
        const value = argv[++i];
        if (name === undefined || sep === undefined || value === undefined)
          throw new Error("--env-prefix requires three arguments: <name> <sep> <value>");
        validateEnvName(name);
        config.envDirectives.push({ kind: "prefix", name, sep, value });
        break;
      }
      case "--env-suffix": {
        const name = argv[++i];
        const sep = argv[++i];
        const value = argv[++i];
        if (name === undefined || sep === undefined || value === undefined)
          throw new Error("--env-suffix requires three arguments: <name> <sep> <value>");
        validateEnvName(name);
        config.envDirectives.push({ kind: "suffix", name, sep, value });
        break;
      }
      case "--include": {
        const inc = argv[++i];
        if (inc === undefined) throw new Error("--include requires an argument");
        const colonIdx = inc.indexOf(":");
        if (colonIdx === -1) throw new Error(`--include format must be src:dest, got: ${inc}`);
        config.includes.push({ src: inc.slice(0, colonIdx), dest: inc.slice(colonIdx + 1) });
        break;
      }
      case "--extra-lib": {
        const lib = argv[++i];
        if (lib === undefined) throw new Error("--extra-lib requires an argument");
        config.extraLibs.push(lib);
        break;
      }
      case "--resolve-with": {
        const libpath = argv[++i];
        if (libpath === undefined) throw new Error("--resolve-with requires an argument");
        if (!isAbsolute(libpath)) {
          throw new Error(`--resolve-with must be an absolute path: ${libpath}`);
        }
        config.libPaths.push(libpath);
        break;
      }
      case "--prefer-pkg": {
        const pkg = argv[++i];
        if (pkg === undefined) throw new Error("--prefer-pkg requires an argument");
        config.preferPkgs.push(pkg);
        break;
      }
      case "--nix-index-db-ref":
        config.nixIndexDbRef = argv[++i] ?? "";
        if (!config.nixIndexDbRef) throw new Error("--nix-index-db-ref requires an argument");
        break;
      default:
        if (arg.startsWith("-")) throw new Error(`unknown option: ${arg}`);
        if (config.scriptPath) throw new Error(`unexpected argument: ${arg}`);
        config.scriptPath = arg;
    }
    i++;
  }

  if (!config.scriptPath) throw new Error("script file is required");
  if (config.binaries.length === 0) throw new Error("at least one --bundle-bin is required");

  if (config.extraLibs.length > 0 && config.type !== "preload") {
    throw new Error("--extra-lib is only supported with --type preload");
  }

  config.scriptPath = resolve(config.scriptPath);
  if (!existsSync(config.scriptPath))
    throw new Error(`script does not exist: ${config.scriptPath}`);

  // Validate and resolve binary targets
  const seenNames = new Set<string>();
  for (const bin of config.binaries) {
    if (seenNames.has(bin.name)) throw new Error(`duplicate --bundle-bin name: ${bin.name}`);
    seenNames.add(bin.name);
    bin.target = realpathSync(bin.target);
    if (!existsSync(bin.target)) throw new Error(`binary does not exist: ${bin.target}`);
  }

  // Validate includes
  for (const include of config.includes) {
    include.src = realpathSync(include.src);
    const st = statSync(include.src);
    if (!st.isFile() && !st.isDirectory()) {
      throw new Error(`--include source must be a file or directory: ${include.src}`);
    }
    if (include.dest === "") {
      throw new Error("--include destination must not be empty");
    }
  }

  for (const libpath of config.libPaths) {
    if (!existsSync(libpath)) {
      throw new Error(`--resolve-with does not exist: ${libpath}`);
    }
  }

  if (!config.output) {
    config.output = resolve(process.cwd(), basename(config.scriptPath));
  }

  const name = basename(config.output);
  config.output = resolve(dirname(config.output), name);

  if (existsSync(config.output)) {
    throw new Error(
      `Output path '${config.output}' already exists. Use -o to specify a different output path, or remove the existing file first.`,
    );
  }

  return config;
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

export function bundleScript(argv: string[]): void {
  const config = parseScriptArgs(argv);
  const name = basename(config.output);

  // Create workdir
  const tmpdir = `${Bun.env.TMPDIR ?? "/tmp"}/nix-bundle-elf-${process.pid}`;
  mkdirSync(tmpdir, { recursive: true });
  const outDir = `${tmpdir}/out`;
  mkdirSync(`${outDir}/orig`, { recursive: true });

  try {
    const binaryInfos: BundledBinaryInfo[] = [];

    for (const bin of config.binaries) {
      log(`==> Processing binary: ${bin.name}`);

      // Construct a BundleConfig for this binary to reuse gatherAllDeps
      const binConfig: BundleConfig = {
        target: bin.target,
        output: "",
        format: "exe",
        useNixLocate: config.useNixLocate,
        addFlags: [],
        includes: [],
        extraLibs: config.extraLibs,
        libPaths: config.libPaths,
        preferPkgs: config.preferPkgs,
        nixIndexDbRef: config.nixIndexDbRef,
        envDirectives: [],
      };

      const deps = gatherAllDeps(binConfig, tmpdir);

      if (config.type === "rpath") {
        // Copy and patch libs to lib-{name}/
        copyAndPatchLibsNamed(deps.libs, deps.interpreterPath, outDir, bin.name);

        // Copy binary and set RPATH + placeholder interpreter
        const binaryPath = `${outDir}/orig/${bin.name}`;
        copyFileSync(deps.effectiveTarget, binaryPath);
        chmodSync(binaryPath, 0o755);
        patchelf.setRpath(binaryPath, `$ORIGIN/../lib-${bin.name}`);
        const interpOffset = setPlaceholderInterpreter(binaryPath);
        chmodSync(binaryPath, 0o555);

        binaryInfos.push({
          name: bin.name,
          effectiveTarget: deps.effectiveTarget,
          interpreterBasename: deps.interpreterBasename,
          interpreterPath: deps.interpreterPath,
          libs: deps.libs,
          interpOffset,
        });
      } else {
        // preload: copy libs without RPATH on binary, similar to bundle-preload.ts
        const libDir = `${outDir}/lib-${bin.name}`;
        mkdirSync(libDir, { recursive: true });

        // Copy interpreter
        copyFileSync(deps.interpreterPath, `${libDir}/${deps.interpreterBasename}`);

        // Copy libraries
        for (const libfile of deps.libs) {
          if (!libfile) continue;
          copyFileSync(libfile, `${libDir}/${basename(libfile)}`);
        }

        // Patch RUNPATH of bundled libraries so they find siblings
        for (const entry of readdirSync(libDir)) {
          const fullPath = `${libDir}/${entry}`;
          const stat = lstatSync(fullPath);
          if (!stat.isFile()) continue;
          if (/^ld-linux/.test(entry)) continue;
          if (!/\.so/.test(entry)) continue;
          if (!isElfBinary(fullPath)) continue;
          chmodSync(fullPath, 0o755);
          patchelf.setRpath(fullPath, "$ORIGIN");
          chmodSync(fullPath, 0o555);
        }

        // Copy binary (no RPATH patching for preload)
        const binaryPath = `${outDir}/orig/${bin.name}`;
        copyFileSync(deps.effectiveTarget, binaryPath);
        chmodSync(binaryPath, 0o755);
        const interpOffset = setPlaceholderInterpreter(binaryPath);
        chmodSync(binaryPath, 0o555);

        binaryInfos.push({
          name: bin.name,
          effectiveTarget: deps.effectiveTarget,
          interpreterBasename: deps.interpreterBasename,
          interpreterPath: deps.interpreterPath,
          libs: deps.libs,
          interpOffset,
        });
      }
    }

    // Compile cleanup_env.so for preload mode (one copy per lib-{name}/)
    if (config.type === "preload") {
      const cleanupEnvSrc = `${tmpdir}/cleanup_env.c`;
      writeFileSync(cleanupEnvSrc, CLEANUP_ENV_C);
      const gcc = resolveTool("", "gcc", "gcc");

      for (const bin of config.binaries) {
        log(`  Compiling cleanup_env.so for ${bin.name}`);
        const gccResult = Bun.spawnSync([
          gcc,
          "-shared",
          "-fPIC",
          "-O2",
          "-o",
          `${outDir}/lib-${bin.name}/cleanup_env.so`,
          cleanupEnvSrc,
          "-ldl",
        ]);
        if (gccResult.exitCode !== 0) {
          throw new Error(`gcc failed: ${gccResult.stderr.toString().trim()}`);
        }
      }
    }

    // Copy entry script
    copyFileSync(config.scriptPath, `${outDir}/entry.sh`);
    chmodSync(`${outDir}/entry.sh`, 0o755);

    // Copy includes
    copyIncludes(config.includes, outDir);

    // Create tar.gz
    const tarPath = `${tmpdir}/bundle.tar.gz`;
    createTarGz(outDir, tarPath);

    // Generate self-extracting script
    const templateParams = {
      name,
      type: config.type,
      binaries: binaryInfos.map((b) => ({
        name: b.name,
        interpreterBasename: b.interpreterBasename,
        interpOffset: b.interpOffset,
        libDir: `lib-${b.name}`,
      })),
      interpPlaceholderLen: INTERP_PLACEHOLDER_LEN,
      envDirectives: config.envDirectives,
      entry: { kind: "script" as const },
    };

    const script = generateScript(templateParams);

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
