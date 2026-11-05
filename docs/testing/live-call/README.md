# Local WebRTC call-audio fixture

This fixture exercises a browser's real WebRTC sender/receiver and audible receiver output without a remote service, another person, browser microphone permission, or camera access. It is useful for testing HeyNotch's selected-browser ScreenCaptureKit audio capture. It is **not a substitute for a real two-person, cross-device call**.

## Run

From the repository root, serve only the fixture directory on loopback:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory docs/testing/live-call
```

Open `http://127.0.0.1:8765/` in the browser being tested. The page makes no requests outside that local origin and configures no ICE/STUN/TURN server. The WebRTC peers exchange SDP in page memory and communicate locally. No call account or network meeting is created.

1. In HeyNotch select the browser under **Call audio**, select the intended microphone, and explicitly start meeting transcription after granting the app's required recording permissions.
2. Press **Start local call test** on the page. It plays generated speech three times, separated by quiet gaps, then automatically stops. Its only speaker connection is the receiver's WebRTC audio track.
3. Check that the receiver reports **connected**, packet/byte counts increase, and audio energy increases while speech is audible. Those observations verify the browser's transport/output, not HeyNotch itself.
4. Inspect HeyNotch's **Call audio** segments for the phrase below. Stop HeyNotch explicitly after the fixture ends; stopping the browser fixture does not stop HeyNotch's microphone.
5. **Stop test** aborts playback and closes both peers immediately. After stopping, **Save test report** downloads transport counters and known fixture text only. The report contains no microphone samples, captured call transcript, ICE addresses, or user account information.

Expected generated phrase:

> Call channel verification. Cobalt river forty two. The invoice is one hundred twenty seven dollars. Do not send it today.

Spelled-out and numeric equivalents of 42 and 127 are acceptable in a speech transcript. Check that **do not send** is retained. The clip is mono 16 kHz PCM. Regenerate it on macOS with `python3 docs/testing/live-call/generate_clip.py`; this uses the installed Samantha voice and does not access the microphone.

## What this does and does not establish

- Confirms local WebRTC/RTP transport and browser output when observed counters, connection state, and audible speech agree.
- Can confirm HeyNotch's real ScreenCaptureKit capture of that browser when the expected phrase appears under **Call audio**. A page report alone cannot establish capture success.
- Does not prove independent local microphone input. With speakers playing, the physical microphone can pick up an acoustic copy of this same phrase. Seeing the phrase in both channels is evidence of leakage, not independent two-sided call capture or diarization.
- Independent microphone verification requires separate speech at the selected physical input, ideally with headphones isolating the fixture's receiver output. Real cross-device calls, muted/unmuted states, app filtering, device swaps, echo cancellation, latency, and long-session behavior still need separate tests.
- No browser `getUserMedia` call, microphone track, camera track, network account, telemetry, analytics, external font, STUN server, or TURN server is present. Host ICE networking is limited to the two peers on this Mac; the page's HTTP requests remain at the loopback server.
- Safari/Chromium versions may differ in autoplay and WebRTC behavior. A connection/permission/output failure is reported rather than counted as a successful capture. Browser audio must be allowed for the test to be audible.
- The page reports local ICE candidate counts/types, mDNS candidate counts, ICE/signaling state, and candidate-error codes without recording IP addresses or full SDP. Zero candidates explicitly fails the test instead of waiting for an unexplained connection timeout. WebKit has documented restrictions on exposing host ICE candidates before camera/microphone access is granted; a permission-free, server-free fixture can therefore be unavailable in Safari or a restricted web view. This is a plausible browser-policy failure, not evidence that HeyNotch capture failed. Do not disable browser security protections to force the test. [WebKit's WebRTC privacy explanation](https://webkit.org/blog/7763/a-closer-look-into-webrtc/).
- The sender starts a silent audio source during negotiation so its media graph is active before speech begins. Transport readiness accepts ICE connected/completed as well as aggregate connection connected, accommodating browser timing differences; increasing received RTP counters remains the evidence that media actually traversed the connection.

## Static checks

```sh
node --check docs/testing/live-call/test.js
python3 -m py_compile docs/testing/live-call/generate_clip.py
```

These checks validate source syntax only. They do not mark live transport or HeyNotch capture as passed.
