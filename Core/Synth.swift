import Foundation

// MARK: - Kit description

public enum FilterMode: Int, Sendable { case low = 0, band = 1, high = 2 }

/// Synthesis recipe for one drum voice. Every drum is built from up to four
/// layers: a pitched sine (with pitch sweep), filtered noise, a "metal" bank of
/// detuned square oscillators, and a short click transient.
public struct DrumParams: Sendable {
    var toneLevel: Float = 0, toneStart: Float = 100, toneEnd: Float = 100
    var pitchTau: Float = 0.02, toneDecay: Float = 0.2
    var noiseLevel: Float = 0, noiseDecay: Float = 0.1, noiseCutoff: Float = 5000
    var noiseQ: Float = 0.7, noiseMode: FilterMode = .band
    var metalLevel: Float = 0, metalScale: Float = 1, metalDecay: Float = 0.1
    var metalCutoff: Float = 7000, metalQ: Float = 0.7, metalMode: FilterMode = .high
    var cowbell = false
    var clickLevel: Float = 0, clickDecay: Float = 0.004
    var clap = false
    var attack: Float = 0.0005
    var drive: Float = 0
    var gain: Float = 1
    var pan: Float = 0
}

public struct KitInfo: Sendable {
    public let name: String
    public let masterCutoff: Float   // gentle low-pass on the kit bus (Hz)
}

public enum Kits {
    public static let all: [KitInfo] = [
        KitInfo(name: "Studio", masterCutoff: 20000),
        KitInfo(name: "Vintage", masterCutoff: 11000),
        KitInfo(name: "Electro", masterCutoff: 20000),
        KitInfo(name: "Lo-Fi", masterCutoff: 4200),
        KitInfo(name: "Brushes", masterCutoff: 14000),
    ]
    public static var names: [String] { all.map(\.name) }

