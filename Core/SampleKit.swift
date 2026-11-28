import Foundation
import AudioToolbox
import Synchronization

// MARK: - .pbkit file format
//
// A PedalBeat kit is a single Core Audio Format file (Apple Lossless, stereo,
// 16-bit) holding every sample of the kit back to back, plus a custom 'pbkt'
// chunk with a JSON manifest that maps drums -> velocity layers -> round-robin
// regions inside the audio stream. Any CAF reader can still play the audio.

public struct KitManifest: Codable, Sendable {
    public struct Region: Codable, Sendable {
        public var start: Int      // frame offset in the audio stream
        public var length: Int     // frames
        public var gain: Float     // linear gain to restore the recorded level
        public init(start: Int, length: Int, gain: Float) { self.start = start; self.length = length; self.gain = gain }
    }
    public struct Layer: Codable, Sendable {
        public var hiVelocity: Int // 1...127, layers sorted ascending
        public var regions: [Region]
        public init(hiVelocity: Int, regions: [Region]) { self.hiVelocity = hiVelocity; self.regions = regions }
    }
    public struct DrumMap: Codable, Sendable {
        public var volume: Float = 1
        public var pan: Float = 0  // -1...1 balance applied on top of the stereo sample
        public var layers: [Layer]
        /// Sustained sweep: regions are long continuous recordings played from a random
        /// point until the next sweep (crossfaded) or two beats, then released.
        public var sweep: Bool?
        public init(volume: Float = 1, pan: Float = 0, layers: [Layer], sweep: Bool? = nil) {
            self.volume = volume; self.pan = pan; self.layers = layers; self.sweep = sweep
        }
    }

    public var format = 1
    public var id: String
    public var name: String
    public var category: String          // "acoustic", "jazz", "brushes", ...
    public var author: String
    public var license: String
    public var source: String
    public var notes: String = ""
    public var sampleRate: Double
    public var frames: Int
    public var fallbackSynthKit = 0      // synthesized kit used for drums the kit lacks
    public var suggestFor: [Int] = []    // synth-kit hints (song kitHint) this kit can stand in for
    public var drums: [String: DrumMap]  // key = Drum.key

    public init(id: String, name: String, category: String, author: String, license: String, source: String,
                notes: String = "", sampleRate: Double, frames: Int, fallbackSynthKit: Int = 0,
                suggestFor: [Int] = [], drums: [String: DrumMap]) {
        self.id = id; self.name = name; self.category = category; self.author = author; self.license = license
        self.source = source; self.notes = notes; self.sampleRate = sampleRate; self.frames = frames
        self.fallbackSynthKit = fallbackSynthKit; self.suggestFor = suggestFor; self.drums = drums
    }
}

extension Drum {
    /// Stable identifier used in kit manifests.
    public var key: String { String(describing: self) }
    public static func named(_ key: String) -> Drum? { Drum.allCases.first { $0.key == key } }
}

public enum KitFileError: LocalizedError {
    case notAKit, badManifest(String), audio(OSStatus), unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .notAKit: "This file is not a PedalBeat kit (.pbkit)."
        case .badManifest(let m): "The kit file is damaged: \(m)"
        case .audio(let s): "The kit's audio could not be decoded (error \(s))."
        case .unsupportedVersion(let v): "This kit needs a newer version of PedalBeat (format \(v))."
        }
    }
}

public enum KitFile {
    static let chunkType: [UInt8] = Array("pbkt".utf8)

