import AppKit
import SwiftUI

struct AppIconCanvas: View {
    var body: some View {
        ZStack {
            // macOS Squircle Background with subtle ambient glow
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.11, green: 0.13, blue: 0.20),
                            Color(red: 0.07, green: 0.08, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 824, height: 824)
                .shadow(color: Color.black.opacity(0.38), radius: 28, x: 0, y: 18)
                .overlay(
                    // Soft radial highlight in top-left
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.35, green: 0.45, blue: 0.95).opacity(0.32),
                                    Color.clear
                                ],
                                center: .topLeading,
                                startRadius: 20,
                                endRadius: 560
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 4
                        )
                )

            // Back floating card (subtle glass layer)
            RoundedRectangle(cornerRadius: 88, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 440, height: 460)
                .rotationEffect(.degrees(-7))
                .offset(x: -22, y: -14)
                .overlay(
                    RoundedRectangle(cornerRadius: 88, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 2.5)
                        .rotationEffect(.degrees(-7))
                        .offset(x: -22, y: -14)
                )

            // Main Ivory Card (Calendar + Note minimal symbol)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 88, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.99, green: 0.99, blue: 1.0),
                                Color(red: 0.93, green: 0.95, blue: 0.99)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 450, height: 470)
                    .shadow(color: Color.black.opacity(0.32), radius: 26, x: 0, y: 16)

                VStack(alignment: .leading, spacing: 38) {
                    // Top pill header (Calendar accent bar)
                    HStack(spacing: 18) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.31, green: 0.38, blue: 0.96),
                                        Color(red: 0.22, green: 0.56, blue: 0.98)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 116, height: 36)

                        Spacer()

                        Circle()
                            .fill(Color(red: 0.96, green: 0.56, blue: 0.20))
                            .frame(width: 24, height: 24)
                    }

                    // Minimalist structured lines with check circles
                    VStack(alignment: .leading, spacing: 32) {
                        HStack(spacing: 22) {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.31, green: 0.38, blue: 0.96))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 23, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.14, green: 0.16, blue: 0.24))
                                .frame(width: 220, height: 26)
                        }

                        HStack(spacing: 22) {
                            ZStack {
                                Circle()
                                    .strokeBorder(Color(red: 0.31, green: 0.38, blue: 0.96).opacity(0.45), lineWidth: 5)
                                    .frame(width: 48, height: 48)
                            }
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.14, green: 0.16, blue: 0.24).opacity(0.55))
                                .frame(width: 165, height: 24)
                        }

                        HStack(spacing: 22) {
                            ZStack {
                                Circle()
                                    .strokeBorder(Color(red: 0.31, green: 0.38, blue: 0.96).opacity(0.28), lineWidth: 5)
                                    .frame(width: 48, height: 48)
                            }
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.14, green: 0.16, blue: 0.24).opacity(0.30))
                                .frame(width: 120, height: 24)
                        }
                    }
                }
                .padding(58)
                .frame(width: 450, height: 470)
            }
            .offset(x: 8, y: 10)

            // Floating AI Sparkle Badge in bottom-right
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.36, green: 0.42, blue: 0.98),
                                Color(red: 0.18, green: 0.62, blue: 0.98)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 176, height: 176)
                    .shadow(color: Color(red: 0.22, green: 0.45, blue: 0.96).opacity(0.55), radius: 22, x: 0, y: 12)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.65), lineWidth: 4)
                    )

                Image(systemName: "sparkles")
                    .font(.system(size: 78, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .offset(x: 185, y: 185)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func generateIcon(outputDir: String) throws {
    let fm = FileManager.default
    let iconsetPath = "\(outputDir)/AppIcon.iconset"
    try? fm.removeItem(atPath: iconsetPath)
    try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

    let masterRenderer = ImageRenderer(content: AppIconCanvas())
    masterRenderer.scale = 1.0
    guard let cgImage = masterRenderer.cgImage else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render master icon"])
    }

    let masterPreviewPath = "\(outputDir)/icon-preview.png"
    let masterRep = NSBitmapImageRep(cgImage: cgImage)
    if let png = masterRep.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: masterPreviewPath))
    }

    let specs: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    let sourceImage = NSImage(cgImage: cgImage, size: NSSize(width: 1024, height: 1024))

    for spec in specs {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: spec.pixels,
            pixelsHigh: spec.pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: spec.pixels, height: spec.pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(
            in: NSRect(x: 0, y: 0, width: spec.pixels, height: spec.pixels),
            from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(spec.name)"))
        }
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetPath, "-o", "\(outputDir)/AppIcon.icns"]
    try proc.run()
    proc.waitUntilExit()
    try? fm.removeItem(atPath: iconsetPath)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/Users/xiatianze/Desktop/MemoPilot/docs"
try MainActor.assumeIsolated {
    try generateIcon(outputDir: outDir)
}
print("✅ Icon generated in \(outDir)/AppIcon.icns")
