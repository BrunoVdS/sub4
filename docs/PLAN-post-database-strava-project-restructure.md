# SUB4 post-database and post-Strava project restructuring plan

| | |
|---|---|
| **Status** | Proposed - validate before execution |
| **Date** | 9 August 2026 |
| **Owner and decider** | Bruno |
| **Scope** | Source organization, dependency boundaries, composition, tests and documentation; followed by a separately gated product roadmap |
| **Starts after** | Database cutover and Strava-to-Apple-Health transition are complete and stable |
| **Primary objective** | Make the project easy to extend without changing product behavior |

Implementation companion: `docs/PLAN-codebase-modernization-and-feature-delivery.md` turns
the prerequisites, R0-R15 restructure and post-restructure roadmap into daily engineering
slices from the current patch-332 baseline.

## 1. Executive decision

SUB4 will be reorganized after the database and Strava work is finished, verified on the
device and stable. The restructuring will not use the PDF's proposed
`Core/Models/Stores/Services/Utilities` tree literally. That structure is a useful sketch,
but it is too generic for the application SUB4 has become.

The project will instead be organized around six explicit responsibilities:

1. **App** - application startup, composition and navigation.
2. **Domain** - source-neutral training concepts and calculations.
3. **Data** - SQLite persistence, repositories, ingestion and backup/restore.
4. **Features** - user-facing screens and feature-specific presentation state.
5. **DesignSystem** - reusable visual language and UI components.
6. **Platform** - Apple operating-system capabilities such as background work, Keychain,
   privacy, file protection and sharing.

The first implementation will keep one application target. Folder boundaries will be
made real through dependency rules and architecture tests. A separate pure Swift domain
module may be extracted later, but the restructure will not begin by creating a collection
of frameworks or packages.

The restructure is a staged migration, not a rewrite. Mechanical moves and behavioral
changes must never share a patch.

## 2. Why this happens after the database and Strava phase

The persistence and source migrations change which code survives:

- D7 changes production reads from legacy files to SQLite.
- D8 retires runtime JSON readers and writers after the approved stability period.
- Phase 4A makes Apple Health canonical and removes Strava networking, authentication and
  Strava-specific background work.
- Disconnect, export, restore, backup and deletion behavior change with those decisions.

Restructuring before those exit gates would move code that is already scheduled for
deletion, mix migration failures with path changes and create large diffs across the most
sensitive work in the project.

The required sequence is therefore:

1. Complete and activate D7.
2. Complete the approved database stability window.
3. Complete HealthKit ingestion, reconciliation and canonical-source activation.
4. Complete Strava revocation, purge and retirement.
5. Complete D8 legacy-persistence retirement, including the supported upgrade path.
6. Verify backup, export, restore, deletion and a clean launch on the phone.
7. Freeze a post-migration baseline.
8. Start this restructuring plan.

This sequence supersedes the earlier tentative idea of restructuring immediately after D7
alone.

## 3. Entry gate

This plan may start only when every item below has evidence.

### 3.1 Database gate

- [ ] Production reads use SQLite for every durable training-data category.
- [ ] `Sub4Launch.migrationFailureBlocksTheApp` has its final database-authoritative
      behavior.
- [ ] A failed database open cannot produce an apparently valid empty history.
- [ ] The latest activation run is represented correctly in the migration ledger.
- [ ] Runtime JSON stores are retired or retained only as a documented, version-bounded
      upgrade path.
- [ ] The app works when retired JSON inputs are absent from their former runtime paths.
- [ ] Export, restore, disconnect and delete-local-data behavior match the database source
      of truth.
- [ ] A fresh protected backup exists and has been verified as readable.

### 3.2 Apple Health and Strava gate

- [ ] Apple Health is the canonical source for completed sessions.
- [ ] Health activity identities are canonical and provider-neutral inside the database.
- [ ] HealthKit route, quantity and workout-event ingestion has passed its device checks.
- [ ] The three accepted historical coverage gaps and degraded summary-only records are
      documented in their final disposition.
- [ ] Strava OAuth has been revoked and credentials/tokens removed according to ADR-0002.
- [ ] Strava networking and source-specific background tasks have been removed.
- [ ] Strava-derived rows have been reconciled, remapped or purged according to lineage.
- [ ] AI review and weather sharing operate only on permitted lineage.
- [ ] No active Swift source imports or calls a Strava client.

### 3.3 Quality gate

- [ ] The full local test suite passes.
- [ ] The Release configuration builds through `./scripts/preflight.sh`.
- [ ] A real-device smoke campaign passes.
- [ ] The Git worktree is clean.
- [ ] The post-migration state has a named tag or equivalent immutable recovery point.
- [ ] The repository is pushed or otherwise backed up in accordance with the project's
      working agreement.
- [ ] The current app version and patch label on the device match the source baseline.

If any gate is not satisfied, this restructure does not start. A folder move is not a way
to make incomplete migration work feel finished.

## 4. Goals

The restructure must make the following easier:

- Adding a new feature without searching the whole target for its persistence and UI.
- Adding or changing a data source without changing domain calculations.
- Testing training logic without constructing SwiftUI views or opening a database.
- Replacing a repository implementation without rewriting screens.
- Building future Watch, widget, iPad or Mac surfaces over the same domain rules.
- Finding the owner of a behavior from the file path.
- Removing an integration without leaving source-specific assumptions scattered behind.
- Enforcing actor, persistence and privacy boundaries in review and tests.
- Keeping diagnostic/developer tooling distinct from athlete-facing settings.

## 5. Non-goals

This plan does not authorize:

- A visual redesign.
- New athlete features.
- A new training-load model.
- Schema redesign unrelated to a defect found during the move.
- Cloud sync, accounts or multi-user support.
- A switch from GRDB to another persistence framework.
- A blanket MVVM rewrite.
- Replacing every singleton in one change.
- Creating a framework or package for every folder.
- Renaming domain language merely to make filenames look uniform.
- Reformatting all Swift source in the same changes as moves.
- Deleting historical ADRs or rewriting migration history.

Findings discovered during restructuring are recorded separately. Only a defect that blocks
the restructure is fixed in the same phase, and its change must have its own patch and
verification.

## 6. Architectural principles

### 6.1 Organize by responsibility, not by suffix

A `Services` folder does not state what a service owns. A `Utilities` folder does not state
why code belongs there. Those names are prohibited as top-level catch-alls.

Each file must answer two questions from its path:

1. Which part of the product owns this behavior?
2. Which architectural layer is allowed to depend on it?

### 6.2 The domain is source-neutral

Training concepts do not know whether a workout came from HealthKit, an import or a future
source. Domain types use canonical identifiers and source-neutral vocabulary. Provider DTOs,
database rows and API response shapes do not leak into domain APIs.

### 6.3 Features do not own persistence

A SwiftUI screen may ask a repository or feature model for data. It may not construct SQL,
decode disk files, operate a `DatabaseQueue`, call `UserDefaults` for training state or
assemble network requests.

### 6.4 The app target remains the composition root

The app creates concrete repositories and platform clients and supplies them to features.
This is the one place where the dependency graph is intentionally visible.

### 6.5 Dependency injection is introduced at seams, not everywhere

A protocol is justified when:

- more than one implementation exists or is planned;
- a feature must be tested without an external system;
- a platform boundary must be isolated; or
- the current global dependency has caused lifecycle or concurrency defects.

A protocol with one implementation, one caller and no test seam is not automatically an
improvement.

### 6.6 Folders first, modules later

The initial restructure uses physical folders inside the synchronized Xcode source tree.
This limits project-file churn and allows small reversible batches. Compile-time module
boundaries are considered only after the folder architecture is stable.

### 6.7 Behavior-neutral means behavior-neutral

A mechanical move does not also:

- change an access level;
- rename a type;
- replace a singleton;
- add an actor;
- change a repository interface;
- edit SQL;
- change resource lookup;
- rewrite tests; or
- fix an unrelated warning.

Those may all be worthwhile. They are separate changes because they require different proof.

## 7. Target source tree

The exact leaf folders may be adjusted during the R1 inventory, but the six top-level
responsibilities and dependency direction are the decision.

