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

  async function action(action, payload) {
    const child = spawn(process.execPath, [new URL("bridge.mjs", import.meta.url).pathname], { stdio: ["pipe", "pipe", "pipe"] });
    const timeout = setTimeout(() => child.kill("SIGKILL"), 5000);
    let output = "";
    let errors = "";
    child.stdout.on("data", chunk => { output += chunk; });
    child.stderr.on("data", chunk => { errors += chunk; });
    const exited = once(child, "exit");
    child.stdin.end(JSON.stringify({ redis: connection, queueName: queue.name, prefix: "bull", action, payload }));
    try {
      const [code] = await exited;
      assert.equal(code, 0, errors || output);
      const response = JSON.parse(output);
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
});
