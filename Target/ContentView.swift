import SwiftUI

struct ContentView: View {
    @Bindable var lifecycle: TunnelLifecycleModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: lifecycle.symbolName)
                .font(.system(size: 42))
                .accessibilityHidden(true)

            Text("app.title")
                .font(.largeTitle)

            Text(lifecycle.statusKey)
                .font(.title3)

            Text(lifecycle.detailKey)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(lifecycle.actionKey) {
                lifecycle.toggle()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!lifecycle.canToggle)
        }
        .frame(minWidth: 360, minHeight: 260)
        .padding(32)
    }
}
