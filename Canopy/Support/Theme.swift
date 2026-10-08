import SwiftUI

// MARK: - Canopy Design System
// A warm, editorial visual language for the app: serif display type over
// system sans body text, paper-toned surfaces instead of system materials,
// and the sage/terracotta brand palette carried through buttons, pills,
// and cards. This file is the single source of truth for those tokens —
// screens should reach for these instead of raw system colors/fonts.

// MARK: Colors
// Color.canopyPaper, .canopyPaperElevated, .canopyInk, .canopyRule,
// .canopySage, .canopySageTint, and .canopyRust are generated automatically
// by Xcode from the matching colorsets in Assets.xcassets — no extension
// needed here.

/// Neutral, low-chroma surround for media viewers. The warm paper palette
/// would tint how footage reads while reviewing, so preview sheets sit on
/// this instead (and force dark appearance).
extension Color {
    static let canopyViewerGray = Color(white: 0.09)
}

// MARK: Typography
extension Font {
    /// Serif display type (renders as New York on macOS) for headings and
    /// masthead-style titles — the main departure from stock system type.
    static func canopyDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static let canopyLargeTitle = canopyDisplay(28)
    static let canopyTitle = canopyDisplay(20)
    static let canopyTitle2 = canopyDisplay(16)
}

// MARK: - Card surface
// Standard container for grouped content: an elevated paper surface with
// soft rounded corners and a hairline rule, replacing ad-hoc
// RoundedRectangle/opacity backgrounds.
struct CanopyCard: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.canopyPaperElevated)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.canopyRule, lineWidth: 1)
            )
    }
}

extension View {
    func canopyCard(padding: CGFloat = 16, cornerRadius: CGFloat = 14) -> some View {
        modifier(CanopyCard(padding: padding, cornerRadius: cornerRadius))
    }
}

// MARK: - Pill / badge
// Small status labels (stat pills, tags) — a soft capsule tinted with the
// given color rather than a flat system-color chip.
struct CanopyPill: View {
    var label: String
    var color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Button styles
struct CanopyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(Capsule())
    }
}

struct CanopySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(Color.canopyInk)
            .background(Color.canopyPaperElevated.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.canopyRule, lineWidth: 1))
    }
}

extension ButtonStyle where Self == CanopyPrimaryButtonStyle {
    static var canopyPrimary: CanopyPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == CanopySecondaryButtonStyle {
    static var canopySecondary: CanopySecondaryButtonStyle { .init() }
}

// MARK: - Phase indicator
// A small ring that fills as work progresses and resolves to a sage
// checkmark with a short spring when it completes. Idle/error phases show
// their plain icon. Honors Reduce Motion by skipping the bounce.
struct CanopyPhaseIndicator: View {
    /// 0...1 while in flight; nil when there's no meaningful fraction.
    var progress: Double?
    var isDone: Bool
    var icon: String
    var color: Color
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(Color.canopySage)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            } else if let progress {
                Circle().stroke(color.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.03, min(progress, 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: progress)
            } else {
                Image(systemName: icon)
                    .resizable().scaledToFit()
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6), value: isDone)
    }
}

// MARK: - Close button
// Icon-only dismiss control for sheets; Esc still closes via `.cancelAction`.
struct CanopyCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityLabel("Close")
    }
}
