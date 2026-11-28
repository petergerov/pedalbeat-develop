import Foundation
import AudioToolbox

// PedalBeat kit builder.
//
//   kitbuilder probe <program.sfz> [ccN=value ...]        list what every note plays
//   kitbuilder build <sources-dir> <out-dir> [kit-id ...]  render SFZ libraries to .pbkit
//   kitbuilder extract <kit.pbkit> <out-dir>               unpack a .pbkit to WAV + kit.json
//
// Renders open-licensed SFZ drum libraries into compact .pbkit files: every
// velocity layer / round robin is mixed down (all mics, as the library's own
// default mix) to one stereo hit, trimmed, faded and stored losslessly.

let args = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

func parseCC(_ list: ArraySlice<String>) -> [Int: Double] {
    var cc: [Int: Double] = [:]
    for a in list where a.hasPrefix("cc") {
        let p = a.dropFirst(2).split(separator: "=")
        if p.count == 2, let n = Int(p[0]), let v = Double(p[1]) { cc[n] = v }
    }
    return cc
}

// MARK: - Probe

func probe(_ path: String, overrides: [Int: Double]) throws {
    let prog = try SFZProgram(url: URL(fileURLWithPath: path))
    var cc = prog.ccDefaults
    cc.merge(overrides) { $1 }
    print("\(prog.regions.count) regions, CC defaults: \(cc.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    for note in 0...127 {
        let regs = prog.candidates(note: note, cc: cc)
        guard !regs.isEmpty else { continue }
        let layers = Set(regs.map { prog.velRange($0).upperBound }).sorted()
        let samples = Set(regs.map { $0.sampleURL($0) }.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent })
        let ex = samples.sorted().prefix(3).joined(separator: ", ")
        print(String(format: "%3d: %4d regions  %2d layers  rr %2d   %@", note, regs.count, layers.count, prog.naturalRR(regs), ex))
    }
}

extension SFZRegion { func sampleURL(_ r: SFZRegion) -> URL { URL(fileURLWithPath: (r.str("sample") ?? "").replacingOccurrences(of: "\\", with: "/")) } }

// MARK: - Recipes

struct DrumRecipe {
    var drum: Drum
    var note: Int
    var layers = 5
    var rr = 3
    var seconds = 1.2
    var gainDB = 0.0
    var pan: Float = 0
    var cc: [Int: Double] = [:]
    var program: String? = nil   // override program for this drum
    /// Sustained sweep: each entry is (note, top velocity of the layer); rendered without the
    /// library's envelope and kept as long continuous recordings.
    var sweepLayers: [SweepLayer]? = nil
    /// Sweep layers are leveled by RMS; each sits at least this much louder than the one below.
    var sweepStepDB = 3.0
}

/// One sweep velocity layer. `swap` renders the note's regions with a different sample
/// file (for recordings the library ships but doesn't map, e.g. its hardest stir).
/// `cc` overrides controllers for this layer only (e.g. a roll position).
struct SweepLayer {
    var note: Int
    var hiVelocity: Int
    var swap: (from: String, to: String)? = nil
    var cc: [Int: Double] = [:]
}

struct KitRecipe {
    var id: String, name: String, category: String
    var author: String, license: String, source: String, notes: String
    var dir: String, program: String
    var outRate: Double = 48000
    var cc: [Int: Double] = [:]
    var fallbackSynthKit: Int
    var suggestFor: [Int]
    var targetPeak: Float = 0.95     // loudest kick/snare hit after kit normalization
    var drums: [DrumRecipe]
}

func D(_ d: Drum, _ note: Int, layers: Int = 5, rr: Int = 3, sec: Double = 1.2, db: Double = 0, pan: Float = 0,
       cc: [Int: Double] = [:], program: String? = nil) -> DrumRecipe {
    DrumRecipe(drum: d, note: note, layers: layers, rr: rr, seconds: sec, gainDB: db, pan: pan, cc: cc, program: program)
}

func Sweep(_ layers: [SweepLayer], rr: Int = 3, sec: Double = 6, db: Double = 0, stepDB: Double = 3) -> DrumRecipe {
    var r = DrumRecipe(drum: .brushSweep, note: layers[0].note, layers: layers.count, rr: rr, seconds: sec, gainDB: db)
    r.sweepLayers = layers
    r.sweepStepDB = stepDB
    return r
}

let recipes: [KitRecipe] = Recipes.all

// MARK: - Build

struct Built { var manifest: KitManifest; var audio: [Int16] }

func dB(_ x: Float) -> Float { 20 * log10(max(x, 1e-9)) }

