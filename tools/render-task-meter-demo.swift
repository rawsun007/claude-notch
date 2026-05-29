// Renders the ClaudeNotch task progress meter to a PNG, offscreen, so we have a
// static visual of the feature without needing a screen recording. Uses SwiftUI
// ImageRenderer (macOS 13+), which rasterizes a view without a window.
//
//   swift tools/render-task-meter-demo.swift [out.png]
//
// Keep TaskMeter here in sync with Sources/ClaudeNotch/NotchView.swift.
import SwiftUI
import AppKit

// Mirror of the in-app private TaskMeter view.
struct TaskMeter: View {
    let done: Int
    let total: Int
    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return min(1, max(0, CGFloat(done) / CGFloat(total)))
    }
    private var complete: Bool { total > 0 && done >= total }
    private var tint: Color { complete ? .green : .blue }
    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(width: 26, height: 3)
                Capsule().fill(tint.opacity(0.9)).frame(width: 26 * fraction, height: 3)
            }
            Text("\(done)/\(total)")
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(.white.opacity(complete ? 0.8 : 0.55))
        }
    }
}

// A faux notch session row, matching the real layout (dot + project + meter).
struct DemoRow: View {
    let project: String
    let done: Int
    let total: Int
    var working: Bool { done < total }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(working ? Color.blue : Color.green).frame(width: 6, height: 6)
            Text(project)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
            Spacer(minLength: 8)
            TaskMeter(done: done, total: total)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(width: 250)
    }
}

struct DemoStrip: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("ClaudeNotch · task progress meter")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
                .padding(.top, 16).padding(.bottom, 10)
            VStack(spacing: 2) {
                DemoRow(project: "auth-service", done: 0, total: 5)
                Divider().overlay(Color.white.opacity(0.08))
                DemoRow(project: "payments-api", done: 3, total: 5)
                Divider().overlay(Color.white.opacity(0.08))
                DemoRow(project: "web-dashboard", done: 5, total: 5)
            }
            .padding(.bottom, 16)
        }
        .frame(width: 282)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .padding(24)
        .background(Color(white: 0.10))
    }
}

MainActor.assumeIsolated {
    let out = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "assets/task-meter-demo.png"
    let renderer = ImageRenderer(content: DemoStrip())
    renderer.scale = 3.0   // retina
    guard let img = renderer.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: out))
        print("✓ wrote \(out) (\(rep.pixelsWide)x\(rep.pixelsHigh) px)")
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        exit(1)
    }
}
