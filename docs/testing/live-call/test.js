"use strict";

const ui = Object.fromEntries(["start", "stop", "report", "status", "sender", "receiver", "elapsed", "packets", "bytes", "energy", "context", "senderIce", "receiverIce", "senderCandidates", "receiverCandidates", "diagnostics"].map(id => [id, document.getElementById(id)]));
const phrase = "Call channel verification. Cobalt river forty two. The invoice is one hundred twenty seven dollars. Do not send it today.";
let active = null;
let lastReport = null;
let sequence = 0;

function status(message) { ui.status.textContent = message; }
function ensureCurrent(run) { if (active !== run) throw new DOMException("Test stopped", "AbortError"); }
function diagnostic(run, text) {
  run.diagnostics.push(text);
  if (active === run) ui.diagnostics.textContent = run.diagnostics.slice(-24).join("\n");
}
function inspectCandidates(run, label, peer) {
  const lines = (peer.localDescription?.sdp || "").split(/\r?\n/).filter(line => line.startsWith("a=candidate:"));
  const types = lines.map(line => line.match(/ typ (\w+)/)?.[1] || "unknown");
  const mdns = lines.filter(line => /\.local(?:\s|$)/.test(line)).length;
  const summary = { count: lines.length, types, mdnsCount: mdns };
  run.candidates[label] = summary;
  ui[`${label}Candidates`].textContent = `${lines.length} (${[...new Set(types)].join(", ") || "none"}; ${mdns} mDNS)`;
  diagnostic(run, `${label}: gathered ${lines.length} candidates; types=${types.join(",") || "none"}; mDNS=${mdns}`);
  return lines.length;
}

function waitForTransport(peer, signal) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timer); peer.removeEventListener("connectionstatechange", changed);
      peer.removeEventListener("iceconnectionstatechange", changed); signal.removeEventListener("abort", aborted);
    };
    const changed = () => {
      if (peer.connectionState === "connected" || ["connected", "completed"].includes(peer.iceConnectionState)) { cleanup(); resolve(); }
      else if (peer.connectionState === "failed" || peer.iceConnectionState === "failed") { cleanup(); reject(new Error("Local ICE/DTLS transport failed")); }
    };
    const aborted = () => { cleanup(); reject(new DOMException("Test stopped", "AbortError")); };
    const timer = setTimeout(() => { cleanup(); reject(new Error(`Transport timed out: connection=${peer.connectionState}, ICE=${peer.iceConnectionState}, signaling=${peer.signalingState}`)); }, 20000);
    peer.addEventListener("connectionstatechange", changed); peer.addEventListener("iceconnectionstatechange", changed);
    signal.addEventListener("abort", aborted, { once: true });
    if (signal.aborted) aborted(); else changed();
  });
}

function waitFor(peer, event, predicate, timeoutMs, signal) {
  if (predicate()) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timer); peer.removeEventListener(event, changed); signal.removeEventListener("abort", aborted);
    };
    const changed = () => { if (predicate()) { cleanup(); resolve(); } };
    const aborted = () => { cleanup(); reject(new DOMException("Test stopped", "AbortError")); };
    const timer = setTimeout(() => { cleanup(); reject(new Error(`Timed out waiting for ${event}`)); }, timeoutMs);
    peer.addEventListener(event, changed); signal.addEventListener("abort", aborted, { once: true });
    if (signal.aborted) aborted();
  });
}

async function sampleStats(run) {
  if (active !== run) return;
  const stats = await run.receiver.getStats();
  if (active !== run) return;
  let packets = 0, bytes = 0, energy = 0;
  for (const item of stats.values()) {
    if (item.type === "inbound-rtp" && (item.kind === "audio" || item.mediaType === "audio")) {
      packets += item.packetsReceived || 0;
      bytes += item.bytesReceived || 0;
      energy += item.totalAudioEnergy || 0;
    }
  }
  run.elapsedSeconds = (performance.now() - run.startedAt) / 1000;
  ui.elapsed.textContent = `${run.elapsedSeconds.toFixed(1)} seconds`;
  ui.packets.textContent = String(packets); ui.bytes.textContent = String(bytes);
  ui.energy.textContent = energy.toFixed(5); ui.context.textContent = run.context.state;
  run.samples.push({ seconds: Number(run.elapsedSeconds.toFixed(2)), packetsReceived: packets, bytesReceived: bytes, totalAudioEnergy: energy });
}

