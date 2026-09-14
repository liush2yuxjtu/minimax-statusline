"use strict";

const endpointRaw = process.env.PI_USAGE_SEND_ENDPOINT || "";
const payloadRaw = process.env.PI_USAGE_SEND_PAYLOAD || "";

(async () => {
  try {
    const endpoint = new URL(endpointRaw);
    if (endpoint.protocol !== "https:" || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) return;
    const events = JSON.parse(payloadRaw);
    if (!Array.isArray(events)) return;
    await Promise.all(events.slice(0, 5).map(async (event) => {
      try {
        await fetch(endpoint, {
          method: "POST",
          redirect: "error",
          headers: { "content-type": "application/json" },
          signal: AbortSignal.timeout(500),
          body: JSON.stringify(event),
        });
      } catch { /* at-most-once: no retry queue */ }
    }));
  } catch { /* detached telemetry must never affect statusline */ }
})();
