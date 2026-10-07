# Branding

Blau's visual identity (issue #82): the app icon, the launch screen, the
color tokens and the type scale. *Blau* is German for blue, so the brand is
one blue and a waveform.

| Piece | Where | Edited with |
| ----- | ----- | ----------- |
| App icon | `Blau/Resources/AppIcon.icon` | Icon Composer (Xcode 26+) |
| Color tokens, brand mark | `Blau/Resources/Assets.xcassets` | Xcode's asset catalog editor |
| Launch screen | `UILaunchScreen` in `project.yml` | `project.yml` |
| Token and type scale API | `Blau/Branding/` | Swift |
| Topic dot mapping | `BlauCore/Branding/TopicPalette.swift` | Swift |

## App icon

The icon is an **Icon Composer document** (`AppIcon.icon`), the layered
format iOS 26 introduced. The system renders it with Liquid Glass and
derives every appearance from the one document, so there are no per-size or
per-appearance PNGs in the repo. `ASSETCATALOG_COMPILER_APPICON_NAME` is
`AppIcon`, which matches the document's name; the build compiles it with
actool into `Assets.car` (one image stack per appearance: light, dark and
tintable) plus the flattened `AppIcon60x60@2x.png` fallback. The deployment
target is iOS 26, so the old `AppIcon.appiconset` is gone.

XcodeGen adds the document to the app's resources like any other file in
`Blau/` (file type `wrapper.icon`), so nothing in `project.yml` names it.

| Layer | Content | Light | Dark |
| ----- | ------- | ----- | ---- |
| Background | Linear gradient, top to 70% | P3 `#568AFF` → `#1A46E0` | P3 `#1A2552` → `#080B1F` |
| Group "Mark", layer "Voice" | The center bar of the waveform (`Assets/Voice.svg`) | white glass | P3 `#6896FF` glass |
| Group "Mark", layer "Waveform" | The four outer bars (`Assets/Waveform.svg`), 85% opacity | white glass | P3 `#6896FF` glass |

Tinted and clear appearances are derived by the system from the same layers.
The group has a neutral shadow, specular highlights and 40% translucency.

### Previewing every appearance

```sh
make icon-previews        # or: scripts/render-app-icon.sh [output-dir]
```

renders the icon with Icon Composer's `ictool` into `.build/AppIcon/`, one
PNG per design generation (iOS 26 and iOS 27) and rendition: `Default`
(light), `Dark`, `TintedLight`, `TintedDark`, `ClearLight` and `ClearDark`.
It fails if any rendition doesn't render. Note that `xcrun ictool` is a
different tool that can't export images; the script uses the one inside
Xcode's `Icon Composer.app` (override with `ICTOOL=`).

## Launch screen

The launch screen is the `UILaunchScreen` dictionary, not a storyboard:

| Key | Value | Why |
| --- | ----- | --- |
| `UIColorName` | `LaunchBackground` | Equal to the system background in both appearances, so launch hands over to the main screen without a flash |
| `UIImageName` | `BrandMark` | The waveform in the accent blue, 96 × 96 pt, centered |

The main screen's empty state (`BrandLockup`) shows the same mark, at the
same size, above the "Blau" wordmark. It doesn't sit in exactly the same
place: the launch image is centered on the whole screen, while the lockup is
centered in the area between the bars and sits above the onboarding button
until a key is stored, so at handoff the mark moves up by a few dozen points
on the same background.

## Color tokens

All colors are color sets in `Assets.xcassets`, each with a dark variant.
Code reads them through `BrandColor` and `TopicDotColor`
(`Blau/Branding/BrandColor.swift`), never as literals:
`Color.brand(.recording)`, `Color.topicDot(colorSeed: topic.colorSeed)`.

The brand colors come in two kinds:

- A **tint** (`accent`, `recording`) is drawn on the background as text or a
  glyph. It gets lighter in dark mode and, with Increased Contrast, moves
  further from the background.
