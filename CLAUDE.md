# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Cashew is a cross-platform budget & finance tracker built with **Flutter**. It runs on Android, iOS, and Web (PWA). Data is stored locally in a **Drift (SQLite)** database and optionally synced/backed up through **Google Drive + Firebase**. The published name "Cashew" maps to the package name `budget` internally.

**The Flutter project lives in the `budget/` subdirectory, not the repo root.** Always `cd budget` before running Flutter/Dart commands.

## Commands

All commands run from inside `budget/`:

```bash
flutter pub get                 # install dependencies
flutter run                     # run on a connected device/emulator
flutter analyze                 # static analysis / lint (uses flutter_lints)
flutter test                    # run tests (only test/widget_test.dart exists)
flutter test test/widget_test.dart   # run a single test file

# Code generation (Drift database) — required after editing database/tables.dart
dart run build_runner build               # one-off
dart run build_runner watch               # continuous

# Release builds
flutter build appbundle --release   # Android (requires Android SDK)
flutter build ipa                   # iOS (requires macOS)
firebase deploy                     # deploy web build to Firebase

# App icons
flutter pub run flutter_launcher_icons:main
```

Windows convenience scripts live in `scripts/`: `deploy_and_build_windows.bat`, `open_release_builds.bat`, `update_translations.bat`.

## Database & Migrations (Drift)

The entire data layer is in `budget/lib/database/`:
- `tables.dart` — **the single most important file** (~300KB). Defines all table schemas, enums, the `FinanceDatabase` class (`@DriftDatabase`), the `MigrationStrategy`, AND all ~250 query methods. New queries go here as methods on `FinanceDatabase`.
- `tables.g.dart` — generated; never edit by hand. Regenerate with `build_runner`.
- `schema_versions.dart` — generated migration steps.
- `drift_schemas/` (repo root of `budget/`) — exported JSON schema snapshots, one per version.

Core tables: `Wallets`, `Transactions`, `Categories`, `CategoryBudgetLimits`, `AssociatedTitles`, `Budgets`, `AppSettings`, `ScannerTemplates`, `DeleteLogs`, `Objectives`. Primary keys are UUID strings (`text().clientDefault(() => uuid.v4())`), and cross-references use `Fk` suffix columns — this UUID-based design is what makes multi-device sync possible.

**To migrate the schema** (from README Developer Notes):
1. Edit tables/schema in `tables.dart`.
2. Bump `int schemaVersionGlobal = N;` near the top of `tables.dart`.
3. From `budget/`: `dart run build_runner build`
4. Export schema: `dart run drift_dev schema dump lib/database/tables.dart drift_schemas/drift_schema_v[N].json`
5. Generate steps: `dart run drift_dev schema steps drift_schemas/ lib/database/schema_versions.dart`
6. Add the migration case inside the `stepByStep`/`onUpgrade` strategy in `tables.dart`.

The global `database` instance is in `struct/databaseGlobal.dart`. The actual connection is opened per-platform via `constructDb()` in `database/platform/` (conditional export: `native.dart` for mobile/desktop, `web.dart` for web, `unsupported.dart` fallback).

## Architecture & State Management

The app **does not use a single state-management framework**. Instead it relies on three patterns:

1. **Global mutable settings** — `struct/settings.dart` holds `Map<String, dynamic> appStateSettings` (persisted to `SharedPreferences` as JSON). Read settings directly from this map; write with `updateSettings(key, value, updateGlobalState: ...)`. Defaults are in `struct/defaultPreferences.dart`. `getSettingConstants()` converts raw stored values (theme strings, hex colors) into typed objects.

2. **GlobalKeys for imperative refresh** — pages expose state via global keys (e.g. `homePageStateKey`, `transactionsListPageStateKey`, `appStateKey`, `pageNavigationFrameworkKey`). `updateSettings(...)` refreshes specific pages via the `pagesNeedingRefresh` list (page indices 0=home, 1=transactions, 2=budgets, 3=settings) or the whole app via `appStateKey.currentState?.refreshAppState()`. When changing settings, choose the narrowest refresh scope.