    /// Reads only the manifest (fast; used for validation and listing).
    public static func readManifest(url: URL) throws -> KitManifest {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard let head = try fh.read(upToCount: 8), head.count == 8, Array(head.prefix(4)) == Array("caff".utf8)
        else { throw KitFileError.notAKit }
        var offset: UInt64 = 8
        let end = try fh.seekToEnd()
        while offset + 12 <= end {
            try fh.seek(toOffset: offset)
            guard let hdr = try fh.read(upToCount: 12), hdr.count == 12 else { break }
            let type = Array(hdr.prefix(4))
            var size: Int64 = 0
            for b in hdr[4..<12] { size = size << 8 | Int64(b) }
            if type == chunkType {
                guard size > 0, size < 16 << 20, let json = try fh.read(upToCount: Int(size)) else { throw KitFileError.notAKit }
                let m: KitManifest
                do { m = try JSONDecoder().decode(KitManifest.self, from: json) }
                catch { throw KitFileError.badManifest(error.localizedDescription) }
                guard m.format == 1 else { throw KitFileError.unsupportedVersion(m.format) }
                return m
            }
            if size < 0 { break } // open-ended data chunk: must be last
            offset += 12 + UInt64(size)
        }
        throw KitFileError.notAKit
    }

    static func clientFormat(_ sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    }

    /// Decodes the whole audio stream as interleaved stereo Int16.
    static func readAudio(url: URL, manifest: KitManifest) throws -> UnsafeMutableBufferPointer<Int16> {
        var fileID: AudioFileID?
        var st = AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileCAFType, &fileID)
        guard st == noErr, let fileID else { throw KitFileError.audio(st) }
        defer { AudioFileClose(fileID) }
        var ext: ExtAudioFileRef?
        st = ExtAudioFileWrapAudioFileID(fileID, false, &ext)
        guard st == noErr, let ext else { throw KitFileError.audio(st) }
        defer { ExtAudioFileDispose(ext) }
        var fmt = clientFormat(manifest.sampleRate)
        st = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &fmt)
        guard st == noErr else { throw KitFileError.audio(st) }

        let frames = manifest.frames
        let buf = UnsafeMutableBufferPointer<Int16>.allocate(capacity: frames * 2)
        buf.initialize(repeating: 0)
        var done = 0
        while done < frames {
            var n = UInt32(min(16384, frames - done))
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: n * 4, mData: UnsafeMutableRawPointer(buf.baseAddress! + done * 2)))
            st = ExtAudioFileRead(ext, &n, &abl)
            if st != noErr { buf.deallocate(); throw KitFileError.audio(st) }
            if n == 0 { break }
            done += Int(n)
        }
        return buf
    }

    /// Writes a kit file. `audio` is interleaved stereo Int16 at `manifest.sampleRate`.
    public static func write(url: URL, manifest: KitManifest, audio: [Int16]) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var alac = AudioStreamBasicDescription(mSampleRate: manifest.sampleRate, mFormatID: kAudioFormatAppleLossless,
                                               mFormatFlags: AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData),
                                               mBytesPerPacket: 0, mFramesPerPacket: 4096, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var ext: ExtAudioFileRef?
        var st = ExtAudioFileCreateWithURL(tmp as CFURL, kAudioFileCAFType, &alac, nil,
                                           AudioFileFlags.eraseFile.rawValue, &ext)
        guard st == noErr, let ext else { throw KitFileError.audio(st) }
        var fmt = clientFormat(manifest.sampleRate)
        st = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &fmt)
        guard st == noErr else { ExtAudioFileDispose(ext); throw KitFileError.audio(st) }
        var samples = audio
        let frames = audio.count / 2
        var done = 0
        try samples.withUnsafeMutableBufferPointer { p in
            while done < frames {
                let n = min(16384, frames - done)
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(p.baseAddress! + done * 2)))
                st = ExtAudioFileWrite(ext, UInt32(n), &abl)
                guard st == noErr else { throw KitFileError.audio(st) }
                done += n
            }
        }
        st = ExtAudioFileDispose(ext)
        guard st == noErr else { throw KitFileError.audio(st) }

        // Append the manifest chunk.
        var data = try Data(contentsOf: tmp)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = try enc.encode(manifest)
        data.append(contentsOf: chunkType)
        var size = Int64(json.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(json)
        try data.write(to: url, options: .atomic)
        _ = try readManifest(url: url) // sanity: data chunk must have a definite size
    }
}

// MARK: - In-memory kit (immutable once published; no ARC on the audio thread)

struct SRegion { var start: Int; var length: Int; var gain: Float }
struct SLayer { var hiVel: Float; var first: Int; var count: Int }
struct SDrum { var firstLayer: Int; var layerCount: Int; var gainL: Float; var gainR: Float; var sweep = false }

