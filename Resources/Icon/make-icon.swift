#!/usr/bin/env swift
//
// Génère AppIcon.icns à partir du dessin, et non d'un PNG exporté à plat.
//
// Raison : la spec §4.7 demande deux traitements distincts. L'anneau avec halo fonctionne
// à 512 px ; à 16 px (favicon, barre de menus, Spotlight) le halo devient une bouillie
// grise et l'anneau se referme optiquement. Un seul fichier redimensionné ne peut pas
// faire les deux — il faut redessiner. C'est exactement ce que ce script fait.
//
//   swift make-icon.swift
//
import AppKit

// MARK: - Dessin

/// Au-dessus de ce seuil : halo, dégradé, mot-symbole. En dessous : anneau nu et épais.
let detailThreshold: CGFloat = 128

func drawIcon(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    let isDetailed = size >= detailThreshold
    // Marge du gabarit macOS : la tuile ne remplit jamais toute la toile.
    let inset = size * 0.085
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.225

    // Tuile : dégradé du gris moyen en haut vers le presque-noir en bas.
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.310, green: 0.310, blue: 0.318, alpha: 1),
        NSColor(srgbRed: 0.180, green: 0.180, blue: 0.188, alpha: 1),
        NSColor(srgbRed: 0.055, green: 0.055, blue: 0.060, alpha: 1)
    ], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
    gradient.draw(in: shape, angle: -90)

    // Assombrissement central : c'est ce qui fait ressortir l'anneau sans le surcharger.
    if isDetailed {
        context.saveGState()
        shape.addClip()
        let vignette = NSGradient(colors: [
            NSColor(white: 0, alpha: 0.62), NSColor(white: 0, alpha: 0)
        ], atLocations: [0, 0.62], colorSpace: .sRGB)!
        vignette.draw(in: tile, relativeCenterPosition: NSPoint(x: 0, y: 0.12))
        context.restoreGState()
    }

    // L'anneau. Centré verticalement quand il est seul, remonté quand le mot-symbole
    // occupe le bas — sinon l'ensemble paraît tomber.
    let ringCenter = NSPoint(x: size / 2, y: isDetailed ? size * 0.565 : size * 0.5)
    let ringRadius = isDetailed ? size * 0.235 : size * 0.30
    let lineWidth = isDetailed ? size * 0.017 : size * 0.075

    let ring = NSBezierPath(ovalIn: NSRect(x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius,
                                           width: ringRadius * 2, height: ringRadius * 2))
    ring.lineWidth = lineWidth

    if isDetailed {
        // Halo : deux passes, une large et sourde, une serrée et vive.
        context.saveGState()
        context.setShadow(offset: .zero, blur: size * 0.055,
                          color: NSColor(white: 1, alpha: 0.55).cgColor)
        NSColor(white: 1, alpha: 0.9).setStroke()
        ring.stroke()
        context.setShadow(offset: .zero, blur: size * 0.02,
                          color: NSColor(white: 1, alpha: 0.8).cgColor)
        NSColor.white.setStroke()
        ring.stroke()
        context.restoreGState()
    } else {
        // Pas de halo : à cette taille il ne produirait qu'un gris sale. Trait épaissi
        // pour compenser la perte de présence.
        NSColor.white.setStroke()
        ring.stroke()
    }

    // Mot-symbole, seulement aux grandes tailles : en dessous il devient illisible et
    // ne fait que boucher l'anneau.
    if isDetailed {
        let font = NSFont.systemFont(ofSize: size * 0.062, weight: .light)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
            .kern: size * 0.038
        ]
        let text = NSAttributedString(string: "WUJI", attributes: attributes)
        let textSize = text.size()
        // Le crénage ajoute une espace après la dernière lettre : on la retire du centrage.
        let x = (size - textSize.width + size * 0.038) / 2
        text.draw(at: NSPoint(x: x, y: size * 0.205))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Assemblage

let root = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent()
let iconset = root.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Les paires attendues par iconutil : chaque taille en 1x et en 2x.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),       ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),       ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),    ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    let data = drawIcon(size: variant.pixels)
    try data.write(to: iconset.appendingPathComponent(variant.name))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()

guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil a échoué\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("→ \(root.appendingPathComponent("AppIcon.icns").path)")
