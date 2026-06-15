import { Job, Queue } from "bullmq";

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
    connection.tls = {};
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

async function run(request) {
  const redis = requiredObject(request.redis, "redis");
  const queueName = requiredString(request.queueName, "queueName");
  const prefix = requiredString(request.prefix, "prefix");
  const action = requiredString(request.action, "action");
  const payload = request.payload ?? {};
  const queue = new Queue(queueName, {
    prefix,
    connection: redisConnection(redis)
  });

  try {
    switch (action) {
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
