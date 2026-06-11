import Foundation

// Headless network self-tests (used by scripts; the GUI never sees these):
//   Hive --selftest-udp          loopback punch + ordered delivery
//   Hive --selftest-rendezvous   live STUN + matchmaking + hole punch
if CommandLine.arguments.contains("--selftest-udp") {
    // The process entry point runs on the main thread.
    MainActor.assumeIsolated {
        NetSelfTest.runUDPLoopbackAndExit()
    }
}

if CommandLine.arguments.contains("--selftest-rendezvous") {
    MainActor.assumeIsolated {
        NetSelfTest.runRendezvousAndExit()
    }
}

if CommandLine.arguments.contains("--selftest-ai") {
    AISelfTest.runAndExit()
}

if CommandLine.arguments.contains("--make-sample-game") {
    AISelfTest.makeSampleGameAndExit()
}

// Background self-play tuning (see train-ai.sh). Runs forever; kill to stop.
if CommandLine.arguments.contains("--train") {
    Trainer.runAndExit()
}

if CommandLine.arguments.contains("--selftest-art") {
    ArtSelfTest.runAndExit()
}

HiveApp.main()
