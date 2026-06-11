# Hive-Mac

A native **macOS** app (Swift / SwiftUI) for playing the board game **Hive**
head-to-head between two Macs — on the same network or across the internet,
with no game server — plus a built-in AI opponent and post-game analysis.

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
- **Single-player vs. a built-in AI** — four tiers (Beginner, Snappy, Balanced,
  Strong) that set the engine's think time; wins count in your stats.
- **Game analysis** — chess.com-style review of any finished game: per-move
  Best/Good/Inaccuracy/Mistake/Blunder classifications, an evaluation graph,
  per-player accuracy, and best-move arrows during replay.
- **GamePigeon-style profiles** — name, avatar emoji, accent color; editable
  any time from the main menu.
- **Stats** — overall wins/losses/draws plus a head-to-head record against
  every opponent you've played (tracked by their profile identity).
- **Rematch** from the game-over screen — colors swap each rematch (and
  Random first-move is re-rolled).
- **Move list & notation panel** (standard UHP-style notation), last-move
  arrow and highlights on the board.
- **Game history with replays** — every finished game is saved; step through
  it move by move from the History screen.
- **Reconnect after a drop** — if the connection dies mid-game, both apps
  derive a private resume code from the original session and hole-punch a
  fresh link; the host re-syncs the position and play continues.
- **Drag pieces** (or tap-select-tap), **pan/zoom** the board for big games,
  **four app themes**, and **sound effects** (toggle in the profile editor).
- **Automatic updates** — on launch the app checks GitHub Releases and offers a
  one-click "Install & Relaunch" when a newer version is published.

## Building

```sh
./make-app.sh        # builds the release binary and produces Hive.app
open Hive.app
```

Or during development: `swift run Hive` and `swift test`. The app's version
comes from the `VERSION` file (stamped into `Hive.app/Contents/Info.plist`);
release builds in CI use the git tag instead.

## How connecting works

Game moves never touch a server — the apps connect to each other directly,
the way mobile games do. The lobby shows a 5-character **game code** (like
`K7Q2M`); the joiner types it in, and the apps find each other whether
they're on the same Wi-Fi or on opposite sides of the country.

Under the hood: each app learns its public address via **STUN** (free public
servers) and the two exchange addresses + a session token through a public
MQTT broker keyed by the code — that's the matchmaking step, carrying only a
few hundred bytes (encrypted with a key derived from the code). Both apps then
**UDP hole-punch**: they fire packets at each other simultaneously, which opens
both NATs from the inside. No port forwarding, no router settings, and it works
through double NAT. Game traffic flows peer-to-peer over a small reliable layer
(sliding window, cumulative acks, retransmission), encrypted with a session key
and identified by token so delivery survives NAT path changes mid-game.
Same-network play uses the same flow — LAN addresses are punch candidates too.

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

## The AI and training

The opponent is an iterative-deepening alpha-beta search engine (`HiveAI`) with
a transposition table and a positional evaluation — Hive has no material, so
the evaluation scores things like queen surroundedness, queen escape routes,
pinned pieces, free attackers, and beetle pressure.

The evaluation's weights are tuned by **local self-play**, with no external
service and no API usage:

```sh
./train-ai.sh start    # background self-play tuning (uses spare cores)
./train-ai.sh watch    # foreground, with live move-by-move games in the terminal
./train-ai.sh status   # rounds played, improvements adopted, pruned attributes
./train-ai.sh log      # follow the training log
./train-ai.sh stop
```

Each round mutates the champion's weights, plays a multi-threaded
candidate-vs-champion match, and adopts the candidate only if it clearly wins.
Improvements are written to
`~/Library/Application Support/HiveP2P/tuned-weights.json`, which the app loads
automatically — so the in-game bot and the analyzer get stronger over time.

## Releasing (auto-update)

Pushing a version tag builds and publishes a release that existing installs
pick up automatically:

```sh
git tag v1.0.1
git push origin v1.0.1
```

`.github/workflows/release.yml` builds `Hive.app` on a macOS runner (version
taken from the tag), runs the tests, zips the bundle, and attaches it to a
GitHub Release. On next launch, other copies of the app see the newer release
and offer to install it.

## Playing against yourself (testing)

Two instances on one Mac, each with its own profile:

```sh
open Hive.app
HIVE_DATA_DIR=/tmp/hive-guest .build/release/Hive   # second player
```

The `HIVE_DATA_DIR` override matters: two instances sharing the default
profile directory would also share one identity and overwrite each other's
stats.

Headless self-tests (used in development and CI):

```sh
.build/release/Hive --selftest-udp          # loopback hole punch, no internet
.build/release/Hive --selftest-rendezvous   # live STUN + matchmaking + punch
.build/release/Hive --selftest-art          # piece icons load from the bundle
.build/release/Hive --selftest-update        # version-comparison logic
.build/release/Hive --selftest-ai            # engine + analysis sanity
```

## Project layout

- `Sources/HiveEngine` — pure, UI-free rules engine, move notation, wire
  protocol, and the `HiveAI` search engine (all unit-tested)
- `Sources/Hive` — SwiftUI app: views, match session, networking (STUN,
  matchmaking rendezvous, hole-punched reliable UDP), AI bot + game analyzer,
  self-play trainer, auto-updater, profile & stats persistence
  (`~/Library/Application Support/HiveP2P`)
- `Tests/HiveEngineTests` — engine tests incl. a random-playout fuzz
- `assets/AppIcon.icns`, `assets/HiveIcons.png` — app icon and the source sheet
  for the classic/carbon piece art (regenerate icons via
  `swift tools/make-icon.swift`, pieces via `swift tools/slice-pieces.swift`)
- `make-app.sh` — packages the SwiftPM build into `Hive.app`
- `train-ai.sh` — controls the background self-play trainer
- `.github/workflows/release.yml` — tag-triggered release build