/// How far (dB) the quietest 20 ms of a sweep take falls below its median 20 ms level.
func sweepDip(_ h: HitRender, rate: Double) -> Float {
    let win = Int(0.02 * rate)
    var levels: [Float] = []
    var i = 0
    while i + win <= h.left.count {
        var acc: Float = 0
        for k in i..<(i + win) { let m = (h.left[k] + h.right[k]) * 0.5; acc += m * m }
        levels.append(10 * log10(acc / Float(win) + 1e-20))
        i += win
    }
    guard let lowest = levels.min() else { return 0 }
    return levels.sorted()[levels.count / 2] - lowest
}

func build(_ k: KitRecipe, sources: URL, outRate: Double) throws -> Built {
    let root = sources.appendingPathComponent(k.dir)
    var programs: [String: SFZProgram] = [:]
    func program(_ p: String) throws -> SFZProgram {
        if let x = programs[p] { return x }
        let x = try SFZProgram(url: root.appendingPathComponent(p))
        programs[p] = x
        return x
    }
    let cache = AudioCache()
    var audio: [Int16] = []
    audio.reserveCapacity(Int(outRate) * 2 * 200)
    var drums: [String: KitManifest.DrumMap] = [:]
    var kitPeak: Float = 0

    struct Pending { var drum: Drum; var layers: [(Int, [(start: Int, length: Int, peak: Float)])]; var gain: Float; var pan: Float; var sweep: Bool }
    var pending: [Pending] = []

    for dr in k.drums {
        let prog = try program(dr.program ?? k.program)
        var cc = prog.ccDefaults
        cc.merge(k.cc) { $1 }
        cc.merge(dr.cc) { $1 }
        let cands = prog.candidates(note: dr.note, cc: cc)
        guard !cands.isEmpty else { print("  ! \(dr.drum.key): note \(dr.note) plays nothing"); continue }

        // Choose velocity points: library layer tops nearest to evenly spread targets.
        let tops = Set(cands.map { prog.velRange($0).upperBound }).sorted()
        var chosen: [Int] = []
        let n = max(1, min(dr.layers, tops.count))
        if n == 1 { chosen = [tops.last!] }
        else {
            // Evenly spread over the library's own layers, always keeping the loudest.
            for i in 0..<n {
                let idx = Int((Double(i) * Double(tops.count - 1) / Double(n - 1)).rounded())
                if !chosen.contains(tops[idx]) { chosen.append(tops[idx]) }
            }
        }
        chosen.sort()
        let sweep = dr.sweepLayers != nil
        // (note to render, velocity to render at, layer's top velocity in the kit)
        let sources: [(note: Int, vel: Int, hi: Int, swap: (from: String, to: String)?, cc: [Int: Double])] =
            dr.sweepLayers.map { $0.map { (note: $0.note, vel: 127, hi: $0.hiVelocity, swap: $0.swap, cc: $0.cc) } }
            ?? chosen.map { (note: dr.note, vel: $0, hi: $0, swap: nil, cc: [:]) }

        var layers: [(Int, [(Int, Int, Float)])] = []
        var layerRMS: [[Float]] = []   // sweeps: RMS (dB) of each region, for leveling
        var drumPeak: Float = 0
        for src in sources {
            let top = src.vel
            let cc = cc.merging(src.cc) { $1 }
            let regsAtVel = prog.candidates(note: src.note, cc: cc).filter { prog.velRange($0).contains(top) }
            let natural = prog.naturalRR(regsAtVel)
            // Sweeps with random start offsets get their variety from the offsets, so they can
            // have more round robins than the library cycles through.
            let offsets = sweep && regsAtVel.contains { $0.has("offset_random") }
            let rrCount = offsets ? max(1, dr.rr) : max(1, min(dr.rr, natural))
            var regions: [(Int, Int, Float)] = []
            var rms: [Float] = []
            for rr in 0..<rrCount {
                // Spread the chosen round robins across the library's full cycle.
                let srcRR = natural <= rrCount ? rr % natural : rr * natural / rrCount
                func render(_ n: Int) throws -> HitRender {
                    try prog.render(note: src.note, vel: top, rr: srcRR, rrCount: natural, cc: cc,
                                    outRate: outRate, maxSeconds: dr.seconds, cache: cache, envelope: !sweep,
                                    sampleSwap: src.swap,
                                    randomOffset: offsets ? (Double(n) * 0.618034).truncatingRemainder(dividingBy: 1) : nil)
                }
                var hit = try render(rr)
                if offsets {
                    // Sweeps play from a random point, so a take must not drop out anywhere: try
                    // other start offsets (distinct per round robin) until the quietest 20 ms stays
                    // within 12 dB of the take's median, else keep the take with the smallest dip.
                    var best = (hit, sweepDip(hit, rate: outRate))
                    var k = 1
                    while best.1 > 12 && k < 32 {
                        let h = try render(rr + k * rrCount)
                        let d = sweepDip(h, rate: outRate)
                        if d < best.1 { best = (h, d) }
                        k += 1
                    }
                    hit = best.0
                }
                guard hit.regionCount > 0, !hit.left.isEmpty else { continue }
                var L = hit.left, R = hit.right
                var peak: Float = 0
                for i in 0..<L.count { peak = max(peak, abs(L[i]), abs(R[i])) }
                guard peak > 1e-5 else { continue }
                if !sweep {
                // Trim leading silence (keep 1.5 ms before the attack) and the tail below -66 dB.
                let thrHead = peak * 0.01, thrTail = peak * 0.0005
                var first = 0
                while first < L.count && max(abs(L[first]), abs(R[first])) < thrHead { first += 1 }
                first = max(0, first - Int(0.0015 * outRate))
                var last = L.count - 1
                while last > first && max(abs(L[last]), abs(R[last])) < thrTail { last -= 1 }
                let truncated = last >= L.count - 2
                last = min(L.count - 1, last + Int(0.01 * outRate))
                L = Array(L[first...last]); R = Array(R[first...last])
                // Fade out: long if the decay was cut short, short otherwise.
                let fadeLen = truncated ? min(Int(0.4 * outRate), L.count / 4) : min(Int(0.01 * outRate), L.count / 4)
                for i in 0..<fadeLen {
                    let g = Float(i) / Float(max(fadeLen, 1))
                    let shaped = g * g
                    L[L.count - 1 - i] *= shaped; R[R.count - 1 - i] *= shaped
                }
                }
                // Store normalized to full scale; the gain restores the level.
                let start = audio.count / 2
                let norm = 32767 / peak
                for i in 0..<L.count {
                    audio.append(Int16(max(-32767, min(32767, (L[i] * norm).rounded()))))
                    audio.append(Int16(max(-32767, min(32767, (R[i] * norm).rounded()))))
                }
                regions.append((start, L.count, peak))
                drumPeak = max(drumPeak, peak)
                if sweep {
                    var acc: Double = 0
                    for i in 0..<L.count { acc += Double(L[i] * L[i] + R[i] * R[i]) }
                    rms.append(Float(10 * log10(acc / Double(2 * L.count) + 1e-20)))
                }
            }
            if !regions.isEmpty { layers.append((src.hi, regions)); layerRMS.append(rms) }
        }
        cache.clear()
        guard !layers.isEmpty else { print("  ! \(dr.drum.key): nothing rendered"); continue }
        if sweep {
            // Level sweeps by RMS, not peak: every take of a layer plays at the layer's level, and
            // each layer is at least `sweepStepDB` louder than the one below, so light / medium /
            // hard sweeps always get louder even when the recordings are about equally loud.
            var target: [Float] = []
            for (i, r) in layerRMS.enumerated() {
                let natural = r.reduce(0, +) / Float(max(r.count, 1))
                target.append(i == 0 ? natural : max(natural, target[i - 1] + Float(dr.sweepStepDB)))
            }
            drumPeak = 0
            for i in layers.indices {
                for j in layers[i].1.indices {
                    layers[i].1[j].2 *= pow(10, (target[i] - layerRMS[i][j]) / 20)
                    drumPeak = max(drumPeak, layers[i].1[j].2)
                }
            }
            print("  \(dr.drum.key) levels: " + zip(layerRMS, target).map { r, t in
                String(format: "%.1f→%.1f dB", r.reduce(0, +) / Float(max(r.count, 1)), t) }.joined(separator: ", "))
        }
        let g = pow(10, Float(dr.gainDB) / 20)
        if dr.drum == .kick || dr.drum == .snare { kitPeak = max(kitPeak, drumPeak * g) }
        pending.append(Pending(drum: dr.drum, layers: layers, gain: g, pan: dr.pan, sweep: sweep))
        let lens = layers.flatMap { $0.1.map { Double($0.1) / outRate } }
        print(String(format: "  %-11@ note %3d  layers %@  rr %d  peak %5.1f dB  len %.2f-%.2fs",
                     dr.drum.key, dr.note, layers.map { String($0.0) }.joined(separator: "/"),
                     layers.map { $0.1.count }.max() ?? 0, dB(drumPeak), lens.min() ?? 0, lens.max() ?? 0))
    }

    // Kit normalization: loudest kick/snare hit lands at targetPeak.
    let norm = kitPeak > 0 ? k.targetPeak / kitPeak : 1
    for p in pending {
        var layers: [KitManifest.Layer] = []
        for (i, l) in p.layers.enumerated() {
            let hi = i == p.layers.count - 1 ? 127 : l.0
            layers.append(KitManifest.Layer(hiVelocity: hi, regions: l.1.map {
                KitManifest.Region(start: $0.start, length: $0.length, gain: $0.peak * norm)
            }))
        }
        drums[p.drum.key] = KitManifest.DrumMap(volume: p.gain, pan: p.pan, layers: layers, sweep: p.sweep ? true : nil)
    }
    let m = KitManifest(id: k.id, name: k.name, category: k.category, author: k.author, license: k.license,
                        source: k.source, notes: k.notes, sampleRate: outRate, frames: audio.count / 2,
                        fallbackSynthKit: k.fallbackSynthKit, suggestFor: k.suggestFor, drums: drums)
    return Built(manifest: m, audio: audio)
}

