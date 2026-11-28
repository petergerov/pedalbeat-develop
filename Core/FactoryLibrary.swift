import Foundation

/// Original factory grooves. Each groove becomes a song (verse + derived chorus
/// and optional bridge), and neighbouring grooves are combined into extra songs.
enum FactoryLibrary {
    typealias T = Groove.Transform

    struct GenreDef {
        let name: String
        var kit = 0
        var swing: Double = 0
        var chorus: [T]
        var bridge: [T]? = nil
        let grooves: [Groove]
    }

    static let genres: [GenreDef] = [
        GenreDef(name: "Rock", chorus: [.openHats, .crashOnOne], bridge: [.floorTom], grooves: [
            Groove("Straight Eights", tempo: 116, [
                "K": "X--- ---- X-x- ----", "S": "---- X--- ---- X---", "H": "X-x- x-x- X-x- x-x-"]),
            Groove("Driving", tempo: 128, [
                "K": "X--- ---x X-x- ----", "S": "---- X--- ---- X---", "H": "X-x- X-x- X-x- X-x-"]),
            Groove("Sixteenth Hats", tempo: 104, [
                "K": "X--- ---- X-x- ---x", "S": "---- X--- ---- X---", "H": "Xoxo xoxo Xoxo xoxo"]),
            Groove("Floor Stomp", tempo: 120, [
                "K": "X--- X--- X--- X---", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Tom Pulse", tempo: 110, [
                "K": "X--- ---- X--- ----", "S": "---- X--- ---- X---", "T3": "x-x- x-x- x-x- x-x-"]),
            Groove("Two-Bar Push", tempo: 124, [
                "K": "X--- ---- X-x- ---- X--- ---- X--- --x-",
                "S": "---- X--- ---- X--- ---- X--- ---- X---",
                "H": "X-x- x-x- x-x- x-x- X-x- x-x- x-x- x-x-"]),
            Groove("Heartland", tempo: 132, [
                "K": "X--- --x- X--- --x-", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Slow Burn", tempo: 76, [
                "K": "X--- ---- --x- ----", "S": "---- X--- ---- X--g", "H": "x-x- x-x- x-x- x-x-"]),
        ]),
        GenreDef(name: "Hard Rock & Metal", chorus: [.ride, .crashOnOne], bridge: [.halfTime], grooves: [
            Groove("Arena", tempo: 128, [
                "K": "X--- --x- X-x- ----", "S": "---- X--- ---- X---", "H": "X-x- x-x- x-x- x-x-"]),
            Groove("Gallop", tempo: 140, [
                "K": "X-xx X-xx X-xx X-xx", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Double Kick", tempo: 120, [
                "K": "xxxx xxxx xxxx xxxx", "S": "---- X--- ---- X---", "H": "x--- x--- x--- x---"]),
            Groove("Thrash Skank", tempo: 172, [
                "K": "X--- X--- X--- X---", "S": "--X- --X- --X- --X-", "H": "X-x- X-x- X-x- X-x-"]),
            Groove("Sludge Half-Time", tempo: 84, [
                "K": "X-x- ---- --x- ----", "S": "---- ---- X--- ----", "Y": "x-x- x-x- x-x- x-x-"]),
            Groove("Chug", tempo: 150, [
                "K": "X-xX ---- X-xX ----", "S": "---- X--- ---- X---", "B": "x--- x--- x--- x---"]),
        ]),
        GenreDef(name: "Pop", chorus: [.tambourine, .crashOnOne], bridge: [.ride], grooves: [
            Groove("Radio", tempo: 112, [
                "K": "X--- --x- X--- ----", "S": "---- X--- ---- X---", "H": "x-xo x-xo x-xo x-xo"]),
            Groove("Dance Floor", tempo: 122, [
                "K": "X--- X--- X--- X---", "C": "---- X--- ---- X---", "S": "---- o--- ---- o---",
                "H": "--x- --x- --x- --x-"]),
            Groove("Ballad Sidestick", tempo: 72, [
                "K": "X--- ---- --x- ----", "R": "---- x--- ---- x---", "H": "x-x- x-x- x-x- x-x-",
                "SW": "o--- o--- o--- o---"]),  // heard with a brush kit, silent on stick kits
            Groove("Synth Pop", tempo: 118, [
                "K": "X--- --x- X--- --x-", "S": "---- X--- ---- X---", "H": "Xoxo Xoxo Xoxo Xoxo"]),
            Groove("Bounce", tempo: 100, [
                "K": "X--x --x- X--- ----", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-",
                "Z": "-g-g -g-g -g-g -g-g"]),
            Groove("Anthem", tempo: 126, [
                "K": "X--- ---x --x- ---- X--- ---- X-x- ----",
                "S": "---- X--- ---- X--- ---- X--- ---- X---",
                "H": "x-x- x-x- x-x- x-x- x-x- x-x- x-x- x-x-"]),
            Groove("Acoustic Pop", tempo: 96, [
                "K": "X--- ---- X--- ----", "R": "---- x--- ---- x---", "Z": "xoxo xoxo xoxo xoxo"]),
        ]),
        GenreDef(name: "Funk", swing: 0.18, chorus: [.crashOnOne, .busyKick], bridge: [.bell], grooves: [
            Groove("Pocket", tempo: 98, [
                "K": "X-x- ---- --x- -x--", "S": "---- X--g --g- X-g-", "H": "xoxo xoxo xoxo xo--",
                "O": "---- ---- ---- --x-"]),
            Groove("Ghost Notes", tempo: 94, [
                "K": "X--x --x- --X- ----", "S": "---- X-g- -g-g X---", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Linear", tempo: 100, [
                "K": "X--- --x- ---x ----", "S": "--g- X--g -g-- X-g-", "H": "-x-x --x- x-x- -x--"]),
            Groove("Strut", tempo: 106, [
                "K": "X--- --x- -x-- --x-", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-",
                "O": "---- ---- ---- ---x"]),
            Groove("Greasy", tempo: 88, [
                "K": "X--- ---x --x- ----", "S": "--g- X--- -g-- X--g", "H": "xxxx xxxx xxxx xxxx"]),
            Groove("Fusion Two-Bar", tempo: 102, [
                "K": "X--- --x- --x- ---- X-x- ---- --x- -x--",
                "S": "---- X--g -g-- X--- ---g X--- -g-- X---",
                "H": "x-x- x-x- x-x- x-x- x-x- x-x- x-x- x-x-"]),
        ]),
        GenreDef(name: "Blues", kit: 1, chorus: [.ride, .crashOnOne], grooves: [
            Groove("Shuffle", .g12_8, tempo: 112, [
                "K": "X-- --x X-- ---", "S": "--- X-- --- X--", "H": "X-x x-x X-x x-x"]),
            Groove("Slow Twelve-Eight", .g12_8, tempo: 62, [
                "K": "X-- --- X-x ---", "S": "--- X-- --- X--", "H": "xoo xoo xoo xoo"]),
            Groove("Texas Shuffle", .g12_8, tempo: 124, [
                "K": "X-- X-- X-- X--", "S": "--g X-- --g X--", "Y": "x-x x-x x-x x-x"]),
            Groove("Chicago", .g12_8, tempo: 104, [
                "K": "X-- --- X-- ---", "S": "--o X-o --o X-o", "H": "x-x x-x x-x x-x"]),
            Groove("Swamp", .g12_8, tempo: 92, [
                "K": "X-- --x --x ---", "S": "--- X-- --- X--", "Y": "x-x x-x x-x x-x"]),
            Groove("Straight Blues Rock", tempo: 120, [
                "K": "X--- ---- X--x ----", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-"],
                ),
        ]),
        GenreDef(name: "Jazz", kit: 4, chorus: [.crashOnOne, .hardSweeps], grooves: [
            Groove("Medium Swing", .g12_8, tempo: 140, [
                "Y": "x-- x-x x-- x-x", "P": "--- x-- --- x--", "K": "g-- g-- g-- g--", "S": "--- --- --- -g-",
                "SW": "o-- X-- o-- X--"]),
            Groove("Up Tempo", .g12_8, tempo: 210, [
                "Y": "x-- x-x x-- x-x", "P": "--- x-- --- x--", "S": "--- --- -g- ---", "K": "g-- --- --- ---",
                "SW": "X-- --- X-- ---"]),
            Groove("Brush Ballad", .g12_8, tempo: 70, [
                "S": "g-g o-g g-g o-g", "P": "--- x-- --- x--", "K": "o-- --- o-- ---", "SW": "x-- --- x-- ---"]),
            Groove("Jazz Waltz", .g3_4t, tempo: 150, [
                "Y": "x-- x-x x--", "P": "--- x-- x--", "K": "o-- --- ---", "SW": "o-- o-- o--"]),
            Groove("Two Feel", .g12_8, tempo: 120, [
                "Y": "x-- x-x x-- x-x", "P": "--- x-- --- x--", "K": "o-- --- o-- ---", "R": "--- --- --- x--",
                "SW": "o-- --- o-- ---"]),
            Groove("Latin Jazz", tempo: 180, [
                "B": "x-x- x-xx -x-x x-x-", "K": "---x --x- ---x --x-", "R": "---- x--- --x- ----",
                "P": "--x- --x- --x- --x-"]),
        ]),
        GenreDef(name: "Latin", chorus: [.crashOnOne], grooves: [
            Groove("Bossa", tempo: 128, [
                "K": "x--x x--x x--x x--x", "R": "x--x --x- --x- -x--", "H": "o-o- o-o- o-o- o-o-"]),
            Groove("Samba", tempo: 100, [
                "K": "X--x X--x X--x X--x", "S": "g-gg -gg- g-gg -gg-", "Z": "xoxo xoxo xoxo xoxo"]),
            Groove("Cha Cha", tempo: 116, [
                "W": "x-x- x-x- x-x- x-x-", "K": "x--- ---- x--- ----", "R": "---- x--- ---- x-x-",
                "T3": "---- ---- ---- x-x-"]),
            Groove("Latin Rock", tempo: 112, [
                "B": "x-x- x-x- x-x- x-x-", "K": "x--- --x- x--- --x-", "S": "---- x--- ---- x---",
                "T3": "---- ---- ---- ---x"]),
            Groove("Mambo Bell", tempo: 190, [
                "W": "x-x- xx-x -xx- x-x-", "K": "---x --x- ---x --x-", "R": "---- x--- ---- x---",
                "P": "--x- --x- --x- --x-"]),
            Groove("Dembow", tempo: 96, [
                "K": "X--- X--- X--- X---", "S": "---x --x- ---x --x-", "H": "x-x- x-x- x-x- x-x-"]),
        ]),
        GenreDef(name: "Reggae & Ska", swing: 0.3, chorus: [.crashOnOne], grooves: [
            Groove("One Drop", tempo: 74, [
                "K": "---- ---- X--- ----", "R": "---- ---- X--- ----", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Rockers", tempo: 80, [
                "K": "X--- X--- X--- X---", "R": "---- X--- ---- X---", "H": "--x- --x- --x- --x-"]),
            Groove("Steppers", tempo: 84, [
                "K": "X--- X--- X--- X---", "S": "---- ---- X--- ----", "H": "x-xx x-xx x-xx x-xx"]),
            Groove("Ska Upbeat", tempo: 152, [
                "K": "X--- ---- X--- ----", "S": "---- X--- ---- X---", "H": "--x- --x- --x- --x-"]),
            Groove("Dub", tempo: 70, [
                "K": "---- ---- X--- ----", "R": "---- ---- X--- ----", "H": "--x- -x-- --x- -xx-"]),
        ]),
        GenreDef(name: "Country", kit: 1, chorus: [.crashOnOne, .rimToSnare], grooves: [
            Groove("Train", tempo: 140, [
                "S": "gogo Xogo gogo Xogo", "K": "X--- ---- X--- ----"]),
            Groove("Two-Step", tempo: 124, [
                "K": "X--- ---- X--- ----", "R": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Country Shuffle", .g12_8, tempo: 116, [
                "K": "X-- --- X-- ---", "R": "--- X-- --- X--", "H": "x-x x-x x-x x-x"]),
            Groove("Boom Chick", tempo: 150, [
                "K": "X--- ---- X--- ----", "S": "---- x--- ---- x---", "P": "--x- --x- --x- --x-"]),
            Groove("Country Waltz", .g3_4, tempo: 132, [
                "K": "X--- ---- ----", "R": "---- x--- x---", "H": "x-x- x-x- x-x-"]),
            Groove("Modern Country", tempo: 108, [
                "K": "X--- --x- X--- ----", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-",
                "M": "---- x--- ---- x---"]),
        ]),
        GenreDef(name: "Hip-Hop & R&B", kit: 3, swing: 0.35, chorus: [.crashOnOne], grooves: [
            Groove("Boom Bap", tempo: 90, [
                "K": "X--- ---x --X- ----", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Lazy", tempo: 84, [
                "K": "X--x ---- --x- -x--", "S": "---- X--- ---- X---", "H": "xoxo xoxo xoxo xoxo"]),
            Groove("Trap", .g32, tempo: 140, [
                "K": "X--- ---- ---- ---- ---- ---- --x- ----",
                "S": "---- ---- ---- ---- X--- ---- ---- ----",
                "H": "x--- x--- x--- x-x- x--- x--- xxxx x---"]),
            Groove("Slow Jam", tempo: 68, [
                "K": "X--- ---x X--- ----", "C": "---- X--- ---- X---", "H": "x-xx x-x- x-xx x-x-"]),
            Groove("Neo Soul", tempo: 82, [
                "K": "X--- ---- -x-x ----", "S": "---- X--g ---- X-g-", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("West Coast", tempo: 94, [
                "K": "X--- --x- X-x- ----", "C": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-"]),
        ]),
        GenreDef(name: "Electronic", kit: 2, chorus: [.crashOnOne, .shaker], grooves: [
            Groove("House", tempo: 124, [
                "K": "X--- X--- X--- X---", "C": "---- X--- ---- X---", "H": "xx-x xx-x xx-x xx-x",
                "O": "--x- --x- --x- --x-"]),
            Groove("Techno", tempo: 130, [
                "K": "X--- X--- X--- X---", "R": "---- ---- ---- --x-", "H": "--x- --x- --x- --x-",
                "Z": "xoxo xoxo xoxo xoxo"]),
            Groove("Breakbeat", tempo: 132, [
                "K": "X--- ---- --X- ---- --x- ---- -x-- ----",
                "S": "---- X--- ---- X--- ---- X--- ---x X---",
                "H": "x-x- x-x- x-x- x-x- x-x- x-x- x-x- x-x-"]),
            Groove("Drum and Bass", tempo: 172, [
                "K": "X--- ---- --X- ----", "S": "---- X--- ---- X---", "Y": "x-x- x-x- x-x- x-x-"]),
            Groove("Electro", tempo: 118, [
                "K": "X--- --x- --x- ----", "C": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Synthwave", tempo: 108, [
                "K": "X--- ---- X--- ----", "S": "---- X--- ---- X---", "H": "xxxx xxxx xxxx xxxx"]),
        ]),
        GenreDef(name: "Disco & Soul", chorus: [.crashOnOne, .tambourine], grooves: [
            Groove("Disco", tempo: 118, [
                "K": "X--- X--- X--- X---", "S": "---- X--- ---- X---", "H": "x--- x--- x--- x---",
                "O": "--x- --x- --x- --x-"]),
            Groove("Motown", tempo: 128, [
                "K": "x--- x--- x--- x---", "S": "---- X--- ---- X---", "M": "---- X--- ---- X---",
                "H": "x-x- x-x- x-x- x-x-"]),
            Groove("Soul", tempo: 96, [
                "K": "X--- ---x --x- ----", "S": "---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x-",
                "M": "---- x--- ---- x---"]),
            Groove("Northern Stomp", tempo: 140, [
                "K": "X--- X--- X--- X---", "S": "X--- X--- X--- X---", "M": "--x- --x- --x- --x-"]),
            Groove("Philly", tempo: 112, [
                "K": "X--- X--- X--- X---", "S": "---- X--- ---- X--g", "H": "xoxo xoxo xoxo xoxo",
                "O": "---- ---- ---- ---x"]),
        ]),
        GenreDef(name: "Punk", chorus: [.crashOnOne], grooves: [
            Groove("Straight Punk", tempo: 176, [
                "K": "X-x- --x- X-x- --x-", "S": "---- X--- ---- X---", "O": "x-x- x-x- x-x- x-x-"]),
            Groove("Skate", tempo: 196, [
                "K": "X--- X--- X--- X---", "S": "--X- --X- --X- --X-", "Y": "x-x- x-x- x-x- x-x-"]),
            Groove("Pop Punk", tempo: 168, [
                "K": "X-x- ---- X-x- ----", "S": "---- X--- ---- X---", "O": "x-x- x-x- x-x- x-x-"]),
            Groove("Garage", tempo: 150, [
                "K": "X--- ---- X--- ----", "S": "---- X--- ---- X---", "H": "X-X- X-X- X-X- X-X-"]),
        ]),
        GenreDef(name: "Folk & Acoustic", kit: 4, chorus: [.crashOnOne, .tambourine, .hardSweeps], grooves: [
            Groove("Shaker Groove", tempo: 100, [
                "Z": "xoxo xoxo xoxo xoxo", "K": "X--- ---- X--- ----", "R": "---- x--- ---- x---"]),
            Groove("Tom Groove", tempo: 108, [
                "T3": "x--x --x- x--x --x-", "K": "X--- ---- X--- ----", "M": "---- x--- ---- x---"]),
            Groove("Six-Eight Ballad", .g6_8, tempo: 150, [
                "H": "x-x- x-x- x-x-", "K": "X--- ---- ----", "S": "---- --X- ----", "SW": "o--- --o- ----"]),
            Groove("Stomp Clap", tempo: 92, [
                "K": "X--- ---- X--- ----", "C": "---- X--- ---- X---"]),
            Groove("Campfire", .g6_8, tempo: 132, [
                "K": "X--- ---- ----", "R": "---- --x- ----", "Z": "x-o- o-x- o-o-", "SW": "o--- --o- ----"]),
        ]),
        GenreDef(name: "Waltz & Triple", chorus: [.crashOnOne, .ride], grooves: [
            Groove("Classic Waltz", .g3_4, tempo: 144, [
                "K": "X--- ---- ----", "S": "---- x--- x---", "H": "x--- x--- x---"]),
            Groove("Rock Three", .g3_4, tempo: 120, [
                "K": "X--- --x- ----", "S": "---- ---- X---", "H": "x-x- x-x- x-x-"]),
            Groove("Six-Eight Rock", .g6_8, tempo: 168, [
                "K": "X--- -x-- ----", "S": "---- --X- ----", "H": "x-x- x-x- x-x-"]),
            Groove("Slow Six-Eight", .g6_8, tempo: 108, [
                "K": "X--- ---- x---", "S": "---- --X- ----", "Y": "x-x- x-x- x-x-"]),
        ]),
        GenreDef(name: "Gospel & Shuffle", chorus: [.crashOnOne], grooves: [
            Groove("Gospel Shuffle", .g12_8, tempo: 108, [
                "K": "X-- --x X-- --x", "S": "--- X-g --- X--", "H": "x-x x-x x-x x-x"]),
            Groove("Church Clap", .g12_8, tempo: 96, [
                "K": "X-- --- X-- ---", "C": "--- X-- --- X--", "S": "--- X-- --- X--", "H": "x-x x-x x-x x-x"]),
            Groove("Half-Time Shuffle", .g12_8, tempo: 86, [
                "K": "X-x --- --x ---", "S": "-g- --g X-g --g", "H": "x-x x-x x-x x-x"]),
            Groove("Pop Shuffle", .g12_8, tempo: 128, [
                "K": "X-- --x --x ---", "S": "--- X-- --- X--", "H": "x-x x-x x-x x-x"]),
        ]),
        GenreDef(name: "Odd Time", chorus: [.crashOnOne, .ride], grooves: [
            Groove("Five Four", .g5_4, tempo: 120, [
                "K": "X--- ---- ---- X--- ----", "S": "---- ---- X--- ---- X---", "H": "x-x- x-x- x-x- x-x- x-x-"]),
            Groove("Seven Eight", .g7_8, tempo: 132, [
                "K": "X--- ---- X--- --", "S": "---- X--- ---- X-", "H": "x-x- x-x- x-x- x-"]),
            Groove("Five Four Swing", .g5_4, tempo: 168, [
                "Y": "x--x x--x x--x x--- x---", "P": "---- x--- x--- ---- x---", "K": "x--- ---- ---- x--- ----"]),
            Groove("Seven Eight Groove", .g7_8, tempo: 116, [
                "K": "X-x- ---- X--- --", "S": "---- X--- --x- X-", "H": "x-x- x-x- x-x- x-"]),
        ]),
        GenreDef(name: "Percussion", chorus: [.crashOnOne], grooves: [
            Groove("Cowbell Groove", tempo: 108, [
                "W": "x-x- x-x- x-x- x-x-", "K": "X--- ---- X--- ----", "S": "---- X--- ---- X---"]),
            Groove("Shaker & Tamb", tempo: 96, [
                "Z": "xoxo xoxo xoxo xoxo", "M": "---- X--- ---- X---", "K": "X--- ---- X--- ----"]),
            Groove("Tom Tribal", tempo: 112, [
                "T3": "X--x --x- X--x --x-", "T1": "---- x--- ---- x-x-", "K": "X--- ---- X--- ----",
                "Z": "x-x- x-x- x-x- x-x-"]),
            Groove("Click Track", tempo: 120, [
                "R": "X--- x--- x--- x---"]),
        ]),
    ]

    /// Builds all factory songs.
    static func build() -> [SongData] {
        var songs: [SongData] = []
        var seed = 0
        for genre in genres {
            var n = 1
            // One song per groove: verse, chorus, optional bridge.
            for g in genre.grooves {
                var parts = [g, g.applying(genre.chorus)]
                if let b = genre.bridge { parts.append(g.applying(b)) }
                let r = SongRecipe(genre: genre.name, name: "\(genre.name) \(n) · \(g.name)", parts: parts,
                                   tempo: g.tempo, bakedSwing: genre.swing, kitHint: genre.kit, seed: seed)
                var song = SongBuilder.build(r)
                BassGenerator.apply(to: &song, seed: seed)
                songs.append(song)
                n += 1; seed += 1
            }
            // Combination songs: verse from one groove, chorus from the next.
            let gs = genre.grooves
            for i in 0..<gs.count {
                let a = gs[i], b = gs[(i + 1) % gs.count]
                guard a.grid == b.grid, a.name != b.name else { continue }
                let parts = [a, b.applying(genre.chorus), a.applying([.ride, .crashOnOne])]
                let tempo = ((a.tempo + b.tempo) / 2).rounded()
                let r = SongRecipe(genre: genre.name, name: "\(genre.name) \(n) · \(a.name) / \(b.name)",
                                   parts: parts, tempo: tempo, bakedSwing: genre.swing, kitHint: genre.kit,
                                   seed: seed + 7)
                var song = SongBuilder.build(r)
                BassGenerator.apply(to: &song, seed: seed + 7)
                songs.append(song)
                n += 1; seed += 1
            }
        }
        // Last, so the songs above keep their numbers. Hand-written bass — generator leaves them alone.
        for (i, d) in bassSongs.enumerated() {
            let g = d.groove
            let r = SongRecipe(genre: bassGenre, name: "\(bassGenre) \(i + 1) · \(g.name)",
                               parts: [g, g.applying(d.chorus), g.applying(d.bridge)], tempo: g.tempo, seed: seed)
            var song = SongBuilder.build(r)
            for (k, line) in d.lines.enumerated() where k < song.parts.count { song.parts[k].bass = BassLine.pattern(line, g.grid) }
            song.outroBass = BassLine.pattern(d.outro, g.grid)
            song.bassRootPitchClass = 4   // E — Bass Follow transpose reference
            BassGenerator.apply(to: &song, seed: seed)   // no-op: song already hasBass
            songs.append(song)
            seed += 1
        }
        return songs
    }

    // MARK: Bass & Drums

    /// A groove with a bass line for verse, chorus and bridge, and one for the ending.
    struct BassSongDef {
        let groove: Groove
        var chorus: [T]
        var bridge: [T]
        let lines: [String]
        let outro: String
    }

    static let bassGenre = "Bass & Drums"

    static let bassSongs: [BassSongDef] = [
        BassSongDef(groove: Groove("Rock Eighths", tempo: 116, [
                        "K": "X--- ---- X-x- ----", "S": "---- X--- ---- X---", "H": "X-x- x-x- X-x- x-x-"]),
                    chorus: [.openHats, .crashOnOne], bridge: [.floorTom], lines: [
                        "E1 . E1 . E1 . E1 . E1 . E1 . G1 . A1 . | E1 . E1 . E1 . E1 . D2 . D2 . B1 . A1 .",
                        "A1 . A1 . A1 . A1 . A1 . A1 . A1 . A1 . | C2 . C2 . C2 . C2 . D2 . D2 . D2 . D2 .",
                        "C2 . . . . . C2 . D2 . . . . . D2 . | E2 . . . . . . . B1 . . . A1 . G1 .",
                    ],
                    outro: "E1 . E1 . E1 . E1 . G1 . G1 . A1 . B1 . | E1 . . . . . . . . . . . . . . ."),
        BassSongDef(groove: Groove("Funk Pocket", tempo: 98, [
                        "K": "X--x --x- --X- ----", "S": "---- X-g- -g-g X---", "H": "x-x- x-x- x-x- x-x-"]),
                    chorus: [.crashOnOne, .busyKick], bridge: [.bell], lines: [
                        "E1 . - E1 - - E2 - - - E1 . - G1 A1 B1",
                        "A1 . - a1 A1 - A2 - - a1 A1 . - C2 D2 Eb2",
                        "D2 . . - D2 . - D2 - - C2 . - C2 - - | B1 . . - B1 . - B1 - - A1 . G1 . E1 -",
                    ],
                    outro: "E1 . - E1 - - E2 - - - E1 . - G1 A1 B1 | E1 . . . . . . . . . . . . . . ."),
        BassSongDef(groove: Groove("Shuffle Walk", .g12_8, tempo: 104, [
                        "K": "X-- --- X-- ---", "S": "--- X-- --- X--", "H": "x-x x-x x-x x-x"]),
                    chorus: [.ride, .crashOnOne], bridge: [.floorTom], lines: [
                        "E1 . G#1 B1 . C#2 D2 . C#2 B1 . G#1 | A1 . C#2 E2 . F#2 G2 . F#2 E2 . C#2",
                        "B1 . D#2 F#2 . G#2 A2 . G#2 F#2 . D#2 | A1 . C#2 E2 . F#2 G2 . F#2 E2 . C#2",
                        "A1 . C#2 E2 . F#2 G2 . F#2 E2 . C#2 | E1 . G#1 B1 . C#2 D2 . C#2 B1 . G#1",
                    ],
                    outro: "B1 . D#2 F#2 . G#2 A2 . G#2 F#2 . D#2 | E1 . . . . . . . . . . ."),
    ]
}
