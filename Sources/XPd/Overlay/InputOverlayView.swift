import SwiftUI

struct InputOverlayView: View {
    let model: InputOverlayModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    InputOverlayRow(
                        entry: entry,
                        now: context.date,
                        isPrimary: index == 0
                    )
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.97))
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: model.visibleEntries.map(\.id))
    }
}

private struct InputOverlayRow: View {
    let entry: InputOverlayEntry
    let now: Date
    let isPrimary: Bool

    private let holdThreshold: TimeInterval = 0.72
    private let visibleDuration: TimeInterval = 1.35

    private var elapsed: TimeInterval {
        max(0, (entry.releasedAt ?? now).timeIntervalSince(entry.pressedAt))
    }

    private var holdProgress: Double {
        entry.isPressed ? min(elapsed / holdThreshold, 1) : 0
    }

    private var isHolding: Bool {
        entry.isPressed && elapsed >= holdThreshold
    }

    private var presentation: InputOverlayPresentation {
        if isHolding, let hold = entry.hold { return hold }
        return entry.tap
    }

    private var rowOpacity: Double {
        guard let releasedAt = entry.releasedAt else { return isPrimary ? 1 : 0.84 }
        let releaseAge = now.timeIntervalSince(releasedAt)
        return max(0, 1 - releaseAge / visibleDuration) * (isPrimary ? 1 : 0.84)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Array(presentation.tokens.prefix(4).enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("+")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    InputKeyCap(label: token)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(isHolding ? "HOLD" : presentation.detail)
                    .font(.system(size: isHolding ? 8 : 9, weight: .semibold, design: .rounded))
                    .tracking(isHolding ? 0.7 : 0)
                    .foregroundStyle(isHolding ? Color.cyan.opacity(0.9) : .white.opacity(0.45))
                    .lineLimit(1)
                if !entry.isPressed {
                    Text(String(format: "%.1fs", min(elapsed, 9.9)))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: 64, alignment: .trailing)

            InputHoldMeter(progress: holdProgress)
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(width: 246, height: isPrimary ? 54 : 48)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.black.opacity(isPrimary ? 0.25 : 0.17))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(isPrimary ? 0.14 : 0.08), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.2), radius: 16, y: 7)
        .opacity(rowOpacity)
    }
}

private struct InputKeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(1)
            .padding(.horizontal, label.count > 2 ? 9 : 8)
            .frame(minWidth: 33, minHeight: 31)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.6)
            )
    }
}

private struct InputHoldMeter: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(0.7), .cyan],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: max(3, proxy.size.height * progress))
                    .shadow(color: .cyan.opacity(progress > 0.85 ? 0.7 : 0.2), radius: 5)
            }
        }
        .frame(width: 5, height: 35)
    }
}
