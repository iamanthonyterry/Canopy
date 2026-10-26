# Merging Canopy into Transcriber (the new app is called Canopy)

Status: plan, nothing built. Items marked **verify** are assumptions to prove in Phase 0.

## Decisions made

- **Keep Transcriber's identity.** Bundle ID `com.rosesashumans.churchlandingpage.transcriber`, Sparkle feed `github.com/iamanthonyterry/transcriber/releases/latest/download/appcast.xml`, and the same EdDSA key. The mic permission, Keychain campus key and login item on the Mac mini all hang on this, so the unattended Mac keeps working through the update. Only the display name, app file name and icon change.
- **One credential: the campus key.** No per-person Supabase session in the app. Workflow progress goes to the website through key-authenticated API routes, like `/api/device-jobs` today. This removes `SupabaseClient`, `SiteAccount` and `ChurchKitAuth` from the app.
- **Workflow sync between Macs is dropped** for now. Add JSON export and import of workflows instead.
- **Build base: Canopy's Xcode project (decided in Phase 2).** Transcriber's sources move into it, with the bundle ID set to Transcriber's. See the Phase 2 build-base test below. The reverse (Canopy into the SwiftPM package) would mean converting ~44,000 lines of code that assumes Swift 6 and main-thread-by-default.

## Phase 0: spikes (done)

The DAW feasibility spike moved out of Phase 0 and is deferred (see Phase 5). The update tests used stub apps with throwaway bundle IDs and a throwaway signing key (since deleted), so nothing touched the live Transcriber's settings, mic or website key.

1. **In-place Sparkle rename: works.** An installed app updated to a build named `Canopy.app` with the same bundle ID. The update installed, relaunched and passed code-signature verification.
   - **File name stays the same on disk.** Sparkle keeps the old path, so an existing `Transcriber.app` is still called `Transcriber.app` in Finder after the update, although the menu and Dock show "Canopy". (Sparkle's rename-on-update option is off by default and we use the stock Sparkle package.) Phase 4 adds a first-launch step that renames the file to `Canopy.app` and relaunches. Test that step too; it's cheap to do and nothing depends on the path (TCC and Keychain follow bundle ID and signature).
   - Not verified here: mic permission and Keychain survival. Both depend only on the bundle ID and signing identity, which don't change. Confirm on the real build in Phase 2.
2. **Bridge for current Canopy installs: no custom installer needed.** A running app with Canopy's bundle ID updated in place to an app with a different bundle ID (Transcriber's). Sparkle finds the new app in the zip by file name, so the new build must be named `Canopy.app` inside the zip. Both apps already share the same EdDSA key, so the signature check passes.
   - So the bridge is a normal Canopy release: publish the merged app as the final update on Canopy's existing appcast (`github.com/iamanthonyterry/Canopy/releases/latest/download/appcast.xml`). The merged app then follows Transcriber's feed.
   - Still to check on the real apps in Phase 4: the nested Transcriber helper and its login item inside old Canopy get replaced or orphaned cleanly. The first-launch cleanup handles any leftovers.
3. **Coupling: light.** The workflow engine uses `WorkflowCheckpointStore`, `ConversionSlotLimiter`, `SchedulerService`, `AppState` (4 uses, mainly device lookup), `ExportQueueManager` (1 use, the `queueClips` step) and `SocialPostExporter` (the `exportPosts` step, which we keep). Cutting the export queue means deleting that one step. The Dashboard mentions in the engine are comments.
4. **Whisper overlap: small.** Both apps already load Whisper models from the shared model folder (`SharedModelFolder` in the kit). Canopy picks a variant in its own settings (default "accurate"); Transcriber uses the turbo variant. Merge to one model manager and one setting.
   - **When removing the kit (Phase 2, item 6), keep `SharedModelFolder` and `LegacyMigration`** and drop only `ChurchKitAuth`, `HelperHandoff` and `HelperStatus`.
