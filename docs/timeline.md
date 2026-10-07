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
| Swipes down | Scrolls up into the history: compressed bullets on a continuous rail, oldest at the top, grouped by day ("Today", "Yesterday", "Tuesday, October 6") and by conversation |
| Taps a compressed bullet | Expands it in place: its summary and transcript open below the bullet, which doesn't move. Tapping again compresses it. Several can be open at once (the full detail with its actions is #58) |
| Swipes back, taps **Now** or taps the current bullet | Returns to the latest line with a spring (a short ease under Reduce Motion). The Now pill shows whenever the latest line is out of view |
| Long-presses a bullet | Rename and Merge with Previous (#54, `topicEditMenu`) |

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
  label changing never moves what they're reading. Tapping a bullet switches
  to `.top` first, so it stays where it is while its transcript opens.
- **No scroll jumps from labels.** Compressed rows have a fixed height, so a
  new title never changes the layout of the history; the current bullet's
  title is at the bottom, where the anchor is.
- `onScrollGeometryChange` tracks whether the latest line is in view:
  `visibleRect.maxY − contentInsets.bottom` against the content height.
  (`containerSize` leaves out the bar insets on iOS 26, so the visible rect
  is the reliable measure.)
- `scrollPosition($position)` drives Now (`scrollTo(edge: .bottom)`) and is
  keyed by `TopicTimeline.ItemID`, ready for #57's paging.
- The timeline loads the 500 most recent topics
  (`TopicTimeline.recentTopics()`). Paging older history in as the user
  scrolls up, and the iOS 27 prepend regression (FB24968838), are #57.

## VoiceOver

- The timeline is a container labelled "Topics" with a **Topics** rotor
  (`accessibilityRotor`) that jumps between bullets, loaded or not.
- Each bullet is one button with the header trait. Its label is the title;
  its value says when and how long: "Current topic, started 9:41 AM,
  recording", or "Yesterday, 6:08 PM, 8 minutes, collapsed". The hint says
  what a tap does ("Shows the topic's transcript", "Collapses the topic",
  "Shows the latest line").
- Day headings have the header trait; transcript rows read as in #42.

## Where the code is

| Piece | Where |
| --- | --- |
| Order, groups, current topic, rail, fetch (`TopicTimeline`, `TimelineTopic`) | `Packages/BlauKit/Sources/BlauTopics/Timeline/` |
| Which lines belong to a topic (`TopicMembership`): the store's link, else by time | same |
| Expansion rules (`TopicExpansion`), times and durations (`TopicTimelineFormat`) | same |
| The scroll view, Now pill, rotor (`TopicTimelineView`) | `Blau/Timeline/TopicTimelineView.swift` |
| Bullets, rail, dot, headings, VoiceOver text (`TopicBullet`, `TopicBulletDescription`) | `Blau/Timeline/TopicBullet.swift` |
| A topic's transcript rows (`TopicTranscriptRows`) | `Blau/Timeline/TopicTranscriptRows.swift` |
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
| `TopicTimelineUITests` | opening on the current topic with bullets above the fold, only it expanded, compressed rows of one height; swiping into history and back by Now, swiping and tapping the current bullet; tapping to expand and compress in place; refined titles not moving the history; the VoiceOver labels and an accessibility audit of the timeline's elements; the largest text size |

UI tests seed a canned history with `-BlauTimelineFixture <topics>` on a
`ui-test` launch (12 topics over three conversations: two days ago,
yesterday and today, the last topic open; every third title starts as
"Draft <n>"), and `-BlauTimelineRelabelAfter <seconds>` refines every
provisional title from a separate `ModelContext` that long after seeding,
the way the topic lifecycle's store does. Previews use the same fixture.

Still to check by hand on a device: the pulse and the spring feel, and
VoiceOver navigation with the rotor (the UI tests check the labels, values
and traits, not the spoken output).
