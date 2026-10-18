# Shared package, bundled Transcriber, and Whisper in Canopy

Status: sketch, nothing built yet. Items marked **verify** are assumptions to check with a spike before committing to them.

## Goals

1. One sign-in flow for Canopy and Transcriber.
2. One copy of each AI model on disk, shared by both apps.
3. One download for the user, still two separate apps.
4. Whisper available in Canopy, loaded from the shared model folder.

## Where things stand

| | Canopy | Transcriber |
|---|---|---|
| Bundle id | `com.ROSESASHUMANS.Canopy` | `church.lifepoint.transcriber` |
| Min macOS | 26 | 14 |
| Sandbox | off | off |
| Updates | Sparkle (GitHub release appcast) | Sparkle (its own repo's appcast) |
| Credential | person's Supabase session (`SiteAccount`, `SupabaseClient`) | per-campus key in Keychain (`WebSignIn`, `Keychain`) |
| Models | MLX LLMs (`AIModels.swift`), Apple SpeechAnalyzer | WhisperKit in `~/Library/Application Support/Transcriber/Models` |

Both are unsandboxed, so sharing a folder on disk needs no entitlements or app groups.

## 1. The shared package: `ChurchLandingPageKit`

A small Swift package in its own repo (`church-landing-page-kit`, tagged versions), consumed by Canopy and Transcriber as a normal SwiftPM dependency. A separate repo is needed because the two apps live in separate repos today. If Transcriber moves into the Canopy repo, make it a local package instead.

```
ChurchLandingPageKit/
  Package.swift
  Sources/
    ChurchKitCore/        // no dependencies
      SharedPaths.swift   // ~/Library/Application Support/Church Landing Page/...
      Keychain.swift      // one Keychain helper, replaces both copies
      FileLock.swift      // cross-process lock (flock) for downloads
    ChurchKitAuth/
      SupabaseSession.swift   // moved from Canopy's SupabaseClient.swift
      TokenRefresh.swift      // refresh + onSessionChange
      ConnectFlow.swift       // browser -> loopback listener (from Transcriber's WebSignIn)
      Credentials.swift       // user session + campus key, stored together
    ChurchKitModels/
      ModelStore.swift        // list, locate, size, delete models in the shared folder
      WhisperModels.swift     // WhisperKit variants, download, progress
      (MLX model support stays in Canopy at first)
```

**Dependency rule:** `ChurchKitModels` depends on WhisperKit. `ChurchKitAuth` and `ChurchKitCore` depend on nothing, so Transcriber's auth code never pulls in MLX.

### Auth: one flow, two kinds of credential

Today the website's connect page serves two clients. Canopy gets a one-time token and trades it for a user session. Transcriber gets a campus key through a loopback redirect. Both are "sign in with the website and pick a campus". They stay different credentials:

- **User session** (Canopy): per person, expires, refreshed. It is what Row Level Security reads.
- **Campus key** (Transcriber and its device jobs): a device credential, long-lived, scoped to one campus. The Mac mini must keep working with nobody signed in, so it must not depend on a person's session.

So "one sign-in" means one flow and one stored record. `ConnectFlow` signs in once, and the connect page returns both the session and the campus key for the chosen campus. `Credentials` stores both. Canopy mostly uses the session. The helper uses the key.

**Sharing the secret between processes (verify).** Options, in order of preference:
1. A shared Keychain access group (`<TeamID>.church.landingpage.shared`). For Developer ID apps this likely needs a provisioning profile with the keychain-access-groups entitlement. Spike it first.
2. If that fails, a legacy keychain item whose access control lists both apps (one prompt on first access).
3. Last resort: Canopy writes the campus key into Transcriber's existing keychain item (`church.lifepoint.transcriber` / `transcriber-key`). Same user and same machine, so the user sees a single prompt. This keeps today's Transcriber storage working unchanged.

Migration: Transcriber keeps reading its old key if the new record is missing, so Macs already deployed keep working through the update.

### Models: one folder

```
~/Library/Application Support/Church Landing Page/Models/
  whisper/                  // WhisperKit downloadBase (it makes models/argmaxinc/whisperkit-coreml/<variant> under this)
  mlx/                      // only if Canopy's HuggingFace/MLX downloads can be pointed here (verify)
  .locks/
```

- Transcriber's `modelsDir` changes from `Transcriber/Models` to the shared path. On first launch, if the old folder exists and the new one doesn't, move it (same volume, instant).
- The README's offline setup instructions need the new path.
- `FileLock` serializes downloads, so Canopy and the helper never download the same 630 MB model at once. Second process waits, then finds the model already there.
- Open question (**verify**): Core ML caches compiled models per app, so the first load in each app may re-prewarm even with shared files. The disk is shared, but the first-run wait may not be.
- Canopy's MLX models: check where `MLXHuggingFace` / `HuggingFace` store downloads by default. Redirecting them to `mlx/` is nice to have but not required for this plan, since Transcriber doesn't use them.

## 2. Bundling Transcriber with Canopy

Two ways to get "one download, two apps":

| | A. Side by side (DMG/zip with both apps) | B. Nested helper inside `Canopy.app` |
|---|---|---|
| Updates | Two Sparkle channels, independent | One channel; Canopy's update replaces both |
| Coupling | Low | Versions locked together |
| Mac mini | Install two apps | One install, Canopy enables the helper |
| Sparkle risk | None | Transcriber's own updater must be disabled when nested |

**Recommendation: B**, because you want a single download and Canopy can then manage the helper. Layout:

```
Canopy.app/Contents/Library/LoginItems/Transcriber.app
```

- Canopy turns it on and off with `SMAppService.loginItem(identifier: "church.lifepoint.transcriber")`. Today Transcriber registers itself with `SMAppService.mainApp`. The nested build registers through Canopy instead.
- Transcriber keeps its own bundle id, menu-bar icon, settings, OSC and schedule. It remains a complete app that can also be run on its own.
- A build flag (or Info.plist key) turns off Transcriber's Sparkle updater when it is nested. Otherwise it would try to replace itself inside Canopy's signed bundle.
- Canopy shows helper status (running or not, last transcript time, campus) with a small `HelperStatus` message sent over `DistributedNotificationCenter` or a status file in `~/Library/Application Support/Church Landing Page/`. No XPC needed at first.
- **Deployment target:** Canopy needs macOS 26. A nested Transcriber ships on 26 too. Confirm the Mac mini runs macOS 26 before choosing B. If it can't, use A.
- Signing and notarization: `release.sh` signs inside-out (helper first, then Canopy) and notarizes once. Port the relevant steps from Transcriber's `build_app.sh` (it already signs Sparkle's pieces inside-out). The helper's Sparkle framework can be dropped from the nested build.
- Transcriber's repo keeps building a standalone app for as long as you want it. Canopy's release pulls a tagged Transcriber build as an input.