```text
Sub4/
├── App/
│   ├── Launch/
│   ├── Composition/
│   └── Navigation/
│
├── Domain/
│   ├── Activity/
│   ├── Athlete/
│   ├── TrainingPlan/
│   ├── Matching/
│   ├── TrainingLoad/
│   ├── Review/
│   ├── Weather/
│   └── Shared/
│
├── Data/
│   ├── Database/
│   │   ├── Schema/
│   │   ├── Migrations/
│   │   ├── Repositories/
│   │   ├── Import/
│   │   ├── Verification/
│   │   └── Maintenance/
│   ├── Sources/
│   │   ├── HealthKit/
│   │   └── Weather/
│   ├── Backup/
│   ├── Export/
│   └── Upgrade/
│       └── LegacyJSON/       # only while a supported upgrade path needs it
│
├── Features/
│   ├── Today/
│   ├── Week/
│   ├── Plan/
│   ├── Progress/
│   ├── Activities/
│   ├── ActivityDetail/
│   ├── Review/
│   ├── Workout/
│   ├── Settings/
│   ├── DataManagement/
│   └── Diagnostics/
│
├── DesignSystem/
│   ├── Theme/
│   ├── Components/
│   ├── Charts/
│   └── Formatting/
│
├── Platform/
│   ├── BackgroundTasks/
│   ├── Security/
│   ├── Privacy/
│   ├── Preferences/
│   ├── FileSystem/
│   ├── Sharing/
│   └── DeviceCapabilities/
│
└── Resources/
    ├── Assets.xcassets/
    ├── plan.json
    ├── manual.html
    ├── PrivacyInfo.xcprivacy
    ├── Info.plist
    └── Sub4.entitlements
```

Repository-level material stays outside the application source folder:

```text
docs/
├── ADR-*.md
├── context/
├── plans/
└── history/

scripts/
tools/
.github/workflows/
```

Moving existing documentation into `plans/` or `history/` is optional and must not break the
rule that ADR-0003 remains authoritative for database history. Historical documents are
never rewritten to look current.

## 8. Dependency rules

### 8.1 Allowed direction

```text
Features ───────► Domain
    │               ▲
    │               │
    └────► DesignSystem

Data ───────────► Domain
Platform ───────► Domain only where a domain protocol requires it

App ────────────► Features + Data + Platform + DesignSystem
```

The arrows mean "may depend on." They do not imply that every dependency should exist.

### 8.2 Domain rules

Domain code may import Foundation when required. It may not import:

- SwiftUI
- UIKit
- GRDB
- HealthKit
- WeatherKit
- MapKit
- CoreLocation

Domain models must not contain database column names, SQL fragments, HealthKit identifiers
or provider DTOs. Source lineage may be represented as a domain concept where product logic
needs it, but not as a provider implementation detail.

### 8.3 Data rules

Data code may depend on Domain and on persistence/source frameworks. It must:

- return domain models or explicit load outcomes;
- preserve the distinction between absent data, refused data and failed reads;
- keep canonical identifiers internal to persistence joins;
- keep migration history immutable;
- make provider-to-domain conversion explicit;
- keep backup/export formats distinct from the runtime database model; and
- avoid importing SwiftUI.

### 8.4 Feature rules

Feature code may import SwiftUI, Domain and DesignSystem. A feature may use a repository
interface supplied by the app environment. It may not:

- import GRDB;
- issue SQL;
- import HealthKit or WeatherKit;
- read or write the filesystem directly;
- read training state from UserDefaults;
- create network sessions; or
- reach into another feature's internal view state.

Cross-feature rules belong in Domain. Reusable visual code belongs in DesignSystem.

### 8.5 Platform rules

Platform owns operating-system mechanics, not training decisions. Examples:

- Keychain and file protection;
- background task registration;
- local preference storage;
- share sheets and document handoff;
- privacy declarations and consent plumbing; and
- device capability checks.

Platform code may implement a domain or app-facing interface. It must not decide how a
training session is matched or how load is calculated.

### 8.6 App rules

App contains:

- `Sub4App` and root scene construction;
- launch state;
- environment/composition objects;
- top-level navigation; and
- configuration selecting concrete implementations.

App does not become a second `Utilities` folder. Business rules found there move to Domain;
integration mechanics move to Data or Platform.

## 9. Concurrency ownership

The restructure must document, not casually rewrite, concurrency boundaries.

- SwiftUI views and presentation state remain `@MainActor`.
- Domain value types should be `Sendable` where their contents allow it.
- Database and ingestion work stays off the main actor.
- One owner coordinates each mutable external integration.
- A repository returning a value across actors must return a `Sendable` domain value or an
  explicit sendable result.
- `nonisolated` changes are not bundled into file moves.
- Extensions are checked separately because a type's isolation does not automatically apply
  to extensions declared elsewhere.

The R1 inventory records the current owner and intended owner of every mutable singleton.
Singleton replacement occurs only in R9, after physical moves are complete.

## 10. Naming rules

- Domain names describe product concepts: `Activity`, `TrainingPlan`, `MatchDecision`.
- Provider response types end in `DTO` or another explicit provider shape.
- Database-only record types end in `Record` or `Row` only when they genuinely differ from
  the domain model.
- Repository interfaces describe what the app asks, not how SQLite answers.
- Implementation names may include the technology when multiple implementations matter,
  for example `GRDBActivityRepository`.
- Feature presentation types use `View`, `ViewModel`, `State` or `Model` according to their
  real role. The restructure does not create a view model for every screen by convention.
- `Manager`, `Service`, `Helper` and `Utility` require a more precise alternative before a
  new file is accepted.

Existing names remain during mechanical moves. Renaming is a later, reviewed step.

## 11. Test organization

The test filesystem will mirror the source architecture:

```text
Sub4CoreTests/
├── Domain/
│   ├── Activity/
│   ├── Matching/
│   ├── TrainingLoad/
│   ├── TrainingPlan/
│   └── Review/
├── Data/
│   ├── Database/
│   ├── Repositories/
│   ├── Sources/
│   ├── Backup/
│   └── Upgrade/
├── Features/
├── Platform/
├── Architecture/
└── Fixtures/
```

The test target name is a separate decision. Today `Sub4CoreTests` imports the app target.
After the restructure:

- rename it to `Sub4Tests` if there is still only one production module; or
- keep/create `Sub4DomainTests` only if a real `Sub4Domain` module is extracted.

A target must not be called "Core" merely because its tests are important.

## 12. Architecture enforcement tests

Folder boundaries in one target are conventions unless checked. Add lightweight source-tree
tests or a repository script covering at least:

- [ ] No `import SwiftUI`, `UIKit`, `GRDB`, `HealthKit`, `WeatherKit`, `MapKit` or
      `CoreLocation` under `Domain/`.
- [ ] No `import GRDB`, `HealthKit` or `WeatherKit` under `Features/`.
- [ ] SQL construction appears only under `Data/Database/` and test fixtures.
- [ ] HealthKit symbols appear only under `Data/Sources/HealthKit/`, Platform capability
      checks and tests.
- [ ] Direct Keychain access appears only under `Platform/Security/`.
- [ ] New direct `UserDefaults.standard` uses appear only under
      `Platform/Preferences/` or a documented migration path.
- [ ] New direct filesystem writes appear only under Data backup/export/upgrade or Platform
      filesystem code.
- [ ] No active Strava imports, endpoints, OAuth types or release-gate cases remain.
- [ ] No new top-level `Services`, `Helpers` or `Utilities` folder appears.
- [ ] Every production Swift file belongs to one approved top-level folder.
- [ ] Resources expected in the bundle are read back from the built product by tests.

Architecture checks fail with the exact offending path and import/symbol. A bare count is not
enough evidence.

## 13. Work plan

Each stage below ends in its own commit or small series of commits. A stage is not complete
until its exit gate passes.

### R0 - Accept the architecture decision

**Purpose:** agree on the destination before touching paths.

Work:

1. Review and accept or amend this document.
2. Record the decision in a short ADR or mark this plan accepted and link it from the project
   documentation index.
3. Confirm the six top-level responsibilities.
4. Confirm that folders come before modules.
5. Confirm that the work begins only after the entry gate in section 3.
6. Decide whether the test target will eventually be renamed.

