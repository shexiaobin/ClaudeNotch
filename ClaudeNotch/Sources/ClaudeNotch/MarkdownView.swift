import SwiftUI

// MARK: - Simple Markdown renderer (macOS 11 compatible)

struct SimpleMarkdownView: View {
    let text: String
    let fontSize: CGFloat

    init(_ text: String, fontSize: CGFloat = 11) {
        self.text = text
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block-level parsing

    private enum Block {
        case text(String)
        case code(String)
        case header(String, Int)
    }

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                let code = codeLines.joined(separator: "\n")
                if !code.isEmpty { blocks.append(.code(code)) }
                i += 1
                continue
            }

            if line.hasPrefix("### ")      { blocks.append(.header(String(line.dropFirst(4)), 3)) }
            else if line.hasPrefix("## ")   { blocks.append(.header(String(line.dropFirst(3)), 2)) }
            else if line.hasPrefix("# ")    { blocks.append(.header(String(line.dropFirst(2)), 1)) }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.text(line))
            }
            i += 1
        }
        return blocks
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .text(let s):
            inlineMarkdown(s)
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundColor(Color.green.opacity(0.9))
                    .padding(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.4))
            .cornerRadius(6)
        case .header(let s, let level):
            Text(s)
                .font(.system(size: fontSize + CGFloat(4 - level), weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Inline parsing (`code`, **bold**)

    private enum Inline {
        case plain(String)
        case code(String)
        case bold(String)
    }

    private func inlineMarkdown(_ raw: String) -> Text {
        var parts: [Inline] = []
        var buf = raw[raw.startIndex...]

        while !buf.isEmpty {
            if let r = buf.range(of: "`") {
                let before = String(buf[buf.startIndex..<r.lowerBound])
                if !before.isEmpty { parts.append(.plain(before)) }
                let rest = buf[r.upperBound...]
                if let end = rest.range(of: "`") {
                    parts.append(.code(String(rest[rest.startIndex..<end.lowerBound])))
                    buf = rest[end.upperBound...]
                    continue
                }
            }
            if let r = buf.range(of: "**") {
                let before = String(buf[buf.startIndex..<r.lowerBound])
                if !before.isEmpty { parts.append(.plain(before)) }
                let rest = buf[r.upperBound...]
                if let end = rest.range(of: "**") {
                    parts.append(.bold(String(rest[rest.startIndex..<end.lowerBound])))
                    buf = rest[end.upperBound...]
                    continue
                }
            }
            parts.append(.plain(String(buf)))
            break
        }

        return parts.reduce(Text("")) { result, part in
            switch part {
            case .plain(let s):
                return result + Text(s)
                    .font(.system(size: fontSize))
                    .foregroundColor(Color.white.opacity(0.85))
            case .code(let s):
                return result + Text(" \(s) ")
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundColor(Color.green.opacity(0.9))
            case .bold(let s):
                return result + Text(s)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Command preview for permission panels

struct CommandPreviewView: View {
    let command: String?
    let filePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cmd = command, !cmd.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("$")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.green.opacity(0.6))
                    Text(cmd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.green)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.4))
                .cornerRadius(6)
            }
            if let path = filePath, !path.isEmpty {
                HStack(spacing: 4) {
                    Text("F")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.orange.opacity(0.8))
                        .frame(width: 14, height: 14)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                    Text(shortenPath(path))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
