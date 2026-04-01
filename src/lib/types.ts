// Core type definitions for nix-bundle-elf.

/** Configuration for a bundle operation. */
export interface BundleConfig {
  target: string;
  output: string;
  format: "exe" | "lambda"; // rpath only
  useNixLocate: boolean;
  addFlags: string[];
  includes: Array<{ src: string; dest: string }>;
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
