import AppKit
import AVFoundation

/// Plays game audio. Sound effects (except the piece-placement "Tink", which is
/// the one macOS system sound we keep) and the background music are synthesized
/// at runtime by `GameAudio` — there are no audio asset files to bundle.
enum SoundPlayer {
    /// Overall output level (0…1). Effects play at master × sfx; music at
    /// master × music. A volume of 0 is silence (the old "off").
    static var masterVolume: Float = 1 { didSet { GameAudio.shared.setMaster(masterVolume) } }
    static var sfxVolume: Float = 0.8 { didSet { GameAudio.shared.setSFX(sfxVolume) } }
    static var musicVolume: Float = 0.6 { didSet { GameAudio.shared.setMusic(musicVolume) } }

    private static var effectsAudible: Bool { masterVolume > 0.001 && sfxVolume > 0.001 }

    enum Event {
        case place, move, gameStart, win, lose, draw
        case click, undoAsk, undoApplied, undoDecline
    }

    /// Which looping ambient track should play.
    enum MusicScene {
        case none, menu, game
    }

    static func play(_ event: Event) {
        guard effectsAudible else { return }
        if event == .place {
            // The one sound we keep from macOS, as requested.
            if let sound = NSSound(named: "Tink")?.copy() as? NSSound {
                sound.volume = masterVolume * sfxVolume
                sound.play()
            }
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
    private let musicReverb = AVAudioUnitReverb()
    private let sfxReverb = AVAudioUnitReverb()
    private let sfxMixer = AVAudioMixerNode()
    private var sfxPool: [AVAudioPlayerNode] = []
    private var poolIndex = 0
    private let format: AVAudioFormat
    private let sampleRate = 44_100.0
    private let queue = DispatchQueue(label: "hive.audio", qos: .userInitiated)

    private var running = false
    private var desiredScene: SoundPlayer.MusicScene = .none
    private var liveScene: SoundPlayer.MusicScene = .none
    private var effectCache: [String: AVAudioPCMBuffer] = [:]
    private var musicCache: [String: AVAudioPCMBuffer] = [:]

    // User-set levels (0…1) and the per-scene base, plus the transient ducking
    // factor. Effective music level = base × musicVolume × duckFactor.
    private var masterVolume: Float = 1
    private var sfxVolume: Float = 0.8
    private var musicVolume: Float = 0.6
    private var musicBaseVolume: Float = 0
    private var duckFactor: Float = 1

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        // Music runs through a roomy hall; effects through a light room. The
        // reverb tails are what stop the synth from sounding dry and chiptune.
        engine.attach(musicNode)
        engine.attach(musicReverb)
        musicReverb.loadFactoryPreset(.largeHall)
        musicReverb.wetDryMix = 38
        engine.connect(musicNode, to: musicReverb, format: format)
        engine.connect(musicReverb, to: engine.mainMixerNode, format: format)

        // The 8 effect voices fan into a mixer first — an effect node has only
        // one input bus, so the pool can't connect to the reverb directly.
        engine.attach(sfxReverb)
        sfxReverb.loadFactoryPreset(.mediumRoom)
        sfxReverb.wetDryMix = 16
        engine.attach(sfxMixer)
        engine.connect(sfxMixer, to: sfxReverb, format: format)
        engine.connect(sfxReverb, to: engine.mainMixerNode, format: format)
        for _ in 0..<8 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: sfxMixer, format: format)
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
            _applyLevels()
        } catch {
            running = false
        }
    }

    /// Pushes the current volumes onto the graph: master on the main mixer,
    /// sfx on the effects submix, music folded into the music node.
    private func _applyLevels() {
        guard running else { return }
        engine.mainMixerNode.outputVolume = masterVolume
        sfxMixer.outputVolume = sfxVolume
        _updateMusicVolume()
    }

    private func _updateMusicVolume() {
        guard running else { return }
        musicNode.volume = musicBaseVolume * musicVolume * duckFactor
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

    func setMaster(_ v: Float) { queue.async { self.masterVolume = v; self._applyLevels() } }
    func setSFX(_ v: Float) { queue.async { self.sfxVolume = v; self._applyLevels() } }
    func setMusic(_ v: Float) { queue.async { self.musicVolume = v; self._updateMusicVolume() } }

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
            // Soft, rounded wooden tap.
            return buffer(seconds: 0.22) { buf in
                addNote(&buf, midi: 52, start: 0, dur: 0.18, gain: 0.42,
                        voice: .soft, attack: 0.004, release: 0.16)
            }
        case .gameStart:
            // A soft, slow chord that swells in gently — easy to miss, not a
            // fanfare. Long attacks keep it from sounding like a chime.
            return buffer(seconds: 1.1) { buf in
                addNote(&buf, midi: 55, start: 0.0, dur: 1.0, gain: 0.1, voice: .pad,
                        attack: 0.3, release: 0.55)
                addNote(&buf, midi: 60, start: 0.05, dur: 0.95, gain: 0.085, voice: .pad,
                        attack: 0.32, release: 0.55)
                addNote(&buf, midi: 64, start: 0.1, dur: 0.9, gain: 0.085, voice: .pad,
                        attack: 0.35, release: 0.55)
            }
        case .win:
            // Glowing major arpeggio C-E-G-C with a pad swell underneath.
            return buffer(seconds: 1.1) { buf in
                addNote(&buf, midi: 60, start: 0.0, dur: 1.0, gain: 0.12, voice: .pad,
                        attack: 0.06, release: 0.6)
                let notes = [72, 76, 79, 84]
                for (i, m) in notes.enumerated() {
                    let t = Double(i) * 0.1
                    addNote(&buf, midi: m, start: t, dur: 0.6 - t * 0.2, gain: 0.34, voice: .lead)
                }
            }
        case .lose:
            // Slow descending minor figure, soft and warm.
            return buffer(seconds: 1.1) { buf in
                let notes = [57, 53, 48]
                for (i, m) in notes.enumerated() {
                    addNote(&buf, midi: m, start: Double(i) * 0.22, dur: 0.6,
                            gain: 0.32, voice: .pad, attack: 0.02, release: 0.35)
                }
            }
        case .draw:
            // Two neutral tones a fourth apart.
            return buffer(seconds: 0.7) { buf in
                addNote(&buf, midi: 72, start: 0.0, dur: 0.34, gain: 0.3, voice: .pad)
                addNote(&buf, midi: 67, start: 0.18, dur: 0.42, gain: 0.3, voice: .pad)
            }
        case .click:
            // Soft, quiet UI tip.
            return buffer(seconds: 0.09) { buf in
                addNote(&buf, midi: 81, start: 0, dur: 0.06, gain: 0.13,
                        voice: .soft, attack: 0.002, release: 0.05)
            }
        case .undoAsk:
            // Gentle rising double-blip: a request arrived.
            return buffer(seconds: 0.45) { buf in
                addNote(&buf, midi: 76, start: 0.0, dur: 0.16, gain: 0.24, voice: .lead)
                addNote(&buf, midi: 81, start: 0.15, dur: 0.22, gain: 0.24, voice: .lead)
            }
        case .undoApplied:
            // Quick descending "rewind".
            return buffer(seconds: 0.4) { buf in
                addNote(&buf, midi: 72, start: 0.0, dur: 0.14, gain: 0.26, voice: .soft)
                addNote(&buf, midi: 64, start: 0.09, dur: 0.22, gain: 0.26, voice: .soft)
            }
        case .undoDecline:
            // Low, short two-pulse — soft, not buzzy.
            return buffer(seconds: 0.42) { buf in
                addNote(&buf, midi: 48, start: 0.0, dur: 0.14, gain: 0.28, voice: .bass,
                        attack: 0.006, release: 0.1)
                addNote(&buf, midi: 48, start: 0.16, dur: 0.18, gain: 0.28, voice: .bass,
                        attack: 0.006, release: 0.12)
            }
        case .place:
            return buffer(seconds: 0.01) { _ in }  // handled by NSSound; unreachable
        }
    }

    // MARK: Music

    private func _applyScene() {
        let target = desiredScene
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
        duckFactor = 1
        _updateMusicVolume()
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
                addNote(&buf, midi: chord[0] - 12, start: start, dur: chordDur, gain: 0.08,
                        voice: .bass, attack: 0.5, release: 0.9)
                for m in chord {
                    addNote(&buf, midi: m, start: start, dur: chordDur, gain: 0.09,
                            voice: .pad, attack: 0.55, release: 1.0)
                }
                guard arpeggio else { continue }
                let ascending = ci % 2 == 0
                var step = 0
                var t = 0.0
                while t < chordDur - 0.1 {
                    let pos = step % chord.count
                    let idx = ascending ? pos : chord.count - 1 - pos
                    addNote(&buf, midi: chord[idx] + 12, start: start + t, dur: 0.5, gain: 0.06,
                            voice: .lead, attack: 0.02, release: 0.4)
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
        duckFactor = 0.35
        _updateMusicVolume()
        let steps = 5
        for i in 1...steps {
            queue.asyncAfter(deadline: .now() + seconds + Double(i) * 0.08) { [weak self] in
                guard let self, self.liveScene != .none else { return }
                self.duckFactor = 0.35 + 0.65 * Float(i) / Float(steps)
                self._updateMusicVolume()
            }
        }
    }

    // MARK: DSP primitives

    /// Instrument timbres built as additive harmonic stacks. Slightly inharmonic
    /// multipliers make the partials beat gently against each other for a richer,
    /// less "pure oscillator" sound. No saw/square anywhere.
    private enum Voice { case pad, lead, soft, bass }

    private func partials(_ voice: Voice) -> [(mult: Double, amp: Double)] {
        switch voice {
        case .pad:  return [(1.0, 1.0), (2.003, 0.5), (3.0, 0.22), (4.005, 0.1), (6.0, 0.04)]
        case .lead: return [(1.0, 1.0), (2.002, 0.32), (3.001, 0.13), (5.0, 0.05)]
        case .soft: return [(1.0, 1.0), (2.0, 0.14), (3.0, 0.045)]
        case .bass: return [(1.0, 1.0), (2.001, 0.28), (3.0, 0.07)]
        }
    }

    /// Allocates a silent stereo buffer, lets `build` add notes into a mono
    /// scratch track, then warms it with a one-pole low-pass and soft limiter
    /// before mirroring to both channels.
    private func buffer(seconds: Double, build: (inout [Float]) -> Void) -> AVAudioPCMBuffer {
        let count = Int(seconds * sampleRate)
        var mono = [Float](repeating: 0, count: count)
        build(&mono)

        // Gentle low-pass (~4 kHz): rolls off the brittle highs that read as
        // chiptune, leaving a rounder tone.
        let alpha: Float = 0.42
        var y: Float = 0
        for i in 0..<count {
            y += alpha * (mono[i] - y)
            mono[i] = y
        }

        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buf.frameLength = AVAudioFrameCount(count)
        let left = buf.floatChannelData![0]
        let right = buf.floatChannelData![1]
        for i in 0..<count {
            let v = tanh(mono[i] * 1.1)  // soft limiter
            left[i] = v
            right[i] = v
        }
        return buf
    }

    private func midiToFreq(_ midi: Int) -> Double {
        440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    }

    private func addNote(_ buf: inout [Float], midi: Int, start: Double, dur: Double,
                         gain: Double, voice: Voice, attack: Double = 0.012,
                         release: Double = 0.18) {
        let f0 = midiToFreq(midi)
        let s0 = Int(start * sampleRate)
        let n = Int(dur * sampleRate)
        guard n > 0 else { return }
        let atk = max(1, Int(attack * sampleRate))
        let rel = max(1, Int(release * sampleRate))
        let parts = partials(voice)
        let norm = parts.reduce(0.0) { $0 + $1.amp }
        var phases = [Double](repeating: 0, count: parts.count)
        let twoPi = 2.0 * Double.pi
        for i in 0..<n {
            let idx = s0 + i
            if idx < 0 || idx >= buf.count { continue }
            // Raised-cosine attack/release: click-free, smoother than linear.
            let env: Double
            if i < atk {
                env = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(atk))
            } else if i > n - rel {
                let r = Double(n - i) / Double(rel)
                env = max(0, 0.5 - 0.5 * cos(Double.pi * r))
            } else {
                env = 1
            }
            var sample = 0.0
            for p in 0..<parts.count {
                phases[p] += twoPi * f0 * parts[p].mult / sampleRate
                sample += sin(phases[p]) * parts[p].amp
            }
            buf[idx] += Float(sample / norm * gain * env)
        }
    }
}
