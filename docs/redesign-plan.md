# Canopy: inventory, connection map and live wireless — redesign plan

Decisions: phased rollout; the interactive system map is the centre of the UI; wireless brands are Shure, Sennheiser and Audio-Technica.

## Where things stand
- Inventory (`Views/Inventory*.swift`, `Support/InventoryStore.swift`, `Models/Inventory.swift`) has nine tabs and keeps its data in Supabase: equipment, ports, cards, cables, stage-box links, console channels, rooms and racks.
- `InventorySystemMap.swift` draws a read-only graph.
- `DashboardView` only knows HyperDecks, Cloud Stores and local folders (`AppState`), polled by `ConnectionMonitor`. It has no link to the inventory `Equipment` model.
- Wireless has no model of its own. A mic receiver is just an `Equipment` row with an IP address.

## Phase 1 — One device model, interactive map
1. Make `Equipment` the single source of truth. Dashboard tiles (HyperDeck, Cloud Store and the rest) become views over inventory devices that carry a "driver" (`DeviceDriver.detect` already exists). Existing decks and stores are migrated by matching host.
2. Rebuild System Map as the home of Inventory:
   - drag from port to port to create a cable (`store.patch`);
   - click a device to open a side inspector with ports, card slots, status, notes, service history and live data;
   - filter by signal type, room or campus;
   - group by room and rack;
   - keep the existing Patch Sheet, Console Patch, Signal Flow, Rooms and Review tabs as supporting views.
3. Add a path trace: select a mic or channel and highlight its full chain (the `SignalChain` logic already exists).

## Phase 2 — Live wireless on the dashboard
- Add a `WirelessDevice` role and a `WirelessMonitor` service next to `ConnectionMonitor`. Each receiver or transmitter-dock model plugs in as a driver that publishes a common `WirelessChannelState`: RF level, antenna A/B, audio level, battery, frequency, mute and status. IEM transmitters report a similar state.
- Dashboard gets a wireless strip: one card per channel with RF and audio meters, battery and frequency. A channel's name and room come from inventory. Alerts (low battery, RF dropout) go through the existing `AlertingService`.
- Drivers, in this order:
  1. Shure: TCP 2202 command and metering protocol (ULX-D, QLX-D, Axient Digital, PSM).
  2. Sennheiser: SSC over UDP (EW-DX, Digital 6000/9000).
  3. Audio-Technica: network control protocol for the 3000/5000 series.
- Only the listed models and a small, checked set of read-only commands are used. Devices must be on a local address, as `isLocalAddress` already enforces. No credentials are stored beyond what inventory already holds.
- I will check each protocol against the maker's published documentation before writing its driver. I won't write one from memory. I also need your actual models and firmware, and ideally access to a receiver for testing.

## Phase 3 — Polish and mapping depth
- Record which wireless channel feeds which console channel, so a dropout on the map shows what it affects.
- Wireless coverage and frequency view per room, and a frequency-conflict check.
- Spares and loan tracking, and a battery and service history for transmitters.

## Open items for you
- Exact wireless models and firmware (for the drivers).
- Whether one network segment reaches all receivers, or whether some sit on separate VLANs.
- Whether the Supabase schema may change. Phase 1 migration matching decks to equipment needs a new column or table.
