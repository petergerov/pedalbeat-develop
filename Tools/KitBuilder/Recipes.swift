/// Drum mappings for the open-licensed source libraries. Notes, CCs and mic
/// settings come from each library's own SFZ program (see `kitbuilder probe`).
/// Layer / RR counts are pushed high so the kits feel as dense as the decoded pedal kits.
enum Recipes {
    static let all: [KitRecipe] = [
        jazz, brushes, studio, bigRoom, cajon, cajon2, cajon3, cajonFlamenco, worldPercussion, bobobo,
        body, bodyStomp, bodyHands, bodyChest, bodyStereo,
    ]

    // Virtuosity Drums: contemporary jazz kit played with sticks (CC0).
    // CC4 = hi-hat pedal (127 closed, 0 open).
    static let jazz = KitRecipe(
        id: "pedalbeat.jazz-sticks", name: "Jazz Kit", category: "jazz",
        author: "Versilian Studios & Karoryfer Samples (Virtuosity Drums)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/virtuosity_drums",
        notes: "Recorded at Virtuosity Musical Instruments, Boston, MA. Close + overhead mics, library default mix. Dense velocity layers for a lively stick kit.",
        dir: "virtuosity_drums", program: "Programs/02-full-kit.sfz", outRate: 48000,
        fallbackSynthKit: 0, suggestFor: [1],
        drums: [
            D(.kick, 36, layers: 6, rr: 4, sec: 1.1, db: 3),
            D(.snare, 38, layers: 8, rr: 3, sec: 1.1),
            D(.rim, 88, layers: 5, rr: 2, sec: 0.55),
            D(.hatClosed, 42, layers: 6, rr: 4, sec: 0.75, cc: [4: 127]),
            D(.hatPedal, 44, layers: 4, rr: 4, sec: 0.75, db: 8),
            D(.hatOpen, 42, layers: 5, rr: 3, sec: 2.4, cc: [4: 0]),
            D(.ride, 51, layers: 5, rr: 4, sec: 3.2, db: 4),
            D(.rideBell, 53, layers: 4, rr: 3, sec: 3.2, db: 3),
            D(.crash, 49, layers: 4, rr: 3, sec: 3.8, db: 3),
            D(.tomHigh, 48, layers: 5, rr: 2, sec: 1.7),
            D(.tomMid, 50, layers: 5, rr: 2, sec: 1.7),
            D(.tomLow, 41, layers: 5, rr: 2, sec: 1.9),
            D(.cowbell, 56, layers: 4, rr: 3, sec: 0.85),
            D(.shaker, 82, layers: 2, rr: 4, sec: 0.65),
            D(.tambourine, 54, layers: 2, rr: 4, sec: 0.95),
        ])

    // Swirly Drums: kit played with brushes (CC0). CC4 = hi-hat (0 closed, 127 open).
    static let brushes = KitRecipe(
        id: "pedalbeat.brushes", name: "Brush Kit", category: "brushes",
        author: "Karoryfer Samples (Swirly Drums)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/karoryfer.swirly-drums",
        notes: "Acoustic kit played with brushes, including continuous snare sweeps (stirs). Library default mix.",
        dir: "karoryfer.swirly-drums", program: "Programs/Full_kit.sfz", outRate: 44100,
        fallbackSynthKit: 4, suggestFor: [4],
        drums: [
            D(.kick, 36, layers: 6, rr: 4, sec: 1.1),
            D(.snare, 38, layers: 7, rr: 4, sec: 1.1),
            D(.rim, 40, layers: 5, rr: 3, sec: 0.75),
            D(.hatClosed, 46, layers: 6, rr: 4, sec: 0.75, db: 3, cc: [4: 0]),
            D(.hatPedal, 44, layers: 4, rr: 3, sec: 0.75, db: 4),
            D(.hatOpen, 46, layers: 5, rr: 3, sec: 2.4, db: 3, cc: [4: 127]),
            D(.ride, 51, layers: 6, rr: 4, sec: 3.2, db: 4),
            D(.rideBell, 51, layers: 3, rr: 3, sec: 3.2, db: 4),
            D(.crash, 49, layers: 5, rr: 3, sec: 3.8, db: 4),
            D(.tomHigh, 47, layers: 5, rr: 3, sec: 1.7, db: 6),
            D(.tomMid, 45, layers: 5, rr: 3, sec: 1.7, db: 6),
            D(.tomLow, 41, layers: 5, rr: 3, sec: 1.9, db: 6),
            D(.cowbell, 66, layers: 4, rr: 3, sec: 0.85, db: 8),
            // Continuous snare stirs: light (dl1), medium (dl2) and hard (dl3) pressure.
            // dl3 isn't mapped in the library, so it's rendered through dl2's mapping (same mics).
            Sweep([SweepLayer(note: 60, hiVelocity: 80),
                   SweepLayer(note: 64, hiVelocity: 108),
                   SweepLayer(note: 64, hiVelocity: 127, swap: ("stir_dl2", "stir_dl3"))],
                  rr: 3, sec: 6, db: 6),
        ])

