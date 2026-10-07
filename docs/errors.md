# Errors, offline mode and edge states

Blau fails gracefully everywhere (issue #80). Every problem the user can
notice has one entry in the **error catalog**: a stable code, a title, a
message that says what it means for the conversation, a severity and the
recovery actions offered. Subsystems map their own errors to the catalog;
the app shows the worst current issue in one banner above the
conversation.

| Piece | Where | What it does |
| ----- | ----- | ------------ |
| `IssueCode` | `BlauCore/Issues/IssueCode.swift` | The catalog: every code with its title, message, severity and default actions |
| `UserFacingIssue` | `BlauCore/Issues/UserFacingIssue.swift` | One issue as shown: a catalog entry plus specifics (a count, a sanitized server message) |
| `RecoveryAction` | same file | The buttons: Try Again, Discard, Update Key, Open xAI Console, Open Settings, Resume, Use Cellular Data |
| `IssueBoard` | `BlauCore/Issues/IssueBoard.swift` | One issue per source (conversation, audio, storage), worst first, dismissals |
| Mappings | `BlauRealtime/Issues/`, `BlauAudio/Issues/`, `BlauTranscription/Issues/`, `BlauPersistence/Issues/` | `XAIError.issue`, `RealtimeClientError.issue`, `RealtimeErrorDetail.issue`, `TurnFailure.issue`, `TurnSnapshot.issue`, `AudioSessionError.issue`, `AudioSessionKeeper.Status.issue`, `ModelFailure.issue`, `ModelSetupStatus.issue`, `SyncState.issue` |
| `IssueCenter` | `Blau/Issues/IssueCenter.swift` | Follows the orchestrator, the audio keeper and the store, feeds the network path to the orchestrator, carries out Try Again, Discard and Resume |
| `IssueBanner` | `Blau/Issues/IssueBanner.swift` | The banner: symbol, title, message, detail, action buttons, dismiss |

Details shown under a message are sanitized: server messages go through
`XAIError.sanitize` (key-shaped strings masked, 300 characters at most),
otherwise only HTTP statuses and system error domains and codes. Never a
key, a client secret or anything the user said. Every issue change is
logged under `category:ui` (`Issue connection.offline (info) from
conversation`).

## Severity

| Severity | Meaning | Banner | Dismiss |
| -------- | ------- | ------ | ------- |
| info | Degraded, and Blau recovers by itself | Secondary tint | Yes, until it changes |
| warning | Something didn't work; the conversation goes on | Orange | Yes, until it changes |
| blocking | Nothing works until the user acts | Red | No |

A dismissed issue stays hidden while its source keeps reporting it, and
comes back once the source reports something else or clears and reports it
again (`IssueBoard`).

## The catalog

Each code is stable: it is logged, and the banner's accessibility value
carries it. The test `IssueCatalogTests.theCatalogDocumentListsEveryCode`
fails when a code is missing here, or listed here but not in `IssueCode`.

### Connection to Grok

| Code | Title | When | What Blau does | Actions |
| ---- | ----- | ---- | -------------- | ------- |
| `connection.offline` | You're offline | `NWPathMonitor` reports no path, or the client gave up on `notConnectedToInternet`, `dataNotAllowed`, `internationalRoamingOff` or `callIsActive` | Keeps transcribing, storing and segmenting topics; queues utterances; reconnects the moment the path is back | Discard (while utterances wait) |
| `connection.reconnecting` | Reconnecting to Grok… | The socket dropped and the client is reopening it (or resuming the conversation, #39) | Queues utterances and sends them as one turn after the resume or reseed | Discard (while utterances wait) |
| `connection.unreachable` | Can't reach Grok | The client's 8 reconnect attempts ran out on timeouts, resets, missed pongs or server closes | Tries again every 30 s while the network is up (`retryAfterGivingUp`), and at once when the path comes back | Try Again, Discard |
| `connection.insecure` | Secure connection failed | TLS failed: an untrusted or expired certificate, often a captive portal, a VPN or a wrong clock | Tries again like `connection.unreachable` | Try Again |
| `connection.rateLimited` | Grok is busy | HTTP 429 on the token or the upgrade, or an `error` / failed response with a `rate_limit` code | The client retries with backoff; after it gives up, every 30 s | Try Again |
| `connection.serverError` | xAI is having problems | HTTP 408 or 5xx, or an `internal_error` from the server | Tries again later | Try Again |

### xAI account

| Code | Title | When | What Blau does | Actions |
| ---- | ----- | ---- | -------------- | ------- |
| `account.missingKey` | Connect your xAI account | No key in the Keychain (#33) | Keeps transcribing; never retries on its own | Update Key |
| `account.invalidKey` | xAI didn't accept your key | HTTP 400/401 minting a secret, or the upgrade refused twice | Never retries on its own | Update Key, Open xAI Console |
| `account.keyDisabled` | Your xAI key is switched off | The key or its team is blocked or disabled | Never retries on its own | Open xAI Console, Update Key |
| `account.noCredits` | No xAI credits left | No credits or spending limit reached (HTTP 402/403/429 with a credit message, or `insufficient_quota`) | Never retries on its own | Open xAI Console, Try Again |
| `account.notPermitted` | Your key can't use voice | HTTP 403: the key's ACL doesn't allow the realtime API | Never retries on its own | Open xAI Console, Update Key |
| `account.keychainLocked` | Unlock your iPhone | The Keychain is locked (first unlock after a restart hasn't happened) | Retries like a network failure | Try Again |
| `account.keychainFailure` | Couldn't read your xAI key | A Keychain error or an unreadable item | Never retries on its own | Update Key |

### Replies

| Code | Title | When | What Blau does | Actions |
| ---- | ----- | ---- | -------------- | ------- |
| `reply.failed` | Grok couldn't answer | `response.done` with status `failed`, or an `error` rejecting the turn's `response.create` | Ends the turn; the next utterance starts a new one | none (say it again) |
| `reply.timedOut` | No answer from Grok | No `response.created` within 15 s of `response.create` | Ends the turn; a late response is cancelled | none (say it again) |
| `reply.unexpected` | Something went wrong | HTTP 400/404/422 that isn't about the key, an undecodable token response, an event Blau can't encode | Reports it; a protocol change can't end a session (unknown frames are ignored, see the fuzz tests below) | Try Again |

### Microphone and audio

| Code | Title | When | What Blau does | Actions |
| ---- | ----- | ---- | -------------- | ------- |
| `audio.microphoneDenied` | Microphone access is off | Permission denied | Nothing records until it's on | Open Settings |
| `audio.routeLost` | No microphone | Mic route lost: the route went away (headset unplugged, Bluetooth out of range) and `AVAudioSession` reports `noSuitableRouteForCategory` | Stops the engine (`failed(.noSuitableRoute)`); a route that simply changes (AirPods out, the built-in mic left) is rebuilt without the user noticing (#23) | Resume |
| `audio.microphoneBusy` | Microphone in use | Activation failed: a call or another app holds the microphone | Waits | Resume |
| `audio.interrupted` | Paused | A call, Siri or another app interrupted the session | Resumes when the system says it should | Resume |
| `audio.paused` | Listening paused | Audio stopped off screen and iOS won't let it restart there | Resumes on the next return to the foreground | Resume |
| `audio.recovering` | Restarting the microphone… | Capture stalled; the keeper is rebuilding the graph (#26) | Rebuilds, then restarts or pauses | none |
| `audio.failed` | Audio couldn't start | Configuration, graph or engine start failed | Retries on the next foreground | Resume |

### Speech models

These show in the speech model card (`SpeechModelSetupView`), not the
banner; `ModelFailure.issue` and `ModelSetupStatus.issue` give the same
codes for code that wants them.

| Code | Title | When | What Blau does | Actions |
| ---- | ----- | ---- | -------------- | ------- |
| `models.waitingForNetwork` | Waiting for a connection | A download waits for any network | Resumes by itself | none |
| `models.waitingForWiFi` | Waiting for Wi-Fi | Wi-Fi-only policy on cellular or Low Data Mode | Resumes on Wi-Fi | Use Cellular Data |
| `models.storageFull` | Not enough storage | Not enough free space (with the size), or writing failed | Stops the download | Try Again |
| `models.downloadFailed` | Download failed | Retries ran out, or the model server refused a file | Stops the download | Try Again |
| `models.damaged` | Download damaged | A file kept failing its SHA-256 | Stops the download | Try Again |
| `models.loadFailed` | Speech model won't load | Core ML couldn't load an installed model, even after one automatic re-download | Stops using the model | Try Again |

### Storage and iCloud

| Code | Title | When | What Blau does | Actions |
| ---- | ----- | ---- | -------------- | ------- |
| `storage.iCloudFull` | iCloud storage is full | CloudKit mirroring fails with `quotaExceeded` (CKError 25) | Keeps saving on the device; syncs once there is space | Open Settings |
| `storage.iCloudUnavailable` | iCloud sync is off | Not signed in, iCloud off for Blau, or the account needs attention (`notAuthenticated`) | Keeps saving on the device | Open Settings |
| `storage.syncPaused` | iCloud sync paused | Any other mirroring failure (network failures excepted: the conversation's banner already says offline) | Retries by itself | none |
| `storage.transcriptNotSaved` | Couldn't save the conversation | A transcript write failed | The conversation goes on; Grok still has the words | none |
| `storage.unavailable` | Conversations aren't being saved | The database couldn't be opened; Blau runs on an in-memory store | Nothing is kept until a restart | none |

`account.*` problems found while *entering* a key are worded separately,
next to the key field (`XAIAccountProblem`, [xai-auth.md](xai-auth.md)).

## Offline mode

```
online ──path lost / drop──▶ reconnecting ──retries run out──▶ offline (no path) or unavailable (path, but xAI unreachable)
   ▲                              │                                     │
   └────────── session ready ◀────┴──── path back: reconnect at once ◀──┘   (and every 30 s while the path is up)
```

- **Transcription never stops.** Parakeet, VAD and the second pass run on
  device; the voice loop doesn't depend on the connection. Utterances are
  written to SwiftData at once (they reach the screen through the
  transcript feed) and queued in the orchestrator.
- **Visible state.** The banner says "You're offline" (or "Reconnecting to
  Grok…", or why Blau can't connect) and how many messages wait. Each
  waiting user row shows "Waiting to send" (`ChatRow.delivery`), read by
  VoiceOver as part of the row.
- **Sent when back online.** When the path returns (`NWPathMonitor` →
  `TurnOrchestrator.networkReachabilityChanged(_:)`) and the client had
  given up, the orchestrator reconnects at once. The new connection
  resumes the server conversation (`?conversation_id=`) or, after 25 idle
  minutes or a refused resumption, is reseeded with the recent exchanges
  (#39). The queued utterances then go out, in order, as one turn with one
  `response.create`, and Grok answers them together.
- **Or discarded.** Discard drops the queue: the rows stay in the
  transcript, marked "Not sent", and Grok never sees them, not even in a
  later reseed (`TurnOrchestrator.discardQueued()`). Utterances still
  waiting when the conversation stops are marked "Not sent" the same way.
- **Topics keep segmenting.** An exchange normally closes when Grok's reply
  is stored. While replies are deferred the orchestrator tells the
  transcript (`TurnTranscriptRecording.repliesDeferredChanged`), and the
  topic lifecycle scores each user utterance as an exchange of its own
  (`TopicLifecycle.setRepliesDeferred`), so topics open, get titles from the
  on-device labeler and close as usual. Replies that arrive after the
  outage become exchanges of their own.
- **Key problems wait for the user.** An `account.*` failure is never
  retried by itself, network or not; Update Key, then Try Again.

### Why this design

- The issue asked for turns queued "with a visible offline state". The
  orchestrator already queued utterances across drops (#36, #39); what was
  missing was a reason to reconnect after the client's retries ran out
  (about 45 s), so a longer outage needed a manual restart. The network path
  and a slow retry timer close that gap without hammering xAI while
  offline (the orchestrator's own retries pause while the path is down).
- Before this change the topic lifecycle waited for a reply to close each
  exchange, so offline speech piled into one exchange and no topic could
  open. Scoring user-only exchanges only while replies are deferred keeps
  the online grouping (a question and its answer) unchanged.

## Fuzzing the realtime decoder

`RealtimeEventFuzzTests` (BlauRealtime) mutates every server frame of the
fixture sessions with a seeded generator: byte flips, insertions of JSON
punctuation and invalid UTF-8, deletions, truncations, values replaced with
other types, dropped keys, another event's `type`, wrapped payloads; plus
random bytes and hand-picked hostile frames (100,000-deep nesting, `1e999`,
a 2 MB base64 audio delta, bad base64, odd-length audio, lone surrogates, a BOM,
duplicate keys). It checks that `RealtimeEventCoding.decodeServerEvent`
never traps, that an untypeable frame comes back `.unknown` with its exact
bytes, that a typed frame round-trips unchanged, and that 500 malformed
frames plus binary garbage pushed through a live `RealtimeClient` and
`TurnOrchestrator` neither drop the socket nor disturb the next turn. A
longer run:

```sh
cd Packages/BlauKit
BLAU_FUZZ_ITERATIONS=1000 swift test --filter RealtimeEventFuzzTests
```

## Tests

```sh
cd Packages/BlauKit
swift test --filter "IssueCatalogTests|IssueBoardTests|RealtimeIssue|ConversationConnectivity|TurnOrchestratorOfflineTests|RealtimeEventFuzzTests|ChatDeliveryTests|TopicLifecycleOfflineTests|SyncIssueTests|ModelIssueTests|AudioIssueTests"
```

- **Airplane mode, simulated**
  (`TurnOrchestratorOfflineTests.airplaneModeKeepsTheTranscriptGoingAndRecoversOnReconnect`):
  a real `RealtimeClient` over fake sockets on a manual clock. A turn is
  answered; the path goes away and the socket dies with
  `notConnectedToInternet`; the client's eight attempts fail and it gives
  up; three utterances are stored and queued (`connection.offline`, "3
  messages are waiting to send", Discard); the path returns and the
  orchestrator reconnects at once, resumes `conv_1`, sends the three as one
  turn and the answer is stored. The transcript holds every line in order.
- A drop with the network up shows `connection.reconnecting`; an xAI
  outage gives up as `connection.serverError` and is retried 30 s later;
  a key problem is never retried by itself and works after Try Again.
- Discarded utterances stay stored, are never sent, and are left out of a
  reseed.
- Topics segment a user-only transcript (the `threeTopics` script without
  its replies) into three topics while replies are deferred, each switch
  found within two exchanges of where the subject changes. With only the
  user's short questions the boundaries are less precise than with whole
  exchanges (one lands two exchanges early).
- Every catalog entry is complete, every mapping lands on its code, and
  docs/errors.md lists every code.

## Manual verification

| Check | How | Result |
| ----- | --- | ------ |
| Airplane mode on a device | Start a conversation (Debug menu → Voice Loop), ask something, turn on Airplane Mode, keep talking for a minute (past the client's ~45 s of retries), turn it off. Expected: the banner shows "You're offline" with the count; each line you say appears with "Waiting to send"; within seconds of Airplane Mode off, Console (`category:realtime`) shows `Network is back; reconnecting`, `Resumed conversation …` (or `Reseeding …`) and `Sending n queued utterance(s)`; Grok answers them; the banner disappears | pending (needs a device and xAI credentials) |
| Discard on a device | As above, but tap Discard while offline. The lines stay with "Not sent"; after reconnecting Grok doesn't answer them | pending (needs a device and xAI credentials) |
| Topics offline | Talk about two clearly different subjects in Airplane Mode for a few minutes each; the timeline (#56) shows two topics before reconnecting | pending (needs a device) |
| Mic route lost | Record with wired headphones (or a USB mic) on an iPad/iPhone without another usable input; unplug. Expected `No microphone` with Resume when nothing else can record; on an iPhone the built-in mic takes over and no banner shows | pending (needs a device and accessories) |
| Call interruption | Receive a call mid-conversation: `Paused` (info), then audio resumes after the call or with Resume | pending (needs a device) |
| iCloud full | On an account with full iCloud storage, finish a conversation: `iCloud storage is full` with Open Settings; data stays on the device | pending (needs a full iCloud account) |
| Invalid key | Enter a revoked key through the DEBUG seed (or revoke it at console.x.ai mid-session): `xAI didn't accept your key`, Update Key opens key entry, Try Again reconnects | pending (needs xAI credentials) |
| Rate limit | Hard to force; if a session hits it, note the `error` event's `type` and `code` here so `RealtimeErrorDetail.issue` matches xAI's real values | pending (needs xAI credentials) |