    static func studio() -> [DrumParams] {
        var k = [DrumParams](repeating: DrumParams(), count: Drum.count)
        k[Drum.kick.rawValue] = DrumParams(toneLevel: 1.0, toneStart: 165, toneEnd: 50, pitchTau: 0.035, toneDecay: 0.42,
                                           noiseLevel: 0.05, noiseDecay: 0.03, noiseCutoff: 1200, noiseMode: .low,
                                           clickLevel: 0.35, clickDecay: 0.003, drive: 0.6, gain: 1.0, pan: 0)
        k[Drum.snare.rawValue] = DrumParams(toneLevel: 0.55, toneStart: 290, toneEnd: 190, pitchTau: 0.01, toneDecay: 0.16,
                                            noiseLevel: 0.85, noiseDecay: 0.26, noiseCutoff: 4200, noiseQ: 0.55, noiseMode: .band,
                                            clickLevel: 0.25, drive: 0.3, gain: 0.85, pan: 0)
        k[Drum.rim.rawValue] = DrumParams(toneLevel: 0.55, toneStart: 1700, toneEnd: 1500, pitchTau: 0.004, toneDecay: 0.045,
                                          noiseLevel: 0.45, noiseDecay: 0.035, noiseCutoff: 2600, noiseQ: 3, noiseMode: .band,
                                          clickLevel: 0.3, clickDecay: 0.002, gain: 0.7, pan: 0.05)
        k[Drum.clap.rawValue] = DrumParams(noiseLevel: 1.0, noiseDecay: 0.28, noiseCutoff: 1300, noiseQ: 1.3, noiseMode: .band,
                                           clap: true, gain: 0.85, pan: -0.05)
        k[Drum.hatClosed.rawValue] = DrumParams(noiseLevel: 0.35, noiseDecay: 0.05, noiseCutoff: 8500, noiseMode: .high,
                                                metalLevel: 0.75, metalScale: 1.0, metalDecay: 0.065, metalCutoff: 7200, metalQ: 0.8,
                                                metalMode: .high, gain: 0.42, pan: -0.32)
        k[Drum.hatPedal.rawValue] = DrumParams(noiseLevel: 0.25, noiseDecay: 0.035, noiseCutoff: 8000, noiseMode: .high,
                                               metalLevel: 0.7, metalScale: 1.0, metalDecay: 0.045, metalCutoff: 6800, metalQ: 0.8,
                                               metalMode: .high, attack: 0.002, gain: 0.3, pan: -0.32)
        k[Drum.hatOpen.rawValue] = DrumParams(noiseLevel: 0.35, noiseDecay: 0.42, noiseCutoff: 8500, noiseMode: .high,
                                              metalLevel: 0.75, metalScale: 1.0, metalDecay: 0.5, metalCutoff: 7000, metalQ: 0.8,
                                              metalMode: .high, gain: 0.36, pan: -0.32)
        k[Drum.ride.rawValue] = DrumParams(toneLevel: 0.1, toneStart: 540, toneEnd: 540, toneDecay: 0.6,
                                           noiseLevel: 0.12, noiseDecay: 0.5, noiseCutoff: 7000, noiseMode: .high,
                                           metalLevel: 0.6, metalScale: 1.45, metalDecay: 1.7, metalCutoff: 5200, metalQ: 0.9,
                                           metalMode: .band, gain: 0.34, pan: 0.38)
        k[Drum.rideBell.rawValue] = DrumParams(toneLevel: 0.45, toneStart: 780, toneEnd: 780, toneDecay: 1.1,
                                               metalLevel: 0.45, metalScale: 1.6, metalDecay: 1.3, metalCutoff: 3200, metalQ: 1.4,
                                               metalMode: .band, gain: 0.32, pan: 0.38)
        k[Drum.crash.rawValue] = DrumParams(noiseLevel: 0.6, noiseDecay: 1.9, noiseCutoff: 4200, noiseMode: .high,
                                            metalLevel: 0.5, metalScale: 1.7, metalDecay: 1.6, metalCutoff: 3600, metalQ: 0.7,
                                            metalMode: .high, attack: 0.001, gain: 0.42, pan: -0.25)
        k[Drum.tomHigh.rawValue] = DrumParams(toneLevel: 1.0, toneStart: 340, toneEnd: 245, pitchTau: 0.06, toneDecay: 0.36,
                                              noiseLevel: 0.12, noiseDecay: 0.06, noiseCutoff: 3000, noiseMode: .low,
                                              clickLevel: 0.12, gain: 0.72, pan: -0.15)
        k[Drum.tomMid.rawValue] = DrumParams(toneLevel: 1.0, toneStart: 255, toneEnd: 180, pitchTau: 0.07, toneDecay: 0.42,
                                             noiseLevel: 0.12, noiseDecay: 0.06, noiseCutoff: 2600, noiseMode: .low,
                                             clickLevel: 0.12, gain: 0.74, pan: 0.1)
        k[Drum.tomLow.rawValue] = DrumParams(toneLevel: 1.0, toneStart: 175, toneEnd: 112, pitchTau: 0.08, toneDecay: 0.55,
                                             noiseLevel: 0.12, noiseDecay: 0.07, noiseCutoff: 2000, noiseMode: .low,
                                             clickLevel: 0.12, gain: 0.8, pan: 0.32)
        k[Drum.cowbell.rawValue] = DrumParams(metalLevel: 1.0, metalScale: 1.0, metalDecay: 0.32, metalCutoff: 1800, metalQ: 1.6,
                                              metalMode: .band, cowbell: true, gain: 0.45, pan: 0.2)
        k[Drum.shaker.rawValue] = DrumParams(noiseLevel: 1.0, noiseDecay: 0.09, noiseCutoff: 6500, noiseQ: 0.8, noiseMode: .high,
                                             attack: 0.014, gain: 0.26, pan: 0.25)
        k[Drum.tambourine.rawValue] = DrumParams(noiseLevel: 0.5, noiseDecay: 0.16, noiseCutoff: 7500, noiseMode: .high,
                                                 metalLevel: 0.7, metalScale: 2.4, metalDecay: 0.22, metalCutoff: 8000, metalQ: 0.9,
                                                 metalMode: .high, attack: 0.002, gain: 0.3, pan: -0.2)
        // Maracas: shorter and drier than the shaker, a band of seeds rather than a hiss.
        k[Drum.maracas.rawValue] = DrumParams(noiseLevel: 1.0, noiseDecay: 0.05, noiseCutoff: 4800, noiseQ: 1.5, noiseMode: .band,
                                              attack: 0.004, gain: 0.3, pan: -0.3)
        return k
    }

