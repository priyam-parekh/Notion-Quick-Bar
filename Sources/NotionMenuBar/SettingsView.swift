import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: TaskStore
    @Binding var isPresented: Bool
    @State private var token: String = ""
    @State private var databaseId: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Appearance")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryTextStyle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                appearanceToggle("Light Mode", isOn: lightModeBinding)
                appearanceToggle("Lunar", isOn: lunarModeBinding)
            }

            Text(store.isConfigured ? "Credentials are saved securely. Enter new values to replace them." : "Paste your Notion integration token and database ID.")
                .font(.system(size: 12))
                .foregroundStyle(secondaryTextStyle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            field(label: "Integration Token") {
                SecureField("secret_...", text: $token)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }

            field(label: "Database ID") {
                TextField(
                    "",
                    text: $databaseId,
                    prompt: Text(store.isConfigured && databaseId.isEmpty ? "Saved securely" : "32-character ID")
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
            }

            HStack {
                Button("Restart") {
                    restartWidget()
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.glass)
                Button("Save") {
                    if store.saveCredentials(token: token, databaseId: databaseId) {
                        token = ""
                        databaseId = ""
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(token.isEmpty || databaseId.isEmpty)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            token = ""
            databaseId = ""
        }
    }

    private var lightModeBinding: Binding<Bool> {
        Binding(
            get: { store.lightMode },
            set: { store.setLightMode($0) }
        )
    }

    private var lunarModeBinding: Binding<Bool> {
        Binding(
            get: { store.lunarMode },
            set: { store.setLunarMode($0) }
        )
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondaryTextStyle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .foregroundStyle(primaryTextStyle)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func appearanceToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(primaryTextStyle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
    }

    private var primaryTextStyle: AnyShapeStyle {
        if store.lunarMode { return AnyShapeStyle(LunarTheme.primaryText) }
        return AnyShapeStyle(.primary)
    }

    private var secondaryTextStyle: AnyShapeStyle {
        if store.lunarMode { return AnyShapeStyle(LunarTheme.secondaryText) }
        return AnyShapeStyle(.secondary)
    }

    private var fieldBackground: Color {
        if store.lunarMode { return LunarTheme.fieldFill }
        if store.lightMode { return LightModeTheme.fieldFill }
        return Color.primary.opacity(0.06)
    }

    private func restartWidget() {
        let process = Process()
        if Bundle.main.bundleURL.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", Bundle.main.bundleURL.path]
        } else if let executableURL = Bundle.main.executableURL {
            process.executableURL = executableURL
            process.arguments = Array(CommandLine.arguments.dropFirst())
        }
        try? process.run()
        NSApp.terminate(nil)
    }
}
