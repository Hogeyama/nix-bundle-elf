import { describe, expect, test } from "bun:test";
import { quoteShLiteral, serializeAddFlagWordsSh, serializeEnvDirectivesSh } from "./add-flags.ts";
import type { EnvDirective } from "./types.ts";

// ---------------------------------------------------------------------------
// quoteShLiteral
// ---------------------------------------------------------------------------

describe("quoteShLiteral", () => {
  test("simple string", () => {
    expect(quoteShLiteral("hello")).toBe("'hello'");
  });

  test("empty string", () => {
    expect(quoteShLiteral("")).toBe("''");
  });

  test("string with single quote", () => {
    expect(quoteShLiteral("it's")).toBe("'it'\\''s'");
  });

  test("string with multiple single quotes", () => {
    expect(quoteShLiteral("a'b'c")).toBe("'a'\\''b'\\''c'");
  });

  test("string with spaces and special chars", () => {
    expect(quoteShLiteral("hello world $VAR")).toBe("'hello world $VAR'");
  });

  test("path-like string", () => {
    expect(quoteShLiteral("/nix/store/abc-123/lib")).toBe("'/nix/store/abc-123/lib'");
  });
});

// ---------------------------------------------------------------------------
// serializeAddFlagWordsSh
// ---------------------------------------------------------------------------

describe("serializeAddFlagWordsSh", () => {
  test("empty flags", () => {
    expect(serializeAddFlagWordsSh([], "$TEMP")).toBe("");
  });

  test("single simple flag", () => {
    expect(serializeAddFlagWordsSh(["--verbose"], "$TEMP")).toBe("'--verbose'");
  });

  test("multiple simple flags", () => {
    expect(serializeAddFlagWordsSh(["--verbose", "--debug"], "$TEMP")).toBe(
      "'--verbose' '--debug'",
    );
  });

  test("flag with %ROOT", () => {
    expect(serializeAddFlagWordsSh(["%ROOT"], "$TEMP")).toBe('"$TEMP"');
  });

  test("flag with %ROOT in middle of path", () => {
    expect(serializeAddFlagWordsSh(["--config=%ROOT/app.cfg"], "$TEMP")).toBe(
      "'--config='" + '"$TEMP"' + "'/app.cfg'",
    );
  });

  test("flag with multiple %ROOT", () => {
    expect(serializeAddFlagWordsSh(["%ROOT/a:%ROOT/b"], "$TEMP")).toBe(
      '"$TEMP"' + "'/a:'" + '"$TEMP"' + "'/b'",
    );
  });

  test("literal %% is preserved as %", () => {
    expect(serializeAddFlagWordsSh(["100%%"], "$TEMP")).toBe("'100%'");
  });

  test("escaped %%ROOT produces literal %ROOT", () => {
    expect(serializeAddFlagWordsSh(["%%ROOT"], "$TEMP")).toBe("'%ROOT'");
  });

  test("different rootExpr", () => {
    expect(serializeAddFlagWordsSh(["%ROOT/lib"], "$TARGET")).toBe('"$TARGET"' + "'/lib'");
  });
});

// ---------------------------------------------------------------------------
// serializeEnvDirectivesSh
// ---------------------------------------------------------------------------

describe("serializeEnvDirectivesSh", () => {
  test("empty directives", () => {
    expect(serializeEnvDirectivesSh([], "$TEMP")).toBe("");
  });

  test("set directive", () => {
    const directives: EnvDirective[] = [{ kind: "set", name: "FOO", value: "bar" }];
    const result = serializeEnvDirectivesSh(directives, "$TEMP");
    expect(result).toBe("FOO='bar'\nexport FOO");
  });

  test("set directive with %ROOT", () => {
    const directives: EnvDirective[] = [{ kind: "set", name: "HOME", value: "%ROOT/home" }];
    const result = serializeEnvDirectivesSh(directives, "$TEMP");
    expect(result).toBe("HOME=\"$TEMP\"'/home'\nexport HOME");
  });

  test("prefix directive", () => {
    const directives: EnvDirective[] = [
      { kind: "prefix", name: "PATH", sep: ":", value: "/extra" },
    ];
    const result = serializeEnvDirectivesSh(directives, "$TEMP");
    // biome-ignore lint/suspicious/noTemplateCurlyInString: shell syntax in expected output
    expect(result).toBe("PATH='/extra'${PATH:+':'${PATH}}\nexport PATH");
  });

  test("suffix directive", () => {
    const directives: EnvDirective[] = [
      { kind: "suffix", name: "PATH", sep: ":", value: "/extra" },
    ];
    const result = serializeEnvDirectivesSh(directives, "$TEMP");
    // biome-ignore lint/suspicious/noTemplateCurlyInString: shell syntax in expected output
    expect(result).toBe("PATH=${PATH:+${PATH}':'}'/extra'\nexport PATH");
  });

  test("heredoc mode escapes dollar signs", () => {
    const directives: EnvDirective[] = [
      { kind: "prefix", name: "PATH", sep: ":", value: "/extra" },
    ];
    const result = serializeEnvDirectivesSh(directives, "$TARGET", { heredoc: true });
    expect(result).toContain("\\$");
    // biome-ignore lint/suspicious/noTemplateCurlyInString: shell syntax in expected output
    expect(result).toBe("PATH='/extra'\\${PATH:+':'\\${PATH}}\nexport PATH");
  });

  test("multiple directives", () => {
    const directives: EnvDirective[] = [
      { kind: "set", name: "FOO", value: "bar" },
      { kind: "prefix", name: "PATH", sep: ":", value: "/bin" },
    ];
    const result = serializeEnvDirectivesSh(directives, "$TEMP");
    const lines = result.split("\n");
    expect(lines).toHaveLength(4);
    expect(lines[0]).toBe("FOO='bar'");
    expect(lines[1]).toBe("export FOO");
    // biome-ignore lint/suspicious/noTemplateCurlyInString: shell syntax in expected output
    expect(lines[2]).toBe("PATH='/bin'${PATH:+':'${PATH}}");
    expect(lines[3]).toBe("export PATH");
  });

  test("set directive with empty value", () => {
    const directives: EnvDirective[] = [{ kind: "set", name: "EMPTY", value: "" }];
    const result = serializeEnvDirectivesSh(directives, "$TEMP");
    expect(result).toBe("EMPTY=''\nexport EMPTY");
  });
});
