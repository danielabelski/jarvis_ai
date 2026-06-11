# Architecture & Protocols

## How a voice turn flows

1. Browser captures mic at 16 kHz mono (AudioContext created at 16 kHz —
   avoids resampling artifacts that wreck Whisper accuracy) and streams int16
   PCM over WebSocket `/ws`.
2. While you speak, the server runs incremental Whisper passes every ~1.2 s
   and emits `partial_transcript` events (live captions).
3. On stop: final Whisper pass → transcript sent to Hermes via its **Sessions
   API** (`POST /api/sessions/{id}/chat/stream`, SSE). Session ids persist in
   `logs/hermes_sessions.json` per conversation name, so memory survives
   restarts. Typed chat (`/api/chat`) uses the *same* session.
4. SSE events parsed: `run.started` (run id → STOP support), `assistant.delta`
   (text), `tool.started` (name + preview → HUD activity), `assistant.completed`
   (incl. `interrupted` flag), `run.completed` (token usage), `*approval*`
   (→ HUD approval cards).
5. Text is sentence-split, markdown/think-block-stripped, **secret-redacted**,
   then each sentence streams through ElevenLabs back to the client as raw PCM
   while generation continues.

Why the Sessions API and not `/v1/responses` or `/v1/runs`: on Hermes v0.16,
sessions are the only surface that combines named persistent memory, run ids,
tool events, and approval events in one stream.

## WebSocket protocol (voice clients)

Client → server (JSON + binary):

```
{"type":"start","sample_rate":16000,"format":"pcm_s16le","channels":1,"conversation":"jarvis-main"?}
<binary int16 PCM chunks>
{"type":"stop"}
{"type":"stop_run"}
{"type":"approval_decision","run_id":...,"approval_id":...,"decision":"allow"|"deny"}
```

`start` during an active turn = barge-in: the server cancels the turn, stops
the Hermes run, records the last spoken sentence, and prefixes the next turn's
input with an interruption note so the agent's memory matches what you heard.

Server → client:

```
status · partial_transcript · transcript · run_started{run_id}
agent_status{state: thinking|tool_use(+tool,preview)|speaking|stopped}
approval_request{data,run_id} · error · done{timing}
<binary TTS PCM — frames split at arbitrary byte boundaries; buffer odd bytes>
```

## HTTP endpoints (voice server)

| Endpoint | Purpose |
|---|---|
| `/hud/` | the HUD (static, single file) |
| `/api/hermes/{path}` | **allowlist** proxy to Hermes API, injects the bearer key (GET: health, capabilities, skills, toolsets, jobs, sessions; POST: v1/responses only) |
| `/api/chat` | typed chat turn on the shared voice session |
| `/api/machines` | host psutil stats + remote workers from config |
| `/api/usage` | local token/char tally + ElevenLabs quota (needs user_read on the key) |
| port 9443 (separate app) | TLS reverse proxy of the Hermes dashboard with WebSocket bridge and frame-header stripping, so the HTTPS HUD can iframe it |

## Auth model

`JARVIS_HUD_TOKEN` (env) gates `/api/*`, the dashboard proxy, and
browser-originated WebSockets (Origin allowlist + cookie). Native clients (the
PTT client, test scripts) send no Origin header and are exempt — the
threat model is a malicious *website* doing cross-origin requests against your
LAN, not your own processes. The Hermes API key never reaches any browser.

## Latency profile (Apple Silicon, small.en on CPU)

STT finalize ~0.7 s · Hermes first token 1–3 s (more with tools) · first
audible audio ~3 s · total simple turn ~4 s. The biggest lever is the LLM
behind Hermes; the second is the Whisper model size.

## Gotchas encoded in this repo (learned the hard way)

1. **SSE charset**: Hermes' event stream has no charset header; Python
   `requests` then decodes as Latin-1 → mojibake. The client forces UTF-8.
2. **macOS port 443**: non-root binds only work on the wildcard address
   (`0.0.0.0`), not a specific IP.
3. **launchd + external drives**: see launchd/*.plist comments (TCC hang on
   `getcwd`, EX_CONFIG from external log paths, venv-python invocation).
4. **Browser mic**: requires a secure context — hence the self-signed TLS and
   the per-device cert trust.
5. **ElevenLabs frames** arrive at arbitrary byte boundaries; decode only
   complete int16 pairs and carry the leftover byte.
