#!/usr/bin/env swift
//
// Draws the Sill app icon and writes both asset catalogs.
//
//   swift scripts/make-app-icon.swift        (or: make icons)
//
// The mark is a single horizontal bar — the "sill" — placed on a 64 pt module
// (1024 ÷ 16). Every edge is a whole multiple of 64 vertically, so at 128 / 64 /
// 32 / 16 pt the bar lands on 8 / 4 / 2 / 1 whole pixels instead of smearing
// across a half row.
//
//   bar width   576 px   9 M
//   bar height   64 px   1 M   (top 576, bottom 640)
//   centre Y    608 px   1.5 M below the canvas centre
//   end radius   16 px   1/4 M
//
// iOS icons are full-bleed opaque squares — the system applies the mask.
// macOS icons carry the 824/1024 squircle themselves but cast no shadow of
// their own — the bar keeps its contact shadow inside the canvas. On Tahoe
// the canvas shape is a mask and the system supplies the material and the
// contact shadow under the silhouette ("avoid baking in drop shadows", WWDC25
// "Say hello to the new look of app icons"). Deployment target is macOS 26.0,
// so there is no older system left to draw that shadow for.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

let canvas: CGFloat = 1024
let module: CGFloat = 64

let barWidth = 9 * module  // 576
let barHeight = 1 * module  // 64
let barCentreY = 9.5 * module  // 608, measured from the top
let barRadius = module / 4  // 16

/// macOS content occupies 824 of the 1024 canvas.
let macInset: CGFloat = 100
let macScale = (canvas - 2 * macInset) / canvas

// MARK: - Colour

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: alpha)
}

struct Palette {
  let groundTop: CGColor
  let groundBottom: CGColor
  /// Top / near-top / bottom of the bar. The near-top stop at 1/16 is the only
  /// hint of thickness — a lit top face, not a 3D object.
  let barStops: [CGColor]
  let shadow: CGColor
  let shadowBlur: CGFloat

  static let light = Palette(
    groundTop: rgb(0xF8_F7F4), groundBottom: rgb(0xF0_EFEA),
    barStops: [rgb(0x4B_4B51), rgb(0x40_4046), rgb(0x32_3237)],
    shadow: rgb(0x2C_2C2E, 0.10), shadowBlur: 16)

  static let dark = Palette(
    groundTop: rgb(0x23_2326), groundBottom: rgb(0x17_1719),
    barStops: [rgb(0xFC_FCFE), rgb(0xED_EDF2), rgb(0xD9_D9E0)],
    shadow: rgb(0x00_0000, 0.34), shadowBlur: 20)

  /// Tinted icons are read as a luminance map, so this one is flat greyscale.
  static let tinted = Palette(
    groundTop: rgb(0x00_0000), groundBottom: rgb(0x00_0000),
    barStops: [rgb(0xFF_FFFF), rgb(0xFF_FFFF), rgb(0xFF_FFFF)],
    shadow: rgb(0x00_0000, 0), shadowBlur: 0)
}

// MARK: - The mask

/// macOS icon corner radius on the 824 content square.
let cornerRatio: CGFloat = 0.2237

/// The system's own continuous corner, rasterised by CoreAnimation rather than
/// approximated: a degree-5 superellipse is off by 242 px at 1024 (it bows the
/// straight edges away and clips the corner), so the real mask is worth the
/// extra render.
func shapeLayer(_ pixels: Int) -> CALayer {
  let layer = CALayer()
  layer.frame = CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
  layer.backgroundColor = CGColor(gray: 1, alpha: 1)
  layer.cornerRadius = CGFloat(pixels) * cornerRatio
  layer.cornerCurve = .continuous
  return layer
}

/// The same shape in DeviceGray, for `CGContext.clip(to:mask:)`.
func shapeMask(_ pixels: Int) -> CGImage {
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  shapeLayer(pixels).render(in: ctx)
  return ctx.makeImage()!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
  CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: colors as CFArray,
    locations: locations)!
}

// MARK: - Drawing

/// Draws ground + bar full-bleed into the 1024 canvas. CoreGraphics is
/// bottom-up, so the spec's top-down Y values are flipped here and nowhere else.
/// Shaping is the caller's job — iOS wants the full square, macOS clips.
///
/// `devicePixel` is the width of one output pixel in canvas units. The 64 px
/// module divides 1024 evenly, but macOS then insets the artwork by 824/1024,
/// so a Dock icon lands the bar on 0.8 of a pixel at 16 pt and it washes out to
/// mid grey. Snapping the bar to whole output rows keeps it a solid line.
func drawIcon(_ ctx: CGContext, _ p: Palette, devicePixel: CGFloat? = nil) {
  ctx.saveGState()
  ctx.clip(to: CGRect(x: 0, y: 0, width: canvas, height: canvas))

  ctx.drawLinearGradient(
    gradient([p.groundTop, p.groundBottom], [0, 1]),
    start: CGPoint(x: 0, y: canvas), end: .zero, options: [])

  var barY = canvas - (barCentreY + barHeight / 2)
  var barH = barHeight
  if let unit = devicePixel, unit > 1 {
    barY = (barY / unit).rounded() * unit
    barH = max(1, (barH / unit).rounded()) * unit
  }
  let bar = CGRect(x: (canvas - barWidth) / 2, y: barY, width: barWidth, height: barH)
  let barPath = CGPath(
    roundedRect: bar, cornerWidth: barRadius, cornerHeight: barRadius, transform: nil)

  // A gradient fill casts no shadow, so lay the shape down twice: once solid to
  // throw the shadow, once with the gradient to cover it.
  if p.shadowBlur > 0 {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -module / 4), blur: p.shadowBlur, color: p.shadow)
    ctx.addPath(barPath)
    ctx.setFillColor(p.barStops[1])
    ctx.fillPath()
    ctx.restoreGState()
  }

  ctx.saveGState()
  ctx.addPath(barPath)
  ctx.clip()
  ctx.drawLinearGradient(
    gradient(p.barStops, [0, 1.0 / 16.0, 1]),
    start: CGPoint(x: 0, y: bar.maxY), end: CGPoint(x: 0, y: bar.minY), options: [])
  ctx.restoreGState()

  ctx.restoreGState()
}

