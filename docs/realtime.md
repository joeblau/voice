# Realtime client

`RealtimeClient` (in `Packages/BlauKit/Sources/BlauRealtime/Client/`) is
Blau's connection to the xAI Grok realtime voice API,
`wss://api.x.ai/v1/realtime?model=…` (issue #34). It owns one WebSocket at a
time, speaks typed events, keeps the connection alive and reopens it when it
drops. Session settings (#35), [turn orchestration](#turn-orchestration)
(#36), barge-in (#37), tools (#38) and resumption (#39) are built on top of
it.

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
still makes sense (a user utterance, yes; stale input audio, no). For
[long sessions](#long-sessions) (#39) the owner calls `setEndpoint(_:)` with
`?conversation_id=` so the next connection replays the conversation,
`reconnect(to:)` to renew a session on purpose (`connected →
reconnecting(attempt: 1) → connected`, the old socket closed with 1000), and
`prepareClientSecret()` to mint the next secret before closing the old
connection. `connectionURL` is the URL the open connection was opened with.

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
| `tools` | Only when there are tools: the registry's function tools, then the built-in search tools turned on | `RealtimeToolRegistry` and Settings → Search, see [Function calling](#function-calling) |
| `resumption` | `{"enabled": true}` | Fixed. The server keeps the conversation so a dropped connection can resume it with `?conversation_id=`; xAI requires the opt-in on the first *and* the resuming session ([Long sessions](#long-sessions)) |

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

## Function calling

Grok can call tools during a session (issue #38). The code is in
`Packages/BlauKit/Sources/BlauRealtime/Tools/`.

| Type | Role |
| ---- | ---- |
| `RealtimeFunctionTool` | A client-side tool: static `name`, `description`, `parameters: JSONSchema` and `timeout` (3 s by default), and `call(_ arguments: Data) async throws -> String`. `RealtimeTypedFunctionTool` decodes the arguments into a `Decodable` type first |
| `JSONSchema` | The arguments schema, built with `.object(properties:required:)`, `.string`, `.integer`, `.number`, `.boolean`, `.array(of:)`, or wrapped from JSON |
| `RealtimeToolRegistry` | The tools by name. `definitions` go into `session.tools`; names are checked (1–64 of `A-Z a-z 0-9 _ -`, unique) when a tool is registered |
| `RealtimeToolRunner` | Answers the calls: runs each tool, sends its output and the one follow-up `response.create` |
| `RealtimeBuiltInTool` | xAI's server-side `web_search` and `x_search`, turned on in Settings → Search |
| `EchoTool` | `echo {"text"}` → `{"text"}`, for testing the round trip |

The protocol is called `RealtimeFunctionTool`, not `RealtimeTool` as the
issue sketched, because `RealtimeTool` is already the wire type of a
`session.tools` entry (#34).

```swift
// Composition root: one registry for both halves.
var registry = RealtimeToolRegistry()
try registry.register(SearchMemoryTool(index: index))       // #68, behind the memoryTools flag
let configurator = RealtimeSessionConfigurator(settings: store, memory: memory, tools: registry.definitions)
let runner = RealtimeToolRunner(registry: registry, sender: client)

// The turn orchestrator (#36), which reads client.events:
for await event in client.events {
    await runner.handle(event)         // every event, in order; returns at once
    ...
}
// On barge-in (#37) and after every reconnect:
await runner.cancelAll()
```

### One round

```
response.function_call_arguments.done (call_a) ─▶ run tool a ┐   (each call runs as soon as its arguments are complete,
response.function_call_arguments.done (call_b) ─▶ run tool b ┤    in parallel, with its own timeout)
response.done (completed)                                     │
                                  tool b done ─▶ conversation.item.create {function_call_output, call_b}
                                  tool a done ─▶ conversation.item.create {function_call_output, call_a}
                       every output sent and response.done ─▶ response.create   (exactly one)
```

- **Exactly one `response.create`** per response that made calls, sent only
  when that response is done, every output has been written, *and* no other
  response is in progress. xAI's guide: "Do not send `response.create` until
  all function call outputs have been submitted"; and a `response.create`
  while any response is active is rejected
  (`conversation_already_has_active_response`), so the runner waits for
  `response.done` too.
- **Someone else's response.** If the user speaks while a tool runs, the
  orchestrator starts their response (barge-in only fires while Grok is
  speaking, so nothing is cancelled). The tool's output still goes out at
  once, but the follow-up waits for that response's `response.done`; rounds
  that become ready together share one `response.create`. While the runner's
  own `response.create` hasn't started yet, no second one is sent. If the
  server rejects the follow-up anyway (an `error` with code
  `conversation_already_has_active_response`), the runner forgets it, so the
  next response isn't counted as its follow-up. This relies on the
  orchestrator passing `response.created` and `response.done`; without
  `response.created` the runner can't see other responses.
- **Every call gets an output**, so the model can always say something:
  the tool's result, or `{"error": "<code>", "message": "…"}` with code
  `timeout` (past the tool's `timeout`; the tool's task is cancelled and a
  late result is dropped), `failed` (the tool threw; a
  `RealtimeToolError.failed(message)` passes its message to the model, any
  other error gets a generic one), `invalid_arguments` (bad JSON or wrong
  shape) or `unknown_tool`.
- **Found once.** A call is run when its `arguments.done` arrives; one only
  reported in `response.output_item.done` or `response.done`'s output is
  run from there. A call id is never run twice. A name missing from
  `arguments.done` is taken from `response.output_item.added`.
- **Cancelled responses.** If the response ends `cancelled` (barge-in) or
  `failed`, its calls are dropped: running tools are cancelled and no
  follow-up is sent. `cancelAll()` does the same for everything in flight,
  and calls that still arrive for a dropped response are ignored.
- **Loops.** A follow-up can call tools again. After four rounds in a row
  without an ordinary reply, calls get a `limit_reached` error (the
  follow-up still goes out so Grok can answer); a further round gets no
  follow-up at all. Only responses the runner requested count: a response
  someone else starts (the user's next turn) begins a new chain, so the
  user's next question gets its tools again after a loop was stopped.
- **Disconnected.** If an output can't be sent (`notConnected`), the round
  is dropped. A new connection is a new server session without those calls.

`runner.activity` reports `started`, `finished(outcome:)`,
`followUpRequested` and `abandoned`, for a "Searching…" hint in the UI.

### Built-in search tools and spoken filler

- **Settings → Search** turns on xAI's `web_search` and `x_search`
  (`RealtimeVoiceSettings.builtInTools`, off by default, saved with the
  voice settings). They are sent as `{"type": "web_search"}` and
  `{"type": "x_search"}` after the function tools, per the Tools section of
  xAI's speech-to-speech guide (checked 2026-10-07). xAI runs them; the
  runner never sees them. A change goes out with the next debounced
  `session.update`, like a voice change.
- **Filler.** While a tool runs Grok would otherwise be silent. The
  instructions' Tools section asks it to say a few natural words ("let me
  check") before calling a tool, in the same reply, and to say briefly when
  a tool fails. The `echo-tool` fixture shows the shape: an audio message,
  then the function call, in one response.

## Telemetry

| Signpost | Kind | Meaning |
| -------- | ---- | ------- |
| `realtime.connect` | interval | One connection attempt: secret, then upgrade. End message `connected` or `failed` |
| `realtime.event` | interval | One received frame: decode and delivery to `events`. End message is the event type |
| `realtime.drop` | event | A connection was lost |
| `realtime.reconnected` | event | A reconnect succeeded |
| `realtime.toolCall` | interval | One function call, from its arguments being complete to its output being decided. End message: tool name and outcome (`echo succeeded`, `search_memory timed_out`, `unknown unknown_tool`) |
| `realtime.rollover` | event | The session is being renewed (age, deadline or `max_duration`) |
| `realtime.resumed` | event | A connection resumed the server conversation |
| `realtime.resumeRefused` | event | A connection meant to resume started a new conversation (or the upgrade was refused) |
| `realtime.reseed` | event | A new server conversation is being given the history again |

`realtime.connect` and `realtime.event` are canonical (see
[performance.md](performance.md)); `realtime.toolCall` is not a pipeline
stage of its own (it happens inside `realtime.turn`), so it is a plain named
interval. Logs go
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

## Turn orchestration

`TurnOrchestrator` (in `Packages/BlauKit/Sources/BlauRealtime/Turns/`, #36)
owns the client for a conversation. It commits each verified user utterance
to Grok, plays the reply, shows both sides live and writes both to the
transcript.

```swift
let orchestrator = TurnOrchestrator(
    client: RealtimeClient(endpoint: config.xaiRealtimeURL, tokenProvider: xai.tokenProvider),
    configurator: realtimeSession.configurator,
    audio: StreamingAudioPlayer(),                  // AgentAudioOutput (#25)
    transcript: conversationStore)                  // TurnTranscriptRecording, e.g. ConversationStore (#21)
try await orchestrator.start(waitsForConnection: false)
Task { await orchestrator.run(transcript: transcriber.events) }   // partials and finals (#29)
for await snapshot in orchestrator.updates() { ... }             // state, live text, latency, usage
await orchestrator.stop()
```

In the app, `AppEnvironment.live()` builds the orchestrator into the
`realtime` slot (`VoiceLoop.makeOrchestrator`) and `VoiceLoop` composes the
rest of the pipeline on `start()`: the audio session with capture and the
player on one voice-processing engine, Silero VAD and the Parakeet
transcriber (see `Blau/VoiceLoop/`). Until the record button (#41) exists,
**Debug menu → Voice Loop** starts and stops it.

### States

```
paused ──start()──▶ listening ──partial──▶ userSpeaking ──final──▶ committing
committing ──item + response.create sent──▶ agentThinking ──first audio delta──▶ agentSpeaking
agentSpeaking ──response.done and the player has drained──▶ listening
any ──failed response, rejected response.create, no response.created within 15 s, connection given up──▶ error ──partial / final──▶ …
any ──stop()──▶ paused
```

`agentSpeaking` lasts until the reply has finished *playing*
(`AgentAudioOutput.waitUntilIdle()`), not just arriving: Grok generates audio
faster than real time, so `response.done` comes seconds before the last word
is heard.

### One turn

| Step | What happens |
| ---- | ------------ |
| Final utterance | `TranscriptEvent.final`, or `send(_:)` from the voice gate (#47). Blank text and utterances the gate didn't `accept` are ignored. It is written to the transcript at once, then sent |
| Commit | `conversation.item.create` with one `input_text` part, then `response.create` with `metadata: {"blau_turn": "<n>"}` and a client `event_id`, so `response.created` matches its turn even after a cancel and a rejection names its request (without the echo, responses are matched in order, one request outstanding at a time; see below) |
| Reply | `response.output_audio.delta` → the player, keyed by `item_id` and `content_index`. `response.output_audio_transcript.delta` (and `response.output_text.delta`) → `TurnSnapshot.agentText`. `response.output_audio.done` finishes the item in the player |
| Done | `response.done` writes the agent utterance (text from the transcript deltas, or from the response's output items if they didn't arrive), adds the response's token usage, ends the signposts |
| Stale events | Deltas of a cancelled or merged response are dropped by response id; an assistant item it still adds is removed from Grok's history (`conversation.item.delete`), since none of it plays |
| Refined text | `TranscriptEvent.refined` (the second pass, #30) rewrites the stored user row it belongs to (the merged row, for a part of a merged utterance); Grok keeps the streaming text it was sent |

#### Matching responses to turns

Whether xAI echoes `response.create`'s `metadata` in `response.created` is
not verified yet (the hand-written `manual-text-turn` fixture echoes a
`turn` key, so its replay runs on the fallback below). With the echo, a
response is matched to the turn its `blau_turn` names. Without it, the
match rests on order: the server answers each `response.create`, in the
order it got them, with either a `response.created` or an `error`
rejecting it. So the orchestrator keeps **at most one `response.create`
outstanding**, and an untagged `response.created` always answers that one:

- Every `response.create` carries a client `event_id`
  (`blau_rc_<turn>_<attempt>`) and gets a slot until its answer arrives. A
  send that fails, or a new connection, removes a slot whose answer will
  never come.
- A turn's user items go out at once, but its `response.create` is **held**
  while a slot is outstanding, or while a response is still active (created
  and not yet `response.done`: the cancelled reply of a merged or
  interrupted turn; the server runs one response at a time). It goes out as
  soon as neither is true. On the merge and interrupt paths that costs the
  round trip of the cancel (`response.cancel` → `response.done`).
- A turn given up before its response was created (merged, interrupted,
  stopped or timed out) **keeps its slot, marked abandoned**, so the next
  turn's request keeps waiting for it. When its `response.created` arrives,
  the response is ignored and cancelled by id (`response.cancel` with
  `response_id`). A turn given up while its request is still held never
  sends it.
- An `error` that names a slot's `event_id` (`error.event_id`) is that
  request's answer: the slot is removed. When the server doesn't name the
  event, a `conversation_already_has_active_response` error is matched to
  the outstanding slot. If the rejection was because another response was
  still active, the turn asks again once a `response.done` arrives, up to 3
  attempts. Any other rejection fails the turn at once with the server's
  message, instead of after the 15 s response timeout.
- A held request waits at most `responseCreateHoldLimit` (2 s). After that
  the orchestrator stops waiting for the outstanding answer or the active
  response, and sends it. This covers a request the server never answers
  (for example a timed-out turn whose response never comes). If the stale
  response does arrive later, without the echo it is taken for the new
  turn's reply. The new turn's own response then finds no slot and is
  ignored. Because only one slot is ever outstanding, matching is back in
  step after that one response, however the user carries on (interrupting,
  merging or waiting). With the echo, the late response is recognized by
  its tag and cancelled.

Agent utterances are stored with the wall-clock time of their first audio
and, on the conversation's timeline, an offset from the start of the
conversation and the length of the audio received (or heard, if cut).

### Rapid follow-ups and interruptions

The issue asked to merge utterances less than 400 ms apart. Holding every
final back for 400 ms in case a continuation follows would add 400 ms to
every turn (the latency budget, #74, is 1.5 s), so nothing is held:

- A final that starts less than `mergeWindow` (400 ms) after the previous
  utterance ended **on the audio timeline** continues it. The reply in
  progress is cancelled (`response.cancel`), the new text goes in as a
  second user item and a new response is requested (once the cancelled
  one is done; see "Matching responses to turns"). Grok sees the two
  items back to back; the transcript stores **one** user utterance (the
  first one's id, the text joined, the ranges united). While the
  connection is down, a continuation merges into the queued utterance.
- A final that doesn't continue the previous one, while Grok is answering
  or still playing, **interrupts** the reply the same way and starts a new
  turn.

Either way the cut reply is handled by what the user heard
(`StreamingAudioPlayer.flush()` reports it): an item none of which was heard
is removed from Grok's history (`conversation.item.delete`) and not stored;
one cut part-way is truncated there (`conversation.item.truncate` with the
played milliseconds) and stored with the share of its text that was heard,
replaced by the transcript `conversation.item.truncated` brings. Triggering
the same cut on *speech start* (VAD), with the echo guard, is barge-in (#37).

### Connection

- After every `.connected` the orchestrator sends `configure(_:)`'s
  `session.update` before anything else, through the same serial send queue
  as the turns. `followSettingsChanges(sending:)` runs for the
  conversation's lifetime.
- Utterances finalized while no session is ready are stored and **queued**.
  On the next configured session they go out in order, as user items
  followed by one `response.create`. A turn whose reply hadn't started when
  the connection dropped is queued again; a reply cut off mid-way keeps what
  arrived (played out and stored). Every send carries the session it was
  decided for, so nothing meant for a dead session reaches the next one.
- A new connection resumes the server conversation or is reseeded before
  anything queued goes out, so Grok remembers the conversation across
  drops and renewals; see [Long sessions](#long-sessions).
- `start(waitsForConnection: false)` returns at once and connects in the
  background (the voice loop uses it so the user can start talking while the
  secret is minted). A connection that gives up moves the state to
  `error(.connection)`; `connect()` tries again.

### Latency and the HUD

`TurnSnapshot.latency` keeps the last 200 turns of **end of utterance →
first audio** (the same span as `realtime.firstAudio`) and **end of utterance
→ `response.done`** (`realtime.turn`) as `RollingLatency`: last, p50, p95.
Turns sent from the queue (they measure the outage) and turns that were
merged, interrupted or timed out (they never ended) are not sampled. "End of utterance"
is when the final reaches the orchestrator; ASR's own end-of-speech delay
is `asr.eou`.

With the **Performance HUD** flag on, `VoiceLoopHUD` shows
`TurnHUDReadout`'s rows over the main screen:

```
Turn         agentSpeaking
Realtime     connected
EOU → audio  last 640 · p50 610 · p95 900 ms (n=12)
Turn time    last 3120 · p50 2890 · p95 4410 ms (n=12)
Tokens       4120 in · 960 out · 12 resp
```

The full HUD (#71) adds the other subsystems.

### Usage

`response.done`'s usage, cancelled responses included (they are billed), is
summed per conversation in `TurnSnapshot.usage` and logged per response
(`Log.realtime`, counts only). The SwiftData schema has no usage field, so
it is not written to the store; adding it is a schema change (v3) for the
cost view.

### Tests

`swift test --filter "TurnOrchestrator|TurnHelper"` runs the orchestrator
against a real `RealtimeClient` over fake sockets on a `ManualClock`: a full
turn and its state sequence, signposts and latency samples; text-only
replies; transcripts from `response.done`; filtering; merging (in flight,
unheard, queued); interruptions mid-reply and after `response.done`, with
the truncate and the server's corrected transcript; queuing while
disconnected and sending after `session.update`; requeuing a turn lost
before its reply; a reply cut off by a drop; connect failures, failed
responses and the response timeout; stop and restart; settings changes;
flushing on backgrounding. `TurnOrchestratorResponseMatchingTests` covers
untagged matching: late responses of merged, interrupted and timed-out
turns; the hold limit; a timeout followed by an interruption; a
`response.create` rejected while a response is active (with and without
`error.event_id`) and asked again; other rejections failing the turn; and
a late response recognized by its tag. `TurnOrchestratorIntegrationTests` adds the
real `ConversationStore` over SwiftData (both roles stored, merges and cuts
stored once), the `manual-text-turn` fixture replayed in lockstep, and the
real `StreamingAudioPlayer` rendering the reply.

## Long sessions

Conversations can last hours, but xAI ends a session after 120 minutes
(`error` with type `max_duration`) and connections drop. The turn
orchestrator keeps one conversation going across both (issue #39). The code
is in `Packages/BlauKit/Sources/BlauRealtime/Continuity/` and
`Turns/TurnOrchestrator+Continuity.swift`; the knobs are
`TurnOrchestrator.Configuration.continuity` (`SessionContinuityConfiguration`).

| Event | What happens |
| ----- | ------------ |
| `conversation.created` | Its id becomes the server conversation, and the client's endpoint gets `?conversation_id=<id>`, so every automatic reconnect asks to resume it |
| Drop | The client reconnects at once with `?conversation_id=`. The session is **not ready** until the server shows whether it resumed; utterances are transcribed, stored and queued meanwhile ("Reconnecting…") |
| Resumed | The server replays the history (`conversation.item.created`) and then answers the `session.update` (`session.updated`); a `conversation.created` with the same id counts too. The queued utterances go out as one turn. A turn whose items already went out before the drop isn't sent twice: items the replay already holds are skipped, and a reply in the replay that never reached the user is deleted (`conversation.item.delete`) so the turn asks again |
| Not resumed | A `conversation.created` with another id, no sign of the old conversation by `session.updated` (or within 5 s), an upgrade refused with a 4xx, or two connections in a row that drop before resuming: the connection is a **new conversation** and is reseeded (below) |
| 110 minutes | The session is renewed at the first moment no turn is in progress and nothing is queued. A client secret is minted at 108 minutes and checked again just before closing, while the old connection still works (`prepareClientSecret()`), so the gap is one WebSocket upgrade; utterances in the gap queue. If no secret can be minted (offline), the old session is kept and the renewal tried again every minute |
| 118 minutes | Renewed even mid-turn, before the server's own limit: what arrived of the reply is kept, as after a drop |
| `max_duration` | Renewed at once, as a new conversation; that conversation id is never resumed again |
| Idle 25 minutes | xAI drops resumable history after 30 idle minutes, so a conversation idle for 25 is not asked for; the next connection is new and reseeded |

**Reseeding** a new server conversation: the `session.update` sent first on
every connection already carries the system instructions and the
ProfileBlock (and facts). Then `conversation.item.create` sends a system
note ("this conversation continues; don't greet again"), with the current
topic's title and summary from `RealtimeReseedContextProviding` (the app
passes its SwiftData transcript, `ConversationStore.topicDigest(for:)`), and
the last 8 exchanges (at most 6,000 characters, newest kept first) as user
and assistant messages, then the queued utterances as the next turn. The
exchanges come from what the orchestrator stored (merged, refined and cut
replies included), so Grok sees what the user actually heard. Utterances
still queued are left out of the reseed: they go out as the new turn.

**Renewal starts a new conversation by default.** The issue sketched
renewing with `?conversation_id=`. xAI documents 120 minutes as the maximum
*conversation* duration and doesn't say that resuming resets it, so a
resumed conversation might be ended at 120 minutes anyway, mid-sentence.
Renewing as a new conversation plus a reseed never depends on that. Set
`continuity.resumesAtRollover = true` to renew by resuming instead (the
renewal then expects the replay, and falls back to a reseed if it doesn't
come) once a device test shows the limit is per connection.

The snapshot's `session` (`RealtimeSessionContinuity`) reports the phase
(`connecting`, `live`, `resuming`, `rollingOver`, `reconnecting`),
`isReconnecting` for the UI, the session's age in whole minutes and the
renewal, resumption and reseed counts. The HUD's **Session** row shows
them: `live · 42 min · 1 renewed · 2 resumed · 1 reseeded`. The Voice Loop
debug screen shows "Reconnecting…" while `isReconnecting`.

### Tests

`swift test --filter "TurnOrchestratorContinuityTests|ConversationHistoryTests|RealtimeReseedTests|RealtimeClientRenewalTests|TopicDigestTests"`:

- **A 2.5-hour session on a fake clock** (`aTwoAndAHalfHourSessionRollsOverSeamlessly`):
  30 turns, one every five minutes. The secret is minted at 108 minutes,
  the session renewed at 110 between turns (old socket closed with 1000,
  new conversation), reseeded with the note and the last 8 exchanges, and
  the conversation goes on: every question answered, all 60 utterances
  stored, never an error state. A variant renews by resuming, twice.
- **A drop mid-response** (`aDropMidResponseResumesAndDeliversTheQueuedTurns`):
  the reply is cut and kept, the state shows reconnecting, two utterances
  are queued, the reconnect resumes `?conversation_id=`, nothing goes out
  until the replay and `session.updated`, then both queued utterances go
  out with one `response.create` and are answered.
- Renewal waiting for the turn in progress, the deadline cutting it, no
  secret postponing it, `max_duration`; a requeued turn not sent twice to a
  resumed conversation; a refused resumption reseeding (with the topic)
  before the queued turn; an unconfirmed resumption timing out; an upgrade
  refused with 404; an idle conversation; a new conversation never resuming
  the last one; the reseed through the real `ConversationStore`.

### Manual verification

| Check | How | Result |
| ----- | --- | ------ |
| Resumption shape | With a real key, record a session (`RealtimeTranscriptRecorder`), toggle Airplane Mode for 5 s. Note whether `conversation.created` arrives before or after the `session.update`, whether the resumed connection sends `conversation.created` with the same id, the replay (`conversation.item.created`) and `session.updated` after it. Console (`category:realtime`) shows `Resumed conversation … (n item(s) replayed)` | pending (needs a device and xAI credentials) |
| Expired conversation | Resume a `conversation_id` idle for over 30 minutes (or a made-up one): note whether the upgrade is refused (HTTP status) or a new `conversation.created` arrives; either way Console shows a reseed | pending (needs xAI credentials) |
| 120-minute limit | Run a session past 120 minutes with `continuity.rolloverAfter = nil`: note the `max_duration` error and whether resuming its `conversation_id` is ended at once. If resuming resets the clock, `resumesAtRollover` can be turned on | pending (needs xAI credentials and two hours) |
| Renewal on a device | Hold a conversation past 110 minutes (or set `rolloverAfter` to 5 minutes in a debug build): the next reply after the renewal shows Grok still knows the conversation; the HUD's Session row shows `1 renewed · 1 reseeded` | pending (needs a device and xAI credentials) |
| Soak | The 1–2 h soak test (#76) covers renewal with real audio | pending (#76) |

## Testing

`swift test` in `Packages/BlauKit` covers, without the internet:

- the wire format of every client event and the decoding of every server
  event, unknown and malformed frames, aliases and open enums;
- every fixture session decoding completely, round-tripping, and replaying
  through the client;
- connecting, refused secrets, token failures, timeouts, backoff, giving up,
  reconnecting after drops and server closes, keepalive, signposts and
  recording, all against fakes driven by `ManualClock`;
- function calling: the echo tool round trip through a real client over the
  `echo-tool` fixture (every frame Blau sends matches), the two parallel
  calls of `function-call` producing one `response.create`, and the runner
  against fakes and `ManualClock` (finish orders, timeouts, errors,
  duplicates, cancelled responses, `cancelAll()`, send failures, the round
  limit);
- the real `URLSessionWebSocketTask` path against a WebSocket server on
  127.0.0.1: subprotocol, frames both ways, pings, HTTP 401/503 on the
  upgrade, and a connection reset mid-session that the client recovers from.

### Manual verification

| Check | How | Result |
| ----- | --- | ------ |
| Real session decodes | Run `LiveRealtimeRecordingTests` with a real key; it fails on any undecoded event | pending (needs xAI credentials) |
| Drop on a device | Start a session on an iPhone, toggle Airplane Mode for 5 s, then off; Console (`category:realtime`) shows `Realtime connection lost` then `Realtime reconnected` | pending (needs a device) |
| Wi-Fi to cellular | Walk out of Wi-Fi range mid-session; the keepalive should notice within 25 s and reconnect | pending (needs a device) |
| Session accepted | With a real key, `session.updated` echoes `turn_detection.type: null`, the voice, 24 kHz PCM output and the speed; no `error` event | pending (needs xAI credentials) |
| Voice change mid-session | Change the voice and speed in Settings during a conversation; the next reply uses them | pending (needs a device and xAI credentials) |
| Echo tool, live | Register `EchoTool`, ask Grok to "test the echo tool with the words blue harbor" with a real key, record it with `RealtimeTranscriptRecorder`; the session should match `echo-tool.jsonl` in shape (filler, `function_call`, one output, one `response.create`, an answer using the result) | pending (needs xAI credentials) |
| Parallel calls, live | Ask a question that needs two lookups at once; Console (`category:realtime`) shows two `Running tool` lines and one `requested the follow-up`; no `conversation_already_has_active_response` error | pending (needs xAI credentials and #68 tools) |
| Web and X search | Turn on Settings → Search → Web Search, ask about today's news; `session.updated` echoes `{"type": "web_search"}` and the answer is current | pending (needs xAI credentials) |
| Spoken filler | With a slow tool, Grok says something like "let me check" before the pause | pending (needs xAI credentials and a device) |
| Spoken conversation end to end | Install the speech models, add an xAI key, open **Debug menu → Voice Loop**, Start, and hold a ten-turn conversation on the speaker and on AirPods; every reply plays and the Voice Loop screen shows both sides | pending (needs a device and xAI credentials) |
| Transcript stored for both roles | After the conversation above, the store holds one user and one agent utterance per turn, in order | pending (needs a device and xAI credentials) |
| Response matching echoes | Record the conversation above with `RealtimeTranscriptRecorder`, interrupting Grok mid-reply a few times. Note whether `response.created` echoes `metadata.blau_turn`, and whether an `error` names the `response.create`'s `event_id` in `error.event_id`. Without either, matching runs on the order fallback | pending (needs xAI credentials) |
| EOU → first audio p50 | Turn on **Performance HUD** in the debug menu; after 20 turns, record the HUD's p50 / p95 here and compare them with Instruments' `realtime.firstAudio` | pending (needs a device and xAI credentials) |
| Echo | On the loudspeaker, Grok's own voice never produces a user utterance (VPIO echo cancellation; voice ID is #47) | pending (needs a device) |
