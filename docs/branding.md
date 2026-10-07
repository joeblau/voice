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

The main screen's empty state (`BrandLockup`) shows the same mark above the
"Blau" wordmark, so the mark stays put while the app finishes launching.

## Color tokens

All colors are color sets in `Assets.xcassets`, each with a dark variant.
Code reads them through `BrandColor` and `TopicDotColor`
(`Blau/Branding/BrandColor.swift`), never as literals:
`Color.brand(.recording)`, `Color.topicDot(colorSeed: topic.colorSeed)`.

| Token | Color set | Light | Dark | Increased contrast (light / dark) | Use |
| ----- | --------- | ----- | ---- | --------------------------------- | --- |
| `accent` | `AccentColor` | `#2152E8` | `#4A7BFF` | `#1A3FBF` / `#8AAEFF` | The app's global accent (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`): tint, buttons, the record button |
| `launchBackground` | `Brand/LaunchBackground` | `#FFFFFF` | `#000000` | | Launch screen background |
| `recording` | `Brand/RecordingTint` | `#D92D20` | `#F0443A` | `#B02018` / `#FF7A70` | The record button while recording |

Contrast, WCAG 2 (checked by `BrandingTests`):

- `accent` and `recording` reach at least 4.5:1 against the system background
  in both appearances (text contrast), and the increased-contrast variants
  reach more. Light accent: 6.1:1 on white, and a white glyph on it 6.1:1.
  Dark accent: 5.6:1 on black.
- Topic dots reach at least 3:1 (WCAG's minimum for graphics) on both the
  system background and the secondary background, in both appearances.

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
| Every token is in the asset catalog, with dark and (accent, recording) increased-contrast variants | `BrandingTests` (app-hosted, `make test-unit`) |
| Contrast thresholds above | `BrandingTests` |
| Launch screen background and image resolve in both appearances | `BrandingTests` |
| The icon compiles into the app (`CFBundleIconName` `AppIcon`, fallback PNG) | `BrandingTests` |
| The icon renders in every appearance | `make icon-previews` |
| Topic color mapping is stable and uniform | `TopicPaletteTests` (`make test-kit`) |
| The icon on a real home screen (light, dark, tinted, clear; iOS 26 and 27) | By hand on an iPhone: Home Screen → Edit → Customize |
