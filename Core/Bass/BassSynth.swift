import Foundation

/// Built-in bass tones (synth kits). Same note stream; pick the character that fits the song.
public enum BassKit: Int, CaseIterable, Sendable {
    case upright = 0
    case electricBallad
    case acoustic
    case electricJazz

    public static let count = BassKit.allCases.count

    public var name: String {
        switch self {
        case .upright: "Acoustic Upright Bass"
        case .electricBallad: "Electric Ballad Bass"
        case .acoustic: "Acoustic Bass"
        case .electricJazz: "Electric Jazz Bass"
        }
    }

    /// Wave mixes and envelope times that define the kit.
    fileprivate var tone: Tone {
        switch self {
        case .upright:
            // Warm double bass: fundamental-heavy, soft finger, woody body, dark.
            Tone(sine: 0.72, saw: 0.12, square: 0.0, sub: 0.28,
                 attack: 0.012, decay: 5.5, release: 0.22, pluck: 0.14,
                 baseCut: 0.55, pluckCut: 0.45, drive: 0.08, noise: 0.18, body: 0.22)
        case .electricBallad:
            // Round fretted electric: smooth, dark, long, almost pad-like sustain.
            Tone(sine: 0.55, saw: 0.35, square: 0.0, sub: 0.2,
                 attack: 0.018, decay: 8.0, release: 0.28, pluck: 0.2,
                 baseCut: 0.5, pluckCut: 0.35, drive: 0.12, noise: 0.04, body: 0.06)
        case .acoustic:
            // Fretted acoustic: clearer mid, stronger pluck, shorter bloom.
            Tone(sine: 0.4, saw: 0.4, square: 0.08, sub: 0.15,
                 attack: 0.005, decay: 4.0, release: 0.14, pluck: 0.07,
                 baseCut: 0.75, pluckCut: 0.9, drive: 0.15, noise: 0.28, body: 0.12)
        case .electricJazz:
            // Jazz/P-bass growl: mid punch, pulse edge, snappy attack.
            Tone(sine: 0.25, saw: 0.35, square: 0.4, sub: 0.18,
                 attack: 0.003, decay: 5.0, release: 0.1, pluck: 0.055,
                 baseCut: 0.95, pluckCut: 1.15, drive: 0.35, noise: 0.1, body: 0.04)
        }
    }

    fileprivate struct Tone {
        var sine, saw, square, sub: Float
        var attack, decay, release, pluck: Float   // seconds
        var baseCut, pluckCut: Float               // multipliers on the default Hz curves
        var drive, noise, body: Float
    }
}

/// Synth bass for the bass track. Four kit characters (upright / ballad / acoustic / jazz),
/// lightly polyphonic (3 voices). New notes cut earlier ones like a bassist muting the last
/// string. All memory is allocated up front so `noteOn`, `allNotesOff` and `render` stay
/// audio-thread safe.
final class BassSynth {
    struct Voice {
        var active = false
        var delay = 0
        var hold = 0
        var releasing = false
        var age = 0
        var phase: Float = 0, inc: Float = 0
        var bodyPhase: Float = 0, bodyInc: Float = 0
        var amp: Float = 0
        var att: Float = 0
        var env: Float = 1
        var pluck: Float = 1
        var noiseEnv: Float = 0
        var baseCut: Float = 0, pluckCut: Float = 0
        var z1: Float = 0, z2: Float = 0
        var sine: Float = 0.5, saw: Float = 0.5, square: Float = 0, sub: Float = 0
        var drive: Float = 0, body: Float = 0
        var noiseAmt: Float = 0
    }

    static let voiceCount = 3
    let voices: UnsafeMutablePointer<Voice>
    private var sampleRate: Float = 44100
    private var attackInc: Float = 0, decayCoef: Float = 1, releaseCoef: Float = 0, pluckCoef: Float = 0
    private var noiseCoef: Float = 0
    private var noiseState: UInt32 = 0xA5A5_1234
    /// Peak of the last `render` call (pre–master volume), for the mixer meter.
    private(set) var lastPeak: Float = 0
    private(set) var kit: BassKit = .electricJazz

    init() {
        voices = .allocate(capacity: BassSynth.voiceCount)
        voices.initialize(repeating: Voice(), count: BassSynth.voiceCount)
        setKit(.electricJazz)
        setSampleRate(44100)
    }

    deinit { voices.deinitialize(count: BassSynth.voiceCount); voices.deallocate() }

    func setKit(_ k: BassKit) {
        kit = k
        applyEnvelopeTimes()
    }

    func setSampleRate(_ sr: Double) {
        sampleRate = Float(sr)
        applyEnvelopeTimes()
        reset()
    }

    private func applyEnvelopeTimes() {
        let t = kit.tone
        attackInc = 1 / max(t.attack * sampleRate, 1)
        decayCoef = powf(0.001, 1 / max(t.decay * sampleRate, 1))
        releaseCoef = powf(0.001, 1 / max(t.release * sampleRate, 1))
        pluckCoef = expf(-1 / max(t.pluck * sampleRate, 1))
        noiseCoef = expf(-1 / (0.012 * sampleRate))
    }

    func reset() {
        for i in 0..<BassSynth.voiceCount { voices[i].active = false }
        lastPeak = 0
    }

