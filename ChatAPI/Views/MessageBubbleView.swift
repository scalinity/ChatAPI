import SwiftUI

struct MessageBubbleView: View {
  let message: Message
  @State private var isReasoningExpanded: Bool = true  // Auto-expand by default

  var body: some View {
    HStack {
      if message.role == .assistant {
        bubbleContent
        Spacer(minLength: 40)
      } else {
        Spacer(minLength: 40)
        bubbleContent
      }
    }
  }

  @ViewBuilder
  private var bubbleContent: some View {
    VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 8) {
      // Reasoning stream (thinking process) - collapsible
      if !message.reasoning_content.isEmpty {
        DisclosureGroup(
          isExpanded: $isReasoningExpanded,
          content: {
            Text(message.reasoning_content)
              .textSelection(.enabled)
              .font(.system(size: 13))
              .foregroundStyle(.primary.opacity(0.7))
              .padding(.top, 8)
          },
          label: {
            HStack(spacing: 6) {
              Image(systemName: "brain.head.profile")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
              Text("Thinking")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
              Spacer()
            }
          }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.black.opacity(0.25))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
            )
        )
      }
      
      // Main content bubble
      bubble
    }
    .frame(maxWidth: 720, alignment: message.role == .assistant ? .leading : .trailing)
  }

  private var bubble: some View {
    Text(renderedText)
      .textSelection(.enabled)
      .font(.system(size: 14))
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(message.role == .assistant ? .black.opacity(0.35) : .blue.opacity(0.25))
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(.white.opacity(0.08), lineWidth: 1)
          )
      )
  }

  private var renderedText: AttributedString {
    // SECURITY: Sanitize content before markdown rendering to prevent injection attacks.
    let sanitized = Self.sanitizeForMarkdown(message.content)

    // Use restrictive markdown parsing options
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false,
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    if let attributed = try? AttributedString(markdown: sanitized, options: options) {
      return attributed
    }
    return AttributedString(sanitized)
  }

  // MARK: - Security

  /// SECURITY: Sanitizes content before markdown rendering.
  /// Removes potentially dangerous protocol handlers and limits content size.
  private static func sanitizeForMarkdown(_ input: String) -> String {
    var sanitized = input

    // SECURITY: Strip dangerous URI protocols that could be exploited in links
    // Pattern matches markdown links: [text](protocol:...)
    let dangerousProtocols = [
      #"\[([^\]]*)\]\(javascript:[^)]*\)"#,   // javascript: protocol
      #"\[([^\]]*)\]\(vbscript:[^)]*\)"#,     // vbscript: protocol
      #"\[([^\]]*)\]\(data:[^)]*\)"#,         // data: protocol (can embed scripts)
      #"\[([^\]]*)\]\(file:[^)]*\)"#,         // file: protocol (local file access)
    ]

    for pattern in dangerousProtocols {
      sanitized = sanitized.replacingOccurrences(
        of: pattern,
        with: "[$1](blocked)",
        options: [.regularExpression, .caseInsensitive]
      )
    }

    // SECURITY: Strip raw dangerous protocols (not in markdown link syntax)
    sanitized = sanitized.replacingOccurrences(
      of: #"(?<![(\[])(javascript|vbscript|data):"#,
      with: "[blocked]:",
      options: [.regularExpression, .caseInsensitive]
    )

    // SECURITY: Neutralize potential RTL override attacks (Unicode bidi)
    // These can be used to visually mislead users about link destinations
    let dangerousBidiChars: [Character] = [
      "\u{202A}", // LEFT-TO-RIGHT EMBEDDING
      "\u{202B}", // RIGHT-TO-LEFT EMBEDDING
      "\u{202C}", // POP DIRECTIONAL FORMATTING
      "\u{202D}", // LEFT-TO-RIGHT OVERRIDE
      "\u{202E}", // RIGHT-TO-LEFT OVERRIDE
      "\u{2066}", // LEFT-TO-RIGHT ISOLATE
      "\u{2067}", // RIGHT-TO-LEFT ISOLATE
      "\u{2068}", // FIRST STRONG ISOLATE
      "\u{2069}", // POP DIRECTIONAL ISOLATE
    ]
    for char in dangerousBidiChars {
      sanitized = sanitized.replacingOccurrences(of: String(char), with: "")
    }

    // SECURITY: Limit content length to prevent DoS via extremely large messages
    let maxLength = 500_000 // 500KB should be more than enough for any message
    if sanitized.count > maxLength {
      sanitized = String(sanitized.prefix(maxLength)) + "\n\n[Content truncated for security]"
    }

    // SECURITY: Limit markdown nesting depth by counting certain patterns
    // Excessive nesting can cause performance issues in the parser
    let nestedPatterns = sanitized.components(separatedBy: "```").count - 1
    if nestedPatterns > 50 {
      // Too many code blocks, render as plain text
      return sanitized.replacingOccurrences(of: "```", with: "'''")
    }

    return sanitized
  }
}



