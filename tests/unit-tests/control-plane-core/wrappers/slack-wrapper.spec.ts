import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, DeferredActor } from "@dfinity/pic";
import {
  createDeferredTestCanister,
  type TestCanisterService,
  SLACK_TEST_TOKEN,
} from "../../../setup";
import { withCassette } from "../../../lib/cassette";

describe("Slack Wrapper Unit Tests", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  // ===========================================================================
  // Helpers
  // ===========================================================================

  /**
   * Submit a call + tick, intercept the first pending HTTPS outcall, respond
   * with the given JSON body (HTTP 200), and return the awaited actor result.
   *
   * `call` is the deferred callback returned by `await testCanister.method(...)`.
   */
  async function mockSlackResponse(
    call: () => Promise<unknown>,
    responseBody: object,
  ): Promise<unknown> {
    await pic.tick(5);

    const pending = await pic.getPendingHttpsOutcalls();
    if (pending.length === 0) throw new Error("No pending HTTPS outcalls");

    const { requestId, subnetId } = pending[0];
    const bodyBytes = new TextEncoder().encode(JSON.stringify(responseBody));

    await pic.mockPendingHttpsOutcall({
      requestId,
      subnetId,
      response: {
        type: "success",
        statusCode: 200,
        headers: [],
        body: bodyBytes,
      },
    });

    return call();
  }

  const slackAuthError = {
    ok: false,
    error: "invalid_auth",
  };

  const slackChannelNotFoundError = {
    ok: false,
    error: "channel_not_found",
  };

  // ===========================================================================
  // getOrganizationMembers
  // ===========================================================================

  describe("getOrganizationMembers", () => {
    it("should return an error for an invalid token", async () => {
      const call =
        await testCanister.slackGetOrganizationMembers("xoxb-invalid");

      const response = (await mockSlackResponse(call, slackAuthError)) as
        | { ok: unknown }
        | { err: string };

      expect("err" in response).toBe(true);
      if ("err" in response) {
        expect(response.err).toContain("invalid_auth");
      }
    });

    it("should return a list of organization members", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/control-plane-core/wrappers/slack-wrapper/get-organization-members",
        () => testCanister.slackGetOrganizationMembers(SLACK_TEST_TOKEN),
        { ticks: 5, maxRounds: 10 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(Array.isArray(response.ok)).toBe(true);
        expect(response.ok.length).toBeGreaterThan(0);

        const firstUser = response.ok[0];
        expect(typeof firstUser.id).toBe("string");
        expect(firstUser.id.length).toBeGreaterThan(0);
        expect(typeof firstUser.name).toBe("string");
        expect(typeof firstUser.isAdmin).toBe("boolean");
        expect(typeof firstUser.isOwner).toBe("boolean");
        expect(typeof firstUser.isPrimaryOwner).toBe("boolean");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should have exactly one primary owner in the organization", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/control-plane-core/wrappers/slack-wrapper/get-organization-members",
        () => testCanister.slackGetOrganizationMembers(SLACK_TEST_TOKEN),
        { ticks: 5, maxRounds: 10 },
      );

      const response = await result;

      if ("ok" in response) {
        const primaryOwners = response.ok.filter((u) => u.isPrimaryOwner);
        expect(primaryOwners.length).toBe(1);
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });
  });

  // ===========================================================================
  // listChannels
  // ===========================================================================

  describe("listChannels", () => {
    it("should return an error for an invalid token", async () => {
      const call = await testCanister.slackListChannels("xoxb-invalid", []);

      const response = (await mockSlackResponse(call, slackAuthError)) as
        | { ok: unknown }
        | { err: string };

      expect("err" in response).toBe(true);
      if ("err" in response) {
        expect(response.err).toContain("invalid_auth");
      }
    });

    it("should return a list of channels with no type filter", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/control-plane-core/wrappers/slack-wrapper/list-channels-all",
        () => testCanister.slackListChannels(SLACK_TEST_TOKEN, []),
        { ticks: 5, maxRounds: 10 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(Array.isArray(response.ok)).toBe(true);
        expect(response.ok.length).toBeGreaterThan(0);

        const firstChannel = response.ok[0];
        expect(typeof firstChannel.id).toBe("string");
        expect(firstChannel.id.length).toBeGreaterThan(0);
        expect(typeof firstChannel.name).toBe("string");
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should return only public channels when types is public_channel", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/control-plane-core/wrappers/slack-wrapper/list-channels-public",
        () =>
          testCanister.slackListChannels(SLACK_TEST_TOKEN, ["public_channel"]),
        { ticks: 5, maxRounds: 10 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(Array.isArray(response.ok)).toBe(true);
        expect(response.ok.length).toBeGreaterThan(0);

        for (const channel of response.ok) {
          expect(typeof channel.id).toBe("string");
          expect(typeof channel.name).toBe("string");
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });

    it("should return only private channels when types is private_channel", async () => {
      const { result } = await withCassette(
        pic,
        "unit-tests/control-plane-core/wrappers/slack-wrapper/list-channels-private",
        () =>
          testCanister.slackListChannels(SLACK_TEST_TOKEN, ["private_channel"]),
        { ticks: 5, maxRounds: 10 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(Array.isArray(response.ok)).toBe(true);
        expect(response.ok.length).toBeGreaterThan(0);

        for (const channel of response.ok) {
          expect(typeof channel.id).toBe("string");
          expect(typeof channel.name).toBe("string");
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });
  });

  // ===========================================================================
  // getChannelMembers
  // ===========================================================================

  describe("getChannelMembers", () => {
    it("should return an error for an invalid token", async () => {
      const call = await testCanister.slackGetChannelMembers(
        "xoxb-invalid",
        "C00000000",
      );

      const response = (await mockSlackResponse(call, slackAuthError)) as
        | { ok: unknown }
        | { err: string };

      expect("err" in response).toBe(true);
      if ("err" in response) {
        expect(response.err).toContain("invalid_auth");
      }
    });

    it("should return an error for a non-existent channel", async () => {
      const call = await testCanister.slackGetChannelMembers(
        SLACK_TEST_TOKEN,
        "C00000000INVALID",
      );

      const response = (await mockSlackResponse(
        call,
        slackChannelNotFoundError,
      )) as { ok: unknown } | { err: string };

      expect("err" in response).toBe(true);
      if ("err" in response) {
        expect(response.err).toContain("channel_not_found");
      }
    });

    it("should return member IDs for a valid channel", async () => {
      // Fetch channels first to get a real channel ID
      const channelsResult = await withCassette(
        pic,
        "unit-tests/control-plane-core/wrappers/slack-wrapper/get-channel-members-list-channels",
        () => testCanister.slackListChannels(SLACK_TEST_TOKEN, []),
        { ticks: 5, maxRounds: 10 },
      );

      const channelsResponse = await channelsResult.result;
      if (!("ok" in channelsResponse) || channelsResponse.ok.length === 0) {
        throw new Error("Could not list channels to pick one for member test");
      }

      const channelId = channelsResponse.ok[0].id;

      const { result } = await withCassette(
        pic,
        "unit-tests/control-plane-core/wrappers/slack-wrapper/get-channel-members",
        () => testCanister.slackGetChannelMembers(SLACK_TEST_TOKEN, channelId),
        { ticks: 5, maxRounds: 10 },
      );

      const response = await result;

      if ("ok" in response) {
        expect(Array.isArray(response.ok)).toBe(true);
        for (const memberId of response.ok) {
          expect(typeof memberId).toBe("string");
          expect(memberId.length).toBeGreaterThan(0);
        }
      } else {
        throw new Error(
          "Expected successful response but got error: " + response.err,
        );
      }
    });
  });

  // ===========================================================================
  // Cursor URL encoding
  //
  // Slack pagination cursors are base64-encoded and contain characters that
  // are not URL-safe: +, /, and = (e.g. "dXNlcjpVMEc5V0ZYTlo="). These must
  // be percent-encoded before being appended to a URL query string. The tests
  // below drive a two-page pagination sequence and assert that the second
  // request URL contains the properly encoded cursor.
  // ===========================================================================

  describe("cursor URL-encoding in pagination", () => {
    // The canonical Slack example cursor that ends with an = character.
    // When used as a URL query parameter it must appear as %3D.
    const RAW_CURSOR = "dXNlcjpVMEc5V0ZYTlo=";
    const ENCODED_CURSOR = "dXNlcjpVMEc5V0ZYTlo%3D";

    /**
     * Drive a two-page mock interaction:
     * 1. Tick until the canister makes its first HTTP request.
     * 2. Respond with firstPageBody (which contains a next_cursor).
     * 3. Tick again so the canister processes the response and issues the
     *    second request.
     * 4. Inspect the second request URL and optionally run assertions on it.
     * 5. Respond with secondPageBody (no cursor → pagination ends).
     * 6. Resolve the deferred call and return the final result.
     */
    async function mockTwoPages(
      call: () => Promise<unknown>,
      firstPageBody: object,
      secondPageBody: object,
      onSecondUrl?: (url: string) => void,
    ): Promise<unknown> {
      // --- First request ---
      await pic.tick(5);
      const pending1 = await pic.getPendingHttpsOutcalls();
      if (pending1.length === 0)
        throw new Error("Expected first pending HTTPS outcall");

      await pic.mockPendingHttpsOutcall({
        requestId: pending1[0].requestId,
        subnetId: pending1[0].subnetId,
        response: {
          type: "success",
          statusCode: 200,
          headers: [],
          body: new TextEncoder().encode(JSON.stringify(firstPageBody)),
        },
      });

      // --- Second request (canister has the cursor now) ---
      await pic.tick(10);
      const pending2 = await pic.getPendingHttpsOutcalls();
      if (pending2.length === 0)
        throw new Error(
          "Expected second pending HTTPS outcall — cursor pagination did not trigger",
        );

      onSecondUrl?.(pending2[0].url);

      await pic.mockPendingHttpsOutcall({
        requestId: pending2[0].requestId,
        subnetId: pending2[0].subnetId,
        response: {
          type: "success",
          statusCode: 200,
          headers: [],
          body: new TextEncoder().encode(JSON.stringify(secondPageBody)),
        },
      });

      return call();
    }

    it("getOrganizationMembers — cursor with = is percent-encoded in users.list URL", async () => {
      const call =
        await testCanister.slackGetOrganizationMembers(SLACK_TEST_TOKEN);

      const firstPage = {
        ok: true,
        members: [
          {
            id: "U001",
            name: "alice",
            is_admin: false,
            is_owner: false,
            is_primary_owner: true,
            deleted: false,
          },
        ],
        response_metadata: { next_cursor: RAW_CURSOR },
      };
      const lastPage = {
        ok: true,
        members: [],
        response_metadata: { next_cursor: "" },
      };

      let capturedUrl = "";
      const response = await mockTwoPages(call, firstPage, lastPage, (url) => {
        capturedUrl = url;
      });

      // The raw = must appear as %3D in the query string
      expect(capturedUrl).toContain(`cursor=${ENCODED_CURSOR}`);
      // The raw unencoded = must NOT appear as a bare query character
      expect(capturedUrl).not.toContain(`cursor=${RAW_CURSOR}`);

      expect("ok" in (response as object)).toBe(true);
    });

    it("listChannels — cursor with = is percent-encoded in conversations.list URL", async () => {
      const call = await testCanister.slackListChannels(SLACK_TEST_TOKEN, []);

      const firstPage = {
        ok: true,
        channels: [{ id: "C001", name: "general" }],
        response_metadata: { next_cursor: RAW_CURSOR },
      };
      const lastPage = {
        ok: true,
        channels: [],
        response_metadata: { next_cursor: "" },
      };

      let capturedUrl = "";
      const response = await mockTwoPages(call, firstPage, lastPage, (url) => {
        capturedUrl = url;
      });

      expect(capturedUrl).toContain(`cursor=${ENCODED_CURSOR}`);
      expect(capturedUrl).not.toContain(`cursor=${RAW_CURSOR}`);

      expect("ok" in (response as object)).toBe(true);
    });

    it("getChannelMembers — cursor with = is percent-encoded in conversations.members URL", async () => {
      const call = await testCanister.slackGetChannelMembers(
        SLACK_TEST_TOKEN,
        "C001",
      );

      const firstPage = {
        ok: true,
        members: ["U001", "U002"],
        response_metadata: { next_cursor: RAW_CURSOR },
      };
      const lastPage = {
        ok: true,
        members: [],
        response_metadata: { next_cursor: "" },
      };

      let capturedUrl = "";
      const response = await mockTwoPages(call, firstPage, lastPage, (url) => {
        capturedUrl = url;
      });

      expect(capturedUrl).toContain(`cursor=${ENCODED_CURSOR}`);
      expect(capturedUrl).not.toContain(`cursor=${RAW_CURSOR}`);

      expect("ok" in (response as object)).toBe(true);
    });
  });
});