// MARK: - Extract (decoded drumset layout: `{midi}-{Name}/{lo}-{hi}/*.wav` + kit.json)

/// Folder / instrument name matching decoded drumset kits (`36-Kick_Drum`, …).
func bbInstrumentName(_ drum: Drum) -> String {
    switch drum {
    case .kick: "Kick_Drum"
    case .snare: "Snare"
    case .rim: "Cross_Stick"
    case .clap: "Handclaps"
    case .hatClosed: "Hi-Hats_Closed"
    case .hatPedal: "Foot_Hi-Hat"
    case .hatOpen: "Hi-Hat_Open"
    case .ride: "Ride_Cymbal"
    case .rideBell: "Ride_C._Bell"
    case .crash: "Crash_Cymbal_1"
    case .tomHigh: "Tom_1"
    case .tomMid: "Tom_3"
    case .tomLow: "Tom_4"
    case .cowbell: "Cowbell"
    case .shaker: "Shaker"
    case .tambourine: "Tambourine"
    case .brushSweep: "Sweeps_Long"
    }
}

/// MIDI note used in decoded drumset folders (may differ from PedalBeat `gmNote`).
func bbMidi(_ drum: Drum) -> Int {
    switch drum {
    case .kick: 36
    case .snare: 38
    case .rim: 37
    case .clap: 39
    case .hatClosed: 42
    case .hatPedal: 44
    case .hatOpen: 46
    case .ride: 51
    case .rideBell: 53
    case .crash: 49
    case .tomHigh: 50   // Tom 1
    case .tomMid: 45    // Tom 3
    case .tomLow: 43    // Tom 4 (PedalBeat gmNote is 41)
    case .cowbell: 56
    case .shaker: 82    // PedalBeat gmNote is 70
    case .tambourine: 54
    case .brushSweep: 41  // Sweeps Long; PedalBeat plays as note 88
    }
}

