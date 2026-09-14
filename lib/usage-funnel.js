"use strict";
const { createHash, randomUUID } = require("node:crypto");
const { spawn } = require("node:child_process");
const { mkdir, readFile, rename, rm, writeFile } = require("node:fs/promises");
const { homedir } = require("node:os");
const { dirname, join } = require("node:path");
const CI_KEYS = ["CI", "GITHUB_ACTIONS", "GITLAB_CI", "TF_BUILD", "JENKINS_URL", "TEAMCITY_VERSION", "BUILDKITE", "CIRCLECI", "TRAVIS", "BITBUCKET_BUILD_NUMBER", "BUILD_ID"];
function truthy(name) { const value = String(process.env[name] || "").trim().toLowerCase(); return !!value && value !== "0" && value !== "false" && value !== "no"; }
function isCI() { return CI_KEYS.some(truthy); }
function day(now) { return new Date(now).toISOString().slice(0, 10); }
function week(now) { const d = new Date(now); d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7)); return d.toISOString().slice(0, 10); }
function endpoint() {
  if (!truthy("PI_USAGE_TELEMETRY") || !truthy("PI_USAGE_TELEMETRY_PRIVACY_ACK")) return;
  if (truthy("DO_NOT_TRACK") || truthy("PI_TELEMETRY_DISABLED") || isCI()) return;
  try { const url = new URL(process.env.PI_USAGE_TELEMETRY_ENDPOINT || ""); return url.protocol === "https:" && !url.username && !url.password && !url.search && !url.hash ? url : undefined; } catch { return; }
}
function stateFile(packageName) {
  const root = process.platform === "win32" ? (process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local")) : (process.env.XDG_CONFIG_HOME || join(homedir(), ".config"));
  return join(root, "liushiyu-usage-funnel", `${createHash("sha256").update(packageName).digest("hex")}.json`);
}
function detachSend(url, events, state, packageName, version) {
  if (!events.length) return;
  const payload = events.map((event) => ({
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
  }));
  try {
    const child = spawn(process.execPath, [join(__dirname, "usage-send.js")], {
      detached: true,
      stdio: "ignore",
      env: {
        PI_USAGE_SEND_ENDPOINT: url.href,
        PI_USAGE_SEND_PAYLOAD: JSON.stringify(payload),
      },
    });
    child.unref();
  } catch { /* delivery is best-effort and never blocks statusline */ }
}
function createUsageFunnel(packageName, version) {
  let queue = Promise.resolve();
  async function record(success) {
    const url = endpoint(); if (!url) return;
    const file = stateFile(packageName), lock = `${file}.lock`;
    let state, locked = false, temporary;
    const events = [];
    try {
      await mkdir(dirname(file), { recursive: true, mode: 0o700 });
      await mkdir(lock, { mode: 0o700 }); locked = true;
      try {
        state = JSON.parse(await readFile(file, "utf8"));
        if (!state || state.schema !== 1 || typeof state.id !== "string" || typeof state.lastDay !== "string" || typeof state.firstSuccess !== "boolean" || typeof state.returned !== "boolean") return;
      } catch (error) { if (error?.code !== "ENOENT") return; }
      const now = Date.now(), today = day(now), currentWeek = week(now);
      if (!state) { state = { schema: 1, id: randomUUID(), lastDay: today, firstSuccess: false, returned: false, week: null }; events.push("first_install", "first_launch"); }
      else if (!state.returned && state.lastDay < today) { state.returned = true; events.push("returning_user"); }
      state.lastDay = today;
      if (state.week !== currentWeek) { state.week = currentWeek; events.push("weekly_active"); }
      if (success && !state.firstSuccess) { state.firstSuccess = true; events.push("first_success"); }
      temporary = `${file}.${randomUUID()}.tmp`;
      await writeFile(temporary, JSON.stringify(state), { mode: 0o600, flag: "wx" });
      await rename(temporary, file); temporary = undefined;
    } catch { return; }
    finally {
      if (temporary) await rm(temporary, { force: true }).catch(() => undefined);
      if (locked) await rm(lock, { recursive: true, force: true }).catch(() => undefined);
    }
    if (state) detachSend(url, events, state, packageName, version);
  }
  const enqueue = (success) => { queue = queue.then(() => record(success)).catch(() => undefined); return queue; };
  return { launch: () => enqueue(false), success: () => enqueue(true) };
}
module.exports = { createUsageFunnel };
