import SwiftUI

struct InputOverlayView: View {
    let model: InputOverlayModel

    var body: some View {
        Group {
            if let selection = model.profileSelection {
                ProfileSelectorCard(selection: selection)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                VStack(alignment: .trailing, spacing: 9) {
                    ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                            if index == 0 {
                                SoftSlateCard(
                                    entry: entry,
                                    now: context.date,
                                    displayDuration: model.displayDuration
                                )
                            } else {
                                SoftSlateHistoryCard(
                                    entry: entry,
                                    now: context.date,
                                    displayDuration: model.displayDuration
                                )
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.98))
                        ))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.visibleEntries.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: model.profileSelection)
    }
}

private struct ProfileSelectorCard: View {
    let selection: ProfileOverlaySelection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PROFILE")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Color.white.opacity(0.42))
                    Text(selection.selectedProfile)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.96))
                }
                Spacer()
                Image(systemName: "dial.medium")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(Color.cyan.opacity(0.85))
            }

            Rectangle()
                .fill(Color.white.opacity(0.11))
                .frame(height: 0.7)

            VStack(spacing: 4) {
                ForEach(selection.profiles, id: \.self) { profile in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(profile == selection.selectedProfile ? Color.cyan : Color.clear)
                            .frame(width: 6, height: 6)
                        Text(profile)
                            .font(.system(size: 12, weight: profile == selection.selectedProfile ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(Color.white.opacity(profile == selection.selectedProfile ? 0.94 : 0.46))
                        Spacer()
                    }
                    .frame(height: 22)
                }
            }

            HStack {
                Text("ROTATE TO CHOOSE")
                Spacer()
                Text("PRESS TO SELECT")
            }
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(Color.white.opacity(0.32))
        }
        .padding(16)
        .frame(width: 290)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.78)
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.52))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.30), radius: 24, y: 12)
    }
}

private struct SoftSlateCard: View {
    let entry: InputOverlayEntry
    let now: Date
    let displayDuration: TimeInterval

    private let holdThreshold: TimeInterval = 0.72

    private var elapsed: TimeInterval {
        max(0, (entry.releasedAt ?? now).timeIntervalSince(entry.pressedAt))
    }

    private var holdProgress: Double {
        entry.isPressed ? min(elapsed / holdThreshold, 1) : 0
    }

    private var isHolding: Bool {
        entry.isPressed && elapsed >= holdThreshold
    }

    private var cardOpacity: Double {
        guard let releasedAt = entry.releasedAt else { return 1 }
        let age = now.timeIntervalSince(releasedAt)
        let fadeDuration = min(0.7, displayDuration * 0.3)
        let fadeStart = displayDuration - fadeDuration
        guard age > fadeStart else { return 1 }
        return max(0, 1 - (age - fadeStart) / fadeDuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Text(entry.control.overlayLabel)
                    .font(.system(size: 70, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.055))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: 118, height: 67, alignment: .trailing)
                    .offset(x: 4, y: -10)

                VStack(alignment: .leading, spacing: 4) {
                    Text("PHYSICAL CONTROL")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(Color.white.opacity(0.38))

                    Text(entry.control.overlayLabel)
                        .font(.system(size: 25, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 59)

            Rectangle()
                .fill(Color.white.opacity(0.11))
                .frame(height: 0.7)
                .padding(.bottom, 9)

            VStack(spacing: 4) {
                SoftSlateActionLine(label: "TAP", presentation: entry.tap, isActive: !isHolding)
                SoftSlateActionLine(label: "HOLD", presentation: entry.hold, isActive: isHolding)
                SoftSlateActionLine(label: "DOUBLE", presentation: entry.doubleTap, isActive: false)
            }

            Spacer(minLength: 9)

            HorizontalHoldMeter(progress: holdProgress)
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(width: 290, height: 184)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.72)
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.58),
                            Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.42)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.075)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .shadow(color: Color.black.opacity(0.30), radius: 24, y: 12)
        .opacity(cardOpacity)
    }
}

private struct SoftSlateActionLine: View {
    let label: String
    let presentation: InputOverlayPresentation
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .tracking(0.55)
                .foregroundStyle(isActive ? Color.cyan.opacity(0.84) : Color.white.opacity(0.48))
                .frame(width: 54, alignment: .leading)

            ActionValue(presentation: presentation, isActive: isActive, compact: false)
        }
        .frame(height: 20)
    }
}

private struct SoftSlateHistoryCard: View {
    let entry: InputOverlayEntry
    let now: Date
    let displayDuration: TimeInterval

    private var cardOpacity: Double {
        guard let releasedAt = entry.releasedAt else { return 0.68 }
        let age = now.timeIntervalSince(releasedAt)
        let fadeDuration = min(0.7, displayDuration * 0.3)
        let fadeStart = displayDuration - fadeDuration
        guard age > fadeStart else { return 0.68 }
        return max(0, 1 - (age - fadeStart) / fadeDuration) * 0.68
    }

    var body: some View {
        HStack(spacing: 13) {
            Text(entry.control.overlayLabel)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 42, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 0.7, height: 25)

            VStack(alignment: .leading, spacing: 3) {
                Text("TAP")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.30))
                ActionValue(presentation: entry.tap, isActive: false, compact: true)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 290, height: 50, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.48)
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.31))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 7)
        .opacity(cardOpacity)
    }
}

private struct ActionValue: View {
    let presentation: InputOverlayPresentation
    let isActive: Bool
    let compact: Bool

    var body: some View {
        Group {
            if presentation.shortcutTokens.isEmpty {
                Text(presentation.title)
                    .font(.system(size: compact ? 10 : 12, weight: isActive ? .medium : .regular, design: .rounded))
                    .foregroundStyle(
                        presentation.isConfigured
                            ? Color.white.opacity(isActive ? 0.94 : 0.70)
                            : Color.white.opacity(0.28)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                HStack(spacing: compact ? 3 : 5) {
                    ForEach(Array(presentation.shortcutTokens.prefix(4).enumerated()), id: \.offset) { index, token in
                        if index > 0 {
                            Text("+")
                                .font(.system(size: compact ? 8 : 10, weight: .regular))
                                .foregroundStyle(Color.white.opacity(0.30))
                        }
                        Text(token)
                            .font(.system(size: compact ? 9 : 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(isActive ? 0.92 : 0.68))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HorizontalHoldMeter: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.38, green: 0.82, blue: 1.0),
                                Color(red: 0.32, green: 0.94, blue: 0.88)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * progress)
                    .shadow(color: Color.cyan.opacity(progress > 0 ? 0.55 : 0), radius: 8)
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.06), value: progress)
    }
}
