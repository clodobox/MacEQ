import AppKit
import CoreGraphics
import Foundation

// Renders the installer window backdrop: the app's own parametric view as
// wallpaper — grid, spectrum skyline, glowing response curve — plus a 3D arrow
// pointing from where the app icon sits to where the Applications alias sits.
//
// Coordinates here are CoreGraphics (origin bottom-left); Finder positions
// icons from the top-left, so scripts/make-dmg.sh mirrors the Y values.
// Regenerate with the steps in scripts/make-dmg.sh.

let width = 600.0
let height = 400.0
let scale = Double(CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1 : 1)

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(width * scale),
        height: Int(height * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else { fatalError("could not create bitmap context") }

context.scaleBy(x: scale, y: scale)
context.setAllowsAntialiasing(true)

// MARK: - Backdrop

let backdrop = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.13, green: 0.15, blue: 0.34, alpha: 1),
        CGColor(red: 0.08, green: 0.09, blue: 0.22, alpha: 1),
        CGColor(red: 0.05, green: 0.05, blue: 0.14, alpha: 1),
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
context.drawLinearGradient(
    backdrop,
    start: CGPoint(x: 0, y: height),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// The response curve rides low so it reads as a floor the icons stand on,
// rather than cutting through the icon labels.
let curveBaseline = 118.0

// MARK: - Grid

context.setLineWidth(1)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.055))
for step in 1..<8 {
    let y = height / 8 * Double(step)
    context.move(to: CGPoint(x: 0, y: y))
    context.addLine(to: CGPoint(x: width, y: y))
}
// Vertical lines at octave spacing, the way the app plots frequency.
for decade in 0..<3 {
    for multiple in 1..<10 {
        let normalized = (Double(decade) + log10(Double(multiple))) / 3.0
        let x = normalized * width
        context.move(to: CGPoint(x: x, y: 0))
        context.addLine(to: CGPoint(x: x, y: height))
    }
}
context.strokePath()

// MARK: - Spectrum skyline

// Deterministic pseudo-random heights: a fixed seed keeps the artwork stable
// across regenerations, so the backdrop doesn't churn in every diff.
var seed: UInt64 = 0x5EED_1234
func nextRandom() -> Double {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double((seed >> 33) & 0xFFFF) / Double(0xFFFF)
}

let barCount = 56
let barGap = 2.4
let barWidth = (width - barGap * Double(barCount - 1)) / Double(barCount)
for index in 0..<barCount {
    let position = Double(index) / Double(barCount - 1)
    // Loose pink-noise tilt: energetic in the bass, tapering to the top end.
    let envelope = pow(1.0 - position, 0.7) * 0.72 + 0.16
    let barHeight = (envelope * 0.62 + nextRandom() * 0.38 * envelope) * curveBaseline * 1.25
    let x = Double(index) * (barWidth + barGap)
    let bar = CGPath(
        roundedRect: CGRect(x: x, y: 0, width: barWidth, height: max(barHeight, 3)),
        cornerWidth: barWidth / 2.4,
        cornerHeight: barWidth / 2.4,
        transform: nil
    )
    context.addPath(bar)
    context.setFillColor(CGColor(red: 0.62, green: 0.74, blue: 1.0, alpha: 0.13))
    context.fillPath()
}

// MARK: - Response curve

// Gaussian bumps stand in for peaking filters: bass lift, mid scoop, presence
// lift, gentle air rolloff — the shape of a plausible tuning.
let bumps: [(center: Double, amplitude: Double, spread: Double)] = [
    (70, 46, 78),
    (215, -28, 62),
    (368, 40, 74),
    (520, -16, 88),
]

func curveY(_ x: Double) -> Double {
    var y = curveBaseline
    for bump in bumps {
        let offset = (x - bump.center) / bump.spread
        y += bump.amplitude * exp(-offset * offset)
    }
    return y
}

let curve = CGMutablePath()
curve.move(to: CGPoint(x: 0, y: curveY(0)))
for step in stride(from: 0.0, through: width, by: 2.0) {
    curve.addLine(to: CGPoint(x: step, y: curveY(step)))
}

// Translucent fill under the curve.
let filled = CGMutablePath()
filled.addPath(curve)
filled.addLine(to: CGPoint(x: width, y: 0))
filled.addLine(to: CGPoint(x: 0, y: 0))
filled.closeSubpath()

context.saveGState()
context.addPath(filled)
context.clip()
let curveFill = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.36, green: 0.62, blue: 1.0, alpha: 0.34),
        CGColor(red: 0.36, green: 0.62, blue: 1.0, alpha: 0.02),
    ] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    curveFill,
    start: CGPoint(x: 0, y: curveBaseline + 60),
    end: CGPoint(x: 0, y: 0),
    options: []
)
context.restoreGState()

// The curve itself, with a bloom underneath.
context.saveGState()
context.setShadow(
    offset: .zero,
    blur: 16,
    color: CGColor(red: 0.42, green: 0.68, blue: 1.0, alpha: 0.85)
)
context.setLineWidth(3)
context.setLineJoin(.round)
context.setStrokeColor(CGColor(red: 0.62, green: 0.82, blue: 1.0, alpha: 0.95))
context.addPath(curve)
context.strokePath()
context.restoreGState()

// MARK: - Label plates