    // Naked Drums: modern multi-mic studio kit (CC-BY-4.0, attribution required).
    static let studio = KitRecipe(
        id: "pedalbeat.studio-acoustic", name: "Studio Acoustic", category: "acoustic",
        author: "Wilkinson Audio (Naked Drums)",
        license: "CC-BY-4.0", source: "https://github.com/sfzinstruments/WilkinsonAudio.NakedDrums",
        notes: "Naked Drums © Wilkinson Audio 2016, licensed CC BY 4.0. Stereo mix, denser layers for a modern session sound.",
        dir: "naked-drums/Wilkinson Audio/Naked Drums", program: "Stereo/Naked Drums.sfz", outRate: 44100,
        fallbackSynthKit: 0, suggestFor: [0],
        drums: [
            D(.kick, 36, layers: 7, rr: 4, sec: 1.1, db: 4),
            D(.snare, 38, layers: 7, rr: 4, sec: 1.1),
            D(.rim, 37, layers: 2, rr: 4, sec: 0.55, db: 4),
            D(.hatClosed, 42, layers: 5, rr: 4, sec: 0.75, db: 6),
            D(.hatPedal, 44, layers: 2, rr: 4, sec: 0.75, db: 10),
            D(.hatOpen, 49, layers: 4, rr: 3, sec: 2.4, db: 5),
            D(.ride, 51, layers: 5, rr: 4, sec: 3.2, db: 3),
            D(.rideBell, 53, layers: 2, rr: 4, sec: 3.2, db: 3),
            D(.crash, 55, layers: 4, rr: 3, sec: 3.8),
            D(.tomHigh, 48, layers: 5, rr: 3, sec: 1.7),
            D(.tomMid, 45, layers: 5, rr: 3, sec: 1.7),
            D(.tomLow, 41, layers: 5, rr: 3, sec: 1.9),
        ])

    // Big Rusty Drums: oversized 1980s kit with a big room sound (CC0).
    static let bigRoom = KitRecipe(
        id: "pedalbeat.big-room", name: "Big Room", category: "acoustic",
        author: "Karoryfer Samples (Big Rusty Drums)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/karoryfer.big-rusty-drums",
        notes: "Oversized drum kit built in 1980s Poland. Library default mix, thick layers for arena punch.",
        dir: "karoryfer.big-rusty-drums", program: "Programs/01-full.sfz", outRate: 44100,
        fallbackSynthKit: 1, suggestFor: [],
        drums: [
            D(.kick, 36, layers: 7, rr: 4, sec: 1.3),
            D(.snare, 38, layers: 7, rr: 4, sec: 1.3),
            D(.rim, 37, layers: 4, rr: 3, sec: 0.65),
            D(.hatClosed, 42, layers: 6, rr: 4, sec: 0.75),
            D(.hatPedal, 44, layers: 4, rr: 3, sec: 0.75, db: 4),
            D(.hatOpen, 46, layers: 5, rr: 3, sec: 2.4),
            D(.ride, 51, layers: 5, rr: 4, sec: 3.2),
            D(.rideBell, 53, layers: 4, rr: 3, sec: 3.2),
            D(.crash, 49, layers: 5, rr: 3, sec: 3.8),
            D(.tomHigh, 47, layers: 5, rr: 3, sec: 1.7),
            D(.tomMid, 43, layers: 5, rr: 3, sec: 1.9),
            D(.tomLow, 41, layers: 5, rr: 3, sec: 2.1),
        ])

