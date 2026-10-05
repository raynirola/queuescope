import { Job, Queue } from "bullmq";
import cronParser from "cron-parser";
const { parseExpression } = cronParser;

function readStdin() {
  return new Promise((resolve, reject) => {
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => {
      input += chunk;
    });
    process.stdin.on("end", () => resolve(input));
    process.stdin.on("error", reject);
  });
}

function requiredString(value, name) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Missing ${name}.`);
  }
  return value;
}

function requiredObject(value, name) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Missing ${name}.`);
  }
  return value;
}

function redisConnection(redis) {
  const connection = {
    host: requiredString(redis.host, "redis.host"),
    port: Number(redis.port),
    db: Number(redis.database ?? 0)
  };

  if (!Number.isInteger(connection.port) || connection.port <= 0) {
    throw new Error("Invalid redis.port.");
  }
  if (!Number.isInteger(connection.db) || connection.db < 0) {
    throw new Error("Invalid redis.database.");
  }
  if (typeof redis.username === "string" && redis.username.length > 0) {
    connection.username = redis.username;
  }
  if (typeof redis.password === "string" && redis.password.length > 0) {
    connection.password = redis.password;
  }
  if (redis.useTLS === true) {
    connection.tls = redis.tlsServerName ? { servername: redis.tlsServerName } : {};
  }

  return connection;
}

async function getJob(queue, jobID) {
  const job = await Job.fromId(queue, requiredString(jobID, "jobID"));
  if (!job) {
    throw new Error(`Job ${jobID} was not found.`);
  }
  return job;
}

function duplicateOptions(rawOptions) {
  if (rawOptions === null || typeof rawOptions !== "object" || Array.isArray(rawOptions)) {
    throw new Error("Duplicate options must be a JSON object.");
  }

  const options = { ...rawOptions };

  // These fields are persisted/internal identity or relationship fields. Reusing
  // them can either collide with the copied job or pass object values into
  // BullMQ's Lua scripts where only strings/numbers are valid.
  for (const key of [
    "jobId",
    "repeat",
    "repeatJobKey",
    "prevMillis",
    "parent",
    "parentKey",
    "de"
  ]) {
    delete options[key];
  }

  return options;
}

function addOptions(rawOptions) {
  if (rawOptions === null || typeof rawOptions !== "object" || Array.isArray(rawOptions)) {
    throw new Error("Options must be a JSON object.");
  }
  return rawOptions;
}

// Uses the same cron-parser version as the pinned BullMQ package. The stored
// next occurrence is authoritative; later dates assume the default strategy.
function schedulerPreview(scheduler, payload) {
  const timeZone = payload.timeZone || scheduler.tz || payload.systemTimeZone || Intl.DateTimeFormat().resolvedOptions().timeZone;
  // Validate overrides before calculating dates instead of silently dropping projections.
  new Intl.DateTimeFormat("en", { timeZone }).format();
  const fields = Object.fromEntries(Object.entries(scheduler)
    .filter(([key, value]) => key !== "template" && value !== null && value !== undefined)
    .map(([key, value]) => [key, String(value)]));
  fields.previewTimeZone = timeZone;
  fields.previewTimeZoneSource = payload.timeZone ? "override" : scheduler.tz ? "recorded" : "system";
  const kind = scheduler.iterationCount !== undefined ? "scheduler" : "legacy";
  const times = [];
  const maximum = scheduler.limit !== undefined && scheduler.iterationCount !== undefined
    ? Math.max(0, Math.min(5, scheduler.limit - scheduler.iterationCount + 1)) : 5;
  const every = Number(scheduler.every);
  const next = Number(scheduler.next);
  const end = Number(scheduler.endDate) || Infinity;
  const offset = every > 0 ? Number(scheduler.offset) || 0 : 0;
  if (Number.isFinite(next) && next > 0 && next + offset <= end && maximum > 0) times.push(next + offset);
  let message = "Stored next occurrence followed by estimates using BullMQ's default repeat strategy. Worker availability can delay runs; custom repeat strategies are not represented.";
  try {
    if (scheduler.pattern) {
      const interval = parseExpression(scheduler.pattern, {
        currentDate: Math.max(next || 0, Date.now(), Number(scheduler.startDate) || 0),
        tz: timeZone,
        ...(Number.isFinite(end) ? { endDate: end } : {})
      });
      while (times.length < maximum && interval.hasNext()) times.push(interval.next().getTime());
    } else if (every > 0 && times.length > 0) {
      while (times.length < maximum) {
        const time = times[times.length - 1] + every;
        if (time > end) break;
        times.push(time);
      }
    } else {
      message = "Only the stored next occurrence is available; this cadence cannot be projected.";
    }
  } catch {
    message = "Only the stored next occurrence is available; the cron pattern or timezone cannot be projected.";
  }
  if (fields.previewTimeZoneSource === "system") message += ` No timezone is recorded; estimates assume your Mac's timezone (${timeZone}). Choose the worker's timezone if different.`;
  if (fields.previewTimeZoneSource === "override") message += ` Estimates use your selected timezone (${timeZone}); the saved schedule is unchanged.`;
  if (kind === "legacy") message += " Legacy repeat metadata may omit iteration limits.";
  return { fields, kind, times, message };
}