func writeWAV(url: URL, rate: Double, interleaved: UnsafePointer<Int16>, frames: Int, gain: Float) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    var ext: ExtAudioFileRef?
    var st = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &asbd, nil,
                                       AudioFileFlags.eraseFile.rawValue, &ext)
    guard st == noErr, let ext else { throw KitFileError.audio(st) }
    defer { ExtAudioFileDispose(ext) }
    // Apply region gain so the WAV matches playback level (samples are peak-normalized in the kit).
    var buf = [Int16](repeating: 0, count: frames * 2)
    if gain == 1 {
        for i in 0..<(frames * 2) { buf[i] = interleaved[i] }
    } else {
        for i in 0..<(frames * 2) {
            let v = Float(interleaved[i]) * gain
            buf[i] = Int16(max(-32767, min(32767, v.rounded())))
        }
    }
    try buf.withUnsafeMutableBufferPointer { p in
        var done = 0
        while done < frames {
            let n = min(16384, frames - done)
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(n * 4),
                mData: UnsafeMutableRawPointer(p.baseAddress! + done * 2)))
            st = ExtAudioFileWrite(ext, UInt32(n), &abl)
            guard st == noErr else { throw KitFileError.audio(st) }
            done += n
        }
    }
}

/// Decoded-drumset-style kit.json so the folder can be re-packed with `bbkitbuilder`.
struct ExtractedKit: Encodable {
    struct Sample: Encodable {
        var velocity: String
        var file: String
        var channels: Int
        var rate: Int
        var bits: Int
        var nSample: Int
    }
    struct Instrument: Encodable {
        var name: String
        var midi: Int
        var volume: Int
        var percussion: Bool
        var samples: [Sample]
    }
    var name: String
    var volume: Int
    var id: String
    var category: String
    var author: String
    var license: String
    var source: String
    var notes: String
    var sampleRate: Double
    var instruments: [Instrument]
}

