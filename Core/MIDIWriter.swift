import Foundation

/// Writes a drum pattern as a Standard MIDI File (type 0, channel 10, 480 PPQ), optionally
/// with a bass line on channel 2.
///
/// A sequencer-specific meta event (FF 7F, "PB1") carries what plain MIDI can't:
/// the exact pattern length and each note's live-swing amount, so a song exported
/// from PedalBeat and read back plays identically. Other programs ignore it.
public enum MIDIWriter {
    static let tag: [UInt8] = Array("PB1".utf8)

    /// `barTicks` / `beatTicks` describe the song's grid; the label is what the UI shows.
    /// If the label doesn't match the bar length (PedalBeat's "12/8" is 4/4 with triplets),
    /// the file gets the metrically correct time signature and the label travels in the meta.
    public static func drumFile(_ p: PatternData, tempo: Double, signature: String,
                                barTicks: Int = 1920, beatTicks: Int = 480, bass: BassPattern? = nil) -> Data {
        let sig = signature.split(separator: "/").compactMap { Int($0) }
        var num = sig.count == 2 ? sig[0] : 4, den = sig.count == 2 ? sig[1] : 4
        if num * PPQN * 4 / max(den, 1) != barTicks {
            if barTicks % PPQN == 0 { num = barTicks / PPQN; den = 4 } else { num = barTicks / (PPQN / 2); den = 8 }
        }
        let notes = p.events.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }.map(\.element)

        // (tick, order, index, bytes): note-offs (order 0) before note-ons (order 1) at the same tick;
        // note-ons keep the order of `notes`, which the swing table below follows.
        var msgs: [(Int, Int, Int, [UInt8])] = []
        for (i, e) in notes.enumerated() {
            let d = Drum(rawValue: Int(e.drum)) ?? .snare
            msgs.append((Int(e.tick), 1, i, [0x99, d.gmNote, max(1, e.velocity)]))
            msgs.append((Int(e.tick) + 30, 0, i, [0x89, d.gmNote, 0]))
        }
        if let bass {
            // Fingered bass program, so other programs (and our reader) know channel 2 is the bass.
            msgs.append((0, 0, -1, [0xC1, 33]))
            for (j, e) in bass.events.enumerated() {
                msgs.append((Int(e.tick), 1, notes.count + j, [0x91, e.note, max(1, e.velocity)]))
                msgs.append((Int(e.tick + e.durationTicks), 0, notes.count + j, [0x81, e.note, 0]))
            }
        }
        msgs.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }

        var trk: [UInt8] = []
        func vlq(_ v: Int) -> [UInt8] {
            var v = max(v, 0); var out = [UInt8(v & 0x7F)]; v >>= 7
            while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            return out
        }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

        let us = Int((60_000_000 / max(tempo, 1)).rounded())
        trk += [0x00, 0xFF, 0x51, 0x03, UInt8(us >> 16 & 0xFF), UInt8(us >> 8 & 0xFF), UInt8(us & 0xFF)]
        var log2den = 0; while (1 << log2den) < den && log2den < 6 { log2den += 1 }
        trk += [0x00, 0xFF, 0x58, 0x04, UInt8(num), UInt8(log2den), 24, 8]
        let label = Array(signature.utf8.prefix(15))
        var meta = tag + be32(p.length) + be32(barTicks) + be32(beatTicks) + [UInt8(label.count)] + label + be32(notes.count)
        for e in notes { meta += [UInt8(UInt16(bitPattern: e.swingUnit) >> 8), UInt8(UInt16(bitPattern: e.swingUnit) & 0xFF)] }
        trk += [0x00, 0xFF, 0x7F] + vlq(meta.count) + meta

        var last = 0
        for (t, _, _, bytes) in msgs { trk += vlq(t - last) + bytes; last = t }
        trk += vlq(max(p.length, last) - last) + [0xFF, 0x2F, 0x00]

        var d = Data("MThd".utf8)
        d.append(contentsOf: [0, 0, 0, 6, 0, 0, 0, 1, UInt8(480 >> 8), UInt8(480 & 0xFF)])
        d.append(Data("MTrk".utf8))
        d.append(contentsOf: be32(trk.count))
        d.append(contentsOf: trk)
        return d
    }
}
