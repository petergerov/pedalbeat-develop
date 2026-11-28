import Foundation
import AudioToolbox

// Offline: run ChordDetector over a WAV and print locked chord changes with time.

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: ChordProbe <wav>\n", stderr)
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])

var file: ExtAudioFileRef?
var status = ExtAudioFileOpenURL(url as CFURL, &file)
guard status == noErr, let file else {
    fputs("open failed \(status)\n", stderr)
    exit(1)
}
defer { ExtAudioFileDispose(file) }

var asbd = AudioStreamBasicDescription(
    mSampleRate: 44100,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
    mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &asbd)
guard status == noErr else { fputs("set format \(status)\n", stderr); exit(1) }

let det = ChordDetector()
det.setSampleRate(44100)
det.gate = 0.004
det.minConfidence = 0.45
det.songRoot = 4
det.preferMinorKey = true

let frames = 1024
let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
defer { buf.deallocate() }
var abl = AudioBufferList(mNumberBuffers: 1,
                          mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: buf))

var lastName = "—"
var t: Double = 0
var segments: [(start: Double, name: String)] = [(0, "—")]
let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

while true {
    var n = UInt32(frames)
    status = ExtAudioFileRead(file, &n, &abl)
    if status != noErr || n == 0 { break }
    _ = det.process(left: UnsafePointer(buf), right: nil, frames: Int(n))
    let name = det.lastChordName
    if name != lastName {
        segments.append((t, name))
        lastName = name
    }
    t += Double(n) / 44100
}
segments.append((t, "END"))

print(String(format: "duration %.1fs  segments %d", t, segments.count - 1))
for i in 0..<(segments.count - 1) {
    let a = segments[i], b = segments[i + 1]
    let dur = b.start - a.start
    if a.name == "—" && dur < 0.15 { continue }
    print(String(format: "%6.2f – %6.2f  (%4.2fs)  %@", a.start, b.start, dur, a.name))
}

// Highlight suspicious labels in Am G F E context.
let odd = ["Bb", "Bbm", "C#", "C#m", "Eb", "Ebm", "F#", "F#m", "Ab", "Abm", "B", "Bm"]
print("\nOdd / out-of-key hits:")
for i in 0..<(segments.count - 1) {
    let a = segments[i], b = segments[i + 1]
    if odd.contains(a.name) {
        print(String(format: "  %.2f–%.2f  %@", a.start, b.start, a.name))
    }
}
