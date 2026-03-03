import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var captureTarget: CaptureTarget?
    @State private var keyCaptureMonitor: Any?

    private struct CaptureTarget: Equatable {
        enum Slot {
            case primary
            case alternate
        }

        let action: ShortcutAction
        let slot: Slot
    }

    var body: some View {
        TabView(selection: $preferences.selectedSettingsTab) {
            playbackTab
                .tag(SettingsTab.playback)
                .tabItem {
                    Label("Playback", systemImage: "play.circle")
                }

            shortcutsTab
                .tag(SettingsTab.shortcuts)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .padding(20)
        .frame(minWidth: 1080, idealWidth: 1200, minHeight: 440, idealHeight: 560)
        .onAppear {
            installKeyCaptureMonitor()
        }
        .onDisappear {
            removeKeyCaptureMonitor()
            captureTarget = nil
            preferences.isCapturingShortcut = false
        }
    }

    private var playbackTab: some View {
        Form {
            Section("Playback Settings") {
                Picker("Skip Backward", selection: $preferences.skipBackwardSeconds) {
                    Text("10 seconds").tag(10.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("45 seconds").tag(45.0)
                    Text("60 seconds").tag(60.0)
                }
                .pickerStyle(.menu)

                Picker("Skip Forward", selection: $preferences.skipForwardSeconds) {
                    Text("10 seconds").tag(10.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("45 seconds").tag(45.0)
                    Text("60 seconds").tag(60.0)
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsTab: some View {
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width - 24, 920)
            let actionColumnWidth = min(max(contentWidth * 0.26, 220), 300)
            let mappingColumnWidth = (contentWidth - actionColumnWidth - 20) / 2
            let modifierPickerWidth = max((mappingColumnWidth * 0.64) - 6, 170)
            let keyPickerWidth = max((mappingColumnWidth * 0.36) - 6, 120)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Button Mappings")
                            .font(.headline)
                        Spacer()
                        Button("Revert to Defaults") {
                            preferences.revertToDefaultShortcuts()
                            captureTarget = nil
                            preferences.isCapturingShortcut = false
                        }
                    }

                    VStack(spacing: 0) {
                        shortcutMappingHeaderRow(
                            actionWidth: actionColumnWidth,
                            mappingWidth: mappingColumnWidth
                        )
                        Divider()
                        shortcutMappingRow(
                            action: .skipBackwardConfiguredInterval,
                            actionWidth: actionColumnWidth,
                            mappingWidth: mappingColumnWidth,
                            modifierWidth: modifierPickerWidth,
                            keyWidth: keyPickerWidth
                        )
                        Divider()
                        shortcutMappingRow(
                            action: .skipForwardConfiguredInterval,
                            actionWidth: actionColumnWidth,
                            mappingWidth: mappingColumnWidth,
                            modifierWidth: modifierPickerWidth,
                            keyWidth: keyPickerWidth
                        )
                        Divider()
                        shortcutMappingRow(
                            action: .skipBackwardOneSecond,
                            actionWidth: actionColumnWidth,
                            mappingWidth: mappingColumnWidth,
                            modifierWidth: modifierPickerWidth,
                            keyWidth: keyPickerWidth
                        )
                        Divider()
                        shortcutMappingRow(
                            action: .skipForwardOneSecond,
                            actionWidth: actionColumnWidth,
                            mappingWidth: mappingColumnWidth,
                            modifierWidth: modifierPickerWidth,
                            keyWidth: keyPickerWidth
                        )
                        Divider()
                        shortcutMappingRow(
                            action: .playPauseToggle,
                            actionWidth: actionColumnWidth,
                            mappingWidth: mappingColumnWidth,
                            modifierWidth: modifierPickerWidth,
                            keyWidth: keyPickerWidth
                        )
                        Divider()
                        shortcutMappingRow(
                            action: .previousChapter,
                            actionWidth: actionColumnWidth,
                            mappingWidth: mappingColumnWidth,
                            modifierWidth: modifierPickerWidth,
                            keyWidth: keyPickerWidth
                        )
                        Divider()
                        shortcutMappingRow(
                            action: .nextChapter,
                            actionWidth: actionColumnWidth,
                            mappingWidth: mappingColumnWidth,
                            modifierWidth: modifierPickerWidth,
                            keyWidth: keyPickerWidth
                        )
                    }
                    .background(.thinMaterial.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .frame(minWidth: contentWidth, maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private func shortcutMappingHeaderRow(actionWidth: CGFloat, mappingWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Action")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: actionWidth, alignment: .leading)

            Text("Primary Mapping")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: mappingWidth, alignment: .leading)

            Text("Alternate Mapping")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: mappingWidth, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutMappingRow(
        action: ShortcutAction,
        actionWidth: CGFloat,
        mappingWidth: CGFloat,
        modifierWidth: CGFloat,
        keyWidth: CGFloat
    ) -> some View {
        return HStack(alignment: .center, spacing: 10) {
            Text(action.title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: actionWidth, alignment: .leading)

            HStack(spacing: 8) {
                Button(captureButtonTitle(action: action, slot: .primary)) {
                    beginCapture(action: action, slot: .primary)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(width: modifierWidth + keyWidth + 8, alignment: .leading)
            }
            .frame(width: mappingWidth, alignment: .leading)

            HStack(spacing: 8) {
                Button(captureButtonTitle(action: action, slot: .alternate)) {
                    beginCapture(action: action, slot: .alternate)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(width: modifierWidth + keyWidth - 28, alignment: .leading)

                Button {
                    preferences.setAlternateBinding(nil, for: action)
                    if captureTarget == CaptureTarget(action: action, slot: .alternate) {
                        captureTarget = nil
                        preferences.isCapturingShortcut = false
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear alternate mapping")
            }
            .frame(width: mappingWidth, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captureButtonTitle(action: ShortcutAction, slot: CaptureTarget.Slot) -> String {
        if captureTarget == CaptureTarget(action: action, slot: slot) {
            return "Press shortcut..."
        }

        let binding: ShortcutBinding?
        switch slot {
        case .primary:
            binding = preferences.primaryBinding(for: action)
        case .alternate:
            binding = preferences.alternateBinding(for: action)
        }

        guard let binding else { return "Set alternate..." }

        if binding.modifiers == .none {
            return binding.key.displayName
        }
        return "\(binding.modifiers.title) + \(binding.key.displayName)"
    }

    private func beginCapture(action: ShortcutAction, slot: CaptureTarget.Slot) {
        captureTarget = CaptureTarget(action: action, slot: slot)
        preferences.isCapturingShortcut = true
    }

    private func installKeyCaptureMonitor() {
        guard keyCaptureMonitor == nil else { return }

        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let target = captureTarget else { return event }

            if event.keyCode == 53 { // Escape cancels capture.
                captureTarget = nil
                preferences.isCapturingShortcut = false
                return nil
            }

            guard let key = ShortcutKey.from(event: event) else { return nil }
            let eventFlags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard let modifiers = ShortcutModifierSet.from(eventFlags: eventFlags) else { return nil }

            let binding = ShortcutBinding(key: key, modifiers: modifiers)
            switch target.slot {
            case .primary:
                preferences.setPrimaryBinding(binding, for: target.action)
            case .alternate:
                preferences.setAlternateBinding(binding, for: target.action)
            }

            captureTarget = nil
            preferences.isCapturingShortcut = false
            return nil
        }
    }

    private func removeKeyCaptureMonitor() {
        if let keyCaptureMonitor {
            NSEvent.removeMonitor(keyCaptureMonitor)
            self.keyCaptureMonitor = nil
        }
    }
}
