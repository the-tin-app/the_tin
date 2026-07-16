// functions/test/overnight-halt.test.ts
import { describe, it, expect } from "vitest";
import { isRateLimitStop, haltGate } from "../src/pipeline/overnight-halt";

describe("isRateLimitStop", () => {
  it("is true for a PPT 429 stop reason", () => {
    expect(isRateLimitStop("PPT 429 for enrich Base (gave up after 2 Retry-After waits)")).toBe(true);
  });
  it("is true for a PPT 403 stop reason", () => {
    expect(isRateLimitStop("PPT 403 for population 50")).toBe(true);
  });
  it("is false for a non-rate-limit PPT error", () => {
    expect(isRateLimitStop("PPT 500 for enrich Base")).toBe(false);
  });
  it("is false for undefined", () => {
    expect(isRateLimitStop(undefined)).toBe(false);
  });
  it("is false for a credit-budget-exceeded message", () => {
    expect(isRateLimitStop("PPT daily credit budget exceeded")).toBe(false);
  });
});

describe("haltGate", () => {
  it("proceeds when not halted, regardless of the clear env", () => {
    expect(haltGate(false, undefined)).toBe("proceed");
    expect(haltGate(false, "1")).toBe("proceed");
  });
  it("clears when halted and the operator set the clear env to '1'", () => {
    expect(haltGate(true, "1")).toBe("clear");
  });
  it("refuses when halted and the clear env is unset", () => {
    expect(haltGate(true, undefined)).toBe("refuse");
  });
  it("refuses when halted and the clear env is set to something other than '1'", () => {
    expect(haltGate(true, "0")).toBe("refuse");
    expect(haltGate(true, "true")).toBe("refuse");
  });
});
