import { describe, expect, test } from "bun:test";
import type { BinaryInfo, TemplateParams } from "./shell-template.ts";
import { generateScript } from "./shell-template.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeBinaryInfo(overrides: Partial<BinaryInfo> = {}): BinaryInfo {
  return {
    name: "myapp",
    interpreterBasename: "ld-linux-x86-64.so.2",
    interpOffset: 1024,
    libDir: "lib",
    ...overrides,
  };
}

function makeParams(overrides: Partial<TemplateParams> = {}): TemplateParams {
  return {
    name: "myapp",
    type: "rpath",
    binaries: [makeBinaryInfo()],
    interpPlaceholderLen: 256,
    envDirectives: [],
    entry: { kind: "binary", addFlags: [] },
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// generateScript — structural tests
// ---------------------------------------------------------------------------

describe("generateScript", () => {
  test("starts with shebang", () => {
    const script = generateScript(makeParams());
    expect(script.startsWith("#!/bin/sh\n")).toBe(true);
  });

  test("contains set -u", () => {
    const script = generateScript(makeParams());
    expect(script).toContain("set -u");
  });

  test("ends with #START_OF_TAR# followed by newline", () => {
    const script = generateScript(makeParams());
    expect(script.endsWith("#START_OF_TAR#\n")).toBe(true);
  });

  test("contains patch_interp function", () => {
    const script = generateScript(makeParams());
    expect(script).toContain("patch_interp()");
    expect(script).toContain("dd if=/dev/zero");
  });

  test("contains placeholder length in patch function", () => {
    const script = generateScript(makeParams({ interpPlaceholderLen: 512 }));
    expect(script).toContain("512");
  });

  test("contains extract mode handling", () => {
    const script = generateScript(makeParams());
    expect(script).toContain("--extract");
    expect(script).toContain("tar -C");
  });

  test("contains cleanup trap", () => {
    const script = generateScript(makeParams());
    expect(script).toContain("trap 'rm -rf \"$TEMP\"' EXIT");
  });

  test("creates temp directory with bundle name", () => {
    const script = generateScript(makeParams({ name: "hello-world" }));
    expect(script).toContain("'hello-world'");
  });

  // ---------------------------------------------------------------------------
  // rpath binary mode
  // ---------------------------------------------------------------------------

  test("rpath binary: exec line without LD_PRELOAD", () => {
    const script = generateScript(makeParams({ type: "rpath" }));
    expect(script).not.toContain("LD_PRELOAD");
    expect(script).not.toContain("LD_LIBRARY_PATH");
    // In run mode, rpath calls binary directly (no LD_ prefix)
    expect(script).toContain("\"$TEMP/orig/\"'myapp'");
  });

  // ---------------------------------------------------------------------------
  // preload binary mode
  // ---------------------------------------------------------------------------

  test("preload binary: exec line with LD_PRELOAD and LD_LIBRARY_PATH", () => {
    const script = generateScript(makeParams({ type: "preload" }));
    expect(script).toContain("LD_PRELOAD");
    expect(script).toContain("LD_LIBRARY_PATH");
    expect(script).toContain("cleanup_env.so");
  });

  // ---------------------------------------------------------------------------
  // script entry mode
  // ---------------------------------------------------------------------------

  test("script entry: generates per-binary wrappers", () => {
    const binaries = [
      makeBinaryInfo({ name: "tool1", libDir: "lib-tool1" }),
      makeBinaryInfo({ name: "tool2", libDir: "lib-tool2" }),
    ];
    const script = generateScript(
      makeParams({
        binaries,
        entry: { kind: "script" },
      }),
    );
    expect(script).toContain("'tool1'");
    expect(script).toContain("'tool2'");
    expect(script).toContain("entry.sh");
  });

  test("script entry with preload: per-binary LD_PRELOAD wrappers", () => {
    const binaries = [
      makeBinaryInfo({ name: "a", libDir: "lib-a" }),
      makeBinaryInfo({ name: "b", libDir: "lib-b" }),
    ];
    const script = generateScript(
      makeParams({
        type: "preload",
        binaries,
        entry: { kind: "script" },
      }),
    );
    expect(script).toContain("LD_PRELOAD");
    expect(script).toContain("'lib-a'");
    expect(script).toContain("'lib-b'");
  });

  // ---------------------------------------------------------------------------
  // addFlags
  // ---------------------------------------------------------------------------

  test("binary with addFlags includes flags in exec line", () => {
    const script = generateScript(
      makeParams({
        entry: { kind: "binary", addFlags: ["--verbose", "--config=%ROOT/app.cfg"] },
      }),
    );
    expect(script).toContain("'--verbose'");
    expect(script).toContain("'/app.cfg'");
  });

  // ---------------------------------------------------------------------------
  // env directives
  // ---------------------------------------------------------------------------

  test("env set directive in exec block", () => {
    const script = generateScript(
      makeParams({
        envDirectives: [{ kind: "set", name: "MY_VAR", value: "hello" }],
      }),
    );
    expect(script).toContain("MY_VAR='hello'");
    expect(script).toContain("export MY_VAR");
  });

  test("env prefix directive", () => {
    const script = generateScript(
      makeParams({
        envDirectives: [{ kind: "prefix", name: "PATH", sep: ":", value: "%ROOT/bin" }],
      }),
    );
    expect(script).toContain("PATH=");
    expect(script).toContain("export PATH");
  });

  test("env suffix directive", () => {
    const script = generateScript(
      makeParams({
        envDirectives: [{ kind: "suffix", name: "PATH", sep: ":", value: "%ROOT/extra" }],
      }),
    );
    expect(script).toContain("PATH=");
    expect(script).toContain("export PATH");
  });

  // ---------------------------------------------------------------------------
  // patch_interp calls for all binaries
  // ---------------------------------------------------------------------------

  test("generates patch_interp call for each binary", () => {
    const binaries = [
      makeBinaryInfo({ name: "bin1", interpOffset: 100 }),
      makeBinaryInfo({ name: "bin2", interpOffset: 200 }),
    ];
    const script = generateScript(makeParams({ binaries, entry: { kind: "script" } }));
    expect(script).toContain("100");
    expect(script).toContain("200");
    expect(script).toContain("'bin1'");
    expect(script).toContain("'bin2'");
  });

  // ---------------------------------------------------------------------------
  // special characters in names
  // ---------------------------------------------------------------------------

  test("handles special characters in bundle name", () => {
    const script = generateScript(makeParams({ name: "my-app.v2" }));
    expect(script).toContain("'my-app.v2'");
  });

  test("handles special characters in binary name", () => {
    const script = generateScript(
      makeParams({
        binaries: [makeBinaryInfo({ name: "my-tool" })],
      }),
    );
    expect(script).toContain("'my-tool'");
  });
});
