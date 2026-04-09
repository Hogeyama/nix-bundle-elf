import { describe, expect, test } from "bun:test";
import {
  INTERP_PLACEHOLDER_LEN,
  INTERP_PLACEHOLDER_TAG,
  makeInterpPlaceholder,
} from "./bundle-common.ts";

// ---------------------------------------------------------------------------
// makeInterpPlaceholder
// ---------------------------------------------------------------------------

describe("makeInterpPlaceholder", () => {
  test("returns a string of exactly INTERP_PLACEHOLDER_LEN bytes", () => {
    const placeholder = makeInterpPlaceholder();
    expect(placeholder.length).toBe(INTERP_PLACEHOLDER_LEN);
    expect(placeholder.length).toBe(256);
  });

  test("starts with /NIXBUNDLEELF_INTERP_PLACEHOLDER", () => {
    const placeholder = makeInterpPlaceholder();
    expect(placeholder.startsWith(`/${INTERP_PLACEHOLDER_TAG}`)).toBe(true);
  });

  test("remaining bytes are slashes", () => {
    const placeholder = makeInterpPlaceholder();
    const tagPart = `/${INTERP_PLACEHOLDER_TAG}`;
    const rest = placeholder.slice(tagPart.length);
    expect(rest).toMatch(/^\/+$/);
  });

  test("is idempotent", () => {
    expect(makeInterpPlaceholder()).toBe(makeInterpPlaceholder());
  });
});

// ---------------------------------------------------------------------------
// INTERP_PLACEHOLDER_TAG / INTERP_PLACEHOLDER_LEN
// ---------------------------------------------------------------------------

describe("placeholder constants", () => {
  test("tag is the expected string", () => {
    expect(INTERP_PLACEHOLDER_TAG).toBe("NIXBUNDLEELF_INTERP_PLACEHOLDER");
  });

  test("length is 256", () => {
    expect(INTERP_PLACEHOLDER_LEN).toBe(256);
  });

  test("tag fits within placeholder length", () => {
    // tag + leading "/" must be shorter than the placeholder length
    expect(`/${INTERP_PLACEHOLDER_TAG}`.length).toBeLessThan(INTERP_PLACEHOLDER_LEN);
  });
});