5. **Mac mini macOS: 26 or later (confirmed).** The app can require macOS 26, matching Canopy, so `FoundationModels` and Liquid Glass need no `#available` gating. Raise the minimum from 14 to 26 in the merged app. Any Mac still on an older macOS stays on its last Transcriber update (add `sparkle:minimumSystemVersion` 26 to the appcast so Sparkle skips it instead of failing).

Exit: bundle ID, build base and update path confirmed. The build base is still undecided; Phase 2 starts by choosing between adding Transcriber's code to Canopy's Xcode project or porting the workflow core into the SwiftPM package.

## Phase 1: website prerequisites (landing page repo)

1. Add key-authenticated routes for run progress (replacing the direct `workflow_runs` writes) and a heartbeat the dashboard can read.
2. Reach inventory parity with what Canopy does that the site doesn't: console patch PDFs, document and patch import, batch device add, CSV backup. Decide the fate of LAN-only features (device discovery, connection monitoring, wireless probing): drop them, or have the Mac report status up.
3. Keep `canopy_keys` and the `/auth/canopy` pages until Phase 6.

Exit: you can run the whole inventory from the website with the Canopy app closed.

## Phase 2: core merge

### Build-base test (done)

Canopy's project builds in Swift 6 mode with the main thread as the default for everything; Transcriber is Swift 5 mode with no default. Mixed settings in one module aren't possible, so one codebase has to be converted. I dropped Transcriber's 21 source files into a scratch copy of Canopy and built it.

- **62 distinct compile errors, none that block the approach.**
  - About 40 are Swift concurrency errors in Transcriber's own files, mainly `PCO.swift` (14), `OSC.swift` (9), `FileTest.swift` (9), `SpeechEngine.swift` (6) and `DeviceAgent.swift`, `MIDI.swift`. They are fixed by marking the right types `nonisolated`, and none need a redesign.
  - The rest come from four duplicate names: `MIDIMessage`, `Videohub`, `AllenHeath`, `SettingsView`. The errors that show up in Canopy's own files (`RemoteControl.swift`, `MIDICodec.swift`, `DeviceDrivers.swift`) are only these collisions.
- **More errors will appear** once these are fixed, because the compiler reports in stages. Treat this as a floor, not a total.
- **Runtime risk is bigger than compile risk.** Audio capture and speech run on real-time threads; after converting, they must stay off the main thread. Re-test live transcription on a real input, not just the build.
- **Duplicates to merge, not just rename:** Canopy's `OSCCodec`/`MIDICodec` and Transcriber's `OSC`/`MIDI`; Canopy's `DeviceDrivers` (Videohub, Allen & Heath) and Transcriber's `DeviceAgent` drivers. Do this at the end of this phase, keeping the existing MIDI source name and OSC addresses (Phase 5).
- **App shell differences to fix:** Canopy has no `LSUIElement` (it shows in the Dock), no microphone permission text and no audio-input entitlement. Add all three. Keep Canopy's Bonjour list for device discovery.
- **Order of work:** (1) move the files in, rename the four clashing types, make it build; (2) make the menu-bar app the only entry point; (3) test live transcription; (4) merge the duplicate OSC/MIDI/driver code.

1. Work in a branch of the Canopy repo. Set the bundle ID to Transcriber's (`com.rosesashumans.churchlandingpage.transcriber`), the Sparkle feed to Transcriber's, and keep the tree icon. The app name stays Canopy.
2. Move Transcriber's sources into the project (see the build-base test above), make the menu-bar app the entry point, and set `LSUIElement`, the microphone text and the audio-input entitlement.
3. Remove from Canopy what you don't need: the dashboard, inventory (all `Inventory*` views and store), starred items, social share screen, export queue and the `queueClips` step. Keep what the workflow steps use: `exportPosts`, `reframe`, `writeCopy` and `findClips` need the exporter, caption and clip-finder code, so only their screens go.
4. Add a small **Devices** page in settings for HyperDecks, Cloud Stores and folders (workflows still need targets), with Canopy's existing add and discovery code.
5. Merge the two Whisper setups into one model manager and one shared model folder.
6. Move the sign-in into the app. Pull `LegacyMigration` out of the kit first; it is needed in Phase 4. Then drop the kit dependency.
7. **Resource rules.** Heavy steps (transcribe, convert, offload) wait while live listening is active, or run at lowest priority. Sparkle installs wait while a workflow is running or the app is listening, extending the current "install when stopped" rule.
8. **Crash safety.** Make sure an interrupted run resumes from its checkpoint after a relaunch.

