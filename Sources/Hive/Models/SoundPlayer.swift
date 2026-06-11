import AppKit
import AVFoundation

/// Plays game audio. Sound effects (except the piece-placement "Tink", which is
/// the one macOS system sound we keep) and the background music are synthesized
/// at runtime by `GameAudio` — there are no audio asset files to bundle.
enum SoundPlayer {
    /// Gates sound effects.
    static var enabled = true

    /// Gates background music, independently of effects.
    static var musicEnabled = true {
        didSet { GameAudio.shared.setMusicEnabled(musicEnabled) }
    }

    enum Event {
        case place, move, gameStart, win, lose, draw
        case click, undoAsk, undoApplied, undoDecline
    }

    /// Which looping ambient track should play.
    enum MusicScene {
        case none, menu, game
    }

    static func play(_ event: Event) {
        guard enabled else { return }
        if event == .place {
            // The one sound we keep from macOS, as requested.
            (NSSound(named: "Tink")?.copy() as? NSSound)?.play()
            return
        }
        GameAudio.shared.playEffect(event)
    }

    static func setMusicScene(_ scene: MusicScene) {
        GameAudio.shared.setScene(scene)
    }
}

// MARK: - Synthesizer

/// A tiny software synth over AVAudioEngine. Renders short PCM buffers for
/// effects and a pair of looping ambient buffers for music, all from
/// oscillators + envelopes — no samples on disk.
private final class GameAudio {
    static let shared = GameAudio()

    private let engine = AVAudioEngine()
    private let musicNode = AVAudioPlayerNode()
    private var sfxPool: [AVAudioPlayerNode] = []
    private var poolIndex = 0
    private let format: AVAudioFormat
    private let sampleRate = 44_100.0
    private let queue = DispatchQueue(label: "hive.audio", qos: .userInitiated)

