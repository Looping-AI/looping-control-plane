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

// ============================================
// MetricRetentionRunner Unit Tests
//
// The runner calls MetricModel.purgeOldDatapoints which:
//   - Computes cutoff = Time.now() - retentionDays * NANOS_PER_DAY
//   - Removes datapoint buckets (day-keyed) entirely before the cutoff
//   - Partial-filters the boundary bucket
//
// We control which timestamps datapoints receive by setting pic.setTime()
// before recording them, since testRecordMetricDatapointHandler uses
// Time.now() internally.
// ============================================

const DAY_MS = 24 * 60 * 60 * 1000;

interface DatapointsResponse {
  success: boolean;
  count?: number;
  datapoints?: Array<{ timestamp: number; value: number; source: string }>;
  error?: string;
}

async function createMetric(
  testCanister: Actor<TestCanisterService>,
  retentionDays = 30,
): Promise<number> {
  const result = await testCanister.testCreateMetricHandler(
    JSON.stringify({
      name: "test-metric",
      description: "Retention test metric",
      unit: "count",
      retentionDays,
    }),
  );
  return JSON.parse(result).metricId as number;
}

async function recordDatapoint(
  testCanister: Actor<TestCanisterService>,
  metricId: number,
  value: number,
): Promise<void> {
  await testCanister.testRecordMetricDatapointHandler(
    JSON.stringify({ metricId, value }),
  );
}

async function getDatapoints(
  testCanister: Actor<TestCanisterService>,
  metricId: number,
): Promise<DatapointsResponse> {
  const result = await testCanister.testGetMetricDatapointsHandler(
    JSON.stringify({ metricId }),
  );
  return JSON.parse(result) as DatapointsResponse;
}

describe("Metric Retention Runner Unit Tests", () => {
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

  it("should complete without error on empty datapoints", async () => {
    const result = await testCanister.testMetricRetentionRunner();
    expect(result).toEqual({ ok: null });
  });

  it("should purge expired datapoints while retaining fresh ones", async () => {
    // Use a "now" that is guaranteed to be in the future relative to PocketIC's
    // current clock (which advances with each freshTestCanister call). Adding
    // 60 days ensures that "now - 31 * DAY_MS" is still ahead of PocketIC time.
    const picNowMs = await pic.getTime();
    const now = picNowMs + 60 * DAY_MS;

    // Create metric with 30-day retention. Clock is set to 31 days ago so that
    // the datapoints we record next will fall outside the retention window.
    await pic.setTime(now - 31 * DAY_MS);
    await pic.tick(1);
    const metricId = await createMetric(testCanister, 30);

    // Record 2 datapoints at 31 days ago — outside the 30-day window, must be purged.
    await recordDatapoint(testCanister, metricId, 1.0);
    await recordDatapoint(testCanister, metricId, 2.0);

    // Advance to the present and record 3 fresh datapoints within the window.
    await pic.setTime(now);
    await pic.tick(1);
    await recordDatapoint(testCanister, metricId, 10.0);
    await recordDatapoint(testCanister, metricId, 20.0);
    await recordDatapoint(testCanister, metricId, 30.0);

    // Sanity: 5 datapoints exist before the purge.
    const before = await getDatapoints(testCanister, metricId);
    expect(before.count).toBe(5);

    // Run the retention runner (cutoff = now - 30 days).
    expectOk(await testCanister.testMetricRetentionRunner());

    // Only the 3 fresh datapoints must survive.
    const after = await getDatapoints(testCanister, metricId);
    expect(after.count).toBe(3);
    const values = after.datapoints?.map((dp) => dp.value) ?? [];
    expect(values).toEqual([10.0, 20.0, 30.0]);
  });

  it("should not purge datapoints recorded within the retention window", async () => {
    // Use a "now" that is guaranteed to be in the future relative to PocketIC's
    // current clock. Adding 60 days ensures "now - 29 * DAY_MS" is still ahead.
    const picNowMs = await pic.getTime();
    const now = picNowMs + 60 * DAY_MS;

    // Create metric at 29 days ago — inside a 30-day retention window.
    await pic.setTime(now - 29 * DAY_MS);
    await pic.tick(1);
    const metricId = await createMetric(testCanister, 30);

    await recordDatapoint(testCanister, metricId, 5.0);
    await recordDatapoint(testCanister, metricId, 6.0);
    await recordDatapoint(testCanister, metricId, 7.0);

    // Advance to now before running the runner.
    await pic.setTime(now);
    await pic.tick(1);

    expectOk(await testCanister.testMetricRetentionRunner());

    // All 3 datapoints must still be present.
    const after = await getDatapoints(testCanister, metricId);
    expect(after.count).toBe(3);
  });
});