async function stop(reason = "Stopped by user.") {
  const run = active;
  if (!run) return;
  active = null; ++sequence;
  const stateAtStop = { sender: { connection: run.sender.connectionState, ice: run.sender.iceConnectionState, signaling: run.sender.signalingState }, receiver: { connection: run.receiver.connectionState, ice: run.receiver.iceConnectionState, signaling: run.receiver.signalingState } };
  run.abort.abort(); clearInterval(run.interval); clearTimeout(run.limit);
  for (const source of run.sources) { try { source.stop(); } catch {} source.disconnect(); }
  if (run.receiveSource) run.receiveSource.disconnect();
  for (const track of run.outbound?.stream.getTracks() || []) track.stop();
  run.sender.close(); run.receiver.close();
  await run.context.close().catch(() => {});
  lastReport = {
    method: "Local two-peer WebRTC loopback; generated speech; no browser microphone or camera access",
    expectedPhrase: phrase, startedUTC: run.startedUTC, result: reason,
    plannedSpeechStartsSeconds: run.speechStarts || [], clipSeconds: run.clipSeconds || null,
    elapsedSeconds: Number(((performance.now() - run.startedAt) / 1000).toFixed(2)),
    receiverConnected: run.connected, receivedTrack: Boolean(run.receiveSource), samples: run.samples,
    candidates: run.candidates, diagnostics: run.diagnostics, stateAtStop,
    limitations: "Browser RTP/output only. HeyNotch capture, independent physical microphone speech, remote-human speech, hardware isolation, echo and cross-device networking must be verified separately."
  };
  ui.sender.textContent = "Closed"; ui.receiver.textContent = "Closed"; ui.context.textContent = "Closed";
  ui.senderIce.textContent = `${stateAtStop.sender.ice} → closed`; ui.receiverIce.textContent = `${stateAtStop.receiver.ice} → closed`;
  ui.start.disabled = false; ui.stop.disabled = true; ui.report.disabled = false;
  status(reason);
}

