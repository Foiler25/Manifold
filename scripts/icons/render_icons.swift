// render_icons.swift — Manifold icon artwork renderer.
//
// Generates AppIcon and DocumentIcon master PNGs at 1024×1024 plus the
// downsamples macOS expects in a `.appiconset`. Ships into:
//   Manifold/Resources/Assets.xcassets/AppIcon.appiconset/
//   Manifold/Resources/Assets.xcassets/DocumentIcon.appiconset/
//
// Motif (per BRIEF.md "Iconography"): automotive intake manifold —
// circular plenum (hub) with N radiating runners (ports). App icon is the
// 3D-rendered cross-section in graphite + brand-accent green; document
// icon is the same motif flattened to a 2D outline on a sheet.
//
// Run: swift scripts/icons/render_icons.swift
//
// No third-party deps. CoreGraphics only.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit  // for CGColorSpace name resolution and font fallback

// MARK: - Brand palette (per BRIEF.md "Color brand")

enum Brand {
    static let accent       = CGColor(red: 0/255,   green: 214/255, blue: 122/255, alpha: 1) // #00D67A
    static let accentSoft   = CGColor(red: 0/255,   green: 214/255, blue: 122/255, alpha: 0.55)
    static let accentGlow   = CGColor(red: 102/255, green: 240/255, blue: 168/255, alpha: 1) // lighter green for highlight
    static let surfaceTop   = CGColor(red: 36/255,  green: 38/255,  blue: 42/255,  alpha: 1) // #24262a
    static let surfaceMid   = CGColor(red: 22/255,  green: 22/255,  blue: 22/255,  alpha: 1) // #161616
    static let surfaceDeep  = CGColor(red: 10/255,  green: 10/255,  blue: 10/255,  alpha: 1) // #0A0A0A
    static let metalHigh    = CGColor(red: 80/255,  green: 84/255,  blue: 90/255,  alpha: 1)
    static let metalMid     = CGColor(red: 52/255,  green: 55/255,  blue: 60/255,  alpha: 1)
    static let metalLow     = CGColor(red: 26/255,  green: 28/255,  blue: 32/255,  alpha: 1)
    static let outline      = CGColor(red: 14/255,  green: 14/255,  blue: 14/255,  alpha: 1)

    // Document icon palette (light page, dark ink)
    static let pageTop      = CGColor(red: 252/255, green: 252/255, blue: 252/255, alpha: 1)
    static let pageBot      = CGColor(red: 232/255, green: 234/255, blue: 236/255, alpha: 1)
    static let pageOutline  = CGColor(red: 200/255, green: 202/255, blue: 206/255, alpha: 1)
    static let foldShadow   = CGColor(red: 188/255, green: 192/255, blue: 196/255, alpha: 1)
    static let inkDark      = CGColor(red: 24/255,  green: 26/255,  blue: 30/255,  alpha: 1)
    static let inkSoft      = CGColor(red: 24/255,  green: 26/255,  blue: 30/255,  alpha: 0.55)
}

// MARK: - Bitmap context + PNG export

func makeContext(size: Int) -> CGContext {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("CGContext alloc failed at size \(size)")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldSmoothFonts(true)
    return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("CGImageDestination failed for \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fatalError("PNG finalize failed for \(url.path)")
    }
}

func downsample(_ master: CGImage, to size: Int) -> CGImage {
    let ctx = makeContext(size: size)
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

// MARK: - Geometry helpers

extension CGContext {
    func roundedRectPath(_ rect: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        self.addPath(path)
    }

    func gradientFill(rect: CGRect, colors: [CGColor], locations: [CGFloat], start: CGPoint, end: CGPoint) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
        self.saveGState()
        self.clip(to: [rect])
        self.drawLinearGradient(g, start: start, end: end, options: [])
        self.restoreGState()
    }

    func radialGradient(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat,
                        colors: [CGColor], locations: [CGFloat]) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
        self.drawRadialGradient(
            g,
            startCenter: center, startRadius: innerRadius,
            endCenter: center, endRadius: outerRadius,
            options: [.drawsAfterEndLocation]
        )
    }
}

// MARK: - macOS squircle tile

// macOS Big Sur+ app icons sit on a centered "squircle" (a rounded square
// with corner-radius ≈ 22.37% of the tile width) inside a 1024×1024 canvas
// with safe-area padding. Standard inset ≈ 100 px, so the tile is 824×824
// with corner radius ≈ 185.
func tileRect(canvas: CGFloat) -> CGRect {
    let inset = canvas * 0.0977 // ~100 / 1024
    return CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
}

