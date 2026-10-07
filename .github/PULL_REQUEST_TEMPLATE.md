<!--
Title: what the change does, then the issue number, e.g.
"Build the mic capture engine (#24)". The PR is squash-merged, so the title
becomes the commit on main. See CONTRIBUTING.md.
-->

## Summary

<!-- What changed and why. Call out decisions, deviations from the issue's
design notes, and anything a reviewer should look at first. -->

Closes #

## Acceptance criteria

<!-- Copy each criterion from the issue. Check a box only if you verified it,
and say how. Leave it unchecked with the reason if it could not be verified
here (needs a device, a developer account, real credentials, a human...). -->

- [ ] 

## Needs on-device / manual verification

<!-- What still has to be checked on a physical iPhone, in the CloudKit
console, with real xAI credentials, or by a person. Write "None" if nothing. -->

## Test evidence

<!-- The commands you ran and their results. -->

```
$ make lint
$ make build
$ make test DESTINATION='id=<simulator udid>'
$ (cd Packages/BlauKit && swift test)
```

## Checklist

- [ ] `make lint` passes
- [ ] Builds with no new warnings (Swift 6, strict concurrency)
- [ ] New logic has tests (Swift Testing for units; XCTest for UI and performance), and they are hermetic: no network, real keys or model downloads
- [ ] No secrets, `Secrets.xcconfig` or generated `.xcodeproj` committed
- [ ] Docs updated (README, CONTRIBUTING.md, `docs/`) if behaviour or workflow changed