Exit: workflows run from inside the new app on a dev Mac and report progress to the site; captions are unaffected.

## Phase 3: menu bar and settings

1. Rename **Website settings** to **Settings**.
2. Add a **Workflows** section in the menu with every workflow, a Run action, and live status with pause and stop.
3. Settings gets a **Workflows** page holding the builder, step config and AI assistant. Open it in a resizable window, since the default settings window is too small for the builder. Handle `LSUIElement` window activation.
4. Manual-confirm steps surface as a notification plus a floating panel.
5. Keep run history and the failure and device-offline alerts (decide whether to keep Show Mode, roles and email notifications; default is to keep email, drop Show Mode and roles).
6. The device-push helper (`DeviceAgent`) already exists; keep it working and add it to the menu status.

## Phase 4: updates and first-launch migration (built; not yet run on real installs)

Built in the canopy repo on `merge-transcriber`:

1. **Mac mini path:** a normal in-place Sparkle update (proved in Phase 0). The Planning Center credentials must be in the release build (`release.sh` now passes them from `../transcriber/Support/pco.env`), or Planning Center scheduling silently stops after the update.
2. **Canopy users:** `release.sh` writes an appcast for each repo from the same zip. Publishing the `appcast-Canopy` one on iamanthonyterry/Canopy moves old Canopy installs into this app (proved in Phase 0 with stand-in apps).
3. **First launch (`CanopyMigration`, `FirstLaunch`):** copies Canopy's settings from `com.rosesashumans.churchlandingpage.canopy` once, skipping Sparkle/system keys and settings of removed screens, never overwriting what is already there; drops the old built-in helper's login item; offers to move a leftover old Canopy.app in /Applications to the Trash; asks once about opening at login (the old helper did that silently).
4. **Rename (`SelfRename`):** an install that updated in place from Transcriber.app moves to Canopy.app once nothing is being transcribed.
5. **Keychain:** nothing to copy, because the service name is unchanged. macOS asks once to let this app use the website sign-in the old app saved ("Always Allow").

Not done / to check on real Macs:
- Interrupted-run checkpoints from the old app are not carried (their step numbers may no longer match); they are simply gone.
- Run the whole path once on a Mac with the real old Canopy and a real old Transcriber before publishing.
- Canopy's CI release workflow (`.github/workflows/release.yml`) publishes to the Canopy repo whenever main gets a new version, and builds the appcast URLs from the app's own feed (now the transcriber repo). Update it before merging to main, or it will publish a release with the wrong download addresses.

## Phase 5: triggers and DAW control