/// Plain struct of raw pointers so the audio thread can use it without retain/release.
struct SampleKitRaw {
    var audio: UnsafeMutablePointer<Int16>
    var frames: Int
    var sampleRate: Double
    var drums: UnsafeMutablePointer<SDrum>      // Drum.count entries
    var layers: UnsafeMutablePointer<SLayer>
    var regions: UnsafeMutablePointer<SRegion>
    var fallbackSynthKit: Int
}

/// Owns the memory of a loaded kit. Deallocate only after the audio thread
/// has stopped using it (see `KitManager`).
public final class LoadedSampleKit: @unchecked Sendable {
    public let manifest: KitManifest
    let raw: UnsafeMutablePointer<SampleKitRaw>
    private let audio: UnsafeMutableBufferPointer<Int16>
    private let layerCount: Int, regionCount: Int
    var bits: Int { Int(bitPattern: raw) }
    public var memoryBytes: Int { audio.count * 2 }

    public init(url: URL) throws {
        let m = try KitFile.readManifest(url: url)
        manifest = m
        audio = try KitFile.readAudio(url: url, manifest: m)

        var drums = [SDrum](repeating: SDrum(firstLayer: 0, layerCount: 0, gainL: 0, gainR: 0), count: Drum.count)
        var layers: [SLayer] = []
        var regions: [SRegion] = []
        for d in Drum.allCases {
            guard let map = m.drums[d.key] else { continue }
            let first = layers.count
            for l in map.layers.sorted(by: { $0.hiVelocity < $1.hiVelocity }) {
                let valid = l.regions.filter { $0.start >= 0 && $0.length > 4 && $0.start + $0.length <= m.frames }
                guard !valid.isEmpty else { continue }
                layers.append(SLayer(hiVel: Float(min(max(l.hiVelocity, 1), 127)), first: regions.count, count: valid.count))
                regions += valid.map { SRegion(start: $0.start, length: $0.length, gain: $0.gain) }
            }
            let pan = min(max(map.pan, -1), 1)
            drums[d.rawValue] = SDrum(firstLayer: first, layerCount: layers.count - first,
                                      gainL: map.volume * min(1, 1 - pan), gainR: map.volume * min(1, 1 + pan),
                                      sweep: map.sweep ?? false)
        }
        if layers.isEmpty { audio.deallocate(); throw KitFileError.badManifest("no playable samples") }
        layerCount = layers.count; regionCount = regions.count
        let dp = UnsafeMutablePointer<SDrum>.allocate(capacity: Drum.count); dp.initialize(from: drums, count: Drum.count)
        let lp = UnsafeMutablePointer<SLayer>.allocate(capacity: layers.count); lp.initialize(from: layers, count: layers.count)
        let rp = UnsafeMutablePointer<SRegion>.allocate(capacity: regions.count); rp.initialize(from: regions, count: regions.count)
        raw = .allocate(capacity: 1)
        raw.initialize(to: SampleKitRaw(audio: audio.baseAddress!, frames: m.frames, sampleRate: m.sampleRate,
                                        drums: dp, layers: lp, regions: rp, fallbackSynthKit: m.fallbackSynthKit))
    }

    deinit {
        let r = raw.pointee
        r.drums.deallocate(); r.layers.deallocate(); r.regions.deallocate()
        raw.deallocate()
        audio.deallocate()
    }
}

// MARK: - Sample playback voices (audio thread)

struct SampleVoice {
    var active = false
    var drum = 0
    var delay = 0
    var start = 0          // first frame (absolute in kit audio)
    var length = 0
    var pos: Double = 0    // relative position in frames
    var step: Double = 1
    var gL: Float = 0, gR: Float = 0
    var fade: Float = 1, fadeStep: Float = 0
    var chokeAt = -1
    var chokeFade: Float = 0   // per-voice choke speed (0 = default hi-hat choke)
    var attack: Float = 1, rise: Float = 0
    var releaseIn = -1         // frames of playback before an automatic release
    var releaseStep: Float = 0
    var serial = 0
}