async function run(request) {
  const redis = requiredObject(request.redis, "redis");
  const queueName = requiredString(request.queueName, "queueName");
  const prefix = requiredString(request.prefix, "prefix");
  const action = requiredString(request.action, "action");
  const payload = request.payload ?? {};
  const queue = new Queue(queueName, {
    prefix,
    skipMetasUpdate: action === "schedulerPreview",
    connection: redisConnection(redis)
  });

  try {
    switch (action) {
    case "schedulerPreview": {
      const key = requiredString(payload.key, "key");
      const scheduler = await queue.getJobScheduler(key);
      if (!scheduler || scheduler.next === null || scheduler.next === undefined) throw new Error("This schedule is no longer registered. Refresh the schedulers list.");
      return { preview: schedulerPreview(scheduler, payload) };
    }
    case "removeScheduler": {
      const key = requiredString(payload.key, "key");
      const scheduler = await queue.getJobScheduler(key);
      if (!scheduler || scheduler.next === null || scheduler.next === undefined) throw new Error("This schedule is no longer registered. Refresh the schedulers list.");
      const kind = scheduler.iterationCount !== undefined ? "scheduler" : "legacy";
      if (payload.kind !== kind) throw new Error("Schedule type changed. Inspect it again before removing.");
      const removed = kind === "scheduler" ? await queue.removeJobScheduler(key) : await queue.removeRepeatableByKey(key);
      if (!removed) throw new Error("Schedule was not removed. Refresh and inspect it before retrying.");
      return { removed: true };
    }
    case "clean": {
      const { state, grace, limit } = payload;
      if (!["completed", "failed"].includes(state)) throw new Error("Cleanup supports only retained completed or failed jobs.");
      if (!Number.isSafeInteger(grace) || grace < 60000) throw new Error("Cleanup age must be at least one minute.");
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000) throw new Error("Cleanup limit must be between 1 and 1000.");
      const removed = await queue.clean(grace, limit, state);
      return { removedCount: removed.length };
    }
    case "pause":
      await queue.pause();
      return { paused: true };
    case "resume":
      await queue.resume();
      return { paused: false };
    case "retry": {
      const job = await getJob(queue, payload.jobID);
      const state = requiredString(payload.state, "state");
      if (state !== "failed" && state !== "completed") {
        throw new Error("Retry supports only failed or completed jobs.");
      }
      await job.retry(state);
      return { jobID: job.id };
    }
    case "remove": {
      const job = await getJob(queue, payload.jobID);
      await job.remove({ removeChildren: payload.removeChildren !== false });
      return { jobID: job.id };
    }
    case "promote": {
      const job = await getJob(queue, payload.jobID);
      await job.promote();
      return { jobID: job.id };
    }
    case "duplicate": {
      const name = requiredString(payload.name, "name");
      const data = payload.data ?? {};
      const options = duplicateOptions(payload.options ?? {});
      const job = await queue.add(name, data, options);
      return { jobID: job.id };
    }
    case "add": {
      const name = requiredString(payload.name, "name");
      const data = payload.data ?? {};
      const options = addOptions(payload.options ?? {});
      const job = await queue.add(name, data, options);
      return { jobID: job.id };
    }
    default:
      throw new Error(`Unsupported action: ${action}.`);
    }
  } finally {
    await queue.close();
  }
}

try {
  const rawInput = await readStdin();
  const request = JSON.parse(rawInput);
  const result = await run(request);
  process.stdout.write(`${JSON.stringify({ ok: true, result })}\n`);
} catch (error) {
  process.stdout.write(`${JSON.stringify({
    ok: false,
    error: error instanceof Error ? error.message : String(error)
  })}\n`);
  process.exitCode = 1;
}
