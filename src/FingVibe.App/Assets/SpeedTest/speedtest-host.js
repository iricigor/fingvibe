import SpeedTest from "./speedtest.js";

let engine = null;
let activeRunId = null;

function post(message) {
  window.chrome.webview.postMessage(JSON.stringify(message));
}

function reportError(runId, category, message, status) {
  post({
    kind: "error",
    runId,
    category,
    message: String(message || "Cloudflare could not complete the measurement.").slice(0, 500),
    ...(Number.isInteger(status) && status >= 100 && status <= 599 ? { status } : {})
  });
}

function classifyError(message, status) {
  if (!navigator.onLine) return "offline";
  if (status === 429) return "rate-limited";
  if (Number.isInteger(status) && status >= 500) return "provider-unavailable";
  if (Number.isInteger(status) && status >= 400) return "rejected";
  if (/timeout|timed out|exceeded bandwidthAbortRequestDuration/i.test(message)) return "timeout";
  return "measurement";
}

function detach(runId, currentEngine, pause) {
  if (activeRunId !== runId || engine !== currentEngine) return;

  activeRunId = null;
  engine = null;
  currentEngine.onError = () => {};
  currentEngine.onFinish = () => {};
  currentEngine.onPhaseChange = () => {};
  if (pause) currentEngine.pause();
}

function start(runId) {
  if (typeof runId !== "string" || !/^[0-9a-f]{32}$/.test(runId)) return false;
  if (engine !== null || activeRunId !== null) {
    reportError(runId, "measurement", "A Cloudflare measurement is already active.");
    return false;
  }

  activeRunId = runId;
  if (!navigator.onLine) {
    reportError(runId, "offline", "This device is offline.");
    activeRunId = null;
    return false;
  }

  try {
    const currentEngine = new SpeedTest({ autoStart: false });
    engine = currentEngine;
    currentEngine.onPhaseChange = ({ measurement }) => {
      if (activeRunId === runId && engine === currentEngine) {
        post({ kind: "progress", runId, phase: measurement.type });
      }
    };
    currentEngine.onError = (message, status) => {
      if (activeRunId !== runId || engine !== currentEngine) return;
      reportError(runId, classifyError(String(message), status), message, status);
      detach(runId, currentEngine, true);
    };
    currentEngine.onFinish = results => {
      if (activeRunId !== runId || engine !== currentEngine) return;
      const summary = results.getSummary();
      if (![summary.download, summary.upload, summary.latency].every(
        value => Number.isFinite(value) && value > 0
      )) {
        reportError(runId, "incomplete", "Cloudflare did not return all required measurements.");
        detach(runId, currentEngine, true);
        return;
      }

      post({
        kind: "result",
        runId,
        downloadBps: summary.download,
        uploadBps: summary.upload,
        latencyMs: summary.latency,
        location: null
      });
      detach(runId, currentEngine, false);
    };
    currentEngine.play();
    return true;
  } catch (error) {
    if (activeRunId === runId) {
      reportError(runId, "measurement", error instanceof Error ? error.message : String(error));
      if (engine !== null) detach(runId, engine, true);
      else activeRunId = null;
    }
    return false;
  }
}

function cancel(runId) {
  if (typeof runId !== "string" || activeRunId !== runId || engine === null) return false;

  const currentEngine = engine;
  detach(runId, currentEngine, true);
  post({ kind: "cancelled", runId });
  return true;
}

window.fingvibeSpeedTest = Object.freeze({ start, cancel });
