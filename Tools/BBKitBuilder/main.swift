import Foundation
import AVFoundation

// Packs decoded drum-pedal kits (kit.json + WAV samples) into PedalBeat .pbkit files.
//
//   swiftc -O Core/*.swift Tools/BBKitBuilder/main.swift -o build/bbkitbuilder
//   ./build/bbkitbuilder drumsets-decoded bb-kits

let args = CommandLine.arguments
func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

guard args.count >= 3 else {
    fail("usage: bbkitbuilder <drumsets-decoded> <out-dir> [kit-folder ...]")
}

// MARK: - Decoded kit.json

struct BBKit: Decodable {
    var name: String
    var file: String?
    var volume: Int
    var instruments: [BBInstrument]
}

struct BBInstrument: Decodable {
    var name: String
    var midi: Int
    var volume: Int
    var samples: [BBSample]
}

struct BBSample: Decodable {
    var velocity: String
    var file: String
    var rate: Int?
    var channels: Int?
}

struct VelRange: Hashable, Comparable {
    var lo: Int, hi: Int
    static func < (a: VelRange, b: VelRange) -> Bool { a.hi < b.hi || (a.hi == b.hi && a.lo < b.lo) }
    static func parse(_ s: String) -> VelRange? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2, p[0] <= p[1] else { return nil }
        return VelRange(lo: p[0], hi: p[1])
    }
}

// MARK: - MIDI → PedalBeat drum

/// Preferred source notes for each PedalBeat voice. First match wins when several
/// instruments would claim the same drum (e.g. Crash 1 over Crash 2 / Splash).
let preferredNotes: [Drum: [Int]] = [
    .kick: [36],
    .snare: [38],
    .rim: [37],
    .clap: [39],
    .hatClosed: [42],
    .hatPedal: [44],
    .hatOpen: [46],
    .ride: [51],
    .rideBell: [53],
    .crash: [49, 55, 57, 52],
    .tomHigh: [50, 48],   // Tom 1, then Tom 2
    .tomMid: [45, 47],    // Tom 3
    .tomLow: [43, 41],    // Tom 4 (41 is also sweeps-long on Brushes — handled by name)
    .cowbell: [56],
    .shaker: [82, 70, 69],
    .tambourine: [54],
]

func isSweepName(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.contains("sweep") || n.contains("stir")
}

func isLongSweep(_ name: String) -> Bool {
    let n = name.lowercased()
    return isSweepName(n) && (n.contains("long") || n.contains("continuous"))
}

/// Map a source instrument to a PedalBeat drum, or nil to skip.
func mapInstrument(_ inst: BBInstrument) -> Drum? {
    if isLongSweep(inst.name) { return .brushSweep }
    if isSweepName(inst.name) { return nil } // short / off sweeps aren't continuous stirs
    // Hi-hat foot open / splash isn't a PedalBeat voice (47 often aliases to tomMid in GM).
    let n = inst.name.lowercased()
    if n.contains("hat") && (n.contains("foot open") || n.contains("foot splash") || n.contains("hats foot")) {
        return nil
    }
    if n.contains("metronome") { return nil }
    // Prefer the PedalBeat voice whose preferred-note list contains this MIDI note.
    var best: (drum: Drum, rank: Int)?
    for (drum, notes) in preferredNotes {
        guard let rank = notes.firstIndex(of: inst.midi) else { continue }
        if best == nil || rank < best!.rank || (rank == best!.rank && drum.rawValue < best!.drum.rawValue) {
            best = (drum, rank)
        }
    }
    if let best { return best.drum }
    // Note 88 is PedalBeat's brush-sweep ID, not GM — don't treat BB timbale/etc. as sweeps.
    if let d = Drum.fromGM(UInt8(clamping: inst.midi)), d != .brushSweep { return d }
    return nil
}

func pickInstruments(_ kit: BBKit) -> [(Drum, BBInstrument)] {
    var byDrum: [Drum: BBInstrument] = [:]
    var sweep: BBInstrument?

    for inst in kit.instruments {
        if isLongSweep(inst.name) {
            if sweep == nil { sweep = inst }
            continue
        }
        guard let drum = mapInstrument(inst) else { continue }
        if let existing = byDrum[drum] {
            let pref = preferredNotes[drum] ?? []
            let oldRank = pref.firstIndex(of: existing.midi) ?? Int.max
            let newRank = pref.firstIndex(of: inst.midi) ?? Int.max
            if newRank < oldRank { byDrum[drum] = inst }
        } else {
            byDrum[drum] = inst
        }
    }
    if let s = sweep { byDrum[.brushSweep] = s }

    // Keep tom assignment coherent when a preferred note was taken by a sweep alias.
    return byDrum.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { d in
        byDrum[d].map { (d, $0) }
    }
}

func category(for name: String) -> String {
    let n = name.lowercased()
    if n.contains("jazz") { return "jazz" }
    if n.contains("brush") { return "brushes" }
    if n.contains("dance") || n.contains("voice") || n.contains("ethereal") { return "electronic" }
    if n.contains("latin") || n.contains("percussion") { return "percussion" }
    if n.contains("metal") || n.contains("rock") { return "acoustic" }
    return "acoustic"
}