- A **fill** (`accentFill`, `recordingFill`) is drawn behind a white label:
  a prominent button's background. It stays deep in dark mode and gets darker
  with Increased Contrast, so the label stays legible. Every prominent button
  uses one through `.brandProminentButtonStyle()`. The record button picks
  its fill per state (`RecordButtonFace.tint(for:)`): `accentFill` to start,
  `recordingFill` while a conversation runs, gray while paused and orange
  for errors ([app-shell.md](app-shell.md#record)).

One color can't be both. White on the dark accent `#4A7BFF` is 3.8:1, and on
its increased-contrast variant `#8AAEFF` only 2.2:1.

| Token | Color set | Light | Dark | Increased contrast (light / dark) | Use |
| ----- | --------- | ----- | ---- | --------------------------------- | --- |
| `accent` | `AccentColor` | `#2152E8` | `#4A7BFF` | `#1A3FBF` / `#8AAEFF` | The app's global accent (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`): tint, links, toggles, bordered buttons |
| `accentFill` | `Brand/AccentFill` | `#2152E8` | `#2F5FEE` | `#1A3FBF` / `#1E4BD6` | Behind a white label: prominent buttons, the idle record button |
| `launchBackground` | `Brand/LaunchBackground` | `#FFFFFF` | `#000000` | | Launch screen background |
| `recording` | `Brand/RecordingTint` | `#D92D20` | `#F0443A` | `#B02018` / `#FF7A70` | Recording state as text or a glyph |
| `recordingFill` | `Brand/RecordingFill` | `#D92D20` | `#C7271C` | `#A81F16` / `#B02018` | Behind a white label: the record button while recording |

Contrast, WCAG 2 (checked by `BrandingTests`):

- Tints reach at least 4.5:1 (text) against the system background in both
  appearances, and their increased-contrast variants reach more.
- A white label on a fill reaches at least 4.5:1 (text) in every appearance
  and contrast level, and Increased Contrast raises it. The fill itself
  reaches at least 3:1 (WCAG's minimum for graphics) against the system
  background, so the button's shape stays visible.
- Topic dots reach at least 3:1 (WCAG's minimum for graphics) on both the
  system background and the secondary background, in both appearances.

| Token | Against | Light | Dark | Increased contrast (light / dark) |
| ----- | ------- | ----- | ---- | --------------------------------- |
| `accent` | background | 6.1:1 | 5.6:1 | 8.4:1 / 9.6:1 |
| `recording` | background | 4.8:1 | 5.6:1 | 6.9:1 / 8.3:1 |
| `accentFill` | white label | 6.1:1 | 5.3:1 | 8.4:1 / 6.9:1 |
| `accentFill` | background | 6.1:1 | 4.0:1 | 8.4:1 / 3.0:1 |
| `recordingFill` | white label | 4.8:1 | 5.6:1 | 7.3:1 / 6.9:1 |
| `recordingFill` | background | 4.8:1 | 3.7:1 | 7.3:1 / 3.1:1 |

### Topic dots

The timeline (#56) gives each topic a dot color. A topic's `colorSeed` (on
`Topic`, the first two bytes of its id unless set) picks a slot with
`TopicPalette.slot(forColorSeed:)`: the non-negative remainder modulo 8.
Seeds from random ids are uniform over `0..<65536`, so each color is equally
likely, and because the seed syncs, a topic has the same color on every
device.

| Slot | Color set | Light | Dark |
| ---- | --------- | ----- | ---- |
| 0 | `TopicDots/TopicDot0` (blue) | `#2152E8` | `#5E8EFF` |
| 1 | `TopicDots/TopicDot1` (teal) | `#0E8A9E` | `#3CC8DC` |
| 2 | `TopicDots/TopicDot2` (green) | `#2E8540` | `#5FCB74` |
| 3 | `TopicDots/TopicDot3` (amber) | `#A86F00` | `#E8B53A` |
| 4 | `TopicDots/TopicDot4` (orange) | `#D4570F` | `#FF8A47` |
| 5 | `TopicDots/TopicDot5` (rose) | `#D12E5A` | `#FF6F92` |
| 6 | `TopicDots/TopicDot6` (magenta) | `#B03AB8` | `#E07AEB` |
| 7 | `TopicDots/TopicDot7` (violet) | `#6A4BD8` | `#9C86FF` |

The mapping is part of what the synced data means: changing the palette size
or `slot(forColorSeed:)` recolors every existing topic, so
`TopicPaletteTests` pins it. Changing a color set's value is safe.

## Typography

`BrandTextStyle` (`Blau/Branding/BrandTypography.swift`) is the type scale.
Every style is a system text style, so it follows Dynamic Type up to the
accessibility sizes, and Bold Text. The wordmark and titles use SF Pro
Rounded for the brand's voice; text read at length stays in SF Pro.

| Style | Text style | Design | Weight | Use |
| ----- | ---------- | ------ | ------ | --- |
| `wordmark` | Large Title | Rounded | Bold | The "Blau" wordmark |
| `topicTitle` | Title 2 | Rounded | Semibold | The current topic's title (#56) |
| `heading` | Headline | Rounded | Semibold | Sheet and section headings |
| `transcript` | Body | Default | Regular | What the user and Grok said (#42) |
| `topicBullet` | Callout | Default | Regular | A topic's bullets (#56) |
| `caption` | Footnote | Default | Regular | Hints, status, compressed older topics |
| `timestamp` | Caption | Default, monospaced digits | Regular | Times and durations |

Apply a style with `.brandTextStyle(.transcript)` or
`.font(.brand(.transcript))`.

## Verification

| Check | How |
| ----- | --- |
| Every token is in the asset catalog, with dark and (tints, fills) increased-contrast variants | `BrandingTests` (app-hosted, `make test-unit`) |
| Contrast thresholds above | `BrandingTests` |
| Launch screen background and image resolve in both appearances | `BrandingTests` |
| The icon compiles into the app (`CFBundleIconName` `AppIcon`, fallback PNG) | `BrandingTests` |
| The icon renders in every appearance | `make icon-previews` |
| Topic color mapping is stable and uniform | `TopicPaletteTests` (`make test-kit`) |
| The icon on a real home screen (light, dark, tinted, clear; iOS 26 and 27) | By hand on an iPhone: Home Screen → Edit → Customize |
