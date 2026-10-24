const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

function createHost() {
  const messages = [];
  const engines = [];
  class FakeEngine {
    constructor() {
      engines.push(this);
      this.bps = undefined;
      this.results = {
        getDownloadBandwidth: () => this.bps,
        getUploadBandwidth: () => this.bps
      };
    }
    play() {}
    pause() { this.paused = true; }
  }
  const context = {
    SpeedTest: FakeEngine,
    navigator: { onLine: true },
    window: { chrome: { webview: { postMessage: value => messages.push(JSON.parse(value)) } } }
  };
  const source = fs.readFileSync(path.join(
    __dirname, "..", "src", "FingVibe.App", "Assets", "SpeedTest", "speedtest-host.js"
  ), "utf8").replace('import SpeedTest from "./speedtest.js";', "");
  vm.runInNewContext(source, context);
  return { host: context.window.fingvibeSpeedTest, messages, engines };
}

const runId = "a".repeat(32);

test("emits positive bandwidth only for the current bandwidth phase", () => {
  const { host, messages, engines } = createHost();
  assert.equal(host.start(runId), true);
  const engine = engines[0];
  engine.onPhaseChange({ measurement: { type: "download" } });
  for (const value of [undefined, NaN, Infinity, 0, -1]) {
    engine.bps = value;
    engine.onResultsChange({ type: "download" });
  }
  assert.equal(messages.filter(m => m.kind === "sample").length, 0);
  engine.bps = 125000000;
  engine.onResultsChange({ type: "download" });
  assert.deepEqual(messages.at(-1), { kind: "sample", runId, phase: "download", bps: 125000000 });
  engine.onPhaseChange({ measurement: { type: "latency" } });
  const count = messages.length;
  engine.onResultsChange({ type: "download" });
  engine.onResultsChange({ type: "latency" });
  assert.equal(messages.length, count);
  engine.onPhaseChange({ measurement: { type: "upload" } });
  engine.onResultsChange({ type: "upload" });
  assert.equal(messages.at(-1).phase, "upload");
});

test("cancel and retry suppress old engine samples, including captured callbacks", () => {
  const { host, messages, engines } = createHost();
  host.start(runId);
  const engine = engines[0];
  engine.onPhaseChange({ measurement: { type: "download" } });
  engine.bps = 100;
  const lateCallback = engine.onResultsChange;
  assert.equal(host.cancel(runId), true);
  assert.equal(engine.paused, true);
  const nextRun = "b".repeat(32);
  host.start(nextRun);
  const count = messages.length;
  lateCallback({ type: "download" });
  engine.onResultsChange({ type: "download" });
  assert.equal(messages.length, count);
});

test("failure and completion detach sample callbacks", () => {
  for (const terminal of ["error", "result"]) {
    const { host, messages, engines } = createHost();
    host.start(runId);
    const engine = engines[0];
    engine.bps = 100;
    engine.onPhaseChange({ measurement: { type: "download" } });
    const lateCallback = engine.onResultsChange;
    if (terminal === "error") engine.onError("rejected", 403);
    else engine.onFinish({ getSummary: () => ({ download: 100, upload: 50, latency: 10 }) });
    const count = messages.length;
    lateCallback({ type: "download" });
    engine.onResultsChange({ type: "download" });
    assert.equal(messages.length, count);
    assert.equal(messages.at(-1).kind, terminal);
  }
});
