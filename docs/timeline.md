# Topic timeline

The main screen is the topic timeline (#56): every topic of every
conversation is a bullet on one vertical rail, the current topic at the
bottom with its live transcript (#42) below its bullet, and the history
above it. The product decisions are in issue #1 ("Timeline").

```
Yesterday                                   ← day heading
  ⦙ Conversation · 6:00 PM                  ← conversation heading
  ● Launch Checklist         6:00 PM · 8 min ›
  ● Draft 6                  6:08 PM · 8 min ›   ← provisional title, italic
Today
  ⦙ Conversation · 3:31 AM
  ● Board Update             3:39 AM · 8 min ›
  ◉ Now · 3:55 AM                           ← current topic (pinned header)
    Draft 12
                 Remind me what we decided…    ← its transcript, chat styling
    You picked the second week of November…
                                   [↓ Now]  ← only when scrolled away
```

## Interaction

| What the user does | What happens |
| --- | --- |
| Opens the app | The screen is anchored to the latest line of the **current topic**: the open topic of the running conversation, or else of the most recent one (else that conversation's last topic). Its bullet is a pinned section header, so it stays on screen however long the transcript gets, and older bullets fill the space above it |
| Swipes down | Scrolls up into the history: compressed bullets on a continuous rail, oldest at the top, grouped by day ("Today", "Yesterday", "Tuesday, October 6") and by conversation. Each day heading appears once, in order: the focus conversation always comes last, so a running conversation that began before midnight, after which another device synced one that began after it, sits under the later day's heading |
| Taps a compressed bullet | Expands it in place, in under 100 ms: its detail (summary, span, actions, [below](#topic-detail)) and transcript open below the bullet, which doesn't move. Tapping again compresses it. Several can be open at once |
| Swipes back, taps **Now** or taps the current bullet | Returns to the latest line with a spring (a short ease under Reduce Motion). The Now pill shows whenever the latest line is out of view. From deep in a long history the lazy stack measures rows on the way down and the spring can stop short, so Now finishes the trip on the `UIScrollView` until the latest line is in view |
| Long-presses a bullet | Continue This Topic and Share as Markdown (#58), Rename and Merge with Previous (#54) |
| Long-presses a line of a topic | Copy, Share and "Split Topic Here" (#54), except on the topic's first line |

Expansion is view state (`TopicExpansion` in BlauKit), never persisted:
on launch only the current topic is expanded. When a new topic opens, the
previous one compresses, unless the user is scrolled up reading; then it
stays open so the text doesn't fold away under them.

## Bullets

| Bullet | Layout |
| --- | --- |
| Current | "Now · 9:41 AM" (`timestamp`, the recording tint while recording) over the title in `topicTitle`; a 12 pt dot that pulses while recording |
| Older | One row of fixed height (44 pt at the default size, scaled with Dynamic Type): title in `topicBullet`, one line, then "9:41 AM · 8 min" and a chevron that turns when expanded; a 10 pt dot |

- The dot's color is the topic's palette slot (`Color.topicDot(colorSeed:)`,
  [branding.md](branding.md#topic-dots)), so a topic has the same color on
  every device. A ring of the background cuts it out of the rail.
- The rail runs down the transcript's 16 pt leading margin (centered at
  10 pt), so transcript rows keep the margins and 85 % width of #42 and the
  rail runs past them through expanded topics. It starts at the first bullet
  and ends at the current one.
- The pulse is a ring that grows to 1.7× and fades every 1.6 s, drawn by a
  `TimelineView` capped at 30 fps. Under Reduce Motion it is a steady halo.
- **Titles.** A provisional title (`Topic.titleIsProvisional`) is italic.
  When the labeler refines it or the user renames it, the text cross-fades
  in place (`.contentTransition(.interpolate)`, no animation under Reduce
  Motion).
- At the accessibility text sizes an older bullet puts its time under the
  title and grows instead of truncating.

## Topic detail

An expanded older topic (#58) shows, under its bullet and above its
transcript:

```
  ● Launch Checklist          6:00 PM · 8 min ⌄
    Went through the launch checklist and agreed on next steps.   ← summary
    6:00 PM – 6:08 PM · 8 min                                     ← span
    [↻ Continue] [⇪ Share] [⋯]                                    ← actions
                    Remind me what we decided…                    ← transcript
    You picked the second week of November…
```

- **Summary**: the labeler's summary (#53), if the topic has one.
- **Span**: when it ran and for how long ("6:00 PM – 6:08 PM · 8 min";
  VoiceOver: "From 6:00 PM to 6:08 PM, 8 minutes").
- **Continue** starts a conversation that picks the topic up: Grok is told
  its title, summary and last exchanges before the user says anything
  ([realtime.md](realtime.md#continuing-an-earlier-topic)). It goes through
  the record button's model (`RecordButtonModel.continueTopic(_:)`), so the
  button, its haptic and its failure alert behave as for a tap; while a
  conversation is running, that conversation takes the topic instead. The
  timeline then returns to the latest line. Not offered on the topic being
  recorded.
- **Share** shares the topic as a Markdown file (`TopicMarkdownDocument`,
  rendered by BlauKit's `TopicMarkdownRenderer` only once a destination is
  picked), in the export's format ([export.md](export.md#format)) with its
  own front matter (`topic:`, `generator: Blau topic 1`) so a shared topic
  saved into iCloud Drive → Blau is never mistaken for an export file.
  Apps that take text get the same Markdown as plain text.
- **More** (⋯): Rename… and Merge with Previous (#54). **Split** is on each
  line: long-press it, "Split Topic Here" (also a VoiceOver action).

One `TopicEditor` per timeline runs every rename, merge and split and
presents the rename prompt and failure alert once. The current topic keeps
its live transcript without the detail; its long-press menu has Continue
(for a conversation that has ended) and Share.

**Tap → expanded under 100 ms.** `TopicExpansionTimer` (BlauKit) measures
every expansion from the tap to the detail's `onAppear`, which SwiftUI
calls in the transaction that lays it out: the `timeline.expand` signpost
([performance.md](performance.md#canonical-intervals)), a log line when it
is over 100 ms, and the latest value for UI tests (`ui-test` launches only,
as the value of `blau.timeline.expandLatency`). Expanding builds only the
detail and the rows on screen (the lazy stack), and the transcript query
fetches that one conversation's utterances.

## Scrolling

- `ScrollView { LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) { … } .scrollTargetLayout() }`,
  one `Section` per topic with the bullet as its header, plus the day and
  conversation headings between them. **Not** an inverted scroll view (it
  breaks VoiceOver and context menus). Every transcript row is its own child
  of the lazy stack, so a 1,000-line topic builds only the rows on screen.
- `defaultScrollAnchor(.bottom)` for the initial offset and alignment.
  For size changes the anchor is `.bottom` while the latest line is in view
  (new lines and a new topic keep it there) and `.top` once the user is
  reading history, so the transcript growing below, a topic opening, or a
  label changing never moves what they're reading. Tapping a bullet at the
  latest line holds `.top` for the length of the expansion (a transient
  hold, separate from the at-bottom flag), so the bullet stays where it is
  while its transcript opens; after that the scroll geometry alone decides.
  A prior Now scroll target is cleared before toggling, and the bullet's
  measured position corrects lazy-layout movement in the same frame. When
  collapsing at the latest line, the current bullet supplies that hold,
  preventing a stale size estimate from leaving space below the transcript.
  Collapsing a topic at the latest line therefore stays there, with no Now
  pill, and keeps following new lines.
- **No scroll jumps from labels.** Compressed rows have a fixed height, so a
  new title never changes the layout of the history; the current bullet's
  title is at the bottom, where the anchor is.
- `onScrollGeometryChange` tracks whether the latest line is in view:
  `visibleRect.maxY − contentInsets.bottom` against the content height.
  (`containerSize` leaves out the bar insets on iOS 26, so the visible rect
  is the reliable measure.)
- `scrollPosition($position)` drives Now (`scrollTo(edge: .bottom)`) and is
  keyed by `TopicTimeline.ItemID`.

## Paging history (#57)

The timeline never loads the whole history up front. Thousands of topics
load a page at a time as the user scrolls up, without the rows on screen
moving.

**The window.** `TopicHistoryPaging` holds a **cutoff** date: the
timeline's `@Query` fetches every topic that started at or after it
(`windowDescriptor`), and a second one-row query tells whether anything is
older (`olderDescriptor`, live, so a sync that brings older topics shows the
spinner again).

- On launch the cutoff isn't known: the window is the 200 most recent
  topics (`TopicTimeline.recentTopics()`). As soon as that fills, the cutoff
  settles on the start of the day of its oldest topic, which completes that
  day. This happens at launch, at the latest line, so nothing on screen
  moves.
- Near the top (within three screen heights of the loaded content's top,
  `TopicHistoryPaging.isNearTop`), the next page moves the cutoff back to
  the start of the day of the 200th older topic (`pageBoundary`, a one-row
  fetch with an offset), or to the beginning of time when fewer are left.
  A page that lands while the top is still near asks for the next.
- **Whole sections.** Cutoffs are always the start of a day, so a page adds
  whole days (heading, conversations, bullets) above everything on screen
  and never inserts rows inside a section that is already laid out. A
  conversation that started before the cutoff and runs past it (two devices
  recording at once, or a conversation over midnight) is left out until the
  next page brings it whole (`TopicTimeline.wholeConversations`), unless it
  is the focus conversation or the only one, which show their loaded topics
  (`partialConversationIDs`): their lines of unloaded topics stay out of the
  loaded ones (`TopicMembership(isPartial:)`).
- **A date, not a count.** A topic opening at the bottom never pushes the
  oldest loaded one out of the window while the user reads it.
- While older history is still to load, the rail runs up off the first
  bullet into an "Earlier topics" row with a spinner at the top
  (`TopicTimeline.ItemID.earlier`). The next page usually lands before it
  scrolls into view.

**Keeping the rows in place.** A scroll view that grows above the visible
area has to move its content offset down by the growth, or the rows on
screen jump down by the page's height. Lazy stacks don't preserve the
position when content is prepended (FB24968838,
[forum thread](https://developer.apple.com/forums/thread/848608)), and once
they lay out the rows they had estimated, they shift the content again.
Measured on the simulators with the 2,000-topic history: a 200-topic page
landed about 10,800 pt above the rows on screen without the offset moving
at all, on iOS 27.0 and on iOS 26.5 alike, with the `scrollPosition`
binding keyed by item ID and the size-change anchor at the bottom. So the
timeline doesn't trust the scroll view:

1. **Whole sections at once**, above everything on screen, in one `@Query`
   update (above).
2. **Only at rest.** Pages load when the top is near *and* the scroll view
   is idle (`onScrollPhaseChange`), and only after the user has scrolled
   (the geometry passes through the top while the screen opens). Reading
   history, the scroll view comes to rest often, well before the top: the
   next page lands then. A fling that reaches the top first stops at the
   "Earlier topics" row, and the page lands there.
3. **Hold a row.** Before it asks for the page, the timeline picks a row
   on screen (`onScrollTargetVisibilityChange`; a day or conversation
   heading or a compressed bullet, never a pinned section header) and has
   it report its top in the window (`onGeometryChange`). If no row on
   screen can be held, the page waits (`PrependScrollAnchor.request`
   returns `.wait`): a long expanded topic can fill the screen with only
   its pinned bullet reported, since its transcript's lines aren't
   timeline rows. A page landing then would jump the rows by its height,
   so the timeline asks again at the next rest, or when the rows on screen
   change (a bullet compressed), once a heading or compressed bullet shows.
   The "Earlier topics" row covers the wait. Only the first window's
   cutoff, settled at launch at the latest line under the bottom anchor,
   loads without a held row.
   `PrependScrollAnchor` pins that position, then asks for the page; until
   the layout has been still for 300 ms (2 s at most), whenever the row
   strays, the content offset moves by as much. The scroll view is at
   rest, so the row only moves because of layout, and the correction is
   exact, whether SwiftUI moved the offset itself, partly or not at all.
4. **In the same frame.** The correction sets `contentOffset` on the
   `UIScrollView` behind the `ScrollView` (`EnclosingScrollView`), from the
   row's geometry callback, so it lands before the frame is drawn.
   There is no fallback: if the scroll view isn't found (a future SwiftUI
   that hosts the content differently), the page lands uncorrected and
   logs `Timeline page landed uncorrected` as an error, which the paging
   UI test would catch as a jump. Each correction emits the signpost
   event `timeline.prependCorrected`, and each page logs `Timeline page held
   in place: <n> corrections, <pt> pt`.

If the user touches the screen while a page is held, the hold ends: the
finger moves the rows from then on. While a page lands, size changes anchor
to the bottom, so whatever SwiftUI does on its own already goes the right
way.

The issue proposed `scrollPosition(id:)` anchoring first, then adjusting
the `UIScrollView` offset through SwiftUIIntrospect behind
`#available(iOS 27, *)`. The ID-keyed `scrollPosition` didn't hold the
rows on either OS (above), so the timeline goes straight to the offset,
found without a third-party dependency (a zero-size view inside the
content walks up to its `UIScrollView`), and on every OS version: iOS 26.5
needed the same correction, and the hold only moves the offset when the
row demonstrably strayed, so where SwiftUI gets it right it costs nothing.

**Memory.** Memory grows with the topics loaded, never with their
transcripts: a compressed bullet is a plain `TimelineTopic` value (a
fetched `Topic` with its conversation prefetched), only an expanded topic
queries its lines, and the lazy stack builds only the rows on screen. The
2,000-topic UI test checks the app's footprint grows less than 60 MB from
the first page to the oldest topic.

## VoiceOver

- The timeline is a container labelled "Topics" with a **Topics** rotor
  (`accessibilityRotor`) that jumps between bullets, loaded or not.
- Each bullet is one button with the header trait. Its label is the title;
  its value says when and how long: "Current topic, started 9:41 AM,
  recording", or "Yesterday, 6:08 PM, 8 minutes, collapsed". The hint says
  what a tap does ("Shows the topic's transcript", "Collapses the topic",
  "Shows the latest line").
- Day headings have the header trait; transcript rows read as in #42.
- A new topic and a refined title are announced ("New topic: Pricing",
  "Topic named Pricing Experiments") without moving focus; `TopicAnnouncer`
  decides when ([accessibility.md](accessibility.md#voiceover), #81).
- Scrolled into the history while Grok speaks, a live caption above the Now
  pill keeps its words on screen ([accessibility.md](accessibility.md#captions)).

## Where the code is

| Piece | Where |
| --- | --- |
| Order, groups, current topic, rail, fetch (`TopicTimeline`, `TimelineTopic`) | `Packages/BlauKit/Sources/BlauTopics/Timeline/` |
| Which lines belong to a topic (`TopicMembership`): the store's link, else by time | same |
| Expansion rules (`TopicExpansion`), times and durations (`TopicTimelineFormat`), the expand timer (`TopicExpansionTimer`) | same |
| The window, its cutoff and pages (`TopicHistoryPaging`); the row held in place while a page lands (`PrependScrollAnchor`) | same |
| The scroll view, paging trigger, Now pill, rotor (`TopicTimelineView`) | `Blau/Timeline/TopicTimelineView.swift` |
| The `UIScrollView` behind it, for same-frame corrections (`EnclosingScrollView`) | `Blau/Timeline/EnclosingScrollView.swift` |
| Bullets, rail, dot, headings, VoiceOver text (`TopicBullet`, `TopicBulletDescription`) | `Blau/Timeline/TopicBullet.swift` |
| A topic's transcript rows (`TopicTranscriptRows`) | `Blau/Timeline/TopicTranscriptRows.swift` |
| The detail: summary, span, actions (`TopicDetailHeader`, `TopicDetailDescription`) | `Blau/Timeline/TopicDetail.swift` |
| Rename, merge and split (`TopicEditor`, `TopicEditMenuItems`) | `Blau/Topics/TopicEditMenu.swift` |
| Share as Markdown (`TopicMarkdownDocument`), reading a topic for Continue (`TopicSource`) | `Blau/Topics/TopicShare.swift` |
| The shared file's format (`TopicMarkdownRenderer`) | `Packages/BlauKit/Sources/BlauPersistence/Export/` |
| What Grok is told on Continue (`RealtimeContinuedTopic`, `RealtimeContinuation`) | `Packages/BlauKit/Sources/BlauRealtime/Continuity/` |
| The canned history (`TopicTimelineFixture`) | `Blau/Timeline/TopicTimelineFixture.swift` |

A topic's transcript queries its conversation's utterances and keeps the
rows of that topic: whether a reply was cut off depends on the line after
it, which can be in the next topic. Lines the app just wrote and the store
hasn't saved yet have no topic link; they go by time, like the store
assigns them. A conversation with no topics (recorded before #54, or in
the moment before its first topic opens) gets one stand-in bullet holding
its whole transcript, titled with the conversation's title.

## Testing

| Test | Covers |
| --- | --- |
| `TopicTimelineTests`, `TopicMembershipTests`, `TopicExpansionTests`, `TopicTimelineFormatTests` (BlauKit, `make test-kit`) | order and grouping, the current topic, stand-in bullets, the rail, duplicates, the fetch; line membership; expansion; times, durations and day headings |
| `TopicTimelineViewTests` (BlauTests) | what each bullet tells VoiceOver, the fixture |
| `TopicExpansionTimerTests`, `TopicMarkdownRendererTests`, `ContinuedTopicTests`, `TurnOrchestratorContinueTopicTests`, `RecordButtonContinueTopicTests` (BlauKit) | the expand timer and its signpost; the shared Markdown; what Grok is told, before the first turn, in a running conversation and again after a renewal; Continue through the record button |
| `TopicDetailTests`, `VoiceLoopTests` (BlauTests) | the detail's span text; Continue and Share reading the store; the voice loop opening a conversation with the topic |
| `TopicDetailUITests` | the detail under the bullet (summary, span, Continue, Share, More, then the lines) and its accessibility audit; tap → expanded under 100 ms over five expansions, as the app measured it; Continue starting a conversation; Share opening the share sheet; Rename from More; Split Topic Here on a line |
| `TopicTimelineUITests` | opening on the current topic with bullets above the fold, only it expanded, compressed rows of one height; swiping into history and back by Now, swiping and tapping the current bullet; tapping to expand and compress in place; refined titles not moving the history; the VoiceOver labels and an accessibility audit of the timeline's elements; the largest text size |
| `TopicHistoryPagingTests`, `TopicTimelinePagingTests`, `PrependScrollAnchorTests` (BlauKit) | #57: the first window and its cutoff; pages of whole days through a 2,000-topic store, each a pure prepend of the rows shown before; a new topic not pushing the oldest out; conversations the window cuts through; the rail into unloaded history; choosing the held row, waiting when none on screen can be held (a long expanded topic), pinning it and putting it back |
| `TopicTimelinePagingUITests` | #57: from the current topic to the oldest of 2,000 with slow held drags, each moving the rows by the finger's travel within the pan's slop and a small fling (a page landing without its offset moves them thousands of points, a page's rows being measured hundreds); the whole history loads; the footprint grows less than 60 MB (about 15 minutes for this test). Flinging to the oldest topic and one tap on Now returning to the latest line |

UI tests seed a canned history with `-BlauTimelineFixture <topics>` on a
`ui-test` launch (12 topics over three conversations: two days ago,
yesterday and today, the last topic open; every third title starts as
"Draft <n>"), and `-BlauTimelineRelabelAfter <seconds>` refines every
provisional title from a separate `ModelContext` that long after seeding,
the way the topic lifecycle's store does. `-BlauTimelineRelabelOnDemand YES`
instead offers a UI-test-only toolbar action that refines the titles once
the test has reached history; slow launches cannot consume its timer.
Previews use the same fixture.
`-BlauTimelineHistory <topics>` seeds a long history instead: conversations
of five topics, two a day going back from today, titled "<title> <n>" with
n counting from the oldest (the "Timeline, long history" preview seeds
2,000).

The paging UI tests take about 25 minutes together (the scroll through
2,000 topics alone about 15), more than a CI UI-test shard
allows, so they skip unless `BLAU_LONG_UI_TESTS=1` (xcodebuild passes
`TEST_RUNNER_`-prefixed variables to the test runner). Run them on an iOS 26
and an iOS 27 simulator before changing the timeline's scrolling:

```sh
TEST_RUNNER_BLAU_LONG_UI_TESTS=1 xcodebuild test -scheme Blau -destination 'id=<iOS 26 simulator>' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -only-testing:BlauUITests/TopicTimelinePagingUITests
# and again with an iOS 27 simulator
```

Still to check by hand on a device: the pulse and the spring feel,
VoiceOver navigation with the rotor (the UI tests check the labels, values
and traits, not the spoken output), the expand latency on an iPhone
(Instruments, `timeline.expand`), Continue against Grok with a real
key ([realtime.md](realtime.md#manual-verification)), and flinging through a long history at
120 Hz on an iOS 27 iPhone (the UI test's drags are slow by design; a fling
that lands a page mid-deceleration is where a correction would show as a
hitch).