    // Gogodze Phu Cajón (CC0): five strike locations, sides, snare-off tones, finger rolls.
    static let cajon = KitRecipe(
        id: "pedalbeat.cajon", name: "Cajón", category: "percussion",
        author: "Karoryfer Samples (Gogodze Phu Vol I)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/karoryfer.gogodze-phu-vol-i",
        notes: "Polish cajón: bass and snare-face hits, side taps, snare-off conga tones, and continuous finger rolls. Front+rear mic mix.",
        dir: "karoryfer.gogodze-phu-vol-i", program: "Programs/Cajon.sfz", outRate: 44100,
        cc: [7: 110, 70: 100, 71: 100, 72: 63, 11: 100],
        fallbackSynthKit: 0, suggestFor: [],
        targetPeak: 0.93,
        drums: [
            D(.kick, 48, layers: 4, rr: 5, sec: 1.5, db: 5),
            D(.snare, 52, layers: 4, rr: 5, sec: 1.3, db: 3),
            D(.clap, 51, layers: 4, rr: 5, sec: 1.1, db: 2),
            D(.rim, 54, layers: 1, rr: 6, sec: 0.9, db: 14),
            D(.hatClosed, 53, layers: 3, rr: 5, sec: 0.8, db: 5),
            D(.hatPedal, 53, layers: 2, rr: 4, sec: 0.7, db: 2),
            D(.hatOpen, 49, layers: 4, rr: 5, sec: 1.3, db: 1),
            D(.tomHigh, 56, layers: 4, rr: 5, sec: 1.35, db: 4),
            D(.tomMid, 55, layers: 4, rr: 5, sec: 1.35, db: 4),
            D(.tomLow, 50, layers: 4, rr: 5, sec: 1.4, db: 3),
            D(.crash, 52, layers: 3, rr: 4, sec: 1.6, db: 7),
            D(.ride, 50, layers: 3, rr: 4, sec: 1.5, db: 0),
            D(.rideBell, 51, layers: 3, rr: 4, sec: 1.3, db: 5),
            // Finger rolls: light / medium / hard via the library's roll volume (CC11), as it does
            // itself. Velocity doesn't change the rolls; the other roll positions (CC1) are far quieter.
            Sweep([SweepLayer(note: 57, hiVelocity: 80, cc: [11: 64]),
                   SweepLayer(note: 57, hiVelocity: 108, cc: [11: 90]),
                   SweepLayer(note: 57, hiVelocity: 127, cc: [11: 127])],
                  rr: 5, sec: 8, db: 5),
        ])

    // Cajón 2: Swirly bass for a bit more depth, but voiced round like Cajón 1 —
    // same Gogodze face/sides/slap family, sweet rim, crash = louder slap.
    static let cajon2 = KitRecipe(
        id: "pedalbeat.cajon2", name: "Cajón 2", category: "percussion",
        author: "Karoryfer Samples (Gogodze Phu + Swirly cajón kick)",
        license: "CC0-1.0",
        source: "https://github.com/sfzinstruments/karoryfer.gogodze-phu-vol-i",
        notes: "Rounder Cajón 2: warmer Swirly bass (pulled back), Gogodze face/sides/slap like Cajón 1, "
            + "sweet side taps, crash = same slap family. Deeper pocket without losing the one-box feel.",
        dir: "karoryfer.gogodze-phu-vol-i", program: "Programs/Cajon.sfz", outRate: 44100,
        // Slightly more rear mic (70) than front (71) → rounder, less clicky box.
        cc: [7: 108, 70: 110, 71: 88, 72: 58, 11: 100],
        fallbackSynthKit: 0, suggestFor: [],
        targetPeak: 0.90,
        drums: [
            // Swirly kick softened (−2 dB vs old) so it sits under Gogodze faces.
            D(.kick, 35, layers: 10, rr: 4, sec: 1.55, db: 1,
              cc: [45: 92, 46: 70, 47: 55],
              program: "../karoryfer.swirly-drums/Programs/Full_kit.sfz"),
            D(.snare, 52, layers: 4, rr: 5, sec: 1.3, db: 2),
            D(.clap, 51, layers: 4, rr: 5, sec: 1.1, db: 1),
            D(.rim, 54, layers: 1, rr: 6, sec: 0.9, db: 14),
            D(.hatClosed, 53, layers: 3, rr: 5, sec: 0.8, db: 5),
            D(.hatPedal, 53, layers: 2, rr: 4, sec: 0.7, db: 2),
            D(.hatOpen, 49, layers: 4, rr: 5, sec: 1.3, db: 0),
            D(.tomHigh, 56, layers: 4, rr: 5, sec: 1.35, db: 3),
            D(.tomMid, 55, layers: 4, rr: 5, sec: 1.35, db: 3),
            D(.tomLow, 50, layers: 4, rr: 5, sec: 1.4, db: 2),
            // Same slap as snare (Cajón 1 sweet spot) — not a foreign crash.
            D(.crash, 52, layers: 3, rr: 4, sec: 1.6, db: 6),
            D(.ride, 50, layers: 3, rr: 4, sec: 1.5, db: 0),
            D(.rideBell, 51, layers: 3, rr: 4, sec: 1.3, db: 4),
            Sweep([SweepLayer(note: 57, hiVelocity: 80, cc: [11: 64]),
                   SweepLayer(note: 57, hiVelocity: 108, cc: [11: 90]),
                   SweepLayer(note: 57, hiVelocity: 127, cc: [11: 127])],
                  rr: 5, sec: 8, db: 4),
        ])

