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

if CommandLine.arguments.contains("--selftest-update") {
    MainActor.assumeIsolated {
        let cases: [(String, String, Bool)] = [
            ("1.0.1", "1.0.0", true), ("1.1.0", "1.0.9", true), ("2.0.0", "1.9.9", true),
            ("1.0.0", "1.0.0", false), ("1.0.0", "1.0.1", false), ("0.9.0", "1.0.0", false),
            ("1.0", "1.0.0", false), ("1.0.0.1", "1.0.0", true),
        ]
        var failures = 0
        for (cand, cur, expected) in cases where UpdateChecker.isNewer(cand, than: cur) != expected {
            print("FAIL: isNewer(\(cand), than: \(cur)) != \(expected)")
            failures += 1
        }
        print(failures == 0 ? "selftest: PASS — version comparison OK" : "selftest: FAIL")
        exit(failures == 0 ? 0 : 1)
    }
}

HiveApp.main()
