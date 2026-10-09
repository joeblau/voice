# Accessibility

Blau is a voice app, and it also has to work for people who rely on
assistive technology: VoiceOver, Dynamic Type, Reduce Motion, Increased
Contrast, and people who can't hear Grok and read it instead. This page
lists what each screen does for them (#81), how it is tested and what still
needs a person with a device.

## VoiceOver

| Where | What VoiceOver gets |
| --- | --- |
| Topic timeline | A container labelled "Topics" with a **Topics** rotor that jumps between bullets. Each bullet is one button with the header trait: the title as its label, "Current topic, started 9:41 AM, recording" or "Yesterday, 6:08 PM, 8 minutes, collapsed" as its value, what a tap does as its hint ([timeline.md](timeline.md#voiceover)) |
| Topic changes | Announced without moving focus: "New topic: Pricing" when a new topic opens in the conversation on screen, "Topic named Pricing Experiments" when the labeler refines the current topic's provisional title. Quiet otherwise (see below) |
| Chat rows | One element per row: the speaker as the label ("You", "Grok", "Blau" for app notes and tool chips) and the words as the value, with "still speaking", "interrupted", "waiting to send" or "not sent" appended when it applies ([chat.md](chat.md)) |
| Record button | The label says what a tap does ("Start Conversation", "End Conversation"), the value where the conversation is ("Listening", "Grok is speaking", "Paused, microphone muted", "Lost the connection to Grok"...), the hint what isn't obvious. Pause and Resume Listening are custom actions. The large content viewer shows it at large text sizes |
| "You're muted" | Announced when it appears |
| Issue banner | A new problem is announced wherever focus is: its title and what it means. A blocking problem interrupts; the rest wait for VoiceOver to finish ([errors.md](errors.md)) |
| Live caption | One static text element: "Grok" as its label and the words as its value, with the updates-frequently trait |

Announcements go through `BlauAnnouncement` (`Blau/Accessibility/Announcements.swift`)
with a speech priority: topic changes are `low`, so they queue behind what
VoiceOver is saying instead of cutting it off.

**When a topic change is announced** is BlauKit's `TopicAnnouncer`
(`BlauTopics/Timeline`), tested on the Mac. It stays quiet:

- on the first topic it sees (the screen just opened);
- when the focus moves to another conversation (starting a conversation is
  already on the record button);
- when a conversation's stand-in bullet gives way to its first real topic;
- when the current topic is merged into the one before it;
- while a provisional title is replaced by another provisional one (the
  labeler is still guessing);
- when a title that wasn't provisional changes (the user renamed it).

## Dynamic Type

Every text style is a system text style (`BrandTextStyle`,
[branding.md](branding.md#typography)), so all text follows Dynamic Type up
to AX5. Nothing that labels something truncates at the accessibility sizes:

- An older topic's bullet puts its time under the title and grows instead of
  truncating; the current topic's title wraps.
- Conversation headings wrap (they used to stop at one line).
- The issue banner's buttons, an expanded topic's actions (Continue, Share,
  More) and the "You're muted" hint stack vertically when they don't fit side
  by side (`ViewThatFits`).
- The empty main screen scrolls instead of clipping.
- The live caption shows fewer words at the accessibility sizes (60
  characters against 140) and wraps them; it is cut to whole words by
  `ChatCaption.tail`, never by the layout.
- Toolbar buttons (Settings, Record) are system bar items that keep their
  size; touch and hold shows them in the large content viewer.

The only deliberate one-line truncations are excerpts of user content that
link to the full text: a note's excerpt in the knowledge base list, a
setting's current value in a list row.

## Reduce Motion

| Motion | Under Reduce Motion |
| --- | --- |
| The record button's level ring grows and shrinks with the level | Keeps its size; only its opacity follows the level |
| The spinner while a conversation starts or stops | A static ellipsis |
| The current topic's dot pulses while recording | A steady halo |
| The Now pill, the live caption, the speech-model card, "You're muted" and the issue banner slide in | They fade in place (`Motion.slide(from:reduceMotion:)`) |
| Now springs back to the latest line | A short ease |
| A refined title or a second-pass transcript cross-fades | Changes without animation |
| Expanding a topic, onboarding pages | No animation |

`RecordButtonSnapshotTests` covers the Reduce Motion faces of the record
button.

## Captions

Grok's words are always on screen while it speaks, for people who can't
hear it, are somewhere they can't play sound, or just missed a word:

- At the latest line they are the streaming row of the transcript, revealed
  in step with the audio ([chat.md](chat.md#where-the-rows-come-from)).
- Scrolled into the history, where that row is out of view, a **live
  caption** floats above the Now pill with the reply's latest words, revealed
  in step with the audio the same way. It takes no touches, so the history
  keeps scrolling under it (at AX5 it covers a good part of the screen); the
  Now pill below it returns to the latest line.
  `ChatCaption` (`BlauRealtime/Chat`) picks the reply (the newest streaming
  agent row) and cuts it; `LiveCaption` (`Blau/Chat/LiveCaption.swift`) lays it
  out.

There is no setting that hides Grok's text.

## Contrast

- Secondary text Blau draws on the background (times, durations,
  conversation headings, an expanded topic's summary and span, speech in
  progress, delivery notes, app notes, tool chips, the caption's speaker) uses the `secondaryText` brand token instead of the
  system's `.secondary`, which reaches only about 3.5:1 on white. The token
  reaches 4.5:1 or more in every appearance and contrast level
  ([branding.md](branding.md#color-tokens), checked by `BrandingTests`).
- The record button's face is white on a brand fill in every state. While a
  conversation runs the button is a menu (touch and hold for Pause), and it
  now uses `.menuStyle(.button)` so the bar draws it with the prominent fill;
  before, the bar drew the menu as plain glass and the white face all but
  disappeared on it.

## Testing

| Test | Covers |
| --- | --- |
| `TopicAnnouncerTests` (BlauKit, `make test-kit`) | when a topic change is announced and when it isn't |
| `ChatCaptionTests` (BlauKit) | which reply is captioned, cutting to whole words, fewer words at the accessibility sizes |
| `AccessibilityTests` (BlauTests) | the announcement wording and priorities, the Reduce Motion animation, the caption following the live model |
| `BrandingTests` (BlauTests) | `secondaryText` contrast, like the other tints |
| `AccessibilityAuditUITests` | XCTest's accessibility audit (`performAccessibilityAudit(for: .all)`, the checks of Accessibility Inspector's Audit tab) on the empty main screen, the timeline, a running conversation, the history with an expanded topic and the live caption, and Settings, each at the default size and at AX5 |
| `LiveCaptionUITests` | the caption appears only when Grok's row is out of view, reads as Grok's, shows the reply's latest words, sits above Now, lets a swipe that starts on it scroll the history, and goes when Now returns to the latest line; at AX5 it stays on screen with fewer words |
| `MainScreenUITests`, `TopicTimelineUITests`, `ChatTranscriptUITests` | the bottom bar, the timeline and the transcript at AX5 |

The UI tests set the text size with the launch arguments
`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`
(AX5). Run them with `make test-ui`, or only these with
`-only-testing:BlauUITests/AccessibilityAuditUITests -only-testing:BlauUITests/LiveCaptionUITests`.

The audit fails on every issue except four kinds it can't judge fairly,
listed in `AccessibilityAuditUITests`:

1. issues with no element (nodes the lazy stack built off screen, with no
   frame);
2. contrast of content under the bars (and within 24 pt of them), which the
   system's scroll edge effect fades on purpose, and of content under the
   live caption and the Now pill; the caption and the pill themselves are
   judged;
3. Dynamic Type of navigation and toolbar buttons, system controls that cap
   their size and show the large content viewer instead;
4. "partially unsupported" Dynamic Type of plain text in the timeline. The
   audit grows the text size and measures each element again, but the
   timeline is a scroll view anchored to its latest line (or to the top while
   reading history), so growing everything moves what it measures. It flags
   texts away from the anchor (a day heading, a conversation heading, a line
   of an expanded older topic), never the ones beside it.
   `testTimelineTextScalesWithDynamicType` measures the day and conversation
   headings at the default size and at AX5 and requires them to at least
   double (transcript lines use the same system text styles, and
   `ChatTranscriptUITests` lays them out at AX5). Text that doesn't scale at
   all still fails.

At AX5 the audit's Dynamic Type check has no larger size to try; the AX5
runs are there for clipped text, contrast, hit regions and descriptions at
that size.

### Known issue: layout loop at AX5 under UI automation

Found while writing these tests: at AX5, when the speech-model card's exit
animation (the main screen's bottom inset) runs while the current topic
holds a reply taller than the screen, the timeline's lazy stack can spin in
an endless layout loop (100 % CPU, the model card frozen halfway out) while
UI automation reads the screen. It reproduced in roughly one launch in three
under XCUITest and never in 12 launches without it. Without the tall reply
(10 launches) or with the reply arriving after the card has gone (12
launches) it didn't happen. The live app can't reach it the same way, since
Grok can only reply once the speech models are ready, so `LiveCaptionFixture`
now waits for them. Whether another animated inset (the issue banner
arriving at the top while a long reply is on screen) can trigger it with
VoiceOver on is still to check on a device, below.

### By hand, on a device

The simulator audit can't stand in for these:

| Check | How | Result |
| --- | --- | --- |
| Accessibility Inspector audit on a device | Xcode → Open Developer Tool → Accessibility Inspector, pick the iPhone, Audit each screen in the table above, light and dark | pending |
| VoiceOver navigation | Settings → Accessibility → VoiceOver. Swipe through the timeline; rotor → Topics jumps between bullets; double-tap expands; the record button's actions offer Pause Listening | pending |
| Announcements | With VoiceOver on, talk through a topic change: "New topic: …" is spoken after Grok's sentence, and "Topic named …" when the title is refined | pending |
| Live caption with VoiceOver | Scroll into history while Grok speaks: the caption reads "Grok, …" and VoiceOver can reach the Now pill below it | pending |
| AX5 everywhere | Settings → Accessibility → Display & Text Size → Larger Text, largest size: every screen, including onboarding, Settings panes and the knowledge base | pending |
| Reduce Motion | Settings → Accessibility → Motion → Reduce Motion: record, pause, scroll into history and back, expand topics | pending |
| Increased Contrast and Bold Text | Settings → Accessibility → Display & Text Size | pending |
| No layout loop at AX5 with VoiceOver | AX5 and VoiceOver on, a long reply on screen: go offline and back so the issue banner comes and goes; the screen stays responsive (see the known issue above) | pending |
