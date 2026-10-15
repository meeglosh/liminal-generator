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
    /// Raw components; text is built on demand so it follows the in-app
    /// language (month names and AM/PM are language-bound).
    var month: Int      // 0...11
    var day: Int
    var year: Int
    var hour12: Int     // 1...12
    var minute: Int
    var second: Int
    var isPM: Bool

    /// e.g. "OCT 26 1998" (month localized)
    var dateText: String {
        String(format: "%@ %02d %d", Self.monthName(month), day, year)
    }
    /// e.g. "11:42:07 PM" — 12-hour clock with AM/PM (localized), used
    /// consistently everywhere the app renders a VHS-style time.
    var timeText: String {
        Self.timeText(hour12: hour12, minute: minute, second: second, isPM: isPM)
    }

    static func timeText(hour12: Int, minute: Int, second: Int, isPM: Bool) -> String {
        String(format: "%d:%02d:%02d %@", hour12, minute, second, isPM ? tr("PM") : tr("AM"))
    }

    static func monthName(_ index: Int) -> String {
        switch index {
        case 0: return tr("JAN")
        case 1: return tr("FEB")
        case 2: return tr("MAR")
        case 3: return tr("APR")
        case 4: return tr("MAY")
        case 5: return tr("JUN")
        case 6: return tr("JUL")
        case 7: return tr("AUG")
        case 8: return tr("SEP")
        case 9: return tr("OCT")
        case 10: return tr("NOV")
        default: return tr("DEC")
        }
    }

    static func random() -> VHSTimestamp {
        let hour24 = Int.random(in: 0...23)
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        return VHSTimestamp(
            month: Int.random(in: 0...11),
            day: Int.random(in: 1...28),
            // Late-80s through the 90s, camcorder-era.
            year: Int.random(in: 1988...1999),
            hour12: hour12,
            minute: Int.random(in: 0...59),
            second: Int.random(in: 0...59),
            isPM: hour24 >= 12
        )
    }
}