## 3. Whisper in Canopy

`TranscriptionService` already has the seam:

```swift
protocol TranscriptionBackend: Sendable {
    func transcribe(audioFile: URL, locale: Locale) async throws -> [TranscriptSegment]
}
```

Plan:

1. Add `WhisperKitBackend: TranscriptionBackend` in Canopy. It uses `ChurchKitModels.WhisperModels` to find or download the variant in the shared folder, then calls WhisperKit's file transcription and maps word and segment timings to `TranscriptSegment`.
2. Backend choice in Canopy settings: Apple (default, no download) or Whisper (shows model size and download progress, and reuses the model if Transcriber already fetched it).
3. Let the user pick a Whisper variant. Default to the same one Transcriber uses so the folder holds one copy. The 150 MB `base.en` is a lighter option.
4. Reuse Transcriber's hallucination filter and the "names and terms" prompt biasing by moving them from `SpeechEngine` into `ChurchKitModels` or a small `ChurchKitSpeech` module. That is a second step. Do the plain backend first.
5. Use a language-detection or English-only setting rather than the `locale` argument alone. Whisper's `.en` models ignore it.

**Dependency conflict risk (verify first).** Canopy already pulls `swift-transformers` (Tokenizers), `HuggingFace`, and MLX packages. WhisperKit depends on swift-transformers too. If their version ranges don't overlap, SwiftPM fails to resolve. Spike this on a branch before anything else. It is the most likely thing to break the plan.

## Build order