Exit gate:

- [ ] Bruno has approved the target architecture and sequencing.
- [ ] Open decisions are resolved or explicitly deferred with an owner.

### R1 - Freeze and inventory the post-migration codebase

**Purpose:** map the code that actually survived the database and Strava work rather than
restructuring today's transitional files from memory.

Work:

1. Record the baseline commit, app patch, Swift file count and line count.
2. Run the full tests and preflight.
3. Capture a real-device smoke result.
4. Generate a complete list of production and test files.
5. For every production file, record:
   - current path;
   - declared types;
   - current responsibility;
   - dependencies/imports;
   - mutable state owner;
   - target folder;
   - move, split, rename, retain or delete;
   - device-only verification requirement.
6. Identify files with more than one architectural responsibility.
7. Identify all `.shared` instances and global stores.
8. Search for direct GRDB, HealthKit, WeatherKit, UserDefaults, Keychain, FileManager and
   URLSession use.
9. Search for every string-based resource lookup and every build-setting path.
10. Produce the final move manifest used by R3-R8.

The manifest is evidence, not a wish list. It is checked against the declarations inside
each file, not inferred from filenames.

Exit gate:

- [ ] Every source and test file has a disposition.
- [ ] Every mixed-responsibility file is named.
- [ ] No file is scheduled both for deletion and movement.
- [ ] The baseline is recoverable.

### R2 - Install the structural safety net

**Purpose:** make dependency drift visible before the first move.

Work:

1. Add the architecture checks from section 12 in a mode that understands the current flat
   tree and the target tree.
2. Initially report existing exceptions explicitly rather than suppressing whole folders.
3. Add resource-presence tests for `plan.json`, `manual.html`, the privacy manifest and any
   other bundle resource that will move.
4. Add or confirm launch tests for Info.plist keys and entitlements that can hard-crash.
5. Add a script/check that fails when a production Swift file remains at the source root
   after the final move stage.
6. Record the expected exceptions and the stage that removes each one.

Exit gate:

- [ ] The checks pass on the baseline with only named transitional exceptions.
- [ ] Deliberately introducing one forbidden import makes the check fail with its path.
- [ ] Removing one required resource makes its test fail.

### R3 - Create the physical tree

**Purpose:** create destinations without changing compilation or behavior.

Work:

1. Create the approved top-level folders under `Sub4/` and `Sub4CoreTests/`.
2. Add a short `README.md` only where a boundary needs local rules; do not add decorative
   readmes to every folder.
3. Confirm Xcode's synchronized folders see nested Swift files automatically.
4. Confirm no file is added through Xcode's **Add Files** command.
5. Confirm no duplicate file references appear in the project.
6. Keep resources and build-setting files in place until R10; creating `Resources/` does
   not authorize moving them early.

Exit gate:

- [ ] Debug and Release still build.
- [ ] No source file has moved yet.
- [ ] The Xcode project contains no duplicated references.

### R4 - Move DesignSystem and leaf UI components

**Purpose:** begin with code that has a narrow dependency surface.

Expected candidates, subject to the R1 manifest:

- theme and appearance;
- chart chrome, scales, swatches and toggles;
- reusable cards, informational notes and formatting helpers;
- visual-only route, split and volume components that contain no domain decisions.

Work:

1. Move one coherent component group at a time.
2. Do not rename types or alter access levels.
3. Keep feature-specific components with their feature rather than forcing every reusable-
   looking view into DesignSystem.
4. Run tests after each batch.
5. Open Today, Week, Plan, Progress and an activity detail on the phone after the final batch.

Exit gate:

- [ ] No DesignSystem file imports Data or Platform implementation code.
- [ ] Visual smoke checks show no changed layout or chart behavior.

### R5 - Move pure Domain code

**Purpose:** make source-neutral business logic visible and testable.

Expected areas:

- canonical activity and detail value types;
- training plan and workout value types;
- matching and session tally rules;
- day grouping and zone calculations;
- load, PMC, monotony, volume and pace calculations;
- review scheduling, evidence and proposal validation rules;
- source-neutral weather values;
- shared day-key, units and time representations.

Work:

1. Move files already pure without editing their contents.
2. Leave mixed files in place and list them for R9.
3. Move their tests into the mirrored Domain test folders.
4. Turn on the Domain import restrictions for each completed subfolder.
5. Verify that every derived figure still calls the single existing implementation rather
   than gaining a folder-specific copy.

Exit gate:

- [ ] Domain folders pass their forbidden-import checks.
- [ ] Matching, plan, load and review tests pass unchanged.
- [ ] No provider or database type appears in a Domain API.

### R6 - Move database implementation

**Purpose:** give persistence one explicit home without rewriting its behavior.

Move as distinct batches:

1. Database opening and configuration.
2. Frozen migrations.
3. Repository implementations.
4. Import/upgrade code that still exists after D8.
5. Semantic verification and database maintenance.
6. Benchmarks and database-specific diagnostics models.

Rules:

- Migration identifiers and bodies do not change because a file moved.
- Migrations remain separate dated history, not consolidated into a new initial schema.
- Repository methods and load outcomes do not change in this stage.
- SQL does not move into Domain or Features.
- Any legacy JSON upgrade reader is isolated under `Data/Upgrade/LegacyJSON` and carries an
  explicit removal condition tied to the minimum supported upgrade path.

Exit gate:

- [ ] A fresh in-memory database migrates from zero.
- [ ] An existing fixture migrates through the complete historical chain.
- [ ] Repository and semantic-verifier tests pass.
- [ ] The database benchmark stays inside its accepted budgets.
- [ ] The phone opens the existing database without creating a second database file.

### R7 - Move external data sources

**Purpose:** isolate Apple and provider APIs from the rest of the product.

Expected destinations:

- HealthKit authorization, queries, workout adaptation and reconciliation under
  `Data/Sources/HealthKit/`;
- WeatherKit/Open-Meteo clients and provider conversion under `Data/Sources/Weather/`;
- device capability checks under Platform where they answer availability rather than fetch
  training data.

Work:

1. Separate provider DTOs/adapters from canonical domain models where they still share a
   file.
2. Keep ingestion orchestration in Data, not in a SwiftUI view.
3. Confirm the post-Strava tree contains no active Strava source directory.
4. Confirm network-bound release gates and consent checks remain at the request boundary.
5. Keep provider attribution with the feature/design component that renders it, while the
   provider result carries the provenance needed to select that attribution.

Exit gate:

- [ ] Domain and Features contain no HealthKit or WeatherKit imports.
- [ ] Health history, routes, quantities and reconciliation pass their device checks.
- [ ] Weather consent and attribution remain correct.
- [ ] An exhaustive search finds no active Strava endpoint or OAuth implementation.

### R8 - Move Platform services

**Purpose:** isolate operating-system mechanics that are neither product domain nor data
source behavior.

Expected areas:

- background task registration and scheduling;
- Keychain and credential storage;
- file protection and filesystem locations;
- UserDefaults-backed reader preferences;
- privacy manifest support and consent records;
- share sheet and document handoff;
- device/build capability and app-version information.

Work:

1. Move existing wrappers mechanically.
2. Identify direct OS API calls outside Platform/Data that need later extraction.
3. Do not turn every one-line API call into a protocol.
4. Centralize new preference keys without silently migrating or deleting existing keys.
5. Keep training data out of UserDefaults.

Exit gate:

- [ ] Privacy, lifecycle, file-protection and preference tests pass.
- [ ] Background refresh is registered and produces a checked result on the phone.
- [ ] Release-gate behavior is unchanged.

### R9 - Move Features

**Purpose:** make every athlete-facing workflow an identifiable vertical slice.

Each feature folder may contain:

- its root view;
- feature-specific subviews;
- a presentation model when the feature genuinely needs one;
- feature-specific formatting and navigation state; and
- tests of feature orchestration that do not belong to Domain.

Work in athlete navigation order:

1. Today.
2. Week.
3. Plan.
4. Progress.
5. Activities and Activity Detail.
6. Review.
7. Workout preparation, warm-up and fuel.
8. Settings and Data Management.
9. Diagnostics/developer tools.

Rules:

