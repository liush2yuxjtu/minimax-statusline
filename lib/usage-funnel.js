"use strict";

const DEFAULT_ENDPOINT = "https://telemetry-peach.vercel.app/api/events";
const FEATURE = "statusline";

function truthy(name) {
  const value = String(process.env[name] || "").trim().toLowerCase();
  return !!value && value !== "0" && value !== "false" && value !== "no";
}

function configuredEndpoint() {
  const raw = process.env.PI_USAGE_TELEMETRY_ENDPOINT || DEFAULT_ENDPOINT;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) return undefined;
    return url.href;
  } catch {
    return undefined;
  }
}

function createUsageFunnel(packageName, version) {
  let clientPromise;
  async function client() {
    if (!clientPromise) {
      clientPromise = import("@nyn5255/telemetry").then(({ createTelemetry }) => createTelemetry({
        package: packageName,
        version,
        enabled: truthy("PI_USAGE_TELEMETRY"),
        endpoint: configuredEndpoint(),
        collectorPrivacyAcknowledged: truthy("PI_USAGE_TELEMETRY_PRIVACY_ACK"),
        features: [FEATURE],
        timeoutMs: 1000,
      })).catch(() => null);
    }
    return clientPromise;
  }

  async function launch() {
    const telemetry = await client();
    if (!telemetry) return;
    await telemetry.install();
    await telemetry.activated(FEATURE);
    await telemetry.active(FEATURE);
  }

  async function success() {
    const telemetry = await client();
    if (!telemetry) return;
    // Keep the process alive while the SDK's deliberately-unref'ed request is flushed.
    const keepAlive = setInterval(() => {}, 1000);
    try {
      await telemetry.success(FEATURE);
      await telemetry.flush();
    } finally {
      clearInterval(keepAlive);
    }
  }

  return { launch, success };
}

module.exports = { createUsageFunnel };
