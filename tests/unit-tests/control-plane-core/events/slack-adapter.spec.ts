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

// PocketIC time helpers.
// After freshTestCanister and advanceTime calls, the actual PocketIC clock
// may differ from a hardcoded baseline. Use pic.getTime() to read the real
// canister time (returned in milliseconds, convert to seconds for Slack).
async function currentPicSeconds(pic: PocketIc): Promise<bigint> {
  const timeMs = await pic.getTime();
  return BigInt(Math.floor(timeMs / 1000));
}

describe("Slack Adapter Signature Verification", () => {
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

  describe("verifySignature - Signature Validation", () => {
    it("should accept valid signature with current timestamp", async () => {
      await pic.advanceTime(5_000);
      await pic.tick();

      // Timestamp must match what PocketIC's Time.now() returns
      const timestamp = (await currentPicSeconds(pic)).toString();
      const signingSecret = "test_secret";
      const body = '{"type":"url_verification","challenge":"3eZbrw1aBNRETGM"}';

      // Compute expected signature using HMAC-SHA256
      const crypto = await import("crypto");
      const baseString = `v0:${timestamp}:${body}`;
      const hmac = crypto.createHmac("sha256", signingSecret);
      hmac.update(baseString);
      const expectedSignature = `v0=${hmac.digest("hex")}`;

      const result = await testCanister.testSlackSignatureVerification(
        signingSecret,
        expectedSignature,
        timestamp,
        body,
      );

      expect(result).toBe(true);
    });

    it("should reject invalid signature", async () => {
      await pic.advanceTime(5_000);
      await pic.tick();

      const timestamp = (await currentPicSeconds(pic)).toString();
      const signingSecret = "test_secret";
      const body = '{"type":"url_verification","challenge":"3eZbrw1aBNRETGM"}';
      const invalidSignature = "v0=invalid_signature_here";

      const result = await testCanister.testSlackSignatureVerification(
        signingSecret,
        invalidSignature,
        timestamp,
        body,
      );

      expect(result).toBe(false);
    });

    it("should reject signature with wrong secret", async () => {
      await pic.advanceTime(5_000);
      await pic.tick();

      const timestamp = (await currentPicSeconds(pic)).toString();
      const signingSecret = "test_secret";
      const wrongSecret = "wrong_secret";
      const body = '{"type":"url_verification","challenge":"3eZbrw1aBNRETGM"}';

      // Create signature with original secret
      const crypto = await import("crypto");
      const baseString = `v0:${timestamp}:${body}`;
      const hmac = crypto.createHmac("sha256", signingSecret);
      hmac.update(baseString);
      const validSignatureWithOriginalSecret = `v0=${hmac.digest("hex")}`;

      // Verify with wrong secret should fail
      const result = await testCanister.testSlackSignatureVerification(
        wrongSecret,
        validSignatureWithOriginalSecret,
        timestamp,
        body,
      );

      expect(result).toBe(false);
    });
  });

  describe("verifyTimestamp - Direct Timestamp Validation", () => {
    it("should accept timestamp just created (within 5 minute window)", async () => {
      await pic.advanceTime(10_000);
      await pic.tick();

      const timestamp = (await currentPicSeconds(pic)).toString();

      const result =
        await testCanister.testSlackTimestampVerification(timestamp);

      expect(result).toBe(true);
    });

    it("should reject timestamp with invalid format", async () => {
      await pic.advanceTime(10_000);
      await pic.tick();

      const invalidTimestamp = "not_a_number";

      const result =
        await testCanister.testSlackTimestampVerification(invalidTimestamp);

      expect(result).toBe(false);
    });

    it("should reject timestamp in the future", async () => {
      await pic.advanceTime(10_000);
      await pic.tick();

      // Create a timestamp 10 minutes in the future
      const futureTimestamp = (
        (await currentPicSeconds(pic)) + 600n
      ).toString();

      const result =
        await testCanister.testSlackTimestampVerification(futureTimestamp);

      expect(result).toBe(false);
    });

    it("should reject timestamp older than 5 minutes", async () => {
      await pic.advanceTime(395_000);
      await pic.tick();

      // Use a timestamp from 6 minutes ago (360 seconds + some buffer)
      const oldTimestamp = ((await currentPicSeconds(pic)) - 400n).toString();

      const result =
        await testCanister.testSlackTimestampVerification(oldTimestamp);

      expect(result).toBe(false);
    });

    it("should accept timestamp at the 5 minute boundary", async () => {
      await pic.advanceTime(305_000);
      await pic.tick();

      // Use a timestamp from exactly 5 minutes ago
      const boundaryTimestamp = (
        (await currentPicSeconds(pic)) - 300n
      ).toString();

      const result =
        await testCanister.testSlackTimestampVerification(boundaryTimestamp);

      expect(result).toBe(true);
    });
  });

  describe("verifySignature - With Timestamp Validation via Full Signature Check", () => {
    it("should accept valid signature with current timestamp", async () => {
      await pic.advanceTime(10_000);
      await pic.tick();

      const timestamp = (await currentPicSeconds(pic)).toString();
      const signingSecret = "test_secret";
      const body = '{"type":"url_verification","challenge":"3eZbrw1aBNRETGM"}';

      // Create valid signature for this timestamp
      const crypto = await import("crypto");
      const baseString = `v0:${timestamp}:${body}`;
      const hmac = crypto.createHmac("sha256", signingSecret);
      hmac.update(baseString);
      const validSignature = `v0=${hmac.digest("hex")}`;

      const result = await testCanister.testSlackSignatureVerification(
        signingSecret,
        validSignature,
        timestamp,
        body,
      );

      expect(result).toBe(true);
    });
  });

  describe("verifySignature - Real-world scenarios", () => {
    it("should verify a Slack event with valid signature and current timestamp", async () => {
      await pic.advanceTime(15_000);
      await pic.tick();

      const timestamp = (await currentPicSeconds(pic)).toString();
      const signingSecret = "8f742231b91f688db8577c53fe3a0481";
      const body =
        '{"token":"Jhj5dBrVaoK8OKHSKwFBHO5C","team_id":"T061EG9R6","api_app_id":"A0HKV7KB4","event":{"type":"app_mention","user":"U024BE7LH","text":"<@U0LAN0Z89> What\'s up?","ts":"1360782804.083113","channel":"C2147483705","event_ts":"1360782804.083113"},"type":"event_callback","event_id":"Ev0PV52K21","event_time":1360782804}';

      // Compute valid signature for this timestamp
      const crypto = await import("crypto");
      const baseString = `v0:${timestamp}:${body}`;
      const hmac = crypto.createHmac("sha256", signingSecret);
      hmac.update(baseString);
      const validSignature = `v0=${hmac.digest("hex")}`;

      const result = await testCanister.testSlackSignatureVerification(
        signingSecret,
        validSignature,
        timestamp,
        body,
      );

      // Should pass both signature and timestamp validation
      expect(result).toBe(true);
    });
  });
});
