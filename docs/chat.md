# Chat transcript

The main screen shows the conversation as a plain transcript (#42): what the
user said right-aligned, what Grok said left-aligned, and **no bubbles**.
Rows differ by alignment, weight and color only.

| Row | Side | Style |
| --- | --- | --- |
| User, final | right, `.trailing` text | body, medium weight, accent color |
| User, speaking (partial) | right | body, medium weight, secondary color |
| Grok | left, `.leading` text | body, regular weight, primary color |
| Grok, interrupted | left | as above, ending in a tertiary thin space and em dash (` —`) |
| App note (`system` role) | centered | footnote, secondary color |

Each row is at most 85 % of the transcript's width
(`containerRelativeFrame(.horizontal)`), so a line never runs edge to edge
and the side reads at a glance. Text selection is on, and long-pressing a
finished row opens a menu headed by when it was said, with **Copy** and
**Share**.

The transcript is laid out on the topic timeline ([timeline.md](timeline.md),
#56): the current topic's rows below its bullet, and an older topic's rows
when the user expands it.

## Where the rows come from

```
SwiftData store ──@Query──▶ TopicFinishedRows ─┐
                                               ├─▶ the timeline's LazyVStack, under the topic's bullet
TurnOrchestrator ─snapshots─┐                  │
TranscriptFeed ──events─────┴▶ ChatTranscriptModel ─▶ TopicLiveRows (current topic only)
StreamingAudioPlayer ─playedItem(for:)─▶ streaming row (TimelineView, 20 Hz)
```

- **Finished rows** are the conversation's stored utterances
  (`ChatTranscript.utterances(in:)`, sorted by `startedAt`), kept to the
  topic's own lines (`TopicMembership`). The main screen opens on the
  running conversation, or else the latest one
  (`ChatTranscript.latestConversation`).
- **Just-written rows.** `ConversationStore` saves in batches, up to 2 s
  after a commit, so a `@Query` alone would show a gap between the partial
  clearing and the saved row arriving. The live app wraps its transcript in
  a `FeedingTranscriptRecorder`, which reports every write to a
  `TranscriptFeed` before it reaches the store. `ChatTranscriptModel` keeps
  those lines (`recorded`) and the view lays them over the stored ones by
  id.
- **Speech in progress.** The latest ASR partial (`TurnSnapshot.userPartial`)
  shows right-aligned in the secondary color. When it clears, its words stay
  until the final utterance is recorded, so the row resolves to the final
  text in place instead of blinking; if no final arrives within 1.5 s (speech
  that wasn't committed), it goes away.
- **Grok's reply** streams token by token in step with the audio.
  `TurnSnapshot.agentSpeech` lists the reply's items with the id each is
  stored under and its playback id; the streaming row shows the share of the
  transcript equal to the share of the item's received audio that has played
  (`ChatTranscript.revealedText(of:played:)`), cut back to whole words. The
  transcript arrives ahead of the audio, so this keeps the words with the
  voice. A stored reply that is still playing is hidden from the finished
  rows (`liveAgentIDs`) until it has played out, then turns into its final
  row under the same id.
- **Second pass.** When the second ASR pass (#30) rewrites a final row, the
  text morphs (`.contentTransition(.interpolate)`), with no animation under
  Reduce Motion.

- **Live caption.** While the user reads the history, the streaming row is
  out of view, so a caption above the Now pill shows the reply's latest
  words, revealed the same way (`ChatCaption`, `LiveCaption`; see
  [accessibility.md](accessibility.md#captions), #81).

All of the rules (merging, ordering, interruptions, revealing, holding a
partial) are plain functions in BlauKit (`BlauRealtime/Chat`) and tested on
the Mac with `swift test`; the app target only lays rows out.

## Tool chips

When Grok calls a tool (the memory tools, #68), the transcript shows a
subtle centered chip, a caption-sized label in a hairline capsule:
"Searching memory…" while it runs, then "Searched memory", "Saved to
memory", "Checked memory" or "Couldn't search memory". The chips come from
`TurnSnapshot.toolCalls`; `ChatLiveState` keeps them for the conversation on
screen, the current turn's with the reply as it plays (`liveRows`) and
finished ones among the stored rows by start time
(`ChatTranscript.rows(…, toolCalls:)`), so a chip sits after the question
and the "let me check" and before the answer. In DEBUG builds tapping a chip
opens the call's arguments and output, pretty-printed. Chips live in memory
only, so a conversation reopened after a relaunch has none (see
[memory-tools.md](memory-tools.md#in-the-chat)). VoiceOver reads them as
"Blau, Searched memory" (`blau.chat.tool`).

## Interrupted replies

Two sources mark a reply as interrupted; a row is marked when either does.

1. **Live, from the orchestrator.** While a conversation runs, the turn
   orchestrator lists the stored replies it cut short, by barge-in (#37)
   or because the user said something new, in
   `TurnSnapshot.interruptedAgentUtterances`. `ChatLiveState` collects
   them (`interruptedAgentIDs`) and keeps them while that conversation
   stays on screen. This is exact, including for barge-ins, where the cut
   lands about when the user starts talking.
2. **Derived from stored times**, for conversations reopened after a
   relaunch or synced from another device. The store has no "interrupted"
   flag (adding one is a schema change), and the orchestrator's set lives
   only in memory.

For the second: when the user cuts Grok off, the orchestrator stores the
reply ending where it was heard (`conversation.item.truncate`), which is
after the user started the utterance that cut it, because the cut happens
when that utterance is final. `ChatTranscript.isInterrupted(_:before:)`
marks an agent row whose next user utterance started more than 250 ms
before the reply ended (the tolerance absorbs the jitter buffer).

Edge cases of the derived rule, which only apply once the live set is gone:
a barge-in cut stores the reply ending about when the VAD heard the user
start, so it is marked only when the stored user utterance starts more than
250 ms earlier than that. Two more read differently from a strict "cut"
flag: a reply the user
talked over that still finished playing before their utterance was final is
marked (they did talk over it), and a reply cut by a rapid follow-up that
was merged into the previous utterance is not (the merged utterance starts
before the reply).

## Scrolling and performance

- The timeline's `LazyVStack` in a `ScrollView` anchored to the bottom
  (`defaultScrollAnchor(.bottom)` for the initial offset and alignment), not
  an inverted scroll view. Each row is a child of the lazy stack, so only
  rows on screen are built.
- While the user is at the bottom, content size changes keep the latest line
  in view (`defaultScrollAnchor(.bottom, for: .sizeChanges)`); scrolled up
  into history, the anchor switches to the top so the reading position
  holds. `onScrollGeometryChange` tracks which (see
  [timeline.md](timeline.md#scrolling)).
- The finished rows and the live rows are separate views reading separate
  observable properties. A partial or a reply's words only redraw the rows at
  the bottom; the streaming row's 20 Hz `TimelineView` redraws only that row.
- The iOS 27 prepend regression (FB24968838) concerns loading older history
  at the top, which is #57 (timeline pagination); a topic's transcript loads
  its whole conversation at once.

`ChatTranscriptScrollPerformanceTests` (`make perf`) flings through a
1,000-row conversation and records `XCTHitchMetric` and
`XCTOSSignpostMetric.scrollingAndDecelerationMetric`. The acceptance bar is
no hitches at 120 Hz, which needs a ProMotion iPhone. The simulator only
reports the scroll's duration (Xcode 27.2, iOS 26.5 simulator: 2.58 s per
iteration of three flings up and three down, 0.7 % RSD); hitch time ratio and
frame rate come from a device run:

| Device | OS | Hitch time ratio | Frame rate | Date |
| --- | --- | --- | --- | --- |
| iPhone (ProMotion) | | pending | pending | |

## Testing

| Test | Covers |
| --- | --- |
| `ChatTranscriptTests` (BlauKit) | ordering, merging stored and just-written lines, interruptions, revealing a reply, the fetch descriptors |
| `ChatToolCallTests` (BlauKit) | tool chip titles, placement between question and answer, live and finished chips |
| `ChatLiveStateTests`, `TranscriptFeedTests` (BlauKit) | partials resolving to finals, held partials expiring, streaming rows, conversation switches, the feed, the orchestrator's `agentSpeech` |
| `ChatTranscriptViewTests` (BlauTests) | the live model, the fixture, and a rendered row: on its speaker's side, within 85 %, no filled background |
| `ChatTranscriptUITests` | user rows right and agent rows left on screen, opening at the latest line, the long-press menu, the largest text size (the fixture conversation has no topics, so it shows under one stand-in bullet) |
| `ChatTranscriptScrollPerformanceTests` | scrolling 1,000 rows |

UI and performance tests seed a canned conversation with the launch
arguments `-BlauChatFixture <count>` on a `ui-test` launch
(`ChatTranscriptFixture`); the live app never seeds anything. Previews use
the same fixture.
