"use strict";
const { createHash, randomUUID } = require("node:crypto");
const { mkdir, readFile, rename, rm, writeFile } = require("node:fs/promises");
const { homedir } = require("node:os");
const { dirname, join } = require("node:path");

function truthy(name) {
  const value = String(process.env[name] || "").trim().toLowerCase();
  return value === "1" || value === "true" || value === "yes";
}
function day(now) { return new Date(now).toISOString().slice(0, 10); }
function week(now) {
  const d = new Date(now);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}
function endpoint() {
  if (!truthy("PI_USAGE_TELEMETRY") || !truthy("PI_USAGE_TELEMETRY_PRIVACY_ACK")) return;
  if (truthy("DO_NOT_TRACK") || truthy("PI_TELEMETRY_DISABLED") || truthy("CI") || truthy("GITHUB_ACTIONS")) return;
  try {
    const url = new URL(process.env.PI_USAGE_TELEMETRY_ENDPOINT || "");
    return url.protocol === "https:" && !url.username && !url.password && !url.search && !url.hash ? url : undefined;
  } catch { return; }
}
function stateFile(packageName) {
  const root = process.platform === "win32"
    ? (process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local"))
    : (process.env.XDG_CONFIG_HOME || join(homedir(), ".config"));
  return join(root, "liushiyu-usage-funnel", `${createHash("sha256").update(packageName).digest("hex")}.json`);
}
async function send(url, event, state, packageName, version) {
  try {
    await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      signal: AbortSignal.timeout(500),
      body: JSON.stringify({
        schema_version: 1,
        event,
        event_id: randomUUID(),
        anonymous_install_id: state.id,
        package: packageName,
        version,
        timestamp: new Date().toISOString(),
        os: process.platform,
        node_major: Number(process.versions.node.split(".")[0]),
        ci: false,
      }),
    });
  } catch {}
}
function createUsageFunnel(packageName, version) {
  let queue = Promise.resolve();
  async function record(success) {
    const url = endpoint();
    if (!url) return;
    const file = stateFile(packageName);
    const now = Date.now();
    const today = day(now);
    const currentWeek = week(now);
    let state;
    try { state = JSON.parse(await readFile(file, "utf8")); } catch { state = undefined; }
    const events = [];
    if (!state || state.schema !== 1 || typeof state.id !== "string") {
      state = { schema: 1, id: randomUUID(), lastDay: today, firstSuccess: false, returned: false, week: null };
      events.push("first_install", "first_launch");
    } else if (!state.returned && state.lastDay < today) {
      state.returned = true;
      events.push("returning_user");
    }
    state.lastDay = today;
    if (state.week !== currentWeek) {
      state.week = currentWeek;
      events.push("weekly_active");
    }
    if (success && !state.firstSuccess) {
      state.firstSuccess = true;
      events.push("first_success");
    }
    let temporary;
    try {
      await mkdir(dirname(file), { recursive: true, mode: 0o700 });
      temporary = `${file}.${randomUUID()}.tmp`;
      await writeFile(temporary, JSON.stringify(state), { mode: 0o600, flag: "wx" });
      await rename(temporary, file);
      temporary = undefined;
      await Promise.all(events.map((event) => send(url, event, state, packageName, version)));
    } catch {
      if (temporary) await rm(temporary, { force: true }).catch(() => undefined);
    }
  }
  const enqueue = (success) => {
    queue = queue.then(() => record(success)).catch(() => undefined);
    return queue;
  };
  return { launch: () => enqueue(false), success: () => enqueue(true) };
}
module.exports = { createUsageFunnel };
