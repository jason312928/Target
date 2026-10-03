import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void
    let onOpenProfiles: () -> Void
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 8)

            Image(systemName: step.symbolName)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(step.titleKey)
                    .font(.title2.weight(.semibold))
                Text(step.messageKey)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            HStack {
                if step == .profiles {
                    Button("onboarding.open-profiles", action: completeAndOpenProfiles)
                        .accessibilityIdentifier("onboarding.open-profiles")
                }
                Spacer()
                if step != .welcome {
                    Button("onboarding.back", action: previousStep)
                }
                Button(step == .systemProxy ? "onboarding.finish" : "onboarding.continue", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
        .padding(32)
        .frame(width: 480, height: 320)
        .accessibilityIdentifier("onboarding")
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            onComplete()
            return
        }
        step = next
    }

    private func previousStep() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func completeAndOpenProfiles() {
        onComplete()
        onOpenProfiles()
    }
}
