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
// Golden tests — each snapshot captures the full generated script so that
// any behavioural change is immediately visible in the diff.
// ---------------------------------------------------------------------------

describe("generateScript", () => {
  test("rpath binary", () => {
    expect(generateScript(makeParams())).toMatchSnapshot();
  });

  test("preload binary", () => {
    expect(generateScript(makeParams({ type: "preload" }))).toMatchSnapshot();
  });

  test("rpath script with multiple binaries", () => {
    const binaries = [
      makeBinaryInfo({ name: "tool1", libDir: "lib-tool1", interpOffset: 100 }),
      makeBinaryInfo({ name: "tool2", libDir: "lib-tool2", interpOffset: 200 }),
    ];
    expect(generateScript(makeParams({ binaries, entry: { kind: "script" } }))).toMatchSnapshot();
  });

  test("preload script with multiple binaries", () => {
    const binaries = [
      makeBinaryInfo({ name: "alpha", libDir: "lib-alpha", interpOffset: 300 }),
      makeBinaryInfo({ name: "beta", libDir: "lib-beta", interpOffset: 400 }),
    ];
    expect(
      generateScript(makeParams({ type: "preload", binaries, entry: { kind: "script" } })),
    ).toMatchSnapshot();
  });

  test("binary with addFlags", () => {
    expect(
      generateScript(
        makeParams({
          entry: { kind: "binary", addFlags: ["--verbose", "--config=%ROOT/app.cfg"] },
        }),
      ),
    ).toMatchSnapshot();
  });

  test("env directives (set, prefix, suffix)", () => {
    expect(
      generateScript(
        makeParams({
          envDirectives: [
            { kind: "set", name: "MY_VAR", value: "hello" },
            { kind: "prefix", name: "PATH", sep: ":", value: "%ROOT/bin" },
            { kind: "suffix", name: "LD_LIBRARY_PATH", sep: ":", value: "%ROOT/lib" },
          ],
        }),
      ),
    ).toMatchSnapshot();
  });

  test("custom interpPlaceholderLen", () => {
    expect(generateScript(makeParams({ interpPlaceholderLen: 512 }))).toMatchSnapshot();
  });

  test("env directive with %ORIG injects ORIG resolution block", () => {
    const script = generateScript(
      makeParams({
        envDirectives: [{ kind: "set", name: "NAS_BIN_PATH", value: "%ORIG" }],
      }),
    );
    // Main-script ORIG resolution (unescaped) must be present.
    expect(script).toContain('case "$0" in');
    expect(script).toContain("ORIG=$0");
    // Exec-mode env export references $ORIG at script runtime.
    expect(script).toContain('NAS_BIN_PATH="$ORIG"');
    // Extract-mode wrapper heredoc must also capture ORIG for the generated
    // wrapper itself (via escaped $0 references).
    expect(script).toContain('case "\\$0" in');
    expect(script).toContain('NAS_BIN_PATH="\\$ORIG"');
  });

  test("env directive without %ORIG does NOT inject ORIG resolution block", () => {
    const script = generateScript(
      makeParams({
        envDirectives: [{ kind: "set", name: "FOO", value: "bar" }],
      }),
    );
    expect(script).not.toContain("ORIG=");
    expect(script).not.toContain('case "$0" in');
  });

  test("addFlags with %ORIG injects resolution block", () => {
    const script = generateScript(
      makeParams({
        entry: { kind: "binary", addFlags: ["--nas-bin=%ORIG"] },
      }),
    );
    expect(script).toContain('case "$0" in');
    expect(script).toContain('"$ORIG"');
  });

  test("special characters in names", () => {
    expect(
      generateScript(
        makeParams({
          name: "my-app.v2",
          binaries: [makeBinaryInfo({ name: "my-tool" })],
        }),
      ),
    ).toMatchSnapshot();
  });
});