3. **Drift `.watch()` streams + StreamBuilder** — live data binds reactively to the database. `struct/listenableSelector.dart` provides a `.select()` extension to derive filtered `ValueListenable`s from a `Listenable`.

`main.dart` is the entry point: it initializes Firebase, EasyLocalization, SharedPreferences, the database, notifications, currency/language JSON, settings, and timezones before `runApp`. The widget tree is wrapped `InitializeLocalizations > RestartApp > InitializeApp > App (MaterialApp)`. `RestartApp` (`widgets/restartApp.dart`) lets the whole app be rebuilt from scratch.

## Navigation

- `widgets/navigationFramework.dart` — `PageNavigationFramework` holds the main `pages`/`pagesExtended` lists and the FAB. Bottom-nav/sidebar index drives a `FadeIndexedStack`.
- `widgets/navigationSidebar.dart` — wide-screen sidebar (responsive layout switches between bottom nav and sidebar).
- **Always navigate with `pushRoute(context, page)`** from `functions.dart` — it handles platform-correct `PageRouteBuilder` transitions. Use `maybePopRoute(context)` to pop.
- Reusable page/popup shells: `widgets/framework/pageFramework.dart` (scaffold with sliver app bar) and `widgets/framework/popupFramework.dart`. Bottom sheets open via `widgets/openBottomSheet.dart` / `widgets/openPopup.dart` / `widgets/openSnackbar.dart`.

## Sync & Backup

`struct/syncClient.dart` implements multi-device sync over Google Drive. Key idea: every create/update is timestamped and every delete is recorded in the `DeleteLogs` table. `syncData()` exchanges a separate `syncdb` database, replays delete logs, and merges by most-recent timestamp. Auth/global Firebase user state is in `struct/firebaseAuthGlobal.dart`. CSV/DB import-export lives in `widgets/importCSV.dart`, `widgets/exportCSV.dart`, `widgets/importDB.dart`, `widgets/exportDB.dart`, and `widgets/accountAndBackup.dart`.

## Directory Map (`budget/lib/`)

- `pages/` — full-screen pages (one file per page; `homePage/` has the dashboard widgets).
- `widgets/` — reusable UI (~115 files). `widgets/framework/` = page/nav/popup shells; `widgets/transactionEntry/` = transaction row rendering; `widgets/util/` = layout/scroll/platform helpers.
- `struct/` — non-UI app infrastructure: settings, sync, currency, icons, notifications, biometrics, logging, default data.
- `database/` — Drift schema, queries, migrations, platform DB construction, preview/demo data generation (`generatePreviewData.dart`).
- `functions.dart` — global utility functions (money/date formatting, `getPlatform()`, `pushRoute()`, clipboard, device info). Large grab-bag; check here before writing a new helper.
- `colors.dart` — `getLightTheme()`/`getDarkTheme()`, `ColorScheme` extensions, `HexColor`, `dynamicPastel()` for Material You theming.
- `modified/` — locally patched third-party code.

`budget/packages/` contains bundled, modified forks of the discontinued `sliding_sheet` and `implicitly_animated_reorderable_list` packages (referenced via `path:` in `pubspec.yaml`).

## Project-Specific Conventions

- **`getPlatform()` from `functions.dart`** — never use `dart:io` `Platform` directly (it breaks on web). This wrapper is the only safe way to branch on platform.
- **Naming mismatch (front-end vs. code):** `Wallet` in code = "Account" in UI. `Objective` in code = "Goal" in UI. Don't rename internals.
- **Long-term loans** are modeled as `Objectives`: the goal total is *not* used; remaining balance is computed by summing opposite-polarity transactions (e.g. a $100 loan lent = a -$100 expense; repayments are +income, and remaining = the difference).
- **Translations:** strings use `easy_localization` (`.tr()`). Source of truth is `assets/translations/translations.csv`; regenerate JSON with `python assets/translations/generate-translations.py`, then restart the app.
- **Debug flags:** gated by `allowDebugFlags` / `allowDangerousDebugFlags` in `main.dart`; the debug surface is `pages/debugPage.dart`.

## Constraints

- Per the README, the maintainer is **not accepting external contributions / PRs** for licensing reasons. Treat this repo as a private app codebase: extend and modify in place rather than proposing upstream-style contributions.
