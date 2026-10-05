import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createServer } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";
import { Queue, Worker } from "bullmq";

// Every test run owns a new loopback Redis instance. Never use application profiles.
test("bridge actions against BullMQ and isolated Redis", { timeout: 30000 }, async t => {
  const listener = createServer();
  listener.listen(0, "127.0.0.1");
  await once(listener, "listening");
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const redis = spawn(process.env.REDIS_SERVER_PATH ?? "redis-server", [
    "--bind", "127.0.0.1", "--port", String(port), "--save", "", "--appendonly", "no"
  ], { stdio: ["ignore", "pipe", "pipe"] });
  t.after(async () => {
    if (redis.exitCode === null) {
      const exited = once(redis, "exit");
      redis.kill();
      await exited;
    }
  });
  await new Promise((resolve, reject) => {
    redis.once("error", reject);
    redis.once("exit", () => reject(new Error("Test Redis exited before ready")));
    redis.stdout.on("data", data => { if (data.toString().includes("Ready to accept connections")) resolve(); });
  });
  const connection = { host: "127.0.0.1", port };
  const queue = new Queue("bridge-tests", { connection });
  t.after(() => queue.close());

  async function action(action, payload, expectedError = false) {
    const child = spawn(process.execPath, [new URL("bridge.mjs", import.meta.url).pathname], { stdio: ["pipe", "pipe", "pipe"] });
    const timeout = setTimeout(() => child.kill("SIGKILL"), 5000);
    let output = "";
    let errors = "";
    child.stdout.on("data", chunk => { output += chunk; });
    child.stderr.on("data", chunk => { errors += chunk; });
    const exited = once(child, "close");
    child.stdin.end(JSON.stringify({ redis: connection, queueName: queue.name, prefix: "bull", action, payload }));
    try {
      const [code] = await exited;
      const response = JSON.parse(output);
      if (expectedError) {
        assert.equal(code, 1);
        assert.equal(response.ok, false);
        return response.error;
      }
      assert.equal(code, 0, errors || output);
      assert.equal(response.ok, true, response.error);
      return response.result;
    } finally { clearTimeout(timeout); }
  }

  await t.test("add, promote and remove are reflected in Redis", async () => {
    const added = await action("add", { name: "delayed", data: { example: true }, options: { delay: 60000 } });
    const job = await queue.getJob(added.jobID);
    assert.deepEqual(job.data, { example: true });
    assert.equal(await job.getState(), "delayed");
    await action("promote", { jobID: job.id });
    assert.equal(await job.getState(), "waiting");
    await action("remove", { jobID: job.id, removeChildren: true });
    assert.equal(await queue.getJob(job.id), undefined);
  });

  await t.test("duplicate strips copied identity and relationship options", async () => {
    const original = await queue.add("original", { value: 1 }, { jobId: "original" });
    const copied = await action("duplicate", {
      name: "copy", data: original.data,
      options: { jobId: original.id, repeat: { every: 1000 }, parent: { id: "missing", queue: "bull:parent" }, parentKey: "parent", de: { id: "dedupe" }, attempts: 3 }
    });
    assert.notEqual(copied.jobID, original.id);
    const job = await queue.getJob(copied.jobID);
    assert.equal(job.opts.attempts, 3);
    assert.equal(job.opts.repeat, undefined);
    assert.equal(job.parentKey, undefined);
    await original.remove();
    await job.remove();
  });

  await t.test("failed and completed jobs can be retried", async () => {
    const worker = new Worker(queue.name, async job => {
      if (job.name === "failure") throw new Error("Expected test failure");
      return "done";
    }, { connection });
    try {
      const failed = await queue.add("failure", {});
      const completed = await queue.add("success", {});
      for (let attempt = 0; attempt < 100; attempt++) {
        if (await failed.getState() === "failed" && await completed.getState() === "completed") break;
        await delay(20);
      }
      await worker.pause();
      assert.equal(await failed.getState(), "failed");
      assert.equal(await completed.getState(), "completed");
      await action("retry", { jobID: failed.id, state: "failed" });
      await action("retry", { jobID: completed.id, state: "completed" });
      assert.equal(await failed.getState(), "waiting");
      assert.equal(await completed.getState(), "waiting");
    } finally { await worker.close(); }
  });

  await t.test("cleanup respects age, count, state and preserves pending jobs", async () => {
    await queue.drain(true);
    const worker = new Worker(queue.name, async job => {
      if (job.name === "clean-failed") throw new Error("retained failure");
      return "done";
    }, { connection });
    const completed = await Promise.all([0, 1, 2].map(index => queue.add(`clean-${index}`, {})));
    const failed = await queue.add("clean-failed", {});
    try {
      for (let attempt = 0; attempt < 100; attempt++) {
        if ((await Promise.all(completed.map(job => job.getState()))).every(state => state === "completed") && await failed.getState() === "failed") break;
        await delay(20);
      }
      await worker.pause();
      const client = await queue.client;
      const old = Date.now() - 172800000;
      for (const job of completed.slice(0, 2)) {
        await client.hset(job.toKey(), "finishedOn", old);
        await client.zadd(queue.toKey("completed"), old, job.id);
      }
      await client.hset(failed.toKey(), "finishedOn", old);
      await client.zadd(queue.toKey("failed"), old, failed.id);
      const pending = await queue.add("pending", {});
      const delayed = await queue.add("pending-delayed", {}, { delay: 60000 });
      assert.equal((await action("clean", { state: "completed", grace: 86400000, limit: 1 })).removedCount, 1);
      assert.equal((await action("clean", { state: "completed", grace: 86400000, limit: 100 })).removedCount, 1);
      assert.equal((await action("clean", { state: "completed", grace: 86400000, limit: 100 })).removedCount, 0);
      assert.ok(await queue.getJob(completed[2].id));
      assert.ok(await queue.getJob(failed.id));
      assert.equal((await action("clean", { state: "failed", grace: 86400000, limit: 100 })).removedCount, 1);
      assert.equal(await pending.getState(), "waiting");
      assert.equal(await delayed.getState(), "delayed");
      for (const payload of [
        { state: "active", grace: 60000, limit: 10 },
        { state: "completed", grace: 0, limit: 10 },
        { state: "completed", grace: 60000, limit: 1001 }
      ]) assert.match(await action("clean", payload, true), /Cleanup/);
    } finally { await worker.close(); }
  });

  await t.test("scheduler previews use six-field cron, timezone, limits and end date", async () => {
    const now = Date.now();
    await queue.upsertJobScheduler("cron-preview", { pattern: "0 */15 * * * *", tz: "Asia/Kolkata", limit: 3, endDate: now + 86400000 }, { name: "scheduled", data: {} });
    const { preview } = await action("schedulerPreview", { key: "cron-preview" });
    assert.equal(preview.kind, "scheduler");
    assert.equal(preview.fields.tz, "Asia/Kolkata");
    assert.equal(preview.fields.previewTimeZone, "Asia/Kolkata");
    assert.equal(preview.fields.previewTimeZoneSource, "recorded");
    const override = (await action("schedulerPreview", { key: "cron-preview", timeZone: "UTC" })).preview;
    assert.equal(override.fields.previewTimeZone, "UTC");
    assert.equal(override.fields.tz, "Asia/Kolkata");
    assert.equal(preview.fields.limit, "3");
    assert.equal(preview.times.length, 3);
    assert.equal(preview.times[0], (await queue.getJobScheduler("cron-preview")).next);
    assert.ok(preview.times.every(time => new Date(time).getUTCSeconds() === 0 && time <= now + 86400000));
    assert.equal(preview.times[1] - preview.times[0], 900000);
    assert.match(await action("removeScheduler", { key: "cron-preview", kind: "legacy" }, true), /type changed/);
    await action("removeScheduler", { key: "cron-preview", kind: "scheduler" });
    assert.equal(await queue.getJobScheduler("cron-preview"), undefined);
    assert.match(await action("schedulerPreview", { key: "cron-preview" }, true), /no longer registered/);
  });

  await t.test("interval preview preserves offset and removal supports legacy repeat keys", async () => {
    const job = await queue.upsertJobScheduler("interval-preview", { every: 60000, limit: 2 }, { name: "interval", data: {} });
    const scheduler = await queue.getJobScheduler("interval-preview");
    const { preview } = await action("schedulerPreview", { key: "interval-preview" });
    assert.equal(preview.times.length, 2);
    assert.equal(preview.times[0], scheduler.next + (scheduler.offset || 0));
    assert.equal(preview.times[1] - preview.times[0], 60000);
    await action("removeScheduler", { key: "interval-preview", kind: "scheduler" });
    assert.equal(await job.getState(), "waiting"); // BullMQ preserves already-emitted waiting jobs.
    const legacy = await queue.add("legacy", {}, { repeat: { every: 60000 } });
    const key = legacy.repeatJobKey;
    assert.ok(key);
    assert.equal((await action("schedulerPreview", { key })).preview.kind, "legacy");
    await action("removeScheduler", { key, kind: "legacy" });
    assert.ok(!(await queue.getJob(legacy.id)));
    assert.ok(!(await queue.getRepeatableJobs()).some(item => item.key === key));
  });


  await t.test("cron preview respects end dates, DST and unknown worker timezone", async () => {
    const now = Date.now();
    await queue.upsertJobScheduler("ends-soon", { pattern: "*/10 * * * * *", tz: "UTC", endDate: now + 15000 }, { name: "end-date", data: {} });
    const ending = (await action("schedulerPreview", { key: "ends-soon" })).preview;
    assert.ok(ending.times.length >= 1 && ending.times.length <= 2);
    assert.ok(ending.times.every(time => time <= now + 15000));
    await action("removeScheduler", { key: "ends-soon", kind: "scheduler" });
    await queue.upsertJobScheduler("dst-preview", { pattern: "0 9 * * *", tz: "America/New_York", startDate: Date.UTC(2030, 10, 2, 0), limit: 5 }, { name: "dst", data: {} });
    const dst = (await action("schedulerPreview", { key: "dst-preview" })).preview;
    assert.equal(dst.times.length, 5);
    assert.equal(dst.times[1] - dst.times[0], 25 * 60 * 60 * 1000);
    await action("removeScheduler", { key: "dst-preview", kind: "scheduler" });
    await queue.upsertJobScheduler("unknown-zone", { pattern: "0 9 * * *" }, { name: "unknown", data: {} });
    const unknown = (await action("schedulerPreview", { key: "unknown-zone" })).preview;
    assert.equal(unknown.times.length, 5);
    assert.equal(unknown.fields.previewTimeZoneSource, "system");
    assert.match(unknown.message, /assume your Mac's timezone/);
    const system = (await action("schedulerPreview", { key: "unknown-zone", systemTimeZone: "Asia/Kolkata" })).preview;
    assert.equal(system.fields.previewTimeZone, "Asia/Kolkata");
    const overridden = (await action("schedulerPreview", { key: "unknown-zone", systemTimeZone: "Asia/Kolkata", timeZone: "America/Los_Angeles" })).preview;
    assert.equal(overridden.fields.previewTimeZoneSource, "override");
    assert.equal(overridden.times[0], system.times[0], "The stored occurrence must remain unchanged");
    for (const [preview, zone] of [[system, "Asia/Kolkata"], [overridden, "America/Los_Angeles"]]) {
      assert.equal(preview.times.length, 5);
      for (const time of preview.times.slice(1)) {
        assert.equal(new Intl.DateTimeFormat("en-GB", { timeZone: zone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(time), "09:00");
      }
    }
    assert.notEqual(system.times[1], overridden.times[1]);
    assert.equal((await queue.getJobScheduler("unknown-zone")).tz, undefined);
    assert.match(await action("schedulerPreview", { key: "unknown-zone", timeZone: "Invalid/Zone" }, true), /time zone/i);
    await action("removeScheduler", { key: "unknown-zone", kind: "scheduler" });
  });

});