func tileCornerRadius(tileWidth: CGFloat) -> CGFloat {
    return tileWidth * 0.2237
}

// MARK: - APP ICON: 3D manifold cross-section

func renderAppIcon(canvas: CGFloat) -> CGImage {
    let ctx = makeContext(size: Int(canvas))
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    // Transparent canvas
    ctx.clear(bounds)

    let tile = tileRect(canvas: canvas)
    let radius = tileCornerRadius(tileWidth: tile.width)
    let center = CGPoint(x: tile.midX, y: tile.midY)

    // --- Tile drop shadow (sits behind the squircle) ---
    ctx.saveGState()
    let shadowOffset = CGSize(width: 0, height: -canvas * 0.012)
    let shadowBlur = canvas * 0.035
    ctx.setShadow(offset: shadowOffset, blur: shadowBlur,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.setFillColor(Brand.surfaceMid)
    ctx.roundedRectPath(tile, radius: radius)
    ctx.fillPath()
    ctx.restoreGState()

    // --- Tile background gradient (graphite top → deep bottom) ---
    ctx.saveGState()
    ctx.roundedRectPath(tile, radius: radius)
    ctx.clip()
    ctx.gradientFill(
        rect: tile,
        colors: [Brand.surfaceTop, Brand.surfaceMid, Brand.surfaceDeep],
        locations: [0.0, 0.55, 1.0],
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.minY)
    )

    // Subtle vignette
    ctx.radialGradient(
        center: center,
        innerRadius: tile.width * 0.45,
        outerRadius: tile.width * 0.72,
        colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
        ],
        locations: [0.0, 1.0]
    )
    ctx.restoreGState()

    // --- Manifold geometry ---
    let plenumOuterR: CGFloat = tile.width * 0.205   // outer flange ring
    let plenumRingR:  CGFloat = tile.width * 0.165   // inner ring boundary
    let plenumCoreR:  CGFloat = tile.width * 0.115   // green core
    let runnerCount = 6
    let runnerLen:   CGFloat = tile.width * 0.34
    let runnerWidth: CGFloat = tile.width * 0.078
    let runnerCapR:  CGFloat = runnerWidth * 0.62
    let runnerStart: CGFloat = plenumOuterR - tile.width * 0.005

    // --- Runners (drawn first, so plenum sits on top of their inner ends) ---
    for i in 0..<runnerCount {
        // Start at top (12 o'clock) and rotate clockwise.
        let angle = (CGFloat(i) / CGFloat(runnerCount)) * (.pi * 2) - (.pi / 2)
        drawRunner(
            ctx: ctx,
            center: center,
            angle: angle,
            innerRadius: runnerStart,
            length: runnerLen,
            width: runnerWidth,
            capRadius: runnerCapR,
            tileWidth: tile.width
        )
    }

    // --- Plenum (hub) ---
    drawPlenum(
        ctx: ctx,
        center: center,
        outerRadius: plenumOuterR,
        ringRadius: plenumRingR,
        coreRadius: plenumCoreR,
        tileWidth: tile.width
    )

    // --- Top sheen highlight on the squircle (very subtle glass) ---
    ctx.saveGState()
    ctx.roundedRectPath(tile, radius: radius)
    ctx.clip()
    let sheenRect = CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height * 0.55)
    ctx.gradientFill(
        rect: sheenRect,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.06),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ],
        locations: [0.0, 1.0],
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.midY)
    )
    ctx.restoreGState()

    return ctx.makeImage()!
}

