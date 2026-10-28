# Breezer — iOS app for the Tion Breezer 4S

An unofficial iPhone app that talks to a Tion Breezer 4S over Bluetooth. It speaks the same
protocol as the official Tion Remote app, cross-checked against
[dentra/esphome-tion](https://github.com/dentra/esphome-tion).

Not affiliated with or endorsed by Tion. Use at your own risk.

**What it adds over the Android app**

- **Schedules with several on/off events, up to 6.** For example: on 04:00, off 07:00,
  on 22:00, off 02:00, each with its own days. They're stored in the breezer, so it follows them
  with the phone off or away.
- **Every reading the breezer reports**, including values the Android app receives but doesn't show:
  - control-board and power-board temperatures
  - powered-on time and fan run time
  - total air moved
  - live airflow estimate (m³/h)
  - heater rating and load
  - a raw byte view and Bluetooth log
- A temperature history chart (outdoor and supply air), recorded while the app is open.

## Screens

| Tab | Contents |
|---|---|
| Status | Power, outdoor, supply and target temperatures, fan and airflow, heater, intake, history chart, filter life, errors and warnings, totals |
| Control | Power, fan speed, intake, heater and target temperature, turbo (1–20 min), sound and light, filter-counter reset, error clear |
| Schedule | Week timeline, list of events, add a turn-on event, turn-off event or on/off period, Save to breezer |
| Device | Firmware, clock offset and sync, last state packet byte by byte, Bluetooth log, forget device |

## Building

You need an iPhone running iOS 17 or later. Choose whichever option fits.

### Option A: with a Mac

1. `brew install xcodegen`
2. In this folder, run `xcodegen generate` and open `TionBreezer.xcodeproj`.
3. Select the TionBreezer target › Signing & Capabilities, and choose your Apple ID team.
   Change the bundle id if Xcode asks.
4. Plug in the iPhone and press Run. On the phone, trust the developer under
   Settings › General › VPN & Device Management.

### Option B: no Mac (GitHub Actions + Sideloadly on Windows)

1. Push this folder to a GitHub repository. Private is fine.
2. The **Build** workflow runs on every push. It runs the TionKit unit tests, builds an unsigned
   app, and uploads `TionBreezer-ipa` as an artifact. Download it from the run's page and unzip it
   to get `TionBreezer.ipa`.
3. Open **Sideloadly** on Windows. Plug in the iPhone, drop in the IPA, enter your Apple ID and
   press Start.
4. On the iPhone:
   - Enable Settings › Privacy & Security › Developer Mode.
   - Trust the profile under Settings › General › VPN & Device Management.

With a free Apple ID the app must be re-signed every 7 days. Sideloadly can do this automatically
while the phone is on the same Wi-Fi. A paid developer account extends that to a year.

## First connection

1. Close the Tion Remote app on other phones. The breezer accepts one connection at a time.
2. The breezer must be in standby (yellow light). Hold its button until the light flashes blue.
3. In the app, tap the breezer marked **Ready to pair**, then confirm the iOS pairing prompt.

After that the app reconnects by itself whenever the breezer is in range.

## How schedules work

The 4S has 12 timer slots. Each slot holds:

- days of the week
- a time
- an action: turn on with a fan speed, intake, heater and target temperature, or turn off
- an enabled flag

The breezer runs the schedule by itself, but its firmware has some limits, and the app works
within them:

- **Up to 6 events.** The slots work in pairs. When the first slot of a pair fires, the breezer
  overwrites the second with the settings from just before it fired. The second slot then runs
  only if nothing has changed since. So the app gives every event the first slot of a pair and
  leaves the second empty. A schedule saved by an earlier version of this app is rewritten the
  next time you save.
- **No timers on Sundays.** The breezer's clock reports Sunday as a day its firmware can't
  handle, so nothing runs on Sundays. Worse, an event due on a Sunday stops the whole schedule
  until the clock is next set. The app therefore doesn't offer Sunday. On Sundays the breezer
  stays as Saturday's last event left it.
- **One event per minute.** If two events fall in the same minute, only one runs, so the app asks
  you to change one.
- **Events fire at the start of their minute.** One saved for the current minute waits until its
  next day.

When you tap **Save to breezer**, the app follows the same sequence as the Tion app:

1. Set the breezer's clock.
2. Mute its beeper.
3. Write each changed slot, about one per second.
4. Restore your settings.
5. Read every slot back to confirm it was stored.

Periods that cross midnight (22:00 → 02:00) put the turn-off on the following day automatically.
Saturday's period can't end on Sunday, so it lasts until the next turn-off.

The breezer's clock runs on local time. The app sets it every time it connects, which also restarts
a stalled schedule. It skips this on Sundays: a clock set on a Sunday makes the breezer skip
Monday's events. Saving on a Sunday still sets it, so open the app once on the Monday after.

Timers need firmware 0050 or newer, the same limit the Tion app applies.

## Protocol notes

The packet format, frame types and byte layouts are documented in the code:

- `Packages/TionKit/Sources/TionKit/Packet.swift`: framing, CRC and frame types
- `BreezerState.swift`: the 31-byte state, device info, turbo and clock
- `Schedule.swift`: timer slots and the week timeline

The tests in `Packages/TionKit/Tests` check the encoder against packets as the Tion Remote app
builds them.

## Not included

MagicAir cloud, firmware updates, and other Tion models (3S, Lite, IQ).
