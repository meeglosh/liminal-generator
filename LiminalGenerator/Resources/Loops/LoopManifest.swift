import Foundation

/// Metadata for one bundled lo-fi drum loop WAV in this directory.
/// See `LICENSES-LOOPS.md` for full source/license records.
struct LoopInfo {
    let fileName: String
    let bpm: Int
    let bars: Int
    let displayName: String
}

enum LoopLibrary {
    static let all: [LoopInfo] = [
        LoopInfo(fileName: "loop_70_drift.wav", bpm: 70, bars: 4, displayName: "DRIFT"),
        LoopInfo(fileName: "loop_76_midnight.wav", bpm: 76, bars: 4, displayName: "MIDNIGHT"),
        LoopInfo(fileName: "loop_76_amber.wav", bpm: 76, bars: 4, displayName: "AMBER"),
        LoopInfo(fileName: "loop_80_shadow.wav", bpm: 80, bars: 4, displayName: "SHADOW"),
        LoopInfo(fileName: "loop_85_hazy.wav", bpm: 85, bars: 4, displayName: "HAZY"),
        LoopInfo(fileName: "loop_88_funky.wav", bpm: 88, bars: 4, displayName: "FUNKY"),
        LoopInfo(fileName: "loop_90_grit.wav", bpm: 90, bars: 4, displayName: "GRIT"),
        LoopInfo(fileName: "loop_95_boombap.wav", bpm: 95, bars: 4, displayName: "BOOMBAP"),
        LoopInfo(fileName: "loop_95_dusty.wav", bpm: 95, bars: 4, displayName: "DUSTY"),
        LoopInfo(fileName: "loop_95_vinyl.wav", bpm: 95, bars: 4, displayName: "VINYL"),
    ]
}