func drawRunner(ctx: CGContext, center: CGPoint, angle: CGFloat,
                innerRadius: CGFloat, length: CGFloat, width: CGFloat,
                capRadius: CGFloat, tileWidth: CGFloat) {

    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)

    // Runner is drawn along +x axis: a stadium shape (rounded ends) from x=innerRadius
    // to x=innerRadius+length, half-width = width/2.
    let outerRadius = innerRadius + length
    let halfW = width / 2

    // Body rect (the rounded-ends path)
    let body = CGRect(
        x: innerRadius - capRadius * 0.4,
        y: -halfW,
        width: (outerRadius - innerRadius) + capRadius * 0.4,
        height: width
    )
    ctx.roundedRectPath(body, radius: halfW)

    // Soft inner drop shadow under the runner
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -tileWidth * 0.005),
        blur: tileWidth * 0.012,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
    )
    ctx.setFillColor(Brand.metalMid)
    ctx.fillPath()
    ctx.restoreGState()

    // Re-add path for gradient (top-edge highlight, bottom shadow)
    ctx.roundedRectPath(body, radius: halfW)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let g = CGGradient(
        colorsSpace: space,
        colors: [Brand.metalHigh, Brand.metalMid, Brand.metalLow] as CFArray,
        locations: [0.0, 0.5, 1.0]
    )!
    ctx.drawLinearGradient(
        g,
        start: CGPoint(x: 0, y: halfW),
        end: CGPoint(x: 0, y: -halfW),
        options: []
    )

    // Subtle specular streak along the top edge of the runner
    ctx.resetClip()
    ctx.roundedRectPath(body, radius: halfW)
    ctx.clip()
    let streak = CGRect(x: body.minX, y: halfW * 0.15, width: body.width, height: halfW * 0.6)
    ctx.gradientFill(
        rect: streak,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ],
        locations: [0.0, 1.0],
        start: CGPoint(x: 0, y: halfW * 0.75),
        end: CGPoint(x: 0, y: halfW * 0.15)
    )

    // Outline (very thin, deep graphite — separates runner from background)
    ctx.resetClip()
    ctx.setStrokeColor(Brand.outline)
    ctx.setLineWidth(tileWidth * 0.0035)
    ctx.roundedRectPath(body, radius: halfW)
    ctx.strokePath()

    // --- Port mouth at the runner tip ---
    let mouthCenter = CGPoint(x: outerRadius - capRadius * 0.15, y: 0)
    let mouthOuterR = capRadius * 0.78
    let mouthInnerR = capRadius * 0.40

    // Outer ring (graphite collar)
    ctx.setFillColor(Brand.metalLow)
    ctx.addArc(center: mouthCenter, radius: mouthOuterR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    // Inner mouth (deep dark — looks like an opening)
    ctx.setFillColor(Brand.surfaceDeep)
    ctx.addArc(center: mouthCenter, radius: mouthInnerR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    // Tiny green spark at the mouth — "live data flowing through this port"
    ctx.setFillColor(Brand.accent)
    ctx.addArc(center: mouthCenter, radius: mouthInnerR * 0.42, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    ctx.restoreGState()
}

func drawPlenum(ctx: CGContext, center: CGPoint,
                outerRadius: CGFloat, ringRadius: CGFloat, coreRadius: CGFloat,
                tileWidth: CGFloat) {

    // --- Outer flange ring (metal collar) ---
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -tileWidth * 0.010),
        blur: tileWidth * 0.025,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.65)
    )
    ctx.setFillColor(Brand.metalMid)
    ctx.addArc(center: center, radius: outerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
    ctx.restoreGState()

    // Flange gradient (top-lit metal)
    ctx.saveGState()
    ctx.addArc(center: center, radius: outerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    let flangeRect = CGRect(
        x: center.x - outerRadius, y: center.y - outerRadius,
        width: outerRadius * 2, height: outerRadius * 2
    )
    ctx.gradientFill(
        rect: flangeRect,
        colors: [Brand.metalHigh, Brand.metalMid, Brand.metalLow],
        locations: [0.0, 0.55, 1.0],
        start: CGPoint(x: center.x, y: center.y + outerRadius),
        end: CGPoint(x: center.x, y: center.y - outerRadius)
    )
    ctx.restoreGState()

    // Flange outline
    ctx.setStrokeColor(Brand.outline)
    ctx.setLineWidth(tileWidth * 0.004)
    ctx.addArc(center: center, radius: outerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // --- Inner ring (recessed groove) ---
    ctx.setFillColor(Brand.surfaceDeep)
    ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    // Slight inner-shadow on the groove
    ctx.saveGState()
    ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    ctx.radialGradient(
        center: CGPoint(x: center.x, y: center.y - ringRadius * 0.15),
        innerRadius: ringRadius * 0.55,
        outerRadius: ringRadius * 1.05,
        colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        ],
        locations: [0.0, 1.0]
    )
    ctx.restoreGState()

    // --- Green core (the live-data heart) ---
    // Outer halo (soft glow)
    ctx.saveGState()
    ctx.addArc(center: center, radius: ringRadius * 0.95, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    ctx.radialGradient(
        center: center,
        innerRadius: 0,
        outerRadius: ringRadius * 0.95,
        colors: [
            CGColor(red: 0/255, green: 214/255, blue: 122/255, alpha: 0.55),
            CGColor(red: 0/255, green: 214/255, blue: 122/255, alpha: 0.0)
        ],
        locations: [0.0, 1.0]
    )
    ctx.restoreGState()

    // Solid core
    ctx.saveGState()
    ctx.addArc(center: center, radius: coreRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    ctx.radialGradient(
        center: CGPoint(x: center.x - coreRadius * 0.25, y: center.y + coreRadius * 0.25),
        innerRadius: 0,
        outerRadius: coreRadius * 1.15,
        colors: [Brand.accentGlow, Brand.accent],
        locations: [0.0, 1.0]
    )
    ctx.restoreGState()

    // Core outline
    ctx.setStrokeColor(CGColor(red: 0/255, green: 140/255, blue: 80/255, alpha: 1))
    ctx.setLineWidth(tileWidth * 0.003)
    ctx.addArc(center: center, radius: coreRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Top specular highlight on the core (a small white crescent)
    ctx.saveGState()
    ctx.addArc(center: center, radius: coreRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    let highlightCenter = CGPoint(x: center.x - coreRadius * 0.35, y: center.y + coreRadius * 0.45)
    ctx.radialGradient(
        center: highlightCenter,
        innerRadius: 0,
        outerRadius: coreRadius * 0.55,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ],
        locations: [0.0, 1.0]
    )
    ctx.restoreGState()
}

// MARK: - DOCUMENT ICON: 2D outline of the same motif on a sheet

func renderDocumentIcon(canvas: CGFloat) -> CGImage {
    let ctx = makeContext(size: Int(canvas))
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    ctx.clear(bounds)

    // Page geometry — slightly narrower than the squircle, taller-than-wide,
    // with a folded top-right corner (standard macOS document-icon shape).
    let inset = canvas * 0.13
    let pageRect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let foldSize: CGFloat = pageRect.width * 0.28
    let cornerR: CGFloat = pageRect.width * 0.06

    // --- Drop shadow under the page ---
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -canvas * 0.010),
        blur: canvas * 0.030,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30)
    )
    drawDocumentSilhouettePath(ctx: ctx, rect: pageRect, foldSize: foldSize, cornerR: cornerR)
    ctx.setFillColor(Brand.pageTop)
    ctx.fillPath()
    ctx.restoreGState()

    // --- Page fill gradient ---
    ctx.saveGState()
    drawDocumentSilhouettePath(ctx: ctx, rect: pageRect, foldSize: foldSize, cornerR: cornerR)
    ctx.clip()
    ctx.gradientFill(
        rect: pageRect,
        colors: [Brand.pageTop, Brand.pageBot],
        locations: [0.0, 1.0],
        start: CGPoint(x: pageRect.midX, y: pageRect.maxY),
        end: CGPoint(x: pageRect.midX, y: pageRect.minY)
    )
    ctx.restoreGState()

    // --- Page outline ---
    ctx.setStrokeColor(Brand.pageOutline)
    ctx.setLineWidth(canvas * 0.0035)
    drawDocumentSilhouettePath(ctx: ctx, rect: pageRect, foldSize: foldSize, cornerR: cornerR)
    ctx.strokePath()

    // --- Folded corner triangle (top-right) ---
    drawFoldTriangle(ctx: ctx, pageRect: pageRect, foldSize: foldSize, canvas: canvas)

    // --- 2D manifold motif on the sheet ---
    // Centered slightly above page-mid so the motif's bottom runner clears
    // the accent bar + "MANIFOLD" wordmark drawn near the bottom edge.
    let motifCenter = CGPoint(x: pageRect.midX, y: pageRect.midY + pageRect.height * 0.10)
    let motifScale = pageRect.width * 0.66
    drawDocumentMotif(ctx: ctx, center: motifCenter, size: motifScale)

    // --- Bottom label band (brand accent stripe + "MANIFOLD" text) ---
    drawDocumentLabel(ctx: ctx, pageRect: pageRect, canvas: canvas)

    return ctx.makeImage()!
}

func drawDocumentSilhouettePath(ctx: CGContext, rect: CGRect, foldSize: CGFloat, cornerR: CGFloat) {
    // Path: rounded-rect with a clipped top-right corner (the fold).
    let p = CGMutablePath()
    let topRightFoldStart = CGPoint(x: rect.maxX - foldSize, y: rect.maxY)
    let topRightFoldEnd   = CGPoint(x: rect.maxX,            y: rect.maxY - foldSize)

    // Start at top-left + cornerR
    p.move(to: CGPoint(x: rect.minX + cornerR, y: rect.maxY))
    // Top edge to fold start
    p.addLine(to: topRightFoldStart)
    // Diagonal across the fold
    p.addLine(to: topRightFoldEnd)
    // Right edge down to bottom-right corner
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerR))
    // Bottom-right corner
    p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
             tangent2End: CGPoint(x: rect.maxX - cornerR, y: rect.minY),
             radius: cornerR)
    // Bottom edge
    p.addLine(to: CGPoint(x: rect.minX + cornerR, y: rect.minY))
    // Bottom-left corner
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
             tangent2End: CGPoint(x: rect.minX, y: rect.minY + cornerR),
             radius: cornerR)
    // Left edge
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerR))
    // Top-left corner
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
             tangent2End: CGPoint(x: rect.minX + cornerR, y: rect.maxY),
             radius: cornerR)
    p.closeSubpath()
    ctx.addPath(p)
}

