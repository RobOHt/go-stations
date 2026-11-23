# Contributing to GO Stations

Thanks for helping. GO Stations is a small, opinionated app for people who ride GO
trains, so the bar for a change is simple: does it make the app more useful or more
reliable for a rider? This page covers how to propose a change, the rules every
change follows, and how to get it merged.

By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md). To report a
security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Before you start

- **Open an issue first** for anything beyond a small fix, using the bug or feature
  form. Describe what a rider sees now and what they should see.
- **Design changes start as a proposal.** For anything that changes how the app
  looks or behaves (a new screen, a moved control, different wording on the board),
  post a mockup or simulator screenshots in the issue and agree on the design before
  writing the code.
- **Check the open issues** and say you're taking one, so two people don't do the
  same work.

## The rules

These apply to every commit, test, screenshot, issue and pull request.

### 1. No personal data, anywhere

The repository is public. Never put in it a real person's home or work station,
their commute, where they live or work, their location, email address or phone
number: not in code, tests, fixtures, screenshots, commit messages, issues or
workflow logs.

- Use the made-up commuter the tests use: **home Oakville, work Union**, on
  Lakeshore West (`-homeStation OA -workStation UN` in debug launches).
- Take screenshots and recordings in the simulator with those made-up stations, or
  crop out anything personal. Never post a screenshot showing your own home or work.
- Trip numbers in tests are made up too.

### 2. No secrets, anywhere

The Metrolinx, App Store Connect, Apple push and Cloudflare keys live only in GitHub
Actions secrets and Cloudflare Worker secrets. Never commit a key, paste one into an
issue or pull request, or print one in a workflow log. The app never ships a key:
it reaches Metrolinx only through the Worker. If you think a key has leaked, follow
[SECURITY.md](SECURITY.md).

### 3. Expect GO's data to be wrong

Feeds freeze, answer with web pages, and send the same thing in different shapes.
For anything that reads GO's data:

- **Write the test first**, from what a rider should see, then make it pass. Name
  tests after the behaviour ("a frozen feed: the timetable's trains, not
  yesterday's").
- **Read feeds leniently.** New fields on the response shapes use `@FeedText`,
  `@FeedList` or `@FeedPart` (`Departures/API/MetrolinxClient.swift`), so one odd
  value costs that value, not the whole answer. Never force-unwrap feed data.
- **Fail visibly.** When live data can't be used, fall back to the timetable and say
  so on screen; don't show an empty board as if no trains were running.

### 4. Go easy on Metrolinx

Every request goes through the Worker, which caches answers so riders share them.
Don't add polling, background fetches or new endpoints without discussing it in an
issue first, and keep refresh intervals at or above the Worker's cache times.

### 5. Respect the data's licence and GO's brand

GO's data is used under the Open Government Licence – Ontario; keep the attribution
in the README. GO Transit and Metrolinx names and logos belong to Metrolinx: describe
the service, but don't add their logos or make the app look official. New data
sources need a licence that allows this use.

## Development setup

| Part | You need |
| --- | --- |
| iOS app | Xcode 26 or later (CI uses Xcode 27), iOS 18 simulator or device. Swift 5 language mode, no third-party packages |
| Worker | Node.js 22 (tests use Node's built-in test runner; no `npm install`) |
| Tools | Python 3 (`tools/` builds the network and timetable from GO's GTFS) |

Open `Departures.xcodeproj`, pick your team under *Signing & Capabilities*, and run.
The app talks to the project's Worker out of the box; to run your own, see
[docs/SETUP.md](docs/SETUP.md).

## Tests

Run the tests that cover what you changed, and add tests for new behaviour.

```sh
node --test worker/test/*.test.js   # the Worker: a few seconds, no network
```

In Xcode, *Product → Test* runs the app's unit tests (`DeparturesTests`) and UI
tests (`DeparturesUITests`).

- **Unit tests** reach "the network" through `FakeNetwork`, which answers by path
  ("/Stop/NextService/OA"). Build fixtures with times relative to now
  (`Toronto.inMinutes(12)`), and use a fresh trip number per test.
- **UI tests** give the app made-up feeds at launch (`GO_FIXTURES`, served by
  `GOFixtures` in debug builds) and open a set-up scene (`-debugScene station`).
- **Tracking logic** is also covered by the in-app self-checks (`SelfCheck.swift`),
  which run as a unit test.

Pull requests run the app's tests and a simulator build on GitHub; changes under
`worker/` and to the start-up planner run their own checks.

## Code style

- **Match the code around you.** SwiftUI views, small types, `async`/`await`; the
  Worker is plain modern JavaScript with no dependencies.
- **Comments say why, in plain words**, the way a rider would put it ("A train
  standing at a station is taken to stay at least this much longer"), not what the
  next line does.
- **Keep the board looking like GO's**: bilingual headings, line colours, platform
  numbers. The board's fixed type sizes are deliberate.
- **iOS 18 and later.** Use iOS 26 features (Liquid Glass) behind availability
  checks, with an iOS 18 fallback.

## Commits

One change per commit, with a subject that says what changes for a rider, or for the
part of the project it touches:

```
A late train past the last stop Metrolinx times: still late, still tracked
Every board: toward work, toward home, or all directions
Worker: say so when the next train of a trip with changes is cancelled
```

No trailing period. Use the body to say why, and what you checked.

## Pull requests

1. Fork the repository and branch from `main`.
2. Keep the pull request to one change, and fill in the template: what changes for a
   rider, how it's tested, and screenshots for anything visible (simulator, made-up
   stations).
3. Make sure the checks pass. A maintainer reviews, may ask for changes, and merges.

Every merge to `main` runs the app's tests and, when they pass, ships a TestFlight
build; changes under `worker/` deploy the Worker. So `main` must always be
releasable.

## Questions

Open an issue with the question; there's no question too small.