final class Sampler {
    static let voicesPerDrum = 5
    let voiceCount = Drum.count * Sampler.voicesPerDrum
    let voices: UnsafeMutablePointer<SampleVoice>
    /// Live mixer gains (linear), default 1. Applied at render so faders move instantly.
    let mixGain: UnsafeMutablePointer<Float>
    /// Per-drum peak for the current render block (absolute sample level). Cleared by the engine.
    let channelPeak: UnsafeMutablePointer<Float>
    private var kit: SampleKitRaw?
    private(set) var kitBits = 0
    private var outRate: Double = 44100
    private var rng: UInt32 = 0x2545F491
    private var serial = 0
    private var lastRegion = [Int](repeating: -1, count: Drum.count)
    /// Output frames per beat at the current tempo (set by the engine every render).
    var beatFrames: Double = 22050

    init() {
        voices = .allocate(capacity: voiceCount)
        voices.initialize(repeating: SampleVoice(), count: voiceCount)
        mixGain = .allocate(capacity: Drum.count)
        mixGain.initialize(repeating: 1, count: Drum.count)
        channelPeak = .allocate(capacity: Drum.count)
        channelPeak.initialize(repeating: 0, count: Drum.count)
    }
    deinit { voices.deallocate(); mixGain.deallocate(); channelPeak.deallocate() }

    func clearChannelPeaks() {
        channelPeak.update(repeating: 0, count: Drum.count)
    }

    var fallbackSynthKit: Int? { kit?.fallbackSynthKit }

    func setSampleRate(_ sr: Double) { outRate = sr; reset() }
    func reset() { for i in 0..<voiceCount { voices[i].active = false } }

    /// Audio thread: switch to the kit at `bits` (0 = none). Stops all voices.
    func setKit(bits: Int) {
        reset()
        kitBits = bits
        kit = UnsafeMutablePointer<SampleKitRaw>(bitPattern: bits)?.pointee
        for i in 0..<Drum.count { lastRegion[i] = -1 }
    }

    func has(_ drum: Int) -> Bool {
        guard let k = kit else { return false }
        return k.drums[drum].layerCount > 0
    }

    @inline(__always) private func random() -> UInt32 {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return rng
    }

    /// Returns false if the active kit has no sample for this drum.
    func trigger(_ drum: Int, velocity: Float, delay: Int, gain: Float = 1) -> Bool {
        guard let k = kit else { return false }
        let d = k.drums[drum]
        guard d.layerCount > 0 else { return false }
        let v127 = min(max(velocity, 0.0), 1.0) * 127

        // Velocity layer (with a little randomness at layer edges for realism).
        var li = d.layerCount - 1
        for i in 0..<d.layerCount where v127 <= k.layers[d.firstLayer + i].hiVel { li = i; break }
        let layer = k.layers[d.firstLayer + li]
        // Round robin: random, never the same region twice in a row.
        var ri = layer.first + Int(random() % UInt32(layer.count))
        if layer.count > 1 && ri == lastRegion[drum] { ri = layer.first + (ri - layer.first + 1) % layer.count }
        lastRegion[drum] = ri
        let region = k.regions[ri]
        let dyn = powf(max(v127, 1) / layer.hiVel, 0.55) * max(gain, 0)

        let dly = max(delay, 0)
        if d.sweep { return triggerSweep(drum, d: d, region: region, gain: region.gain * dyn, delay: dly, kit: k) }
        // Hi-hat choke.
        if drum == Drum.hatClosed.rawValue || drum == Drum.hatPedal.rawValue {
            let base = Drum.hatOpen.rawValue * Sampler.voicesPerDrum
            for j in base..<(base + Sampler.voicesPerDrum) where voices[j].active && voices[j].delay <= dly {
                voices[j].chokeAt = dly - voices[j].delay
            }
        }

        // Voice slot: free one in this drum's range, else steal the oldest.
        let base = drum * Sampler.voicesPerDrum
        var slot = -1, oldest = base, activeCount = 0
        for j in base..<(base + Sampler.voicesPerDrum) {
            if !voices[j].active { if slot < 0 { slot = j } } else {
                activeCount += 1
                if voices[j].serial < voices[oldest].serial || !voices[oldest].active { oldest = j }
            }
        }
        if slot < 0 { slot = oldest }
        // Keep overlaps natural but bounded: fade the oldest ringing hit.
        if activeCount >= 3 && oldest != slot && voices[oldest].fadeStep == 0 {
            voices[oldest].fadeStep = 1 / Float(0.03 * outRate)
        }

        serial &+= 1
        var nv = SampleVoice()
        nv.active = true
        nv.drum = drum
        nv.delay = dly
        nv.start = region.start
        nv.length = region.length
        nv.step = k.sampleRate / outRate
        let g = region.gain * dyn * (1.0 / 32768.0)
        nv.gL = g * d.gainL
        nv.gR = g * d.gainR
        nv.serial = serial
        voices[slot] = nv
        return true
    }

