// Hosts the installed PedalBeat AU through the AUv2 API, the way Logic does (out-of-process
// AUv3 behind the system bridge). Feeds a 1 kHz tone on input element 0 (track) and an
// A-major chord on input element 1 (Side Chain), then reports which elements the AU pulls,
// the buffer layouts the bridge asks for, and whether the track tone reaches the output.
//
//   swiftc -O Tools/SideChainProbe/main.swift -o build/sidechainprobe
//   ./build/sidechainprobe [aumf|aumu] [main channels] [side chain channels] [seconds]
//
// Side Chain arrival is reported by the AU itself:
//   log show --last 1m --predicate 'subsystem == "com.pedalbeat.au"'
import AudioToolbox
import Foundation

func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

func check(_ status: OSStatus, _ what: String) {
    guard status != noErr else { return }
    print("FAILED \(what): \(status)")
    exit(1)
}

final class Probe {
    var calls = [0, 0]
    var layouts = ["", ""]
    var phase = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 2)
    let sampleRate: Double
    /// Bridge may pass NULL mData; render callbacks then supply their own memory.
    let own: [UnsafeMutablePointer<Float>]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        own = (0..<4).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
            p.initialize(repeating: 0, count: 16384)
            return p
        }
    }

    /// Element 0: 1 kHz tone. Element 1: A2/C#3/E3 + octaves (guitar-like A major).
    func sample(bus: Int) -> Float {
        let freqs: [Double] = bus == 0 ? [1000] : [110.0, 138.59, 164.81, 220.0, 277.18, 329.63]
        let amps: [Double] = bus == 0 ? [0.25] : [0.28, 0.24, 0.24, 0.18, 0.16, 0.16]
        var s = 0.0
        for j in freqs.indices {
            s += amps[j] * sin(phase[bus][j])
            phase[bus][j] += 2 * Double.pi * freqs[j] / sampleRate
            if phase[bus][j] > 2 * Double.pi { phase[bus][j] -= 2 * Double.pi }
        }
        return Float(s)
    }
}

let inputProc: AURenderCallback = { refCon, _, _, bus, frames, ioData in
    let p = Unmanaged<Probe>.fromOpaque(refCon).takeUnretainedValue()
    guard let ioData, bus < 2 else { return kAudio_ParamError }
    let b = Int(bus)
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    p.calls[b] += 1
    if p.layouts[b].isEmpty {
        p.layouts[b] = "\(abl.count) buffer(s): " + abl.map {
            "\($0.mNumberChannels)ch \($0.mDataByteSize)B \($0.mData == nil ? "NULL" : "data")"
        }.joined(separator: ", ")
    }
    for i in 0..<abl.count where abl[i].mData == nil {
        abl[i].mData = UnsafeMutableRawPointer(p.own[min(b * 2 + i, 3)])
        abl[i].mDataByteSize = frames * abl[i].mNumberChannels * 4
    }
    for f in 0..<Int(frames) {
        let s = p.sample(bus: b)
        for i in 0..<abl.count {
            let ch = Int(abl[i].mNumberChannels)
            let d = abl[i].mData!.assumingMemoryBound(to: Float.self)
            for c in 0..<ch { d[f * ch + c] = s }
        }
    }
    return noErr
}

let args = CommandLine.arguments
let type = args.count > 1 ? args[1] : "aumf"
let mainChannels = UInt32(args.count > 2 ? Int(args[2]) ?? 2 : 2)
let sideChannels = UInt32(args.count > 3 ? Int(args[3]) ?? 2 : 2)
let seconds = args.count > 4 ? Double(args[4]) ?? 3 : 3
let sampleRate = 48000.0
let frames: UInt32 = 512

var desc = AudioComponentDescription(componentType: fourCC(type),
                                     componentSubType: fourCC(type == "aumu" ? "pdbt" : "pdbf"),
                                     componentManufacturer: fourCC("PdBt"),
                                     componentFlags: 0, componentFlagsMask: 0)