- Shared business rules do not move into the first feature that uses them.
- A feature does not import another feature's internal type.
- Athlete-facing Settings remains separate from engineering diagnostics.
- Large SwiftUI bodies are split by structural depth and responsibility, not merely by line
  count.
- Existing `@State` ownership does not move between view types without a separate lifecycle
  review.

Exit gate:

- [ ] Every navigation destination opens on the phone.
- [ ] Today, Week, Plan and Progress figures match the frozen baseline.
- [ ] Activity details, routes, splits and charts render correctly.
- [ ] Review and proposal flows retain their due-date and identity behavior.
- [ ] Diagnostics remain excluded or gated appropriately in external builds.

### R10 - Move App composition and resources

**Purpose:** finish the tree after every dependency it composes has a stable destination.

App work:

1. Move `Sub4App`, `RootView`, launch state and root navigation under `App/`.
2. Introduce or formalize `AppEnvironment`/composition only if needed to express the final
   dependency graph.
3. Keep construction of database, repositories and platform clients in the composition
   area.
4. Ensure background entry points use the same authoritative dependencies as foreground
   launch.

Resource work:

1. Move assets and ordinary bundle resources in one batch.
2. Move `Info.plist` and entitlements in separate changes because their paths live in build
   settings.
3. Update `INFOPLIST_FILE`, `CODE_SIGN_ENTITLEMENTS` and any other affected path explicitly.
4. Confirm `plan.json`, `manual.html` and `PrivacyInfo.xcprivacy` remain target resources.
5. Read each resource back from the built product in tests.
6. Do not use Xcode Add Files; rely on synchronized folders and explicit build settings.

Exit gate:

- [ ] Cold launch and database-failure launch behave correctly.
- [ ] Debug and Release build.
- [ ] HealthKit purpose strings are present in the built product.
- [ ] Entitlements and background modes are present.
- [ ] All required resources load by their existing bundle names.
- [ ] No production Swift file remains directly under `Sub4/`.

### R11 - Split mixed-responsibility files

**Purpose:** improve architecture after the mechanical location changes are proven.

This is the first stage allowed to edit type boundaries. Candidate categories are determined
by R1 and may include:

- a file containing both provider transport and a domain value;
- a store combining persistence, network fetch and presentation state;
- a view containing reusable business calculations;
- database diagnostics embedded in a large view;
- source-specific identifiers embedded in canonical models; or
- backup/export code sharing runtime-persistence types.

For each split:

1. State the responsibility being separated.
2. Search all production and test call sites.
3. Extract one responsibility without changing output.
4. Add a focused test at the new boundary.
5. Run the suite.
6. Perform the required device check.
7. Commit before starting the next split.

`DatabaseHealthView` and other large diagnostic surfaces receive special treatment: state
ownership and view-builder depth are mapped before code moves. A child that renders nothing
still contributes structural depth.

Exit gate:

- [ ] Every production file has one primary responsibility.
- [ ] No known provider/domain, view/domain or persistence/presentation mixed file remains
      without a documented reason.

### R12 - Replace global dependencies at selected seams

**Purpose:** make future sources and surfaces testable without a big-bang rewrite.

Prioritize dependencies that cross architecture boundaries:

1. Repository access used by features.
2. Health and weather source clients.
3. Clock/date provider where deterministic behavior needs it.
4. Background execution entry points.
5. Backup/export destinations.

Work:

1. Define the smallest interface that expresses the consumer's need.
2. Keep interfaces close to the domain/app boundary that owns the question.
3. Supply the concrete implementation from App composition.
4. Migrate one feature at a time.
5. Preserve observable lifetimes explicitly.
6. Remove the global accessor only when no production caller remains.

Do not replace harmless pure static functions with injected objects. Do not create an object
graph whose only purpose is avoiding the word `shared`.

Exit gate:

- [ ] No feature constructs a concrete database or external-source implementation.
- [ ] Selected features can be tested with deterministic in-memory implementations.
- [ ] App composition is the single visible construction point.

### R13 - Decide on a pure Domain module

**Purpose:** use compile-time boundaries only where their value now exceeds their cost.

Evaluate extracting `Sub4Domain` as a Swift package or target containing:

- source-neutral models;
- matching;
- plan rules;
- load and volume calculations;
- review rules; and
- shared domain time/unit types.

Adopt only if:

- Domain already passes its forbidden-import checks;
- public/internal API boundaries can be stated without exposing implementation detail;
- build and test speed improves or a second consumer such as Watch/widget needs reuse; and
- concurrency annotations remain clear across the module boundary.

If adopted:

1. Extract in small domain-area batches.
2. Add `Sub4DomainTests`.
3. Keep GRDB, HealthKit and SwiftUI out of the package manifest and source.
4. Update the app target to import it.
5. Run the full device campaign.

If not adopted, record that folder boundaries plus architecture checks are sufficient for the
current product. Deferring is an accepted outcome, not an incomplete restructure.

Exit gate:

- [ ] A written accept/defer decision exists.
- [ ] Test-target names match the modules that actually exist.

### R14 - Documentation and tooling repair

**Purpose:** leave one current map rather than a new tree described by old paths.

Work:

1. Update `CLAUDE.md` with the new source map and dependency rules.
2. Update the documentation index.
3. Update scripts that assume flat paths.
4. Update CI path filters and test commands.
5. Update comments that cite old file paths while preserving the decisions they explain.
6. Update the user manual only where the restructure exposed an actual user-visible change;
   a structural move alone should not require user documentation.
7. Mark this plan completed with the final baseline commit and measured results.
8. Archive superseded structural proposals without rewriting their historical content.

Prefer links to ADR-0002 and ADR-0003 over duplicating their decisions here.

Exit gate:

- [ ] A new contributor can locate app startup, a feature, a domain rule, a repository, an
      external source and a platform service from the documentation index.
- [ ] No active document tells readers that production source is flat.
- [ ] CI and local scripts use the new paths.

### R15 - Final verification and release

**Purpose:** prove that the restructure changed ownership and paths, not behavior.

Automated checks:

- [ ] Full local test suite.
- [ ] Release preflight.
- [ ] Architecture enforcement tests.
- [ ] Privacy/resource tests against the built product.
- [ ] Fresh-database migration tests.
- [ ] Existing-database migration/open tests.
- [ ] Repository integration tests.
- [ ] Backup/export/restore tests.

Device campaign:

1. Cold launch.
2. Existing-database launch.
3. Today, Week, Plan and Progress baseline figures.
4. Activity list, detail, route, splits, load and weather.
5. Health authorization and refresh.
6. Background refresh and foreground catch-up.
7. Review due state and review/proposal history.
8. Data export and share.
9. Protected backup and restore rehearsal.
10. Delete/disconnect preview and receipt without performing an unplanned destructive test.
11. Settings privacy and source disclosures.
12. Diagnostics and database-health screens.

Release requirements:

- [ ] No unexplained baseline difference.
- [ ] No new warning.
- [ ] No new architecture exception.
- [ ] Clean worktree.
- [ ] Tagged final restructure baseline.
- [ ] Rollback instructions tested on a disposable branch or checkout.

## 14. Current-file disposition guide

The definitive map is produced from the post-migration source in R1. The following guide
states how today's major families should be classified if they still exist.