1. **Spike (half a day):** add WhisperKit to Canopy and resolve. Test whether a shared keychain access group works for a Developer ID build. Confirm the Mac mini's macOS version. These three answers decide the rest.
2. Create `ChurchLandingPageKit` with `ChurchKitCore` (paths, keychain, lock). Switch Transcriber's model path to the shared folder with the move-on-first-launch migration. Ship a Transcriber update. Nothing user-visible changes except one model location.
3. Move auth into `ChurchKitAuth`. Update the connect page to return the campus key with the session. Canopy and Transcriber both use it.
4. `WhisperKitBackend` in Canopy plus the settings picker.
5. Nest Transcriber in Canopy as a login item, update `release.sh`, and add the helper status view to Canopy.

Steps 2 and 4 are independent of steps 3 and 5, and the later ones carry the release-process risk. Do 2 and 4 first and ship them.

## Risks

- WhisperKit and MLX dependency resolution (above).
- Keychain sharing under Developer ID (above) may force the fallback.
- Nested helper plus Sparkle: get the "no updater when nested" switch right, or the first update breaks the signature.
- The Mac mini is a live Sunday service. Roll out the Transcriber changes in steps 2 and 3 there first, and keep the standalone Transcriber release available for rollback.
- Changing the connect page affects both apps, so deploy it additively (return both credentials, keep the old redirect shape working) before either app depends on it.

## Branding: Church Landing Page, not Lifepoint

Package and module names use the Church Landing Page name: `ChurchLandingPageKit` with `ChurchKitCore`, `ChurchKitAuth` and `ChurchKitModels`. The shared folder is `~/Library/Application Support/Church Landing Page/`, and the shared keychain group is `<TeamID>.church.landingpage.shared`.

The **existing identifiers are still Lifepoint**: Transcriber's bundle id is `church.lifepoint.transcriber`, its Keychain service and its SMAppService registration use it, and Canopy's id is `com.ROSESASHUMANS.Canopy`. Renaming a bundle id on deployed Macs has costs:

- Settings in UserDefaults (`settings.v1`) are stored per bundle id, so a renamed app starts blank unless it migrates them.
- The Keychain item (campus key, PCO tokens) is keyed by the old service name and has to be read under the old name and rewritten.
- The Login Item registration and Sparkle's update lineage both follow the bundle id. Sparkle needs one last update shipped under the old id that moves the app over.
- Microphone permission is granted per bundle id, so the user is asked again.

**Decided: both apps move to new Church Landing Page IDs**, in the same release that nests Transcriber (step 5), so each Mac is disrupted once.

| App | Old | New |
|---|---|---|
| Canopy | `com.ROSESASHUMANS.Canopy` | `com.rosesashumans.churchlandingpage.canopy` |
| Transcriber | `church.lifepoint.transcriber` | `com.rosesashumans.churchlandingpage.transcriber` |
| Shared keychain group | n/a | `<TeamID>.com.rosesashumans.churchlandingpage.shared` |

The prefix follows the domain the website already uses (`churchlandingpage.rosesashumans.com`). Confirm it before building, because bundle ids are painful to change a second time.

### Migration (each app, first launch of the new id)

1. Look for the old app's data and copy it, never move it, so a rollback still works.
   - UserDefaults: read the old domain with `UserDefaults(suiteName: "<old id>")` (or the old `.plist` in `~/Library/Preferences`) and write it into the new domain.
   - Keychain: read the old service's items and rewrite them under the new service or shared group. Both are the same user and the same machine, but the first read may prompt once.
   - Canopy's Core Data store and any files under `~/Library/Application Support/Canopy` or the old container move to the new location if the folder name changes.
2. Write a `migrated-from` marker so it only runs once.
3. Transcriber's old Application Support folders (`Transcriber`, `LifepointTranscriber`, `Lifepoint Transcriber`) are left in place. Only `Models` moves, into the shared folder, as in section 1.

### Updates and old installs