func drawFoldTriangle(ctx: CGContext, pageRect: CGRect, foldSize: CGFloat, canvas: CGFloat) {
    // Triangle path for the folded corner — fills the cut-out area.
    let p = CGMutablePath()
    p.move(to: CGPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY))
    p.addLine(to: CGPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY - foldSize))
    p.addLine(to: CGPoint(x: pageRect.maxX,            y: pageRect.maxY - foldSize))
    p.closeSubpath()

    // Fold shadow (gradient — looks like the underside of a folded corner)
    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    ctx.gradientFill(
        rect: CGRect(
            x: pageRect.maxX - foldSize,
            y: pageRect.maxY - foldSize,
            width: foldSize,
            height: foldSize
        ),
        colors: [Brand.foldShadow, Brand.pageBot],
        locations: [0.0, 1.0],
        start: CGPoint(x: pageRect.maxX, y: pageRect.maxY),
        end: CGPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY - foldSize)
    )
    ctx.restoreGState()

    // Fold edge stroke (the diagonal seam)
    ctx.setStrokeColor(Brand.pageOutline)
    ctx.setLineWidth(canvas * 0.0035)
    ctx.move(to: CGPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY))
    ctx.addLine(to: CGPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY - foldSize))
    ctx.addLine(to: CGPoint(x: pageRect.maxX,            y: pageRect.maxY - foldSize))
    ctx.strokePath()
}