| Current family | Expected destination or action |
|---|---|
| `Sub4App`, `RootView`, `ContentView`, `Sub4Launch` | `App/` |
| `Activity`, `ActivityDetail`, `ActivityStreams`, `MergedActivity` | `Domain/Activity/` after provider fields are separated |
| `Matcher`, `MatchResolver`, `SessionTally` | `Domain/Matching/` |
| `PMC`, `TrainingLoad`, `Monotony`, `LoadSeries`, `LoadMetrics`, `PowerLoad` | `Domain/TrainingLoad/` |
| plan models, `PlanFocus`, `PlanWorkout`, fuel and warm-up rules | `Domain/TrainingPlan/` |
| review scheduling, payload and proposal rules | `Domain/Review/` |
| GRDB repositories | `Data/Database/Repositories/` |
| `Sub4Database` | `Data/Database/` |
| `Sub4Migrations*` | `Data/Database/Migrations/` unchanged internally |
| `Sub4Import*` retained for supported upgrades | `Data/Database/Import/` or `Data/Upgrade/` with removal condition |
| semantic verifier and migration ledger | `Data/Database/Verification/` |
| database benchmark code | `Data/Database/Maintenance/` or Diagnostics when presentation-only |
| HealthKit stores/adapters/reconciliation | `Data/Sources/HealthKit/` |
| Weather providers/adapters | `Data/Sources/Weather/` |
| Strava auth/client/store code | Delete before entry; do not create a permanent Strava folder |
| legacy JSON stores/readers | Delete at D8 or isolate under time-bounded `Data/Upgrade/LegacyJSON/` |
| Today/Week/Plan/Progress views | corresponding `Features/` folders |
| activity detail views, maps, stream charts, split tables | `Features/ActivityDetail/` unless genuinely reusable visually |
| review views and proposal UI | `Features/Review/` |
| data lifecycle screens and controls | `Features/DataManagement/` |
| database health/parity/read-back screens | `Features/Diagnostics/` |
| theme, chart chrome, shared cards and toggles | `DesignSystem/` |
| Keychain, file protection, preferences, share sheet | `Platform/` |
| assets, plan seed, manual, manifests and entitlements | `Resources/`, with build-setting verification |

Files are classified by their declarations, not their names. For example, a file named like a
view that also computes a training rule is split in R11 rather than assigned wholesale to
Features.

## 15. Rollback strategy

### 15.1 Repository rollback

- Tag the accepted post-database/post-Strava baseline.
- Keep each move batch in its own commit.
- Keep every responsibility split in its own later commit.
- Do not squash until device verification is complete.
- Revert the failing batch rather than applying multiple speculative fixes on top of it.

### 15.2 Data safety

The restructure should not create a database migration. If a structural change appears to
require one, stop and treat it as separate persistence work.

Before the first stage and before any device build that changes resource/configuration paths:

- take a protected backup;
- verify its manifest and database copy;
- retain the preceding app build/source baseline; and
- do not perform delete/disconnect tests against the only device copy.

### 15.3 Xcode rollback

- Never use **Add Files** for synchronized source folders.
- Do not hand-create duplicate project references.
- Treat changes to `project.pbxproj`, Info.plist paths and entitlement paths as high-risk,
  isolated commits.
- Quit and reopen Xcode after new paths if the app target does not see them.

## 16. Effort estimate

These are focused engineering ranges, not calendar promises.

| Stage group | Expected effort |
|---|---:|
| R0-R2 decision, inventory and safety net | 1-2 days |
| R3-R10 mechanical tree and moves | 3-6 days |
| R11 mixed-responsibility splits | 3-8 days, depending on the post-migration source |
| R12 selected dependency injection | 2-5 days |
| R13 optional domain module | 0 days if deferred; 2-5 days if adopted |
| R14-R15 documentation and final verification | 1-3 days |

Expected total: approximately **2-4 focused working weeks**, with the optional module and the
number of mixed files creating most of the variance.

The work should be allowed to stop after any completed stage if the next stage does not yet
justify its cost. A stable folder architecture with enforced dependencies is already a valid
outcome.

## 17. Definition of done

The restructure is complete when:

- [ ] Every production Swift file has one approved top-level owner.
- [ ] No production Swift file remains directly under `Sub4/`.
- [ ] Domain is source-neutral and passes its import restrictions.
- [ ] Features contain no SQL, provider frameworks or direct training-data persistence.
- [ ] Database migrations remain byte-for-byte historical logic apart from path movement.
- [ ] Apple Health and weather integrations are isolated under Data sources.
- [ ] No active Strava implementation remains.
- [ ] Legacy JSON code exists only when a documented supported upgrade path still needs it.
- [ ] App composition is the visible construction point for concrete dependencies.
- [ ] DesignSystem has no persistence or domain ownership.
- [ ] Platform contains OS mechanics rather than training decisions.
- [ ] Test folders mirror the production architecture.
- [ ] Architecture checks enforce the dependency rules.
- [ ] Debug tests and Release preflight pass.
- [ ] The complete device campaign passes without unexplained differences.
- [ ] Backup and rollback evidence exists.
- [ ] Documentation and scripts point to the new paths.
- [ ] The final worktree is clean and the result is tagged.

## 18. Work that remains after the restructure

The restructure is a foundation, not the end of the modernization program. The PDF and the
current repository describe additional work that should not be silently treated as part of
the behavior-neutral file move. Mixing it into R0-R15 would make regressions much harder to
attribute.

The following work therefore starts only after R15 has an accepted, tagged baseline:

| Workstream | Evidence in the current project | Why it remains separate |
|---|---|---|
| Fresh independent peer review | `SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md` is a pre-database/pre-Health baseline | Findings and file references must be re-run against the final architecture, not copied forward as if still current |
| Load/strain model redesign | `docs/context/load-model-research.md`; detailed staged plan currently exists only in the former Triathlon document set | It deliberately changes calculations and UI meaning |
| Living in-app manual | `Sub4/manual.html` and peer-review phase 8.5 | The current manual is stale and a rewrite changes user-facing content |
| Source-aware Activities and manual entry | Peer-review phase 7.2 | New data, workflows, audit history and matching behavior are product changes |
| Athlete and plan generalization | Peer-review phase 7.3 | Removes Bruno-specific assumptions and adds versioned editing |
| Label, lifecycle and error-state repair | Peer-review phase 7.4 | Correctness and UX changes require their own tests and acceptance |
| First-run and recovery experience | Peer-review phase 7.1 | Introduces a launch/setup state machine and permission sequencing |
| Consumer Settings and support diagnostics | Peer-review phase 7.6 | Changes navigation and public/debug exposure |
| Accessibility, localization and units | Peer-review phases 8.1-8.2 | Cross-feature product work, not folder organization |
| iPad design and Progress scalability | `docs/context/ipad-readiness.md`, `docs/context/ipad-rebuild-plan.md`, peer-review phases 8.3-8.3.1 | Requires adaptive presentation, device decisions and performance work |
| Deployment-target review | Peer-review phase 8.4 | A release/product-support decision |
| Cloud sync, Watch and direct recording | Peer-review phase 7.5 | Large independent platform programs with new conflict and source behavior |

The current peer-review plan remains valuable as history and as a checklist, but it must not
be used as a literal current-state report after the database, Health and restructure phases.
Each open item is re-proven before it is placed on the active backlog.

## 19. Rules for the post-restructure product roadmap

1. **One canonical write path.** Every new durable value enters through a repository and the
   canonical database. No new feature-owned JSON or domain state in `UserDefaults`.
2. **Source and authorship remain visible.** Health-derived, app-authored, imported,
   calculated and corrected values are never collapsed into an indistinguishable number.
3. **Raw evidence is preserved.** Exclusion, matching, merging and correction alter derived
   use; they do not silently destroy source records.
4. **Plan and activity are different concepts.** A planned session, a recorded activity and
   their match have independent stable identities.
5. **Recovery signals inform before they steer.** Sleep, intake and subjective data are
   displayed and evaluated before any one of them automatically changes training.
6. **Every feature ships with its manual section.** User-facing behavior, glossary terms,
   privacy explanation and troubleshooting change in the same feature patch.
7. **Every calculation is versioned.** Load, matching, shoe wear, adherence and derived
   recovery results retain the calculation version needed to explain historical output.
8. **Every bulk write previews its effect.** Calendar publication, plan import, export,
   merge, exclusion and deletion show scope before commit and produce a result or receipt.
9. **iPhone remains correct while iPad improves.** The iPad implementation is adaptive
   presentation over shared features and domain logic, not a fork of the application.
10. **A feature is not complete at the happy path.** Empty, unavailable, denied, stale,
    partial, duplicated, offline and recovery states are part of its definition of done.

## 20. Post-restructure foundation programs

### F0 - Re-baseline and peer-review the restructured app

**Purpose:** establish what is genuinely still open after the migrations and structural
work, and prevent stale findings from driving implementation.

Steps:

1. Tag the R15 baseline and record app version, schema version, test count and device state.
2. Re-run architecture, correctness, privacy/security, concurrency, performance,
   accessibility and UX reviews against the live source.