- Sparkle follows the bundle id, so the new apps cannot update the old ones in place. Ship a **last release under each old id** whose only job is to download the new app and, on launch, offer to switch (or simply tell the user to install the new download). Keep the old appcast URLs alive for as long as old Macs exist.
- The new Canopy ships with a new appcast URL (and a new Sparkle feed for the bundle) set in its Info.plist. Transcriber's standalone feed can stay at its repo or move with it.
- `SMAppService` registrations are per id. The old login item must be removed (the last old release unregisters itself) and the new one registered. Otherwise two copies start at login.
- Microphone and any other privacy permissions are granted per bundle id, so the Mac mini will ask again. Do the switch at the mini in person, and confirm the mic prompt is allowed before leaving.
- Anything else that references the old ids: notarization profiles in `release.sh` and `build_app.sh`, the Xcode project's `PRODUCT_BUNDLE_IDENTIFIER` (and the Tests and UITests ids), `Info.plist`, entitlements, the Keychain service strings, the `DispatchQueue` labels, and the website's `Connect Canopy` page if it names the app.

Display names, the DMG and website copy change at the same time, and do not need a separate migration.

## Spike results (2026-10-18)

Run in a scratch SwiftPM package that copies Canopy's dependency requirements (mlx-swift-lm 3.32.3+, swift-transformers 1.3.0+, swift-huggingface 0.9.0+, Sparkle 2.9.4+). Resolution only; nothing was compiled yet.

**1. WhisperKit in Canopy: conflict found, two ways around it.**
- Released WhisperKit (0.12 to 0.18.0, latest) requires `swift-transformers` below 1.2. Canopy's project asks for 1.3.0 or later (`Canopy.xcodeproj`, currently resolved at 1.3.5). They cannot both resolve as the project stands.
- **Option A, use released WhisperKit 0.18.0:** remove Canopy's own `swift-transformers` requirement. `mlx-swift-lm` doesn't depend on it, so SwiftPM then picks 1.1.9 for both, the same version Transcriber already ships with. Resolves cleanly. Still to check: Canopy's `import Tokenizers` and the `#huggingFaceTokenizerLoader()` macro in `AIModels.swift` must compile against 1.1.9. That needs a real build.
- **Option B, WhisperKit `main` (unreleased, commit 9f99b5c, 2026-10-10):** no longer depends on swift-transformers, so Canopy's 1.3.5 stays. Resolves cleanly. Cost: pinned to an unreleased commit, and its Package.swift also declares Vapor and OpenAPI packages for its server targets. SwiftPM only builds what's imported, but it will fetch them.
- **Recommendation:** A if Canopy compiles on 1.1.9, because it keeps released versions on both sides. Otherwise B pinned by revision until a WhisperKit release catches up.

**2. Keychain sharing: needs Apple Developer portal work, can't be finished offline.**
- Signing: team `GAYT638PXY`, Developer ID Application "Roses as Humans LLC" (two identities installed). `exportOptions.plist` uses manual Developer ID signing. Both apps are unsandboxed.
- A shared Keychain access group is a restricted entitlement, so a Developer ID build needs a provisioning profile that grants it. That means registering explicit App IDs for the new bundle ids in the developer portal and creating Developer ID profiles for both. Nothing in the repo or entitlements does this today.
- **Fallback if that is more setup than it is worth:** the access list on the keychain item. Canopy creates the campus-key item with an access list that trusts the helper's path (`SecTrustedApplicationCreateFromPath`; deprecated but still works for the file-based keychain). The helper then reads it without a prompt. This matters for the Mac mini, which must never block on a keychain dialog.
- **Recommendation:** try the access-list approach first (no portal work). Move to the access group only if it prompts.

**3. Mac mini macOS version: not checked, I can't see that machine.** A nested Transcriber needs macOS 26 (Canopy's floor). Open question for you.

### What this changes in the build order

- Step 1 spike is done except for a real Canopy build against Tokenizers 1.1.9 (Option A) and the Mac mini's OS version.
- Step 4 (Whisper in Canopy) starts with the dependency change above.

### Update: Option A confirmed in a real Canopy build