    private var running = false
    private var musicEnabled = true
    private var desiredScene: SoundPlayer.MusicScene = .none
    private var liveScene: SoundPlayer.MusicScene = .none
    private var effectCache: [String: AVAudioPCMBuffer] = [:]
    private var musicCache: [String: AVAudioPCMBuffer] = [:]
    private var musicBaseVolume: Float = 0

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.attach(musicNode)
        engine.connect(musicNode, to: engine.mainMixerNode, format: format)
        for _ in 0..<8 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sfxPool.append(node)
        }
    }

    // MARK: Lifecycle

    private func ensureRunning() {
        guard !running else { return }
        do {
            try engine.start()
            sfxPool.forEach { $0.play() }
            musicNode.play()
            running = true
        } catch {
            running = false
        }
    }

    // MARK: Public (queue-hopping) API

    func playEffect(_ event: SoundPlayer.Event) {
        queue.async { self._playEffect(event) }
    }

    func setScene(_ scene: SoundPlayer.MusicScene) {
        queue.async {
            self.desiredScene = scene
            self._applyScene()
        }
    }

    func setMusicEnabled(_ on: Bool) {
        queue.async {
            self.musicEnabled = on
            self._applyScene()
        }
    }

    // MARK: Effects

    private func _playEffect(_ event: SoundPlayer.Event) {
        ensureRunning()
        guard running else { return }
        let key = effectKey(event)
        let buffer = effectCache[key] ?? {
            let b = renderEffect(event)
            effectCache[key] = b
            return b
        }()
        let node = sfxPool[poolIndex]
        poolIndex = (poolIndex + 1) % sfxPool.count
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)

        // Let prominent stingers breathe over the music.
        switch event {
        case .gameStart: duckMusic(for: 0.5)
        case .win: duckMusic(for: 0.75)
        case .lose: duckMusic(for: 0.9)
        case .draw: duckMusic(for: 0.55)
        default: break
        }
    }

    private func effectKey(_ e: SoundPlayer.Event) -> String { "\(e)" }

    /// One buffer per effect, built by layering notes onto a silent canvas.
    private func renderEffect(_ event: SoundPlayer.Event) -> AVAudioPCMBuffer {
        switch event {
        case .move:
            // Soft wooden tap.
            return buffer(seconds: 0.14) { buf in
                addNote(&buf, midi: 55, start: 0, dur: 0.11, gain: 0.5,
                        wave: .triangle, attack: 0.002, release: 0.09)
            }
        case .gameStart:
            // Two-note rise with a little shimmer.
            return buffer(seconds: 0.5) { buf in
                addNote(&buf, midi: 67, start: 0.0, dur: 0.2, gain: 0.34, wave: .sine)
                addNote(&buf, midi: 67, start: 0.0, dur: 0.2, gain: 0.16, wave: .triangle)
                addNote(&buf, midi: 74, start: 0.13, dur: 0.3, gain: 0.34, wave: .sine)
                addNote(&buf, midi: 74, start: 0.13, dur: 0.3, gain: 0.16, wave: .triangle)
            }
        case .win:
            // Bright major arpeggio C-E-G-C.
            return buffer(seconds: 0.75) { buf in
                let notes = [72, 76, 79, 84]
                for (i, m) in notes.enumerated() {
                    let t = Double(i) * 0.09
                    addNote(&buf, midi: m, start: t, dur: 0.4 - t * 0.2, gain: 0.4, wave: .sine)
                    addNote(&buf, midi: m, start: t, dur: 0.4 - t * 0.2, gain: 0.18, wave: .triangle)
                }
            }
        case .lose:
            // Slow descending minor figure.
            return buffer(seconds: 0.9) { buf in
                let notes = [57, 53, 48]
                for (i, m) in notes.enumerated() {
                    addNote(&buf, midi: m, start: Double(i) * 0.2, dur: 0.45,
                            gain: 0.36, wave: .softSquare, attack: 0.01, release: 0.25)
                }
            }
        case .draw:
            // Two neutral tones a fourth apart.
            return buffer(seconds: 0.55) { buf in
                addNote(&buf, midi: 72, start: 0.0, dur: 0.28, gain: 0.32, wave: .sine)
                addNote(&buf, midi: 67, start: 0.16, dur: 0.34, gain: 0.32, wave: .sine)
            }
        case .click:
            // Crisp, quiet UI tick.
            return buffer(seconds: 0.04) { buf in
                addNote(&buf, midi: 96, start: 0, dur: 0.028, gain: 0.16,
                        wave: .sine, attack: 0.001, release: 0.02)
            }
        case .undoAsk:
            // Gentle rising double-blip: a request arrived.
            return buffer(seconds: 0.35) { buf in
                addNote(&buf, midi: 76, start: 0.0, dur: 0.12, gain: 0.26, wave: .sine)
                addNote(&buf, midi: 81, start: 0.14, dur: 0.16, gain: 0.26, wave: .sine)
            }
        case .undoApplied:
            // Quick descending "rewind".
            return buffer(seconds: 0.3) { buf in
                addNote(&buf, midi: 72, start: 0.0, dur: 0.1, gain: 0.28, wave: .triangle)
                addNote(&buf, midi: 64, start: 0.08, dur: 0.16, gain: 0.28, wave: .triangle)
            }
        case .undoDecline:
            // Low, short two-pulse buzz.
            return buffer(seconds: 0.32) { buf in
                addNote(&buf, midi: 48, start: 0.0, dur: 0.1, gain: 0.3,
                        wave: .softSquare, attack: 0.004, release: 0.06)
                addNote(&buf, midi: 48, start: 0.14, dur: 0.12, gain: 0.3,
                        wave: .softSquare, attack: 0.004, release: 0.06)
            }
        case .place:
            return buffer(seconds: 0.01) { _ in }  // handled by NSSound; unreachable
        }
    }

    // MARK: Music

    private func _applyScene() {
        let target: SoundPlayer.MusicScene = musicEnabled ? desiredScene : .none
        guard target != liveScene else { return }
        if target == .none {
            if running { musicNode.stop(); musicNode.play() }
            liveScene = .none
            return
        }
        ensureRunning()
        guard running else { return }
        let key = "\(target)"
        let buffer = musicCache[key] ?? {
            let b = renderMusic(target)
            musicCache[key] = b
            return b
        }()
        musicNode.stop()
        musicBaseVolume = (target == .menu) ? 0.5 : 0.26
        musicNode.volume = musicBaseVolume
        musicNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        musicNode.play()
        liveScene = target
    }

    /// A calm, seamless ambient loop. Several distinct chord progressions are
    /// concatenated into one long buffer so the music doesn't repeat a single
    /// four-bar phrase forever — the menu hears them all (with a soft arpeggio
    /// whose direction alternates), the in-game loop a quieter subset, pad only.
    private func renderMusic(_ scene: SoundPlayer.MusicScene) -> AVAudioPCMBuffer {
        let chordDur = 3.0
        // Each progression is a list of chords (MIDI note numbers).
        let progA = [[45, 60, 64, 67], [41, 57, 60, 64], [48, 64, 67, 71], [43, 59, 62, 64]]  // Am7·Fmaj7·Cmaj7·G6
        let progB = [[50, 57, 65, 69], [43, 55, 62, 67], [48, 60, 64, 67], [45, 57, 64, 69]]  // Dm7·G·Cadd9·Am
        let progC = [[52, 59, 67, 71], [48, 64, 67, 71], [43, 62, 67, 71], [50, 57, 62, 69]]  // Em7·Cmaj7·G·Dsus
        let progressions = (scene == .menu) ? [progA, progB, progC] : [progA, progC]
        let arpeggio = (scene == .menu)

        let chords = progressions.flatMap { $0 }
        let total = chordDur * Double(chords.count)
        return buffer(seconds: total) { buf in
            for (ci, chord) in chords.enumerated() {
                let start = Double(ci) * chordDur
                // Warm sustained bass root + the chord pad.
                addNote(&buf, midi: chord[0] - 12, start: start, dur: chordDur, gain: 0.09,
                        wave: .sine, attack: 0.4, release: 0.85)
                for m in chord {
                    addNote(&buf, midi: m, start: start, dur: chordDur, gain: 0.1,
                            wave: .sine, attack: 0.45, release: 0.9)
                }
                guard arpeggio else { continue }
                let ascending = ci % 2 == 0
                var step = 0
                var t = 0.0
                while t < chordDur - 0.1 {
                    let pos = step % chord.count
                    let idx = ascending ? pos : chord.count - 1 - pos
                    addNote(&buf, midi: chord[idx] + 12, start: start + t, dur: 0.34, gain: 0.08,
                            wave: .triangle, attack: 0.01, release: 0.2)
                    t += 0.4
                    step += 1
                }
            }
        }
    }

    /// Dip the music under a stinger, then ease it back so the effect reads
    /// clearly without a jarring volume jump.
    private func duckMusic(for seconds: Double) {
        guard liveScene != .none else { return }
        let base = musicBaseVolume
        musicNode.volume = base * 0.35
        let steps = 5
        for i in 1...steps {
            queue.asyncAfter(deadline: .now() + seconds + Double(i) * 0.08) { [weak self] in
                guard let self, self.liveScene != .none else { return }
                self.musicNode.volume = base * (0.35 + 0.65 * Float(i) / Float(steps))
            }
        }
    }

    // MARK: DSP primitives

    private enum Wave { case sine, triangle, softSquare }

    /// Allocates a silent stereo buffer, lets `build` add notes into a mono
    /// scratch track, then mirrors it to both channels with soft clipping.
    private func buffer(seconds: Double, build: (inout [Float]) -> Void) -> AVAudioPCMBuffer {
        let count = Int(seconds * sampleRate)
        var mono = [Float](repeating: 0, count: count)
        build(&mono)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buf.frameLength = AVAudioFrameCount(count)
        let left = buf.floatChannelData![0]
        let right = buf.floatChannelData![1]
        for i in 0..<count {
            let v = tanh(mono[i] * 1.1)  // gentle limiter to avoid harsh clipping
            left[i] = v
            right[i] = v
        }
        return buf
    }

    private func midiToFreq(_ midi: Int) -> Double {
        440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    }

    private func waveform(_ wave: Wave, phase: Double) -> Double {
        switch wave {
        case .sine:
            return sin(2 * .pi * phase)
        case .triangle:
            return 2 * abs(2 * (phase - floor(phase + 0.5))) - 1
        case .softSquare:
            return tanh(sin(2 * .pi * phase) * 2.2)
        }
    }

    private func addNote(_ buf: inout [Float], midi: Int, start: Double, dur: Double,
                         gain: Double, wave: Wave, attack: Double = 0.01,
                         release: Double = 0.14) {
        let freq = midiToFreq(midi)
        let s0 = Int(start * sampleRate)
        let n = Int(dur * sampleRate)
        guard n > 0 else { return }
        let atk = max(1, Int(attack * sampleRate))
        let rel = max(1, Int(release * sampleRate))
        var phase = 0.0
        for i in 0..<n {
            let idx = s0 + i
            if idx < 0 || idx >= buf.count { continue }
            let amp: Double
            if i < atk {
                amp = Double(i) / Double(atk)
            } else if i > n - rel {
                amp = max(0, Double(n - i) / Double(rel))
            } else {
                amp = 1
            }
            phase += freq / sampleRate
            buf[idx] += Float(waveform(wave, phase: phase) * gain * amp)
        }
    }
}
