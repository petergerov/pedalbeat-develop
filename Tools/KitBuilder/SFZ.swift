import Foundation
import AVFoundation

/// Minimal SFZ interpreter: enough of the format to evaluate which regions a
/// sampler would play for a given note / velocity / round robin / CC state,
/// and with what gain, pan, width, pitch and envelope.
struct SFZRegion {
    var op: [String: String]
    func str(_ k: String) -> String? { op[k] }
    func num(_ k: String, _ def: Double = 0) -> Double { op[k].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? def }
    func has(_ k: String) -> Bool { op[k] != nil }
}

struct SFZProgram {
    var regions: [SFZRegion] = []
    var ccDefaults: [Int: Double] = [:]
    var curves: [Int: [Double]] = [:]
    let rootDir: URL

    init(url: URL) throws {
        rootDir = url.deletingLastPathComponent()
        var defines: [String: String] = [:]
        var lines: [String] = []
        try SFZProgram.preprocess(url: url, root: rootDir, defines: &defines, into: &lines, depth: 0)
        parse(lines)
    }

    // MARK: Preprocessing (#include, #define, comments)

    static func preprocess(url: URL, root: URL, defines: inout [String: String], into out: inout [String], depth: Int) throws {
        guard depth < 16 else { return }
        var text = try String(contentsOf: url, encoding: .utf8)
        // Block comments.
        while let s = text.range(of: "/*"), let e = text.range(of: "*/", range: s.upperBound..<text.endIndex) {
            text.removeSubrange(s.lowerBound..<e.upperBound)
        }
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]) }
            // #define statements (possibly several per line) are read before substitution.
            if line.contains("#define") {
                let ns = line as NSString
                for m in defineRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    defines[ns.substring(with: m.range(at: 1))] = substitute(ns.substring(with: m.range(at: 2)), defines)
                }
                continue
            }
            line = substitute(line, defines)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#include") {
                if let q1 = t.firstIndex(of: "\""), let q2 = t[t.index(after: q1)...].firstIndex(of: "\"") {
                    let rel = String(t[t.index(after: q1)..<q2]).replacingOccurrences(of: "\\", with: "/")
                    let inc = root.appendingPathComponent(rel)
                    if FileManager.default.fileExists(atPath: inc.path) {
                        try preprocess(url: inc, root: root, defines: &defines, into: &out, depth: depth + 1)
                    } else {
                        FileHandle.standardError.write("warning: missing include \(rel)\n".data(using: .utf8)!)
                    }
                }
                continue
            }
            if !t.isEmpty { out.append(line) }
        }
    }

    static let defineRegex = try! NSRegularExpression(pattern: "#define\\s+(\\$[A-Za-z0-9_]+)\\s+(\\S+)")
    static let varRegex = try! NSRegularExpression(pattern: "\\$[A-Za-z0-9_]+")

    /// Replaces `$NAME` tokens with the longest matching define.
    static func substitute(_ s: String, _ defines: [String: String]) -> String {
        guard s.contains("$") else { return s }
        var out = s
        for _ in 0..<4 { // values may themselves contain variables
            let ns = out as NSString
            let ms = varRegex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            if ms.isEmpty { break }
            var result = ""
            var last = 0
            var changed = false
            for m in ms {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let token = ns.substring(with: m.range)
                var replaced = token
                var len = token.count
                while len > 1 {
                    let name = String(token.prefix(len))
                    if let v = defines[name] { replaced = v + token.dropFirst(len); changed = true; break }
                    len -= 1
                }
                result += replaced
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
            if !changed { break }
        }
        return out
    }

    // MARK: Parsing

    private mutating func parse(_ lines: [String]) {
        enum Level { case control, global, master, group, region, curve, other }
        var level = Level.other
        var control: [String: String] = [:], global: [String: String] = [:]
        var master: [String: String] = [:], group: [String: String] = [:]
        var region: [String: String] = [:]
        var curve: [String: String] = [:]
        var inRegion = false

        func flushRegion() {
            if inRegion {
                var m = global
                m.merge(master) { $1 }; m.merge(group) { $1 }; m.merge(region) { $1 }
                if let dp = control["default_path"] { m["__default_path"] = dp }
                if let no = control["note_offset"] { m["__note_offset"] = no }
                regions.append(SFZRegion(op: m))
            }
            inRegion = false
            region = [:]
        }
        func flushCurve() {
            guard level == .curve, let idx = curve["curve_index"].flatMap({ Int($0) }) else { curve = [:]; return }
            var pts = [Double?](repeating: nil, count: 128)
            pts[0] = 0; pts[127] = 1
            for (k, v) in curve where k.hasPrefix("v") {
                if let i = Int(k.dropFirst()), i >= 0, i < 128, let d = Double(v) { pts[i] = d }
            }
            // Linear interpolation between defined points.
            var out = [Double](repeating: 0, count: 128)
            var last = 0
            for i in 1..<128 where pts[i] != nil {
                let a = pts[last]!, b = pts[i]!
                for j in last...i { out[j] = a + (b - a) * Double(j - last) / Double(max(i - last, 1)) }
                last = i
            }
            curves[idx] = out
            curve = [:]
        }

        let opRegex = try! NSRegularExpression(pattern: "(?:^|(?<=[ \\t]))([A-Za-z0-9_]+)=")
        for line in lines {
            // Split the line into header tags and opcode text.
            var segments: [(isHeader: Bool, text: String)] = []
            var cur = ""
            var i = line.startIndex
            while i < line.endIndex {
                if line[i] == "<", let close = line[i...].firstIndex(of: ">") {
                    if !cur.isEmpty { segments.append((false, cur)); cur = "" }
                    segments.append((true, String(line[line.index(after: i)..<close])))
                    i = line.index(after: close)
                } else { cur.append(line[i]); i = line.index(after: i) }
            }
            if !cur.isEmpty { segments.append((false, cur)) }

            for seg in segments {
                if seg.isHeader {
                    flushRegion(); flushCurve()
                    switch seg.text {
                    case "control": level = .control; control = [:]
                    case "global": level = .global; global = [:]; master = [:]; group = [:]
                    case "master": level = .master; master = [:]; group = [:]
                    case "group": level = .group; group = [:]
                    case "region": level = .region; inRegion = true; region = [:]
                    case "curve": level = .curve; curve = [:]
                    default: level = .other
                    }
                    continue
                }
                let ns = seg.text as NSString
                let ms = opRegex.matches(in: seg.text, range: NSRange(location: 0, length: ns.length))
                for (k, m) in ms.enumerated() {
                    let key = ns.substring(with: m.range(at: 1))
                    let vStart = m.range.location + m.range.length
                    let vEnd = k + 1 < ms.count ? ms[k + 1].range.location : ns.length
                    apply(key, ns.substring(with: NSRange(location: vStart, length: vEnd - vStart)).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        flushRegion(); flushCurve()

        func apply(_ k: String, _ v: String) {
            switch level {
            case .control:
                if k.hasPrefix("set_cc"), let n = Int(k.dropFirst(6)), let d = Double(v) { ccDefaults[n] = d }
                else if k.hasPrefix("set_hdcc"), let n = Int(k.dropFirst(8)), let d = Double(v) { ccDefaults[n] = d * 127 }
                else { control[k] = v }
            case .global: global[k] = v
            case .master: master[k] = v
            case .group: group[k] = v
            case .region: region[k] = v
            case .curve: curve[k] = v
            case .other: break
            }
        }
    }

    // MARK: Evaluation

    func curveValue(_ index: Int, _ cc: Double) -> Double {
        let x = min(max(cc / 127, 0), 1)
        if let c = curves[index] { return c[min(max(Int((x * 127).rounded()), 0), 127)] }
        switch index {
        case 1: return 2 * x - 1
        case 2: return 1 - x
        case 3: return 1 - 2 * x
        case 4: return x * x
        case 5: return x.squareRoot()
        case 6: return (1 - x).squareRoot()
        default: return x
        }
    }

    /// Sum of `<base>_onccN` / `<base>_ccN` / legacy `<base>ccN` modulations.
    func ccMod(_ r: SFZRegion, _ base: String, cc: [Int: Double]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (k, v) in r.op where k.hasPrefix(base) {
            var tail = k.dropFirst(base.count)
            if tail.hasPrefix("_oncc") { tail = tail.dropFirst(5) }
            else if tail.hasPrefix("_cc") { tail = tail.dropFirst(3) }
            else if tail.hasPrefix("cc") { tail = tail.dropFirst(2) }
            else { continue }
            guard let n = Int(tail), let amount = Double(v) else { continue }
            let curveIdx = Int(r.num("\(base)_curvecc\(n)", 0))
            out.append((amount, curveValue(curveIdx, cc[n] ?? 0)))
        }
        return out
    }

    func modulated(_ r: SFZRegion, _ base: String, _ def: Double, cc: [Int: Double]) -> Double {
        ccMod(r, base, cc: cc).reduce(r.num(base, def)) { $0 + $1.0 * $1.1 }
    }

    static func parseNote(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if let n = Int(s) { return n }
        let names: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]
        var chars = Array(s)
        guard let base = names[chars.removeFirst()] else { return nil }
        var semis = base
        if chars.first == "#" { semis += 1; chars.removeFirst() } else if chars.first == "b" && chars.count > 1 { semis -= 1; chars.removeFirst() }
        guard let oct = Int(String(chars)) else { return nil }
        return (oct + 1) * 12 + semis
    }

    func keyRange(_ r: SFZRegion) -> ClosedRange<Int> {
        let off = Int(r.num("__note_offset", 0))
        if let k = SFZProgram.parseNote(r.str("key")) { return (k + off)...(k + off) }
        let lo = (SFZProgram.parseNote(r.str("lokey")) ?? 0) + off
        let hi = (SFZProgram.parseNote(r.str("hikey")) ?? 127) + off
        return lo...max(lo, hi)
    }

    /// Regions that play for `note` ignoring velocity and round robin (CC / keyswitch / trigger aware).
    func candidates(note: Int, cc: [Int: Double]) -> [SFZRegion] {
        regions.filter { r in
            guard keyRange(r).contains(note) else { return false }
            if let t = r.str("trigger"), t == "release" || t == "release_key" { return false }
            if let s = r.str("sample"), s.hasPrefix("*") { return false }
            guard r.str("sample") != nil else { return false }
            // CC-triggered or keyswitched regions.
            if r.op.keys.contains(where: { $0.hasPrefix("on_locc") || $0.hasPrefix("on_hicc") || $0.hasPrefix("start_locc") || $0.hasPrefix("start_hicc") }) { return false }
            if let swl = r.str("sw_last") {
                guard let def = r.str("sw_default"), SFZProgram.parseNote(def) == SFZProgram.parseNote(swl) else { return false }
            }
            if r.has("sw_down") || r.has("sw_up") || r.has("sw_previous") { return false }
            for (k, v) in r.op where k.hasPrefix("locc") || k.hasPrefix("hicc") {
                guard let n = Int(k.dropFirst(4)), let bound = Double(v) else { continue }
                let val = cc[n] ?? 0
                if k.hasPrefix("locc") && val < bound { return false }
                if k.hasPrefix("hicc") && val > bound { return false }
            }
            return true
        }
    }

    func velRange(_ r: SFZRegion) -> ClosedRange<Int> {
        let lo = Int(r.num("lovel", 1)), hi = Int(r.num("hivel", 127))
        return max(lo, 0)...max(min(hi, 127), lo)
    }

    /// Round-robin selection: sequence position and random slice.
    func plays(_ r: SFZRegion, rr: Int, rrCount: Int) -> Bool {
        let len = max(Int(r.num("seq_length", 1)), 1)
        let pos = Int(r.num("seq_position", 1))
        if len > 1 && (rr % len) + 1 != pos { return false }
        if r.has("lorand") || r.has("hirand") {
            let x = (Double(rr % max(rrCount, 1)) + 0.5) / Double(max(rrCount, 1))
            if x < r.num("lorand", 0) || x >= r.num("hirand", 1) { return false }
        }
        return true
    }

    /// Natural number of round robins for a set of candidate regions.
    func naturalRR(_ regs: [SFZRegion]) -> Int {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        var lcm = 1
        var randSlices = Set<Double>()
        for r in regs {
            let l = max(Int(r.num("seq_length", 1)), 1)
            lcm = lcm / gcd(lcm, l) * l
            if r.has("lorand") || r.has("hirand") { randSlices.insert(r.num("lorand", 0)) }
        }
        return max(lcm, randSlices.count, 1)
    }

    func velocityGain(_ r: SFZRegion, vel: Int) -> Double {
        let track = r.num("amp_veltrack", 100) / 100
        var pts: [(Int, Double)] = []
        for (k, v) in r.op where k.hasPrefix("amp_velcurve_") {
            if let i = Int(k.dropFirst(13)), let d = Double(v) { pts.append((i, d)) }
        }
        let curve: Double
        if pts.isEmpty {
            let x = Double(vel) / 127
            curve = x * x
        } else {
            if !pts.contains(where: { $0.0 == 0 }) { pts.append((0, 0)) }
            if !pts.contains(where: { $0.0 == 127 }) { pts.append((127, 1)) }
            pts.sort { $0.0 < $1.0 }
            var c = pts.last!.1
            for i in 1..<pts.count where vel <= pts[i].0 {
                let (x0, y0) = pts[i - 1], (x1, y1) = pts[i]
                c = x1 == x0 ? y1 : y0 + (y1 - y0) * Double(vel - x0) / Double(x1 - x0)
                break
            }
            curve = c
        }
        return track >= 0 ? 1 + track * (curve - 1) : 1 + track * curve
    }

    func xfadeGain(_ r: SFZRegion, vel: Int, cc: [Int: Double]) -> Double {
        var g = 1.0
        func fin(_ x: Double, _ lo: Double, _ hi: Double) -> Double { x <= lo ? 0 : (x >= hi ? 1 : ((x - lo) / max(hi - lo, 1e-9)).squareRoot()) }
        func fout(_ x: Double, _ lo: Double, _ hi: Double) -> Double { x <= lo ? 1 : (x >= hi ? 0 : (1 - (x - lo) / max(hi - lo, 1e-9)).squareRoot()) }
        let v = Double(vel)
        if r.has("xfin_lovel") || r.has("xfin_hivel") { g *= fin(v, r.num("xfin_lovel", 0), r.num("xfin_hivel", 0)) }
        if r.has("xfout_lovel") || r.has("xfout_hivel") { g *= fout(v, r.num("xfout_lovel", 127), r.num("xfout_hivel", 127)) }
        for (k, _) in r.op where k.hasPrefix("xfin_locc") {
            guard let n = Int(k.dropFirst(9)) else { continue }
            g *= fin(cc[n] ?? 0, r.num("xfin_locc\(n)", 0), r.num("xfin_hicc\(n)", 0))
        }
        for (k, _) in r.op where k.hasPrefix("xfout_locc") {
            guard let n = Int(k.dropFirst(10)) else { continue }
            g *= fout(cc[n] ?? 0, r.num("xfout_locc\(n)", 127), r.num("xfout_hicc\(n)", 127))
        }
        return g
    }

    func sampleURL(_ r: SFZRegion) -> URL {
        let path = ((r.str("__default_path") ?? "") + (r.str("sample") ?? "")).replacingOccurrences(of: "\\", with: "/")
        return rootDir.appendingPathComponent(path).standardizedFileURL
    }
}

// MARK: - Rendering one hit

final class AudioCache {
    struct Clip { var channels: [[Float]]; var rate: Double }
    private var clips: [URL: Clip] = [:]
    func clear() { clips.removeAll() }
    func load(_ url: URL) throws -> Clip {
        if let c = clips[url] { return c }
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let n = AVAudioFrameCount(f.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(n, 1)) else { throw NSError(domain: "kit", code: 1) }
        try f.read(into: buf)
        var ch: [[Float]] = []
        for c in 0..<Int(fmt.channelCount) {
            ch.append(Array(UnsafeBufferPointer(start: buf.floatChannelData![c], count: Int(buf.frameLength))))
        }
        let clip = Clip(channels: ch, rate: fmt.sampleRate)
        clips[url] = clip
        return clip
    }
}

struct HitRender {
    var left: [Float]
    var right: [Float]
    var regionCount: Int
}

extension SFZProgram {
    /// Mixes all regions that play for (note, vel, rr) into a stereo buffer at `outRate`.
    func render(note: Int, vel: Int, rr: Int, rrCount: Int, cc: [Int: Double], outRate: Double,
                maxSeconds: Double, cache: AudioCache, envelope: Bool = true,
                sampleSwap: (from: String, to: String)? = nil) throws -> HitRender {
        let regs = candidates(note: note, cc: cc).filter { velRange($0).contains(vel) && plays($0, rr: rr, rrCount: rrCount) }
        let maxFrames = Int(maxSeconds * outRate) + 1
        var L = [Float](repeating: 0, count: maxFrames), R = [Float](repeating: 0, count: maxFrames)
        var used = 0
        var longest = 0
        for r in regs {
            var gain = velocityGain(r, vel: vel) * xfadeGain(r, vel: vel, cc: cc)
            let volDB = modulated(r, "volume", 0, cc: cc) + modulated(r, "gain", 0, cc: cc)
                + r.num("global_volume", 0) + r.num("master_volume", 0) + r.num("group_volume", 0)
            gain *= pow(10, volDB / 20) * r.num("amplitude", 100) / 100
            gain *= r.num("global_amplitude", 100) / 100 * r.num("master_amplitude", 100) / 100 * r.num("group_amplitude", 100) / 100
            for (amount, x) in ccMod(r, "amplitude", cc: cc) { gain *= amount / 100 * x }
            guard gain > 1e-5 else { continue }
            var url = sampleURL(r)
            if let sw = sampleSwap {
                // Use an unmapped sample with the same mic/level settings as this region.
                guard url.lastPathComponent.contains(sw.from) else { continue }
                url = url.deletingLastPathComponent().appendingPathComponent(
                    url.lastPathComponent.replacingOccurrences(of: sw.from, with: sw.to))
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw NSError(domain: "kit", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing \(url.lastPathComponent)"])
                }
            }
            let clip = try cache.load(url)
            let src = clip.channels
            guard !src.isEmpty, !src[0].isEmpty else { continue }

            // Pitch: transpose, tune (cents), key tracking.
            let keycenter = SFZProgram.parseNote(r.str("pitch_keycenter")) ?? (SFZProgram.parseNote(r.str("key")) ?? note)
            let cents = modulated(r, "transpose", 0, cc: cc) * 100 + modulated(r, "tune", 0, cc: cc)
                + Double(note - keycenter) * r.num("pitch_keytrack", 100)
            let step = pow(2, cents / 1200) * clip.rate / outRate

            // Pan / width (percent, -100...100).
            let pan = min(max(modulated(r, "pan", 0, cc: cc), -100), 100) / 100
            let width = min(max(modulated(r, "width", 100, cc: cc), -100), 100) / 100
            let pl = cos((pan + 1) * .pi / 4) * 2.squareRoot(), pr = sin((pan + 1) * .pi / 4) * 2.squareRoot()

            // Envelope (attack, hold, decay -> sustain); release is not used for one-shots.
            let delay = max(modulated(r, "ampeg_delay", 0, cc: cc), 0)
            let attack = max(modulated(r, "ampeg_attack", 0, cc: cc), 0)
            let hold = max(modulated(r, "ampeg_hold", 0, cc: cc), 0)
            let decay = max(modulated(r, "ampeg_decay", 0, cc: cc), 0)
            let sustain = min(max(modulated(r, "ampeg_sustain", 100, cc: cc), 0), 100) / 100

            let offset = Int(r.num("offset", 0))
            let endIdx = r.has("end") ? min(Int(r.num("end", 0)), src[0].count - 1) : src[0].count - 1
            guard endIdx > offset + 4 else { continue }
            let s0 = src[0], s1 = src.count > 1 ? src[1] : src[0]
            let stereo = src.count > 1
            let start = Int(delay * outRate)
            var pos = Double(offset)
            var i = start
            while i < maxFrames && pos < Double(endIdx - 1) {
                let ip = Int(pos), f = Float(pos - Double(ip))
                func at(_ a: [Float], _ k: Int) -> Float { k >= 0 && k <= endIdx ? a[k] : 0 }
                var a = at(s0, ip), b = at(s1, ip)
                if f > 0 {
                    a = hermite(f, at(s0, ip - 1), a, at(s0, ip + 1), at(s0, ip + 2))
                    b = hermite(f, at(s1, ip - 1), b, at(s1, ip + 1), at(s1, ip + 2))
                }
                let t = Double(i - start) / outRate
                var env: Double
                if !envelope { env = 1 }
                else if t < attack { env = t / max(attack, 1e-9) }
                else if t < attack + hold { env = 1 }
                else if decay > 0 && t < attack + hold + decay { env = 1 - (1 - sustain) * (t - attack - hold) / decay }
                else { env = decay > 0 || sustain < 1 ? sustain : 1 }
                let g = Float(gain * env)
                if stereo {
                    let mid = (a + b) * 0.5, side = (a - b) * 0.5 * Float(width)
                    L[i] += (mid + side) * g * Float(pl)
                    R[i] += (mid - side) * g * Float(pr)
                } else {
                    L[i] += a * g * Float(pl) * 0.7071
                    R[i] += a * g * Float(pr) * 0.7071
                }
                pos += step
                i += 1
            }
            longest = max(longest, i)
            used += 1
        }
        L.removeSubrange(min(longest, L.count)...)
        R.removeSubrange(min(longest, R.count)...)
        return HitRender(left: L, right: R, regionCount: used)
    }
}

@inline(__always)
func hermite(_ t: Float, _ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float) -> Float {
    let c = (x1 - xm1) * 0.5, v = x0 - x1, w = c + v
    let a = w + v + (x2 - x0) * 0.5, bNeg = w + a
    return (((a * t) - bNeg) * t + c) * t + x0
}
