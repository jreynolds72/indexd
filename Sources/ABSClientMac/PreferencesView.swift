import SwiftUI
import AppKit
import ABSCore

struct PreferencesView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var captureTarget: CaptureTarget?
    @State private var keyCaptureMonitor: Any?
    @State private var showUninstallSummarySheet = false
    @State private var uninstallInProgress = false
    @State private var uninstallErrorMessage: String?
    @State private var showUninstallProgressSheet = false
    @State private var cachedDownloads: [CachedDownloadSelection] = []
    @State private var loadingCachedDownloads = false
    @State private var uninstallStepStates: [UninstallStep: UninstallStepState] = Dictionary(
        uniqueKeysWithValues: UninstallStep.allCases.map { ($0, .pending) }
    )

    private struct CaptureTarget: Equatable {
        enum Slot {
            case primary
            case alternate
        }

        let action: ShortcutAction
        let slot: Slot
    }

    private enum UninstallStepState {
        case pending
        case inProgress
        case complete
        case failed
    }

    private struct CachedDownloadSelection: Identifiable {
        let id: String
        let title: String
        let author: String
        var selected: Bool
    }

    private enum UninstallCleanupAction: String, CaseIterable, Identifiable {
        case clearSupportFolder
        case clearKeychain
        case clearLogs
        case clearPreferences
        case deleteAppBundle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .clearSupportFolder:
                return "Clear Application Support data"
            case .clearKeychain:
                return "Clear saved keychain credentials"
            case .clearLogs:
                return "Clear app logs and caches"
            case .clearPreferences:
                return "Clear app preferences"
            case .deleteAppBundle:
                return "Delete indexd.app bundle"
            }
        }
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

            maintenanceTab
                .tag(SettingsTab.maintenance)
                .tabItem {
                    Label("Maintenance", systemImage: "wrench.and.screwdriver")
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

    private var maintenanceTab: some View {
        Form {
            Section {
                Button(role: .destructive) {
                    showUninstallSummarySheet = true
                } label: {
                    Text("Uninstall indexd…")
                }
                .disabled(uninstallInProgress)

                if uninstallInProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing uninstall…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Uninstall")
            } footer: {
                Text("This removes app data and the app bundle. Optionally, you can export downloaded books first.")
            }
        }
        .formStyle(.grouped)
        .alert("Uninstall Failed", isPresented: uninstallErrorBinding) {
            Button("OK", role: .cancel) {
                uninstallErrorMessage = nil
            }
        } message: {
            Text(uninstallErrorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showUninstallSummarySheet) {
            uninstallSummarySheet
        }
        .sheet(isPresented: $showUninstallProgressSheet) {
            uninstallProgressSheet
        }
    }

    private var uninstallSummarySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall Summary")
                .font(.title3.bold())

            Text("indexd will perform the following cleanup actions:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(UninstallCleanupAction.allCases) { action in
                    Label(action.title, systemImage: "checklist")
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(12)
            .background(.thinMaterial.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Divider()

            HStack {
                Text("Cached Books")
                    .font(.headline)
                Spacer()
                if loadingCachedDownloads {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(cachedDownloads.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if cachedDownloads.isEmpty {
                Text(loadingCachedDownloads ? "Loading cached books…" : "No cached books found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($cachedDownloads) { $book in
                            Toggle(isOn: $book.selected) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                        .fontWeight(.semibold)
                                    Text(book.author)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 4)

                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 240)
                .padding(10)
                .background(.thinMaterial.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showUninstallSummarySheet = false
                }

                Button(uninstallPrimaryActionTitle, role: .destructive) {
                    runUninstallFromSummary()
                }
                .disabled(uninstallInProgress || loadingCachedDownloads)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
        .task(id: showUninstallSummarySheet) {
            guard showUninstallSummarySheet else { return }
            await loadCachedDownloadsForSummary()
        }
    }

    private var uninstallProgressSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uninstalling indexd")
                .font(.title3.bold())

            Text("The app will close automatically after helper handoff.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(UninstallStep.allCases) { step in
                    HStack(spacing: 10) {
                        uninstallStatusIcon(for: step)
                        Text(step.title)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 320)
    }

    @ViewBuilder
    private func uninstallStatusIcon(for step: UninstallStep) -> some View {
        switch uninstallStepStates[step] ?? .pending {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
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

    private var uninstallErrorBinding: Binding<Bool> {
        Binding(
            get: { uninstallErrorMessage != nil },
            set: { visible in
                if !visible {
                    uninstallErrorMessage = nil
                }
            }
        )
    }

    private var selectedCachedDownloadIDs: Set<String> {
        Set(cachedDownloads.filter(\.selected).map(\.id))
    }

    private var uninstallPrimaryActionTitle: String {
        selectedCachedDownloadIDs.isEmpty ? "Uninstall" : "Choose Folder…"
    }

    private func runUninstallFromSummary() {
        guard !uninstallInProgress else { return }
        let selectedIDs = selectedCachedDownloadIDs

        if selectedIDs.isEmpty {
            showUninstallSummarySheet = false
            startUninstall(exportDestination: nil, selectedDownloadItemIDs: [])
            return
        }

        guard let destinationURL = selectExportDirectory() else { return }
        showUninstallSummarySheet = false
        startUninstall(exportDestination: destinationURL, selectedDownloadItemIDs: selectedIDs)
    }

    private func loadCachedDownloadsForSummary() async {
        loadingCachedDownloads = true
        defer { loadingCachedDownloads = false }

        guard let downloadManager = try? DownloadManager() else {
            cachedDownloads = []
            return
        }

        let records = await downloadManager.allDownloads()
        cachedDownloads = records.map { record in
            let title = record.itemTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = record.itemAuthor?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = (title?.isEmpty == false) ? (title ?? record.localFileName) : record.localFileName
            let resolvedAuthor = (author?.isEmpty == false) ? (author ?? "Unknown author") : "Unknown author"
            return CachedDownloadSelection(
                id: record.itemID,
                title: resolvedTitle,
                author: resolvedAuthor,
                selected: false
            )
        }
    }

    private func startUninstall(exportDestination: URL?, selectedDownloadItemIDs: Set<String>) {
        guard !uninstallInProgress else { return }
        uninstallInProgress = true

        Task { @MainActor in
            do {
                uninstallStepStates = Dictionary(
                    uniqueKeysWithValues: UninstallStep.allCases.map { ($0, .pending) }
                )
                showUninstallProgressSheet = true

                try UninstallCoordinator.prepareAndLaunchUninstall(
                    exportDownloadsTo: exportDestination,
                    selectedDownloadItemIDs: selectedDownloadItemIDs
                ) { step, started in
                    Task { @MainActor in
                        uninstallStepStates[step] = started ? .inProgress : .complete
                    }
                }
                NSApp.terminate(nil)
            } catch {
                uninstallInProgress = false
                showUninstallProgressSheet = false
                if let running = uninstallStepStates.first(where: { $0.value == .inProgress })?.key {
                    uninstallStepStates[running] = .failed
                }
                uninstallErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func selectExportDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Export Downloaded Books"
        panel.message = "Choose a folder to move downloaded books before uninstall."
        panel.prompt = "Choose Folder"
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url
    }
}