    // Cajón 3: ghost-dense Gogodze + soft Swirly bass, one-box mapping like Cajón 1.
    // FreePats only for PedalBeat percussion layers (shaker/tamb/maracas), tucked back.
    static let cajon3 = KitRecipe(
        id: "pedalbeat.cajon3", name: "Cajón 3", category: "percussion",
        author: "Karoryfer (Gogodze Phu + Swirly) + FreePats hand perc",
        license: "CC0-1.0",
        source: "https://github.com/sfzinstruments/karoryfer.gogodze-phu-vol-i",
        notes: "Round Cajón 3: soft Swirly bass, full Gogodze ghost→slap dynamics, Cajón-1 voice map "
            + "(sweet rim, crash = slap), finger rolls; FreePats shaker/tamb/maracas only for layers.",
        dir: "karoryfer.gogodze-phu-vol-i", program: "Programs/Cajon.sfz", outRate: 44100,
        cc: [7: 108, 70: 110, 71: 88, 72: 58, 11: 100],
        fallbackSynthKit: 0, suggestFor: [],
        targetPeak: 0.90,
        drums: [
            D(.kick, 35, layers: 13, rr: 4, sec: 1.6, db: 1,
              cc: [45: 92, 46: 70, 47: 55],
              program: "../karoryfer.swirly-drums/Programs/Full_kit.sfz"),
            // Soft ≤31 = ghosts; keep all 4 dynamics.
            D(.snare, 52, layers: 4, rr: 5, sec: 1.3, db: 2),
            D(.clap, 51, layers: 4, rr: 5, sec: 1.1, db: 1),
            D(.rim, 54, layers: 1, rr: 6, sec: 0.9, db: 14),
            D(.hatClosed, 53, layers: 3, rr: 5, sec: 0.8, db: 5),
            D(.hatPedal, 53, layers: 2, rr: 4, sec: 0.7, db: 2),
            D(.hatOpen, 49, layers: 4, rr: 5, sec: 1.3, db: 0),
            D(.tomHigh, 56, layers: 4, rr: 5, sec: 1.35, db: 3),
            D(.tomMid, 55, layers: 4, rr: 5, sec: 1.35, db: 3),
            D(.tomLow, 50, layers: 4, rr: 5, sec: 1.4, db: 2),
            D(.crash, 52, layers: 3, rr: 4, sec: 1.6, db: 6),
            D(.ride, 50, layers: 4, rr: 5, sec: 1.5, db: 0),
            D(.rideBell, 51, layers: 3, rr: 4, sec: 1.3, db: 4),
            // Hand perc only — quiet so they don't break the box.
            D(.shaker, 54, layers: 1, rr: 8, sec: 0.5, db: -2,
              program: "../world-percussion/WorldPercussion 20200905.sfz"),
            D(.tambourine, 57, layers: 1, rr: 8, sec: 0.75, db: -1,
              program: "../world-percussion/WorldPercussion 20200905.sfz"),
            D(.maracas, 67, layers: 1, rr: 8, sec: 0.5, db: -2,
              program: "../world-percussion/WorldPercussion 20200905.sfz"),
            Sweep([SweepLayer(note: 57, hiVelocity: 80, cc: [11: 58]),
                   SweepLayer(note: 57, hiVelocity: 108, cc: [11: 85]),
                   SweepLayer(note: 57, hiVelocity: 127, cc: [11: 120])],
                  rr: 5, sec: 8, db: 4),
        ])