async function start() {
  if (active) return;
  if (!window.AudioContext || !window.RTCPeerConnection) { status("This browser does not expose the audio/WebRTC APIs needed for this test."); return; }
  ui.start.disabled = true; ui.stop.disabled = false; ui.report.disabled = true;
  for (const key of ["packets", "bytes", "energy", "senderCandidates", "receiverCandidates"]) ui[key].textContent = "0";
  ui.diagnostics.textContent = "Starting. Addresses and SDP are not logged.";
  ui.elapsed.textContent = "0.0 seconds";
  const token = ++sequence;
  const context = new AudioContext({ sampleRate: 48000 });
  const sender = new RTCPeerConnection({ iceServers: [], bundlePolicy: "max-bundle" });
  const receiver = new RTCPeerConnection({ iceServers: [], bundlePolicy: "max-bundle" });
  const run = { token, context, sender, receiver, abort: new AbortController(), sources: [], samples: [], candidates: {}, diagnostics: [], startedAt: performance.now(), startedUTC: new Date().toISOString(), connected: false };
  active = run;
  status("Preparing two local peers. Nothing is playing yet…");
  for (const [label, peer] of [["sender", sender], ["receiver", receiver]]) {
    peer.addEventListener("iceconnectionstatechange", () => {
      if (active !== run) return;
      ui[`${label}Ice`].textContent = peer.iceConnectionState;
      diagnostic(run, `${label}: ICE=${peer.iceConnectionState}, connection=${peer.connectionState}, signaling=${peer.signalingState}`);
    });
    peer.addEventListener("icecandidateerror", event => { if (active === run) diagnostic(run, `${label}: ICE candidate error code ${event.errorCode}`); });
  }
  sender.addEventListener("connectionstatechange", () => { if (active === run) ui.sender.textContent = sender.connectionState; });
  receiver.addEventListener("connectionstatechange", () => {
    if (active !== run) return;
    ui.receiver.textContent = receiver.connectionState;
    if (receiver.connectionState === "failed") void stop("WebRTC connection failed. No capture result can be inferred.");
  });
  receiver.addEventListener("track", event => {
    if (active !== run || event.track.kind !== "audio") return;
    // The only audible path is the remote peer's received track. The send
    // source is connected solely to a MediaStream destination, never speakers.
    run.receiveSource = context.createMediaStreamSource(new MediaStream([event.track]));
    run.receiveSource.connect(context.destination);
  });
  try {
    // Resume inside the explicit Start user gesture, before asynchronous work.
    await context.resume(); ensureCurrent(run);
    if (context.state !== "running") throw new Error("Browser audio is suspended. Allow playback and press Start again.");
    const response = await fetch("remote.wav", { signal: run.abort.signal });
    if (!response.ok) throw new Error("The generated speech file is unavailable.");
    const clip = await context.decodeAudioData(await response.arrayBuffer()); ensureCurrent(run);
    run.clipSeconds = clip.duration;
    run.outbound = context.createMediaStreamDestination();
    // Keep the sender graph active during negotiation. Some engines defer
    // media transport work for a destination with no active source connected.
    const silence = context.createConstantSource(); silence.offset.value = 0;
    silence.connect(run.outbound); silence.start(); run.sources.push(silence);
    sender.addTrack(run.outbound.stream.getAudioTracks()[0], run.outbound.stream);
    // Full SDP exchange after local gathering avoids candidate-order races.
    await sender.setLocalDescription(await sender.createOffer());
    await waitFor(sender, "icegatheringstatechange", () => sender.iceGatheringState === "complete", 10000, run.abort.signal); ensureCurrent(run);
    if (!inspectCandidates(run, "sender", sender)) throw new Error("No local ICE candidates were exposed by this browser. Its WebRTC privacy/network policy may prevent this permission-free local test. No security setting was changed.");
    await receiver.setRemoteDescription(sender.localDescription);
    await receiver.setLocalDescription(await receiver.createAnswer());
    await waitFor(receiver, "icegatheringstatechange", () => receiver.iceGatheringState === "complete", 10000, run.abort.signal); ensureCurrent(run);
    if (!inspectCandidates(run, "receiver", receiver)) throw new Error("The receiver has no local ICE candidates. This browser cannot complete the permission-free local test under its current network/privacy policy.");
    await sender.setRemoteDescription(receiver.localDescription);
    await waitForTransport(receiver, run.abort.signal); ensureCurrent(run);
    run.connected = true; run.startedAt = performance.now();
    const spacing = Math.max(15, clip.duration + 3);
    run.speechStarts = [2, 2 + spacing, 2 + 2 * spacing];
    for (const offset of run.speechStarts) {
      const source = context.createBufferSource(); source.buffer = clip;
      source.connect(run.outbound); source.start(context.currentTime + offset); run.sources.push(source);
    }
    run.interval = setInterval(() => { void sampleStats(run).catch(() => {}); }, 1000);
    run.limit = setTimeout(() => { void stop("Finished. Both local peers and audio playback are stopped."); }, (run.speechStarts[2] + clip.duration + 3) * 1000);
    status("Connected. Receiving generated call audio through WebRTC. The test will stop automatically.");
    await sampleStats(run);
  } catch (error) {
    if (active === run && token === sequence) await stop(`Test did not complete: ${error.message}`);
  }
}

ui.start.addEventListener("click", () => { void start(); });
ui.stop.addEventListener("click", () => { void stop(); });
ui.report.addEventListener("click", () => {
  if (!lastReport) return;
  const url = URL.createObjectURL(new Blob([JSON.stringify(lastReport, null, 2) + "\n"], { type: "application/json" }));
  const link = document.createElement("a"); link.href = url; link.download = "heynotch-local-call-test.json"; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
window.addEventListener("pagehide", () => { void stop("Page closed; local audio stopped."); });
