//
//  VHSTimestamp.swift
//  LiminalGenerator
//
//  Pinned API contract (see SPEC.md "Pinned API contract"): a random retro
//  VCR-style timestamp, regenerated whenever the VHS image card swipes to a
//  new library image.
//

import Foundation

struct VHSTimestamp {
    /// e.g. "OCT 26 1998"
    var dateText: String
    /// e.g. "11:42:07 PM" — 12-hour clock with AM/PM, used consistently
    /// everywhere the app renders a VHS-style time.
    var timeText: String

    private static let months = [
        "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
        "JUL", "AUG", "SEP", "OCT", "NOV", "DEC",
    ]

    static func random() -> VHSTimestamp {
        let month = months.randomElement()!
        let day = Int.random(in: 1...28)
        // Late-80s through the 90s, camcorder-era.
        let year = Int.random(in: 1988...1999)
        let dateText = String(format: "%@ %02d %d", month, day, year)

        let hour24 = Int.random(in: 0...23)
        let minute = Int.random(in: 0...59)
        let second = Int.random(in: 0...59)
        let period = hour24 < 12 ? "AM" : "PM"
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        let timeText = String(format: "%d:%02d:%02d %@", hour12, minute, second, period)

        return VHSTimestamp(dateText: dateText, timeText: timeText)
    }
}
