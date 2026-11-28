import Foundation
import AudioToolbox

// Measures Bass Follow chord detection on a labeled recording: how much of the time the locked chord
// is right, how long it takes to follow each chord change, and how often it jumps to a wrong chord.
// Runs each timbre with and without the song chord prior (the song's chords = the labels' chords).
//
//   swiftc -O -import-objc-header Core/PedalBeat-Bridging-Header.h -I Core -I ThirdParty/onnxruntime/include \
//     Core/*.swift Core/*/*.swift Tools/ChordEval/main.swift build/songpack-tool/SolititoORT.o \
//     -L ThirdParty/onnxruntime/lib -lonnxruntime -lc++ -Xlinker -rpath -Xlinker $PWD/ThirdParty/onnxruntime/lib \
//     -o build/chordeval
//   ./build/chordeval tmp/BeatBudyTest.wav [labels.txt] [--solitito]
//
// labels.txt: one "start end chord" per line (seconds, e.g. "0.2 7.2 Am"); without it, the labels of
// BeatBudyTest.wav (Am G F E, A minor). Solitito runs in real time (the model predicts on its own thread).

struct Segment { var start: Double; var end: Double; var chord: LiveChord }

func parseChord(_ s: String) -> LiveChord? {
    let names = ["C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
                 "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11]
    let minor = s.hasSuffix("m")
    guard let root = names[minor ? String(s.dropLast()) : s] else { return nil }
    return LiveChord(root: root, minor: minor)
}

let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
let withSolitito = CommandLine.arguments.contains("--solitito")
guard args.count >= 2 else { fputs("usage: chordeval <wav> [labels.txt] [--solitito]\n", stderr); exit(1) }
var segments: [Segment] = []
if args.count >= 3 {
    for line in try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n") {
        let f = line.split(separator: " ")
        if f.count == 3, let a = Double(f[0]), let b = Double(f[1]), let c = parseChord(String(f[2])) {
            segments.append(Segment(start: a, end: b, chord: c))
        }
    }
} else {
    for (a, b, c) in [(0.2, 7.2, "Am"), (7.9, 12.1, "G"), (12.2, 16.9, "F"), (17.0, 19.5, "E"), (19.7, 24.0, "Am"),
                      (24.9, 26.4, "Am"), (29.4, 31.2, "G"), (31.5, 36.0, "F"), (36.3, 41.4, "E")] {
        segments.append(Segment(start: a, end: b, chord: parseChord(c)!))
    }
}

// The song's chords: time share of each labeled chord. Robustness checks:
//   --shift=N         the song is written N semitones higher than played (capo / other key)
//   --profile=C,F,G   the song's chords are these instead (equal shares; the first is the key)
func option(_ name: String) -> String? {
    CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
}
var profile = [Float](repeating: 0, count: 24)
var tonic = segments.first!.chord   // the first chord is taken as the key
if let list = option("profile") {
    let chords = list.split(separator: ",").compactMap { parseChord(String($0)) }
    for c in chords { profile[c.root + (c.minor ? 12 : 0)] += 1 }
    tonic = chords.first ?? tonic
} else {
    for s in segments { profile[s.chord.root + (s.chord.minor ? 12 : 0)] += Float(s.end - s.start) }
}
if let n = option("shift").flatMap(Int.init) {
    var shifted = [Float](repeating: 0, count: 24)
    for i in 0..<24 { shifted[((i % 12 + n) % 12 + 12) % 12 + (i >= 12 ? 12 : 0)] = profile[i] }
    profile = shifted
    tonic = LiveChord(root: tonic.root + n, minor: tonic.minor)
}

// Audio, mono float at 44.1 kHz.
func loadWAV(_ path: String) -> [Float] {
    var file: ExtAudioFileRef?
    guard ExtAudioFileOpenURL(URL(fileURLWithPath: path) as CFURL, &file) == noErr, let file else {
        fputs("cannot open \(path)\n", stderr); exit(1)
    }
    defer { ExtAudioFileDispose(file) }
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: asbd)), &asbd)
    var out: [Float] = []
    let n = 4096
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
    defer { buf.deallocate() }
    while true {
        var frames = UInt32(n)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf))
        guard ExtAudioFileRead(file, &frames, &abl) == noErr, frames > 0 else { break }
        out.append(contentsOf: UnsafeBufferPointer(start: buf, count: Int(frames)))
    }
    return out
}
let audio = loadWAV(args[1])
let sr = 44100.0

