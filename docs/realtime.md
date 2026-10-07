# Realtime client

`RealtimeClient` (in `Packages/BlauKit/Sources/BlauRealtime/Client/`) is
Blau's connection to the xAI Grok realtime voice API,
`wss://api.x.ai/v1/realtime?model=…` (issue #34). It owns one WebSocket at a
time, speaks typed events, keeps the connection alive and reopens it when it
drops. Session settings (#35), turn orchestration (#36), barge-in (#37), tools
(#38) and resumption (#39) are built on top of it.

```swift
let client = RealtimeClient(endpoint: config.xaiRealtimeURL, tokenProvider: services.tokenProvider)
try await client.connect()
try await client.send(.sessionUpdate(RealtimeSession(voice: "eve", turnDetection: .manual)))
try await client.send(.conversationItemCreate(.userText(utterance.text)))
try await client.send(.responseCreate())

for await event in client.events {
    switch event {
    case .responseOutputAudioDelta(let delta): player.enqueue(delta.audio)  // 24 kHz PCM16
    case .responseOutputAudioTranscriptDelta(let delta): transcript.append(delta.delta)
    case .responseDone(let done): finishTurn(done.response)
    case .unknown(let unknown): break  // logged by the client; never fatal
    default: break
    }
}
```

## Connecting

| Step | What happens |
| ---- | ------------ |
| Secret | `RealtimeTokenProviding.clientSecret()` (the on-device `TokenProvider`, see [xai-auth.md](xai-auth.md)) |
| Upgrade | `URLSessionWebSocketTask` with subprotocol `xai-client-secret.<secret>`. `URLSession` strips `Authorization` from the upgrade, so the secret can't go in a header |
| Refused secret | HTTP 401/403 on the upgrade: the secret is invalidated, one fresh secret is minted and tried. A second refusal is `RealtimeClientError.unauthorized` |
| Timeout | 10 s per upgrade (`connectTimeout`); a socket that opens just as it fires is closed, not leaked |
| Retries | Retryable failures (offline, timeouts, 5xx, 429) are retried with `RetryPolicy.realtimeReconnect`: 8 attempts, the first immediate, then 0.5, 1, 2, 4, 8, 10, 10 s (±20 % jitter). Key and account problems (`requiresUserAction`) fail at once |

`connect()` returns once a socket is open and joins an attempt already in
progress. The URL session is ephemeral, so neither the secret nor anything
else is written to disk by the URL loading system.

## Connection states

`client.states` yields every change of `client.state`:

```
disconnected(nil) → connecting(attempt: 1…) → connected
connected → reconnecting(attempt: 1…) → connected          after a drop
reconnecting(…) → disconnected(error)                      attempts exhausted, or not retryable
any → disconnected(nil)                                    disconnect()
```

Every connection is a new server session, so after each `.connected` the
owner sends its `session.update` again (`RealtimeSessionConfigurator.configure`,
see [Session configuration](#session-configuration)). Nothing is queued while
disconnected: `send(_:)` throws `notConnected`, and the caller decides what
still makes sense (a user utterance, yes; stale input audio, no). With
resumption (#39) the owner calls `setEndpoint(_:)` with `?conversation_id=` so
the next connection replays the conversation.

## Keepalive and drops

- A WebSocket ping goes out every 15 s (`keepAliveInterval`). No pong within
  10 s (`pongTimeout`) counts as a drop. This catches connections that died
  without an error, such as a phone moving between networks, which would
  otherwise only be noticed on the next send.
- A failed receive (ECONNRESET, a lost network), a failed send, a missed pong
  or a close frame from the server all go through the same path: the socket
  is torn down, `realtime.drop` is signposted, and the reconnect loop above
  starts at attempt 1 immediately. `realtime.reconnected` marks success.
- `URLSessionWebSocketTask` only reads a pong while a `receive()` is
  outstanding (verified on macOS 27; without one, pongs arrived in roughly
  two thirds of tries). The client's receive loop always has one in flight.

## Events

`RealtimeClientEvent` and `RealtimeServerEvent` are `Codable` enums that cover
every event in xAI's realtime reference
(<https://docs.x.ai/voice-realtime.ws.json>, fetched 2026-10-07):

- **Client:** `session.update`, `input_audio_buffer.append/commit/clear`,
  `conversation.item.create/delete/truncate`, `response.create`,
  `response.cancel`.
- **Server:** the 37 reference events, plus `conversation.item.created`
  (resumption replays history with it) and the older OpenAI-beta names xAI
  documents as equivalent (`response.text.delta`, `response.audio.delta`, …),
  which decode to their canonical case.
- **Unknown or malformed frames** decode to `.unknown(UnknownEvent)` with the
  raw bytes, and `decodingFailure` set when a known type didn't parse.
  `RealtimeEventCoding.decodeServerEvent` never throws, so a protocol change
  can't end a session.
- **Open enums.** Statuses, roles, content types and error types are
  string-backed structs with known constants, so a new value from the server
  decodes instead of failing the event.
- **Lenient payloads.** The reference marks almost no field as required, so
  ids and indices are optional; only fields an event is useless without (an
  audio delta's `delta`) are required.

Choices where xAI's documents disagree or are silent:

| Topic | Choice | Why |
| ----- | ------ | --- |
| Manual turns | `"turn_detection": {"type": null}` | The session parameters table documents `turn_detection.type` as `null` for manual text turns |
| Function tools | Written flat: `{"type": "function", "name", "description", "parameters"}`; both flat and nested `function: {…}` are read | The guide's "Custom Function Tools" examples (and the OpenAI GA format) are flat; only the AsyncAPI schema nests them |
| Text deltas | `response.output_text.delta` and `response.text.delta` are one case | The reference says they are functionally identical and to handle both |

### Binary audio

With `Configuration.inputAudioTransport = .binary`,
`.inputAudioBufferAppend(data)` goes out as a raw binary frame (no base64,
a third fewer bytes). Binary frames from the server (output transport
`binary`) arrive as `.responseOutputAudioDelta` with `isBinaryFrame` set and
the response, item and content index of the audio part in progress, taken
from the surrounding `response.created`, `response.output_item.added` and
`response.content_part.added`. The session's `audio.input.transport` and
`audio.output.transport` must still be set with `session.update`.

## Session configuration

Every connection is a new server session, so Blau configures it with one
complete `session.update` (issue #35). The code is in
`Packages/BlauKit/Sources/BlauRealtime/Session/`.

| Field | Value | Source |
| ----- | ----- | ------ |
| `turn_detection` | `{"type": null}`: manual turns | Fixed. Only verified utterances reach Grok, and manual sessions are billed for audio exchanged, not time open |
| `voice` | `eve` by default | Settings → Voice |
| `audio.output.format` | `{"type": "audio/pcm", "rate": 24000}` | Fixed: what the playback engine plays (#25) |
| `audio.output.transport` | `json` | Fixed (output is strict about transport, so it is set explicitly) |
| `audio.output.speed` | 0.7–1.5 in steps of 0.05, default 1.0 | Settings → Voice |
| `reasoning.effort` | `high` (default) or `none` | Settings → Voice ("Think Before Answering") |
| `instructions` | `RealtimeInstructions` | Persona, long-form style, short spoken answers, how to read transcribed input, tool guidance, ProfileBlock and active facts, today's date |
| `tools` | Only when there are tools (#38) | `RealtimeSessionConfigurator.setTools` |

Not sent: `audio.input` (Blau sends the *text* of utterances, never audio)
and `model` (it is on the WebSocket URL, see below).

```swift
let configurator = RealtimeSessionConfigurator(settings: voiceSettingsStore, memory: memoryContext)

// After every `.connected` (the owner of the client, #36, watches `client.states`):
try await configurator.configure(client)

// For the session's lifetime: push Settings changes to the live session.
await configurator.followSettingsChanges(sending: client)
```

- **Settings apply to the next `session.update`.** `RealtimeVoiceSettingsStore`
  is the single source of truth: Settings → Voice writes it (through
  `RealtimeVoiceSettingsModel`), it is saved in `UserDefaults`, and
  `configure(_:)` reads it each time. `followSettingsChanges(sending:)`
  debounces: every change restarts a 400 ms quiet period, and an update is
  sent only once the settings have gone a full 400 ms without changing
  (tracked by the store's `revision` counter). Dragging the speed slider
  therefore sends one update, with the final value, 400 to 800 ms after it
  is let go (the quiet period is checked once per 400 ms). While disconnected
  nothing is sent; the next `configure(_:)` carries the change.
- **Always complete.** Each update carries every field above, built from the
  settings and memory at that moment, so it never depends on an earlier
  update having arrived. If the settings change while an update is in
  flight, `configure(_:)` sends again so the last update on the wire is the
  latest.
- **Voices.** The built-in voices offered are Eve, Ara, Rex, Sal and Leo
  (`RealtimeVoice.builtIn`). `RealtimeVoice` is open, so any id from
  `GET /v1/tts/voices` or a custom voice id also works; built-in ids are sent
  lowercase, as xAI's guide asks.
- **Memory (M3).** `RealtimeMemoryContextProviding` supplies the ProfileBlock
  and active facts. BlauMemory is a sibling module, so the app's composition
  root adapts it; until then `NoRealtimeMemoryContext` leaves those sections
  out. User text is flattened so it can't add prompt sections, and capped
  (2,000 profile characters, 40 facts of 280 characters).

### Model pin and remote override

The model is pinned in `Config/Base.xcconfig` (`XAI_REALTIME_MODEL =
grok-voice-think-fast-2.0`) and read by `AppConfig`. It can be overridden
at run time, without a build, under the key `BlauXAIRealtimeModel`:

1. **Managed app configuration** (`com.apple.configuration.managed`), pushed
   by an MDM server: the remote override, e.g. if xAI retires the pinned
   version.
2. **The app's defaults or a launch argument**, e.g.
   `-BlauXAIRealtimeModel grok-voice-latest` in the scheme, for trying a new
   model on a development device.

`AppConfig.current` applies the override at launch (`effectiveRealtimeModel`,
used by `xaiRealtimeURL`). An invalid id (anything but letters, digits, `.`,
`_` and `-`) is ignored with a fault. There is no Blau backend, so there is
no Blau-hosted remote config; see [configuration.md](configuration.md).

### Snapshot tests

`SessionUpdateSnapshotTests` compares the encoded `session.update` (the exact
bytes `RealtimeEventCoding` produces, pretty-printed for review) and the
instructions with the files in
`Packages/BlauKit/Tests/BlauRealtimeTests/Fixtures/Snapshots/`. After an
intended change to the session or the prompt, re-record and review the diff:

```sh
cd Packages/BlauKit
BLAU_RECORD_SNAPSHOTS=1 swift test --filter SessionUpdateSnapshotTests
git diff Tests/BlauRealtimeTests/Fixtures/Snapshots
```

## Telemetry

| Signpost | Kind | Meaning |
| -------- | ---- | ------- |
| `realtime.connect` | interval | One connection attempt: secret, then upgrade. End message `connected` or `failed` |
| `realtime.event` | interval | One received frame: decode and delivery to `events`. End message is the event type |
| `realtime.drop` | event | A connection was lost |
| `realtime.reconnected` | event | A reconnect succeeded |

Both intervals are canonical (see [performance.md](performance.md)). Logs go
to `Log.realtime`: lifecycle at `notice`, failures at `error`, error-event
messages from the server as `private`. Secrets and conversation text are
never logged.

## Record and replay

`RealtimeTranscriptRecorder` captures every frame of a session (with connects
and closes) as a `RealtimeTranscript`, saved as JSON Lines.
`RealtimeReplayConnector` plays a transcript back through a real
`RealtimeClient`: each `connect` gets the next recorded connection, and in
`lockstep` pacing each server frame waits until the client has sent as many
frames as it had when the frame was recorded. Tests of anything built on the
client can run a whole session, including a drop and a reconnect, without a
network.

The fixtures in `Packages/BlauKit/Tests/BlauRealtimeTests/Fixtures/` (see its
README) are hand-written from xAI's reference examples, and the tests fail if
any of their frames doesn't decode to a typed event. Record a real session
with the gated `LiveRealtimeRecordingTests`:

```sh
cd Packages/BlauKit
BLAU_XAI_LIVE=1 XAI_API_KEY=<key> \
BLAU_XAI_RECORD_PATH="$PWD/Tests/BlauRealtimeTests/Fixtures/live-manual-text-turn.jsonl" \
swift test --filter LiveRealtimeRecordingTests
```

A transcript never contains the client secret (it travels in the upgrade
header, which isn't recorded), but it does contain what was said and the
audio, so treat recordings of real conversations as private.

## Testing

`swift test` in `Packages/BlauKit` covers, without the internet:

- the wire format of every client event and the decoding of every server
  event, unknown and malformed frames, aliases and open enums;
- every fixture session decoding completely, round-tripping, and replaying
  through the client;
- connecting, refused secrets, token failures, timeouts, backoff, giving up,
  reconnecting after drops and server closes, keepalive, signposts and
  recording, all against fakes driven by `ManualClock`;
- the real `URLSessionWebSocketTask` path against a WebSocket server on
  127.0.0.1: subprotocol, frames both ways, pings, HTTP 401/503 on the
  upgrade, and a connection reset mid-session that the client recovers from.

### Manual verification

| Check | How | Result |
| ----- | --- | ------ |
| Real session decodes | Run `LiveRealtimeRecordingTests` with a real key; it fails on any undecoded event | pending (needs xAI credentials) |
| Drop on a device | Start a session on an iPhone, toggle Airplane Mode for 5 s, then off; Console (`category:realtime`) shows `Realtime connection lost` then `Realtime reconnected` | pending (needs a device and #36) |
| Wi-Fi to cellular | Walk out of Wi-Fi range mid-session; the keepalive should notice within 25 s and reconnect | pending (needs a device and #36) |
| Session accepted | With a real key, `session.updated` echoes `turn_detection.type: null`, the voice, 24 kHz PCM output and the speed; no `error` event | pending (needs xAI credentials and #36) |
| Voice change mid-session | Change the voice and speed in Settings during a conversation; the next reply uses them | pending (needs xAI credentials and #36) |
