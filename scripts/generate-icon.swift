import AppKit
import CoreGraphics
import Foundation

// Renders the MacEQ app icon: a macOS-style squircle with a blue->indigo
// gradient and four EQ sliders set to varying positions.
//
// The .icns in Resources/ is generated, not hand-drawn — edit this file to
// change the icon, then regenerate:
//
//   swiftc -O scripts/generate-icon.swift -o /tmp/icongen
//   /tmp/icongen /tmp/icon-1024.png
//   mkdir -p /tmp/AppIcon.iconset
//   for s in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
//            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
//            "512 512x512" "1024 512x512@2x"; do
//       sips -z ${s%% *} ${s%% *} /tmp/icon-1024.png \
//           --out "/tmp/AppIcon.iconset/icon_${s#* }.png"
//   done
//   iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns

let canvas = 1024.0
let inset = 100.0           // Apple's grid: 824pt of art inside a 1024pt canvas
let artSize = canvas - inset * 2
let cornerRadius = 185.0

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(canvas),
        height: Int(canvas),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else { fatalError("could not create bitmap context") }

let artRect = CGRect(x: inset, y: inset, width: artSize, height: artSize)
let squircle = CGPath(
    roundedRect: artRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

// Drop shadow, so the icon sits on the Dock/Finder background like a real one.
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -12),
    blur: 32,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28)
)
context.addPath(squircle)
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fillPath()
context.restoreGState()

// Background gradient: vivid blue at the top falling to deep indigo.
context.saveGState()
context.addPath(squircle)
context.clip()
let backdrop = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.29, green: 0.56, blue: 0.99, alpha: 1),
        CGColor(red: 0.20, green: 0.33, blue: 0.88, alpha: 1),
        CGColor(red: 0.24, green: 0.16, blue: 0.55, alpha: 1),
    ] as CFArray,
    locations: [0.0, 0.5, 1.0]
)!
context.drawLinearGradient(
    backdrop,
    start: CGPoint(x: 0, y: canvas - inset),
    end: CGPoint(x: 0, y: inset),
    options: []
)

// Soft top-edge sheen for depth.
let sheen = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    sheen,
    start: CGPoint(x: 0, y: canvas - inset),
    end: CGPoint(x: 0, y: canvas - inset - artSize * 0.42),
    options: []
)
context.restoreGState()

// Four sliders. Knob heights rise then fall — reads as an EQ curve, not a meter.
let trackCount = 4
let trackWidth = 44.0
let knobHeight = 78.0
let knobWidth = 108.0
let trackTop = inset + artSize * 0.80
let trackBottom = inset + artSize * 0.20
let trackHeight = trackTop - trackBottom
let knobPositions = [0.30, 0.62, 0.46, 0.78]   // fraction from the bottom

let spacing = artSize / Double(trackCount + 1)
for index in 0..<trackCount {
    let centerX = inset + spacing * Double(index + 1)

    // Track: translucent white channel.
    let track = CGPath(
        roundedRect: CGRect(
            x: centerX - trackWidth / 2,
            y: trackBottom,
            width: trackWidth,
            height: trackHeight
        ),
        cornerWidth: trackWidth / 2,
        cornerHeight: trackWidth / 2,
        transform: nil
    )
    context.addPath(track)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.26))
    context.fillPath()

    // Filled portion below the knob, so each slider reads as "set to a value".
    let knobCenterY = trackBottom + trackHeight * knobPositions[index]
    let fill = CGPath(
        roundedRect: CGRect(
            x: centerX - trackWidth / 2,
            y: trackBottom,
            width: trackWidth,
            height: knobCenterY - trackBottom
        ),
        cornerWidth: trackWidth / 2,
        cornerHeight: trackWidth / 2,
        transform: nil
    )
    context.addPath(fill)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.52))
    context.fillPath()

    // Knob, with its own shadow to lift it off the track.
    let knobRect = CGRect(
        x: centerX - knobWidth / 2,
        y: knobCenterY - knobHeight / 2,
        width: knobWidth,
        height: knobHeight
    )
    let knob = CGPath(
        roundedRect: knobRect,
        cornerWidth: 26,
        cornerHeight: 26,
        transform: nil
    )
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -6),
        blur: 18,
        color: CGColor(red: 0.05, green: 0.05, blue: 0.2, alpha: 0.5)
    )
    context.addPath(knob)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()
}

guard let image = context.makeImage() else { fatalError("could not render image") }
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not encode png")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try data.write(to: output)
print("wrote \(output.path)")