3. Reproduce each surviving finding; close or reword findings whose premise disappeared.
4. Add a product review of Today, Week, Plan, Progress, Activities, Review, Settings,
   onboarding and recovery states.
5. Classify findings as correctness/release blocker, data-safety, product debt, performance,
   accessibility or feature opportunity.
6. Convert accepted findings into small deliverables with an owner, dependency, test and
   rollback condition.
7. Repeat a focused independent review before the first external beta and before each major
   public release.

Exit gate:

- [ ] No active finding relies only on a pre-restructure filename or behavior.
- [ ] P0/P1 findings have regression tests or a written reason why automation is impossible.
- [ ] The product backlog below is updated from evidence rather than assumed current.

### F1 - Establish the living manual system

**Purpose:** replace the obsolete monolithic manual with documentation that can be built one
section at a time and kept synchronized with the app.

Recommended shape:

```text
Resources/Manual/
├── manifest.json             # section order, title, version and feature ownership
├── getting-started.md
├── data-and-privacy.md
├── today.md
├── week.md
├── plan.md
├── progress.md
├── activities.md
├── review.md
├── settings.md
├── glossary.md
└── troubleshooting.md
```

The exact rendering mechanism is decided in a short spike. The preferred result is modular
Markdown as the editable source, validated during the build and rendered into the existing
in-app Help experience. If native Markdown does not provide the required tables, anchors or
accessibility, generate one bundled HTML artifact from those source sections. Do not return
to hand-editing a single large HTML file.

Build sequence:

1. Inventory every current screen, action, metric, permission and failure state.
2. Define a section manifest and permanent anchors so feature screens can deep-link to the
   relevant explanation.
3. Build Help navigation, search and the glossary shell.
4. Rewrite Getting Started and Data & Privacy from live behavior.
5. Add Today, Week and Plan sections.
6. Add Progress and explain each metric, source, unit, limitation and update cadence.
7. Add Activities, including matching, exclusion, manual entry, imports and route handling.
8. Add Review, Settings and data-management sections.
9. Add the full glossary. At minimum cover target, recorded, matched, adherence, load,
   adaptation, burden, fatigue, freshness terminology that remains, RPE, HRmax, HRR, zones,
   provenance, canonical source, estimated/measured, recovery and data quality.
10. Add troubleshooting for Health availability, missing routes/samples, stale data,
    import/merge problems, calendar permissions, failed export, database recovery and
    background refresh.
11. Add current screenshots only after the relevant screen is stable; provide useful alt
    text and keep text instructions sufficient without the image.
12. Add documentation checks: every manifest entry exists, anchors are unique, internal
    links resolve and every public feature declares a manual owner/section.

Definition of done:

- [ ] A user can reach the relevant manual section from every principal feature.
- [ ] A user can search a term without knowing which screen owns it.
- [ ] Manual content, screenshots and app behavior are reviewed together at release time.
- [ ] `Sub4/manual.html` is generated from current sources or retired with a migration note.

### F2 - Recover and implement the load/strain model decision

**Purpose:** give strain, work done, adaptation, burden and fatigue defensible meanings before
adding recovery signals that users may incorrectly assume already steer the plan.

Available material:

- `docs/context/load-model-research.md` is the active repository summary of the evidence
  review.
- The detailed `load-model-implementation-plan.md` was found in the former Triathlon
  document set rather than the active repository. Its decisions must be recovered into an
  active, versioned plan before implementation.

Placement after restructuring:

```text
Domain/TrainingLoad/             # eligibility, adaptation, burden, day state, versions
Data/Database/Repositories/      # stored inputs, cached outputs and invalidation revisions
Features/Progress/               # curves, explanations, comparisons and drill-down
Features/Today/                  # small current-state summary only
Features/ActivityDetail/         # per-activity contribution and eligibility explanation
```

Implementation stages recovered from that plan:

1. **Measurement harness:** compute current and proposed results side by side on fixed real
   and synthetic fixtures; do not change visible behavior.
2. **Typed score eligibility:** replace a single included/excluded idea with
   `planLinked`, `discretionary` and `incidental`, retaining the reason and provenance.
3. **Adaptation engine:** use eligible recorded work and apply the evidence-backed intensity
   floor per heart-rate sample, initially 60% of stored HRmax. Store HRmax/HRrest and the
   model version used.
4. **Burden engine:** calculate all-day/extra burden separately and without using the
   adaptation floor as a reason to erase low-level work.
5. **Day state:** combine the two curves for explanation only. Burden may be shown as context
   but never silently steer plan decisions.
6. **Cache contract:** key derived results by input revisions, athlete settings and
   calculation version; prove edits, exclusions, source corrections and profile changes
   invalidate the right range.
7. **UI shadow period:** show old/new comparisons in Diagnostics and validate expected days,
   missing HR, walking, strength, cycling and very long activities.
8. **UI cutover:** make adaptation and burden the primary language. Remove unsupported
   ATL:CTL/TSB ratio or difference freshness bands rather than relabelling them.
9. **Cleanup:** remove the old engine only after historical comparisons, documentation and
   rollback evidence are retained.

Required tests include threshold boundaries, missing/partial HR, sample gaps, timezone/day
boundaries, profile changes, excluded recordings, mixed sports, edited activities, cache
invalidation and deterministic historical recomputation.

Exit gate:

- [ ] The app can explain why an activity contributed to adaptation, burden, both or neither.
- [ ] A displayed fatigue/load state names its inputs and calculation version.
- [ ] No sleep or intake value automatically changes a workout through an unvalidated rule.
- [ ] The manual uses exactly the same vocabulary as the code and interface.

## 21. Product feature build cards

These are product increments after F0-F2. Their order is defined in section 23.

### P1 - Per-activity discard/exclusion

**Product intent:** let the athlete exclude a faulty recording from matching, load, totals,
charts and review without deleting the source evidence.

The current compile-time `DataCorrections.ignoredActivities` is not an acceptable user
feature. Replace it with a durable, reversible database decision.

Build:

1. Add an activity decision record containing activity ID, state, reason, created/updated
   time, actor and optional note. Prefer `included`/`excludedFaultyRecording`; do not create a
   vague hide switch.
2. Seed the current known faulty-recording exclusions during a versioned migration so
   behavior does not change at cutover.
3. Apply the decision once in the canonical activity/query boundary so every downstream
   calculation sees the same eligibility.
4. Add Exclude/Restore actions to activity detail with a consequence preview.
5. Preserve the raw activity, route, samples and source aliases. Exclusion changes derived
   participation only.
6. Recalculate affected matches, plan totals, load, gear wear, heatmaps and review evidence
   transactionally or through a durable invalidation queue.
7. Show excluded recordings in an explicit filter and in Diagnostics; never make them
   disappear without a recovery path.
8. Audit every change and support undo.

Definition of done:

- [ ] A faulty activity can be excluded and restored with identical source data.
- [ ] Every affected feature agrees immediately after recalculation.
- [ ] Compile-time activity ID exceptions are removed after seed verification.

### P2 - Route heatmap

**Product intent:** visualize where running and cycling work occurred while keeping precise
location data local and controllable.

This is not a cheap reuse of Strava `summary_polyline` after the source transition. It must
use the canonical route records populated from Apple Health or supported imports.

Build:

1. Verify real route coverage by sport and recording device after Health reconciliation.
2. Define heatmap inclusion rules: sport, date range, excluded activities, privacy zones,
   missing/low-quality routes and duplicate sources.
3. Create a source-neutral route-segment or tile aggregation in `Domain/Activity/Route` and a
   revision-keyed cache in Data. Do not redraw every raw point on each screen visit.
4. Downsample according to zoom while retaining the canonical route separately.
5. Add home/start/end privacy masking and an option to omit selected activities.
6. Build the presentation under `Features/Activities/Heatmap`, with sport/date filters,
   empty/partial coverage explanations and a textual accessibility summary.
7. Keep heatmap data out of diagnostics/support bundles and make export an explicit choice.
8. Profile long histories and memory on the oldest supported iPhone and on iPad.

Definition of done:

- [ ] The map never implies full coverage when routes are missing.
- [ ] Excluded/private segments disappear after cache invalidation.
- [ ] No third-party map or telemetry transfer occurs without documented consent and policy.

