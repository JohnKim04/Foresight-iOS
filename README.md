# Foresight for iOS

Foresight is a native SwiftUI journal for recording what happened, checking in on outcomes, and reviewing personal patterns without causal claims. This is a fresh iOS-only implementation of the existing React Native product; it does not import Expo or AsyncStorage data.

## Prerequisites

- macOS with Xcode 27 and an installed iOS 26 simulator runtime.
- Accept the Xcode license once: `sudo xcodebuild -license accept`.
- XcodeGen: `brew install xcodegen`.

## Run it

Generate the committed Xcode project after any `project.yml` change:

```sh
cd /Users/johnkim/Documents/Projects/Foresight-projects/Foresight-iOS
xcodegen generate --spec project.yml
open Foresight.xcodeproj
```

Select the **Foresight QA** scheme and an iPhone or iPad simulator, then Run. Debug is intentionally unsigned and uses `com.foresight.journal.testing`; Release is `Foresight` with `com.foresight.journal`.

For a command-line build, unit/UI test pass, install, and launch on the newest available iPhone simulator:

```sh
./Scripts/verify.sh
```

Use the launch argument `-in-memory-store` for isolated UI tests or disposable sessions. First-run onboarding shows once; pass `-reset-onboarding` to see it again, or `-hasCompletedOnboarding YES` to skip it.

## Run on your iPhone

Device signing is prepared in `Config/Signing.xcconfig` but switched off until a local team is set. To turn it on:

1. Your iPhone must run iOS 26 or later. Turn on Developer Mode (Settings > Privacy & Security > Developer Mode) and connect it to the Mac.
2. In Xcode > Settings > Accounts, sign in with your Apple ID. A free account works, but its installs expire after 7 days; TestFlight needs the paid Apple Developer Program.
3. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set `DEVELOPMENT_TEAM` to your team ID (Xcode shows it under the account's team). That file is gitignored, so the team ID stays out of the repo. If Xcode reports that `com.foresight.journal.testing` is already in use, set `BUNDLE_ID_PREFIX` there to something unique, such as `com.<yourname>`, and update the bundle ID in `Scripts/verify.sh`. For a one-off command-line build you can pass `DEVELOPMENT_TEAM=<id> CODE_SIGNING_ALLOWED=YES` to `xcodebuild` instead.
4. Run `xcodegen generate --spec project.yml`, select the Foresight QA scheme and your iPhone, and Run. The first time, trust the developer profile on the phone under Settings > General > VPN & Device Management.

Installing a newer build over the old one keeps the journal. Deleting the app deletes it.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs `Scripts/verify.sh` on every pull request and push to `main`, on a `macos-26` runner with Xcode 26.6 and an iOS 26.5 simulator. It builds the Foresight QA scheme and runs the unit and UI tests; failed runs upload the `.xcresult` bundle. CI uses Xcode 26, so app code must stick to iOS 26 SDK APIs even when building locally with Xcode 27.

## Architecture

- `ForesightApp/Models.swift` contains SwiftData entities: `JournalEntry`, `JournalCategory`, and `OutcomeCheckIn`, with UUID identities, typed states, relationships, and cascading entry deletion.
- `ForesightApp/ForesightSchema.swift` versions the store with a SwiftData `VersionedSchema` and `ForesightMigrationPlan`, so a journal on a phone survives new builds. Read the notes at the top of that file before adding or changing a stored property.
- `ForesightApp/JournalStore.swift` is the `@MainActor @Observable` dependency-injected mutation store. It validates text, category, scheduling, response, fixture, archive, and deletion rules.
- Saving a new log turns the editor into a short check-in step (`PostLogCheckInView.swift`): rate how you feel right now and pick a one-tap later time. `CheckInFlow.swift` holds the pure rules for those times and for the Check In tab's due badge. `OnboardingView.swift` is the first-run walkthrough.
- `JournalAnalytics.swift` and `OutcomeAnalytics.swift` are deterministic pure functions for discovery, queues, date/calendar grouping, activity trends, outcome aggregation, and non-causal insights.
- The app uses native `TabView`, separate `NavigationStack`s, full-screen writing, native sheets for response/scheduling, Swift Charts, Dynamic Type-aware controls, system serif display type, SF Symbols, haptics, and system Liquid Glass navigation/tab/sheet surfaces.

If SwiftData cannot initialize, the app offers retry and an explicit local reset. There are deliberately no notifications, accounts, AI, sync, Android support, or App Store submission workflow.

## Parity checklist

- [x] Journal: create, edit, delete, event date/time, categories, search, check-in filters, 30-day default/all/custom ranges, timeline, calendar, older-log reveal, empty states, and log navigation.
- [x] Check In: due/upcoming/recent filters, overdue ordering, early answers, later today/tomorrow/custom scheduling, reschedule, skip, editable responses, notes, exclusions, source-log navigation, and Debug fixture controls.
- [x] Patterns: activity/outcome views, weekly/monthly comparisons, 8-week/6-month charts, category drill-down, 30/90-day outcome windows, phase selection, ranked insights, evidence thresholds, distributions, timing shifts, recent changes, and source-log links.
- [x] Domain constraints: five-thousand-character limits, unique category names, archived-category history, one immediate and one pending delayed check-in, skip/reschedule/cascade delete behavior, and deterministic five-response/60%/Early–Building–Established insight rules.
- [x] Verification: Swift Testing behavior coverage and XCUITest smoke flows for primary app journeys.

## Project files

`project.yml` is the reproducible XcodeGen specification. `Foresight.xcodeproj` is generated from it and committed so the project opens directly in Xcode. Regenerate both whenever build settings, targets, or file membership change.
