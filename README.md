# Fulcrum

Your [tilt](https://tilt.dev) instances, in the macOS menu bar.

Fulcrum is a native macOS front end for tilt — not a replacement for it. It
finds whatever instances you are already running, shows their resource health
in the menu bar, and gives you a readable log pane without a browser tab open.

**[Download for macOS](https://fulcrum.originalfunction.com)** — signed,
notarized, free. macOS 14 (Sonoma) or later.

## What it does

- **Every instance at a glance.** Resource health in the menu bar, grouped by
  label.
- **Tells you when a build breaks.** A notification the moment a resource starts
  failing; click it and you land on that resource.
- **Logs that are readable.** Live streaming with filters, ANSI colour
  preserved, and JSON collapsed into a tree you can expand.
- **Search that keeps the context.** Match a line inside a log record and you
  get the whole record, not an orphaned fragment.
- **Failures you can see without reading.** Rows are scored by severity from
  their own structure and tinted, with an errors-only filter and
  jump-to-next-error.
- **Control without the terminal.** Trigger, enable and disable resources;
  reload a Tiltfile; open a project's web UI.

## Building

Requires Xcode 16 or later (Swift 6) and macOS 14+.

```sh
git clone https://github.com/OriginalFunction/fulcrum.git
cd fulcrum
swift test                                    # the logic layer, no Xcode needed
xcodebuild -project Fulcrum/Fulcrum.xcodeproj \
           -scheme Fulcrum -destination 'platform=macOS' build
```

`swift test` must pass without Xcode — that is a deliberate constraint, not an
accident. Note that `xcodebuild -scheme Fulcrum` without `-project` fails from
the repository root, because SwiftPM resolves the root as a workspace named
`fulcrum`.

## Layout

| Path | What lives there |
|---|---|
| `Sources/FulcrumKit/` | All logic: discovery, the tilt API client, log streaming, parsing, filtering, severity scoring, settings. Pure Swift. |
| `Fulcrum/Fulcrum/` | The app: SwiftUI views, AppKit window and menu bar controllers. Thin. |
| `Tests/FulcrumKitTests/` | swift-testing suites for everything in `FulcrumKit`. |
| `scripts/` | Release: build, sign, notarize, staple, tag, publish. |
| `site/` | The download page and its CDK stack. |
| `docs/` | Design specs and implementation plans. |

**`FulcrumKit` must never import AppKit, SwiftUI or UserNotifications.** That
boundary is what keeps the logic testable from the command line, and it is
enforced by the build rather than by convention.

## Contributing

Issues and pull requests are welcome.

A few things worth knowing before you send a patch, because they are unusual
enough to trip people up:

- **Tests count operations; they do not time them.** Eight wall-clock bounds
  have been replaced in this project after flaking or failing to discriminate.
  If you need to prove work did not happen twice, count the invocations.
- **A test's name is a claim.** Several tests have shipped here asserting
  something other than what their name said. Before adding one, break the code
  it covers and check that it actually fails.
- **The log corpus is synthesized.** `Tests/FulcrumKitTests/Fixtures/` holds a
  generated corpus with the shapes real emitters produce — pino, postgres,
  nginx, vite, embedded JSON, ANSI escapes. The severity rules are validated
  against it. If you add a rule, add the shape it recognises to the generator
  rather than hand-writing a fixture that suits the rule.

## Licence

Apache License 2.0 — see [LICENSE](LICENSE).

Copyright 2026 Original Function Inc.

Not affiliated with the tilt project.