enum Platform {
  /// Full-bleed opaque square; the system masks it.
  case iOS
  /// 824/1024 squircle on a transparent canvas; Tahoe adds material and shadow.
  case macOS
}

func render(_ p: Palette, _ platform: Platform, pixels: Int) -> CGImage {
  let opaque = platform == .iOS
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
  ctx.interpolationQuality = .high
  ctx.setShouldAntialias(true)

  switch platform {
  case .iOS:
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(ctx, p)

  case .macOS:
    // Round the margin rather than the content size: rounding the content first
    // yields an odd pixel count at 16 and 128 pt, which leaves the squircle a
    // pixel off-centre. Deriving the size from a whole margin keeps it centred
    // at every size, at the cost of a few tenths of a percent on the inset.
    let side = CGFloat(pixels)
    let margin = ((side - side * macScale) / 2).rounded()
    let contentPx = max(1, Int(side - 2 * margin))
    let frame = CGRect(x: margin, y: margin, width: CGFloat(contentPx), height: CGFloat(contentPx))

    ctx.saveGState()
    ctx.clip(to: frame, mask: shapeMask(contentPx))
    ctx.translateBy(x: frame.minX, y: frame.minY)
    ctx.scaleBy(x: frame.width / canvas, y: frame.height / canvas)
    drawIcon(ctx, p, devicePixel: canvas / CGFloat(contentPx))
    ctx.restoreGState()
  }

  return ctx.makeImage()!
}

// MARK: - Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// Paths below are relative to the repo root. Run from anywhere else and the
// script would quietly build a second asset tree there and still print "done".
for dir in ["Apps/iOS", "Apps/Mac"] {
  guard FileManager.default.fileExists(atPath: root.appendingPathComponent(dir).path) else {
    FileHandle.standardError.write(
      Data("run this from the repository root: \(dir) not found in the working directory\n".utf8))
    exit(1)
  }
}

func write(_ image: CGImage, to url: URL) {
  try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  guard
    let dest = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("cannot write \(url.path)") }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { fatalError("cannot finalize \(url.path)") }
  print("  \(url.lastPathComponent)  \(image.width)×\(image.height)")
}

func writeJSON(_ object: Any, to url: URL) {
  let data = try! JSONSerialization.data(
    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  try! (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
}

let catalogInfo: [String: Any] = ["info": ["author": "xcode", "version": 1]]

// iOS — one 1024 square per appearance.
let iosSet = root.appendingPathComponent("Apps/iOS/Assets.xcassets/AppIcon.appiconset")
print("iOS:")
var iosImages: [[String: Any]] = []
for (name, palette, appearance) in [
  ("icon-1024", Palette.light, String?.none),
  ("icon-1024-dark", Palette.dark, "dark"),
  ("icon-1024-tinted", Palette.tinted, "tinted"),
] {
  write(render(palette, .iOS, pixels: 1024), to: iosSet.appendingPathComponent("\(name).png"))
  var entry: [String: Any] = [
    "filename": "\(name).png", "idiom": "universal", "platform": "ios", "size": "1024x1024",
  ]
  if let appearance {
    entry["appearances"] = [["appearance": "luminosity", "value": appearance]]
  }
  iosImages.append(entry)
}
writeJSON(
  ["images": iosImages, "info": ["author": "xcode", "version": 1]],
  to: iosSet.appendingPathComponent("Contents.json"))
writeJSON(
  catalogInfo, to: root.appendingPathComponent("Apps/iOS/Assets.xcassets/Contents.json"))

// macOS — the classic 16…512 ladder at 1x and 2x.
let macSet = root.appendingPathComponent("Apps/Mac/Assets.xcassets/AppIcon.appiconset")
print("macOS:")
var macImages: [[String: Any]] = []
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    // Underscore rather than Apple's usual at-sign before the scale suffix.
    // Contents.json carries the real scale either way, so the name is free.
    let name = "icon_\(points)x\(points)\(scale == 1 ? "" : "_2x").png"
    write(render(.light, .macOS, pixels: points * scale), to: macSet.appendingPathComponent(name))
    macImages.append([
      "filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)",
    ])
  }
}
writeJSON(
  ["images": macImages, "info": ["author": "xcode", "version": 1]],
  to: macSet.appendingPathComponent("Contents.json"))
writeJSON(
  catalogInfo, to: root.appendingPathComponent("Apps/Mac/Assets.xcassets/Contents.json"))

print("done")
