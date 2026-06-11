<<<<<<< HEAD
# Hive-Mac
Hive application for Mac built in AppleScript that supports Peer-to-Peer connection as well as vs Computer. Working on game analysis and strengthening the computer opponents.
=======
# Hive — peer-to-peer for two Macs

A native macOS app for playing the board game **Hive** head-to-head between two
Macs, on the same network or across the internet, with no game server.

## Features

- **Full rules engine** — queen, ants, spiders, beetles, grasshoppers, with the
  one-hive rule, freedom-to-move (gate) sliding, beetle climbing/stacking,
  forced queen by the 4th placement (tournament opening: no queen first), pass
  turns, win/draw detection.
- **Classic or Full game** — Full adds the **Ladybug**, **Mosquito**, and
  **Pillbug** (including throw immunity rules).
- **Create / join games** with options for **turn length** (untimed, 30s, 1m,
  2m, 5m — timeout plays a random legal move), **first player** (White, Black,
  or Random), and Classic/Full. **The lobby creator always plays White.**
- **GamePigeon-style profiles** — name, avatar emoji, accent color; editable
  any time from the main menu.
- **Stats** — overall wins/losses/draws plus a head-to-head record against
  every opponent you've played (tracked by their profile identity).
- **Rematch** from the game-over screen — colors swap each rematch (and
  Random first-move is re-rolled).
- **Single-player vs. a bot** — three difficulties; wins count in your stats.
- **Move list & notation panel** (standard UHP-style notation), last-move
  arrow and highlights on the board.
- **Game history with replays** — every finished game is saved; step through
  it move by move from the History screen.
- **Reconnect after a drop** — if the connection dies mid-game, both apps
  derive a private resume code from the original session and hole-punch a
  fresh link; the host re-syncs the position and play continues.
- **Drag pieces** (or tap-select-tap), **pan/zoom** the board for big games,
  **four app themes**, and **sound effects** (toggle in the profile editor).

## Building

```sh
./make-app.sh        # builds release binary and produces Hive.app
open Hive.app
```

Or during development: `swift run Hive` and `swift test`.

## How connecting works

Game moves never touch a server — the apps connect to each other directly,
the way mobile games do. The lobby shows a 5-character **game code** (like
`K7Q2M`); the joiner types it in, and the apps find each other whether
they're on the same Wi-Fi or on opposite sides of the country.

Under the hood: each app learns its public address via **STUN** (free public
servers) and the two exchange addresses + a session token through a public
MQTT broker keyed by the code — that's the matchmaking step, carrying only a
few hundred bytes. Both apps then **UDP hole-punch**: they fire packets at
each other simultaneously, which opens both NATs from the inside. No port
forwarding, no router settings, and it works through double NAT. Game traffic
flows peer-to-peer over a small reliable layer (sliding window, cumulative
acks, retransmission), with packets identified by the session token so
delivery survives NAT path changes mid-game. Same-network play uses the same
flow — LAN addresses are punch candidates too.

The only setup this can't beat is a *symmetric* NAT on **both** ends (rare
for home networks; common on corporate/cellular). Connection failures are
reported in the UI, and connection events are logged to
`~/Library/Logs/Hive-net.log` for debugging.

Moves are validated by the full rules engine on **both** machines; if the two
ever disagree the game ends rather than desyncing silently.

Note on privacy: anyone who knows an active game code could read the host's
IP address from the matchmaking broker while the lobby is open (comparable to
sharing your IP with whoever you invite). Codes are random, single-use, and
cleared when the lobby closes.

## Playing against yourself (testing)

Two instances on one Mac, each with its own profile:

```sh
open Hive.app
HIVE_DATA_DIR=/tmp/hive-guest .build/release/Hive   # second player
```

The `HIVE_DATA_DIR` override matters: two instances sharing the default
profile directory would also share one identity and overwrite each other's
stats.

Headless networking checks: `.build/release/Hive --selftest-udp` (loopback,
no internet needed) and `--selftest-rendezvous` (live STUN + matchmaking +
hole punch).

## Project layout

- `Sources/HiveEngine` — pure, UI-free rules engine + wire protocol (unit-tested)
- `Sources/Hive` — SwiftUI app: views, match session, networking (STUN,
  matchmaking rendezvous, hole-punched reliable UDP), profile & stats
  persistence (`~/Library/Application Support/HiveP2P`)
- `Tests/HiveEngineTests` — engine tests incl. a random-playout fuzz
- `assets/AppIcon.icns` — app icon; regenerate via
  `swift tools/make-icon.swift /tmp/AppIcon.png`, then `sips`/`iconutil`
  into an `.iconset` (see `make-app.sh`)
>>>>>>> fbc3400 (Initial commit)
