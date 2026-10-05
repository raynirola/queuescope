// Local integration fixture. It accepts only a loopback port, never a saved URL.
import { createRequire } from "node:module";
const { Queue, Worker, FlowProducer } = createRequire(import.meta.url)(process.argv[3] ?? "bullmq");
import { setTimeout as delay } from "node:timers/promises";
const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid test port");
const connection = { host: "127.0.0.1", port };
const queue = new Queue("feature-jobs", { connection });
const literal = new Queue("literal", { connection, prefix: "team[*]" });
const schedules = new Queue("schedules", { connection });
const outcomes = new Queue("outcomes", { connection });
const workers = [
  new Worker("workers", async () => {}, { connection, name: "visible" }),
  new Worker("workers", async () => {}, { connection: { ...connection, db: 1 }, name: "other-db" }),
  new Worker("outcomes", async job => { if (job.name === "failure") throw new Error("fixture failure"); return "done"; }, { connection })
];
const flow = new FlowProducer({ connection });
try {
  await queue.addBulk(Array.from({ length: 620 }, (_, index) => ({
    name: index === 0 ? "needle" : "ordinary", data: { index }, opts: { jobId: `job-${index}`, timestamp: Date.UTC(2026, 0, 1) }
  })));
  await literal.add("literal", {});
  await schedules.upsertJobScheduler("modern:custom:id", { every: 60000, limit: 3 }, { name: "modern", data: {} });
  await schedules.add("legacy", {}, { repeat: { every: 60000 } });
  const failed = await outcomes.add("failure", {}, { jobId: "outcome-failed" });
  for (let i = 0; i < 100 && await failed.getState() !== "failed"; i++) await delay(20);
  if (await failed.getState() !== "failed") throw new Error("Fixture failed job not ready");
  await flow.add({ name: "parent", queueName: "parents", opts: { jobId: "root" }, children: [
    { name: "child-a", queueName: "children", opts: { jobId: "child-a" }, children: [
      { name: "grandchild", queueName: "grandchildren", opts: { jobId: "grandchild" } }
    ] },
    { name: "child-b", queueName: "children", opts: { jobId: "child-b" } }
  ] });
  await flow.add({ name: "wide", queueName: "parents", opts: { jobId: "wide" }, children:
    Array.from({ length: 90 }, (_, index) => ({ name: "branch", queueName: "branches", opts: { jobId: `branch-${index}` } }))
  });
  await Promise.all(workers.map(worker => worker.waitUntilReady()));
  process.stdout.write("READY\n");
  for await (const chunk of process.stdin) {}
} finally {
  await Promise.all(workers.map(worker => worker.close()));
  await Promise.all([queue.close(), literal.close(), outcomes.close(), schedules.close(), flow.close()]);
}