- `Canopy.xcodeproj` now has the WhisperKit package (0.18.0) linked to the Canopy target, and the `swift-transformers` requirement is lowered from 1.3.0 to 1.1.9.
- Resolved versions: WhisperKit 0.18.0, swift-transformers 1.1.9 (was 1.3.5), swift-argument-parser 1.8.2 (new). Everything else is unchanged.
- `xcodebuild` Debug build succeeded: Canopy's `import Tokenizers` and `#huggingFaceTokenizerLoader()` compile against 1.1.9. Not yet run: the unit tests and an actual local-model run, so check the Enhanced (MLX) models still load before shipping.
- The first resolve after the change failed once with a "disabled default traits on swift-transformers" error. Running the resolve again succeeded. If it recurs on a fresh clone, resolve twice.
- Option B (WhisperKit `main`) is no longer needed.
- Mac mini confirmed on macOS 26 or later, so the nested-helper layout (section 2) stands.

## Progress and queued follow-ups

Done: WhisperKit in Canopy (option A), `SharedModelFolder` and `WhisperKitBackend` in Canopy, Transcriber moved to the shared model folder with a move-on-first-launch migration (`ModelFolder.swift` in the transcriber repo).

Still to do from the plan: `ChurchLandingPageKit` package with `ChurchKitAuth`, the combined sign-in, the new bundle ids with their migration, and the nested helper.

Queued for after the plan is complete (requested 2026-10-18):

1. **Church Landing Page website:** update its links and info to reflect the new package, the bundled download, and the new app names. The site is at `~/Developer/church-landing-page`. This includes the connect page that signs in both apps and any download or release links that still point at the separate Transcriber release.
2. **Canopy menu bar icon:** use the SF Symbol `tree.circle` and turn it red while a workflow is running. Look at how `WorkflowRunSession` and `WorkflowEngine` report that a run is active, and drive the icon from that.

### Update: shared package and combined sign-in (built, not released)

- **`~/Developer/church-landing-page-kit`** (local git repo, not published): `ChurchKitCore` (shared model folder, migration, download lock) and `ChurchKitAuth` (`SupabaseSession`, `SupabaseAuth.verify/refresh`, `ConnectFlow`). Ten tests. Canopy links it as a local package (`../church-landing-page-kit`), Transcriber through `Package.swift` `path:`. Publish it to GitHub before building either app anywhere but this Mac.
- **Website:** new `/auth/connect` page and `connectApp` action (`app/(platform)/auth/connect`). Takes `port`, `state`, `app` and `want` (`session`, `key`, or both) and redirects back with `token`/`supabase`/`apikey` and/or `key`/`campus`/`campus_name`. The old `/auth/canopy` and `/auth/transcriber` pages are untouched so already-installed apps keep working.
- **Order matters for release:** deploy the website first. Both apps now open `/auth/connect`, which doesn't exist on the live site yet, so signing in from a new build fails until it is deployed.
- Canopy asks for `session` only and Transcriber for `key` only. The two-credential request (`session,key`) is supported by the page and the package and is what Canopy will use to hand the campus key to the nested helper.

### Update: new bundle ids (built, not released)

- Canopy is `com.rosesashumans.churchlandingpage.canopy` (tests `.canopytests`, `.canopyuitests`). Transcriber is `com.rosesashumans.churchlandingpage.transcriber`.
- `LegacyMigration` (ChurchKitCore) runs first thing at launch in both apps. It copies the old id's UserDefaults and the old Keychain service's items to the new ones, once, and never deletes anything. Tested on sample data, and checked read-only against this Mac's real old settings (46 Canopy keys, 6 Transcriber keys). It has not been run through a real launch of a signed build.
- Canopy's other files (the `Canopy/RunCheckpoints` folder) are named by folder, not bundle id, so they carry over untouched.
- **Keychain prompt:** the Keychain trusts the old app's code identity, which includes its bundle id, so the first launch of each new app may ask for the login password once to read the old items. Do the switch at the Mac mini in person.

Still open before release:
1. **Sparkle:** I believe Sparkle refuses an update whose bundle id differs from the running app (verify with a real test). If so, the old apps can't update into the new ones. Each old app needs one last release that shows "Canopy has moved, download the new version" and links the download. The new apps need their own appcast URL (`SUFeedURL`) so old installs never see their entries.
2. **Login items:** the old Transcriber's `SMAppService` registration stays on the old id. The final old release should unregister it; otherwise both start at login.
3. **Permissions:** microphone access is asked again for the new Transcriber.
