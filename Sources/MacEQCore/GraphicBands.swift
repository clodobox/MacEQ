import Foundation

/// The classic 10-band octave layout (ISO 266 centers, rounded).
public let defaultGraphicBandFrequencies: [Double] = [
    31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
]

/// Audible-range bounds for user-added bands.
public let graphicBandFrequencyRange: ClosedRange<Double> = 20...20000

/// UI-driven cap: below 1 the mode is meaningless, above 16 the popover
/// sliders become too narrow to grab.
public let graphicBandCountRange: ClosedRange<Int> = 1...16

/// Two bands closer than this ratio are near-duplicates: their peaking filters
/// overlap so heavily that separate sliders stop meaning anything.
private let minimumBandSpacingRatio = 1.05

public enum GraphicBandError: Error, CustomStringConvertible, Equatable {
    case frequencyOutOfRange(Double)
    case tooCloseToExistingBand(new: Double, existing: Double)
    case tooManyBands(limit: Int)
    case cannotRemoveLastBand
    case indexOutOfBounds(index: Int, count: Int)

    public var description: String {
        switch self {
        case .frequencyOutOfRange(let frequency):
            return String(
                format: "%.0f Hz is outside the supported range %.0f–%.0f Hz",
                frequency, graphicBandFrequencyRange.lowerBound, graphicBandFrequencyRange.upperBound
            )
        case .tooCloseToExistingBand(let new, let existing):
            return String(format: "%.0f Hz is too close to the existing %.0f Hz band", new, existing)
        case .tooManyBands(let limit):
            return "the graphic EQ supports at most \(limit) bands"
        case .cannotRemoveLastBand:
            return "the graphic EQ needs at least one band"
        case .indexOutOfBounds(let index, let count):
            return "band index \(index) is out of bounds for \(count) bands"
        }
    }
}

/// Display label matching the classic layout: "31", "500", "1k", "2.5k".
/// Sub-kilohertz frequencies truncate (31.5 -> "31", like hardware EQ fascias);
/// kilohertz values show one decimal only when it is meaningful.
public func graphicBandLabel(frequency: Double) -> String {
    if frequency < 1000 {
        return String(Int(frequency))
    }
    let kilohertz = frequency / 1000
    if kilohertz == kilohertz.rounded() {
        return "\(Int(kilohertz))k"
    }
    return String(format: "%.1fk", kilohertz)
}

/// Inserts a frequency into a sorted band list, keeping it sorted.
/// Returns the new list and the insertion index (for aligning a gains array).
public func insertGraphicBand(
    frequency: Double, into frequencies: [Double]
) throws -> (frequencies: [Double], index: Int) {
    guard graphicBandFrequencyRange.contains(frequency) else {
        throw GraphicBandError.frequencyOutOfRange(frequency)
    }
    guard frequencies.count < graphicBandCountRange.upperBound else {
        throw GraphicBandError.tooManyBands(limit: graphicBandCountRange.upperBound)
    }
    for existing in frequencies {
        let ratio = max(frequency, existing) / min(frequency, existing)
        if ratio < minimumBandSpacingRatio {
            throw GraphicBandError.tooCloseToExistingBand(new: frequency, existing: existing)
        }
    }
    let index = frequencies.firstIndex { $0 > frequency } ?? frequencies.count
    var result = frequencies
    result.insert(frequency, at: index)
    return (result, index)
}

/// Changes one band's frequency, re-sorting if it moved past a neighbour.
/// Returns the new list and the edited band's new index, so callers can move
/// its gain with it. Setting a band to the value it already has is a no-op
/// (it must not collide with itself).
public func updateGraphicBand(
    at index: Int, to frequency: Double, in frequencies: [Double]
) throws -> (frequencies: [Double], index: Int) {
    guard frequencies.indices.contains(index) else {
        throw GraphicBandError.indexOutOfBounds(index: index, count: frequencies.count)
    }
    guard graphicBandFrequencyRange.contains(frequency) else {
        throw GraphicBandError.frequencyOutOfRange(frequency)
    }
    if frequencies[index] == frequency {
        return (frequencies, index)
    }
    for (other, existing) in frequencies.enumerated() where other != index {
        let ratio = max(frequency, existing) / min(frequency, existing)
        if ratio < minimumBandSpacingRatio {
            throw GraphicBandError.tooCloseToExistingBand(new: frequency, existing: existing)
        }
    }
    var result = frequencies
    result.remove(at: index)
    let newIndex = result.firstIndex { $0 > frequency } ?? result.count
    result.insert(frequency, at: newIndex)
    return (result, newIndex)
}

/// Removes the band at `index`, refusing to empty the list.
public func removeGraphicBand(at index: Int, from frequencies: [Double]) throws -> [Double] {
    guard frequencies.indices.contains(index) else {
        throw GraphicBandError.indexOutOfBounds(index: index, count: frequencies.count)
    }
    guard frequencies.count > graphicBandCountRange.lowerBound else {
        throw GraphicBandError.cannotRemoveLastBand
    }
    var result = frequencies
    result.remove(at: index)
    return result
}