    // FreePats flamenco cajón (CC0): lots of round-robins, no velocity layers — different character.
    static let cajonFlamenco = KitRecipe(
        id: "pedalbeat.cajon-flamenco", name: "Cajón Flamenco", category: "percussion",
        author: "FreePats / Xavimart (World Percussion)",
        license: "CC0-1.0", source: "https://github.com/freepats/world-percussion",
        notes: "Flamenco cajón from FreePats World Percussion (Zoom H1 field recordings). Huge round-robin pools, single dynamic layer — lively and raw, not as deep as the hybrid Cajón kit.",
        dir: "world-percussion", program: "WorldPercussion 20200905.sfz", outRate: 48000,
        fallbackSynthKit: 0, suggestFor: [],
        targetPeak: 0.92,
        drums: [
            D(.kick, 48, layers: 1, rr: 8, sec: 1.2, db: 4),       // flamenco 1
            D(.snare, 50, layers: 1, rr: 10, sec: 1.0, db: 3),     // flamenco 2
            D(.rim, 49, layers: 1, rr: 2, sec: 0.8, db: 2),        // flamenco 3
            D(.clap, 59, layers: 1, rr: 6, sec: 0.7, db: 1),       // hand clap
            D(.hatClosed, 54, layers: 1, rr: 8, sec: 0.5, db: 2), // egg shaker soft
            D(.hatPedal, 56, layers: 1, rr: 6, sec: 0.5),
            D(.hatOpen, 55, layers: 1, rr: 6, sec: 0.6, db: 1),   // egg shaker fast
            D(.tomHigh, 63, layers: 1, rr: 4, sec: 1.0, db: 2),   // conga high
            D(.tomMid, 62, layers: 1, rr: 4, sec: 1.1, db: 2),    // conga
            D(.tomLow, 64, layers: 1, rr: 4, sec: 1.2, db: 3),    // conga low
            D(.crash, 50, layers: 1, rr: 6, sec: 1.2, db: 6),
            D(.ride, 52, layers: 1, rr: 6, sec: 0.9, db: 1),      // bongo high
            D(.cowbell, 60, layers: 1, rr: 4, sec: 0.6, db: 3),   // claves
            D(.shaker, 67, layers: 1, rr: 6, sec: 0.5, db: 2),    // maracas
            D(.tambourine, 57, layers: 1, rr: 6, sec: 0.7, db: 2),
        ])

    // FreePats World Percussion as a Handy Grooves–style section kit: cajón + congas/bongos +
    // darbuka + shakers/claves/castanets, mapped so GM Latin notes (Groove Monkee World Beats, etc.)
    // land on the right voices via Drum.fromGM.
    static let worldPercussion = KitRecipe(
        id: "pedalbeat.world-percussion", name: "World Percussion", category: "percussion",
        author: "FreePats / Xavimart (World Percussion)",
        license: "CC0-1.0", source: "https://github.com/freepats/world-percussion",
        notes: "Handy Grooves–style world section: cajón bass/slap, darbuka doom/tak, congas & bongos on the toms, egg shaker time-keeping, claves/castanets/maracas/tambourine accents. Built for layered world MIDI grooves (4/4 and 6/8).",
        dir: "world-percussion", program: "WorldPercussion 20200905.sfz", outRate: 48000,
        fallbackSynthKit: 0, suggestFor: [],
        targetPeak: 0.93,
        drums: [
            D(.kick, 69, layers: 1, rr: 8, sec: 1.4, db: 5),        // darbuka doom (deep pocket)
            D(.snare, 70, layers: 1, rr: 8, sec: 1.0, db: 4),       // darbuka tak
            D(.rim, 60, layers: 1, rr: 4, sec: 0.55, db: 4),        // claves (also GM woodblocks)
            D(.clap, 59, layers: 1, rr: 6, sec: 0.7, db: 2),        // hand clap
            D(.hatClosed, 56, layers: 1, rr: 8, sec: 0.45, db: 2),  // egg shaker soft
            D(.hatPedal, 54, layers: 1, rr: 6, sec: 0.45),          // egg shaker slow
            D(.hatOpen, 55, layers: 1, rr: 8, sec: 0.55, db: 1),    // egg shaker fast
            D(.ride, 52, layers: 1, rr: 8, sec: 0.9, db: 1),        // bongo high
            D(.rideBell, 51, layers: 1, rr: 4, sec: 0.75, db: 2),   // bongo muted
            D(.crash, 48, layers: 1, rr: 8, sec: 1.3, db: 3),       // cajón flamenco bass accent
            D(.tomHigh, 53, layers: 1, rr: 8, sec: 1.0, db: 2),     // bongo low (GM hi/lo bongo)
            D(.tomMid, 62, layers: 1, rr: 6, sec: 1.1, db: 2),      // conga (GM mute/open hi)
            D(.tomLow, 63, layers: 1, rr: 6, sec: 1.25, db: 3),     // low conga (GM low conga)
            D(.cowbell, 61, layers: 1, rr: 8, sec: 0.65, db: 3),    // castanets
            D(.shaker, 67, layers: 1, rr: 8, sec: 0.5, db: 2),      // maracas (GM cabasa/maracas)
            D(.tambourine, 57, layers: 1, rr: 8, sec: 0.75, db: 2),
        ])