func kitHint(for name: String) -> Int {
    BBSImport.kitHint(genre: name, name: name)
}

func slug(_ name: String) -> String {
    let s = name.lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return s.isEmpty ? "kit" : s
}

// MARK: - Audio

final class WavCache {
    struct Clip { var left: [Float]; var right: [Float]; var rate: Double }
    private var clips: [URL: Clip] = [:]

    func load(_ url: URL) throws -> Clip {
        if let c = clips[url] { return c }
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let n = AVAudioFrameCount(f.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(n, 1)) else {
            throw NSError(domain: "bbkit", code: 1, userInfo: [NSLocalizedDescriptionKey: "buffer \(url.lastPathComponent)"])
        }
        try f.read(into: buf)
        let frames = Int(buf.frameLength)
        var L = [Float](repeating: 0, count: frames)
        var R = [Float](repeating: 0, count: frames)
        if fmt.channelCount >= 2 {
            let l = UnsafeBufferPointer(start: buf.floatChannelData![0], count: frames)
            let r = UnsafeBufferPointer(start: buf.floatChannelData![1], count: frames)
            L = Array(l); R = Array(r)
        } else if fmt.channelCount == 1 {
            let m = UnsafeBufferPointer(start: buf.floatChannelData![0], count: frames)
            L = Array(m); R = L
        }
        let clip = Clip(left: L, right: R, rate: fmt.sampleRate)
        clips[url] = clip
        return clip
    }
}

func dB(_ x: Float) -> Float { 20 * log10(max(x, 1e-9)) }

func prepareHit(L inL: [Float], R inR: [Float], sweep: Bool, outRate: Double, srcRate: Double) -> (L: [Float], R: [Float], peak: Float)? {
    var L = inL, R = inR
    // Resample if needed (linear).
    if abs(srcRate - outRate) > 0.5 {
        let step = srcRate / outRate
        let n = max(1, Int(Double(L.count) / step))
        var oL = [Float](repeating: 0, count: n), oR = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = Double(i) * step
            let j = Int(x)
            let f = Float(x - Double(j))
            let j1 = min(j + 1, L.count - 1)
            oL[i] = L[j] * (1 - f) + L[j1] * f
            oR[i] = R[j] * (1 - f) + R[j1] * f
        }
        L = oL; R = oR
    }
    var peak: Float = 0
    for i in 0..<L.count { peak = max(peak, abs(L[i]), abs(R[i])) }
    guard peak > 1e-5 else { return nil }

    if !sweep {
        let thrHead = peak * 0.01, thrTail = peak * 0.0005
        var first = 0
        while first < L.count && max(abs(L[first]), abs(R[first])) < thrHead { first += 1 }
        first = max(0, first - Int(0.0015 * outRate))
        var last = L.count - 1
        while last > first && max(abs(L[last]), abs(R[last])) < thrTail { last -= 1 }
        let truncated = last >= L.count - 2
        last = min(L.count - 1, last + Int(0.01 * outRate))
        L = Array(L[first...last]); R = Array(R[first...last])
        let fadeLen = truncated ? min(Int(0.4 * outRate), L.count / 4) : min(Int(0.01 * outRate), L.count / 4)
        for i in 0..<fadeLen {
            let g = Float(i) / Float(max(fadeLen, 1))
            let shaped = g * g
            L[L.count - 1 - i] *= shaped
            R[R.count - 1 - i] *= shaped
        }
        peak = 0
        for i in 0..<L.count { peak = max(peak, abs(L[i]), abs(R[i])) }
    }
    return (L, R, peak)
}

// MARK: - Build one kit

struct Built { var manifest: KitManifest; var audio: [Int16] }