    static func vintage() -> [DrumParams] {
        var k = studio()
        k[Drum.kick.rawValue].toneStart = 120; k[Drum.kick.rawValue].toneEnd = 46
        k[Drum.kick.rawValue].toneDecay = 0.5; k[Drum.kick.rawValue].clickLevel = 0.12; k[Drum.kick.rawValue].drive = 0.2
        k[Drum.snare.rawValue].toneLevel = 0.75; k[Drum.snare.rawValue].toneStart = 230; k[Drum.snare.rawValue].toneEnd = 175
        k[Drum.snare.rawValue].noiseCutoff = 2800; k[Drum.snare.rawValue].noiseDecay = 0.22
        for d in [Drum.hatClosed, .hatPedal, .hatOpen] {
            k[d.rawValue].metalCutoff = 5600; k[d.rawValue].noiseCutoff = 6500; k[d.rawValue].metalScale = 0.85
        }
        for d in [Drum.tomHigh, .tomMid, .tomLow] {
            k[d.rawValue].toneDecay *= 1.3; k[d.rawValue].toneStart *= 0.9; k[d.rawValue].toneEnd *= 0.92
        }
        k[Drum.ride.rawValue].metalCutoff = 4200
        k[Drum.crash.rawValue].noiseCutoff = 3200; k[Drum.crash.rawValue].metalCutoff = 2800
        return k
    }

    static func electro() -> [DrumParams] {
        var k = studio()
        k[Drum.kick.rawValue] = DrumParams(toneLevel: 1.0, toneStart: 120, toneEnd: 44, pitchTau: 0.055, toneDecay: 0.95,
                                           clickLevel: 0.15, clickDecay: 0.002, drive: 1.2, gain: 1.0)
        k[Drum.snare.rawValue] = DrumParams(toneLevel: 0.6, toneStart: 238, toneEnd: 180, pitchTau: 0.02, toneDecay: 0.12,
                                            noiseLevel: 0.8, noiseDecay: 0.2, noiseCutoff: 2200, noiseQ: 0.7, noiseMode: .high,
                                            gain: 0.8)
        k[Drum.clap.rawValue].gain = 1.0; k[Drum.clap.rawValue].noiseDecay = 0.35
        k[Drum.hatClosed.rawValue].metalDecay = 0.04; k[Drum.hatClosed.rawValue].noiseLevel = 0.1
        k[Drum.hatOpen.rawValue].metalDecay = 0.35; k[Drum.hatOpen.rawValue].noiseLevel = 0.1
        for d in [Drum.tomHigh, .tomMid, .tomLow] {
            k[d.rawValue].noiseLevel = 0; k[d.rawValue].clickLevel = 0; k[d.rawValue].toneDecay *= 1.5
            k[d.rawValue].pitchTau *= 1.4
        }
        k[Drum.rim.rawValue].toneStart = 1650; k[Drum.rim.rawValue].toneEnd = 1650; k[Drum.rim.rawValue].noiseLevel = 0.1
        return k
    }

    static func lofi() -> [DrumParams] {
        var k = vintage()
        k[Drum.kick.rawValue].drive = 1.5
        k[Drum.snare.rawValue].drive = 1.0
        for i in 0..<Drum.count { k[i].gain *= 1.05 }
        return k
    }

