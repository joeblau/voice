# Realtime session fixtures

Each `.jsonl` file is a `RealtimeTranscript`: one realtime WebSocket session,
frame by frame, in the JSON Lines format documented on `RealtimeTranscript`
(`Sources/BlauRealtime/Transcript/RealtimeTranscript.swift`).

`RealtimeFixtureTests` decodes every server and client frame of every file
here and fails on any frame that doesn't decode to a typed event, so a new
file is checked as soon as it is added. `RealtimeReplayConnector` replays them
in tests of anything built on `RealtimeClient`.

| File | What it covers |
| ---- | -------------- |
| `manual-text-turn.jsonl` | Blau's main loop: manual turns, a user text item, an audio reply with transcript, usage |
| `function-call.jsonl` | Two parallel function calls, their outputs, the follow-up reply, a text-modality response (`response.output_text.delta` and the older `response.text.delta`) |
| `barge-in.jsonl` | `response.cancel`, `conversation.item.truncate`, `conversation.item.truncated`, a cancelled `response.done`, `conversation.item.delete` |
| `server-vad-and-errors.jsonl` | Input audio with server VAD, input transcription, clear, idle timeout, `force_message`, DTMF, `error` events, a server close |
| `binary-audio.jsonl` | Binary audio frames in both directions |
| `mcp-tools.jsonl` | Remote MCP discovery and calls, including failures |
| `drop-and-resume.jsonl` | A drop without a close frame (1006), then a second connection with `?conversation_id=` replaying history as `conversation.item.created` |

`Snapshots/` holds the `session.update` and instruction snapshots checked by
`SessionUpdateSnapshotTests` (see `docs/realtime.md`, "Snapshot tests"). They
are not transcripts; `RealtimeFixtureTests` only reads `.jsonl` files.

## Where they come from

The files above are **hand-written** from the event examples in xAI's
realtime reference (<https://docs.x.ai/voice-realtime.ws.json>) and
speech-to-speech guide, fetched 2026-10-07, with consistent ids across each
session. They are not live recordings; each says so in its `meta` line.

## Recording a real session

`LiveRealtimeRecordingTests` connects to xAI with a real key, runs a short
manual text turn and writes the transcript. It is skipped unless enabled:

```sh
cd Packages/BlauKit
BLAU_XAI_LIVE=1 XAI_API_KEY=<your key> \
BLAU_XAI_RECORD_PATH="$PWD/Tests/BlauRealtimeTests/Fixtures/live-manual-text-turn.jsonl" \
swift test --filter LiveRealtimeRecordingTests
```

The key is only used to mint a short-lived client secret; it is never written
to the transcript. A transcript does contain what was said and the audio, so
only commit sessions whose content is fine to publish.
