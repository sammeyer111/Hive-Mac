import AppKit

/// Plays short system sounds for game events. Uses the sounds that ship with
/// every macOS install, so there are no audio assets to bundle.
enum SoundPlayer {
    static var enabled = true

    enum Event {
        case place, move, gameStart, win, lose, draw
    }

    static func play(_ event: Event) {
        guard enabled else { return }
        let name: String
        switch event {
        case .place: name = "Tink"
        case .move: name = "Pop"
        case .gameStart: name = "Ping"
        case .win: name = "Glass"
        case .lose: name = "Basso"
        case .draw: name = "Submarine"
        }
        // Copy: the shared named instance won't restart while already playing.
        (NSSound(named: name)?.copy() as? NSSound)?.play()
    }
}
