#!/usr/bin/env node
// minimax-statusline.js — npm wrapper that execFile's the bash script.
// Lives at the bin/ entry in package.json; on `npm i -g` it ends up on PATH
// as `minimax-statusline`. On Windows, the .cmd shim points here.
"use strict";
const { spawn } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const { createUsageFunnel } = require("../lib/usage-funnel.js");
const { version } = require("../package.json");

const funnel = createUsageFunnel("@liushiyumathxjtu/minimax-statusline", version);
void funnel.launch();

const script = path.join(__dirname, "..", "minimax-statusline.sh");
if (!fs.existsSync(script)) {
  process.stderr.write(`minimax-statusline.sh not found at ${script}\n`);
  process.exit(127);
}

const child = spawn("bash", [script, ...process.argv.slice(2)], {
  stdio: "inherit",
});
child.on("error", (error) => {
  process.stderr.write(`failed to launch minimax-statusline.sh: ${error.message}\n`);
  process.exit(127);
});
child.on("exit", async (code) => {
  if (code === 0) await funnel.success();
  process.exit(code ?? 0);
});