    /// A sweep continues the stir: it crossfades out the previous sweep, starts at a random
    /// point of a long recording with a short fade-in, and releases after two beats.
    private func triggerSweep(_ drum: Int, d: SDrum, region: SRegion, gain: Float, delay dly: Int, kit k: SampleKitRaw) -> Bool {
        let xfade = Float(0.04 * outRate)
        let base = drum * Sampler.voicesPerDrum
        var slot = -1, oldest = base
        for j in base..<(base + Sampler.voicesPerDrum) {
            if voices[j].active {
                if voices[j].delay <= dly { voices[j].chokeAt = dly - voices[j].delay; voices[j].chokeFade = 1 / xfade }
                if voices[j].serial < voices[oldest].serial || !voices[oldest].active { oldest = j }
            } else if slot < 0 { slot = j }
        }
        if slot < 0 { slot = oldest }

        let step = k.sampleRate / outRate
        let hold = max(Int(2 * beatFrames), Int(0.1 * outRate))
        let release = 0.18 * outRate
        let needed = Int((Double(hold) + release + Double(xfade)) * step) + 4
        let room = region.length - needed
        let offset = room > 0 ? Int(random() % UInt32(room)) : 0

        serial &+= 1
        var nv = SampleVoice()
        nv.active = true
        nv.drum = drum
        nv.delay = dly
        nv.start = region.start + offset
        nv.length = region.length - offset
        nv.step = step
        let g = gain * (1.0 / 32768.0)
        nv.gL = g * d.gainL
        nv.gR = g * d.gainR
        nv.attack = 0
        nv.rise = 1 / Float(0.015 * outRate)
        nv.releaseIn = hold
        nv.releaseStep = Float(1 / release)
        nv.serial = serial
        voices[slot] = nv
        return true
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        render(busesL: nil, busesR: nil, busCount: 0, left: left, right: right, frames: frames)
    }

