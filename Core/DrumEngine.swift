import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free queue (UI -> audio thread).
final class CommandQueue: @unchecked Sendable {
    private let capacity = 128
    private let buffer: UnsafeMutablePointer<Int>
    private let head = Atomic<Int>(0)   // next write slot
    private let tail = Atomic<Int>(0)   // next read slot
    private let producerLock = NSLock() // serializes multiple UI producers (never taken on audio thread)

    init() {
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }
    deinit { buffer.deallocate() }

    func push(_ value: Int) {
        producerLock.lock(); defer { producerLock.unlock() }
        let h = head.load(ordering: .relaxed)
        let next = (h + 1) % capacity
        guard next != tail.load(ordering: .acquiring) else { return } // full: drop
        buffer[h] = value
        head.store(next, ordering: .releasing)
    }

    /// Audio thread only.
    func pop() -> Int? {
        let t = tail.load(ordering: .relaxed)
        guard t != head.load(ordering: .acquiring) else { return nil }
        let v = buffer[t]
        tail.store((t + 1) % capacity, ordering: .releasing)
        return v
    }
}

/// Float stored in an atomic so UI and audio threads can share it safely.
public final class AtomicFloat: @unchecked Sendable {
    private let storage: Atomic<UInt32>
    public init(_ v: Float) { storage = Atomic(v.bitPattern) }
    public var value: Float {
        get { Float(bitPattern: storage.load(ordering: .relaxed)) }
        set { storage.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

public final class AtomicInt: @unchecked Sendable {
    private let storage: Atomic<Int>
    public init(_ v: Int) { storage = Atomic(v) }
    public var value: Int {
        get { storage.load(ordering: .relaxed) }
        set { storage.store(newValue, ordering: .relaxed) }
    }
}

/// Parameter addresses shared by the engine and the AU parameter tree.
public enum ParamAddress: UInt64, CaseIterable, Sendable {
    case volume = 0, tempo, hostSync, kit, swing, humanize, song, followTransport, fillVolume, fillOrder
}

/// Snapshot of playback state for the UI (written by the audio thread).
public struct EngineStatus: Sendable {
    public var state: PlayState
    public var song: Int
    public var part: Int
    public var partCount: Int
    public var bar: Int
    public var barsInPattern: Int
    public var beat: Int
    public var beatsPerBar: Int
    public var pendingFill: Bool
    public var pendingTransition: Bool
    public var pendingOutro: Bool
    public var effectiveTempo: Double
    public var level: Float
    public var fillNumber: Int = 0     // which fill is playing (1-based), 0 = none
    public var fillCount: Int = 0      // fills available in the current part
    public var previewing = false      // a file is being auditioned
    public var previewProgress: Double = 0
}

/// Complete realtime drum engine. Create on any thread; call `render` from the
/// audio thread and everything else from the UI.
public final class DrumEngine: @unchecked Sendable {
    public let store = SongStore()
    let synth = DrumSynth()
    let sequencer: Sequencer
    private let commands = CommandQueue()

    // Parameters
    public let volume = AtomicFloat(0.8)
    public let tempo = AtomicFloat(120)
    public let hostSync = AtomicInt(1)
    public let kit = AtomicInt(0)
    public let swing = AtomicFloat(0)        // 0...100 (%)
    public let humanize = AtomicFloat(15)    // 0...100 (%)
    public let songParam = AtomicInt(0)
    public let followTransport = AtomicInt(0)
    public let fillOrder = AtomicInt(0)      // 0 in order, 1 random

    // Status (audio thread -> UI)
    private let sState = AtomicInt(0), sSong = AtomicInt(-1), sPart = AtomicInt(0), sPartCount = AtomicInt(0)
    private let sBar = AtomicInt(0), sBars = AtomicInt(0), sBeat = AtomicInt(0), sBeats = AtomicInt(4)
    private let sPending = AtomicInt(0)
    private let sTempo = AtomicFloat(120), sLevel = AtomicFloat(0)
    private let sFill = AtomicInt(0), sFillCount = AtomicInt(0)
    private let sPreview = AtomicInt(0), sPreviewProgress = AtomicFloat(0)

    private var sampleRate: Double = 44100
    public private(set) var maxFrames = 4096
    public private(set) var scratchL: UnsafeMutablePointer<Float>
    public private(set) var scratchR: UnsafeMutablePointer<Float>
    /// Per MixBus stereo scratch (bus 0 unused — master uses scratchL/R).
    private var busL: UnsafeMutablePointer<UnsafeMutablePointer<Float>>!
    private var busR: UnsafeMutablePointer<UnsafeMutablePointer<Float>>!
    private var lpL: Float = 0, lpR: Float = 0
    private var wasHostPlaying = false
    private let sampleKitSlot = Atomic<Int>(0)   // published LoadedSampleKit (raw bits), 0 = none
    private let sampleKitAck = Atomic<Int>(0)    // kit the audio thread is currently using
    private var levelMeter: Float = 0
    /// Ballistic per-drum meters (audio thread writes, UI reads).
    private let channelMeter: UnsafeMutablePointer<Float>
    /// Peak-hold countdown in seconds (classic digital peak meter feel).
    private let channelHold: UnsafeMutablePointer<Float>
    /// Last multi-bus render identity (host may pull each bus separately).
    private var lastBusRenderTime: Float64 = .nan
    private var lastBusRenderFrames = 0

    public init() {
        sequencer = Sequencer(store: store, synth: synth)
        scratchL = .allocate(capacity: maxFrames)
        scratchR = .allocate(capacity: maxFrames)
        scratchL.initialize(repeating: 0, count: maxFrames)
        scratchR.initialize(repeating: 0, count: maxFrames)
        channelMeter = .allocate(capacity: Drum.count)
        channelMeter.initialize(repeating: 0, count: Drum.count)
        channelHold = .allocate(capacity: Drum.count)
        channelHold.initialize(repeating: 0, count: Drum.count)
        allocateBuses(frames: maxFrames)
    }

    deinit {
        freeBuses()
        scratchL.deallocate(); scratchR.deallocate()
        channelMeter.deallocate()
        channelHold.deallocate()
    }

    /// Peak level 0…1 for a mixer channel (after gain), with release ballistics.
    public func channelLevel(_ drum: Drum) -> Float { channelMeter[drum.rawValue] }

    private func allocateBuses(frames: Int) {
        freeBuses()
        busL = .allocate(capacity: MixBus.count)
        busR = .allocate(capacity: MixBus.count)
        for i in 0..<MixBus.count {
            if i == MixBus.master.rawValue {
                busL[i] = scratchL
                busR[i] = scratchR
            } else {
                busL[i] = .allocate(capacity: frames)
                busR[i] = .allocate(capacity: frames)
                busL[i].initialize(repeating: 0, count: frames)
                busR[i].initialize(repeating: 0, count: frames)
            }
        }
    }

    private func freeBuses() {
        guard busL != nil else { return }
        for i in 0..<MixBus.count where i != MixBus.master.rawValue {
            busL[i].deallocate(); busR[i].deallocate()
        }
        busL.deallocate(); busR.deallocate()
        busL = nil; busR = nil
    }

    /// Call before rendering starts (not on the audio thread).
    public func prepare(sampleRate: Double, maxFrames: Int) {
        self.sampleRate = sampleRate
        synth.setSampleRate(sampleRate)
        sequencer.sampleRate = sampleRate
        sequencer.stop()
        if maxFrames > self.maxFrames {
            freeBuses()
            scratchL.deallocate(); scratchR.deallocate()
            self.maxFrames = maxFrames
            scratchL = .allocate(capacity: maxFrames)
            scratchR = .allocate(capacity: maxFrames)
            scratchL.initialize(repeating: 0, count: maxFrames)
            scratchR.initialize(repeating: 0, count: maxFrames)
            allocateBuses(frames: maxFrames)
        }
        lastBusRenderTime = .nan
    }

    /// Live per-drum mixer gain (linear, 0…2). Applies immediately on the audio thread.
    public func setMixGain(drum: Drum, _ gain: Float) {
        synth.sampler.mixGain[drum.rawValue] = min(max(gain, 0), 2)
    }
    public func mixGain(drum: Drum) -> Float { synth.sampler.mixGain[drum.rawValue] }
    public func resetMixGains() {
        for i in 0..<Drum.count { synth.sampler.mixGain[i] = 1 }
    }

    // MARK: UI API

    public func send(_ command: PedalCommand) { commands.push(command.rawValue) }
    public func gotoPart(_ index: Int) { commands.push(PedalCommand.gotoPartBase.rawValue + index) }

    /// Auditions a stored pattern with the current kit and tempo (stops pedal playback).
    public func preview(pattern: Int32, loop: Bool) {
        guard pattern >= 0 else { return }
        sPreview.value = 1   // shown immediately; the audio thread confirms
        commands.push(PreviewCommand.base + Int(pattern) * 2 + (loop ? 1 : 0))
    }
    public func stopPreview() { sPreview.value = 0; commands.push(PreviewCommand.stop) }

    public func setParameter(_ address: ParamAddress, _ value: Float) {
        switch address {
        case .volume: volume.value = min(max(value, 0), 1.5)
        case .tempo: tempo.value = min(max(value, 30), 300)
        case .hostSync: hostSync.value = value >= 0.5 ? 1 : 0
        case .kit: kit.value = min(max(Int(value.rounded()), 0), KitManager.maxKits - 1)
        case .swing: swing.value = min(max(value, 0), 100)
        case .humanize: humanize.value = min(max(value, 0), 100)
        case .song: songParam.value = max(Int(value.rounded()), 0)
        case .followTransport: followTransport.value = value >= 0.5 ? 1 : 0
        case .fillVolume: break
        case .fillOrder: fillOrder.value = value >= 0.5 ? 1 : 0
        }
    }

    public func parameter(_ address: ParamAddress) -> Float {
        switch address {
        case .volume: volume.value
        case .tempo: tempo.value
        case .hostSync: Float(hostSync.value)
        case .kit: Float(kit.value)
        case .swing: swing.value
        case .humanize: humanize.value
        case .song: Float(songParam.value)
        case .followTransport: Float(followTransport.value)
        case .fillVolume: 1
        case .fillOrder: Float(fillOrder.value)
        }
    }

    /// Hands a loaded sample kit to the audio thread (see KitManager).
    func publishSampleKit(bits: Int) { sampleKitSlot.store(bits, ordering: .releasing) }
    var publishedSampleKit: Int { sampleKitSlot.load(ordering: .acquiring) }
    var sampleKitInUse: Int { sampleKitAck.load(ordering: .acquiring) }

    public var status: EngineStatus {
        let pending = sPending.value
        return EngineStatus(state: PlayState(rawValue: sState.value) ?? .stopped, song: sSong.value,
                            part: sPart.value, partCount: sPartCount.value, bar: sBar.value,
                            barsInPattern: sBars.value, beat: sBeat.value, beatsPerBar: sBeats.value,
                            pendingFill: pending & 1 != 0, pendingTransition: pending & 2 != 0,
                            pendingOutro: pending & 4 != 0, effectiveTempo: Double(sTempo.value),
                            level: sLevel.value, fillNumber: sFill.value, fillCount: sFillCount.value,
                            previewing: sPreview.value != 0, previewProgress: Double(sPreviewProgress.value))
    }

    // MARK: Audio thread API

    /// Handles a MIDI 1.0 channel message. Notes 0-11 are pedal commands,
    /// GM percussion notes play the kit, program change selects a song,
    /// CC 80-87 are footswitch commands.
    public func handleMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, offset: Int) {
        let type = status & 0xF0
        switch type {
        case 0x90 where d2 > 0:
            if d1 <= 11 {
                switch d1 {
                case 0: sequencer.handle(PedalCommand.pedalTap.rawValue)
                case 1: sequencer.handle(PedalCommand.startStop.rawValue)
                case 2: sequencer.handle(PedalCommand.fill.rawValue)
                case 3: sequencer.handle(PedalCommand.transition.rawValue)
                case 4: sequencer.handle(PedalCommand.outro.rawValue)
                case 5: sequencer.handle(PedalCommand.stop.rawValue)
                case 6: sequencer.handle(PedalCommand.accent.rawValue)
                case 7: sequencer.handle(PedalCommand.pauseResume.rawValue)
                case 8: sequencer.handle(PedalCommand.nextSong.rawValue); songParam.value = sequencer.requestedSong
                case 9: sequencer.handle(PedalCommand.prevSong.rawValue); songParam.value = sequencer.requestedSong
                default: break
                }
            } else if let drum = Drum.fromGM(d1) {
                sequencer.playDrum(drum.rawValue, velocity: Float(d2) / 127, offset: offset)
            }
        case 0xB0 where d2 >= 64:
            switch d1 {
            case 80: sequencer.handle(PedalCommand.pedalTap.rawValue)
            case 81: sequencer.handle(PedalCommand.transition.rawValue)
            case 82: sequencer.handle(PedalCommand.outro.rawValue)
            case 83: sequencer.handle(PedalCommand.accent.rawValue)
            case 84: sequencer.handle(PedalCommand.pauseResume.rawValue)
            case 85: sequencer.handle(PedalCommand.stop.rawValue)
            default: break
            }
        case 0xC0:
            if Int(d1) < store.count { songParam.value = Int(d1) }
        default:
            break
        }
    }

    /// Call at the start of each render cycle, before handleMIDI.
    public func beginRender() {
        sequencer.beginBuffer()
        while let c = commands.pop() { sequencer.handle(c) }
    }

    /// Renders `frames` stereo samples (replacing buffer contents). Master only.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                       hostTempo: Double?, hostPlaying: Bool?) {
        _ = renderAllBuses(frames: frames, sampleTime: .nan, hostTempo: hostTempo, hostPlaying: hostPlaying)
        if left != scratchL { left.update(from: scratchL, count: frames) }
        if right != scratchR { right.update(from: scratchR, count: frames) }
    }

    /// True when the next `renderAllBuses` will actually recompute (not a multi-out cache hit).
    public func isNewRenderCycle(sampleTime: Float64, frames: Int) -> Bool {
        !(sampleTime == lastBusRenderTime && frames == lastBusRenderFrames && !sampleTime.isNaN)
    }

    /// Ensures all MixBus buffers are filled for this host render cycle, then copies `bus` out.
    public func renderBus(_ bus: Int, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                          sampleTime: Float64, hostTempo: Double?, hostPlaying: Bool?) {
        _ = renderAllBuses(frames: frames, sampleTime: sampleTime, hostTempo: hostTempo, hostPlaying: hostPlaying)
        let b = min(max(bus, 0), MixBus.count - 1)
        left.update(from: busL[b], count: frames)
        right.update(from: busR[b], count: frames)
    }

    /// Renders master + subgroups into internal bus buffers. Returns false if `frames` is too large.
    @discardableResult
    public func renderAllBuses(frames: Int, sampleTime: Float64, hostTempo: Double?, hostPlaying: Bool?) -> Bool {
        guard frames <= maxFrames else { return false }
        // Same cycle (multi-out hosts pull each bus): reuse buffers.
        if !isNewRenderCycle(sampleTime: sampleTime, frames: frames) {
            return true
        }
        lastBusRenderTime = sampleTime
        lastBusRenderFrames = frames

        // Host transport follow.
        if let playing = hostPlaying, followTransport.value == 1 {
            if playing && !wasHostPlaying && sequencer.state == .stopped { sequencer.handle(PedalCommand.start.rawValue) }
            if !playing && wasHostPlaying && sequencer.state != .stopped { sequencer.handle(PedalCommand.stop.rawValue) }
            wasHostPlaying = playing
        }

        if songParam.value != sequencer.requestedSong {
            sequencer.requestedSong = min(songParam.value, max(store.count - 1, 0))
        }
        let kitBits = sampleKitSlot.load(ordering: .acquiring)
        if kitBits != synth.sampler.kitBits {
            synth.sampler.setKit(bits: kitBits)
            sampleKitAck.store(kitBits, ordering: .releasing)
        }
        let kitIndex = kit.value
        let sampled = kitIndex >= Kits.all.count
        synth.kit = sampled ? (synth.sampler.fallbackSynthKit ?? 0) : kitIndex
        sequencer.swing = Double(swing.value) / 100
        sequencer.fillOrder = fillOrder.value
        sequencer.humanize = Double(humanize.value) / 100
        var bpm = Double(tempo.value)
        if hostSync.value == 1, let ht = hostTempo, ht > 0 { bpm = ht }

        scratchL.update(repeating: 0, count: frames)
        scratchR.update(repeating: 0, count: frames)
        for i in 1..<MixBus.count {
            busL[i].update(repeating: 0, count: frames)
            busR[i].update(repeating: 0, count: frames)
        }
        synth.sampler.clearChannelPeaks()

        synth.sampler.beatFrames = sampleRate * 60 / max(bpm, 1)
        let chunk = 64
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            sequencer.advance(frames: n, chunkOffset: done, tempo: bpm)
            // Offset subgroup pointers for this chunk.
            var chunkL = [UnsafeMutablePointer<Float>](repeating: scratchL, count: MixBus.count)
            var chunkR = [UnsafeMutablePointer<Float>](repeating: scratchR, count: MixBus.count)
            for b in 0..<MixBus.count {
                chunkL[b] = busL[b] + done
                chunkR[b] = busR[b] + done
            }
            chunkL.withUnsafeMutableBufferPointer { lBuf in
                chunkR.withUnsafeMutableBufferPointer { rBuf in
                    synth.render(busesL: lBuf.baseAddress, busesR: rBuf.baseAddress, busCount: MixBus.count,
                                 left: scratchL + done, right: scratchR + done, frames: n)
                }
            }
            done += n
        }

        // Master: kit tone filter, volume, soft clip, meter.
        let cutoff: Float = sampled ? 20000 : Kits.all[min(max(kitIndex, 0), Kits.all.count - 1)].masterCutoff
        let lpCoef: Float = cutoff >= 19000 ? 1 : 1 - expf(-2 * Float.pi * cutoff / Float(sampleRate))
        let vol = volume.value
        var peak: Float = 0
        for i in 0..<frames {
            var l = scratchL[i], r = scratchR[i]
            if lpCoef < 1 {
                lpL += lpCoef * (l - lpL); lpR += lpCoef * (r - lpR)
                l = lpL; r = lpR
            }
            l = softClip(l * vol); r = softClip(r * vol)
            scratchL[i] = l; scratchR[i] = r
            peak = max(peak, abs(l), abs(r))
        }
        // Soft-clip subgroups with the same master volume so inserts sit at a usable level.
        for b in 1..<MixBus.count {
            let bl = busL[b], br = busR[b]
            for i in 0..<frames {
                bl[i] = softClip(bl[i] * vol)
                br[i] = softClip(br[i] * vol)
            }
        }
        levelMeter = max(peak, levelMeter * 0.85)
        // Channel meters: instant attack, ~350 ms peak hold, ~1.2 s for a 20 dB fall.
        let dt = Float(frames) / Float(max(sampleRate, 1))
        let holdSec: Float = 0.35
        let releaseTau: Float = 0.52   // exp(-1.2/0.52) ≈ 0.1 → ~20 dB in 1.2 s
        let releaseCoef = expf(-dt / releaseTau)
        for i in 0..<Drum.count {
            let p = min(synth.sampler.channelPeak[i], 1.5) / 1.5
            if p >= channelMeter[i] - 0.0001 {
                channelMeter[i] = p
                channelHold[i] = holdSec
            } else if channelHold[i] > 0 {
                channelHold[i] -= dt
            } else {
                channelMeter[i] *= releaseCoef
                if channelMeter[i] < 0.0005 { channelMeter[i] = 0 }
            }
        }

        // Publish status.
        let s = sequencer
        sState.value = s.state.rawValue
        sSong.value = s.hasSong ? s.song : -1
        sPart.value = s.part
        sPartCount.value = s.partCount
        sBar.value = s.barInPattern
        sBars.value = s.barsInPattern
        sBeat.value = s.beatInBar
        sBeats.value = s.beatTicks > 0 ? max(1, s.barTicks / s.beatTicks) : 4
        sPending.value = (s.pendingFill ? 1 : 0) | (s.pendingTransition ? 2 : 0) | (s.pendingOutro ? 4 : 0)
        sTempo.value = Float(bpm)
        sLevel.value = levelMeter
        sFill.value = s.state == .fill ? s.currentFill : 0
        sFillCount.value = s.fillCountInPart
        sPreview.value = s.isPreviewing ? 1 : 0
        sPreviewProgress.value = Float(s.previewProgress)
        return true
    }

    /// MIDI notes produced during the last render (for MIDI output).
    public func forEachOutputEvent(_ body: (Int, UInt8, UInt8) -> Void) {
        for i in 0..<sequencer.outCount {
            let e = sequencer.outEvents[i]
            body(Int(e.offset), e.note, e.velocity)
        }
    }
}
