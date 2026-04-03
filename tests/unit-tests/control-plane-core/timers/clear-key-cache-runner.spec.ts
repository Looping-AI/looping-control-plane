import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
  freshTestCanister,
} from "../../../setup";
import { expectOk } from "../../../helpers";

describe("Clear Key Cache Runner Unit Tests", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeAll(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
  });

  beforeEach(async () => {
    testCanister = (await freshTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  it("should return zero cache size after clearing", async () => {
    // Run the clear cache runner (starts with empty cache)
    const result = await testCanister.testClearKeyCacheRunner();

    expect(expectOk(result)).toBe(0n);
  });
});