func drawDocumentMotif(ctx: CGContext, center: CGPoint, size: CGFloat) {
    // 2D outline: concentric rings + 6 short radiating strokes + green center dot.
    let outerR  = size * 0.30
    let middleR = size * 0.22
    let innerR  = size * 0.14
    let coreR   = size * 0.08

    let strokeW = size * 0.028
    let runnerCount = 6
    let runnerInner = outerR + size * 0.010
    let runnerOuter = outerR + size * 0.20
    let runnerCapR  = size * 0.030

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Rings
    ctx.setStrokeColor(Brand.inkDark)
    ctx.setLineWidth(strokeW)
    ctx.addArc(center: center, radius: outerR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    ctx.setStrokeColor(Brand.inkSoft)
    ctx.setLineWidth(strokeW * 0.6)
    ctx.addArc(center: center, radius: middleR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    ctx.setStrokeColor(Brand.inkSoft)
    ctx.setLineWidth(strokeW * 0.6)
    ctx.addArc(center: center, radius: innerR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Radiating runners (outline strokes with port-cap dots)
    for i in 0..<runnerCount {
        let angle = (CGFloat(i) / CGFloat(runnerCount)) * (.pi * 2) - (.pi / 2)
        let inner = CGPoint(x: center.x + cos(angle) * runnerInner,
                            y: center.y + sin(angle) * runnerInner)
        let outer = CGPoint(x: center.x + cos(angle) * runnerOuter,
                            y: center.y + sin(angle) * runnerOuter)

        ctx.setStrokeColor(Brand.inkDark)
        ctx.setLineWidth(strokeW)
        ctx.move(to: inner)
        ctx.addLine(to: outer)
        ctx.strokePath()

        // Port-cap dot at the tip
        ctx.setFillColor(Brand.inkDark)
        ctx.addArc(center: outer, radius: runnerCapR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }

    // Green core dot
    ctx.setFillColor(Brand.accent)
    ctx.addArc(center: center, radius: coreR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
}

func drawDocumentLabel(ctx: CGContext, pageRect: CGRect, canvas: CGFloat) {
    // Small accent bar + tiny "MANIFOLD" text near the bottom of the sheet —
    // identifies the file as a Manifold export to the user without relying on
    // an extension match.
    let barH: CGFloat = canvas * 0.014
    let barW: CGFloat = pageRect.width * 0.30
    let barY: CGFloat = pageRect.minY + pageRect.height * 0.13
    let barRect = CGRect(x: pageRect.midX - barW / 2, y: barY, width: barW, height: barH)
    ctx.setFillColor(Brand.accent)
    ctx.roundedRectPath(barRect, radius: barH / 2)
    ctx.fillPath()

    // Wordmark
    let label = "MANIFOLD" as CFString
    let fontSize = canvas * 0.040
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: Brand.inkSoft,
        kCTKernAttributeName: fontSize * 0.18
    ]
    let attrString = CFAttributedStringCreate(nil, label, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attrString)
    let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let textX = pageRect.midX - textBounds.width / 2
    let textY = barY - barH * 1.2 - textBounds.height
    ctx.textPosition = CGPoint(x: textX, y: textY)
    CTLineDraw(line, ctx)
}

// MARK: - Driver

struct IconSlot {
    let nominal: Int   // e.g. 16, 32, 128
    let scale: Int     // 1 or 2
    var pixels: Int { nominal * scale }
    var filename: String {
        scale == 1
            ? "icon_\(nominal)x\(nominal).png"
            : "icon_\(nominal)x\(nominal)@2x.png"
    }
}

let macSlots: [IconSlot] = [
    .init(nominal: 16,  scale: 1),
    .init(nominal: 16,  scale: 2),
    .init(nominal: 32,  scale: 1),
    .init(nominal: 32,  scale: 2),
    .init(nominal: 128, scale: 1),
    .init(nominal: 128, scale: 2),
    .init(nominal: 256, scale: 1),
    .init(nominal: 256, scale: 2),
    .init(nominal: 512, scale: 1),
    .init(nominal: 512, scale: 2),
]

func renderSet(name: String, master: CGImage, into directory: URL, mastersDirectory: URL) {
    print("→ Writing \(name) into \(directory.path)")

    // Master lives OUTSIDE the .appiconset — actool flags any file inside
    // the set that isn't referenced in Contents.json as an "unassigned
    // child". The master is a designer reference, not an icon slot.
    try? FileManager.default.createDirectory(at: mastersDirectory, withIntermediateDirectories: true)
    let masterPath = mastersDirectory.appendingPathComponent("\(name)_1024x1024_master.png")
    writePNG(master, to: masterPath)
    print("   • master → \(masterPath.path)")

    for slot in macSlots {
        let outURL = directory.appendingPathComponent(slot.filename)
        let img: CGImage = (slot.pixels == 1024) ? master : downsample(master, to: slot.pixels)
        writePNG(img, to: outURL)
        print("   • \(slot.filename) (\(slot.pixels)px)")
    }
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetsRoot = repoRoot.appendingPathComponent("Manifold/Resources/Assets.xcassets")
let appIconDir = assetsRoot.appendingPathComponent("AppIcon.appiconset")
let docIconDir = assetsRoot.appendingPathComponent("DocumentIcon.appiconset")
let mastersDir = repoRoot.appendingPathComponent("scripts/icons/masters")

guard FileManager.default.fileExists(atPath: appIconDir.path) else {
    fatalError("AppIcon.appiconset missing at \(appIconDir.path) — run from repo root")
}
guard FileManager.default.fileExists(atPath: docIconDir.path) else {
    fatalError("DocumentIcon.appiconset missing at \(docIconDir.path) — run from repo root")
}

print("Manifold icon renderer — generating masters + downsamples")
print("==========================================================")

let appMaster = renderAppIcon(canvas: 1024)
renderSet(name: "AppIcon", master: appMaster, into: appIconDir, mastersDirectory: mastersDir)

let docMaster = renderDocumentIcon(canvas: 1024)
renderSet(name: "DocumentIcon", master: docMaster, into: docIconDir, mastersDirectory: mastersDir)

print("==========================================================")
print("Done.")
