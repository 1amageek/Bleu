# Repository Guidelines

## Project Structure & Module Organization
Bleu ships as a Swift Package (`Package.swift`). Core sources live under `Sources/Bleu`, grouped by responsibility: `Actors` for distributed entry points, `Core` for system orchestration, `LocalActors` wrapping CoreBluetooth, `Mapping` for service metadata, `Transport` for packet routing, and `Extensions`/`Utils` for shared helpers. The CLI sample lives in `Sources/BleuDemo/main.swift`. The `Examples` workspace is its own package with executable targets (`SensorServer`, `SensorClient`, `BleuExampleApp`) that exercise end-to-end BLE flows. Tests sit in `Tests/BleuTests`, and companion docs (`SPECIFICATION.md`, `API_REFERENCE.md`, `MIGRATION.md`) track protocol details that should evolve with code.

## Build, Test, and Development Commands
- `swift build` — compiles the Bleu library and demo target in debug mode.
- `swift test` — runs the Swift Testing suites in `Tests/BleuTests`.
- `swift run BleuDemo` — spins up the demo executable for manual actor experiments.
- `swift run --package-path Examples SensorServer` / `SensorClient` — launches paired examples against a local build for integration smoke tests.
- `swift test --filter ServiceMetadataTests` — targets a specific suite when iterating.

## Coding Style & Naming Conventions
Follow Swift API Design Guidelines with four-space indentation and trailing commas for multi-line literals. Keep imports grouped by framework and ordered from Foundation to project modules. Types use `PascalCase`, methods and variables prefer `camelCase`, and async distributed APIs should read like verbs (`startAdvertising`, `discover`). When introducing new folders or targets, mirror the domain-based layout in `Sources/Bleu` and update `Package.swift` plus `Examples/Package.swift`.

## Testing Guidelines
All tests use the Swift `Testing` module; prefer `@Suite` containers that align with the namespace you cover and expressive `@Test` names (`@Test("Characteristic permissions")`). New functionality should ship with unit coverage plus an integration exercise when RPC or transport behavior changes. For BLE handshake or serialization adjustments, pair tests with an `Examples` scenario so reviewers can reproduce via the example runners. Run `swift test` before every push and sync results from macOS and iOS simulator runs.

## Commit & Pull Request Guidelines
Write commit subjects in the imperative mood and keep them under ~72 characters. Scoped prefixes such as `feat:`, `fix:`, or `docs:` help triage, as seen in recent history. Each PR should describe the behavior change, list validation steps (`swift test`, example runs), reference any issues or specs touched, and include logs or screenshots when GUI or peripheral behavior changes. Draft PRs are welcome for discussion; convert to ready-for-review once tests are green.