func build(kitDir: URL, outRate: Double = 44100, targetPeak: Float = 0.95, maxRR: Int = 4) throws -> Built {
    let jsonURL = kitDir.appendingPathComponent("kit.json")
    let kit = try JSONDecoder().decode(BBKit.self, from: Data(contentsOf: jsonURL))
    let picked = pickInstruments(kit)
    let cache = WavCache()
    var audio: [Int16] = []
    audio.reserveCapacity(Int(outRate) * 2 * 120)

    struct Pending {
        var drum: Drum
        var layers: [(hi: Int, regions: [(start: Int, length: Int, peak: Float)])]
        var volume: Float
        var sweep: Bool
    }
    var pending: [Pending] = []
    var kitPeak: Float = 0
    let kitVol = Float(kit.volume) / 100

    for (drum, inst) in picked {
        let sweep = drum == .brushSweep
        // Group samples by velocity range, preserve file order as round-robins.
        var groups: [VelRange: [BBSample]] = [:]
        var order: [VelRange] = []
        for s in inst.samples {
            guard let vr = VelRange.parse(s.velocity) else { continue }
            if groups[vr] == nil { order.append(vr); groups[vr] = [] }
            groups[vr]!.append(s)
        }
        order.sort()

        var layers: [(Int, [(Int, Int, Float)])] = []
        var drumPeak: Float = 0
        for vr in order {
            let samples = groups[vr] ?? []
            let rrCount = max(1, min(maxRR, samples.count))
            var regions: [(Int, Int, Float)] = []
            for i in 0..<rrCount {
                // Spread chosen RRs across the available takes.
                let idx = samples.count <= rrCount ? i : i * samples.count / rrCount
                let url = kitDir.appendingPathComponent(samples[idx].file)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    print("  ! missing \(samples[idx].file)")
                    continue
                }
                let clip = try cache.load(url)
                guard let hit = prepareHit(L: clip.left, R: clip.right, sweep: sweep,
                                           outRate: outRate, srcRate: clip.rate) else { continue }
                let L = hit.L, R = hit.R
                let peak = hit.peak
                let start = audio.count / 2
                let norm = 32767 / peak
                for j in 0..<L.count {
                    audio.append(Int16(max(-32767, min(32767, (L[j] * norm).rounded()))))
                    audio.append(Int16(max(-32767, min(32767, (R[j] * norm).rounded()))))
                }
                regions.append((start, L.count, peak))
                drumPeak = max(drumPeak, peak)
            }
            if !regions.isEmpty {
                let hi = vr.hi
                layers.append((hi, regions))
            }
        }
        guard !layers.isEmpty else {
            print("  ! \(drum.key): no samples")
            continue
        }
        // Last layer must reach 127.
        if let last = layers.indices.last { layers[last].0 = max(layers[last].0, 127) }

        let vol = (Float(inst.volume) / 100) * kitVol
        if drum == .kick || drum == .snare { kitPeak = max(kitPeak, drumPeak * vol) }
        pending.append(Pending(drum: drum, layers: layers, volume: vol, sweep: sweep))
        let lens = layers.flatMap { $0.1.map { Double($0.1) / outRate } }
        print(String(format: "  %-11@ midi %3d  layers %@  rr %d  peak %5.1f dB  len %.2f-%.2fs  vol %.2f",
                     drum.key, inst.midi,
                     layers.map { String($0.0) }.joined(separator: "/"),
                     layers.map { $0.1.count }.max() ?? 0,
                     dB(drumPeak), lens.min() ?? 0, lens.max() ?? 0, vol))
    }

    let norm = kitPeak > 0 ? targetPeak / kitPeak : 1
    var drums: [String: KitManifest.DrumMap] = [:]
    for p in pending {
        var layers: [KitManifest.Layer] = []
        for (i, l) in p.layers.enumerated() {
            let hi = i == p.layers.count - 1 ? 127 : l.hi
            layers.append(KitManifest.Layer(hiVelocity: hi, regions: l.regions.map {
                KitManifest.Region(start: $0.start, length: $0.length, gain: $0.peak * norm)
            }))
        }
        drums[p.drum.key] = KitManifest.DrumMap(volume: p.volume, pan: 0, layers: layers,
                                                sweep: p.sweep ? true : nil)
    }

    let name = kit.name
    let id = "pedalbeat.bb.\(slug(name))"
    let hint = kitHint(for: name)
    let m = KitManifest(
        id: id, name: "BB \(name)", category: category(for: name),
        author: "Original kit maker",
        license: "Proprietary — for personal use with your own content",
        source: kit.file.map { "Decoded drumset \($0)" } ?? "Decoded drumset",
        notes: "Converted from decoded kit “\(name)”. Import only if you own the original content.",
        sampleRate: outRate, frames: audio.count / 2,
        fallbackSynthKit: hint, suggestFor: [hint],
        drums: drums)
    return Built(manifest: m, audio: audio)
}

// MARK: - Main

let srcRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let outRoot = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)

let only = Set(args.dropFirst(3))
let kits = try FileManager.default.contentsOfDirectory(at: srcRoot, includingPropertiesForKeys: [.isDirectoryKey])
    .filter { ($0.lastPathComponent.first?.isNumber ?? false) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("kit.json").path) }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

do {
    for kitDir in kits {
        let folder = kitDir.lastPathComponent
        if !only.isEmpty && !only.contains(folder)
            && !only.contains(where: { folder == $0 || folder.hasSuffix(". \($0)") || folder.hasSuffix($0) }) {
            continue
        }
        print("Building \(folder)…")
        let t0 = Date()
        let b = try build(kitDir: kitDir)
        let url = outRoot.appendingPathComponent("\(b.manifest.id).pbkit")
        try KitFile.write(url: url, manifest: b.manifest, audio: b.audio)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print(String(format: "  -> %@  %.1f MB on disk, %.1f MB PCM, %.0f s audio, %.1fs\n",
                     url.lastPathComponent, Double(size) / 1e6, Double(b.audio.count * 2) / 1e6,
                     Double(b.manifest.frames) / b.manifest.sampleRate, Date().timeIntervalSince(t0)))
    }
} catch {
    fail("error: \(error)")
}