    // Gogodze Phu Bobobo: five Ghanaian bobobo drums (CC0).
    static let bobobo = KitRecipe(
        id: "pedalbeat.bobobo", name: "Bobobo", category: "percussion",
        author: "Karoryfer Samples (Gogodze Phu Vol I)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/karoryfer.gogodze-phu-vol-i",
        notes: "Five bobobo drums from Ghana — bass, tenor and treble, open and muted articulations — mapped across the PedalBeat kit for Afro / percussion grooves.",
        dir: "karoryfer.gogodze-phu-vol-i", program: "Programs/Bobobo.sfz", outRate: 44100,
        fallbackSynthKit: 0, suggestFor: [],
        targetPeak: 0.93,
        drums: [
            D(.kick, 36, layers: 4, rr: 4, sec: 1.4, db: 4),          // bass drum
            D(.snare, 40, layers: 4, rr: 4, sec: 1.2, db: 3),         // tenor small open
            D(.rim, 41, layers: 4, rr: 4, sec: 1.0, db: 2),           // tenor small muted
            D(.clap, 39, layers: 4, rr: 4, sec: 1.1, db: 2),          // tenor large muted
            D(.hatClosed, 44, layers: 4, rr: 4, sec: 0.9, db: 1),    // treble large muted
            D(.hatPedal, 41, layers: 3, rr: 3, sec: 0.85),
            D(.hatOpen, 43, layers: 4, rr: 4, sec: 1.3, db: 2),      // treble large open
            D(.tomHigh, 45, layers: 4, rr: 4, sec: 1.25, db: 3),     // treble small open
            D(.tomMid, 38, layers: 4, rr: 4, sec: 1.3, db: 3),       // tenor large open
            D(.tomLow, 36, layers: 3, rr: 4, sec: 1.5, db: 1),       // bass again, softer trim via dyn
            D(.crash, 45, layers: 3, rr: 3, sec: 1.5, db: 6),
            D(.ride, 43, layers: 3, rr: 3, sec: 1.4, db: 1),
            D(.cowbell, 46, layers: 4, rr: 4, sec: 1.0, db: 4),      // treble small muted — dry click
        ])

    // Body percussion (CC0): one sample set, several PedalBeat mappings with different feels.

    /// Balanced “human drum kit”: stomp kick, handclap snare, snaps as hats.
    static let body = KitRecipe(
        id: "pedalbeat.body", name: "Body Percussion", category: "percussion",
        author: "Karoryfer Samples (Body Percussion)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/body_percussion",
        notes: "Balanced body kit: stomps, chest, snaps and claps mapped like a drum set.",
        dir: "body_percussion", program: "Programs/body.sfz", outRate: 44100,
        fallbackSynthKit: 2, suggestFor: [2],
        targetPeak: 0.9,
        drums: [
            D(.kick, 40, layers: 2, rr: 6, sec: 0.9, db: 4),
            D(.snare, 61, layers: 2, rr: 6, sec: 0.8, db: 2),
            D(.rim, 56, layers: 1, rr: 6, sec: 0.5, db: 3),
            D(.clap, 60, layers: 2, rr: 6, sec: 0.7, db: 1),
            D(.hatClosed, 58, layers: 1, rr: 4, sec: 0.4, db: 2),
            D(.hatPedal, 38, layers: 2, rr: 6, sec: 0.6),
            D(.hatOpen, 57, layers: 1, rr: 6, sec: 0.5, db: 1),
            D(.tomHigh, 48, layers: 2, rr: 4, sec: 0.8, db: 2),
            D(.tomMid, 46, layers: 2, rr: 4, sec: 0.85, db: 2),
            D(.tomLow, 44, layers: 2, rr: 4, sec: 0.9, db: 3),
            D(.crash, 51, layers: 2, rr: 6, sec: 1.0, db: 5),
            D(.ride, 42, layers: 2, rr: 6, sec: 0.7),
            D(.shaker, 59, layers: 1, rr: 4, sec: 0.4, db: 4),
            D(.tambourine, 52, layers: 1, rr: 4, sec: 0.45, db: 2),
        ])

