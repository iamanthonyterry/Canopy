# Upgrade test plan: old Canopy and Transcriber to the merged Canopy

Goal: prove, on real Macs, that people who have the old apps end up with one working Canopy, with their settings, sign-in and login behavior intact, and that a Mac running live captions is never broken by the update.

Everything in the merged app has been built and checked with stand-in apps, real UDP packets and rendered pages. What has **not** been run is a real upgrade of a real install. That is what this plan does.

## What must be true at the end

1. The Mac mini (Transcriber only) updates itself, comes back listening, and nothing needs a person at the keyboard.
2. A Mac with the old Canopy ends up with Canopy's workflows, devices, schedules and history in the new app.
3. Nobody is left with two copies running the same workflows, or a login item that opens an old app.
4. Nothing was lost that can't be restored from the backup you took first.

## Before you start (do not skip)

- **Use a spare Mac, a second user account, or a Mac you can afford to break first.** Do the mini last, and only when no service is coming up.
- **Back up each Mac you test on.** For every Mac:

  ```bash
  mkdir -p ~/Desktop/canopy-upgrade-backup && cd ~/Desktop/canopy-upgrade-backup
  defaults export com.rosesashumans.churchlandingpage.canopy canopy-defaults.plist
  defaults export com.rosesashumans.churchlandingpage.transcriber transcriber-defaults.plist
  ditto /Applications/Canopy.app Canopy.app.backup          # if installed
  ditto /Applications/Transcriber.app Transcriber.app.backup  # if installed
  ```

  Also copy `~/Library/Application Support/Church Landing Page/` and `~/Library/Application Support/Transcriber/` (the speech models are in there, a few hundred MB). Keychain items can't be copied out safely: note that the **website sign-in** (Canopy) and the **campus key** (Transcriber) are in the Keychain, and know where to get both again (the website's Sign in, and the campus key on the site).
- **Write down what each Mac looks like now**, so you can compare afterwards: the list of workflows and their triggers, devices (names and IPs), the campus the transcriber sends to, the schedule, the OSC port setting, any voice cues, and whether each app opens at login.
- **Have the build ready** (see "Making the release candidate"). Version it above 2.7.0, for example `3.0.0`.

## Making the release candidate

Do this on a scratch copy of the `canopy` repo or a throwaway branch: `release.sh` edits the version in the project file.