### P3 - Sleep from Apple Health

**Product intent:** add recovery context without pretending that one sleep number can safely
prescribe training.

Build:

1. Add least-privilege Health authorization and anchored ingestion for sleep analysis.
2. Store source samples and enough timezone/provenance data to explain nights spanning day
   boundaries and travel.
3. Derive a night record that can represent asleep, awake, in-bed, unspecified and supported
   sleep stages without fabricating missing stages.
4. Reconcile overlapping samples from multiple devices/sources deterministically.
5. Display duration, consistency and stage availability in a Recovery section, with
   unavailable/no-data/query-failed/stale states kept distinct.
6. Let Review consume a minimized summary only after its meaning and consent are approved.
7. Run a shadow observation period before correlating sleep with load, RPE or plan changes.
8. Add manual correction only if Health data proves insufficient; never overwrite the source
   sample.

Initial placement:

```text
Data/Sources/HealthKit/Sleep/
Domain/Recovery/Sleep/
Data/Database/Repositories/SleepRepository.swift
Features/Progress/Recovery/
Features/Today/RecoverySummary/
```

Definition of done:

- [ ] Nights remain correct across DST, timezone travel, naps and overlapping devices.
- [ ] Missing stages are described as missing, not zero.
- [ ] Sleep is informative-only until a separately validated decision rule is accepted.

### P4 - Manual training and plan building

This item contains two different products and they must not be implemented as one ambiguous
“Add training” button.

#### P4A - Create or edit a planned session

1. Add a plan-builder flow for sport, title, date/time, duration/distance target, intensity,
   structure, notes, fuel/warm-up and recurrence/template choice.
2. Preserve a stable session identity through reschedule, edit, skip, substitute and restore.
3. Version every plan mutation and support undo/history.
4. Show conflicts and the consequences for WorkoutKit and Calendar before commit.
5. Keep imported/bundled plan origin visible after edits.
6. Add validation for units, date boundaries, duplicate sessions and unsupported workout
   structures.

#### P4B - Create or edit a recorded activity manually

1. Add an app-authored activity source with sport, start/end, duration, distance, perceived
   effort and optional notes.
2. Never present manual distance, heart rate, power or calories as device-measured.
3. Run it through the same matching, load-eligibility and audit path as imported activities.
4. Support edit, correction history and deletion/restore without changing other source rows.
5. Make duplicate/merge suggestions explicit when a Health workout later appears.

Architecture placement:

```text
Domain/TrainingPlan/Editing/
Domain/Activity/ManualEntry/
Data/Database/Repositories/PlanRepository.swift
Data/Database/Repositories/ActivityRepository.swift
Features/PlanBuilder/
Features/Activities/ManualEntry/
```

This feature requires a product ADR because it supersedes the older rule that nothing is
ever logged manually. The ADR must decide whether both P4A and P4B are in scope, how authored
measurements affect load, and which fields may be edited after matching.

Definition of done:

- [ ] Plan edits retain history and do not orphan notes, matches or external event links.
- [ ] Manual activities are visibly authored and never impersonate Health measurements.
- [ ] The manual contains separate “Plan a workout” and “Record completed training” guides.

### P5 - Shoe and gear tracking

**Product intent:** retain useful gear history after Strava and let the athlete manage future
wear locally.

Build:

1. Preserve imported shoe/bike identity, retired state and lifetime baseline during Strava
   retirement.
2. Add local gear creation/editing, active/retired state, purchase/start date, initial
   distance, sport eligibility and optional wear threshold.
3. Add default gear rules per activity type while allowing a per-activity override.
4. Calculate wear from canonical included activities plus the explicit starting baseline;
   keep calculation version and history.
5. Recalculate on merge, exclusion, distance correction or gear reassignment.
6. Show current gear on activity detail and a Gear destination with remaining-distance
   guidance, history and retirement action.
7. Warn rather than auto-retire; thresholds are guidance, not a medical/safety guarantee.
8. Keep retired gear linked to historical activities.

Placement: `Domain/Athlete/Gear`, the athlete/gear repositories,
`Features/Gear`, and the gear section of Activity Detail and Settings.

### P6 - Energy, fluid and electrolyte intake

**Product intent:** turn fuel/liquid notes into structured evidence for the athlete and Review.

Separate two concepts:

- **Planned intake:** targets attached to a session or day.
- **Consumed intake:** timestamped entries linked to a day/activity, with source and units.

Build:

1. Define canonical quantities for water/fluid volume, carbohydrate, energy and sodium;
   optionally potassium/caffeine where there is a clear use. A “gel” is a product/serving
   that contributes quantities, not the scientific unit itself.
2. Add reusable products/servings and quick actions for water, electrolyte drink and gel.
3. Link intake to an activity when useful while permitting day-level entries.
4. Compare planned versus consumed without treating missing logging as zero intake.
5. Start with app-authored records. Add an optional HealthKit bridge only after duplicate,
   unit, provenance and consent rules are proven.
6. Decide explicitly whether the app writes supported nutrition types to Health or only reads
   them. Writes need confirmation, correction and deletion semantics.
7. Add Review summaries only with transparent coverage; free-text notes remain separate.
8. Avoid hydration/energy recommendations that imply medical precision without validated
   inputs and clear limits.

Placement:

```text
Domain/Nutrition/
Data/Database/Repositories/IntakeRepository.swift
Data/Sources/HealthKit/Nutrition/       # only if the bridge is accepted
Features/Intake/
Features/ActivityDetail/Intake/
```

Definition of done:

- [ ] Planned and consumed values cannot be confused in the UI or exports.
- [ ] Units convert without changing canonical stored quantities.
- [ ] Review can state logging coverage and never interprets absent entries as none consumed.

### P7 - Publish the training plan to Apple Calendar

**Product intent:** make scheduled training visible in the iOS/iPadOS Calendar app with a
link back to the exact SUB4 session.

Recommended model: SUB4 creates or uses a user-approved dedicated **SUB4 Training** calendar
and owns the events it publishes. This is easier to reconcile than scattering unmanaged
events across calendars.

Build:

1. Give every plan session a stable app deep link independent of its date and current plan
   version.
2. Add a preview showing calendars, date range, events to add/update/remove and permission
   required.
3. Store the EventKit calendar identifier, event identifier, session ID and last-published
   fingerprint in a sync-link table.
4. Publish title, start/end, concise training summary and the app URL. Keep sensitive notes
   out by default because Calendar may sync to other services/devices.
5. Reconcile reschedules, edits, skips, archive and plan replacement. Never delete an event
   the app does not own.
6. Detect a missing/deleted calendar or user-edited event and offer a clear rebuild/keep
   choice.
7. Decide whether v1 is one-way SUB4-to-Calendar. Bidirectional edits should be deferred
   unless conflict rules are designed explicitly.
8. Add disable/disconnect with a preview: keep published events or remove only SUB4-owned
   events.
9. Test timezone travel, all-day boundaries, DST, multiple calendars, denied/revoked access
   and plans with hundreds of sessions.

Placement: EventKit mechanics under `Platform/Calendar`, link persistence under Data,
publication/reconciliation rules under `Domain/TrainingPlan/CalendarPublishing`, and UI
under `Features/Plan/CalendarExport`.

### P8 - Week, month and full-plan export

**Product intent:** let the athlete share, print, analyze or move a selected part of the plan.

There is no single best format for every purpose. Build one export sheet with scope first
and format second:

| Format | Best use | Recommendation |
|---|---|---|
| PDF | Human-readable sharing, coach review and printing | Default share format |
| ICS | Importing scheduled sessions into calendar products | Calendar interchange; separate from managed EventKit sync |
| CSV | Spreadsheet analysis of sessions and targets | Stable documented columns |
| JSON | Lossless machine-readable backup/interchange | Versioned technical format, not the default user document |
| Markdown | Lightweight readable text for messages/notes | Optional after the core formats |

Build:

1. Define scope as selected week, calendar month, plan phase/custom range or full active plan.
2. Generate every format from one source-neutral `PlanExportSnapshot`, not separately from
   views.
