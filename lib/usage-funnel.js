"use strict";

const DEFAULT_ENDPOINT = "https://telemetry-peach.vercel.app/api/events";

function truthy(name) {
  const value = String(process.env[name] || "").trim().toLowerCase();
  return !!value && value !== "0" && value !== "false" && value !== "no";
}

function createUsageFunnel(packageName, version) {
  let telemetryPromise;
  const telemetry = () => {
    if (!telemetryPromise) {
      telemetryPromise = import("@nyn5255/telemetry").then(({ createTelemetry }) =>
        createTelemetry({
          package: packageName,
          version,
          enabled: truthy("PI_USAGE_TELEMETRY"),
          collectorPrivacyAcknowledged: truthy("PI_USAGE_TELEMETRY_PRIVACY_ACK"),
          endpoint: process.env.PI_USAGE_TELEMETRY_ENDPOINT || DEFAULT_ENDPOINT,
        }),
      );
    }
    return telemetryPromise;
  };

  return {
    async launch() {
      const client = await telemetry();
      await client.install();
      await client.activated();
      await client.active();
    },
    async success() {
      const client = await telemetry();
      await client.success();
    },
  };
}

module.exports = { createUsageFunnel };