struct EvalResult { var accuracy = 0.0; var latencies: [Double] = []; var wrongJumps = 0; var changes = 0; var shift = 0 }

func evaluate(_ timbre: ChordTimbre, prior: Bool) -> EvalResult {
    let det = ChordDetector()
    det.setSampleRate(sr)
    det.chordTimbre = timbre
    det.songRoot = tonic.root
    det.preferMinorKey = tonic.minor
    if prior { profile.withUnsafeBufferPointer { det.setSongChords($0) } }
    let block = 512
    var timeline: [(t: Double, chord: LiveChord?)] = []
    var current: LiveChord?
    var i = 0
    let pace = timbre == .solititoGuitar
    if pace {   // let the model load before the clip starts
        let silence = [Float](repeating: 0, count: block)
        let until = Date().addingTimeInterval(4)
        while Date() < until { silence.withUnsafeBufferPointer { _ = det.process(left: $0.baseAddress!, right: nil, frames: block) }; usleep(11_000) }
        det.reset()
        det.chordTimbre = timbre
        if prior { profile.withUnsafeBufferPointer { det.setSongChords($0) } }
    }
    let t0 = Date()
    while i + block <= audio.count {
        let c = audio.withUnsafeBufferPointer { det.process(left: $0.baseAddress! + i, right: nil, frames: block) }
        if let c {
            if ProcessInfo.processInfo.environment["CHORDEVAL_TRACE"] != nil, prior,
               current.map({ $0.root != c.root || $0.minor != c.minor }) ?? true {
                print(String(format: "  %6.2f s  %-4@ shift %d fit %.2f", Double(i) / sr, c.name, det.songShift, det.songFit))
            }
            current = c
        }
        timeline.append((Double(i + block) / sr, current))
        i += block
        if pace {
            let due = t0.addingTimeInterval(Double(i) / sr)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { usleep(UInt32(wait * 1e6)) }
        }
    }
    func same(_ a: LiveChord?, _ b: LiveChord) -> Bool { a.map { $0.root == b.root && $0.minor == b.minor } ?? false }
    var r = EvalResult()
    var right = 0.0, total = 0.0
    let dt = Double(block) / sr
    for seg in segments {
        var first: Double?
        var prev: LiveChord?
        for (t, c) in timeline where t >= seg.start && t < seg.end {
            total += dt
            if same(c, seg.chord) { right += dt; if first == nil { first = t - seg.start } }
            // A change inside the segment to anything but its chord, once it was right = a wrong jump.
            if let p = prev, let c, !(p.root == c.root && p.minor == c.minor) {
                r.changes += 1
                if first != nil && !same(c, seg.chord) { r.wrongJumps += 1 }
            }
            prev = c
        }
        r.latencies.append(first ?? (seg.end - seg.start))
    }
    r.accuracy = total > 0 ? right / total : 0
    r.shift = det.songShift
    return r
}

let timbres: [ChordTimbre] = withSolitito ? [.guitar, .mixed, .solititoGuitar] : [.guitar, .mixed]
print("segments: \(segments.map { $0.chord.name }.joined(separator: " ")), \(String(format: "%.1f", audio.count.description.isEmpty ? 0 : Double(audio.count) / sr)) s")
for t in timbres {
    for prior in [false, true] {
        let r = evaluate(t, prior: prior)
        let lat = r.latencies.map { String(format: "%.2f", $0) }.joined(separator: " ")
        let mean = r.latencies.reduce(0, +) / Double(r.latencies.count)
        print(String(format: "%-16@ %@  accuracy %5.1f%%  mean latency %.2f s  wrong jumps %2d  changes in segments %2d  shift %d   [%@]",
                     "\(t)", prior ? "prior" : "     ", r.accuracy * 100, mean, r.wrongJumps, r.changes, r.shift, lat))
    }
}