    /// Foot-forward: heels, half-stomps and stomps — weighty, march / house feel.
    static let bodyStomp = KitRecipe(
        id: "pedalbeat.body-stomp", name: "Body Stomp", category: "percussion",
        author: "Karoryfer Samples (Body Percussion)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/body_percussion",
        notes: "Feet-first mapping: heels, half-stomps and full stomps as the whole kit. Heavy and grounded.",
        dir: "body_percussion", program: "Programs/body.sfz", outRate: 44100,
        fallbackSynthKit: 2, suggestFor: [2],
        targetPeak: 0.92,
        drums: [
            D(.kick, 40, layers: 2, rr: 6, sec: 0.95, db: 5),
            D(.snare, 41, layers: 2, rr: 6, sec: 0.95, db: 3),
            D(.rim, 36, layers: 2, rr: 6, sec: 0.7, db: 2),
            D(.clap, 37, layers: 2, rr: 6, sec: 0.7, db: 2),
            D(.hatClosed, 38, layers: 2, rr: 6, sec: 0.65, db: 1),
            D(.hatPedal, 39, layers: 2, rr: 6, sec: 0.65),
            D(.hatOpen, 40, layers: 2, rr: 4, sec: 0.9, db: -2),
            D(.tomHigh, 39, layers: 2, rr: 4, sec: 0.7, db: 1),
            D(.tomMid, 38, layers: 2, rr: 4, sec: 0.75, db: 2),
            D(.tomLow, 36, layers: 2, rr: 4, sec: 0.8, db: 3),
            D(.crash, 41, layers: 2, rr: 4, sec: 1.0, db: 6),
            D(.ride, 37, layers: 2, rr: 4, sec: 0.75, db: 1),
            D(.shaker, 38, layers: 2, rr: 4, sec: 0.55, db: -1),
            D(.tambourine, 39, layers: 2, rr: 4, sec: 0.55),
        ])

    /// Hands-only: snaps, pinky snaps, finger/hand claps, cheek taps — dry and clicky.
    static let bodyHands = KitRecipe(
        id: "pedalbeat.body-hands", name: "Body Hands", category: "percussion",
        author: "Karoryfer Samples (Body Percussion)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/body_percussion",
        notes: "Hands only: snaps, pinky snaps, finger claps, handclaps and cheek taps. Dry, intimate, pop/electro friendly.",
        dir: "body_percussion", program: "Programs/body.sfz", outRate: 44100,
        fallbackSynthKit: 2, suggestFor: [2],
        targetPeak: 0.88,
        drums: [
            D(.kick, 60, layers: 2, rr: 6, sec: 0.75, db: 4),
            D(.snare, 61, layers: 2, rr: 6, sec: 0.85, db: 3),
            D(.rim, 56, layers: 1, rr: 6, sec: 0.5, db: 4),
            D(.clap, 60, layers: 2, rr: 6, sec: 0.7, db: 1),
            D(.hatClosed, 58, layers: 1, rr: 4, sec: 0.4, db: 3),
            D(.hatPedal, 59, layers: 1, rr: 4, sec: 0.4, db: 2),
            D(.hatOpen, 57, layers: 1, rr: 6, sec: 0.5, db: 2),
            D(.tomHigh, 52, layers: 1, rr: 4, sec: 0.5, db: 3),
            D(.tomMid, 53, layers: 1, rr: 4, sec: 0.5, db: 3),
            D(.tomLow, 54, layers: 1, rr: 4, sec: 0.5, db: 3),
            D(.crash, 61, layers: 2, rr: 4, sec: 0.9, db: 6),
            D(.ride, 55, layers: 1, rr: 4, sec: 0.5, db: 2),
            D(.shaker, 58, layers: 1, rr: 4, sec: 0.4, db: 4),
            D(.tambourine, 59, layers: 1, rr: 4, sec: 0.4, db: 3),
            D(.cowbell, 56, layers: 1, rr: 4, sec: 0.45, db: 5),
        ])

