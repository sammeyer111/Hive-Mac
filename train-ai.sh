#!/bin/bash
# Background self-play trainer for the Hive AI.
#
#   ./train-ai.sh start    build + start training in the background (all cores)
#   ./train-ai.sh watch    train in the FOREGROUND, showing each exhibition
#                          game move-by-move in the terminal (Ctrl-C to stop)
#   ./train-ai.sh stop     stop training
#   ./train-ai.sh status   is it running? rounds played? current champion?
#   ./train-ai.sh log      follow the live training log
#
# Only one trainer runs at a time (they'd fight over the weights file), so
# 'watch' stops any background trainer first. Use 'start' for unattended
# background training, 'watch' when you want to see the models duel live.
#
# Training evolves the engine's evaluation weights via candidate-vs-champion
# self-play matches. Improved weights are written to
#   ~/Library/Application Support/HiveP2P/tuned-weights.json
# and the app loads them automatically the next time a bot game or analysis
# starts. Everything runs locally — no network, no API usage.
set -euo pipefail
cd "$(dirname "$0")"

LOG="$HOME/Library/Logs/Hive-training.log"
PIDFILE="/tmp/hive-trainer.pid"
WEIGHTS="$HOME/Library/Application Support/HiveP2P/tuned-weights.json"

running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "${1:-start}" in
start)
    if running; then
        echo "Trainer already running (pid $(cat "$PIDFILE")). Use './train-ai.sh log' to watch."
        exit 0
    fi
    echo "Building release binary..."
    swift build -c release > /dev/null
    # nice: stay out of the way of normal use; caffeinate -i: don't let idle
    # sleep pause training (display can still sleep).
    nohup nice -n 10 caffeinate -i .build/release/Hive --train >> "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    echo "Trainer started (pid $(cat "$PIDFILE"))."
    echo "  log:     $LOG"
    echo "  weights: $WEIGHTS"
    echo "  stop:    ./train-ai.sh stop"
    ;;
watch)
    if running; then
        echo "Stopping background trainer first (only one trainer at a time)..."
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        pkill -f "Hive --train" 2>/dev/null || true
        rm -f "$PIDFILE"
        sleep 1
    fi
    echo "Building..."
    swift build -c release > /dev/null
    echo "Training live — each round plays one exhibition game you can watch."
    echo "Press Ctrl-C to stop. (Improvements are still saved as they're found.)"
    echo
    # Foreground, watch mode. caffeinate keeps it awake while you watch.
    exec caffeinate -i .build/release/Hive --train --watch
    ;;
stop)
    if running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    # caffeinate's child can survive it; make sure the trainer itself dies.
    pkill -f "Hive --train" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "Trainer stopped."
    ;;
status)
    if running; then
        echo "Trainer RUNNING (pid $(cat "$PIDFILE"))."
    else
        echo "Trainer not running."
    fi
    if [ -f "$LOG" ]; then
        ROUNDS=$(grep -c "^.*round " "$LOG" 2>/dev/null || true)
        ADOPTED=$(grep -c "ADOPTED" "$LOG" 2>/dev/null || true)
        echo "Rounds logged: ${ROUNDS:-0}, improvements adopted: ${ADOPTED:-0}"
        echo "Last activity:"
        tail -3 "$LOG" | sed 's/^/  /'
    fi
    if [ -f "$WEIGHTS" ]; then
        echo "Tuned weights present: $WEIGHTS"
    else
        echo "No tuned weights yet (still using defaults)."
    fi
    ;;
log)
    touch "$LOG"
    tail -f "$LOG"
    ;;
*)
    echo "usage: $0 {start|watch|stop|status|log}"
    exit 1
    ;;
esac