    var activeVoices: Int {
        var n = 0
        for i in 0..<BassSynth.voiceCount where voices[i].active { n += 1 }
        return n
    }

    /// Schedules a note `delay` samples into the next render call; it sounds for `length` samples.
    func noteOn(_ note: UInt8, velocity: Float, delay: Int, length: Int) {
        let d = max(delay, 0)
        for i in 0..<BassSynth.voiceCount where voices[i].active && (voices[i].age > 0 || voices[i].delay < d) {
            voices[i].hold = min(voices[i].hold, d - voices[i].delay)
        }
        var idx = -1
        for i in 0..<BassSynth.voiceCount where !voices[i].active { idx = i; break }
        if idx < 0 {
            idx = 0
            for i in 1..<BassSynth.voiceCount {
                let a = voices[idx], b = voices[i]
                if (b.releasing && !a.releasing) || (b.releasing == a.releasing && b.env < a.env) { idx = i }
            }
        }
        let t = kit.tone
        let f = 440 * powf(2, (Float(note) - 69) / 12)
        let vel = min(max(velocity, 0), 1)
        var v = Voice()
        v.active = true
        v.delay = d
        v.hold = max(length, 1)
        v.inc = f / sampleRate
        v.bodyInc = f * 1.0035 / sampleRate
        v.amp = 0.42 * powf(vel, 1.25)
        v.baseCut = (180 + 2.6 * f) * t.baseCut
        v.pluckCut = (500 + 2800 * vel) * t.pluckCut
        v.sine = t.sine; v.saw = t.saw; v.square = t.square; v.sub = t.sub
        v.drive = t.drive; v.body = t.body
        v.noiseAmt = t.noise * (0.55 + 0.45 * vel)
        v.noiseEnv = v.noiseAmt
        voices[idx] = v
    }

    /// Releases every note `delay` samples into the next render call; notes that would start later are dropped.
    func allNotesOff(delay: Int = 0) {
        for i in 0..<BassSynth.voiceCount where voices[i].active {
            if voices[i].age == 0 && voices[i].delay >= delay { voices[i].active = false }
            else { voices[i].hold = min(voices[i].hold, max(delay - voices[i].delay, 0)) }
        }
    }

    /// Adds `frames` samples of all voices, times `gain`, to both channels.
    /// When `busLeft`/`busRight` are set, the same samples are written there too (bass multi-out).
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, gain: Float,
                busLeft: UnsafeMutablePointer<Float>? = nil, busRight: UnsafeMutablePointer<Float>? = nil) {
        let twoPi = 2 * Float.pi
        let wScale = twoPi / sampleRate
        let maxCut = 0.45 * sampleRate
        var peak: Float = 0
        for vi in 0..<BassSynth.voiceCount where voices[vi].active {
            var v = voices[vi]
            var i = 0
            while i < frames {
                if v.delay > 0 { v.delay -= 1; i += 1; continue }
                if !v.releasing {
                    if v.hold > 0 { v.hold -= 1 } else { v.releasing = true }
                }
                // Band-limited falling saw (polyBLEP).
                var saw = 1 - 2 * v.phase
                if v.phase < v.inc {
                    let t = v.phase / v.inc; saw += t + t - t * t - 1
                } else if v.phase > 1 - v.inc {
                    let t = (v.phase - 1) / v.inc; saw += t * t + t + t + 1
                }
                // Soft square via tanh of a sine (no aliasing edges).
                let sine = sinf(twoPi * v.phase)
                let square = tanhf(sine * 4)
                let sub = sinf(Float.pi * v.phase)                    // one octave down
                let body = v.body > 0.001 ? sinf(twoPi * v.bodyPhase) : 0
                // Short noise burst for the string attack.
                noiseState = noiseState &* 1664525 &+ 1013904223
                let n = Float(Int32(bitPattern: noiseState)) * (1.0 / 2_147_483_648.0)
                let noise = n * v.noiseEnv
                v.noiseEnv *= noiseCoef

                var x = v.sine * sine + v.saw * saw + v.square * square + v.sub * sub
                x += v.body * body + noise
                if v.drive > 0.001 {
                    let d = 1 + 3 * v.drive
                    x = tanhf(x * d) / tanhf(d)
                }

                v.phase += v.inc
                if v.phase >= 1 { v.phase -= 1 }
                v.bodyPhase += v.bodyInc
                if v.bodyPhase >= 1 { v.bodyPhase -= 1 }

                let w = min(v.baseCut + v.pluckCut * v.pluck, maxCut) * wScale
                let g = w / (1 + w)
                v.z1 += g * (x - v.z1)
                v.z2 += g * (v.z1 - v.z2)
                v.pluck *= pluckCoef
                if v.att < 1 { v.att = min(1, v.att + attackInc) }
                v.env *= v.releasing ? releaseCoef : decayCoef
                let s = v.z2 * v.amp * v.att * v.env * gain
                left[i] += s
                right[i] += s
                if let bl = busLeft { bl[i] += s }
                if let br = busRight { br[i] += s }
                peak = max(peak, abs(s))
                v.age += 1
                if v.releasing && v.env < 0.0001 { v.active = false; break }
                i += 1
            }
            voices[vi] = v
        }
        lastPeak = peak
    }
}
