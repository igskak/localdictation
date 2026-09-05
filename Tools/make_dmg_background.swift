#!/usr/bin/env swift
//
// Draws the background of the disk image window: an arrow from where the app
// icon sits to where the Applications folder sits, and the one sentence that
// says what to do with it.
//
//   ./Tools/make_dmg_background.swift <destination.png>
//
// The window is 640x400 points and the icons are placed by
// `Tools/release.sh`; the constants below have to agree with the ones there,
// which is why both files name them rather than either guessing.
//
// It is drawn at twice the size and then told it is 640x400, which is what
// records 144 dpi in the PNG. Finder maps a background image point-for-point,
// so a 640-pixel one is soft on every display Apple has sold for a decade.
//
// German first and English under it, because the site is German-first and the
// app is English -- and both folder names appear, since a buyer on a German
// system is shown "Programme" where this file cannot know which they will see.
//
import AppKit

let width: CGFloat = 640
let height: CGFloat = 400
let scale: CGFloat = 2

let appIconCentre = CGPoint(x: 170, y: 170)   // from the top left, as Finder counts
let applicationsCentre = CGPoint(x: 470, y: 170)

let ground = NSColor(calibratedRed: 0.961, green: 0.957, blue: 0.941, alpha: 1)   // #f5f4f0
let ink = NSColor(calibratedRed: 0.110, green: 0.114, blue: 0.102, alpha: 1)      // #1c1d1a
let quiet = NSColor(calibratedRed: 0.110, green: 0.114, blue: 0.102, alpha: 0.55)
let accent = NSColor(calibratedRed: 1.0, green: 0.408, blue: 0.275, alpha: 1)     // #ff6846, the site's one accent

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_dmg_background.swift <destination.png>\n".utf8))
    exit(1)
}
let destination = CommandLine.arguments[1]

// Finder counts from the top left and AppKit from the bottom left.
func flipped(_ y: CGFloat) -> CGFloat { height - y }

let image = NSImage(size: NSSize(width: width * scale, height: height * scale))
image.lockFocus()

guard let context = NSGraphicsContext.current else { exit(1) }
context.cgContext.scaleBy(x: scale, y: scale)
context.imageInterpolation = .high

ground.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// The arrow, from the gap after the app icon to the gap before the folder.
let iconHalf: CGFloat = 64
let start = CGPoint(x: appIconCentre.x + iconHalf + 22, y: flipped(appIconCentre.y))
let end = CGPoint(x: applicationsCentre.x - iconHalf - 22, y: flipped(applicationsCentre.y))
let headLength: CGFloat = 26
let headHalf: CGFloat = 13

let shaft = NSBezierPath()
shaft.move(to: start)
shaft.line(to: CGPoint(x: end.x - headLength + 6, y: end.y))
shaft.lineWidth = 5
shaft.lineCapStyle = .round
accent.setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: end)
head.line(to: CGPoint(x: end.x - headLength, y: end.y + headHalf))
head.line(to: CGPoint(x: end.x - headLength, y: end.y - headHalf))
head.close()
accent.setFill()
head.fill()

func draw(_ text: String, font: NSFont, colour: NSColor, centredAt y: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    string.draw(at: NSPoint(x: (width - size.width) / 2, y: flipped(y) - size.height / 2))
}

draw("Witness in den Ordner „Programme“ ziehen",
     font: .systemFont(ofSize: 19, weight: .medium), colour: ink, centredAt: 300)
draw("Drag Witness to the Applications folder",
     font: .systemFont(ofSize: 15, weight: .regular), colour: quiet, centredAt: 330)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff)
else { exit(1) }

// Saying it is 640x400 while holding twice that many pixels is what writes
// 144 dpi into the file, and 144 dpi is what makes Finder draw it sharp.
rep.size = NSSize(width: width, height: height)

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: destination))
print("  wrote \(destination) at \(Int(width * scale))x\(Int(height * scale)) px, \(Int(width))x\(Int(height)) pt")
