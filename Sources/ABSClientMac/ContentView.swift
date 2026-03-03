import SwiftUI
import AVFoundation
import AppKit
import OSLog
import ABSCore

struct ContentView: View {
    private static let settingsLogger = Logger(subsystem: "com.indexd.app", category: "settings")
    private enum ProgressHistorySource: String, Codable {
        case appClient = "App Client"
        case appPauseSync = "App Pause Sync"
        case appClear = "App Clear Action"
        case absServer = "ABS Server"
        case manualUpload = "Manual Upload"
        case manualRestore = "Manual Restore"
    }

    private struct ProgressHistoryEntry: Identifiable, Codable {
        let id: UUID
        let itemID: String
        let positionSeconds: TimeInterval
        let source: ProgressHistorySource
        let occurredAt: Date
    }
    private struct PrecisionScrubber: View {
        @Binding var value: Double
        let range: ClosedRange<Double>
        let markerValues: [Double]
        let showsMarkers: Bool
        let snapToMarkers: Bool
        let snapTolerance: Double
        var onEditingChanged: ((Bool) -> Void)? = nil

        @State private var isHovering = false
        @State private var isDragging = false
        @State private var holdPrecisionHandle = false

        var body: some View {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let normalized = normalizedProgress(for: value)
                let handleX = width * normalized
                let precisionHandle = isDragging || holdPrecisionHandle

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.34))
                        .frame(height: 4)

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: handleX, height: 4)

                    if showsMarkers {
                        ForEach(Array(markerValues.enumerated()), id: \.offset) { _, marker in
                            let markerX = width * normalizedProgress(for: marker)
                            Capsule()
                                .fill(Color.secondary.opacity(0.72))
                                .frame(width: 2, height: 8)
                                .offset(x: min(max(markerX, 0), width))
                        }
                    }

                    RoundedRectangle(cornerRadius: precisionHandle ? 2 : 10)
                        .fill(Color(nsColor: .systemGray))
                        .frame(width: precisionHandle ? 4 : 22, height: precisionHandle ? 20 : 22)
                        .offset(x: min(max(handleX, 0), width) - (precisionHandle ? 2 : 11))
                        .animation(.easeInOut(duration: 0.12), value: precisionHandle)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !isDragging {
                                isDragging = true
                                holdPrecisionHandle = true
                                onEditingChanged?(true)
                            }
                            value = valueForLocationX(drag.location.x, width: width)
                        }
                        .onEnded { drag in
                            value = valueForLocationX(drag.location.x, width: width)
                            isDragging = false
                            onEditingChanged?(false)
                        }
                )
            }
            .frame(height: 24)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovering = hovering
                    if !hovering {
                        holdPrecisionHandle = false
                    }
                }
            }
        }

        private func normalizedProgress(for rawValue: Double) -> CGFloat {
            let clamped = min(max(rawValue, range.lowerBound), range.upperBound)
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            return CGFloat((clamped - range.lowerBound) / span)
        }

        private func valueForLocationX(_ x: CGFloat, width: CGFloat) -> Double {
            let clampedX = min(max(0, x), width)
            let ratio = Double(clampedX / max(width, 1))
            let raw = range.lowerBound + ((range.upperBound - range.lowerBound) * ratio)
            return snap(raw, width: width)
        }

        private func snap(_ raw: Double, width: CGFloat) -> Double {
            let clamped = min(max(raw, range.lowerBound), range.upperBound)
            guard snapToMarkers, !markerValues.isEmpty else { return clamped }
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let pixelTolerance: CGFloat = 12
            let pixelToleranceInValue = span * Double(pixelTolerance / max(width, 1))
            let effectiveTolerance = max(snapTolerance, pixelToleranceInValue)
            guard let nearest = markerValues.min(by: { abs($0 - clamped) < abs($1 - clamped) }) else {
                return clamped
            }
            return abs(nearest - clamped) <= effectiveTolerance ? nearest : clamped
        }
    }

    private struct BrowseGroup: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let itemCount: Int
        let items: [ABSCore.LibraryItem]
    }

    private struct SearchSeriesSuggestion: Identifiable {
        let id: String
        let name: String
        let count: Int
    }

    private struct SearchNarratorSuggestion: Identifiable {
        let id: String
        let name: String
        let count: Int
    }

    private struct SeriesDetailSection: Identifiable {
        let id: String
        let title: String
        let items: [ABSCore.LibraryItem]
    }

    private enum LibraryBrowseTab: String {
        case authors = "Authors"
        case narrators = "Narrators"
        case series = "Series"
        case collections = "Collections"
        case continueListening = "Continue"
        case recent = "Recent"
        case favorites = "Favorites"
        case books = "Books"
    }

    private enum BookSortOption: String, CaseIterable, Identifiable {
        case alphabetical = "Alphabetical"
        case author = "Author"
        case durationLongest = "Duration (Longest)"
        case durationShortest = "Duration (Shortest)"
        case recentlyActive = "Recently Active"

        var id: String { rawValue }
    }

    private enum GroupSortOption: String, CaseIterable, Identifiable {
        case alphabetical = "Alphabetical"
        case bookCountMost = "Book Count (Most)"
        case bookCountLeast = "Book Count (Least)"

        var id: String { rawValue }
    }

    private enum ItemFilterOption: String, CaseIterable, Identifiable {
        case all = "All Items"
        case inProgress = "In Progress"
        case favorites = "Favorites"

        var id: String { rawValue }
    }

    private let mediaIntegration = MacMediaIntegrationManager.shared
    private let progressDefaultsKey = "abs.local.progress.v1"
    private let progressHistoryDefaultsKey = "abs.local.progress.history.v1"
    private let favoritesDefaultsKey = "abs.local.favorites.v1"
    private let recentDefaultsKey = "abs.local.recent.v1"
    private let searchSuggestionLimit = 5
    private let libraryBrowseTabs: [LibraryBrowseTab] = [
        .authors,
        .narrators,
        .series,
        .collections,
        .continueListening,
        .recent,
        .favorites,
        .books
    ]

    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel = AppViewModel()
    @State private var selectedItemID: ABSCore.LibraryItem.ID?
    @State private var selectedGroupID: String?
    @State private var searchText = ""
    @State private var itemFilter: ItemFilterOption = .all
    @State private var bookSortOption: BookSortOption = .alphabetical
    @State private var groupSortOption: GroupSortOption = .alphabetical
    @State private var playbackSpeed = 1.0
    @State private var isPlaying = false
    @State private var elapsedSeconds = 0.0
    @State private var showingServerSheet = false
    @State private var activeItemID: String?
    @State private var nowPlayingItem: ABSCore.LibraryItem?
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var showingNowPlaying = false
    @State private var keyboardMonitor: Any?
    @State private var expandedLibraryIDs: Set<String> = []
    @State private var browseTabByLibraryID: [String: LibraryBrowseTab] = [:]

    @State private var player = AVPlayer()
    @State private var timeObserverToken: Any?
    @State private var playbackChapters: [ABSCore.Chapter] = []
    @State private var coverImagesByItemID: [String: NSImage] = [:]
    @State private var nowPlayingChapterListHeight: CGFloat = 180
    @State private var nowPlayingChapterListDragStart: CGFloat?
    @State private var nowPlayingChapterListUserResized = false
    @State private var nowPlayingDismissDragOffset: CGFloat = 0
    @State private var nowPlayingDismissHandleHovered = false
    @State private var bottomExpandHandleHovered = false
    @State private var bottomExpandDragOffset: CGFloat = 0
    @State private var localProgressByItemID: [String: TimeInterval] = [:]
    @State private var progressHistoryByItemID: [String: [ProgressHistoryEntry]] = [:]
    @State private var favoriteItemIDs: Set<String> = []
    @State private var recentActivityByItemID: [String: Date] = [:]
    @State private var isTimelineScrubbing = false
    @State private var scrubPreviewSeconds: TimeInterval?
    @State private var progressHydrationTask: Task<Void, Never>?

    var body: some View {
        var view = AnyView(
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    NavigationSplitView(columnVisibility: $splitVisibility) {
                        sidebarView
                    } content: {
                        itemListView
                    } detail: {
                        detailView
                            .navigationSplitViewColumnWidth(min: 390, ideal: 430, max: 640)
                    }
                    .navigationSplitViewStyle(.balanced)
                    .animation(.easeInOut(duration: 0.24), value: showingNowPlaying)

                    Divider()

                    bottomPlayerBar
                }
                .onAppear {
                    updateSplitVisibility(for: geometry.size.width)
                }
                .onChange(of: geometry.size.width, perform: { newWidth in
                    updateSplitVisibility(for: newWidth)
                })
            }
            .frame(minWidth: 980, minHeight: 620)
        )

        view = AnyView(view.toolbar {
            ToolbarItem(placement: .automatic) {
                Menu(viewModel.isAuthenticated ? "Connected" : "Disconnected") {
                    Label(
                        viewModel.isAuthenticated ? "Status: Connected" : "Status: Disconnected",
                        systemImage: viewModel.isAuthenticated ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(viewModel.isAuthenticated ? .green : .secondary)

                    Text("Server: \(viewModel.serverAddressDisplay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Button("Connect New Server…") {
                        viewModel.errorMessage = nil
                        viewModel.isConnecting = false
                        showingServerSheet = true
                    }

                    Button("Logout", role: .destructive) {
                        Task {
                            await handleLogout()
                        }
                    }
                    .disabled(!viewModel.isAuthenticated)
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    if viewModel.isProgressSyncing {
                        Label("Sync in progress…", systemImage: "arrow.triangle.2.circlepath")
                    } else if let last = viewModel.lastProgressSyncAt {
                        Label("Last sync: \(formattedSyncTimestamp(last))", systemImage: "checkmark.circle")
                    } else {
                        Label("No sync yet", systemImage: "clock")
                    }

                    Divider()

                    Button("Download Progress") {
                        Task { await manualDownloadProgress() }
                    }
                    .disabled(progressSyncTargetItem == nil || !viewModel.isAuthenticated)

                    Button("Upload Progress") {
                        Task { await manualUploadProgress() }
                    }
                    .disabled(progressSyncTargetItem == nil || !viewModel.isAuthenticated)

                    Divider()

                    if let item = progressSyncTargetItem {
                        let entries = recentHistory(for: item.id, limit: 8)
                        if entries.isEmpty {
                            Text("No history for this item")
                                .foregroundStyle(.secondary)
                        } else {
                            Menu("Progress History (\(entries.count))") {
                                ForEach(entries) { entry in
                                    Button(
                                        "\(formattedClock(entry.positionSeconds)) • \(entry.source.rawValue) • \(formattedHistoryTimestamp(entry.occurredAt))"
                                    ) {
                                        restoreProgress(from: entry)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        viewModel.isProgressSyncing ? "Syncing" : "Synced",
                        systemImage: viewModel.isProgressSyncing ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill"
                    )
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu("Settings") {
                    Button("Open Settings…") {
                        openSettingsWindow(tab: .playback)
                    }

                    Divider()

                    Menu("Skip Backward by configured interval: \(Int(preferences.skipBackwardSeconds))s") {
                        ForEach([10.0, 15.0, 30.0, 45.0, 60.0], id: \.self) { seconds in
                            Button {
                                preferences.skipBackwardSeconds = seconds
                            } label: {
                                if Int(preferences.skipBackwardSeconds) == Int(seconds) {
                                    Label("\(Int(seconds))s", systemImage: "checkmark")
                                } else {
                                    Text("\(Int(seconds))s")
                                }
                            }
                        }
                    }

                    Menu("Skip Forward by configured interval: \(Int(preferences.skipForwardSeconds))s") {
                        ForEach([10.0, 15.0, 30.0, 45.0, 60.0], id: \.self) { seconds in
                            Button {
                                preferences.skipForwardSeconds = seconds
                            } label: {
                                if Int(preferences.skipForwardSeconds) == Int(seconds) {
                                    Label("\(Int(seconds))s", systemImage: "checkmark")
                                } else {
                                    Text("\(Int(seconds))s")
                                }
                            }
                        }
                    }

                    Divider()

                    Text("Shortcuts")
                    Text("Backward (configured): \(shortcutDisplay(for: .skipBackwardConfiguredInterval))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Forward (configured): \(shortcutDisplay(for: .skipForwardConfiguredInterval))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Backward (1s): \(shortcutDisplay(for: .skipBackwardOneSecond))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Forward (1s): \(shortcutDisplay(for: .skipForwardOneSecond))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Play/Pause: \(shortcutDisplay(for: .playPauseToggle))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Previous Chapter: \(shortcutDisplay(for: .previousChapter))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Next Chapter: \(shortcutDisplay(for: .nextChapter))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Configure Shortcuts in Settings…") {
                        openSettingsWindow(tab: .shortcuts)
                    }
                }
            }
        })

        view = AnyView(view.sheet(isPresented: $showingServerSheet) {
            serverSheet
        })

        view = AnyView(view.task {
            await viewModel.bootstrap()
            loadLocalPlaybackMetadata()
            showingServerSheet = !viewModel.isAuthenticated
            if viewModel.selectedLibraryID == nil {
                viewModel.selectedLibraryID = viewModel.libraries.first?.id
            }
            if let selectedLibraryID = viewModel.selectedLibraryID, browseTabByLibraryID[selectedLibraryID] == nil {
                browseTabByLibraryID[selectedLibraryID] = .books
            }
            if currentBrowseTab == .books {
                selectedItemID = browsedItems.first?.id
                selectedGroupID = nil
            } else {
                selectedGroupID = displayedBrowseGroups.first?.id
                selectedItemID = nil
            }
            configurePlayerObservers()
            configureKeyboardMonitor()
            updateNowPlaying()
            Task {
                await viewModel.refreshDetailsForSelectedItem(itemID: selectedItemID)
                await syncSelectedItemProgressFromServer()
                scheduleProgressHydration()
                await preloadChaptersForSelectedItem(adoptForPlayback: activeItemID == nil)
                await preloadCoverForSelectedItem()
                await preloadCoverForPlaybackItem()
            }
        })

        view = AnyView(view.onDisappear {
            teardownPlayerObservers()
            teardownKeyboardMonitor()
            progressHydrationTask?.cancel()
            progressHydrationTask = nil
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            isPlaying = false
            if let activeItemID {
                Task {
                    _ = await viewModel.recordPlaybackProgress(
                        itemID: activeItemID,
                        positionSeconds: totalDuration,
                        durationSeconds: totalDuration > 0 ? totalDuration : nil,
                        trigger: .stop
                    )
                }
            }
            updateNowPlaying()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushProgressToServer(trigger: .quit)
        })

        view = AnyView(view.onChange(of: viewModel.selectedLibraryID, perform: { _ in
            if currentBrowseTab == .books {
                selectedItemID = browsedItems.first?.id
                selectedGroupID = nil
            } else {
                selectedGroupID = displayedBrowseGroups.first?.id
                selectedItemID = nil
            }
            elapsedSeconds = 0
            isPlaying = false
            updateNowPlaying()
            scheduleProgressHydration()
        }))

        view = AnyView(view.onChange(of: selectedItemID, perform: { _ in
            if activeItemID == nil || activeItemID == selectedItemID {
                elapsedSeconds = 0
                playbackChapters = []
                showingNowPlaying = false
                updateNowPlaying()
            }
            Task {
                await viewModel.refreshDetailsForSelectedItem(itemID: selectedItemID)
                await syncSelectedItemProgressFromServer()
                await preloadChaptersForSelectedItem(adoptForPlayback: activeItemID == nil || activeItemID == selectedItemID)
                await preloadCoverForSelectedItem()
            }
        }))

        view = AnyView(view.onChange(of: viewModel.displayedItems.map(\.id), perform: { _ in
            scheduleProgressHydration()
        }))

        view = AnyView(view.onChange(of: playbackDisplayItem?.id, perform: { _ in
            Task {
                await preloadCoverForPlaybackItem()
            }
        }))

        view = AnyView(view.onChange(of: showingNowPlaying, perform: { isShowing in
            if !isShowing {
                nowPlayingDismissDragOffset = 0
            }
        }))

        view = AnyView(view.onChange(of: playbackSpeed, perform: { newSpeed in
            if isPlaying {
                player.rate = Float(newSpeed)
            }
            updateNowPlaying()
        }))

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaPlay)) { _ in
            play()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaPause)) { _ in
            pause()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaTogglePlayPause)) { _ in
            isPlaying ? pause() : play()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaSkipBackward)) { _ in
            skipBackward15()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaSkipForward)) { _ in
            skipForward30()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaSkipBackwardOneSecond)) { _ in
            skipBackwardOneSecond()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaSkipForwardOneSecond)) { _ in
            skipForwardOneSecond()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaPreviousChapter)) { _ in
            previousChapter()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absMediaNextChapter)) { _ in
            nextChapter()
        })

        view = AnyView(view.alert("Connection Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        })

        return view
    }

    private var sidebarView: some View {
        List {
            ForEach(viewModel.libraries) { library in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedLibraryIDs.contains(library.id) },
                        set: { expanded in
                            if expanded {
                                expandedLibraryIDs.insert(library.id)
                            } else {
                                expandedLibraryIDs.remove(library.id)
                            }
                        }
                    )
                ) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(libraryBrowseTabs, id: \.rawValue) { tab in
                            Button(tab.rawValue) {
                                selectLibrary(libraryID: library.id, browseTab: tab)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(currentBrowseTab(for: library.id) == tab ? .accentColor : .gray.opacity(0.32))
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        Label(library.name, systemImage: "books.vertical")
                        Spacer(minLength: 8)
                        if viewModel.selectedLibraryID == library.id {
                            Text(currentBrowseTab(for: library.id).rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !expandedLibraryIDs.contains(library.id) {
                            expandedLibraryIDs.insert(library.id)
                        }
                        if viewModel.selectedLibraryID != library.id {
                            selectLibrary(libraryID: library.id, browseTab: currentBrowseTab(for: library.id))
                        }
                    }
                }
                .disclosureGroupStyle(.automatic)
            }
        }
        .navigationTitle("Libraries")
    }

    private var itemListView: some View {
        VStack(spacing: 0) {
            itemListHeader
            Divider()
            itemListContent
        }
        .searchable(text: $searchText, prompt: "Search audiobooks")
        .searchSuggestions {
            searchSuggestionsView
        }
        .onChange(of: searchText, perform: { query in
            Task {
                await viewModel.search(query: query)
                refreshSelectionForCurrentBrowseContext()
            }
        })
        .onChange(of: itemFilter, perform: { _ in
            refreshSelectionForCurrentBrowseContext()
        })
        .onChange(of: bookSortOption, perform: { _ in
            refreshSelectionForCurrentBrowseContext()
        })
        .onChange(of: groupSortOption, perform: { _ in
            refreshSelectionForCurrentBrowseContext()
        })
        .navigationTitle(itemListNavigationTitle)
    }

    @ViewBuilder
    private var searchSuggestionsView: some View {
        if !trimmedSearchText.isEmpty {
            if !searchPreviewBooks.isEmpty {
                Section("Books") {
                    ForEach(searchPreviewBooks) { item in
                        Button {
                            selectedItemID = item.id
                            selectedGroupID = nil
                            searchText = item.title
                        } label: {
                            HStack(spacing: 8) {
                                searchSuggestionCover(for: item)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .lineLimit(1)
                                    if let author = item.author, !author.isEmpty {
                                        Text("by \(author)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !searchPreviewSeries.isEmpty {
                Section("Series") {
                    ForEach(searchPreviewSeries) { series in
                        Button {
                            searchText = series.name
                            selectCurrentLibraryBrowseTab(.series)
                            selectedGroupID = series.id
                            selectedItemID = nil
                        } label: {
                            HStack {
                                Text(series.name)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(series.count) books")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !searchPreviewNarrators.isEmpty {
                Section("Narrators") {
                    ForEach(searchPreviewNarrators) { narrator in
                        Button {
                            searchText = narrator.name
                            selectCurrentLibraryBrowseTab(.narrators)
                            selectedGroupID = narrator.id
                            selectedItemID = nil
                        } label: {
                            HStack {
                                Image(systemName: "person.wave.2")
                                    .foregroundStyle(.secondary)
                                Text(narrator.name)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(narrator.count) books")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func searchSuggestionCover(for item: ABSCore.LibraryItem) -> some View {
        if let cover = coverImagesByItemID[item.id] {
            Image(nsImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "book.closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    Task { await preloadCoverForItemID(item.id) }
                }
        }
    }

    private var itemListHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Sort")
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: sortPickerSelectionBinding) {
                    if currentBrowseTab == .books {
                        ForEach(BookSortOption.allCases) { option in
                            Text(option.rawValue).tag(option.rawValue)
                        }
                    } else {
                        ForEach(GroupSortOption.allCases) { option in
                            Text(option.rawValue).tag(option.rawValue)
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack(spacing: 6) {
                Text("Filter")
                    .foregroundStyle(.secondary)
                Picker("Filter", selection: $itemFilter) {
                    ForEach(ItemFilterOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var sortPickerSelectionBinding: Binding<String> {
        Binding<String>(
            get: {
                currentBrowseTab == .books ? bookSortOption.rawValue : groupSortOption.rawValue
            },
            set: { newValue in
                if currentBrowseTab == .books {
                    if let option = BookSortOption(rawValue: newValue) {
                        bookSortOption = option
                    }
                } else {
                    if let option = GroupSortOption(rawValue: newValue) {
                        groupSortOption = option
                    }
                }
            }
        )
    }

    private var itemListNavigationTitle: String {
        "\(currentBrowseTab.rawValue) (\(visibleItemCount))"
    }

    private var visibleItemCount: Int {
        if currentBrowseTab == .books {
            return browsedItems.count
        }

        return displayedBrowseGroups.count
    }

    @ViewBuilder
    private var itemListContent: some View {
        if currentBrowseTab == .books {
            booksListView
        } else {
            groupListView
        }
    }

    private var booksListView: some View {
        List(browsedItems, selection: $selectedItemID) { item in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                    if let author = item.author {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if hasSavedProgress(for: item.id) {
                        Text("Current position at \(formattedClock(savedProgress(for: item.id)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if favoriteItemIDs.contains(item.id) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.vertical, 2)
            .tag(item.id)
            .contextMenu {
                Button("Start from Beginning") {
                    selectedItemID = item.id
                    play(item: item, startPosition: 0, forceReload: true)
                }

                if hasSavedProgress(for: item.id) {
                    let resumePosition = savedProgress(for: item.id)
                    Button("Resume at \(formattedClock(resumePosition))") {
                        selectedItemID = item.id
                        play(item: item, startPosition: resumePosition)
                    }
                }

                Divider()

                Button(favoriteItemIDs.contains(item.id) ? "Unfavorite" : "Favorite") {
                    toggleFavorite(itemID: item.id)
                }

                Button("Clear Progress") {
                    clearSavedProgressEverywhere(item: item)
                }
                .disabled(!hasSavedProgress(for: item.id))
            }
            .onTapGesture(count: 2) {
                selectedItemID = item.id
                let resumePosition = savedProgress(for: item.id)
                play(item: item, startPosition: resumePosition > 0 ? resumePosition : nil)
            }
        }
    }

    private var groupListView: some View {
        List(displayedBrowseGroups, selection: $selectedGroupID) { group in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.headline)
                    if let subtitle = group.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text("\(group.itemCount)")
                    .font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.16))
                    .clipShape(Capsule())
            }
            .padding(.vertical, 2)
            .tag(group.id)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if showingNowPlaying, let item = playbackDisplayItem {
            nowPlayingDetailView(item: item)
                .navigationTitle("Now Playing")
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if currentBrowseTab != .books, let group = selectedGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.largeTitle.weight(.semibold))
                        if let subtitle = group.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(group.itemCount) \(group.itemCount == 1 ? "book" : "books")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    ForEach(Array(seriesSectionsForGroupDetail(items: group.items).enumerated()), id: \.element.id) { index, section in
                        if index > 0 {
                            Divider()
                                .padding(.vertical, 2)
                        }

                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(section.items) { item in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    if let sequence = seriesSequenceDisplayValue(for: item) {
                                        Text("Book \(sequence)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(item.title)
                                        .font(.headline)
                                    if let author = item.author {
                                        Text(author)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    play(item: item, startPosition: savedProgress(for: item.id))
                                } label: {
                                    Image(systemName: "play.fill")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle("Details")
            .transition(.opacity)
        } else if let item = selectedItem {
            GeometryReader { detailGeometry in
                let horizontalPadding = detailHorizontalPadding(for: detailGeometry.size.width)
                ScrollView {
                    VStack(spacing: 18) {
                        if let image = coverImagesByItemID[item.id] {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(LinearGradient(colors: [.indigo.opacity(0.55), .orange.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay {
                                    Image(systemName: "book.closed.fill")
                                        .font(.system(size: 46, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .frame(maxWidth: 320)
                                .aspectRatio(1, contentMode: .fit)
                        }

                        VStack(spacing: 8) {
                            Text(item.title)
                                .font(.largeTitle)
                                .lineLimit(3)
                                .minimumScaleFactor(0.75)
                                .multilineTextAlignment(.center)
                            if let author = item.author {
                                Text(author)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                    .multilineTextAlignment(.center)
                            }

                            Text(positionSummary(for: item))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        Button {
                            let resumePosition = savedProgress(for: item.id)
                            play(item: item, startPosition: resumePosition > 0 ? resumePosition : nil)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            detailRow(title: "Duration", value: formattedDuration(item.duration))
                            detailRow(title: "Chapters", value: "\(item.chapters.count)")
                            detailRow(title: "Library", value: selectedLibraryName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Details")
            .transition(.opacity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "book")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(viewModel.isAuthenticated ? "Select an audiobook" : "Connect a server")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if !viewModel.isAuthenticated {
                    Button("Add Server") {
                        showingServerSheet = true
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nowPlayingDetailView(item: ABSCore.LibraryItem) -> some View {
        GeometryReader { geometry in
            let minChapterListHeight: CGFloat = nowPlayingChapterListUserResized ? 120 : 56
            let maxChapterListHeight = max(minChapterListHeight, geometry.size.height * 0.9)
            let autoChapterListHeight = min(
                max(geometry.size.height * 0.28, minChapterListHeight),
                maxChapterListHeight
            )
            let chapterListHeight = nowPlayingChapterListUserResized
                ? min(max(nowPlayingChapterListHeight, minChapterListHeight), maxChapterListHeight)
                : autoChapterListHeight

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: nowPlayingDismissHandleHovered ? 10 : 3)
                        .fill(Color.secondary.opacity(nowPlayingDismissHandleHovered ? 0.28 : 0.45))
                        .frame(
                            width: nowPlayingDismissHandleHovered ? 24 : 58,
                            height: nowPlayingDismissHandleHovered ? 20 : 6
                        )
                    if nowPlayingDismissHandleHovered {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .padding(.top, 6)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        nowPlayingDismissHandleHovered = hovering
                    }
                }
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingNowPlaying = false
                        nowPlayingDismissDragOffset = 0
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            nowPlayingDismissDragOffset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            let shouldDismiss = value.translation.height > 120
                            if shouldDismiss {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showingNowPlaying = false
                                    nowPlayingDismissDragOffset = 0
                                }
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    nowPlayingDismissDragOffset = 0
                                }
                            }
                        }
                )

                nowPlayingArtwork(item: item)
                    .layoutPriority(2)

                VStack(spacing: 6) {
                    Text(item.title)
                        .font(.title3)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(currentChapterTitle)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }

                nowPlayingProgressSection
                nowPlayingTransportSection

                if currentChapters.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    nowPlayingChapterList(
                        chapterListHeight: chapterListHeight,
                        minHeight: minChapterListHeight,
                        maxHeight: maxChapterListHeight
                    )
                    .layoutPriority(0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .offset(y: nowPlayingDismissDragOffset)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.85), value: nowPlayingDismissDragOffset)
            .onChange(of: geometry.size.height, perform: { _ in
                // Keep user-selected size stable while ensuring it remains valid
                // when the window is resized. Avoid touching height during an
                // active drag to prevent jitter.
                guard nowPlayingChapterListUserResized else { return }
                guard nowPlayingChapterListDragStart == nil else { return }
                nowPlayingChapterListHeight = min(
                    max(nowPlayingChapterListHeight, minChapterListHeight),
                    maxChapterListHeight
                )
            })
        }
    }

    @ViewBuilder
    private func nowPlayingArtwork(item: ABSCore.LibraryItem) -> some View {
        if let coverImage = playbackCoverImage {
            Image(nsImage: coverImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 10)
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.indigo.opacity(0.55), .orange.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 48, weight: .semibold))
                        Text(item.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 14)
                    }
                    .foregroundStyle(.white)
                }
                .frame(maxWidth: 360)
                .aspectRatio(1, contentMode: .fit)
                .padding(.top, 10)
        }
    }

    private var nowPlayingProgressSection: some View {
        VStack(spacing: 10) {
            PrecisionScrubber(
                value: Binding(
                    get: { chapterElapsedSeconds },
                    set: { newValue in
                        let start = currentChapterRange.lowerBound
                        seek(to: start + newValue)
                    }
                ),
                range: 0...max(currentChapterDuration, 1),
                markerValues: [],
                showsMarkers: false,
                snapToMarkers: false,
                snapTolerance: 0
            )

            PrecisionScrubber(
                value: Binding(
                    get: { elapsedSeconds },
                    set: { newValue in
                        elapsedSeconds = newValue
                    }
                ),
                range: 0...max(totalDuration, 1),
                markerValues: chapterMarkerTimes,
                showsMarkers: true,
                snapToMarkers: true,
                snapTolerance: chapterSnapToleranceSeconds,
                onEditingChanged: { editing in
                    isTimelineScrubbing = editing
                    if !editing {
                        seek(to: elapsedSeconds)
                    }
                }
            )

            HStack {
                Text(formattedClock(elapsedSeconds))
                Spacer()
                Text(formattedClock(totalDuration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 520)
    }

    private var nowPlayingTransportSection: some View {
        HStack(spacing: 26) {
            Button {
                seek(to: elapsedSeconds - preferences.skipBackwardSeconds)
            } label: {
                Label("\(Int(preferences.skipBackwardSeconds))", systemImage: "gobackward")
            }
            .buttonStyle(.borderless)

            Button {
                isPlaying ? pause() : play()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
            }
            .buttonStyle(.plain)

            Button {
                seek(to: elapsedSeconds + preferences.skipForwardSeconds)
            } label: {
                Label("\(Int(preferences.skipForwardSeconds))", systemImage: "goforward")
            }
            .buttonStyle(.borderless)
        }
        .labelStyle(.titleAndIcon)
    }

    private func nowPlayingChapterList(chapterListHeight: CGFloat, minHeight: CGFloat, maxHeight: CGFloat) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Color.clear
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 44, height: 5)
            }
            .frame(width: 140, height: 28)
            .contentShape(Rectangle())
            .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // On first interaction, lock manual sizing to the
                            // currently rendered size so we don't jump.
                            if !nowPlayingChapterListUserResized {
                                nowPlayingChapterListUserResized = true
                                nowPlayingChapterListHeight = chapterListHeight
                            }
                            if nowPlayingChapterListDragStart == nil {
                                nowPlayingChapterListDragStart = chapterListHeight
                            }
                            let start = nowPlayingChapterListDragStart ?? chapterListHeight
                            nowPlayingChapterListHeight = min(max(start - value.translation.height, minHeight), maxHeight)
                        }
                        .onEnded { _ in
                            nowPlayingChapterListDragStart = nil
                        }
            )
            .padding(.top, 2)

            HStack {
                Text("Chapters")
                    .font(.headline)
                Spacer()
            }

            let chapterScroll = ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(currentChapters.enumerated()), id: \.element.id) { index, chapter in
                        nowPlayingChapterRow(index: index, chapter: chapter)
                    }
                }
            }

            chapterScroll.frame(height: chapterListHeight)
        }
        .frame(maxWidth: 520)
    }

    private func nowPlayingChapterRow(index: Int, chapter: ABSCore.Chapter) -> some View {
        Button {
            seek(to: chapter.startTime)
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1).")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title)
                        .lineLimit(1)
                    Text(formattedClock(chapter.startTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if currentChapterIndex == index {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(currentChapterIndex == index ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var bottomPlayerBar: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: bottomExpandHandleHovered ? 10 : 3)
                    .fill(Color.secondary.opacity(bottomExpandHandleHovered ? 0.28 : 0.45))
                    .frame(
                        width: bottomExpandHandleHovered ? 24 : 58,
                        height: bottomExpandHandleHovered ? 20 : 6
                    )
                if bottomExpandHandleHovered {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .frame(width: 140, height: 24)
            .offset(y: bottomExpandDragOffset)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    bottomExpandHandleHovered = hovering
                }
            }
            .onTapGesture {
                openNowPlayingPanel()
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        bottomExpandDragOffset = min(0, value.translation.height)
                    }
                    .onEnded { value in
                        let shouldOpen = value.translation.height < -70
                        if shouldOpen {
                            openNowPlayingPanel()
                        }
                        withAnimation(.easeOut(duration: 0.2)) {
                            bottomExpandDragOffset = 0
                        }
                    }
            )

            ZStack(alignment: .leading) {
                HStack(spacing: 12) {
                    Text(formattedClock(elapsedSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)

                    PrecisionScrubber(
                        value: Binding(
                            get: { elapsedSeconds },
                            set: { newValue in
                                elapsedSeconds = newValue
                                if isTimelineScrubbing {
                                    scrubPreviewSeconds = newValue
                                }
                            }
                        ),
                        range: 0...max(totalDuration, 1),
                        markerValues: chapterMarkerTimes,
                        showsMarkers: true,
                        snapToMarkers: true,
                        snapTolerance: chapterSnapToleranceSeconds,
                        onEditingChanged: { editing in
                            isTimelineScrubbing = editing
                            scrubPreviewSeconds = editing ? elapsedSeconds : nil
                            if !editing {
                                seek(to: elapsedSeconds)
                            }
                        }
                    )

                    Text(formattedClock(totalDuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                if let scrubTitle = scrubPreviewChapterTitle {
                    Text(scrubTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 0)
                        .offset(x: 0, y: -16)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 16) {
                Text(playbackDisplayItem?.title ?? "No selection")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        seek(to: elapsedSeconds - preferences.skipBackwardSeconds)
                    } label: {
                        Image(systemName: "gobackward")
                    }
                    .buttonStyle(.borderless)
                    .disabled(playbackDisplayItem == nil)

                    Button {
                        isPlaying ? pause() : play()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(playbackDisplayItem == nil)

                    Button {
                        seek(to: elapsedSeconds + preferences.skipForwardSeconds)
                    } label: {
                        Image(systemName: "goforward")
                    }
                    .buttonStyle(.borderless)
                    .disabled(playbackDisplayItem == nil)
                }

                Spacer()

                HStack(spacing: 8) {
                    Menu("Chapters") {
                        if currentChapters.isEmpty {
                            Text("No chapters")
                        } else {
                            ForEach(Array(currentChapters.enumerated()), id: \.element.id) { index, chapter in
                                Button("\(index + 1). \(chapter.title)") {
                                    seek(to: chapter.startTime)
                                }
                            }
                        }
                    }
                    .disabled(currentChapters.isEmpty)

                    Text("Speed")
                        .foregroundStyle(.secondary)
                    Picker("Speed", selection: $playbackSpeed) {
                        Text("0.5x").tag(0.5)
                        Text("1.0x").tag(1.0)
                        Text("1.5x").tag(1.5)
                        Text("2.0x").tag(2.0)
                        Text("3.0x").tag(3.0)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            openNowPlayingPanel()
        }
    }

    private var serverSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Audiobookshelf")
                .font(.title3)
                .bold()

            HStack(spacing: 8) {
                Picker("Protocol", selection: $viewModel.serverScheme) {
                    Text("http").tag("http")
                    Text("https").tag("https")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 92)

                TextField("IP or Hostname", text: $viewModel.serverHost)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.next)

                TextField("Port", text: $viewModel.serverPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .submitLabel(.next)
            }

            TextField("Username", text: $viewModel.username)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.next)

            SecureField("Password", text: $viewModel.password)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.go)
                .onSubmit {
                    attemptServerConnect()
                }

            if let error = viewModel.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    viewModel.errorMessage = nil
                    viewModel.isConnecting = false
                    showingServerSheet = false
                }

                Spacer()

                Button(viewModel.isConnecting ? "Connecting..." : "Connect") {
                    attemptServerConnect()
                }
                .disabled(viewModel.isConnecting)
            }
        }
        .onSubmit {
            attemptServerConnect()
        }
        .padding(20)
        .frame(minWidth: 520)
    }

    private var selectedItem: ABSCore.LibraryItem? {
        guard let selectedItemID else { return nil }
        return browsedItems.first { $0.id == selectedItemID }
            ?? viewModel.displayedItems.first { $0.id == selectedItemID }
    }

    private var selectedGroup: BrowseGroup? {
        guard let selectedGroupID else { return nil }
        return displayedBrowseGroups.first { $0.id == selectedGroupID }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchPreviewSourceItems: [ABSCore.LibraryItem] {
        viewModel.currentLibraryItems
    }

    private var searchPreviewBooks: [ABSCore.LibraryItem] {
        let query = trimmedSearchText
        guard !query.isEmpty else { return [] }
        return searchPreviewSourceItems
            .filter { item in
                item.title.localizedCaseInsensitiveContains(query)
                    || (item.author?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(searchSuggestionLimit)
            .map { $0 }
    }

    private var searchPreviewSeries: [SearchSeriesSuggestion] {
        let query = trimmedSearchText
        guard !query.isEmpty else { return [] }

        var grouped: [String: Set<String>] = [:]
        for item in searchPreviewSourceItems {
            let series = inferredSeriesName(for: item)
            guard series != "Unknown Series" else { continue }
            guard series.localizedCaseInsensitiveContains(query) else { continue }
            grouped[series, default: []].insert(item.id)
        }

        return grouped
            .map { SearchSeriesSuggestion(id: $0.key, name: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count == $1.count {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.count > $1.count
            }
            .prefix(searchSuggestionLimit)
            .map { $0 }
    }

    private var searchPreviewNarrators: [SearchNarratorSuggestion] {
        let query = trimmedSearchText
        guard !query.isEmpty else { return [] }

        var grouped: [String: Set<String>] = [:]
        for item in searchPreviewSourceItems {
            guard let narrator = preferredNarrator(for: item), !narrator.isEmpty else { continue }
            guard narrator.localizedCaseInsensitiveContains(query) else { continue }
            grouped[narrator, default: []].insert(item.id)
        }

        return grouped
            .map { SearchNarratorSuggestion(id: $0.key, name: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count == $1.count {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.count > $1.count
            }
            .prefix(searchSuggestionLimit)
            .map { $0 }
    }

    private var browsedItems: [ABSCore.LibraryItem] {
        let items = filteredBaseItems
        switch currentBrowseTab {
        case .books:
            return sortedBooks(items)
        case .authors:
            return sortedBooks(items.sorted {
                let lhsAuthor = ($0.author ?? "Unknown Author").localizedLowercase
                let rhsAuthor = ($1.author ?? "Unknown Author").localizedLowercase
                if lhsAuthor == rhsAuthor {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhsAuthor < rhsAuthor
            })
        case .narrators:
            // ABS model currently does not expose narrator on LibraryItem.
            // Fallback to author ordering until narrator metadata is surfaced.
            return sortedBooks(items.sorted {
                let lhsNarrator = ($0.author ?? "Unknown Narrator").localizedLowercase
                let rhsNarrator = ($1.author ?? "Unknown Narrator").localizedLowercase
                if lhsNarrator == rhsNarrator {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhsNarrator < rhsNarrator
            })
        case .series:
            return sortedBooks(items.sorted {
                let lhsSeries = inferredSeriesName(for: $0).localizedLowercase
                let rhsSeries = inferredSeriesName(for: $1).localizedLowercase
                if lhsSeries == rhsSeries {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhsSeries < rhsSeries
            })
        case .collections:
            return sortedBooks(items.sorted {
                let lhsCollection = inferredCollectionName(for: $0).localizedLowercase
                let rhsCollection = inferredCollectionName(for: $1).localizedLowercase
                if lhsCollection == rhsCollection {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhsCollection < rhsCollection
            })
        case .continueListening:
            return sortedBooks(items
                .filter { item in
                    let progress = savedProgress(for: item.id)
                    guard progress > 0 else { return false }
                    if let duration = item.duration, duration > 0 {
                        return progress < (duration - 1)
                    }
                    return true
                }
                .sorted {
                    let lhsDate = recentActivityByItemID[$0.id] ?? .distantPast
                    let rhsDate = recentActivityByItemID[$1.id] ?? .distantPast
                    if lhsDate == rhsDate {
                        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                    return lhsDate > rhsDate
                })
        case .recent:
            return sortedBooks(items.sorted {
                let lhsDate = recentActivityByItemID[$0.id] ?? .distantPast
                let rhsDate = recentActivityByItemID[$1.id] ?? .distantPast
                if lhsDate == rhsDate {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhsDate > rhsDate
            })
        case .favorites:
            return sortedBooks(items
                .filter { favoriteItemIDs.contains($0.id) }
                .sorted {
                    let lhsDate = recentActivityByItemID[$0.id] ?? .distantPast
                    let rhsDate = recentActivityByItemID[$1.id] ?? .distantPast
                    if lhsDate == rhsDate {
                        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                    return lhsDate > rhsDate
                })
        }
    }

    private var currentBrowseTab: LibraryBrowseTab {
        guard let selectedLibraryID = viewModel.selectedLibraryID else { return .books }
        return browseTabByLibraryID[selectedLibraryID] ?? .books
    }

    private var browseGroups: [BrowseGroup] {
        let items = filteredBaseItems
        switch currentBrowseTab {
        case .books:
            return []
        case .authors:
            return groupedRowsForPeople(items, names: authorNames(for:), unknownLabel: "Unknown Author")
        case .narrators:
            return groupedRows(from: items, key: { (preferredNarrator(for: $0) ?? "Unknown Narrator").trimmedForGrouping }, subtitle: nil)
        case .series:
            return groupedRows(from: items, key: { inferredSeriesName(for: $0) }, subtitle: nil)
        case .collections:
            return groupedRowsForCollections(items)
        case .favorites:
            let filtered = items.filter { favoriteItemIDs.contains($0.id) }
            return groupedRows(from: filtered, key: { ($0.author?.trimmedForGrouping ?? "Unknown Author") }) { groupItems in
                let favoriteCount = groupItems.filter { favoriteItemIDs.contains($0.id) }.count
                return "\(favoriteCount) favorites"
            }
        case .continueListening:
            let filtered = items.filter { item in
                let progress = savedProgress(for: item.id)
                guard progress > 0 else { return false }
                if let duration = item.duration, duration > 0 {
                    return progress < (duration - 1)
                }
                return true
            }
            return groupedRows(from: filtered, key: continueBucketName(for:))
        case .recent:
            let filtered = items.filter { recentActivityByItemID[$0.id] != nil }
            return groupedRows(from: filtered, key: recentBucketName(for:))
        }
    }

    private var displayedBrowseGroups: [BrowseGroup] {
        sortedGroups(browseGroups)
    }

    private func currentBrowseTab(for libraryID: String) -> LibraryBrowseTab {
        browseTabByLibraryID[libraryID] ?? .books
    }

    private func selectLibrary(libraryID: String, browseTab: LibraryBrowseTab) {
        browseTabByLibraryID[libraryID] = browseTab
        viewModel.selectedLibraryID = libraryID

        Task {
            await viewModel.selectLibrary(id: libraryID)
            if browseTab == .books {
                selectedItemID = browsedItems.first?.id
                selectedGroupID = nil
            } else {
                selectedGroupID = displayedBrowseGroups.first?.id
                selectedItemID = nil
            }
        }
    }

    private func selectCurrentLibraryBrowseTab(_ browseTab: LibraryBrowseTab) {
        guard let currentLibraryID = viewModel.selectedLibraryID else { return }
        browseTabByLibraryID[currentLibraryID] = browseTab
    }

    private var filteredBaseItems: [ABSCore.LibraryItem] {
        let items = viewModel.displayedItems
        switch itemFilter {
        case .all:
            return items
        case .inProgress:
            return items.filter { item in
                let progress = savedProgress(for: item.id)
                guard progress > 0 else { return false }
                if let duration = item.duration, duration > 0 {
                    return progress < (duration - 1)
                }
                return true
            }
        case .favorites:
            return items.filter { favoriteItemIDs.contains($0.id) }
        }
    }

    private func sortedBooks(_ items: [ABSCore.LibraryItem]) -> [ABSCore.LibraryItem] {
        switch bookSortOption {
        case .alphabetical:
            return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:
            return items.sorted {
                let lhsAuthor = ($0.author ?? "Unknown Author").localizedLowercase
                let rhsAuthor = ($1.author ?? "Unknown Author").localizedLowercase
                if lhsAuthor == rhsAuthor {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhsAuthor < rhsAuthor
            }
        case .durationLongest:
            return items.sorted {
                let lhs = $0.duration ?? 0
                let rhs = $1.duration ?? 0
                if lhs == rhs {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhs > rhs
            }
        case .durationShortest:
            return items.sorted {
                let lhs = $0.duration ?? .greatestFiniteMagnitude
                let rhs = $1.duration ?? .greatestFiniteMagnitude
                if lhs == rhs {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhs < rhs
            }
        case .recentlyActive:
            return items.sorted {
                let lhs = recentActivityByItemID[$0.id] ?? .distantPast
                let rhs = recentActivityByItemID[$1.id] ?? .distantPast
                if lhs == rhs {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhs > rhs
            }
        }
    }

    private func sortedGroups(_ groups: [BrowseGroup]) -> [BrowseGroup] {
        switch groupSortOption {
        case .alphabetical:
            return groups.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .bookCountMost:
            return groups.sorted {
                if $0.itemCount == $1.itemCount {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.itemCount > $1.itemCount
            }
        case .bookCountLeast:
            return groups.sorted {
                if $0.itemCount == $1.itemCount {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.itemCount < $1.itemCount
            }
        }
    }

    private func refreshSelectionForCurrentBrowseContext() {
        if currentBrowseTab == .books {
            if selectedItem == nil {
                selectedItemID = browsedItems.first?.id
            }
            selectedGroupID = nil
        } else {
            if selectedGroup == nil {
                selectedGroupID = displayedBrowseGroups.first?.id
            }
            selectedItemID = nil
        }
    }

    private func inferredSeriesName(for item: ABSCore.LibraryItem) -> String {
        if let seriesName = item.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines), !seriesName.isEmpty {
            return normalizedSeriesName(seriesName)
        }

        let title = item.title

        if let range = title.range(of: ", Book ", options: .caseInsensitive) {
            let inferred = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedSeriesName(inferred)
        }

        if let range = title.range(of: " - ") {
            let inferred = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedSeriesName(inferred)
        }

        return "Unknown Series"
    }

    private func normalizedSeriesName(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Unknown Series" }

        // ABS may include sequence in series labels (e.g. "Shadows of the Apt #1").
        // Group by canonical name and keep sequence for ordering separately.
        let stripPatterns = [
            #"(?i)\s*#\s*\d+\s*(,.*)?$"#,
            #"(?i)\s*\(\s*#\s*\d+\s*\)\s*$"#,
            #"(?i)\s*,\s*book\s*\d+\s*$"#
        ]
        for pattern in stripPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value.isEmpty ? "Unknown Series" : value
    }

    private func continueBucketName(for item: ABSCore.LibraryItem) -> String {
        let progress = savedProgress(for: item.id)
        if let duration = item.duration, duration > 0 {
            let ratio = progress / duration
            if ratio >= 0.9 {
                return "Almost Finished"
            }
            if ratio >= 0.5 {
                return "More Than Halfway"
            }
            return "Started"
        }
        return "In Progress"
    }

    private func recentBucketName(for item: ABSCore.LibraryItem) -> String {
        guard let lastActivity = recentActivityByItemID[item.id] else {
            return "Older"
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(lastActivity) {
            return "Today"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()), lastActivity >= weekAgo {
            return "Last 7 Days"
        }
        return "Older"
    }

    private func groupedRows(
        from items: [ABSCore.LibraryItem],
        key: (ABSCore.LibraryItem) -> String,
        subtitle: (([ABSCore.LibraryItem]) -> String?)? = nil
    ) -> [BrowseGroup] {
        let grouped = Dictionary(grouping: items, by: key)
        return grouped
            .map { entry in
                let sortedItems = entry.value.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return BrowseGroup(
                    id: entry.key,
                    title: entry.key,
                    subtitle: subtitle?(sortedItems),
                    itemCount: sortedItems.count,
                    items: sortedItems
                )
            }
            .sorted {
                if $0.itemCount == $1.itemCount {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.itemCount > $1.itemCount
            }
    }

    private func groupedRowsForCollections(_ items: [ABSCore.LibraryItem]) -> [BrowseGroup] {
        var grouped: [String: [ABSCore.LibraryItem]] = [:]
        for item in items {
            let names = collectionNames(for: item)
            for name in names {
                grouped[name, default: []].append(item)
            }
        }

        return grouped
            .map { entry in
                let sortedItems = entry.value.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return BrowseGroup(
                    id: entry.key,
                    title: entry.key,
                    subtitle: nil,
                    itemCount: sortedItems.count,
                    items: sortedItems
                )
            }
            .sorted {
                if $0.itemCount == $1.itemCount {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.itemCount > $1.itemCount
            }
    }

    private func groupedRowsForPeople(
        _ items: [ABSCore.LibraryItem],
        names: (ABSCore.LibraryItem) -> [String],
        unknownLabel: String
    ) -> [BrowseGroup] {
        var grouped: [String: [ABSCore.LibraryItem]] = [:]

        for item in items {
            let personNames = names(item)
            let keys = personNames.isEmpty ? [unknownLabel] : personNames
            for key in keys {
                let cleanedKey = key.trimmedForGrouping
                if !(grouped[cleanedKey]?.contains(where: { $0.id == item.id }) ?? false) {
                    grouped[cleanedKey, default: []].append(item)
                }
            }
        }

        return grouped
            .map { entry in
                let sortedItems = entry.value.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return BrowseGroup(
                    id: entry.key,
                    title: entry.key,
                    subtitle: nil,
                    itemCount: sortedItems.count,
                    items: sortedItems
                )
            }
            .sorted {
                if $0.itemCount == $1.itemCount {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.itemCount > $1.itemCount
            }
    }

    private func inferredCollectionName(for item: ABSCore.LibraryItem) -> String {
        collectionNames(for: item).first ?? "Uncategorized"
    }

    private func collectionNames(for item: ABSCore.LibraryItem) -> [String] {
        let metadataCollections = item.collections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !metadataCollections.isEmpty {
            return metadataCollections
        }

        let metadataTags = item.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !metadataTags.isEmpty {
            return metadataTags
        }

        let metadataGenres = item.genres
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !metadataGenres.isEmpty {
            return metadataGenres
        }

        let series = inferredSeriesName(for: item)
        if series != "Unknown Series" {
            return [series]
        }

        if let author = item.author, !author.isEmpty {
            return [author]
        }

        return ["Uncategorized"]
    }

    private func preferredNarrator(for item: ABSCore.LibraryItem) -> String? {
        if let narrator = item.narrator?.trimmingCharacters(in: .whitespacesAndNewlines), !narrator.isEmpty {
            return narrator
        }
        if let author = item.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            return author
        }
        return nil
    }

    private func authorNames(for item: ABSCore.LibraryItem) -> [String] {
        let metadataAuthors = item.authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !metadataAuthors.isEmpty {
            return metadataAuthors
        }

        guard let author = item.author, !author.isEmpty else {
            return []
        }
        let normalized = author
            .replacingOccurrences(of: " & ", with: ",")
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: ";", with: ",")
        return normalized
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func seriesSectionsForGroupDetail(items: [ABSCore.LibraryItem]) -> [SeriesDetailSection] {
        if currentBrowseTab == .continueListening {
            let sortedByRecentProgress = items.sorted { lhs, rhs in
                let lhsDate = recentActivityByItemID[lhs.id] ?? .distantPast
                let rhsDate = recentActivityByItemID[rhs.id] ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhsDate > rhsDate
            }

            return [
                SeriesDetailSection(
                    id: "continue-started",
                    title: "Started",
                    items: sortedByRecentProgress
                )
            ]
        }

        let grouped = Dictionary(grouping: items) { item -> String in
            let series = inferredSeriesName(for: item)
            return series == "Unknown Series" ? "Standalone" : series
        }

        return grouped
            .map { entry in
                let sortedItems = entry.value.sorted { lhs, rhs in
                    let lhsOrder = inferredSeriesOrder(for: lhs)
                    let rhsOrder = inferredSeriesOrder(for: rhs)
                    if lhsOrder != rhsOrder {
                        return lhsOrder < rhsOrder
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

                return SeriesDetailSection(id: entry.key, title: entry.key, items: sortedItems)
            }
            .sorted { lhs, rhs in
                if lhs.title == "Standalone" { return false }
                if rhs.title == "Standalone" { return true }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func inferredSeriesOrder(for item: ABSCore.LibraryItem) -> Int {
        if let sequence = item.seriesSequence, sequence >= 0 {
            return sequence
        }

        if let seriesName = item.seriesName,
           let parsed = parsedSequence(from: seriesName) {
            return parsed
        }

        let title = item.title
        if let parsed = parsedSequence(from: title) {
            return parsed
        }

        return Int.max
    }

    private func seriesSequenceDisplayValue(for item: ABSCore.LibraryItem) -> Int? {
        if let sequence = item.seriesSequence, sequence >= 0 {
            return sequence
        }

        let inferred = inferredSeriesOrder(for: item)
        return inferred == Int.max ? nil : inferred
    }

    private func parsedSequence(from raw: String) -> Int? {
        let patterns = [
            #"(?i),\s*book\s*(\d+)"#,
            #"(?i)\bbook\s*(\d+)\b"#,
            #"(?i)\bpart\s*(\d+)\b"#,
            #"(?i)#\s*(\d+)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: raw.utf16.count)
            if let match = regex.firstMatch(in: raw, options: [], range: range), match.numberOfRanges > 1,
               let numberRange = Range(match.range(at: 1), in: raw),
               let number = Int(raw[numberRange]) {
                return number
            }
        }

        return nil
    }

    private var selectedLibraryName: String {
        viewModel.libraries.first(where: { $0.id == viewModel.selectedLibraryID })?.name ?? "Unknown"
    }

    private var activePlaybackItem: ABSCore.LibraryItem? {
        guard let activeItemID else { return nil }
        return viewModel.item(withID: activeItemID) ?? nowPlayingItem
    }

    private var playbackDisplayItem: ABSCore.LibraryItem? {
        activePlaybackItem ?? selectedItem
    }

    private var playbackCoverImage: NSImage? {
        guard let itemID = playbackDisplayItem?.id else { return nil }
        return coverImagesByItemID[itemID]
    }

    private var totalDuration: TimeInterval {
        if let playerDuration = player.currentItem?.duration.seconds, playerDuration.isFinite, playerDuration > 0 {
            return playerDuration
        }
        return playbackDisplayItem?.duration ?? 0
    }

    private var currentChapters: [ABSCore.Chapter] {
        let chapters = playbackChapters.isEmpty ? (playbackDisplayItem?.chapters ?? []) : playbackChapters
        return chapters.sorted { $0.startTime < $1.startTime }
    }

    private var currentChapterIndex: Int? {
        let chapters = currentChapters
        guard !chapters.isEmpty else { return nil }

        for (index, chapter) in chapters.enumerated() {
            let end = chapter.endTime ?? .greatestFiniteMagnitude
            if elapsedSeconds >= chapter.startTime && elapsedSeconds < end {
                return index
            }
        }

        return elapsedSeconds >= (chapters.last?.startTime ?? 0) ? max(0, chapters.count - 1) : nil
    }

    private var currentChapterTitle: String {
        guard let index = currentChapterIndex, currentChapters.indices.contains(index) else {
            return "No Chapter"
        }
        return currentChapters[index].title
    }

    private var currentChapterRange: ClosedRange<TimeInterval> {
        guard let index = currentChapterIndex, currentChapters.indices.contains(index) else {
            return 0...max(totalDuration, 1)
        }
        let chapter = currentChapters[index]
        let start = chapter.startTime
        let end = chapter.endTime ?? totalDuration
        return start...max(start, end)
    }

    private var currentChapterDuration: TimeInterval {
        currentChapterRange.upperBound - currentChapterRange.lowerBound
    }

    private var chapterElapsedSeconds: TimeInterval {
        max(0, elapsedSeconds - currentChapterRange.lowerBound)
    }

    private var chapterMarkerTimes: [TimeInterval] {
        currentChapters.map(\.startTime)
    }

    private var chapterSnapToleranceSeconds: TimeInterval {
        max(1.5, min(12, totalDuration * 0.0035))
    }

    private var scrubPreviewChapterTitle: String? {
        guard isTimelineScrubbing, let preview = scrubPreviewSeconds else { return nil }
        guard let snapped = currentChapters.first(where: { abs($0.startTime - preview) < 0.01 }) else {
            return nil
        }
        return snapped.title
    }

    private var chapterMarkersOverlay: some View {
        GeometryReader { geometry in
            let duration = max(totalDuration, 1)
            ZStack(alignment: .leading) {
                ForEach(Array(currentChapters.enumerated()), id: \.element.id) { index, chapter in
                    let x = geometry.size.width * CGFloat(chapter.startTime / duration)
                    Capsule()
                        .fill((currentChapterIndex == index) ? Color.accentColor : Color.secondary.opacity(0.6))
                        .frame(width: 2, height: 8)
                        .offset(x: min(max(x, 0), geometry.size.width))
                }
            }
        }
        .frame(height: 10)
        .allowsHitTesting(false)
    }

    private func formattedDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "Unknown" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }

    private func formattedClock(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.body)
    }

    private func detailHorizontalPadding(for width: CGFloat) -> CGFloat {
        if width >= 420 { return 24 }
        if width >= 340 { return 16 }
        if width >= 280 { return 10 }
        return 6
    }

    private func updateSplitVisibility(for totalWidth: CGFloat) {
        // Collapse detail column when the app is too narrow to keep
        // right-panel text readable.
        splitVisibility = totalWidth < 1120 ? .doubleColumn : .all
    }

    private func configurePlayerObservers() {
        guard timeObserverToken == nil else { return }

        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            if seconds.isFinite {
                if !isTimelineScrubbing {
                    elapsedSeconds = seconds
                }
                updateNowPlaying()
                if let activeItemID {
                    persistProgress(itemID: activeItemID, seconds: seconds)
                    Task {
                        _ = await viewModel.recordPlaybackProgress(
                            itemID: activeItemID,
                            positionSeconds: seconds,
                            durationSeconds: totalDuration > 0 ? totalDuration : nil,
                            trigger: .periodic
                        )
                    }
                }
            }
        }
    }

    private func teardownPlayerObservers() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func configureKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        let prefs = preferences

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if prefs.isCapturingShortcut {
                return event
            }

            // Avoid stealing regular typing from text inputs.
            if NSApp.keyWindow?.firstResponder is NSTextView, !event.modifierFlags.contains(.command) {
                return event
            }

            if prefs.shouldTrigger(action: .skipBackwardConfiguredInterval, for: event) {
                NotificationCenter.default.post(name: .absMediaSkipBackward, object: nil)
                return nil
            }

            if prefs.shouldTrigger(action: .skipForwardConfiguredInterval, for: event) {
                NotificationCenter.default.post(name: .absMediaSkipForward, object: nil)
                return nil
            }

            if prefs.shouldTrigger(action: .skipBackwardOneSecond, for: event) {
                NotificationCenter.default.post(name: .absMediaSkipBackwardOneSecond, object: nil)
                return nil
            }

            if prefs.shouldTrigger(action: .skipForwardOneSecond, for: event) {
                NotificationCenter.default.post(name: .absMediaSkipForwardOneSecond, object: nil)
                return nil
            }

            if prefs.shouldTrigger(action: .playPauseToggle, for: event) {
                NotificationCenter.default.post(name: .absMediaTogglePlayPause, object: nil)
                return nil
            }

            if prefs.shouldTrigger(action: .previousChapter, for: event) {
                NotificationCenter.default.post(name: .absMediaPreviousChapter, object: nil)
                return nil
            }

            if prefs.shouldTrigger(action: .nextChapter, for: event) {
                NotificationCenter.default.post(name: .absMediaNextChapter, object: nil)
                return nil
            }

            return event
        }
    }

    private func teardownKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    private func shortcutDisplay(for action: ShortcutAction) -> String {
        let primary = preferences.primaryBinding(for: action)
        let primaryLabel = primary.modifiers == .none
            ? primary.key.displayName
            : "\(primary.modifiers.title) + \(primary.key.displayName)"

        guard let alternate = preferences.alternateBinding(for: action) else {
            return primaryLabel
        }

        let alternateLabel = alternate.modifiers == .none
            ? alternate.key.displayName
            : "\(alternate.modifiers.title) + \(alternate.key.displayName)"
        return "\(primaryLabel) / \(alternateLabel)"
    }

    private func openSettingsWindow(tab: SettingsTab) {
        preferences.selectedSettingsTab = tab
        Self.settingsLogger.info("Opening settings window for tab: \(tab.rawValue, privacy: .public)")
        openWindow(id: "indexd-settings-window")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func attemptServerConnect() {
        guard !viewModel.isConnecting else { return }

        Task {
            await viewModel.connect()
            if viewModel.isAuthenticated {
                showingServerSheet = false
                if let selectedLibraryID = viewModel.selectedLibraryID, browseTabByLibraryID[selectedLibraryID] == nil {
                    browseTabByLibraryID[selectedLibraryID] = .books
                }
                if currentBrowseTab == .books {
                    selectedItemID = browsedItems.first?.id
                    selectedGroupID = nil
                } else {
                    selectedGroupID = displayedBrowseGroups.first?.id
                    selectedItemID = nil
                }
                updateNowPlaying()
            }
        }
    }

    private func play() {
        if activeItemID != nil, player.currentItem != nil {
            player.play()
            player.rate = Float(playbackSpeed)
            isPlaying = true
            updateNowPlaying()
            return
        }

        guard let item = selectedItem else { return }

        play(item: item, startPosition: nil)
    }

    private func pause() {
        player.pause()
        isPlaying = false
        flushProgressToServer(trigger: .pause)
        updateNowPlaying()
    }

    private func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time)
        elapsedSeconds = max(0, seconds)
        if let activeItemID {
            persistProgress(itemID: activeItemID, seconds: elapsedSeconds, source: .appClient)
            Task {
                _ = await viewModel.recordPlaybackProgress(
                    itemID: activeItemID,
                    positionSeconds: elapsedSeconds,
                    durationSeconds: totalDuration > 0 ? totalDuration : nil,
                    trigger: .manual
                )
            }
        }
        updateNowPlaying()
    }

    private func skipBackward15() {
        seek(to: elapsedSeconds - preferences.skipBackwardSeconds)
    }

    private func skipForward30() {
        let duration = totalDuration > 0 ? totalDuration : (elapsedSeconds + preferences.skipForwardSeconds)
        seek(to: min(duration, elapsedSeconds + preferences.skipForwardSeconds))
    }

    private func skipBackwardOneSecond() {
        seek(to: elapsedSeconds - 1.0)
    }

    private func skipForwardOneSecond() {
        let duration = totalDuration > 0 ? totalDuration : (elapsedSeconds + 1.0)
        seek(to: min(duration, elapsedSeconds + 1.0))
    }

    private func previousChapter() {
        let chapters = currentChapters
        guard !chapters.isEmpty else { return }

        guard let currentIndex = currentChapterIndex else {
            seek(to: chapters[0].startTime)
            return
        }

        // If user is more than a couple seconds into chapter, restart it;
        // otherwise jump to previous chapter.
        if elapsedSeconds - chapters[currentIndex].startTime > 2 {
            seek(to: chapters[currentIndex].startTime)
            return
        }

        let previousIndex = max(0, currentIndex - 1)
        seek(to: chapters[previousIndex].startTime)
    }

    private func nextChapter() {
        let chapters = currentChapters
        guard !chapters.isEmpty else { return }

        guard let currentIndex = currentChapterIndex else {
            seek(to: chapters[0].startTime)
            return
        }

        let nextIndex = min(chapters.count - 1, currentIndex + 1)
        seek(to: chapters[nextIndex].startTime)
    }

    private func updateNowPlaying() {
        guard let item = playbackDisplayItem else {
            mediaIntegration.clearNowPlaying()
            return
        }

        mediaIntegration.updateNowPlaying(
            title: item.title,
            author: item.author,
            elapsedSeconds: elapsedSeconds,
            duration: item.duration,
            playbackRate: playbackSpeed,
            isPlaying: isPlaying
        )
    }

    private func play(item: ABSCore.LibraryItem, startPosition: TimeInterval?, forceReload: Bool = false) {
        if activeItemID == item.id, player.currentItem != nil, !forceReload {
            if let startPosition {
                seek(to: max(0, startPosition))
            }
            player.play()
            player.rate = Float(playbackSpeed)
            isPlaying = true
            updateNowPlaying()
            return
        }

        Task {
            do {
                let localStart = max(0, startPosition ?? savedProgress(for: item.id))
                let resolvedStart = await viewModel.resolvePlaybackPosition(
                    itemID: item.id,
                    localPosition: localStart,
                    durationSeconds: item.duration
                )
                let source: ProgressHistorySource? = abs(resolvedStart - localStart) > 0.5 ? .absServer : nil
                persistProgress(itemID: item.id, seconds: resolvedStart, source: source)

                let url = try await viewModel.streamURL(for: item.id)
                let newItem = AVPlayerItem(url: url)
                player.replaceCurrentItem(with: newItem)
                activeItemID = item.id
                nowPlayingItem = item
                playbackChapters = item.chapters
                elapsedSeconds = 0
                markRecentActivity(itemID: item.id, force: true)

                if resolvedStart > 0 {
                    let startTime = CMTime(seconds: resolvedStart, preferredTimescale: 600)
                    await player.seek(to: startTime)
                    elapsedSeconds = resolvedStart
                }

                player.play()
                player.rate = Float(playbackSpeed)
                isPlaying = true
                await loadMetadataChapters(from: url)
                updateNowPlaying()
            } catch {
                isPlaying = false
                viewModel.setError("Playback failed: \(viewModel.describeError(error))")
            }
        }
    }

    private func flushProgressToServer(trigger: ProgressUpdateTrigger) {
        guard let activeItemID else { return }
        let duration = totalDuration > 0 ? totalDuration : nil
        let position = max(0, elapsedSeconds)

        Task {
            let synced = await viewModel.recordPlaybackProgress(
                itemID: activeItemID,
                positionSeconds: position,
                durationSeconds: duration,
                trigger: trigger
            )
            if synced != nil, trigger == .pause {
                appendProgressHistory(itemID: activeItemID, positionSeconds: position, source: .appPauseSync)
            }
        }
    }

    private func syncSelectedItemProgressFromServer() async {
        guard let item = selectedItem else { return }
        let local = savedProgress(for: item.id)
        let resolved = await viewModel.resolvePlaybackPosition(
            itemID: item.id,
            localPosition: local,
            durationSeconds: item.duration
        )
        if abs(resolved - local) > 0.5 {
            persistProgress(itemID: item.id, seconds: resolved, source: .absServer)
            if activeItemID == item.id, !isTimelineScrubbing {
                elapsedSeconds = resolved
            }
        }
    }

    private var progressSyncTargetItem: ABSCore.LibraryItem? {
        selectedItem ?? playbackDisplayItem
    }

    private func manualDownloadProgress() async {
        guard let item = progressSyncTargetItem else { return }
        let local = savedProgress(for: item.id)
        guard let resolved = await viewModel.downloadProgressFromServer(
            itemID: item.id,
            localPosition: local,
            durationSeconds: item.duration
        ) else { return }

        if abs(resolved - local) > 0.5 {
            persistProgress(itemID: item.id, seconds: resolved)
            if activeItemID == item.id, !isTimelineScrubbing {
                elapsedSeconds = resolved
            }
        }
    }

    private func manualUploadProgress() async {
        guard let item = progressSyncTargetItem else { return }
        let local = savedProgress(for: item.id)
        let uploaded = await viewModel.uploadProgressToServer(
            itemID: item.id,
            positionSeconds: local,
            durationSeconds: item.duration
        )
        if uploaded != nil {
            appendProgressHistory(itemID: item.id, positionSeconds: local, source: .manualUpload)
        }
    }

    private func restoreProgress(from entry: ProgressHistoryEntry) {
        let restoredSeconds = max(0, entry.positionSeconds)
        persistProgress(itemID: entry.itemID, seconds: restoredSeconds, source: .manualRestore)
        if activeItemID == entry.itemID {
            seek(to: restoredSeconds)
        }

        if let item = viewModel.item(withID: entry.itemID) {
            Task {
                _ = await viewModel.uploadProgressToServer(
                    itemID: entry.itemID,
                    positionSeconds: restoredSeconds,
                    durationSeconds: item.duration
                )
            }
        }
    }

    private func recentHistory(for itemID: String, limit: Int) -> [ProgressHistoryEntry] {
        Array((progressHistoryByItemID[itemID] ?? []).prefix(limit))
    }

    private func formattedHistoryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func formattedSyncTimestamp(_ date: Date) -> String {
        let absoluteFormatter = DateFormatter()
        absoluteFormatter.dateStyle = .short
        absoluteFormatter.timeStyle = .medium
        return absoluteFormatter.string(from: date)
    }

    private func appendProgressHistory(itemID: String, positionSeconds: TimeInterval, source: ProgressHistorySource) {
        let entry = ProgressHistoryEntry(
            id: UUID(),
            itemID: itemID,
            positionSeconds: max(0, positionSeconds),
            source: source,
            occurredAt: Date()
        )
        var entries = progressHistoryByItemID[itemID] ?? []
        entries.insert(entry, at: 0)
        if entries.count > 200 {
            entries = Array(entries.prefix(200))
        }
        progressHistoryByItemID[itemID] = entries
        if let data = try? JSONEncoder().encode(progressHistoryByItemID) {
            UserDefaults.standard.set(data, forKey: progressHistoryDefaultsKey)
        }
    }

    private func scheduleProgressHydration() {
        progressHydrationTask?.cancel()
        let candidates = browsedItems

        progressHydrationTask = Task {
            await hydrateProgressFromServer(for: candidates)
        }
    }

    private func hydrateProgressFromServer(for items: [ABSCore.LibraryItem]) async {
        guard viewModel.isAuthenticated else { return }

        let maxItemsToHydrate = 300
        let uniqueItems = Array(
            Dictionary(grouping: items, by: \.id)
                .values
                .compactMap(\.first)
                .prefix(maxItemsToHydrate)
        )

        for item in uniqueItems {
            if Task.isCancelled { return }

            let local = savedProgress(for: item.id)
            let resolved = await viewModel.resolvePlaybackPosition(
                itemID: item.id,
                localPosition: local,
                durationSeconds: item.duration
            )

            if abs(resolved - local) > 0.5 {
                await MainActor.run {
                    persistProgress(itemID: item.id, seconds: resolved, source: .absServer)
                    if activeItemID == item.id, !isTimelineScrubbing {
                        elapsedSeconds = resolved
                    }
                }
            }
        }
    }

    @MainActor
    private func handleLogout() async {
        await viewModel.logout()

        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        elapsedSeconds = 0
        selectedItemID = nil
        activeItemID = nil
        nowPlayingItem = nil
        playbackChapters = []
        showingNowPlaying = false
        localProgressByItemID = [:]
        progressHistoryByItemID = [:]
        favoriteItemIDs = []
        recentActivityByItemID = [:]
        UserDefaults.standard.removeObject(forKey: progressDefaultsKey)
        UserDefaults.standard.removeObject(forKey: progressHistoryDefaultsKey)
        UserDefaults.standard.removeObject(forKey: favoritesDefaultsKey)
        UserDefaults.standard.removeObject(forKey: recentDefaultsKey)
        updateNowPlaying()
    }

    private func loadLocalPlaybackMetadata() {
        if let progress = UserDefaults.standard.dictionary(forKey: progressDefaultsKey) as? [String: Double] {
            localProgressByItemID = progress.mapValues { TimeInterval($0) }
        } else {
            localProgressByItemID = [:]
        }

        if let data = UserDefaults.standard.data(forKey: progressHistoryDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [ProgressHistoryEntry]].self, from: data) {
            progressHistoryByItemID = decoded
        } else {
            progressHistoryByItemID = [:]
        }

        let favorites = UserDefaults.standard.stringArray(forKey: favoritesDefaultsKey) ?? []
        favoriteItemIDs = Set(favorites)

        if let recents = UserDefaults.standard.dictionary(forKey: recentDefaultsKey) as? [String: Double] {
            recentActivityByItemID = recents.reduce(into: [:]) { result, entry in
                result[entry.key] = Date(timeIntervalSince1970: entry.value)
            }
        } else {
            recentActivityByItemID = [:]
        }
    }

    private func persistProgress(itemID: String, seconds: TimeInterval, source: ProgressHistorySource? = nil) {
        localProgressByItemID[itemID] = max(0, seconds)
        let raw = localProgressByItemID.mapValues { Double($0) }
        UserDefaults.standard.set(raw, forKey: progressDefaultsKey)
        markRecentActivity(itemID: itemID)
        if let source {
            appendProgressHistory(itemID: itemID, positionSeconds: seconds, source: source)
        }
    }

    private func savedProgress(for itemID: String) -> TimeInterval {
        max(0, localProgressByItemID[itemID] ?? 0)
    }

    private func hasSavedProgress(for itemID: String) -> Bool {
        savedProgress(for: itemID) > 0
    }

    private func clearSavedProgress(itemID: String) {
        persistProgress(itemID: itemID, seconds: 0, source: .appClear)
        if activeItemID == itemID {
            seek(to: 0)
        }
    }

    private func clearSavedProgressEverywhere(item: ABSCore.LibraryItem) {
        clearSavedProgress(itemID: item.id)
        Task {
            _ = await viewModel.uploadProgressToServer(
                itemID: item.id,
                positionSeconds: 0,
                durationSeconds: item.duration
            )
        }
    }

    private func toggleFavorite(itemID: String) {
        if favoriteItemIDs.contains(itemID) {
            favoriteItemIDs.remove(itemID)
        } else {
            favoriteItemIDs.insert(itemID)
            markRecentActivity(itemID: itemID, force: true)
        }
        UserDefaults.standard.set(Array(favoriteItemIDs).sorted(), forKey: favoritesDefaultsKey)
    }

    private func markRecentActivity(itemID: String, force: Bool = false) {
        let now = Date()
        if !force, let previous = recentActivityByItemID[itemID], now.timeIntervalSince(previous) < 30 {
            return
        }
        recentActivityByItemID[itemID] = now
        let raw = recentActivityByItemID.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: recentDefaultsKey)
    }

    private func positionSummary(for item: ABSCore.LibraryItem) -> String {
        let current = formattedClock(savedProgress(for: item.id))
        let total = formattedClock(item.duration ?? 0)
        return "\(current) / \(total)"
    }

    private func openNowPlayingPanel() {
        guard playbackDisplayItem != nil else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            showingNowPlaying = true
            nowPlayingChapterListHeight = 180
            nowPlayingChapterListUserResized = false
            splitVisibility = .all
            bottomExpandDragOffset = 0
        }
    }

    private func preloadChaptersForSelectedItem(adoptForPlayback: Bool) async {
        guard let item = selectedItem else { return }
        if !item.chapters.isEmpty {
            if adoptForPlayback {
                playbackChapters = item.chapters
            }
            return
        }

        do {
            let sessionChapters = try await viewModel.playbackChapters(for: item.id)
            if !sessionChapters.isEmpty {
                if adoptForPlayback {
                    playbackChapters = sessionChapters
                }
                return
            }
        } catch {
            // Try metadata extraction fallback next.
        }

        do {
            let url = try await viewModel.streamURL(for: item.id)
            if adoptForPlayback {
                await loadMetadataChapters(from: url)
            }
        } catch {
            // If stream URL lookup fails, chapters remain unavailable.
        }
    }

    private func preloadCoverForPlaybackItem() async {
        guard let item = playbackDisplayItem else { return }
        guard coverImagesByItemID[item.id] == nil else { return }
        guard let data = await viewModel.coverData(for: item.id) else { return }
        guard let image = NSImage(data: data) else { return }

        await MainActor.run {
            coverImagesByItemID[item.id] = image
        }
    }

    private func preloadCoverForItemID(_ itemID: String) async {
        guard coverImagesByItemID[itemID] == nil else { return }
        guard let data = await viewModel.coverData(for: itemID) else { return }
        guard let image = NSImage(data: data) else { return }
        await MainActor.run {
            coverImagesByItemID[itemID] = image
        }
    }

    private func preloadCoverForSelectedItem() async {
        guard let item = selectedItem else { return }
        guard coverImagesByItemID[item.id] == nil else { return }
        guard let data = await viewModel.coverData(for: item.id) else { return }
        guard let image = NSImage(data: data) else { return }

        await MainActor.run {
            coverImagesByItemID[item.id] = image
        }
    }

    private func loadMetadataChapters(from url: URL) async {
        let asset = AVURLAsset(url: url)
        let preferredLanguages: [String]
        if #available(macOS 12.0, *) {
            let locales = (try? await asset.load(.availableChapterLocales)) ?? []
            preferredLanguages = locales.isEmpty ? Locale.preferredLanguages : locales.map(\.identifier)
        } else {
            preferredLanguages = Locale.preferredLanguages
        }

        let groups = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: preferredLanguages)

        guard !groups.isEmpty else {
            return
        }

        var extracted: [ABSCore.Chapter] = []

        for (index, group) in groups.enumerated() {
            let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = titleItem?.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let start = group.timeRange.start.seconds
            let duration = group.timeRange.duration.seconds
            let end: TimeInterval? = duration.isFinite ? start + duration : nil

            extracted.append(
                ABSCore.Chapter(
                    id: "m4b-\(index)",
                    title: (title?.isEmpty == false ? title! : "Chapter \(index + 1)"),
                    startTime: start.isFinite ? start : 0,
                    endTime: end
                )
            )
        }

        await MainActor.run {
            playbackChapters = extracted
        }
    }
}

private extension String {
    var trimmedForGrouping: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }
}