guard let comp = AudioComponentFindNext(nil, &desc) else { print("PedalBeat \(type) not registered"); exit(1) }
var version: UInt32 = 0
AudioComponentGetVersion(comp, &version)
var unitOpt: AudioUnit?
var instantiateStatus: OSStatus = 1
AudioComponentInstantiate(comp, .loadOutOfProcess) { u, status in
    unitOpt = u
    instantiateStatus = status
}
while instantiateStatus == 1 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(instantiateStatus, "AudioComponentInstantiate")
let unit = unitOpt!

func elementCount(_ scope: AudioUnitScope) -> UInt32 {
    var n: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioUnitGetProperty(unit, kAudioUnitProperty_ElementCount, scope, 0, &n, &size)
    return n
}

func format(_ channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}

func setFormat(_ scope: AudioUnitScope, _ element: UInt32, _ channels: UInt32) {
    var f = format(channels)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &f,
                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
          "StreamFormat scope \(scope) element \(element) \(channels)ch")
}

print("PedalBeat \(type) version 0x\(String(version, radix: 16)): inputs \(elementCount(kAudioUnitScope_Input)), outputs \(elementCount(kAudioUnitScope_Output))")
print("formats: main in \(mainChannels)ch, side chain \(sideChannels)ch, out 2ch, \(Int(sampleRate)) Hz, \(frames) frames")

setFormat(kAudioUnitScope_Output, 0, 2)
setFormat(kAudioUnitScope_Input, 0, mainChannels)
setFormat(kAudioUnitScope_Input, 1, sideChannels)
var maxFrames: UInt32 = 1024
check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                           &maxFrames, UInt32(MemoryLayout<UInt32>.size)), "MaximumFramesPerSlice")

let probe = Probe(sampleRate: sampleRate)
let ref = Unmanaged.passUnretained(probe).toOpaque()
for element: UInt32 in [0, 1] {
    var cb = AURenderCallbackStruct(inputProc: inputProc, inputProcRefCon: ref)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, element,
                               &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetRenderCallback \(element)")
}
check(AudioUnitInitialize(unit), "AudioUnitInitialize")

let out = AudioBufferList.allocate(maximumBuffers: 2)
let outL = UnsafeMutablePointer<Float>.allocate(capacity: Int(frames))
let outR = UnsafeMutablePointer<Float>.allocate(capacity: Int(frames))
var sampleTime = 0.0
var sumSq = 0.0, count = 0
var toneRe = 0.0, toneIm = 0.0
var renderErrors = 0
let cycles = Int(seconds * sampleRate / Double(frames))
for _ in 0..<cycles {
    out[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(outL))
    out[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(outR))
    outL.initialize(repeating: 0, count: Int(frames))
    outR.initialize(repeating: 0, count: Int(frames))
    var flags = AudioUnitRenderActionFlags()
    var ts = AudioTimeStamp()
    ts.mSampleTime = sampleTime
    ts.mFlags = .sampleTimeValid
    let err = AudioUnitRender(unit, &flags, &ts, 0, frames, out.unsafeMutablePointer)
    if err != noErr { renderErrors += 1; if renderErrors == 1 { print("AudioUnitRender error \(err)") } }
    // Real-time pace, so the AU's once-a-second input log gets to run.
    usleep(UInt32(Double(frames) / sampleRate * 1_000_000))
    let l = out[0].mData!.assumingMemoryBound(to: Float.self)
    for i in 0..<Int(frames) {
        let v = Double(l[i])
        sumSq += v * v
        let t = 2 * Double.pi * 1000 * (sampleTime + Double(i)) / sampleRate
        toneRe += v * cos(t); toneIm += v * sin(t)
        count += 1
    }
    sampleTime += Double(frames)
}
let rms = sqrt(sumSq / Double(max(count, 1)))
let tone = 2 * sqrt(toneRe * toneRe + toneIm * toneIm) / Double(max(count, 1))
print("element 0 pulled \(probe.calls[0])× of \(cycles) [\(probe.layouts[0])]")
print("element 1 pulled \(probe.calls[1])× of \(cycles) [\(probe.layouts[1])]")
print(String(format: "output L rms %.4f, 1 kHz track tone amplitude %.4f (fed 0.25), render errors %d",
             rms, tone, renderErrors))
AudioUnitUninitialize(unit)
AudioComponentInstanceDispose(unit)