3. Include plan version, generation time, timezone, units and whether values are target or
   recorded. Plan export defaults to targets; completed evidence requires an explicit option.
4. Preview record count and sensitive fields before generation.
5. Give filenames stable readable dates and plan names.
6. Validate ICS recurrence/timezone behavior and stable UIDs so repeated imports update
   rather than duplicate when supported.
7. Validate PDF pagination, headings, accessibility metadata and long workout descriptions.
8. Document CSV/JSON schemas and version them compatibly.
9. Keep “Export my data” as a separate privacy/lifecycle operation; a training-plan export
   is not a full backup.
10. Share through the platform service and remove temporary files according to the data
    lifecycle policy.

Placement: snapshot and format rules under `Domain/TrainingPlan/Export`, encoders and file
mechanics under `Platform/Export`, and the export sheet under `Features/Plan/Export`.

### P9 - iPad application experience

**Product intent:** deliver a designed adaptive experience, not a stretched phone UI.

The repository already records the chosen direction in `docs/context/ipad-rebuild-plan.md`:
a full split-view presentation for regular width, with the compact iPhone flow retained.
Revalidate that decision after the restructure and after Activities/Plan Builder navigation
is known.

Build:

1. Verify supported device families, Health capability requirements and iPad orientations.
2. Decide cross-device persistence/sync before promising equivalent iPhone/iPad state. A
   local-only app can support iPad, but the limitation must be explicit.
3. Add adaptive navigation and selection state at the App/Feature boundary using
   `NavigationSplitView` for regular width and compact navigation for iPhone/Slide Over.
4. Define DesignSystem layout metrics: readable width, sidebar/list widths, chart aspect
   ratios, grids, spacing and empty-detail states.
5. Convert sheets that represent navigation into detail panes/popovers; retain true modal
   tasks as sheets.
6. Make charts responsive, lazy and revision-cached; add sport filters so mixed-distance
   scales remain meaningful.
7. Support pointer, keyboard focus/shortcuts, multiple windows only if state and presentation
   ownership are safe, Stage Manager, Split View and all supported orientations.
8. Test the same feature semantics and repository behavior on both device classes; do not
   create iPad-only domain stores.

Definition of done:

- [ ] Regular-width screens have intentional information hierarchy and readable widths.
- [ ] Compact-width behavior remains correct.
- [ ] Cross-device and multi-window limitations are stated rather than implied away.
- [ ] Charts pass accessibility and maximum-history performance budgets.

## 22. Additional backlog retained from current project files

These items were not all in the new feature list, but should remain visible after the
restructure:

### Near-term product quality

- First-run, profile setup, source selection, initial-sync progress, demo/no-source mode and
  recovery without reinstalling.
- A source-aware Activities library with search, filters, calendar, detail, data-quality
  badges, merge/unmerge and FIT/TCX/GPX import/recovery.
- Correct Target versus Recorded labels, sport-specific totals, genuine adherence, shared
  plan lifecycle states and visible stale/last-updated/error states.
- Versioned/account-scoped plans with create/import, reschedule, skip, substitute, lock,
  archive, undo and stable session identity.
- Removal of hard-coded athlete/date/sex/zone/FTP/commute assumptions into explicit profile
  settings or versioned corrections.
- Consumer Settings separated from Advanced Diagnostics, plus a redacted support bundle that
  excludes tokens, raw routes and private notes.
- Progress performance work: lazy sections, deferred calculations, revision-based caching,
  maximum-history profiling and drill-down rather than rendering every chart immediately.
- A real-device and release verification matrix after every substantial feature group.

### Product readiness

- Full VoiceOver, Dynamic Type, target-size, contrast, Reduce Motion, chart-summary and
  keyboard/pointer accessibility.
- String Catalog, localized formatting, pluralization, metric/imperial display choices and
  pseudo-localized/right-to-left layout testing.
- Reassess the minimum iOS version from actual API needs and supported-device intent.
- Revalidate privacy manifests, entitlements, provider policies, Health declarations,
  Calendar disclosure and export/deletion behavior before external release.

### Later platform programs

- Cloud/device synchronization only after account ownership, encryption, backup and conflict
  rules exist for plan edits, notes, manual activities, exclusions, intake and matches.
- Apple Watch companion and direct workout recording only as another canonical source
  adapter, with offline, duplicate, interruption and clock-drift tests.
- Multiple goals/active plans and broader athlete templates after Bruno-specific assumptions
  are removed and one second-athlete fixture passes.
- Daily subjective readiness, individualized load coefficients and DFA-alpha1 remain research
  candidates, not committed behavior.

## 23. Recommended order after R15

The following order keeps correctness and explainability ahead of attractive surfaces:

| Wave | Work | Reason |
|---|---|---|
| W0 | F0 re-baseline/peer review; recover the detailed load plan; establish manual manifest | Establishes current truth and protects the two at-risk knowledge assets |
| W1 | P1 per-activity exclusion; correctness/label/error-state fixes; load measurement harness | Faulty evidence and ambiguous UI must be fixed before new analytics consume them |
| W2 | F2 load/strain implementation and UI cutover | Gives future recovery and Review features stable vocabulary and inputs |
| W3 | Activities library/import recovery; P4 plan building/manual activity ADR and first slice | Creates the source-aware user-editing foundation used by later features |
| W4 | P5 shoe tracking; P6 structured intake; P3 sleep read-only | Adds durable athlete-owned and Health recovery context without automatic steering |
| W5 | P7 managed Calendar publication and P8 multi-format plan export | Both depend on stable versioned plan/session identity |
| W6 | P2 route heatmap | Depends on verified Health route coverage, exclusion, privacy and scalable route storage |
| W7 | P9 iPad designed experience and Progress performance completion | Uses stable final navigation/features and avoids rebuilding the split view repeatedly |
| W8 | Cloud sync, Watch/direct recording, multiple plans/goals and validated advanced recovery | Separate future platform/product programs |

The living manual advances in every wave rather than waiting until W7. Accessibility,
localization, privacy and performance acceptance likewise belong to each feature, followed by
focused whole-app passes before external release.

## 24. Decisions to validate before acceptance

The following recommendations are part of this proposal and require explicit validation:

1. **Timing:** start after the complete database and Strava-to-Health transition, not after
   D7 alone.
2. **Top-level architecture:** App, Domain, Data, Features, DesignSystem, Platform and
   Resources.
3. **No generic Core/Services/Utilities tree.**
4. **Folders first, modules later.**
5. **One optional module:** evaluate `Sub4Domain`; do not pre-approve multiple frameworks.
6. **Mechanical moves before responsibility splits.**
7. **Dependency injection only at selected seams.**
8. **Architecture tests make folder boundaries enforceable.**
9. **No active Strava folder in the final tree.**
10. **Legacy JSON upgrade code must have a written removal condition.**
11. **Post-restructure boundary:** R0-R15 remain behavior-neutral; F0 onward is a separate,
    newly estimated product program.
12. **Manual architecture:** modular Markdown is the editable source, with validated native
    rendering or generated bundled HTML.
13. **Load terminology:** adaptation and burden are separate; unsupported freshness ratios
    are removed rather than renamed.
14. **Manual training:** explicitly decide planned-session editing (P4A) and completed manual
    activity entry (P4B), superseding the old absolute no-manual-entry rule through an ADR.
15. **Faulty recordings:** exclusion is durable, reversible and audited; raw evidence is not
    deleted.
16. **Route heatmap:** build from canonical Health/import routes, not a retired Strava
    summary-polyline assumption.
17. **Sleep:** read-only/informative first; it does not steer training until a validated rule
    is separately accepted.
18. **Intake:** planned and consumed quantities are distinct; gels are product servings and
    electrolytes use measurable components such as sodium.
19. **Calendar:** begin with one-way publication to a dedicated user-approved SUB4 calendar;
    defer bidirectional edits.
20. **Export:** offer PDF, ICS, CSV and versioned JSON by purpose rather than selecting one
    universal format.
21. **iPad:** build an adaptive split-view experience over the same domain/repositories and
    decide cross-device sync limitations before release claims.

Once these are accepted, change this document's status to **Accepted** and link it from the
project's documentation index. Until then it is a proposal and authorizes no source moves.