**Status (non-DAW part): built** in the canopy repo, `merge-transcriber`. `ControlBus` is the single place OSC and MIDI arrive; OSC, MIDI and Voice Cue are workflow triggers with editors in the builder; `/canopy/…` works like `/transcriber/…`. Checked end to end with real UDP packets. Not done: a `Canopy` MIDI source alias (only the existing "Transcriber" source exists), and the DAW steps below, which are deferred.
1. One OSC listener and one MIDI listener, routed to both the voice cue system and workflow triggers.
2. New workflow triggers: **OSC message**, **MIDI message**, and **voice cue** (cheap, since the cue engine exists).
3. Keep the existing MIDI source name "Transcriber" and `/transcriber/...` OSC addresses working; add `Canopy` and `/canopy/...` as aliases.
4. **DAW steps: Pro Tools first, Ableton second.** The Pro Tools backend ships first; Ableton follows once Pro Tools is working. Deferred for now: the Pro Tools feasibility spike (Pro Tools scripting API, then Accessibility preset recall) comes first when this phase starts, and must run on a Mac with Pro Tools installed (this development Mac has Ableton Live 12 Suite but no Pro Tools). Required actions: **play, pause, record arm, change plugin preset**. One "DAW" step type with a per-DAW backend, so a workflow reads the same for both.
   - **Ableton Live:** use the community AbletonOSC remote script (the user installs it once into Live's MIDI Remote Scripts folder; the app can copy it in and check it's running). Play, stop and record arm are covered. **Presets are the weak spot:** Live's scripting API doesn't list or load a third-party plugin's presets. Options, in order of preference: (a) Live's own devices: load the preset from the browser; (b) for VST/AU plugins: map the plugin's preset or program parameter if the plugin exposes it; (c) put each preset in an Instrument or Audio Effect Rack and have the step pick the chain by its selector value. **verify** against the plugins you actually use.
   - **Pro Tools:** Avid's PTSL scripting API (gRPC, Pro Tools 2022.12 or later) is needed, because HUI over MIDI only gives transport, not record arm per track or presets. It covers transport and track record-enable. **Plugin presets are not something I can confirm PTSL does**; if it doesn't, the fallbacks are keyboard shortcuts or macOS UI scripting (fragile, needs Accessibility permission and the plugin window in a known state), or Pro Tools' own preset-recall shortcuts. **verify**
   - **SoundFlow-style approach (chosen model).** As I understand SoundFlow, it drives the DAW the way a person would: it controls the app's windows and menus through macOS Accessibility, with the DAW's own scripting API where one exists, and addresses things by name ("track Pastor, insert B, preset Warm Voice"). Do the same here:
     - **Accessibility automation** (needs the Accessibility permission, granted once) opens the plugin window, opens the preset menu in its header, and picks the preset by name. In Pro Tools every plugin window has the same Avid-drawn header with a preset/settings menu, which is why this works reliably there. A preset browser inside a plugin's own custom UI is not reliable, so those plugins are listed as unsupported.
     - **Targets by name, not position.** A step stores track name, insert slot, plugin name and preset name. Where the DAW can report them (PTSL lists tracks), the step offers pickers; otherwise the user types the names.
     - **Check after acting.** After switching, read the preset name back from the header and fail the step if it doesn't match, so a workflow never silently leaves the wrong preset on.
     - **Safe to run at service time.** Steps bring the plugin window forward and close it again, restore the previously frontmost app, and time out with a clear error rather than clicking blindly.
     - **Ableton** has no standard plugin header, so presets there still use the rack-chain approach above, or the plugin's own menu via Accessibility where it has one. Pro Tools is the DAW this model fits best; confirm which one you use more.
   - **Pause vs stop:** Ableton has no true pause (stop keeps the position); Pro Tools treats pause as its own transport state. The step offers Play, Pause and Stop, and each backend maps them as closely as it can.

## Phase 6: website cleanup and download

1. Remove Canopy from `lib/apps.ts`, `lib/tools.ts`, the hub "Install Canopy" step, the `/auth/canopy` pages, `wants.ts`, README, workflows page copy, and the `canopy_keys` migration once no old app needs it.
2. Replace the two download cards with one **Canopy** card, shown only to people with access. If the files must not be public, serve them through a signed route.
3. Keep the live workflow progress page; remove the remote-run and start/stop options.
4. Retire the Canopy repo (archive it) and the Transcriber download card. Don't reuse the old repo name.

## Risks to watch

- Older Macs left behind by the macOS 26 minimum (they keep their last Transcriber build).
- Heavy workflows starving live captions during a service.
- A workflow crash taking captions down.
- Existing QLab, Companion or DAW mappings breaking if names change.
- A password prompt on the Mac mini from Keychain migration; migrate only on the Canopy side, never touch the mini's existing key.