    /// Renders into master `left`/`right`. When `busesL`/`busesR` are set (count = MixBus.count),
    /// also writes each hit into its subgroup bus (and bus 0 = master mirrors left/right).
    func render(busesL: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?,
                busesR: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?,
                busCount: Int,
                left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard let k = kit else { return }
        let a = k.audio
        let chokeStep = 1 / Float(0.025 * outRate)
        let multi = busesL != nil && busesR != nil && busCount > 1
        for vi in 0..<voiceCount where voices[vi].active {
            var v = voices[vi]
            var i = 0
            let last = Double(v.length - 2)
            let mg = mixGain[min(max(v.drum, 0), Drum.count - 1)]
            let bus = multi ? MixBus.forDrumIndex(v.drum).rawValue : 0
            while i < frames {
                if v.chokeAt >= 0 {
                    let cs = v.chokeFade > 0 ? v.chokeFade : chokeStep
                    if v.chokeAt == 0 && v.fadeStep < cs { v.fadeStep = cs }
                    v.chokeAt -= 1
                }
                if v.delay > 0 { v.delay -= 1; i += 1; continue }
                if v.pos >= last { v.active = false; break }
                if v.releaseIn >= 0 {
                    if v.releaseIn == 0 && v.fadeStep < v.releaseStep { v.fadeStep = v.releaseStep }
                    v.releaseIn -= 1
                }

                let ip = Int(v.pos)
                let f = Float(v.pos - Double(ip))
                let idx = (v.start + ip) * 2
                var l: Float, r: Float
                if f == 0 {
                    l = Float(a[idx]); r = Float(a[idx + 1])
                } else if ip == 0 {
                    l = Float(a[idx]) + f * Float(Int(a[idx + 2]) - Int(a[idx]))
                    r = Float(a[idx + 1]) + f * Float(Int(a[idx + 3]) - Int(a[idx + 1]))
                } else {
                    // 4-point Hermite interpolation for sample-rate conversion.
                    l = Sampler.hermite(f, Float(a[idx - 2]), Float(a[idx]), Float(a[idx + 2]),
                                        ip + 2 < v.length ? Float(a[idx + 4]) : 0)
                    r = Sampler.hermite(f, Float(a[idx - 1]), Float(a[idx + 1]), Float(a[idx + 3]),
                                        ip + 2 < v.length ? Float(a[idx + 5]) : 0)
                }
                if v.rise > 0 {
                    v.attack += v.rise
                    if v.attack >= 1 { v.attack = 1; v.rise = 0 }
                }
                if v.fadeStep > 0 {
                    v.fade -= v.fadeStep
                    if v.fade <= 0 { v.active = false; break }
                }
                let e = v.attack * v.fade * mg
                let sl = l * e * v.gL
                let sr = r * e * v.gR
                left[i] += sl
                right[i] += sr
                let pk = max(abs(sl), abs(sr))
                if pk > channelPeak[v.drum] { channelPeak[v.drum] = pk }
                if multi, bus > 0, bus < busCount {
                    busesL![bus][i] += sl
                    busesR![bus][i] += sr
                }
                v.pos += v.step
                i += 1
            }
            voices[vi] = v
        }
    }

    @inline(__always)
    static func hermite(_ t: Float, _ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float) -> Float {
        let c = (x1 - xm1) * 0.5
        let v = x0 - x1
        let w = c + v
        let a = w + v + (x2 - x0) * 0.5
        let bNeg = w + a
        return ((((a * t) - bNeg) * t + c) * t + x0)
    }
}

// MARK: - Installed kits (UI side)

/// Manages imported `.pbkit` files and loads the selected one off the audio
/// thread. Kit indices: 0..<Kits.all.count are synthesized kits, the rest are
/// installed sample kits sorted by name.
public final class KitManager: @unchecked Sendable {
    public struct Installed: Sendable, Identifiable {
        public let manifest: KitManifest
        public let url: URL
        /// Imported by the user (removable), not put in place by an installer.
        public var removable = true
        public var id: String { manifest.id }
        public var name: String { manifest.name }
    }

    public static let maxKits = 64
    private let lock = NSLock()
    private weak var engine: DrumEngine?
    private let directory: URL
    /// Kits an installer put in place (read-only), listed after the user's own of the same id.
    private let installedDirectory: URL?
    private var installed: [Installed] = []
    private var loaded: LoadedSampleKit?
    private var retired: [LoadedSampleKit] = []
    private var loadingID: String?
    private let queue = DispatchQueue(label: "pedalbeat.kitloader", qos: .userInitiated)
    public var onChange: (@Sendable () -> Void)?

    public init(engine: DrumEngine, directory: URL? = nil, installedDirectory: URL? = nil) {
        self.engine = engine
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PedalBeat/Kits", isDirectory: true)
        self.directory = base
        self.installedDirectory = installedDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        rescan()
    }

    public var kits: [Installed] { lock.withLock { installed } }
    public var allKitNames: [String] { Kits.names + kits.map(\.name) }
    public var kitCount: Int { Kits.all.count + kits.count }

    public func name(at index: Int) -> String {
        let names = allKitNames
        return names.indices.contains(index) ? names[index] : "Kit \(index + 1)"
    }

    public func installed(at index: Int) -> Installed? {
        let list = kits, i = index - Kits.all.count
        return list.indices.contains(i) ? list[i] : nil
    }

