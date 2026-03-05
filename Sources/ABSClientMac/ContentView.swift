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

    private struct StatsSummary {
        let totalListeningSeconds: TimeInterval
        let listeningLast7Days: TimeInterval
        let listeningLast30Days: TimeInterval
        let startedCount: Int
        let completedCount: Int
        let currentStreakDays: Int
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
        case downloaded = "Downloaded"
        case stats = "Stats"
    }

    private enum StatsScope: String, CaseIterable, Identifiable {
        case currentLibrary = "Current Library"
        case allLoadedLibraries = "All Loaded Libraries"

        var id: String { rawValue }
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

    private enum FilterMode: String, CaseIterable, Identifiable {
        case quick = "Quick"
        case advanced = "Advanced"

        var id: String { rawValue }
    }

    private enum AdvancedFilterMatchMode: String, CaseIterable, Identifiable {
        case all = "AND (All Rules)"
        case any = "OR (Any Rule)"

        var id: String { rawValue }
    }

    private enum AdvancedFilterField: String, CaseIterable, Identifiable {
        case duration = "Duration"
        case publishedYear = "Publication Year"
        case title = "Title"
        case author = "Author"

        var id: String { rawValue }
    }

    private enum AdvancedFilterOperator: String, CaseIterable, Identifiable {
        case equals = "="
        case notEquals = "!="
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case contains = "contains"
        case notContains = "not contains"
        case startsWith = "starts with"
        case endsWith = "ends with"

        var id: String { rawValue }
    }

    private enum AdvancedDurationUnit: String, CaseIterable, Identifiable {
        case seconds = "Seconds"
        case minutes = "Minutes"
        case hours = "Hours"

        var id: String { rawValue }

        var multiplier: Double {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            }
        }
    }

    private struct AdvancedFilterRule: Identifiable, Hashable {
        let id: UUID
        var field: AdvancedFilterField
        var operation: AdvancedFilterOperator
        var value: String
        var durationUnit: AdvancedDurationUnit

        init(
            id: UUID = UUID(),
            field: AdvancedFilterField = .duration,
            operation: AdvancedFilterOperator = .greaterThan,
            value: String = "",
            durationUnit: AdvancedDurationUnit = .hours
        ) {
            self.id = id
            self.field = field
            self.operation = operation
            self.value = value
            self.durationUnit = durationUnit
        }
    }

    private let mediaIntegration = MacMediaIntegrationManager.shared
    private let progressDefaultsKey = "abs.local.progress.v1"
    private let progressHistoryDefaultsKey = "abs.local.progress.history.v1"
    private let favoritesDefaultsKey = "abs.local.favorites.v1"
    private let recentDefaultsKey = "abs.local.recent.v1"
    private let searchSuggestionLimit = 5
    private let downloadMenuPageSize = 8
    private let libraryBrowseTabs: [LibraryBrowseTab] = [
        .authors,
        .narrators,
        .series,
        .collections,
        .continueListening,
        .recent,
        .favorites,
        .books,
        .downloaded,
        .stats
    ]

    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = AppViewModel()
    @State private var selectedItemID: ABSCore.LibraryItem.ID?
    @State private var selectedItemIDs: Set<ABSCore.LibraryItem.ID> = []
    @State private var selectedGroupID: String?
    @State private var searchText = ""
    @State private var itemFilter: ItemFilterOption = .all
    @State private var filterMode: FilterMode = .quick
    @State private var bookSortOption: BookSortOption = .alphabetical
    @State private var groupSortOption: GroupSortOption = .alphabetical
    @State private var advancedFilterMatchMode: AdvancedFilterMatchMode = .all
    @State private var advancedFilterRules: [AdvancedFilterRule] = []
    @State private var showingAdvancedFilterPopover = false
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
    @State private var playedStateByItemID: [String: Bool] = [:]
    @State private var progressHistoryByItemID: [String: [ProgressHistoryEntry]] = [:]
    @State private var favoriteItemIDs: Set<String> = []
    @State private var recentActivityByItemID: [String: Date] = [:]
    @State private var downloadedItemIDs: Set<String> = []
    @State private var downloadStateByItemID: [String: DownloadState] = [:]
    @State private var downloadBusyItemIDs: Set<String> = []
    @State private var downloadQueuedItemIDs: Set<String> = []
    @State private var downloadProgressByItemID: [String: Double] = [:]
    @State private var downloadRecoveredStateByItemID: [String: DownloadJobState] = [:]
    @State private var copiedToLocalItemIDs: Set<String> = []
    @State private var isClearingDownloads = false
    @State private var downloadMenuPage = 0
    @State private var showingDownloadsPopover = false
    @State private var downloadPopoverWidth: CGFloat = 720
    @State private var downloadPopoverHeight: CGFloat = 560
    @State private var downloadPopoverDragStartWidth: CGFloat?
    @State private var downloadPopoverDragStartHeight: CGFloat?
    @State private var showingItemDownloadPopover = false
    @State private var showingBulkActionsPopover = false
    @State private var isTimelineScrubbing = false
    @State private var scrubPreviewSeconds: TimeInterval?
    @State private var progressHydrationTask: Task<Void, Never>?
    @State private var liveUpdateTask: Task<Void, Never>?
    @State private var lastLiveUpdateAt: Date?
    @State private var statsScope: StatsScope = .currentLibrary
    @State private var hasAttemptedDownloadRecovery = false

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

                    Text("Transport: \(transportStatusDisplay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Button("Add Local Folder…") {
                        addLocalLibraryFolder()
                    }

                    Button("Rescan Local Libraries") {
                        rescanLocalLibraries()
                    }
                    .disabled(!viewModel.hasLocalLibraries)

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
                Button {
                    showingDownloadsPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        downloadToolbarLabel
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showingDownloadsPopover, arrowEdge: .top) {
                    downloadsPopoverContent
                }
                .help("Downloads")
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
            await refreshDownloadedInventory()
            await recoverPendingDownloadsIfNeeded()
            showingServerSheet = !viewModel.isAuthenticated && !viewModel.hasAnyLibraries
            if viewModel.selectedLibraryID == nil {
                viewModel.selectedLibraryID = viewModel.libraries.first?.id
            }
            if let selectedLibraryID = viewModel.selectedLibraryID, browseTabByLibraryID[selectedLibraryID] == nil {
                browseTabByLibraryID[selectedLibraryID] = .books
            }
            if isBookListTab {
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
                await refreshDownloadStates(for: viewModel.displayedItems.map(\.id))
                await preloadChaptersForSelectedItem(adoptForPlayback: activeItemID == nil)
                await preloadCoverForSelectedItem()
                await preloadCoverForPlaybackItem()
            }
            startLiveUpdatesIfNeeded()
        })

        view = AnyView(view.onDisappear {
            teardownPlayerObservers()
            teardownKeyboardMonitor()
            progressHydrationTask?.cancel()
            progressHydrationTask = nil
            stopLiveUpdates()
        })

        view = AnyView(view.onChange(of: scenePhase, perform: { _ in
            restartLiveUpdatesIfNeeded()
        }))

        view = AnyView(view.onChange(of: viewModel.isAuthenticated, perform: { _ in
            restartLiveUpdatesIfNeeded()
        }))

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
            if isBookListTab {
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
            Task {
                await refreshDownloadStates(for: viewModel.displayedItems.map(\.id))
            }
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
            Task {
                await refreshDownloadedInventory()
                await refreshDownloadStates(for: viewModel.displayedItems.map(\.id))
            }
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

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockOpenSettings)) { _ in
            openSettingsWindow(tab: .playback)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockSyncProgressNow)) { _ in
            Task {
                await manualDownloadProgress()
                await manualUploadProgress()
            }
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockOpenDownloadCache)) { _ in
            Task { await openDownloadCacheInFinder() }
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockShowNowPlaying)) { _ in
            guard playbackDisplayItem != nil else { return }
            showingNowPlaying = true
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockBrowseBooks)) { _ in
            selectDockBrowseTab(.books)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockBrowseAuthors)) { _ in
            selectDockBrowseTab(.authors)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockBrowseSeries)) { _ in
            selectDockBrowseTab(.series)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockBrowseContinue)) { _ in
            selectDockBrowseTab(.continueListening)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .absDockBrowseDownloaded)) { _ in
            selectDockBrowseTab(.downloaded)
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
            if currentBrowseTab == .stats {
                HStack(spacing: 6) {
                    Text("Scope")
                        .foregroundStyle(.secondary)
                    Picker("Scope", selection: $statsScope) {
                        ForEach(StatsScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if let statsLastUpdatedAt {
                    Text("Last updated: \(formattedSyncTimestamp(statsLastUpdatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Last updated: Pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Text("Sort")
                        .foregroundStyle(.secondary)
                    Picker("Sort", selection: sortPickerSelectionBinding) {
                        if isBookListTab {
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

                HStack(spacing: 6) {
                    Text("Mode")
                        .foregroundStyle(.secondary)
                    Picker("Filter Mode", selection: $filterMode) {
                        ForEach(FilterMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if filterMode == .advanced {
                    Button {
                        showingAdvancedFilterPopover.toggle()
                    } label: {
                        Label(advancedFilterSummaryLabel, systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showingAdvancedFilterPopover, arrowEdge: .top) {
                        advancedFilterPopoverContent
                    }
                }

                if currentBrowseTab == .downloaded {
                    Button(openLibraryFolderActionTitle) {
                        Task { await openPreferredLibraryFolderInFinder() }
                    }

                    Button(isClearingDownloads ? "Clearing…" : "Clear Downloads", role: .destructive) {
                        Task { await clearAllDownloads() }
                    }
                    .disabled(isClearingDownloads || downloadedItemIDs.isEmpty)
                }
            }

            Spacer()

            if isBookListTab {
                Button {
                    showingBulkActionsPopover.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline.weight(.semibold))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.bordered)
                .help("Bulk actions")
                .popover(isPresented: $showingBulkActionsPopover, arrowEdge: .top) {
                    bulkActionsPopoverContent
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var sortPickerSelectionBinding: Binding<String> {
        Binding<String>(
            get: {
                isBookListTab ? bookSortOption.rawValue : groupSortOption.rawValue
            },
            set: { newValue in
                if isBookListTab {
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
        if currentBrowseTab == .stats {
            return statsSourceItems.count
        }

        if isBookListTab {
            return browsedItems.count
        }

        return displayedBrowseGroups.count
    }

    @ViewBuilder
    private var itemListContent: some View {
        if currentBrowseTab == .stats {
            statsListView
        } else if isBookListTab {
            booksListView
        } else {
            groupListView
        }
    }

    private var booksListView: some View {
        List(browsedItems, selection: booksListSelectionBinding) { item in
            HStack(spacing: 8) {
                itemListRowCover(for: item)

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
                    if isMarkedPlayed(itemID: item.id, duration: item.duration) {
                        Text("Played")
                            .font(.caption)
                            .foregroundStyle(.green)
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
                let contextItemIDs = contextSelectionIDs(for: item.id)
                let contextAllFavorited = contextItemIDs.allSatisfy { favoriteItemIDs.contains($0) }

                if contextItemIDs.count > 1 {
                    Button("Download Selected to App Cache (\(contextItemIDs.count))") {
                        Task { await downloadItems(contextItemIDs) }
                    }

                    if canCopyToLocalLibrary {
                        Button("Copy Selected to Local Library (\(contextItemIDs.count))") {
                            Task { await copyItemsToLocalLibrary(contextItemIDs) }
                        }
                    }

                    Button("Remove Downloaded Files (\(contextSelectedDownloadedItemIDs(for: item.id).count))", role: .destructive) {
                        Task { await removeDownloads(contextItemIDs) }
                    }
                    .disabled(contextSelectedDownloadedItemIDs(for: item.id).isEmpty)

                    if contextAllFavorited {
                        Button("Unfavorite Selected (\(contextItemIDs.count))") {
                            setFavorite(for: contextItemIDs, isFavorite: false)
                        }
                    } else {
                        Button("Favorite Selected (\(contextItemIDs.count))") {
                            setFavorite(for: contextItemIDs, isFavorite: true)
                        }
                    }

                    Divider()

                    Button("Mark Played (\(contextItemIDs.count))") {
                        Task { await setPlayedState(for: contextItemIDs, isPlayed: true) }
                    }

                    Button("Mark Unplayed (\(contextItemIDs.count))") {
                        Task { await setPlayedState(for: contextItemIDs, isPlayed: false) }
                    }
                } else {
                    Button("Start from Beginning") {
                        selectedItemID = item.id
                        selectedItemIDs = [item.id]
                        play(item: item, startPosition: 0, forceReload: true)
                    }

                    if hasSavedProgress(for: item.id) {
                        let resumePosition = savedProgress(for: item.id)
                        Button("Resume at \(formattedClock(resumePosition))") {
                            selectedItemID = item.id
                            selectedItemIDs = [item.id]
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

                    if isMarkedPlayed(itemID: item.id, duration: item.duration) {
                        Button("Mark Unplayed") {
                            Task { await setPlayedState(for: [item.id], isPlayed: false) }
                        }
                    } else {
                        Button("Mark Played") {
                            Task { await setPlayedState(for: [item.id], isPlayed: true) }
                        }
                    }

                    Divider()

                    Menu(downloadMenuTitle) {
                        Button(downloadBusyItemIDs.contains(item.id) ? "Downloading to App Cache…" : "Download to App Cache") {
                            Task { await downloadItem(item.id) }
                        }
                        .disabled(downloadBusyItemIDs.contains(item.id))

                        Button("Download To…") {
                            Task { await downloadItemToChosenLocation(item: item) }
                        }
                        .disabled(downloadBusyItemIDs.contains(item.id))

                        Button(openLibraryFolderActionTitle) {
                            Task { await openPreferredLibraryFolderInFinder() }
                        }

                        if downloadState(for: item.id) == .downloaded {
                            Divider()
                            Button("Remove Downloaded File", role: .destructive) {
                                Task { await removeDownload(for: item.id) }
                            }
                        }
                    }

                    if canCopyToLocalLibrary {
                        Button("Copy to Local Library") {
                            Task { await copyItemsToLocalLibrary([item.id]) }
                        }
                    }
                }
            }
            .onTapGesture(count: 2) {
                selectedItemID = item.id
                selectedItemIDs = [item.id]
                let resumePosition = savedProgress(for: item.id)
                play(item: item, startPosition: resumePosition > 0 ? resumePosition : nil)
            }
        }
    }

    private var statsListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    statsCard(
                        title: "Total Listening",
                        value: formattedDuration(statsSummary.totalListeningSeconds)
                    )
                    statsCard(
                        title: "Last 7 Days",
                        value: formattedDuration(statsSummary.listeningLast7Days)
                    )
                    statsCard(
                        title: "Last 30 Days",
                        value: formattedDuration(statsSummary.listeningLast30Days)
                    )
                }

                HStack(spacing: 12) {
                    statsCard(title: "Started", value: "\(statsSummary.startedCount)")
                    statsCard(title: "Completed", value: "\(statsSummary.completedCount)")
                    statsCard(title: "Current Streak", value: "\(statsSummary.currentStreakDays) day\(statsSummary.currentStreakDays == 1 ? "" : "s")")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Window Labels")
                        .font(.headline)
                    Text("Last 7 Days and Last 30 Days are based on locally recorded listening deltas from progress history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Scope: \(statsScope.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)
        }
    }

    private func statsCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func itemListRowCover(for item: ABSCore.LibraryItem) -> some View {
        if let cover = coverImagesByItemID[item.id] {
            Image(nsImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 44, height: 44)
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
            .contextMenu {
                let copyItemIDs = groupCopyItemIDs(for: group)
                if canCopyToLocalLibrary, !copyItemIDs.isEmpty {
                    Button(groupCopyActionLabel(itemCount: copyItemIDs.count)) {
                        Task { await copyItemsToLocalLibrary(copyItemIDs) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if showingNowPlaying, let item = playbackDisplayItem {
            nowPlayingDetailView(item: item)
                .navigationTitle("Now Playing")
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if !isBookListTab, let group = selectedGroup {
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
                            let authors = displayAuthorNames(for: item)
                            if !authors.isEmpty {
                                VStack(spacing: 2) {
                                    ForEach(Array(authors.enumerated()), id: \.offset) { _, author in
                                        Button(author) {
                                            navigateToBrowseGroup(tab: .authors, groupID: author.trimmedForGrouping)
                                        }
                                        .buttonStyle(.plain)
                                        .font(.title3)
                                        .foregroundStyle(Color.blue)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.85)
                                        .multilineTextAlignment(.center)
                                        .help("Browse author")
                                    }
                                }
                            }
                            if let narrator = preferredNarrator(for: item) {
                                Button("Narrated by \(narrator)") {
                                    navigateToBrowseGroup(tab: .narrators, groupID: narrator.trimmedForGrouping)
                                }
                                .buttonStyle(.plain)
                                .font(.subheadline)
                                .foregroundStyle(Color.blue)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.center)
                                .help("Browse narrator")
                            }
                            let series = inferredSeriesName(for: item)
                            if series != "Unknown Series" {
                                Button(seriesDisplayLabel(for: item)) {
                                    navigateToBrowseGroup(tab: .series, groupID: series)
                                }
                                .buttonStyle(.plain)
                                .font(.subheadline)
                                .foregroundStyle(Color.blue)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.center)
                                .help("Browse series")
                            }

                            Text(positionSummary(for: item))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        HStack(spacing: 10) {
                            Button {
                                let resumePosition = savedProgress(for: item.id)
                                play(item: item, startPosition: resumePosition > 0 ? resumePosition : nil)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(minWidth: 120)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                showingItemDownloadPopover.toggle()
                            } label: {
                                let isDownloaded = downloadedItemIDs.contains(item.id) || downloadStateByItemID[item.id] == .downloaded
                                Image(systemName: "arrow.down")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(isDownloaded ? Color.green : Color.primary)
                                    .frame(width: 28, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .popover(isPresented: $showingItemDownloadPopover, arrowEdge: .top) {
                                itemDownloadPopoverContent(item: item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            if let blurb = renderedBlurb(for: item) {
                                Text(blurb)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Divider()
                            }

                            detailRow(title: "Duration", value: formattedDuration(item.duration))
                            detailRow(
                                title: "Status",
                                value: isMarkedPlayed(itemID: item.id, duration: item.duration) ? "Played" : "Unplayed"
                            )
                            if let author = authorDisplayValue(for: item) {
                                detailRow(title: "Author", value: author)
                            }
                            if let narrator = preferredNarrator(for: item) {
                                detailRow(title: "Narrator", value: narrator)
                            }
                            if let series = seriesValue(for: item) {
                                detailRow(title: "Series", value: series)
                            }
                            if let publisher = item.publisher, !publisher.isEmpty {
                                detailRow(title: "Publisher", value: publisher)
                            }
                            if let publishedYear = item.publishedYear {
                                detailRow(title: "Published", value: "\(publishedYear)")
                            }
                            if let language = item.language, !language.isEmpty {
                                detailRow(title: "Language", value: language)
                            }
                            if !item.genres.isEmpty {
                                detailRow(title: "Genres", value: item.genres.joined(separator: ", "), multiline: true)
                            }
                            if !item.tags.isEmpty {
                                detailRow(title: "Tags", value: item.tags.joined(separator: ", "), multiline: true)
                            }
                            if !item.collections.isEmpty {
                                detailRow(title: "Collections", value: item.collections.joined(separator: ", "), multiline: true)
                            }
                            detailRow(title: "Chapters", value: "\(visibleChapterCount(for: item))")
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
                Text(viewModel.isAuthenticated || viewModel.hasAnyLibraries ? "Select an audiobook" : "Connect a server or add a local folder")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if !viewModel.isAuthenticated && !viewModel.hasAnyLibraries {
                    HStack(spacing: 12) {
                        Button("Add Server") {
                            showingServerSheet = true
                        }
                        Button("Add Local Folder…") {
                            addLocalLibraryFolder()
                        }
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
        let resolvedID = selectedItemID ?? selectedVisibleItemIDs.first
        guard let resolvedID else { return nil }
        return browsedItems.first { $0.id == resolvedID }
            ?? viewModel.displayedItems.first { $0.id == resolvedID }
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

    private var statsSourceItems: [ABSCore.LibraryItem] {
        let raw: [ABSCore.LibraryItem]
        switch statsScope {
        case .currentLibrary:
            raw = viewModel.currentLibraryItems
        case .allLoadedLibraries:
            raw = viewModel.allKnownItems()
        }

        let deduped = Dictionary(grouping: raw, by: \.id).compactMap { $0.value.first }
        return deduped
    }

    private var statsSummary: StatsSummary {
        let itemIDs = Set(statsSourceItems.map(\.id))
        let now = Date()
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)

        var started = 0
        var completed = 0
        var totalListeningSeconds: TimeInterval = 0

        for item in statsSourceItems {
            let progress = savedProgress(for: item.id)
            if progress > 0 {
                started += 1
                totalListeningSeconds += progress
            }
            if let duration = item.duration, duration > 1, progress >= (duration - 1) {
                completed += 1
            }
        }

        let deltasByDay = listeningDeltasByDay(for: itemIDs)
        let listeningLast7Days = listeningSecondsFromDeltas(deltasByDay, since: sevenDaysAgo)
        let listeningLast30Days = listeningSecondsFromDeltas(deltasByDay, since: thirtyDaysAgo)
        let currentStreak = streakFromDeltas(deltasByDay)

        return StatsSummary(
            totalListeningSeconds: totalListeningSeconds,
            listeningLast7Days: listeningLast7Days,
            listeningLast30Days: listeningLast30Days,
            startedCount: started,
            completedCount: completed,
            currentStreakDays: currentStreak
        )
    }

    private var statsLastUpdatedAt: Date? {
        let candidates: [Date?] = [viewModel.lastProgressSyncAt, lastLiveUpdateAt]
        return candidates.compactMap { $0 }.max()
    }

    private var browsedItems: [ABSCore.LibraryItem] {
        let items = filteredBaseItems
        switch currentBrowseTab {
        case .books:
            return sortedBooks(items)
        case .downloaded:
            return sortedBooks(items.filter { downloadedItemIDs.contains($0.id) })
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
        case .stats:
            return []
        }
    }

    private var currentBrowseTab: LibraryBrowseTab {
        guard let selectedLibraryID = viewModel.selectedLibraryID else { return .books }
        return browseTabByLibraryID[selectedLibraryID] ?? .books
    }

    private var isBookListTab: Bool {
        currentBrowseTab == .books || currentBrowseTab == .downloaded
    }

    private var browseGroups: [BrowseGroup] {
        let items = filteredBaseItems
        switch currentBrowseTab {
        case .books:
            return []
        case .downloaded:
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
        case .stats:
            return []
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
            if browseTab == .books || browseTab == .downloaded {
                selectedItemID = browsedItems.first?.id
                selectedItemIDs = selectedItemID.map { [$0] } ?? []
                selectedGroupID = nil
            } else if browseTab == .stats {
                selectedItemID = nil
                selectedItemIDs = []
                selectedGroupID = nil
            } else {
                selectedGroupID = displayedBrowseGroups.first?.id
                selectedItemID = nil
                selectedItemIDs = []
            }
        }
    }

    private func selectCurrentLibraryBrowseTab(_ browseTab: LibraryBrowseTab) {
        guard let currentLibraryID = viewModel.selectedLibraryID else { return }
        browseTabByLibraryID[currentLibraryID] = browseTab
    }

    private func selectDockBrowseTab(_ browseTab: LibraryBrowseTab) {
        let targetLibraryID = viewModel.selectedLibraryID ?? viewModel.libraries.first?.id
        guard let targetLibraryID else { return }
        selectLibrary(libraryID: targetLibraryID, browseTab: browseTab)
    }

    private func navigateToBrowseGroup(tab: LibraryBrowseTab, groupID: String) {
        guard viewModel.selectedLibraryID != nil else { return }

        selectCurrentLibraryBrowseTab(tab)
        selectedItemID = nil
        selectedItemIDs = []
        let groups = displayedBrowseGroups
        if groups.contains(where: { $0.id == groupID }) {
            selectedGroupID = groupID
        } else {
            selectedGroupID = groups.first?.id
        }
    }

    private func openItemFromDownloadsPopover(_ itemID: String) {
        guard viewModel.selectedLibraryID != nil else { return }
        selectCurrentLibraryBrowseTab(.books)
        selectedGroupID = nil
        selectedItemID = itemID
        selectedItemIDs = [itemID]
        showingDownloadsPopover = false
    }

    private var filteredBaseItems: [ABSCore.LibraryItem] {
        let base = viewModel.displayedItems
        let quickFiltered: [ABSCore.LibraryItem]
        switch itemFilter {
        case .all:
            quickFiltered = base
        case .inProgress:
            quickFiltered = base.filter { item in
                let progress = savedProgress(for: item.id)
                guard progress > 0 else { return false }
                if let duration = item.duration, duration > 0 {
                    return progress < (duration - 1)
                }
                return true
            }
        case .favorites:
            quickFiltered = base.filter { favoriteItemIDs.contains($0.id) }
        }

        guard filterMode == .advanced else {
            return quickFiltered
        }
        return applyAdvancedFilters(to: quickFiltered)
    }

    private var advancedFilterSummaryLabel: String {
        let activeCount = activeAdvancedFilterRules.count
        if activeCount == 0 {
            return "Advanced Filter"
        }
        let mode = advancedFilterMatchMode == .all ? "AND" : "OR"
        return "\(activeCount) Rule\(activeCount == 1 ? "" : "s") • \(mode)"
    }

    private var activeAdvancedFilterRules: [AdvancedFilterRule] {
        advancedFilterRules.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @ViewBuilder
    private var advancedFilterPopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Advanced Filter")
                .font(.headline)

            HStack(spacing: 8) {
                Text("Match")
                    .foregroundStyle(.secondary)
                Picker("Match Mode", selection: $advancedFilterMatchMode) {
                    ForEach(AdvancedFilterMatchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if advancedFilterRules.isEmpty {
                Text("No rules yet. Add a rule to filter by duration, publication year, title, or author.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach($advancedFilterRules) { $rule in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Picker("Field", selection: $rule.field) {
                                    ForEach(AdvancedFilterField.allCases) { field in
                                        Text(field.rawValue).tag(field)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 150)
                                .onChange(of: rule.field, perform: { newField in
                                    let supported = supportedOperators(for: newField)
                                    if !supported.contains(rule.operation), let first = supported.first {
                                        rule.operation = first
                                    }
                                })

                                Picker("Operator", selection: $rule.operation) {
                                    ForEach(supportedOperators(for: rule.field)) { op in
                                        Text(op.rawValue).tag(op)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 140)

                                if rule.field == .duration {
                                    TextField("Value", text: $rule.value)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 90)
                                    Picker("Unit", selection: $rule.durationUnit) {
                                        ForEach(AdvancedDurationUnit.allCases) { unit in
                                            Text(unit.rawValue).tag(unit)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 120)
                                } else {
                                    TextField(rule.field == .publishedYear ? "Year" : "Value", text: $rule.value)
                                        .textFieldStyle(.roundedBorder)
                                }

                                Button(role: .destructive) {
                                    advancedFilterRules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Add Rule") {
                    advancedFilterRules.append(AdvancedFilterRule())
                }
                Button("Clear Rules", role: .destructive) {
                    advancedFilterRules = []
                }
                .disabled(advancedFilterRules.isEmpty)
                Spacer()
                Button("Done") {
                    showingAdvancedFilterPopover = false
                }
            }
        }
        .padding(14)
        .frame(minWidth: 640)
    }

    private func supportedOperators(for field: AdvancedFilterField) -> [AdvancedFilterOperator] {
        switch field {
        case .duration, .publishedYear:
            return [.equals, .notEquals, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual]
        case .title, .author:
            return [.equals, .notEquals, .contains, .notContains, .startsWith, .endsWith]
        }
    }

    private func applyAdvancedFilters(to items: [ABSCore.LibraryItem]) -> [ABSCore.LibraryItem] {
        let rules = activeAdvancedFilterRules
        guard !rules.isEmpty else { return items }

        return items.filter { item in
            let matches = rules.map { evaluateAdvancedFilter(rule: $0, item: item) }
            switch advancedFilterMatchMode {
            case .all:
                return matches.allSatisfy { $0 }
            case .any:
                return matches.contains(true)
            }
        }
    }

    private func evaluateAdvancedFilter(rule: AdvancedFilterRule, item: ABSCore.LibraryItem) -> Bool {
        switch rule.field {
        case .duration:
            guard let lhs = item.duration, lhs > 0 else { return false }
            guard let rhsInput = Double(rule.value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            let rhs = rhsInput * rule.durationUnit.multiplier
            return compareNumeric(lhs: lhs, rhs: rhs, operation: rule.operation)
        case .publishedYear:
            guard let lhs = item.publishedYear else { return false }
            guard let rhs = Int(rule.value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return compareNumeric(lhs: Double(lhs), rhs: Double(rhs), operation: rule.operation)
        case .title:
            return compareText(lhs: item.title, rhs: rule.value, operation: rule.operation)
        case .author:
            let lhs = displayAuthorNames(for: item).joined(separator: ", ")
            return compareText(lhs: lhs, rhs: rule.value, operation: rule.operation)
        }
    }

    private func compareNumeric(lhs: Double, rhs: Double, operation: AdvancedFilterOperator) -> Bool {
        switch operation {
        case .equals:
            return abs(lhs - rhs) < 0.0001
        case .notEquals:
            return abs(lhs - rhs) >= 0.0001
        case .greaterThan:
            return lhs > rhs
        case .greaterThanOrEqual:
            return lhs >= rhs
        case .lessThan:
            return lhs < rhs
        case .lessThanOrEqual:
            return lhs <= rhs
        case .contains, .notContains, .startsWith, .endsWith:
            return false
        }
    }

    private func compareText(lhs: String, rhs: String, operation: AdvancedFilterOperator) -> Bool {
        let left = lhs.lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !right.isEmpty else { return true }

        switch operation {
        case .equals:
            return left == right
        case .notEquals:
            return left != right
        case .contains:
            return left.contains(right)
        case .notContains:
            return !left.contains(right)
        case .startsWith:
            return left.hasPrefix(right)
        case .endsWith:
            return left.hasSuffix(right)
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            return false
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
        if currentBrowseTab == .stats {
            selectedItemID = nil
            selectedItemIDs = []
            selectedGroupID = nil
            return
        }

        if isBookListTab {
            let visibleIDs = Set(browsedItems.map(\.id))
            selectedItemIDs = selectedItemIDs.intersection(visibleIDs)
            if let selectedItemID, !visibleIDs.contains(selectedItemID) {
                self.selectedItemID = nil
            }
            if selectedItem == nil {
                selectedItemID = browsedItems.first?.id
                selectedItemIDs = selectedItemID.map { [$0] } ?? []
            } else if selectedItemIDs.isEmpty, let selectedItemID {
                selectedItemIDs = [selectedItemID]
            }
            selectedGroupID = nil
        } else {
            if selectedGroup == nil {
                selectedGroupID = displayedBrowseGroups.first?.id
            }
            selectedItemID = nil
            selectedItemIDs = []
        }
    }

    private var booksListSelectionBinding: Binding<Set<String>> {
        Binding(
            get: { selectedItemIDs },
            set: { newSelection in
                selectedItemIDs = newSelection
                if let selectedItemID, newSelection.contains(selectedItemID) {
                    return
                }
                selectedItemID = newSelection.first
            }
        )
    }

    private var selectedVisibleItemIDs: [String] {
        let visibleIDs = Set(browsedItems.map(\.id))
        let ids = selectedItemIDs.filter { visibleIDs.contains($0) }
        if !ids.isEmpty {
            return ids.sorted()
        }
        if let selectedItemID, visibleIDs.contains(selectedItemID) {
            return [selectedItemID]
        }
        return []
    }

    private var allSelectedVisibleItemsFavorited: Bool {
        let ids = selectedVisibleItemIDs
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { favoriteItemIDs.contains($0) }
    }

    private var canCopyToLocalLibrary: Bool {
        viewModel.canCopyFromSelectedLibraryToLocal
    }

    private func groupCopyItemIDs(for group: BrowseGroup) -> [String] {
        guard canCopyToLocalLibrary else { return [] }
        switch currentBrowseTab {
        case .authors, .series:
            return Array(Set(group.items.map(\.id))).sorted()
        default:
            return []
        }
    }

    private func groupCopyActionLabel(itemCount: Int) -> String {
        switch currentBrowseTab {
        case .authors:
            return "Copy Author to Local Library (\(itemCount))"
        case .series:
            return "Copy Series to Local Library (\(itemCount))"
        default:
            return "Copy to Local Library (\(itemCount))"
        }
    }

    private func contextSelectionIDs(for rowItemID: String) -> [String] {
        if selectedItemIDs.count > 1, selectedItemIDs.contains(rowItemID) {
            return selectedVisibleItemIDs
        }
        return [rowItemID]
    }

    private func contextSelectedDownloadedItemIDs(for rowItemID: String) -> [String] {
        contextSelectionIDs(for: rowItemID).filter { downloadedItemIDs.contains($0) }
    }

    private var selectedDownloadedItemIDs: [String] {
        selectedVisibleItemIDs.filter { downloadedItemIDs.contains($0) }
    }

    private var bulkActionsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Select All Visible (\(browsedItems.count))") {
                selectedItemIDs = Set(browsedItems.map(\.id))
                if selectedItemID == nil {
                    selectedItemID = browsedItems.first?.id
                }
                showingBulkActionsPopover = false
            }
            .disabled(browsedItems.isEmpty)

            Button("Clear Selection") {
                selectedItemIDs = []
                selectedItemID = nil
                showingBulkActionsPopover = false
            }
            .disabled(selectedVisibleItemIDs.isEmpty)

            Divider()

            Button("Download Selected to App Cache (\(selectedVisibleItemIDs.count))") {
                let ids = selectedVisibleItemIDs
                showingBulkActionsPopover = false
                Task { await downloadItems(ids) }
            }
            .disabled(selectedVisibleItemIDs.isEmpty)

            if canCopyToLocalLibrary {
                Button("Copy Selected to Local Library (\(selectedVisibleItemIDs.count))") {
                    let ids = selectedVisibleItemIDs
                    showingBulkActionsPopover = false
                    Task { await copyItemsToLocalLibrary(ids) }
                }
                .disabled(selectedVisibleItemIDs.isEmpty)
            }

            Button("Remove Downloaded Files (\(selectedDownloadedItemIDs.count))", role: .destructive) {
                let ids = selectedVisibleItemIDs
                showingBulkActionsPopover = false
                Task { await removeDownloads(ids) }
            }
            .disabled(selectedDownloadedItemIDs.isEmpty)

            if allSelectedVisibleItemsFavorited {
                Button("Unfavorite Selected (\(selectedVisibleItemIDs.count))") {
                    setFavorite(for: selectedVisibleItemIDs, isFavorite: false)
                    showingBulkActionsPopover = false
                }
                .disabled(selectedVisibleItemIDs.isEmpty)
            } else {
                Button("Favorite Selected (\(selectedVisibleItemIDs.count))") {
                    setFavorite(for: selectedVisibleItemIDs, isFavorite: true)
                    showingBulkActionsPopover = false
                }
                .disabled(selectedVisibleItemIDs.isEmpty)
            }

            Divider()

            Button("Mark Played (\(selectedVisibleItemIDs.count))") {
                let ids = selectedVisibleItemIDs
                showingBulkActionsPopover = false
                Task { await setPlayedState(for: ids, isPlayed: true) }
            }
            .disabled(selectedVisibleItemIDs.isEmpty)

            Button("Mark Unplayed (\(selectedVisibleItemIDs.count))") {
                let ids = selectedVisibleItemIDs
                showingBulkActionsPopover = false
                Task { await setPlayedState(for: ids, isPlayed: false) }
            }
            .disabled(selectedVisibleItemIDs.isEmpty)
        }
        .padding(12)
        .frame(width: 290, alignment: .leading)
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

    private var hasActiveDownloads: Bool {
        !downloadBusyItemIDs.isEmpty
    }

    private var downloadMenuItemIDs: [String] {
        let allIDs = Set(downloadedItemIDs)
            .union(downloadBusyItemIDs)
            .union(downloadQueuedItemIDs)
            .union(downloadRecoveredStateByItemID.keys)
            .union(copiedToLocalItemIDs)
        return allIDs.sorted { lhs, rhs in
            let lhsBusy = downloadBusyItemIDs.contains(lhs)
            let rhsBusy = downloadBusyItemIDs.contains(rhs)
            if lhsBusy != rhsBusy {
                return lhsBusy && !rhsBusy
            }
            let lhsQueued = downloadQueuedItemIDs.contains(lhs)
            let rhsQueued = downloadQueuedItemIDs.contains(rhs)
            if lhsQueued != rhsQueued {
                return lhsQueued && !rhsQueued
            }
            let lhsTitle = downloadDisplayTitle(for: lhs)
            let rhsTitle = downloadDisplayTitle(for: rhs)
            return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
        }
    }

    private func downloadDisplayTitle(for itemID: String) -> String {
        guard let item = viewModel.item(withID: itemID) else { return itemID }
        return item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? itemID : item.title
    }

    private func downloadRecoveryLabel(for itemID: String) -> String? {
        guard let state = downloadRecoveredStateByItemID[itemID] else { return nil }
        switch state {
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading…"
        case .recovered:
            return "Recovered after relaunch"
        case .restarted:
            return "Restarted after relaunch"
        case .failed:
            return "Failed (tap item to retry)"
        }
    }

    @ViewBuilder
    private func downloadLinearProgressBar(progress: Double) -> some View {
        let clamped = max(0, min(progress, 1))
        GeometryReader { geometry in
            let width = max(geometry.size.width, 0)
            let fillWidth = max(4, width * clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.orange)
                    .frame(width: fillWidth)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: 220)
        .opacity(0.9)
    }

    private var downloadsPopoverContent: some View {
        let itemIDs = downloadMenuItemIDs

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads (\(itemIDs.count))")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Go to Downloaded") {
                    openDownloadedListFromDownloadsPopover()
                }
                .disabled(viewModel.selectedLibraryID == nil)
            }

            if itemIDs.isEmpty {
                Text("No downloads yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(itemIDs.enumerated()), id: \.element) { index, itemID in
                            if index > 0 {
                                Divider()
                                    .opacity(0.45)
                            }
                            Button {
                                openItemFromDownloadsPopover(itemID)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(downloadDisplayTitle(for: itemID))
                                        .lineLimit(2)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)

                                    if let progress = downloadProgressByItemID[itemID] {
                                        downloadLinearProgressBar(progress: progress)
                                        Text("\(Int(max(0, min(progress, 1)) * 100))%")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else if let recoveryLabel = downloadRecoveryLabel(for: itemID) {
                                        Text(recoveryLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if downloadQueuedItemIDs.contains(itemID) {
                                        Text("Queued")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if copiedToLocalItemIDs.contains(itemID) {
                                        Text("Copied to Local Library")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Downloaded")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            Divider()

            HStack {
                Button(openLibraryFolderActionTitle) {
                    Task { await openPreferredLibraryFolderInFinder() }
                }

                Spacer()

                if currentBrowseTab == .downloaded {
                    Button(isClearingDownloads ? "Clearing…" : "Clear Downloads", role: .destructive) {
                        Task { await clearAllDownloads() }
                    }
                    .disabled(isClearingDownloads || downloadedItemIDs.isEmpty)
                }
            }

            HStack {
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if downloadPopoverDragStartWidth == nil {
                                    downloadPopoverDragStartWidth = downloadPopoverWidth
                                }
                                if downloadPopoverDragStartHeight == nil {
                                    downloadPopoverDragStartHeight = downloadPopoverHeight
                                }

                                let startWidth = downloadPopoverDragStartWidth ?? downloadPopoverWidth
                                let startOuterHeight = downloadPopoverDragStartHeight ?? downloadPopoverHeight
                                let nextWidth = startWidth + value.translation.width
                                let nextOuterHeight = startOuterHeight + value.translation.height
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    downloadPopoverWidth = min(max(nextWidth, 420), 1400)
                                    downloadPopoverHeight = min(max(nextOuterHeight, 360), 980)
                                }
                            }
                            .onEnded { _ in
                                downloadPopoverDragStartWidth = nil
                                downloadPopoverDragStartHeight = nil
                            }
                    )
                    .onTapGesture(count: 2) {
                        downloadPopoverWidth = 720
                        downloadPopoverHeight = 560
                    }
            }
        }
        .padding(14)
        .frame(width: downloadPopoverWidth, height: downloadPopoverHeight, alignment: .topLeading)
        .animation(nil, value: downloadPopoverWidth)
        .animation(nil, value: downloadPopoverHeight)
    }

    private func openDownloadedListFromDownloadsPopover() {
        guard let currentLibraryID = viewModel.selectedLibraryID else { return }
        browseTabByLibraryID[currentLibraryID] = .downloaded
        selectedGroupID = nil
        selectedItemID = browsedItems.first?.id
        showingDownloadsPopover = false
    }

    private func itemDownloadPopoverContent(item: ABSCore.LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(downloadBusyItemIDs.contains(item.id) ? "Downloading to App Cache…" : "Download to App Cache") {
                showingItemDownloadPopover = false
                Task { await downloadItem(item.id) }
            }
            .disabled(downloadBusyItemIDs.contains(item.id))

            Button("Download To…") {
                showingItemDownloadPopover = false
                Task { await downloadItemToChosenLocation(item: item) }
            }
            .disabled(downloadBusyItemIDs.contains(item.id))

            Button(openLibraryFolderActionTitle) {
                showingItemDownloadPopover = false
                Task { await openPreferredLibraryFolderInFinder() }
            }

            if downloadState(for: item.id) == .downloaded {
                Divider()
                Button("Remove Downloaded File", role: .destructive) {
                    showingItemDownloadPopover = false
                    Task { await removeDownload(for: item.id) }
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    private var activeDownloadProgress: Double? {
        guard hasActiveDownloads else { return nil }
        let values = downloadBusyItemIDs.compactMap { downloadProgressByItemID[$0] }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let clamped = min(max(mean, 0), 1)
        // Treat near-zero as indeterminate so UI still conveys "busy".
        return clamped > 0.001 ? clamped : nil
    }

    private var downloadMenuTitle: String {
        viewModel.isSelectedLibraryLocal ? "Local Library…" : "Download…"
    }

    private var openLibraryFolderActionTitle: String {
        viewModel.isSelectedLibraryLocal ? "Open Local Library in Finder" : "Open Download Cache in Finder"
    }

    private var downloadToolbarLabel: some View {
        let progress = activeDownloadProgress
        return Group {
            if hasActiveDownloads {
                let clamped = max(0.03, min(max(progress ?? 0.08, 0), 1))
                let step = Int((clamped * 100).rounded())
                Image(nsImage: downloadProgressIcon(progress: clamped))
                    .interpolation(.none)
                    .id("download-progress-\(step)")
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private func downloadProgressIcon(progress: Double) -> NSImage {
        let clamped = min(max(progress, 0), 1)
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 8.8

            let fillPath = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            NSColor.systemOrange.withAlphaComponent(0.16).setFill()
            fillPath.fill()

            let trackPath = NSBezierPath()
            trackPath.appendArc(withCenter: center, radius: radius - 1, startAngle: 0, endAngle: 360, clockwise: false)
            trackPath.lineWidth = 2.0
            trackPath.lineCapStyle = .round
            NSColor.systemOrange.withAlphaComponent(0.38).setStroke()
            trackPath.stroke()

            let progressPath = NSBezierPath()
            let endAngle = CGFloat(90 - (360 * clamped))
            progressPath.appendArc(withCenter: center, radius: radius - 1, startAngle: 90, endAngle: endAngle, clockwise: true)
            progressPath.lineWidth = 2.8
            progressPath.lineCapStyle = .round
            NSColor.systemOrange.setStroke()
            progressPath.stroke()

            let arrowPath = NSBezierPath()
            arrowPath.lineWidth = 1.8
            arrowPath.lineCapStyle = .round
            arrowPath.lineJoinStyle = .round
            arrowPath.move(to: NSPoint(x: center.x, y: center.y + 3.6))
            arrowPath.line(to: NSPoint(x: center.x, y: center.y - 1.6))
            arrowPath.move(to: NSPoint(x: center.x - 2.9, y: center.y - 0.5))
            arrowPath.line(to: NSPoint(x: center.x, y: center.y - 3.6))
            arrowPath.line(to: NSPoint(x: center.x + 2.9, y: center.y - 0.5))
            NSColor.white.withAlphaComponent(0.95).setStroke()
            arrowPath.stroke()

            return true
        }
        image.isTemplate = false
        return image
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
        detailRow(title: title, value: value, multiline: false)
    }

    private func detailRow(title: String, value: String, multiline: Bool) -> some View {
        HStack(alignment: multiline ? .top : .center) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(multiline ? nil : 1)
                .minimumScaleFactor(multiline ? 1 : 0.7)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: multiline)
        }
        .font(.body)
    }

    private func displayAuthorNames(for item: ABSCore.LibraryItem) -> [String] {
        let names = authorNames(for: item)
        if !names.isEmpty {
            return names
        }
        if let author = item.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            return [author]
        }
        return []
    }

    private func authorDisplayValue(for item: ABSCore.LibraryItem) -> String? {
        let names = displayAuthorNames(for: item)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }

    private func seriesValue(for item: ABSCore.LibraryItem) -> String? {
        let series = inferredSeriesName(for: item)
        guard series != "Unknown Series" else { return nil }
        if let sequence = seriesSequenceDisplayValue(for: item) {
            return "\(series) #\(sequence)"
        }
        return series
    }

    private func seriesDisplayLabel(for item: ABSCore.LibraryItem) -> String {
        seriesValue(for: item) ?? inferredSeriesName(for: item)
    }

    private func renderedBlurb(for item: ABSCore.LibraryItem) -> AttributedString? {
        guard let raw = item.blurb?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if raw.contains("<"), raw.contains(">"), let parsed = htmlAttributedString(raw) {
            return parsed
        }

        let stripped = strippedHTML(raw)
        guard !stripped.isEmpty else { return nil }
        return AttributedString(stripped)
    }

    private func htmlAttributedString(_ html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }

        do {
            let nsAttributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            let plain = nsAttributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return nil }
            return AttributedString(nsAttributed)
        } catch {
            return nil
        }
    }

    private func strippedHTML(_ input: String) -> String {
        let noTags = input.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        return noTags
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func visibleChapterCount(for item: ABSCore.LibraryItem) -> Int {
        if playbackDisplayItem?.id == item.id {
            let activeCount = currentChapters.count
            if activeCount > 0 {
                return activeCount
            }
        }
        return item.chapters.count
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
                await recoverPendingDownloadsIfNeeded()
                if let selectedLibraryID = viewModel.selectedLibraryID, browseTabByLibraryID[selectedLibraryID] == nil {
                    browseTabByLibraryID[selectedLibraryID] = .books
                }
                if isBookListTab {
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

    private func addLocalLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder containing audiobook files."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                try await viewModel.addLocalLibraryRoot(directoryURL: url)
                showingServerSheet = !viewModel.isAuthenticated && !viewModel.hasAnyLibraries
                if viewModel.selectedLibraryID == nil {
                    viewModel.selectedLibraryID = viewModel.libraries.first?.id
                }
                if let selectedLibraryID = viewModel.selectedLibraryID, browseTabByLibraryID[selectedLibraryID] == nil {
                    browseTabByLibraryID[selectedLibraryID] = .books
                }
                if isBookListTab {
                    selectedItemID = browsedItems.first?.id
                    selectedGroupID = nil
                } else {
                    selectedGroupID = displayedBrowseGroups.first?.id
                    selectedItemID = nil
                }
            } catch {
                viewModel.setError("Failed to add local folder: \(viewModel.describeError(error))")
            }
        }
    }

    private func rescanLocalLibraries() {
        Task {
            do {
                try await viewModel.rescanLocalLibraries()
                if isBookListTab {
                    selectedItemID = browsedItems.first?.id
                    selectedGroupID = nil
                } else {
                    selectedGroupID = displayedBrowseGroups.first?.id
                    selectedItemID = nil
                }
            } catch {
                viewModel.setError("Failed to rescan local libraries: \(viewModel.describeError(error))")
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
            isPlaying: isPlaying,
            artworkImage: coverImagesByItemID[item.id]
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

                let url = try await viewModel.playbackURL(for: item.id)
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
        let target = await MainActor.run { () -> (itemID: String, duration: TimeInterval?)? in
            guard let item = selectedItem else { return nil }
            return (item.id, item.duration)
        }
        guard let target else { return }

        let local = await MainActor.run { savedProgress(for: target.itemID) }
        if let remote = try? await viewModel.fetchProgress(itemID: target.itemID) {
            let remotePosition = max(0, remote.positionSeconds)
            if abs(remotePosition - local) > 0.5 {
                await MainActor.run {
                    persistProgress(itemID: target.itemID, seconds: remotePosition, source: .absServer)
                    if activeItemID == target.itemID, !isTimelineScrubbing {
                        elapsedSeconds = remotePosition
                    }
                }
            }

            if let finished = remote.isFinished {
                await MainActor.run {
                    playedStateByItemID[target.itemID] = finished
                }
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

    private var transportStatusDisplay: String {
        guard viewModel.isAuthenticated else { return "Unavailable" }
        guard let probe = viewModel.liveTransportProbe else { return "Probing…" }

        switch probe.recommended {
        case .webSocket:
            return "WebSocket"
        case .serverSentEvents:
            return "Server-Sent Events"
        case .polling:
            return "Polling"
        }
    }

    private func listeningDeltasByDay(for itemIDs: Set<String>) -> [Date: TimeInterval] {
        guard !itemIDs.isEmpty else { return [:] }
        let calendar = Calendar.current
        var totals: [Date: TimeInterval] = [:]

        for itemID in itemIDs {
            let history = (progressHistoryByItemID[itemID] ?? [])
                .sorted { $0.occurredAt < $1.occurredAt }
            guard !history.isEmpty else { continue }

            var previousPosition: TimeInterval = 0
            for entry in history {
                if entry.source == .appClear {
                    previousPosition = 0
                    continue
                }
                let delta = max(0, entry.positionSeconds - previousPosition)
                previousPosition = entry.positionSeconds
                guard delta > 0 else { continue }
                let day = calendar.startOfDay(for: entry.occurredAt)
                totals[day, default: 0] += delta
            }
        }

        return totals
    }

    private func listeningSecondsFromDeltas(_ deltasByDay: [Date: TimeInterval], since: Date?) -> TimeInterval {
        guard let since else {
            return deltasByDay.values.reduce(0, +)
        }
        let thresholdDay = Calendar.current.startOfDay(for: since)
        return deltasByDay
            .filter { $0.key >= thresholdDay }
            .map(\.value)
            .reduce(0, +)
    }

    private func streakFromDeltas(_ deltasByDay: [Date: TimeInterval]) -> Int {
        guard !deltasByDay.isEmpty else { return 0 }
        let calendar = Calendar.current
        let activeDays = Set(deltasByDay.keys.map { calendar.startOfDay(for: $0) })
        var day = calendar.startOfDay(for: Date())
        var streak = 0

        while activeDays.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        return streak
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

    private func startLiveUpdatesIfNeeded() {
        guard liveUpdateTask == nil else { return }
        guard viewModel.isAuthenticated else { return }

        liveUpdateTask = Task {
            let eventStream = await viewModel.liveUpdateEvents()
            var eventDrivenTask: Task<Void, Never>?

            if let eventStream {
                eventDrivenTask = Task {
                    var eventCount = 0
                    var lastEventDrivenTick: Date?
                    do {
                        // Prime with an initial refresh to avoid stale state while waiting for first event.
                        await performLiveUpdateTick(refreshLibraries: true)

                        for try await _ in eventStream {
                            if Task.isCancelled { break }
                            let shouldRunNow = await MainActor.run { scenePhase == .active && viewModel.isAuthenticated }
                            guard shouldRunNow else { continue }

                            let now = Date()
                            if let last = lastEventDrivenTick, now.timeIntervalSince(last) < 1.0 {
                                // Coalesce noisy transport bursts.
                                continue
                            }
                            lastEventDrivenTick = now

                            let refreshLibraries = (eventCount % 12) == 0
                            await performLiveUpdateTick(refreshLibraries: refreshLibraries)
                            eventCount += 1
                        }
                    } catch {
                        // Transport stream failed; periodic fallback loop below remains active.
                    }
                }
            }

            // Periodic reconciliation path always runs, even with live events.
            // This ensures server-side progress/played-state changes still land when transport
            // does not emit an item-progress event for a given action.
            let selectedItemReconcileIntervalWithLiveTransport: Duration = .seconds(3)
            let fallbackPollingInterval: Duration = .seconds(15)
            var tick = 0
            while !Task.isCancelled {
                let shouldRunNow = await MainActor.run { scenePhase == .active && viewModel.isAuthenticated }
                if shouldRunNow {
                    if eventStream == nil {
                        let refreshLibraries = (tick % 4) == 0
                        await performLiveUpdateTick(refreshLibraries: refreshLibraries)
                        try? await Task.sleep(for: fallbackPollingInterval)
                    } else {
                        await syncSelectedItemProgressFromServer()
                        try? await Task.sleep(for: selectedItemReconcileIntervalWithLiveTransport)
                    }
                    tick += 1
                } else {
                    try? await Task.sleep(for: .seconds(30))
                }
            }

            eventDrivenTask?.cancel()
        }
    }

    private func stopLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
    }

    private func restartLiveUpdatesIfNeeded() {
        stopLiveUpdates()
        startLiveUpdatesIfNeeded()
    }

    private func performLiveUpdateTick(refreshLibraries: Bool) async {
        guard viewModel.isAuthenticated else { return }
        let currentSearchQuery = await MainActor.run { trimmedSearchText }
        let selectedID = await MainActor.run { selectedItemID }

        if refreshLibraries {
            // Keep library metadata current without replacing the currently filtered list.
            try? await viewModel.refreshLibrariesMetadataOnly()
        }
        // Always refresh the current browse/search context in one pass.
        await viewModel.liveRefreshCurrentContext(searchQuery: currentSearchQuery)
        if let selectedID {
            // Ensure selected item metadata/progress stays fresh without requiring reselection.
            await viewModel.refreshDetailsForSelectedItem(itemID: selectedID)
        }

        await syncSelectedItemProgressFromServer()
        await refreshDownloadedInventory()
        await refreshDownloadStates(for: viewModel.displayedItems.map(\.id))
        await MainActor.run {
            lastLiveUpdateAt = Date()
            // Defer selection normalization to avoid reentrant NSTableView delegate updates.
            DispatchQueue.main.async {
                refreshSelectionForCurrentBrowseContext()
            }
        }
    }

    private func downloadState(for itemID: String) -> DownloadState {
        if downloadBusyItemIDs.contains(itemID) {
            return .downloading
        }
        if downloadQueuedItemIDs.contains(itemID) {
            return .downloading
        }
        if let state = downloadStateByItemID[itemID] {
            return state
        }
        return downloadedItemIDs.contains(itemID) ? .downloaded : .notDownloaded
    }

    private func refreshDownloadedInventory() async {
        downloadedItemIDs = await viewModel.downloadedItemIDs()
    }

    private func refreshDownloadStates(for itemIDs: [String]) async {
        let uniqueItemIDs = Array(Set(itemIDs))
        guard !uniqueItemIDs.isEmpty else { return }

        var updates: [String: DownloadState] = [:]
        for itemID in uniqueItemIDs {
            updates[itemID] = await viewModel.downloadState(for: itemID)
        }
        for (itemID, state) in updates {
            downloadStateByItemID[itemID] = state
        }
    }

    private func recoverPendingDownloadsIfNeeded() async {
        guard viewModel.isAuthenticated else { return }
        guard !hasAttemptedDownloadRecovery else { return }
        hasAttemptedDownloadRecovery = true

        let recovered = await viewModel.recoverPendingDownloadJobs()
        guard !recovered.isEmpty else { return }

        for job in recovered {
            downloadRecoveredStateByItemID[job.itemID] = job.state
        }

        let autoRestartIDs = recovered
            .filter { $0.state != .failed }
            .map(\.itemID)

        let queuedNow = autoRestartIDs.filter { !downloadedItemIDs.contains($0) && !downloadBusyItemIDs.contains($0) }
        downloadQueuedItemIDs.formUnion(queuedNow)

        for itemID in autoRestartIDs {
            await downloadItem(itemID)
        }
    }

    private func downloadItem(_ itemID: String) async {
        guard !downloadBusyItemIDs.contains(itemID) else { return }
        await viewModel.queueDownloadJob(itemID: itemID)
        downloadQueuedItemIDs.remove(itemID)
        downloadRecoveredStateByItemID[itemID] = .downloading
        copiedToLocalItemIDs.remove(itemID)
        downloadBusyItemIDs.insert(itemID)
        downloadProgressByItemID[itemID] = 0
        defer {
            downloadBusyItemIDs.remove(itemID)
            downloadProgressByItemID.removeValue(forKey: itemID)
        }

        do {
            _ = try await viewModel.downloadItem(itemID: itemID, progress: { progress in
                await MainActor.run {
                    downloadProgressByItemID[itemID] = progress
                }
            })
            downloadStateByItemID[itemID] = .downloaded
            downloadedItemIDs.insert(itemID)
            downloadRecoveredStateByItemID.removeValue(forKey: itemID)
        } catch {
            viewModel.setError("Download failed: \(viewModel.describeError(error))")
            downloadRecoveredStateByItemID[itemID] = .failed
            await refreshDownloadStates(for: [itemID])
        }
    }

    private func openDownloadCacheInFinder() async {
        guard let cacheURL = await viewModel.downloadCacheDirectoryURL() else {
            viewModel.setError("Download cache unavailable")
            return
        }

        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(cacheURL)
    }

    private func openPreferredLibraryFolderInFinder() async {
        if viewModel.isSelectedLibraryLocal {
            guard let localRootURL = viewModel.selectedLocalLibraryRootURL() else {
                viewModel.setError("Local library folder unavailable")
                return
            }
            NSWorkspace.shared.open(localRootURL)
            return
        }
        await openDownloadCacheInFinder()
    }

    private func downloadItemToChosenLocation(item: ABSCore.LibraryItem) async {
        guard !downloadBusyItemIDs.contains(item.id) else { return }
        guard let directory = promptForDownloadDirectory() else { return }

        downloadQueuedItemIDs.remove(item.id)
        downloadBusyItemIDs.insert(item.id)
        downloadProgressByItemID[item.id] = 0
        defer {
            downloadBusyItemIDs.remove(item.id)
            downloadProgressByItemID.removeValue(forKey: item.id)
        }

        do {
            let destination = try await viewModel.downloadItemToDirectory(
                itemID: item.id,
                directoryURL: directory,
                progress: { progress in
                    await MainActor.run {
                        downloadProgressByItemID[item.id] = progress
                    }
                }
            )
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            viewModel.setError("Download failed: \(viewModel.describeError(error))")
        }
    }

    private func promptForDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = "Select Download Location"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func removeDownload(for itemID: String) async {
        guard !downloadBusyItemIDs.contains(itemID) else { return }
        downloadBusyItemIDs.insert(itemID)
        defer { downloadBusyItemIDs.remove(itemID) }

        do {
            try await viewModel.removeDownloadedItem(itemID: itemID)
            downloadStateByItemID[itemID] = .notDownloaded
            downloadedItemIDs.remove(itemID)
            downloadRecoveredStateByItemID.removeValue(forKey: itemID)
            copiedToLocalItemIDs.remove(itemID)
        } catch {
            viewModel.setError("Failed removing download: \(viewModel.describeError(error))")
        }
    }

    private func clearAllDownloads() async {
        guard !isClearingDownloads else { return }
        isClearingDownloads = true
        defer { isClearingDownloads = false }

        do {
            try await viewModel.clearAllDownloads()
            downloadedItemIDs.removeAll()
            downloadQueuedItemIDs.removeAll()
            downloadProgressByItemID.removeAll()
            downloadRecoveredStateByItemID.removeAll()
            copiedToLocalItemIDs.removeAll()
            for itemID in downloadStateByItemID.keys {
                downloadStateByItemID[itemID] = .notDownloaded
            }
            if currentBrowseTab == .downloaded {
                selectedItemID = browsedItems.first?.id
            }
        } catch {
            viewModel.setError("Failed clearing downloads: \(viewModel.describeError(error))")
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
            if let remote = try? await viewModel.fetchProgress(itemID: item.id) {
                if let finished = remote.isFinished {
                    await MainActor.run {
                        playedStateByItemID[item.id] = finished
                    }
                }

                let remotePosition = max(0, remote.positionSeconds)
                if abs(remotePosition - local) > 0.5 {
                    await MainActor.run {
                        persistProgress(itemID: item.id, seconds: remotePosition, source: .absServer)
                        if activeItemID == item.id, !isTimelineScrubbing {
                            elapsedSeconds = remotePosition
                        }
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
        playedStateByItemID = [:]
        progressHistoryByItemID = [:]
        favoriteItemIDs = []
        recentActivityByItemID = [:]
        downloadedItemIDs = []
        downloadStateByItemID = [:]
        downloadBusyItemIDs = []
        downloadQueuedItemIDs = []
        downloadProgressByItemID = [:]
        downloadRecoveredStateByItemID = [:]
        copiedToLocalItemIDs = []
        isClearingDownloads = false
        hasAttemptedDownloadRecovery = false
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

    private func isMarkedPlayed(itemID: String, duration: TimeInterval?) -> Bool {
        if let explicitState = playedStateByItemID[itemID] {
            return explicitState
        }
        guard let duration, duration > 1 else { return false }
        return savedProgress(for: itemID) >= (duration - 1)
    }

    private func clearSavedProgress(itemID: String) {
        persistProgress(itemID: itemID, seconds: 0, source: .appClear)
        if activeItemID == itemID {
            seek(to: 0)
        }
    }

    private func clearSavedProgressEverywhere(item: ABSCore.LibraryItem) {
        clearSavedProgress(itemID: item.id)
        playedStateByItemID[item.id] = false
        Task {
            _ = await viewModel.uploadProgressToServer(
                itemID: item.id,
                positionSeconds: 0,
                durationSeconds: item.duration
            )
        }
    }

    private func setPlayedState(for itemIDs: [String], isPlayed: Bool) async {
        let unique = Array(Set(itemIDs)).sorted()
        guard !unique.isEmpty else { return }

        for itemID in unique {
            guard let item = viewModel.item(withID: itemID) else { continue }
            let localPosition = savedProgress(for: itemID)
            guard let pushed = await viewModel.setPlayedState(
                itemID: itemID,
                isPlayed: isPlayed,
                durationSeconds: item.duration,
                currentPositionSeconds: localPosition
            ) else {
                continue
            }

            await MainActor.run {
                playedStateByItemID[itemID] = isPlayed
                let resolvedDuration = pushed.durationSeconds ?? item.duration
                let localResolvedPosition: TimeInterval = {
                    if isPlayed {
                        if let resolvedDuration, resolvedDuration > 0 {
                            return max(localPosition, resolvedDuration)
                        }
                        return max(localPosition, pushed.positionSeconds)
                    }
                    return 0
                }()
                persistProgress(
                    itemID: itemID,
                    seconds: localResolvedPosition,
                    source: isPlayed ? .manualUpload : .appClear
                )
                if activeItemID == itemID, !isPlayed {
                    seek(to: 0)
                }
            }
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

    private func setFavorite(for itemIDs: [String], isFavorite: Bool) {
        guard !itemIDs.isEmpty else { return }
        for itemID in itemIDs {
            if isFavorite {
                favoriteItemIDs.insert(itemID)
                markRecentActivity(itemID: itemID, force: true)
            } else {
                favoriteItemIDs.remove(itemID)
            }
        }
        UserDefaults.standard.set(Array(favoriteItemIDs).sorted(), forKey: favoritesDefaultsKey)
    }

    private func downloadItems(_ itemIDs: [String]) async {
        let ordered = Array(Set(itemIDs)).sorted()
        let queuedNow = ordered.filter { !downloadBusyItemIDs.contains($0) && !downloadedItemIDs.contains($0) }
        downloadQueuedItemIDs.formUnion(queuedNow)
        for itemID in queuedNow {
            await viewModel.queueDownloadJob(itemID: itemID)
            if downloadRecoveredStateByItemID[itemID] == nil {
                downloadRecoveredStateByItemID[itemID] = .queued
            }
        }
        for itemID in ordered {
            await downloadItem(itemID)
        }
    }

    private func copyItemsToLocalLibrary(_ itemIDs: [String]) async {
        guard canCopyToLocalLibrary else { return }

        let ordered = Array(Set(itemIDs)).sorted()
        let copyCandidates = ordered.filter { itemID in
            guard let item = viewModel.item(withID: itemID) else { return false }
            return !item.libraryID.hasPrefix(LocalLibraryManager.libraryIDPrefix)
        }
        guard !copyCandidates.isEmpty else { return }

        guard let targetRootID = viewModel.preferredLocalCopyRootID() else {
            viewModel.setError("No local library available for copy")
            return
        }

        let queuedNow = copyCandidates.filter { !downloadBusyItemIDs.contains($0) }
        downloadQueuedItemIDs.formUnion(queuedNow)
        for itemID in queuedNow where downloadRecoveredStateByItemID[itemID] == nil {
            downloadRecoveredStateByItemID[itemID] = .queued
        }

        var copiedAny = false
        for itemID in copyCandidates {
            let didCopy = await copyItemToLocalLibrary(itemID, targetRootID: targetRootID)
            copiedAny = copiedAny || didCopy
        }

        if copiedAny {
            do {
                try await viewModel.rescanLocalLibraryRoot(id: targetRootID)
            } catch {
                let targetName = viewModel.localLibraryRootName(rootID: targetRootID) ?? "Local Library"
                viewModel.setError("Copied files, but failed to refresh \(targetName): \(viewModel.describeError(error))")
            }
        }
    }

    @discardableResult
    private func copyItemToLocalLibrary(_ itemID: String, targetRootID: String) async -> Bool {
        guard !downloadBusyItemIDs.contains(itemID) else { return false }

        downloadQueuedItemIDs.remove(itemID)
        downloadRecoveredStateByItemID[itemID] = .downloading
        downloadBusyItemIDs.insert(itemID)
        copiedToLocalItemIDs.remove(itemID)
        downloadProgressByItemID[itemID] = 0
        defer {
            downloadBusyItemIDs.remove(itemID)
            downloadProgressByItemID.removeValue(forKey: itemID)
        }

        do {
            _ = try await viewModel.copyItemToLocalLibrary(
                itemID: itemID,
                targetRootID: targetRootID,
                organizationOptions: AppViewModel.LocalCopyOrganizationOptions(
                    enabled: preferences.localFileOrganizationEnabled,
                    template: preferences.localFileOrganizationTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? AppPreferences.defaultLocalFileOrganizationTemplate
                        : preferences.localFileOrganizationTemplate
                ),
                progress: { progress in
                    await MainActor.run {
                        downloadProgressByItemID[itemID] = progress
                    }
                }
            )
            downloadRecoveredStateByItemID.removeValue(forKey: itemID)
            copiedToLocalItemIDs.insert(itemID)
            return true
        } catch {
            viewModel.setError("Copy to local library failed: \(viewModel.describeError(error))")
            downloadRecoveredStateByItemID[itemID] = .failed
            return false
        }
    }

    private func removeDownloads(_ itemIDs: [String]) async {
        let removable = Array(Set(itemIDs)).filter { downloadedItemIDs.contains($0) }.sorted()
        guard !removable.isEmpty else { return }
        for itemID in removable {
            await removeDownload(for: itemID)
        }
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
            let url = try await viewModel.playbackURL(for: item.id)
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
            updateNowPlaying()
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