func extract(kitURL: URL, outDir: URL) throws {
    let m = try KitFile.readManifest(url: kitURL)
    let audio = try KitFile.readAudio(url: kitURL, manifest: m)
    defer { audio.deallocate() }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    print("\(m.name) (\(m.id))  \(m.sampleRate) Hz  \(m.frames) frames  \(m.drums.count) drums")
    var instruments: [ExtractedKit.Instrument] = []
    var files = 0

    // Stable order by MIDI note (source kit.json order).
    let drums = m.drums.keys.compactMap { Drum.named($0) }.sorted { bbMidi($0) < bbMidi($1) }
    for drum in drums {
        guard let map = m.drums[drum.key] else { continue }
        let instName = bbInstrumentName(drum)
        let midi = bbMidi(drum)
        let rootName = "\(midi)-\(instName)"
        let vol = max(1, min(127, Int((map.volume * 100).rounded())))
        var samples: [ExtractedKit.Sample] = []
        var lo = 0
        for (li, layer) in map.layers.enumerated() {
            let hi = layer.hiVelocity
            let vel = "\(lo)-\(hi)"
            let folder = outDir.appendingPathComponent(rootName).appendingPathComponent(vel)
            for (ri, region) in layer.regions.enumerated() {
                let fileName = "\(instName)_\(vel)_rr\(String(format: "%02d", ri + 1)).wav"
                let rel = "\(rootName)/\(vel)/\(fileName)"
                let url = folder.appendingPathComponent(fileName)
                guard region.start >= 0, region.length > 0,
                      region.start + region.length <= m.frames else {
                    print("  ! \(rootName) layer \(li) rr \(ri): out of range")
                    continue
                }
                try writeWAV(url: url, rate: m.sampleRate,
                             interleaved: audio.baseAddress! + region.start * 2,
                             frames: region.length, gain: region.gain)
                samples.append(.init(velocity: vel, file: rel, channels: 2,
                                     rate: Int(m.sampleRate), bits: 16, nSample: region.length * 2))
                files += 1
            }
            let sweep = map.sweep == true ? "  sweep" : ""
            print("  \(rootName)  \(vel)  \(layer.regions.count) rr\(sweep)")
            lo = hi + 1
        }
        let display = instName.replacingOccurrences(of: "_", with: " ")
        instruments.append(.init(name: display, midi: midi, volume: vol, percussion: true, samples: samples))
    }

    let kit = ExtractedKit(
        name: m.name.replacingOccurrences(of: "BB ", with: ""),
        volume: 100, id: m.id, category: m.category, author: m.author,
        license: m.license, source: m.source, notes: m.notes,
        sampleRate: m.sampleRate, instruments: instruments)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(kit).write(to: outDir.appendingPathComponent("kit.json"), options: .atomic)
    print("-> \(files) WAVs + kit.json in \(outDir.path)")
}

// MARK: - Main

guard args.count >= 3 else {
    fail("""
        usage:
          kitbuilder probe <program.sfz> [ccN=v ...]
          kitbuilder build <sources-dir> <out-dir> [kit-id ...]
          kitbuilder extract <kit.pbkit> <out-dir>
        """)
}
do {
    switch args[1] {
    case "probe":
        try probe(args[2], overrides: parseCC(args.dropFirst(3)))
    case "build":
        guard args.count >= 4 else { fail("build needs <sources-dir> <out-dir>") }
        let src = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let only = Set(args.dropFirst(4))
        for k in recipes where only.isEmpty || only.contains(k.id) {
            print("Building \(k.name) (\(k.id))…")
            let t0 = Date()
            let b = try build(k, sources: src, outRate: k.outRate)
            let url = out.appendingPathComponent("\(k.id).pbkit")
            try KitFile.write(url: url, manifest: b.manifest, audio: b.audio)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print(String(format: "  -> %@  %.1f MB on disk, %.1f MB in RAM, %.0f s of audio, %.1fs",
                         url.lastPathComponent, Double(size) / 1e6, Double(b.audio.count * 2) / 1e6,
                         Double(b.manifest.frames) / k.outRate, Date().timeIntervalSince(t0)))
        }
    case "extract":
        guard args.count >= 4 else { fail("extract needs <kit.pbkit> <out-dir>") }
        try extract(kitURL: URL(fileURLWithPath: args[2]),
                    outDir: URL(fileURLWithPath: args[3], isDirectory: true))
    default:
        fail("unknown command \(args[1])")
    }
} catch {
    fail("error: \(error)")
}