    static func brushes() -> [DrumParams] {
        var k = studio()
        k[Drum.kick.rawValue].toneDecay = 0.35; k[Drum.kick.rawValue].clickLevel = 0.05
        k[Drum.kick.rawValue].gain = 0.8; k[Drum.kick.rawValue].drive = 0
        // Brushed snare: soft attack, no tone body, darker, longer swish.
        k[Drum.snare.rawValue] = DrumParams(toneLevel: 0.15, toneStart: 220, toneEnd: 190, pitchTau: 0.01, toneDecay: 0.1,
                                            noiseLevel: 0.9, noiseDecay: 0.32, noiseCutoff: 3600, noiseQ: 0.5, noiseMode: .band,
                                            attack: 0.018, gain: 0.7)
        k[Drum.rim.rawValue].gain = 0.5
        k[Drum.ride.rawValue].metalDecay = 2.2; k[Drum.ride.rawValue].gain = 0.3
        k[Drum.hatPedal.rawValue].gain = 0.24
        for d in [Drum.tomHigh, .tomMid, .tomLow] { k[d.rawValue].clickLevel = 0; k[d.rawValue].gain *= 0.75 }
        k[Drum.crash.rawValue].gain = 0.3
        // Brush sweep: slow-swelling, band-limited swish (other synth kits leave it silent).
        k[Drum.brushSweep.rawValue] = DrumParams(noiseLevel: 0.8, noiseDecay: 4.0, noiseCutoff: 3400, noiseQ: 0.45,
                                                 noiseMode: .band, attack: 0.04, gain: 0.3, pan: 0)
        return k
    }

    /// Flat array of kitCount * Drum.count params.
    static func buildAll() -> [DrumParams] {
        studio() + vintage() + electro() + lofi() + brushes()
    }
}

// MARK: - DSP primitives

/// Topology-preserving state variable filter (Cytomic / Simper).
struct SVF {
    var a1: Float = 0, a2: Float = 0, a3: Float = 0, k: Float = 1
    var mode: Int = 0
    var ic1: Float = 0, ic2: Float = 0

    mutating func set(cutoff: Float, q: Float, sampleRate: Float, mode: FilterMode) {
        let fc = min(max(cutoff, 20), sampleRate * 0.45)
        let g = tanf(Float.pi * fc / sampleRate)
        k = 1 / max(q, 0.1)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
        self.mode = mode.rawValue
        ic1 = 0; ic2 = 0
    }

    @inline(__always)
    mutating func process(_ v0: Float) -> Float {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        switch mode {
        case 0: return v2
        case 1: return v1
        default: return v0 - k * v1 - v2
        }
    }
}

@inline(__always)
func whiteNoise(_ s: inout UInt32) -> Float {
    s ^= s << 13; s ^= s >> 17; s ^= s << 5
    return Float(Int32(bitPattern: s)) * (1.0 / 2147483648.0)
}

@inline(__always)
func softClip(_ x: Float) -> Float {
    let c = min(max(x, -3), 3)
    return c * (27 + c * c) / (27 + 9 * c * c)
}

// MARK: - Voice

struct Voice {
    var active = false
    var drum = 0
    var delay = 0
    var age = 0
    var chokeAt = -1
    var slowChoke = false      // sweep release (150 ms) instead of the 30 ms hi-hat choke
    var amp: Float = 0
    var gainL: Float = 0, gainR: Float = 0

    var toneLevel: Float = 0, toneEnv: Float = 0, toneCoef: Float = 0
    var pitchEnv: Float = 0, pitchCoef: Float = 0
    var toneStart: Float = 0, toneEnd: Float = 0, phase: Float = 0

    var noiseLevel: Float = 0, noiseEnv: Float = 0, noiseCoef: Float = 0
    var noiseFilter = SVF()

    var metalLevel: Float = 0, metalEnv: Float = 0, metalCoef: Float = 0
    var metalFilter = SVF()
    var metalCount = 6
    var mp0: Float = 0, mp1: Float = 0, mp2: Float = 0, mp3: Float = 0, mp4: Float = 0, mp5: Float = 0
    var mf0: Float = 0, mf1: Float = 0, mf2: Float = 0, mf3: Float = 0, mf4: Float = 0, mf5: Float = 0

    var clickLevel: Float = 0, clickEnv: Float = 0, clickCoef: Float = 0

