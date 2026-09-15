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

Use the launch argument `-in-memory-store` for isolated UI tests or disposable sessions.

## Architecture

- `ForesightApp/Models.swift` contains SwiftData entities: `JournalEntry`, `JournalCategory`, and `OutcomeCheckIn`, with UUID identities, typed states, relationships, and cascading entry deletion.
- `ForesightApp/JournalStore.swift` is the `@MainActor @Observable` dependency-injected mutation store. It validates text, category, scheduling, response, fixture, archive, and deletion rules.
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
