# Canopy

Canopy is a macOS app for organizing and syncing media across record decks
and storage. It manages Blackmagic HyperDecks and Blackmagic Cloud Stores on
the local network, automates pulling footage off them, converts and renames
it, and keeps it backed up to a shared destination — so a production's
recordings end up organized on shared storage without anyone manually
copying files off a deck.

## What it does

- **Device management** — discover and add HyperDecks (via Bonjour/network
  scan or manually) and Blackmagic Cloud Stores, monitor their reachability,
  login, and drive/media status in real time, and browse and preview files
  on them directly from the app.
- **Workflows** — build multi-step automations per HyperDeck or set of
  HyperDecks: start/stop recording, wait, sync (download new files), convert
  (transcode to MP4 at a chosen quality preset), rename (with tokens like
  device name, date, and file index), format a drive, clean up old files on
  the destination, and send an email notification. Steps can require manual
  confirmation before continuing, and workflows can target specific decks or
  all configured ones.
- **Scheduling** — any workflow can run automatically on a daily recurring
  schedule (optionally limited to specific weekdays) or at a one-time date
  and time, with no one needing to trigger it by hand.
- **Sync destination** — a shared SMB volume (e.g. a Blackmagic Cloud Store)
  that workflows sync footage to, organized under a configurable base path.
- **Remote control** — an OSC and MIDI listener lets external control
  surfaces (TouchOSC, Companion, a MIDI controller, etc.) trigger HyperDeck
  record/stop/format actions, either through user-defined mappings or a
  built-in zero-configuration OSC address scheme.
- **Alerting & notifications** — get an immediate system notification (and
  optionally an email) if a recording or in-progress device goes offline,
  loses its login, or loses its drive — not just a passive status badge.
- **Show Mode** — a simplified, large-text status view meant for a second
  monitor during a live event: device health and active recordings at a
  glance, nothing else.
- **History** — a searchable log of past workflow runs, including what was
  processed, errors, and duration.
- **Roles** — an Admin mode with full access to devices, workflows, and
  settings, and a restricted Content Manager mode for operators who should
  only view and pull clips, not change configuration.

## Requirements

- macOS
- Network access to the HyperDecks and Cloud Store(s) being managed

## Project structure

- `Canopy/Models/` — persisted app state and data types (devices, workflows,
  remote-control mappings, settings)
- `Canopy/Support/` — services that do the actual work (FTP/SMB transfer,
  conversion, connection monitoring, discovery, scheduling, alerting,
  remote control listeners, email)
- `Canopy/Views/` — SwiftUI views for the dashboard, workflow editor,
  history, settings, and Show Mode

Built with SwiftUI, uses Sparkle for auto-updates.