    var clap = false
    var clapInterval = 1, clapBursts = 0
    var clapTailCoef: Float = 0

    var att: Float = 1, attInc: Float = 1
    var drive: Float = 0
    var rng: UInt32 = 0x1234567
}

// MARK: - Synth

/// Polyphonic drum synthesizer. All memory is allocated up front so that
/// `trigger` and `render` are safe to call on the audio thread.
public final class DrumSynth {
    static let voicesPerDrum = 2
    let voiceCount = Drum.count * DrumSynth.voicesPerDrum
    let voices: UnsafeMutablePointer<Voice>
    let kitParams: UnsafeMutablePointer<DrumParams>
    let kitCount: Int
    public var kit = 0
    let sampler = Sampler()
    var sampleRate: Float = 44100
    var invSR: Float = 1.0 / 44100
    var seed: UInt32 = 0x9E3779B9

    static let metalRatios: [Float] = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]

    public init() {
        voices = .allocate(capacity: voiceCount)
        voices.initialize(repeating: Voice(), count: voiceCount)
        let all = Kits.buildAll()
        kitCount = all.count / Drum.count
        kitParams = .allocate(capacity: all.count)
        kitParams.initialize(from: all, count: all.count)
    }

    deinit {
        voices.deinitialize(count: voiceCount); voices.deallocate()
        kitParams.deinitialize(count: kitCount * Drum.count); kitParams.deallocate()
    }

    public func setSampleRate(_ sr: Double) {
        sampleRate = Float(sr)
        invSR = 1 / sampleRate
        sampler.setSampleRate(sr)
        reset()
    }

    public func reset() {
        for i in 0..<voiceCount { voices[i].active = false }
        sampler.reset()
    }

    @inline(__always)
    private func t60(_ t: Float) -> Float {
        t <= 0 ? 0 : powf(0.001, 1 / (t * sampleRate))
    }

    /// Schedules a hit `delay` samples from the start of the next render call. `gain` scales its
    /// level without changing the velocity's tone (percussion layer level).
    /// `layer` uses the percussion-layer kit when one is selected; a layer shaker plays through the
    /// shaker stack (`back` = back stroke).
    public func trigger(_ drumIndex: Int, velocity: Float, delay: Int, gain: Float = 1, layer: Bool = false,
                        back: Bool = false) {
        guard drumIndex >= 0 && drumIndex < Drum.count else { return }
        // Sampled kit first; drums it lacks fall back to the synth.
        if layer && drumIndex == Drum.shaker.rawValue {
            if sampler.triggerShaker(velocity: velocity, delay: delay, gain: gain, back: back) { return }
        } else if layer {
            if sampler.triggerLayer(drumIndex, velocity: velocity, delay: delay, gain: gain) { return }
        } else if sampler.trigger(drumIndex, velocity: velocity, delay: delay, gain: gain) { return }
        let k = min(max(kit, 0), kitCount - 1)
        let p = kitParams[k * Drum.count + drumIndex]
        let vel = min(max(velocity, 0), 1)
        let d = max(delay, 0)

        // Hi-hat choke: closed/pedal/open hats cut a ringing open hat.
        if drumIndex == Drum.hatClosed.rawValue || drumIndex == Drum.hatPedal.rawValue
            || drumIndex == Drum.hatOpen.rawValue {
            let base = Drum.hatOpen.rawValue * DrumSynth.voicesPerDrum
            for j in base..<(base + DrumSynth.voicesPerDrum) where voices[j].active && voices[j].delay < d {
                voices[j].chokeAt = d - voices[j].delay
            }
        }

        let a = drumIndex * DrumSynth.voicesPerDrum
        let b = a + 1
        let idx: Int
        if !voices[a].active { idx = a }
        else if !voices[b].active { idx = b }
        else { idx = voices[a].age >= voices[b].age ? a : b }

        seed = seed &* 1664525 &+ 1013904223
        var v = Voice()
        v.active = true
        v.drum = drumIndex
        v.delay = d
        v.rng = seed | 1
        v.amp = p.gain * powf(vel, 1.5) * max(gain, 0)
        if drumIndex == Drum.brushSweep.rawValue {
            // Sustained sweep: release two beats after it starts (the next sweep overlaps it).
            v.chokeAt = d + max(Int(2 * sampler.beatFrames), Int(0.1 * sampleRate))
            v.slowChoke = true
        }
        let angle = (min(max(p.pan, -1), 1) + 1) * Float.pi / 4
        v.gainL = cosf(angle) * 1.41421356
        v.gainR = sinf(angle) * 1.41421356
        let bright: Float = 0.65 + 0.35 * vel

        v.toneLevel = p.toneLevel
        v.toneEnv = 1
        v.toneCoef = t60(p.toneDecay)
        v.pitchEnv = 1
        v.pitchCoef = p.pitchTau > 0 ? expf(-1 / (p.pitchTau * sampleRate)) : 0
        v.toneStart = p.toneStart
        v.toneEnd = p.toneEnd

        v.noiseLevel = p.noiseLevel
        v.noiseEnv = 1
        v.noiseFilter.set(cutoff: p.noiseCutoff * bright, q: p.noiseQ, sampleRate: sampleRate, mode: p.noiseMode)
        if p.clap {
            v.clap = true
            v.clapInterval = max(1, Int(0.011 * sampleRate))
            v.clapBursts = 4
            v.noiseCoef = t60(0.03)
            v.clapTailCoef = t60(p.noiseDecay)
        } else {
            v.noiseCoef = t60(p.noiseDecay)
        }

        v.metalLevel = p.metalLevel
        v.metalEnv = 1
        v.metalCoef = t60(p.metalDecay)
        v.metalFilter.set(cutoff: p.metalCutoff * bright, q: p.metalQ, sampleRate: sampleRate, mode: p.metalMode)
        let r = DrumSynth.metalRatios
        if p.cowbell {
            v.metalCount = 2
            v.mf0 = 540 * p.metalScale * invSR
            v.mf1 = 800 * p.metalScale * invSR
        } else {
            v.metalCount = 6
            v.mf0 = r[0] * p.metalScale * invSR; v.mf1 = r[1] * p.metalScale * invSR
            v.mf2 = r[2] * p.metalScale * invSR; v.mf3 = r[3] * p.metalScale * invSR
            v.mf4 = r[4] * p.metalScale * invSR; v.mf5 = r[5] * p.metalScale * invSR
        }
        v.mp1 = 0.31; v.mp2 = 0.67; v.mp3 = 0.13; v.mp4 = 0.89; v.mp5 = 0.45

        v.clickLevel = p.clickLevel * vel
        v.clickEnv = 1
        v.clickCoef = t60(p.clickDecay)

        let attackSamples = max(1, p.attack * sampleRate)
        v.att = 0
        v.attInc = 1 / attackSamples
        v.drive = p.drive
        voices[idx] = v
    }

    /// Adds `frames` samples of all active voices into the two output buffers.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        render(busesL: nil, busesR: nil, busCount: 0, left: left, right: right, frames: frames)
    }

    public func render(busesL: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?,
                       busesR: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?,
                       busCount: Int,
                       left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let twoPi = 2 * Float.pi
        let chokeCoef = t60(0.03), slowChokeCoef = t60(0.15)
        let multi = busesL != nil && busesR != nil && busCount > 1
        for vi in 0..<voiceCount {
            if !voices[vi].active { continue }
            var v = voices[vi]
            let mg = sampler.mixGain[min(max(v.drum, 0), Drum.count - 1)]
            let bus = multi ? MixBus.forDrumIndex(v.drum).rawValue : 0
            var i = 0
            while i < frames {
                if v.chokeAt >= 0 {
                    if v.chokeAt == 0 {
                        let c = v.slowChoke ? slowChokeCoef : chokeCoef
                        v.toneCoef = min(v.toneCoef, c)
                        v.noiseCoef = min(v.noiseCoef, c)
                        v.clapTailCoef = min(v.clapTailCoef, c)
                        v.metalCoef = min(v.metalCoef, c)
                    }
                    v.chokeAt -= 1
                }
                if v.delay > 0 { v.delay -= 1; i += 1; continue }

                var s: Float = 0
                if v.toneLevel > 0 {
                    let f = v.toneEnd + (v.toneStart - v.toneEnd) * v.pitchEnv
                    v.phase += f * invSR
                    if v.phase >= 1 { v.phase -= 1 }
                    s += sinf(twoPi * v.phase) * v.toneEnv * v.toneLevel
                    v.toneEnv *= v.toneCoef
                    v.pitchEnv *= v.pitchCoef
                }
                if v.noiseLevel > 0 {
                    if v.clap && v.age > 0 && v.age % v.clapInterval == 0 {
                        let burst = v.age / v.clapInterval
                        if burst < v.clapBursts { v.noiseEnv = 1 }
                        if burst == v.clapBursts - 1 { v.noiseCoef = v.clapTailCoef }
                    }
                    let n = whiteNoise(&v.rng)
                    s += v.noiseFilter.process(n) * v.noiseEnv * v.noiseLevel
                    v.noiseEnv *= v.noiseCoef
                }
                if v.metalLevel > 0 {
                    var m: Float = 0
                    v.mp0 += v.mf0; if v.mp0 >= 1 { v.mp0 -= 1 }; m += v.mp0 < 0.5 ? 1 : -1
                    v.mp1 += v.mf1; if v.mp1 >= 1 { v.mp1 -= 1 }; m += v.mp1 < 0.5 ? 1 : -1
                    if v.metalCount > 2 {
                        v.mp2 += v.mf2; if v.mp2 >= 1 { v.mp2 -= 1 }; m += v.mp2 < 0.5 ? 1 : -1
                        v.mp3 += v.mf3; if v.mp3 >= 1 { v.mp3 -= 1 }; m += v.mp3 < 0.5 ? 1 : -1
                        v.mp4 += v.mf4; if v.mp4 >= 1 { v.mp4 -= 1 }; m += v.mp4 < 0.5 ? 1 : -1
                        v.mp5 += v.mf5; if v.mp5 >= 1 { v.mp5 -= 1 }; m += v.mp5 < 0.5 ? 1 : -1
                        m *= 0.3
                    } else {
                        m *= 0.6
                    }
                    s += v.metalFilter.process(m) * v.metalEnv * v.metalLevel
                    v.metalEnv *= v.metalCoef
                }
                if v.clickLevel > 0 {
                    s += whiteNoise(&v.rng) * v.clickEnv * v.clickLevel
                    v.clickEnv *= v.clickCoef
                }
                if v.att < 1 {
                    s *= v.att
                    v.att = min(1, v.att + v.attInc)
                }
                if v.drive > 0 {
                    s = softClip(s * (1 + v.drive)) / (1 + v.drive * 0.35)
                }
                s *= v.amp * mg
                let sl = s * v.gainL
                let sr = s * v.gainR
                left[i] += sl
                right[i] += sr
                let di = min(max(v.drum, 0), Drum.count - 1)
                let pk = max(abs(sl), abs(sr))
                if pk > sampler.channelPeak[di] { sampler.channelPeak[di] = pk }
                if multi, bus > 0, bus < busCount {
                    busesL![bus][i] += sl
                    busesR![bus][i] += sr
                }
                v.age += 1

                if v.age & 63 == 0 {
                    let clapping = v.clap && v.age < v.clapInterval * v.clapBursts
                    let level = max(max(v.toneEnv * v.toneLevel, v.noiseEnv * v.noiseLevel),
                                    max(v.metalEnv * v.metalLevel, v.clickEnv * v.clickLevel))
                    if !clapping && level < 0.0002 {
                        v.active = false
                        break
                    }
                }
                i += 1
            }
            voices[vi] = v
        }
        sampler.render(busesL: busesL, busesR: busesR, busCount: busCount,
                       left: left, right: right, frames: frames)
    }
}
