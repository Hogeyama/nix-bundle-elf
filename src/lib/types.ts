// Core type definitions for nix-bundle-elf.

/** A directive to manipulate an environment variable at runtime. */
export type EnvDirective =
  | { kind: "set"; name: string; value: string }
  | { kind: "prefix"; name: string; sep: string; value: string }
  | { kind: "suffix"; name: string; sep: string; value: string };

/** Configuration for a bundle operation. */
export interface BundleConfig {
  target: string;
  output: string;
  format: "exe" | "lambda"; // rpath only
  useNixLocate: boolean;
  addFlags: string[];
  includes: Array<{ src: string; dest: string }>;
  /** Extra library sonames to resolve alongside NEEDED entries (e.g. libutil.so.1). */
  extraLibs: string[];
  /** Additional library file paths for dependency resolution (searched after RPATH). */
  libPaths: string[];
  /** Additional preferred package prefixes for nix-locate resolution. */
  preferPkgs: string[];
  /** nix-community/nix-index-database release tag override (e.g. "2026-03-15-045700"). */
  nixIndexDbRef?: string;
  /** Environment variable directives (set, prefix, suffix). */
  envDirectives: EnvDirective[];
}

/** A binary to include in a script bundle. */
export interface BundleBinary {
  /** Logical name for the binary (used in bin/ wrapper and lib-{name}/ directory). */
  name: string;
  /** Absolute path to the ELF binary to bundle. */
  target: string;
}

/** Per-binary gathered dependency info for script bundles. */
export interface BundledBinaryInfo {
  name: string;
  /** The effective target path (may be patched copy). */
  effectiveTarget: string;
  /** Interpreter basename (e.g. ld-linux-x86-64.so.2). */
  interpreterBasename: string;
  /** Full path to interpreter. */
  interpreterPath: string;
  /** Absolute paths to library files. */
  libs: string[];
  /** Byte offset of interpreter placeholder in the bundled binary. */
  interpOffset: number;
}

/** Configuration for a script bundle operation. */
export interface ScriptBundleConfig {
  /** Path to the user's entry shell script. */
  scriptPath: string;
  /** Output path for the self-extracting bundle. */
  output: string;
  /** Bundling strategy for all binaries. */
  type: "rpath" | "preload";
  /** Binaries to bundle. */
  binaries: BundleBinary[];
  useNixLocate: boolean;
  includes: Array<{ src: string; dest: string }>;
  /** Extra library sonames to resolve alongside NEEDED entries (preload only). */
  extraLibs: string[];
  /** Additional library file paths for dependency resolution. */
  libPaths: string[];
  /** Additional preferred package prefixes for nix-locate resolution. */
  preferPkgs: string[];
  /** nix-community/nix-index-database release tag override. */
  nixIndexDbRef?: string;
  /** Environment variable directives (set, prefix, suffix). */
  envDirectives: EnvDirective[];
}

/** Result of gathering shared library dependencies via RPATH/NEEDED traversal. */
export interface GatherResult {
  /** Absolute paths to shared libraries. */
  libs: string[];
}

/** Result of scanning a binary's dynamic dependencies. */
export interface ScanResult {
  /** Library sonames (e.g. libfoo.so.1). */
  needed: string[];
  /** Interpreter soname if ld-linux was in NEEDED, or null. */
  interpNeeded: string | null;
}

/** Result of resolving needed libraries to nixpkgs attributes via nix-locate. */
export interface ResolveResult {
  /** Map from library soname to nixpkgs attribute. */
  libToAttr: Map<string, string>;
  /** nixpkgs attribute for the interpreter, or null. */
  interpAttr: string | null;
  /** Libraries that could not be resolved. */
  notFound: string[];
}

/** Result of building nixpkgs attributes. */
export interface BuildResult {
  /** Map from nixpkgs attribute to /nix/store path. */
  attrToStorePath: Map<string, string>;
}

/** Information about the resolved dynamic linker. */
export interface InterpreterInfo {
  /** Full path to ld-linux (e.g. /nix/store/.../lib/ld-linux-x86-64.so.2). */
  path: string;
  /** Basename (e.g. ld-linux-x86-64.so.2). */
  basename: string;
  /** Extra glibc store path found via strategy 3, or null. */
  extraStorePath: string | null;
}