    /// Torso: belly, chest, shoulders, head — warm midrange thumps.
    static let bodyChest = KitRecipe(
        id: "pedalbeat.body-chest", name: "Body Chest", category: "percussion",
        author: "Karoryfer Samples (Body Percussion)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/body_percussion",
        notes: "Torso mapping: belly, chest thumps, shoulders and head. Warm, mid-heavy, tribal / lo-fi.",
        dir: "body_percussion", program: "Programs/body.sfz", outRate: 44100,
        fallbackSynthKit: 3, suggestFor: [3],
        targetPeak: 0.9,
        drums: [
            D(.kick, 46, layers: 2, rr: 4, sec: 0.9, db: 5),
            D(.snare, 44, layers: 2, rr: 4, sec: 0.85, db: 3),
            D(.rim, 49, layers: 2, rr: 4, sec: 0.7, db: 2),
            D(.clap, 45, layers: 2, rr: 4, sec: 0.8, db: 2),
            D(.hatClosed, 47, layers: 2, rr: 4, sec: 0.65, db: 1),
            D(.hatPedal, 48, layers: 2, rr: 4, sec: 0.65),
            D(.hatOpen, 50, layers: 2, rr: 4, sec: 0.75, db: 1),
            D(.tomHigh, 48, layers: 2, rr: 4, sec: 0.8, db: 2),
            D(.tomMid, 42, layers: 2, rr: 6, sec: 0.85, db: 2),
            D(.tomLow, 43, layers: 2, rr: 6, sec: 0.9, db: 3),
            D(.crash, 51, layers: 2, rr: 6, sec: 1.0, db: 6),
            D(.ride, 47, layers: 2, rr: 4, sec: 0.75, db: 1),
            D(.shaker, 49, layers: 2, rr: 4, sec: 0.55, db: 2),
            D(.tambourine, 50, layers: 2, rr: 4, sec: 0.55, db: 2),
        ])

    /// Hard L/R split for wide stereo grooves.
    static let bodyStereo = KitRecipe(
        id: "pedalbeat.body-stereo", name: "Body Stereo", category: "percussion",
        author: "Karoryfer Samples (Body Percussion)",
        license: "CC0-1.0", source: "https://github.com/sfzinstruments/body_percussion",
        notes: "Left/right body hits hard-panned for a wide stereo image.",
        dir: "body_percussion", program: "Programs/body.sfz", outRate: 44100,
        fallbackSynthKit: 2, suggestFor: [2],
        targetPeak: 0.9,
        drums: [
            D(.kick, 40, layers: 2, rr: 6, sec: 0.9, db: 4, pan: -0.65),
            D(.snare, 41, layers: 2, rr: 6, sec: 0.9, db: 3, pan: 0.65),
            D(.rim, 56, layers: 1, rr: 6, sec: 0.5, db: 3, pan: -0.85),
            D(.clap, 61, layers: 2, rr: 6, sec: 0.8, db: 2, pan: 0.15),
            D(.hatClosed, 58, layers: 1, rr: 4, sec: 0.4, db: 2, pan: -0.7),
            D(.hatPedal, 38, layers: 2, rr: 6, sec: 0.6, pan: -0.4),
            D(.hatOpen, 59, layers: 1, rr: 4, sec: 0.4, db: 1, pan: 0.7),
            D(.tomHigh, 48, layers: 2, rr: 4, sec: 0.8, db: 2, pan: 0.75),
            D(.tomMid, 47, layers: 2, rr: 4, sec: 0.8, db: 2, pan: -0.75),
            D(.tomLow, 44, layers: 2, rr: 4, sec: 0.9, db: 3, pan: -0.35),
            D(.crash, 51, layers: 2, rr: 6, sec: 1.0, db: 5, pan: 0.0),
            D(.ride, 43, layers: 2, rr: 6, sec: 0.7, pan: 0.55),
            D(.shaker, 57, layers: 1, rr: 6, sec: 0.45, db: 3, pan: 0.8),
            D(.tambourine, 52, layers: 1, rr: 4, sec: 0.45, db: 2, pan: -0.8),
        ])
}
