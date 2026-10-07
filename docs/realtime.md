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
owner sends its `session.update` again. Nothing is queued while
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