// Finder draws the icon labels itself, in the viewer's system text colour:
// black in light mode, white in dark mode, and a disk image cannot override it.
// So neither a dark nor a light backdrop is legible both ways. These mid-tone
// plates sit behind the labels and keep either colour above ~4.2:1 contrast.
//
// Their Y is pinned to where Finder lays labels out for a 128pt icon centred at
// Finder y=200 with 12pt text — the values make-dmg.sh sets. Change either and
// these must move with it.
// Measured against a real render: Finder's text sits ~4pt above the geometric
// midpoint of where a naive plate would go, so the plate is nudged up to match.
let labelPlateY = 118.0
let labelTextSize = 12.0      // must match "set text size of options" in make-dmg.sh
let labelPlatePadding = 9.0
let labelPlateHeight = 22.0

// Measured in the same font and size Finder renders the label with, so each
// plate hugs its own text instead of being eyeballed to a fixed width.
func labelWidth(_ text: String) -> Double {
    let attributed = NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: labelTextSize)]
    )
    return Double(attributed.size().width)
}

let labelPlates: [(centerX: Double, text: String)] = [
    (150, "MacEQ"),
    (450, "Applications"),
]
for plate in labelPlates {
    let plateWidth = labelWidth(plate.text) + labelPlatePadding * 2
    let rect = CGRect(
        x: plate.centerX - plateWidth / 2,
        y: labelPlateY - labelPlateHeight / 2,
        width: plateWidth,
        height: labelPlateHeight
    )
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: labelPlateHeight / 2,
        cornerHeight: labelPlateHeight / 2,
        transform: nil
    )
    context.addPath(path)
    context.setFillColor(CGColor(red: 0.46, green: 0.49, blue: 0.61, alpha: 0.92))
    context.fillPath()
    context.addPath(path)
    context.setLineWidth(1)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    context.strokePath()
}

// MARK: - Arrow

// A plain straight arrow: shaft, barbs, tip. Seven points, no curves, nothing
// derived from a tangent — so the outline is a fixed polygon that cannot fold
// through itself however these numbers are tuned.
//
// Icons sit centred at x=150 and x=450, each ~128pt with roughly 51pt of
// half-width to the visible glyph, leaving a gap from about x=201 to x=399.
// The arrow is centred in that gap and level with the icon centres at y=200.

let arrowCenterY = 200.0            // matches the icons' centre line
let arrowTailX = 224.0
let arrowHeadBaseX = 330.0          // where the shaft stops and the barbs start
let arrowTipX = 376.0
let arrowShaftHalfHeight = 14.0     // shaft thickness
let arrowBarbHalfHeight = 30.0      // how far the barbs flare past the shaft

let arrow = CGMutablePath()
arrow.addLines(between: [
    CGPoint(x: arrowTailX, y: arrowCenterY + arrowShaftHalfHeight),
    CGPoint(x: arrowHeadBaseX, y: arrowCenterY + arrowShaftHalfHeight),
    CGPoint(x: arrowHeadBaseX, y: arrowCenterY + arrowBarbHalfHeight),
    CGPoint(x: arrowTipX, y: arrowCenterY),
    CGPoint(x: arrowHeadBaseX, y: arrowCenterY - arrowBarbHalfHeight),
    CGPoint(x: arrowHeadBaseX, y: arrowCenterY - arrowShaftHalfHeight),
    CGPoint(x: arrowTailX, y: arrowCenterY - arrowShaftHalfHeight),
])
arrow.closeSubpath()

let arrowBounds = arrow.boundingBox

// Cast shadow: sells the arrow as sitting above the backdrop.
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -7),
    blur: 16,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
)
context.addPath(arrow)
context.setFillColor(CGColor(red: 0.20, green: 0.40, blue: 0.92, alpha: 1))
context.fillPath()
context.restoreGState()

// Body: lit from above, so bright at the top edge and deep at the bottom.
context.saveGState()
context.addPath(arrow)
context.clip()
let arrowBody = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.72, green: 0.88, blue: 1.00, alpha: 1),
        CGColor(red: 0.38, green: 0.63, blue: 0.99, alpha: 1),
        CGColor(red: 0.16, green: 0.35, blue: 0.88, alpha: 1),
        CGColor(red: 0.10, green: 0.22, blue: 0.66, alpha: 1),
    ] as CFArray,
    locations: [0.0, 0.42, 0.78, 1.0]
)!
context.drawLinearGradient(
    arrowBody,
    start: CGPoint(x: 0, y: arrowBounds.maxY),
    end: CGPoint(x: 0, y: arrowBounds.minY),
    options: []
)

// Specular band across the upper half.
let gloss = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.06),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
context.drawLinearGradient(
    gloss,
    start: CGPoint(x: 0, y: arrowBounds.maxY),
    end: CGPoint(x: 0, y: arrowBounds.midY),
    options: []
)
context.restoreGState()

// Rim light along the very top edge.
context.saveGState()
context.addPath(arrow)
context.setLineWidth(2.2)
context.setLineJoin(.round)
context.setLineCap(.round)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
context.strokePath()
context.restoreGState()

// MARK: - Text

let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerY: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.5)
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha),
        .paragraphStyle: style,
        .shadow: shadow,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let bounds = attributed.size()
    attributed.draw(
        with: CGRect(x: 0, y: centerY - bounds.height / 2, width: width, height: bounds.height),
        options: [.usesLineFragmentOrigin]
    )
}

draw("MacEQ", size: 32, weight: .semibold, alpha: 1.0, centerY: 348)
draw("Drag MacEQ into your Applications folder", size: 14, weight: .medium, alpha: 0.72, centerY: 312)

NSGraphicsContext.restoreGraphicsState()

guard let image = context.makeImage() else { fatalError("could not render image") }
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not encode png")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1]) at \(Int(scale))x")
