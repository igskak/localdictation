#!/usr/bin/env swift
//
// Turns a square artwork whose rounded-square shape sits on an opaque
// background into the PNG a macOS app icon is made from, and writes the
// `.iconset` beside it for `iconutil`.
//
//   ./Tools/make_appicon.swift <source.png> <destination.png> [luma-threshold]
//
// Two things it does, and both are conventions rather than taste:
//
//   1. The background becomes transparent. It is found by flooding inwards
//      from the four corners over pixels darker than the threshold, which
//      stops at the artwork's own rim rather than at a shape this script
//      guessed at -- the alternative, clipping to a synthetic squircle, leaves
//      black slivers wherever the guess and the drawing disagree by a pixel.
//   2. The shape is inset to 824 of 1024. Every icon macOS ships is drawn
//      that way, so an edge-to-edge one sits visibly larger than its
//      neighbours in Finder and in the Accessibility list -- which for this
//      app is not a gallery, it is the list the user has to find it in.
//
import AppKit

let side = 1024
let inset: CGFloat = 100

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_appicon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { die("usage: make_appicon.swift <source.png> <destination.png> [threshold]") }
let sourcePath = arguments[1]
let destinationPath = arguments[2]
let threshold = arguments.count > 3 ? (Int(arguments[3]) ?? 40) : 40

guard let image = NSImage(contentsOfFile: sourcePath),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { die("could not read \(sourcePath)") }

guard source.width == source.height else { die("the artwork must be square, got \(source.width)x\(source.height)") }

let space = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

var pixels = [UInt8](repeating: 0, count: side * side * 4)
pixels.withUnsafeMutableBytes { raw in
    guard let context = CGContext(
        data: raw.baseAddress, width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: side * 4,
        space: space, bitmapInfo: bitmapInfo
    ) else { die("could not open a bitmap for the artwork") }
    context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
}

func luminance(_ index: Int) -> Int {
    let o = index * 4
    return (Int(pixels[o]) * 299 + Int(pixels[o + 1]) * 587 + Int(pixels[o + 2]) * 114) / 1000
}

print("  corner \(luminance(0)), centre \(luminance(side * side / 2 + side / 2)), threshold \(threshold)")

// Flood inwards from every corner. A corner brighter than the threshold means
// the artwork already has its own transparency and this would do nothing, so
// say so rather than writing a file that silently changed nothing.
var cleared = 0
var stack = [0, side - 1, side * (side - 1), side * side - 1]
var seen = [Bool](repeating: false, count: side * side)

while let index = stack.popLast() {
    if seen[index] || luminance(index) > threshold { continue }
    seen[index] = true
    cleared += 1
    for channel in 0..<4 { pixels[index * 4 + channel] = 0 }

    let x = index % side, y = index / side
    if x > 0 { stack.append(index - 1) }
    if x < side - 1 { stack.append(index + 1) }
    if y > 0 { stack.append(index - side) }
    if y < side - 1 { stack.append(index + side) }
}

let percent = cleared * 100 / (side * side)
print("  cleared \(cleared) background pixels (\(percent)%)")
if percent < 2 { die("almost nothing was cleared -- raise the threshold, or the artwork is already cut out") }
if percent > 40 { die("\(percent)% was cleared, which is the artwork and not its background -- lower the threshold") }

guard let shaped = pixels.withUnsafeMutableBytes({ raw -> CGImage? in
    CGContext(
        data: raw.baseAddress, width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: side * 4,
        space: space, bitmapInfo: bitmapInfo
    )?.makeImage()
}) else { die("could not rebuild the cut-out artwork") }

guard let output = CGContext(
    data: nil, width: side, height: side,
    bitsPerComponent: 8, bytesPerRow: side * 4,
    space: space, bitmapInfo: bitmapInfo
) else { die("could not open a bitmap for the icon") }

output.interpolationQuality = .high
output.draw(shaped, in: CGRect(x: inset, y: inset, width: CGFloat(side) - 2 * inset, height: CGFloat(side) - 2 * inset))

guard let icon = output.makeImage(),
      let png = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:])
else { die("could not encode the icon") }

try! png.write(to: URL(fileURLWithPath: destinationPath))
print("  wrote \(destinationPath)")
