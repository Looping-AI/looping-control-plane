import { beforeAll, afterAll, setDefaultTimeout } from "bun:test";
import { PocketIcServer } from "@dfinity/pic";

setDefaultTimeout(30_000);

let pic: PocketIcServer | undefined;

beforeAll(async () => {
  // When run via the parallel coordinator, PIC_URL is already set — skip starting a server.
  if (process.env.PIC_URL) return;

  pic = await PocketIcServer.start({
    showRuntimeLogs: true,
    showCanisterLogs: true,
  });
  const url = pic.getUrl();

  process.env.PIC_URL = url;
}, 10000);

afterAll(async () => {
  await pic?.stop();
});
