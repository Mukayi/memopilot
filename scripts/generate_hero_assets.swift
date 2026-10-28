import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct HeroBannerFrameView: View {
    let phase: Double // 0.0 ..< 1.0
    let iconImage: NSImage?

    var body: some View {
        ZStack {
            // Deep Navy / Indigo Background Gradient (matching FlightLogHero aesthetic)
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.082, blue: 0.145),
                    Color(red: 0.085, green: 0.122, blue: 0.215),
                    Color(red: 0.065, green: 0.095, blue: 0.175)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Subtle Architectural Grid Overlay
            Canvas { context, size in
                let gridSpacing: CGFloat = 32
                var path = Path()
                for x in stride(from: 0, through: size.width, by: gridSpacing) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0, through: size.height, by: gridSpacing) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(Color.white.opacity(0.035)), lineWidth: 1)

                // Soft glowing orbital rings on the right side
                let center = CGPoint(x: size.width * 0.76, y: size.height * 0.52)
                for r in [90.0, 145.0, 205.0] {
                    let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(Color(red: 0.38, green: 0.58, blue: 0.98).opacity(0.10)),
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 5])
                    )
                }
            }

            // Ambient radial glow behind right visual cards
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.30, green: 0.52, blue: 0.98).opacity(0.22 + 0.06 * sin(phase * .pi * 2)),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 210
                    )
                )
                .frame(width: 420, height: 420)
                .offset(x: 240, y: 10)

            // Main Left + Right Content Layout
            HStack(alignment: .center, spacing: 0) {
                // LEFT SECTION: Icon + Branding + Tagline + Spec Pill
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 18) {
                        if let iconImage {
                            Image(nsImage: iconImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 78, height: 78)
                                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("AI MEMO & SCHEDULE COPILOT")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(1.6)
                                .foregroundStyle(Color(red: 0.96, green: 0.73, blue: 0.32))

                            Text("MemoPilot 闪记领航")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            Text("记录零碎想法 · 识别微信截图 · 自动归档日历与提醒")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.78))
                        }
                    }

                    // Bottom Info Pill (matching FlightLog style)
                    HStack(alignment: .center, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("备忘 / 截图")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.9))
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(red: 0.96, green: 0.73, blue: 0.32))
                            Text("日历 · 提醒 · 闹钟 · 备忘录")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.9))
                        }

                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1, height: 12)

                        Text("macOS 15+ · iCloud 同步")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.42, green: 0.82, blue: 0.95))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.07))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                            )
                    )
                }
                .padding(.leading, 38)

                Spacer()

                // RIGHT SECTION: Floating Structured Draft Cards Preview
                VStack(alignment: .leading, spacing: 10) {
                    heroPreviewCard(
                        badge: "日历",
                        badgeColor: Color(red: 0.35, green: 0.62, blue: 0.98),
                        title: "老张丨国贸三期丨年度合同洽谈",
                        meta: "10月28日 15:00 – 16:30  ·  提前 1 小时提醒",
                        highlight: phase < 0.34
                    )
                    .offset(x: -8, y: CGFloat(sin(phase * .pi * 2) * 2.0))

                    heroPreviewCard(
                        badge: "闹钟",
                        badgeColor: Color(red: 0.95, green: 0.45, blue: 0.40),
                        title: "早起闹钟：✈️ 飞往上海虹桥 MU5102",
                        meta: "10月29日 05:00 强提醒  ·  首都机场 T2",
                        highlight: phase >= 0.34 && phase < 0.67
                    )
                    .offset(x: 6, y: CGFloat(cos(phase * .pi * 2) * 2.0))

                    heroPreviewCard(
                        badge: "提醒",
                        badgeColor: Color(red: 0.95, green: 0.65, blue: 0.25),
                        title: "丰巢取件码 4-2-1028（顺丰文件）",
                        meta: "今天 19:00 准点提醒  ·  小区西门快递柜",
                        highlight: phase >= 0.67
                    )
                    .offset(x: -2, y: CGFloat(sin((phase + 0.3) * .pi * 2) * 2.0))
                }
                .padding(.trailing, 36)
            }
        }
        .frame(width: 920, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func heroPreviewCard(
        badge: String,
        badgeColor: Color,
        title: String,
        meta: String,
        highlight: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(badgeColor)

            Text(badge)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(badgeColor.opacity(0.18))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8.5)
        .frame(width: 325)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(highlight ? 0.12 : 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            highlight ? badgeColor.opacity(0.55) : Color.white.opacity(0.12),
                            lineWidth: highlight ? 1.2 : 0.8
                        )
                )
        )
    }
}

@MainActor
func generateHeroBanner(assetsDir: String, iconPath: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)
    let iconImage = NSImage(contentsOfFile: iconPath)

    let frameCount = 12
    var cgFrames: [CGImage] = []

    for i in 0..<frameCount {
        let phase = Double(i) / Double(frameCount)
        let view = HeroBannerFrameView(phase: phase, iconImage: iconImage)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0
        if let cg = renderer.cgImage {
            cgFrames.append(cg)
        }
    }

    guard let firstFrame = cgFrames.first else {
        throw NSError(domain: "HeroGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render frames"])
    }

    // Save static PNG
    let pngRep = NSBitmapImageRep(cgImage: firstFrame)
    if let pngData = pngRep.representation(using: .png, properties: [:]) {
        try pngData.write(to: URL(fileURLWithPath: "\(assetsDir)/MemoPilotHero.png"))
    }

    // Save animated GIF (920x280)
    let gifURL = URL(fileURLWithPath: "\(assetsDir)/MemoPilotHero.gif")
    guard let dest = CGImageDestinationCreateWithURL(
        gifURL as CFURL,
        UTType.gif.identifier as CFString,
        cgFrames.count,
        nil
    ) else {
        throw NSError(domain: "HeroGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create GIF destination"])
    }

    let fileProps: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFLoopCount as String: 0
        ]
    ]
    CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

    let frameProps: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: 0.14,
            kCGImagePropertyGIFUnclampedDelayTime as String: 0.14
        ]
    ]

    for cg in cgFrames {
        CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
    }

    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "HeroGen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize GIF"])
    }
}

let assetsDir = "/Users/xiatianze/Desktop/MemoPilot/Assets"
let iconPath = "/Users/xiatianze/Desktop/MemoPilot/docs/icon-preview.png"
try MainActor.assumeIsolated {
    try generateHeroBanner(assetsDir: assetsDir, iconPath: iconPath)
}
print("✅ Generated \(assetsDir)/MemoPilotHero.gif and MemoPilotHero.png")
