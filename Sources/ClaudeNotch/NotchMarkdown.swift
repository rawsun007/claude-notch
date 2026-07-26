import SwiftUI
import AppKit

// Minimal markdown block parsing and rendering for card bodies.



enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(index: Int, String)
    case code(language: String?, content: String)
    case blank
}

func parseMarkdownBlocks(_ src: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraphLines: [String] = []
    var codeLines: [String] = []
    var inCode = false
    var codeLang: String? = nil

    func flushParagraph() {
        guard !paragraphLines.isEmpty else { return }
        let combined = paragraphLines.joined(separator: " ")
        if !combined.trimmingCharacters(in: .whitespaces).isEmpty {
            blocks.append(.paragraph(combined))
        }
        paragraphLines.removeAll()
    }

    for rawLine in src.components(separatedBy: "\n") {
        let line = rawLine

        // Fenced code blocks
        if line.hasPrefix("```") {
            if inCode {
                blocks.append(.code(language: codeLang, content: codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                inCode = false
                codeLang = nil
            } else {
                flushParagraph()
                inCode = true
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLang = lang.isEmpty ? nil : lang
            }
            continue
        }
        if inCode {
            codeLines.append(line)
            continue
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            flushParagraph()
            blocks.append(.blank)
            continue
        }

        // Headings (#, ##, ###)
        if trimmed.hasPrefix("# ") {
            flushParagraph()
            blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
            continue
        }
        if trimmed.hasPrefix("## ") {
            flushParagraph()
            blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
            continue
        }
        if trimmed.hasPrefix("### ") {
            flushParagraph()
            blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
            continue
        }

        // Bullet lists
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            flushParagraph()
            blocks.append(.bullet(String(trimmed.dropFirst(2))))
            continue
        }

        // Numbered lists (e.g. "1. text")
        if let dot = trimmed.firstIndex(of: "."),
           let n = Int(trimmed[..<dot]),
           trimmed.distance(from: trimmed.startIndex, to: dot) <= 3,
           trimmed.index(after: dot) < trimmed.endIndex,
           trimmed[trimmed.index(after: dot)] == " " {
            flushParagraph()
            let rest = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
            blocks.append(.numbered(index: n, rest))
            continue
        }

        paragraphLines.append(trimmed)
    }
    flushParagraph()
    if !codeLines.isEmpty {
        blocks.append(.code(language: codeLang, content: codeLines.joined(separator: "\n")))
    }
    return blocks
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            attributed(text)
                .font(.system(size: headingSize(level), weight: .bold, design: .default))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 6 : 2)

        case .paragraph(let text):
            attributed(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 10, alignment: .center)
                attributed(text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .numbered(let idx, let text):
            HStack(alignment: .top, spacing: 8) {
                Text("\(idx).")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 18, alignment: .trailing)
                attributed(text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .code(let lang, let content):
            VStack(alignment: .leading, spacing: 4) {
                if let lang, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                        .textCase(.uppercase)
                }
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

        case .blank:
            Spacer().frame(height: 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 14
        default: return 13
        }
    }

    private func attributed(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s,
                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}

let timeAgoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM"   // "9 Jul"
    return f
}()

func timeAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    let m = s / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    if h < 24 { return "\(h)h ago" }
    let d = h / 24
    // Past a week "312h ago" / even "13d ago" stops meaning anything — show the
    // actual date instead.
    if d <= 7 { return "\(d)d ago" }
    return timeAgoDateFormatter.string(from: date)
}

/// Compact elapsed-wait label: "45s", "3m", "1h 20m".
func waitElapsed(_ since: Date) -> String {
    let s = Int(Date().timeIntervalSince(since))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60; let rm = m % 60
    return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
}

/// Badge for non-default Claude Code permission modes. `default` (and empty)
/// return nil — no badge for the normal case. bypassPermissions is the loud
/// one: every action runs unchecked, so it's red and impossible to miss.
///
/// `acceptEdits` gets no badge either: auto-accepting file edits is a normal
/// way to work rather than something you need warning about, and the badge sat
/// in the notch permanently for anyone who works that way.
func permissionModeBadge(_ mode: String) -> (label: String, color: Color, help: String)? {
    switch mode {
    case "bypassPermissions":
        return ("BYPASS", .red, "Permissions are bypassed — every action runs without asking")
    case "plan":
        return ("PLAN", .blue, "Plan mode — Claude is planning, not editing")
    case "auto":
        return ("AUTO", .teal, "Auto mode — background safety checks approve safe actions")
    case "dontAsk":
        return ("DON'T ASK", .orange, "Don't-ask mode — most actions run without prompting")
    default:
        return nil
    }
}