    public func index(forID id: String) -> Int? {
        kits.firstIndex { $0.id == id }.map { $0 + Kits.all.count }
    }

    /// Best kit for a song's synth-kit hint: an installed kit that declares it, else the synth kit.
    public func suggestedKit(forHint hint: Int) -> Int {
        if let i = kits.firstIndex(where: { $0.manifest.suggestFor.contains(hint) }) { return i + Kits.all.count }
        return hint
    }

    private func rescan() {
        var list: [Installed] = []
        // The user's imports first: one of the same id replaces the installed kit.
        for (dir, removable) in [(directory, true)] + (installedDirectory.map { [($0, false)] } ?? []) {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension.lowercased() == "pbkit" {
                guard let m = try? KitFile.readManifest(url: f), !list.contains(where: { $0.id == m.id }) else { continue }
                list.append(Installed(manifest: m, url: f, removable: removable))
            }
        }
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lock.withLock { installed = Array(list.prefix(KitManager.maxKits - Kits.all.count)) }
    }

    /// Copies a kit file into the library (replacing a kit with the same id). Returns its index.
    @discardableResult
    public func importKit(from url: URL) throws -> Int {
        let m = try KitFile.readManifest(url: url)
        let safe = m.id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard !safe.isEmpty else { throw KitFileError.badManifest("missing kit id") }
        // Check that the audio decodes before installing.
        _ = try LoadedSampleKit(url: url)
        let dest = directory.appendingPathComponent("\(safe).pbkit")
        if let old = kits.first(where: { $0.id == m.id }), old.removable, old.url != dest { try? FileManager.default.removeItem(at: old.url) }
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: url, to: dest)
        rescan()
        onChange?()
        return index(forID: m.id) ?? 0
    }

    public func remove(id: String) {
        guard let k = kits.first(where: { $0.id == id }), k.removable else { return }
        try? FileManager.default.removeItem(at: k.url)
        lock.withLock { if loaded?.manifest.id == id { loadingID = nil } }
        rescan()
        onChange?()
    }

    /// Activates the kit at `index`: synth kits unload any sample kit; sample
    /// kits are decoded on a background queue and then handed to the engine.
    public func select(index: Int) {
        guard let engine else { return }
        reclaim()
        guard let inst = installed(at: index) else {
            lock.withLock { loadingID = nil }
            publish(nil, engine: engine)
            return
        }
        let already: Bool = lock.withLock {
            if loaded?.manifest.id == inst.id || loadingID == inst.id { return true }
            loadingID = inst.id
            return false
        }
        if already { return }
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try LoadedSampleKit(url: inst.url) }
            let current = self.lock.withLock { self.loadingID == inst.id }
            guard current else { return }
            switch result {
            case .success(let kit):
                self.publish(kit, engine: engine)
                self.lock.withLock { self.loadingID = nil; self.lastError = nil }
            case .failure(let error):
                self.lock.withLock { self.loadingID = nil; self.lastError = "\(inst.name): \(error.localizedDescription)" }
            }
            self.onChange?()
        }
    }

    public var isLoading: Bool { lock.withLock { loadingID != nil } }
    private var lastError: String?
    /// Error from the last failed kit load, if any.
    public var loadError: String? { lock.withLock { lastError } }
    public var activeSampleKitID: String? { lock.withLock { loaded?.manifest.id } }

    private func publish(_ kit: LoadedSampleKit?, engine: DrumEngine) {
        lock.withLock {
            if let old = loaded, old !== kit { retired.append(old) }
            loaded = kit
            engine.publishSampleKit(bits: kit?.bits ?? 0)
        }
        reclaim()
    }

    /// Frees retired kits once the audio thread has moved off them.
    private func reclaim() {
        guard let engine else { return }
        let pending: Bool = lock.withLock {
            let inUse = engine.sampleKitInUse
            let published = engine.publishedSampleKit
            retired.removeAll { $0.bits != inUse && $0.bits != published }
            return !retired.isEmpty
        }
        if pending {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reclaim() }
        }
    }
}