1. Check `../transcriber/Support/pco.env` exists. Without it the build has **no Planning Center credentials** and Planning Center scheduling silently stops after the update.
2. `STOP_BEFORE_NOTARIZE=1 ./release.sh 3.0.0` builds and signs without notarizing, so you can inspect it. Then run it without that switch to notarize and produce the two update feeds.
3. Inspect the result:
   - `codesign --verify --deep --strict build/export/Canopy.app` passes, and `spctl --assess --type execute -v` says accepted (after notarizing).
   - `codesign -d --entitlements :- build/export/Canopy.app` lists `com.apple.security.device.audio-input`.
   - In its Info.plist: bundle id `com.rosesashumans.churchlandingpage.transcriber`, `LSUIElement` true, `NSMicrophoneUsageDescription` present, `SUFeedURL` pointing at the **transcriber** repo, `PCOClientID` not empty.
   - `CFBundleVersion` is a date-style number (it must be larger than any earlier Transcriber or Canopy build, or Sparkle won't offer the update).
4. Check the two update zips `release.sh` makes. They are **named differently on purpose**: Sparkle finds the new app inside the zip by the installed app's file name or bundle id. The transcriber feed's zip must contain `Transcriber.app` (installs there are called that, and some still have Transcriber's earlier bundle id, which only the file name can match); the Canopy feed's zip must contain `Canopy.app`. `unzip -l build/appcast-transcriber/*.zip | head` and the same for `appcast-Canopy` should show exactly that.
5. **Do not publish yet.** For the update tests below, serve the feed from your own Mac (see "Trying a real Sparkle update without publishing").

## Trying a real Sparkle update without publishing

The installed old apps point at GitHub. To exercise the real update path without releasing anything:

1. Make a **copy** of the old app you want to test (`ditto`), edit the copy's `SUFeedURL` in `Contents/Info.plist` to `http://localhost:8765/appcast.xml`, add `NSAppTransportSecurity > NSAllowsLocalNetworking = true`, and re-sign it with your Developer ID (`codesign -f -s <identity> -o runtime --deep`). The Sparkle signing key is unchanged, so the update still verifies.
2. Put the release candidate's zip and an appcast whose download address is `http://localhost:8765/...` in a folder and serve it with `python3 -m http.server 8765`. Generate the appcast with `generate_appcast --download-url-prefix http://localhost:8765/ <folder>`.
3. Launch the edited copy, choose Check for Updates, and let it install.

Phase 0 proved this works with stand-in apps, including a different bundle id and a renamed file. This repeats it with the real ones.

## Scenarios

For each: do the steps, then tick the checks. Write down anything surprising even if it isn't on the list.

### A. The Mac mini: Transcriber only

**First check which Transcriber you have:** `/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleShortVersionString" /Applications/Transcriber.app/Contents/Info.plist`. Builds before 2.7.0 (for example the 2.5.1 on this development Mac) have the **earlier** bundle id `church.lifepoint.transcriber`. The merged app uses `com.rosesashumans.churchlandingpage.transcriber`, so a Mac on an older id gets a fresh microphone permission and one Keychain prompt (the campus key is carried across, but the new app has to be allowed to read the old item). That is fine at a keyboard and a stuck dialog on an unattended Mac. **Update the mini to 2.7.0 or later first, and confirm it is back to listening, before the merged update.**

Setup: a Mac with only the standalone Transcriber 2.7.0 or later, set up as it runs on Sundays: signed in to a campus, start-at-launch on, open at login on, a schedule, a mic input, voice cues if you use them, an OSC port if a cue list uses it.

Steps:
1. Note the current state (listening, campus, schedule, version 2.7.0). Check which file name it has in Applications.
2. Update to the candidate (real Sparkle path above, or replace the app file by hand to see only the first-launch logic).
3. Let it relaunch.

Check:
- [ ] It comes back and **starts listening by itself**, to the same campus, with no prompt on screen.
- [ ] **No Keychain prompt, no microphone prompt, no "allow" dialog of any kind.** (The campus key and mic permission belong to the bundle id, which didn't change. A prompt here is a failure on an unattended Mac.)
- [ ] The menu shows the new version; the window says **Settings** (not "Website settings").
- [ ] Settings kept: inputs and channels, corrections, names and terms, schedule or Planning Center, translations, save folder, OSC port and voice cues.
- [ ] Planning Center still works (Refresh times).
- [ ] A transcript line reaches the live page for the campus.
- [ ] `/transcriber/start`, `/transcriber/stop` and the new `/canopy/start` all work from your cue list or a test sender. A MIDI cue still shows up on the "Transcriber" MIDI source.
- [ ] An "Apply to device" job queued on the website is carried out.
- [ ] The app **did not rename itself while listening**. After you stop it (or between scheduled windows) and wait about ten seconds, it renames itself to `Canopy.app` and reopens, and starts listening again if start-at-launch is on.
- [ ] After a restart of the Mac, it opens at login and listens.
- [ ] Sparkle does not interrupt a live session: with it listening, an available update waits.

### B. A Mac with the old Canopy (with its built-in Transcriber helper)

Setup: old Canopy (0.0.5x) with workflows, a few devices (a HyperDeck, network storage, a local folder), a daily schedule, signed in to the website, the built-in Transcriber helper set to open at login, AI model downloaded if you use it.

Steps: update it with the candidate (Canopy's feed path), let it relaunch, and answer the prompts as a normal person would.

Check:
- [ ] Sparkle replaces the app in place; the app opens as the menu-bar app (no window, no Dock icon).
- [ ] **Workflows, devices, schedules and run history are there** in Settings → Workflows and Devices. Compare with your written list. Triggers still show correctly, with their schedule times.
- [ ] A workflow that **had a Queue Clips step** loads without that step and with the other steps in order.
- [ ] Alerts, email, performance, AI model and OSC/MIDI mapping choices are kept (Settings → More).
- [ ] You are asked **once** "Open Canopy when you log in?" and choosing Open at Login really adds it (check System Settings → General → Login Items).
- [ ] The **old helper's login item is gone** from Login Items, or at least doesn't launch anything.
- [ ] macOS asks **once** to let the app use the saved website sign-in ("Always Allow"); after that, no more prompts. The website sign-in still works: progress shows on the website's Workflows page.
- [ ] Run a workflow end to end on a folder, then a scheduled one. Stop it from the menu. Check the Workflows part of the menu: Run, Stop, Retry Failed.
- [ ] Force-quit during a run and relaunch: the menu offers Resume or Discard.
- [ ] Describe It (the AI builder) still produces a draft.
- [ ] Add an OSC trigger and a MIDI trigger to a test workflow, use "Listen for the Next Message", and fire them. Add a Voice Cue trigger and say the phrase on an input with Trigger OSC on.

### Campus connection checks (do these on B and C, and once on A)

The app no longer signs a person in; it uses the campus key (Settings → Transcription → Website). Workflow progress, the shared workflow list and workflow email all depend on it, so test them with a real campus. **The website must be updated first**: apply `20261114_campus_workflows_and_notify.sql`, set the `RESEND_API_KEY` secret on the Worker, deploy, then publish the app update.
- [ ] A Mac that was only signed in to the old Canopy (no campus key) shows "Not connected" in Settings → More → Website and in the Notification step. After you connect it under Transcription → Website, those messages go away.
- [ ] **Run progress:** run a workflow; the website's Workflows page shows it live, and shows it finished. Quit the app mid-run and relaunch: the website marks the old run stopped.
- [ ] **Sync across Macs:** with two Macs on the same campus, a workflow edited on one shows up on the other within about a minute; a workflow deleted on one disappears from the other; editing the same workflow on both before either syncs leaves the website's version plus a "(this Mac)" copy.
- [ ] **Email:** a workflow with a Notification step delivers (check the inbox and the sender, canopy@send.rosesashumans.com). Replies no longer go to the person who ran it. Sending more than 40 recipients in an hour is refused with a clear message.
- [ ] Regenerating the campus key on the website and reconnecting does not duplicate every workflow.
- [ ] A Mac on the old (pre-merge) Canopy keeps working against the updated website until it updates.

### C. A Mac with both the old Canopy and the standalone Transcriber (the likeliest real case)

Setup: old Canopy.app **and** standalone Transcriber.app in Applications, as many of your Macs have them.

Both apps update to the same app (same bundle id), one in place at `Canopy.app` and one at `Transcriber.app`, so the Mac ends up with two copies. The first launch now looks for another copy of itself in `/Applications` and `~/Applications` (one folder deep, by each app's own bundle id) and asks: **"Another copy of Canopy is installed … Quit and Move to Trash / Keep Both."**

Steps: update both, then launch each.

Check:
- [ ] The copy you launch first offers to quit and trash the other. Choosing **Quit and Move to Trash** quits the other if it is running, moves it to the Trash, and leaves the one you launched.
- [ ] **Open at login survives.** It belongs to the bundle id, so check System Settings → General → Login Items still lists Canopy once, and that it opens after a restart.
- [ ] If the copy that stayed is `Transcriber.app`, it renames itself to `Canopy.app` on a **later** launch once idle (the other one is gone from Applications by then).
- [ ] **Keep Both** is remembered: relaunching does not ask again about those same copies.
- [ ] If both copies are open at once (launched by hand), say what happens to the microphone and to a scheduled workflow. This should not be left like this, which is the point of the prompt.
- [ ] The separate prompt about moving the **old Canopy** to the Trash does not appear (neither copy is the old one any more).

### D. A clean Mac (or a new user account)

Steps: download the candidate, unzip, drag to Applications, open it.

Check:
- [ ] Opens with no right-click workaround (notarized and stapled).
- [ ] No migration happens, and no upgrade prompts: no "move the old Canopy" question, no "open at login" question.
- [ ] Settings → Transcription signs in with the website; the mic prompt appears the first time you listen and works after Allow.
- [ ] Add a device and a workflow from scratch.

### E. An older macOS

The merged app needs macOS 26. On a Mac still on an older macOS:
- [ ] The existing Transcriber is **not** offered the update (nothing breaks, and it keeps working). This only holds if the update feed says the new version needs macOS 26. Check the feed: the item should carry a minimum system version of 26. If it doesn't, add it before publishing.

## Also try, once

- **Rollback.** On a test Mac, put the backed-up `Transcriber.app` (or `Canopy.app`) back and import the backed-up settings (`defaults import <domain> <file>`). The old app should open as before. Note that the Keychain items are shared, so the old app still signs in.
- **The release script on its own.** Run it once end to end and confirm the two feed folders are produced: one with download addresses for the `transcriber` repo, one for the `Canopy` repo.
- **The GitHub release workflow.** It publishes a release on the Canopy repo whenever `main` gets a new version, and builds download addresses from the app's own feed (now the transcriber repo). Before merging this work to `main`, change it or turn it off, otherwise it will publish a release with wrong download addresses.

## Stop conditions

Stop the rollout and fix first if you see any of these:
- A prompt of any kind on the unattended Mac mini.
- The mini doesn't come back listening on its own.
- Workflows or devices missing after upgrading the old Canopy.
- Two copies of the app running on one Mac.
- Planning Center no longer connecting.
- An update offered to a Mac that can't run it.

## Order I would do it in

1. Build the candidate; inspect it (checks above).
2. Scenario D on a clean account (fastest, nothing to lose).
3. Scenario B on a Mac or account with a copy of the old Canopy's data.
4. Scenario C, to decide whether the duplicate-copy fix is needed.
5. Scenario A on a spare Mac set up like the mini.
6. The real mini, on a quiet weekday, with someone able to walk to it.
7. Only then publish: the `transcriber` feed first, then (once) the `Canopy` feed.
