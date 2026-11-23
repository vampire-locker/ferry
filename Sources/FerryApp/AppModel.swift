import AppKit
import CryptoKit
import FerryCore
import SwiftUI

struct FolderLocation: Identifiable {
  let id: UInt32
  let name: String
}

enum AppPage {
  case browser, downloads, tools
}

struct EnqueueFeedback: Identifiable {
  let id: Int
  let itemCount: Int
}

/// Only queue changes that affect browsing belong to AppModel. Byte progress
/// and timing stay on DownloadQueueController so they cannot rebuild the table.
struct DownloadQueueSummary: Equatable {
  var pendingTaskCount = 0
  var hasTasks = false
  var isTransferring = false
  var hasScheduledWork = false

  var hasPendingTasks: Bool { pendingTaskCount > 0 }
}

private struct DirectorySnapshot {
  let entries: [RemoteEntry]
  let sortOrder: [KeyPathComparator<RemoteEntry>]
  let yearIndex: DirectoryYearIndex
  let hasUnloadedSizes: Bool
}

private enum FrequentNavigationFailure: Error {
  case cancelled, notFound
}

private struct FileFilterKey: Hashable {
  let year: DirectoryYearFilter
  let month: DirectoryMonthFilter
  let media: DirectoryMediaFilter
  let showHidden: Bool
  let query: String
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var selectedPage: AppPage = .browser
  @Published private(set) var enqueueFeedback: EnqueueFeedback?
  @Published private(set) var enqueueRevision = 0
  @Published var demo =
    ProcessInfo.processInfo.arguments.contains("--demo")
    || ProcessInfo.processInfo.environment["FERRY_DEMO"] == "1"
  @Published var deviceName = L10n.text("尚未连接手机")
  @Published var storages: [DeviceStorage] = []
  @Published private(set) var usbDevices: [USBDeviceChoice] = []
  @Published private(set) var selectedUSBDeviceID: UInt64?
  @Published private(set) var frequentDirectories: [FrequentDirectory] = []
  @Published var storageID: UInt32 = 0
  @Published var entries: [RemoteEntry] = [] {
    didSet {
      cachedYearOptions = nil
      cachedMonthOptions.removeAll()
      filterResults.removeAll()
      filterResultOrder.removeAll()
      appliedFilterKey = nil
      refreshVisibleEntries()
    }
  }
  @Published var sortOrder = DirectoryOrdering.defaultOrder {
    didSet { if sortOrder != oldValue { resortDirectory() } }
  }
  @Published private(set) var hasUnloadedSizes = false
  @Published private(set) var sorting = false
  @Published private(set) var filtering = false
  @Published var selection = Set<UInt32>()
  @Published var folders: [FolderLocation] = []
  @Published var query = "" { didSet { refreshVisibleEntries() } }
  @Published private(set) var yearFilter: DirectoryYearFilter = .all
  @Published private(set) var monthFilter: DirectoryMonthFilter = .all
  @Published private(set) var mediaFilter: DirectoryMediaFilter = .all
  @Published private(set) var yearOptions = [DirectoryYearOption(filter: .all, count: 0)]
  @Published private(set) var monthOptions = [DirectoryMonthOption(filter: .all, count: 0)]
  @Published private(set) var showHiddenFiles: Bool
  @Published private(set) var visibleEntries: [RemoteEntry] = []
  @Published private(set) var hiddenEntryCount = 0
  @Published private(set) var viewMode: BrowserViewMode
  @Published private(set) var languagePreference: AppLanguage
  @Published private(set) var appearance: AppAppearance
  @Published private(set) var allowUSBCapture: Bool
  let usbCaptureAvailable: Bool
  let usbCaptureRequiresAdministrator: Bool
  let media: MediaController
  let downloadQueue: DownloadQueueController
  let photoDateRepair = PhotoDateRepairController()
  let duplicatePhotos = DuplicatePhotosController()
  let mediaArchive = LocalMediaArchiveController()
  let mediaRename = LocalMediaArchiveController(operation: .renameMedia)
  @Published private(set) var selectedLocalTool: LocalTool?
  private let preferences: UserDefaults
  static let showHiddenFilesKey = "showHiddenFiles"
  static let viewModeKey = "browserViewMode"
  static let frequentDirectoriesKey = "frequentDirectories.v1"
  static let createDownloadFolderKey = "createDownloadFolder"
  @Published private(set) var createDownloadFolder = false
  static let usePhotoCreationDateKey = "usePhotoCreationDate"
  @Published private(set) var usePhotoCreationDate = false
  static let archivePhotosByMonthKey = "archivePhotosByMonth"
  @Published private(set) var archivePhotosByMonth = false
  static let archiveVideosByMonthKey = "archiveVideosByMonth"
  @Published private(set) var archiveVideosByMonth = false
  private var frequentHistory: FrequentDirectoryHistory
  private var sessionFrequentHistory = FrequentDirectoryHistory()
  private var frequentDeviceID: String?
  private var persistFrequentVisits = false
  // Only valid for this connection. Persistent records never contain handles.
  private var frequentSessionPaths: [UUID: [FolderLocation]] = [:]
  @Published var busy = false
  @Published private(set) var downloadSummary = DownloadQueueSummary()
  var downloading: Bool { downloadSummary.isTransferring }
  @Published var cancelling = false
  @Published var status = L10n.text("正在检测已连接的手机…")
  @Published var error: String?
  @Published private(set) var destination: URL
  private let destinationIsAvailable: (URL) -> Bool
  @Published private var foregroundOutput: URL?
  var output: URL? { downloadQueue.focusedTask?.output ?? foregroundOutput }
  var currentFile: String { downloadQueue.focusedTask?.currentFile ?? "" }
  var completed: Int { downloadQueue.focusedTask?.completed ?? 0 }
  var total: Int { downloadQueue.focusedTask?.total ?? 0 }
  var transferred: Int64 { downloadQueue.focusedTask?.transferred ?? 0 }
  var totalBytes: Int64 { downloadQueue.focusedTask?.totalBytes ?? 0 }
  var taskState: String { downloadQueue.focusedTask?.state.rawValue ?? "" }
  var downloadTiming: TransferTiming { downloadQueue.focusedTask?.timing ?? TransferTiming() }
  private let uptime: () -> TimeInterval
  var downloadElapsed: TimeInterval? { downloadTiming.elapsed(at: uptime()) }
  var downloadRemaining: TimeInterval? { downloadTiming.estimatedRemaining(at: uptime()) }
  let runner: any EngineRunning
  private var deviceKey = ""
  private var deviceRecoveryIdentity = ""
  private var activeUSBTarget: USBDeviceTarget?
  private var gridSelectionAnchor: UInt32?
  private var yearIndex = DirectoryYearIndex()
  private var visibleEntryIDs = Set<UInt32>()
  // Pin the navigation path, plus a bounded LRU of recently left folders.
  // Returning to a sibling/descendant should not trigger another phone scan.
  private var directoryCache: [UInt32: DirectorySnapshot] = [:]
  private var directoryRecency: [UInt32] = []
  private let recentDirectoryLimit = 4
  private let recentEntryLimit = 100_000
  private var appliedSortOrder = DirectoryOrdering.defaultOrder
  private var sortTask: Task<Void, Never>?
  private var sortGeneration = 0
  private var filterTask: Task<Void, Never>?
  private var filterGeneration = 0
  private var cachedYearOptions: [DirectoryYearOption]?
  private var cachedMonthOptions: [DirectoryYearFilter: [DirectoryMonthOption]] = [:]
  private var filterResults: [FileFilterKey: DirectoryFilterResult] = [:]
  private var filterResultOrder: [FileFilterKey] = []
  private var appliedFilterKey: FileFilterKey?
  private var fileFilterKey: FileFilterKey {
    FileFilterKey(
      year: yearFilter, month: monthFilter, media: mediaFilter, showHidden: showHiddenFiles,
      query: query)
  }
  private var needsSizeOrder: Bool {
    sortOrder.contains { $0.keyPath == \RemoteEntry.sortSize || $0.keyPath == \RemoteEntry.size }
  }
  private var task: Task<Void, Never>?
  private var foregroundRequestStarted = false
  private let usbMonitor: any USBMonitoring
  private var autoConnectPolicy = AutoConnectPolicy()
  private var autoConnectTask: Task<Void, Never>?
  private var lifecycleStarted = false
  private var usbMonitoringPaused = false
  private var isShuttingDown = false
  private var connectionInterfaces: Set<UInt64> = []
  private var usbGeneration = 0

  init(
    runner: (any EngineRunning)? = nil, usbMonitor: any USBMonitoring = USBDeviceMonitor(),
    preferences: UserDefaults = .standard,
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    destinationIsAvailable: @escaping (URL) -> Bool = DownloadDestination.isAvailable,
    downloadStoreURL: URL? = nil
  ) {
    self.uptime = uptime
    self.preferences = preferences
    self.destinationIsAvailable = destinationIsAvailable
    frequentHistory = FrequentDirectoryHistory(
      data: preferences.data(forKey: Self.frequentDirectoriesKey))
    allowUSBCapture =
      preferences.object(forKey: EngineRunner.usbCapturePreferenceKey) as? Bool ?? true
    languagePreference =
      AppLanguage(rawValue: preferences.string(forKey: L10n.languagePreferenceKey) ?? "") ?? .system
    appearance =
      AppAppearance(rawValue: preferences.string(forKey: AppAppearance.preferenceKey) ?? "")
      ?? .system
    showHiddenFiles = preferences.bool(forKey: Self.showHiddenFilesKey)
    createDownloadFolder = preferences.bool(forKey: Self.createDownloadFolderKey)
    usePhotoCreationDate = preferences.bool(forKey: Self.usePhotoCreationDateKey)
    archivePhotosByMonth = preferences.bool(forKey: Self.archivePhotosByMonthKey)
    archiveVideosByMonth = preferences.bool(forKey: Self.archiveVideosByMonthKey)
    viewMode =
      BrowserViewMode(rawValue: preferences.string(forKey: Self.viewModeKey) ?? "") ?? .list
    self.usbMonitor = usbMonitor
    destination = DownloadDestination.restore(from: preferences)
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ferry-engine")
    let environmentPath = ProcessInfo.processInfo.environment["FERRY_ENGINE_PATH"]
    let resolvedRunner =
      runner ?? EngineRunner(executable: environmentPath.map { URL(fileURLWithPath: $0) } ?? helper)
    self.runner = resolvedRunner
    usbCaptureAvailable = resolvedRunner.usbCaptureSupported
    usbCaptureRequiresAdministrator = resolvedRunner.usbCaptureRequiresAdministrator
    media = MediaController(runner: resolvedRunner)
    downloadQueue = DownloadQueueController(
      runner: resolvedRunner, uptime: uptime, destinationIsAvailable: destinationIsAvailable,
      storeURL: downloadStoreURL ?? (runner == nil ? DownloadTaskStore.defaultURL : nil))
    allowUSBCapture = allowUSBCapture && usbCaptureAvailable
    downloadQueue.beforeRequests = { [weak self] in
      guard let self else { return }
      self.media.suspend()
      await self.media.waitUntilIdle()
    }
    downloadQueue.canResume = { [weak self] request, demo in
      guard let self else { return false }
      return self.demo == demo && self.deviceKey == request.deviceKey
        && self.activeUSBTarget == request.usbTarget
        && self.storages.contains { $0.id == request.storageID }
    }
    downloadQueue.recoveryRequest = { [weak self] request, demo in
      guard let self, self.demo == demo, !self.deviceKey.isEmpty,
        self.deviceKey == request.deviceKey, request.recoveryIdentity == self.deviceRecoveryIdentity
      else { return nil }
      if let old = request.usbTarget, !old.serialNumber.isEmpty,
        old.serialNumber != self.activeUSBTarget?.serialNumber
      {
        return nil
      }
      let matches = self.storages.filter {
        if let storage = request.sourceStorage {
          return $0.name == storage.name && $0.capacity == storage.capacity
        }
        return $0.id == request.storageID
      }
      guard matches.count == 1 else { return nil }
      var rebound = request
      rebound.storageID = matches[0].id
      rebound.usbTarget = self.activeUSBTarget
      return rebound
    }
    downloadQueue.onChange = { [weak self] in self?.synchronizeDownloads() }
    synchronizeDownloads()
  }

  var fileActionsBlocked: Bool { busy || filtering || selectedPage != .browser }
  var previewActionsBlocked: Bool { fileActionsBlocked || downloadQueue.hasPendingTasks }
  var connectionActionsBlocked: Bool { busy || downloadQueue.hasScheduledWork }

  func selectPage(_ page: AppPage) {
    guard page != selectedPage else { return }
    selectedPage = page
    if page != .browser {
      media.suspend()
      if page == .tools {
        autoConnectTask?.cancel()
        autoConnectTask = nil
      }
    } else {
      resumeMedia()
      if storages.isEmpty { scheduleAutoConnect() }
    }
  }

  func selectLocalTool(_ tool: LocalTool?) {
    if let tool {
      guard !photoDateRepair.isBusy || tool == .dates,
        !duplicatePhotos.isBusy || tool == .duplicates,
        !mediaArchive.isBusy || tool == .archive,
        !mediaRename.isBusy || tool == .rename
      else { return }
    }
    selectedLocalTool = tool
  }

  func setLanguage(_ language: AppLanguage) {
    languagePreference = language
    preferences.set(language.rawValue, forKey: L10n.languagePreferenceKey)
    if language == .system {
      preferences.removeObject(forKey: "AppleLanguages")
    } else {
      preferences.set([language.rawValue], forKey: "AppleLanguages")
    }
  }

  func setAppearance(_ value: AppAppearance) {
    appearance = value
    preferences.set(value.rawValue, forKey: AppAppearance.preferenceKey)
    NSApp?.appearance = value.nativeAppearance
  }

  func setAllowUSBCapture(_ enabled: Bool) {
    guard !connectionActionsBlocked, usbCaptureAvailable, enabled != allowUSBCapture else { return }
    allowUSBCapture = enabled
    preferences.set(enabled, forKey: EngineRunner.usbCapturePreferenceKey)
    disconnectPhone()
  }

  func disconnectPhone() {
    guard !connectionActionsBlocked else { return }
    autoConnectTask?.cancel()
    autoConnectTask = nil
    autoConnectPolicy.suppressCurrentAttachment()
    usbMonitoringPaused = true
    usbMonitor.stop()
    usbGeneration += 1
    connectionInterfaces = []
    clearDevice()
    error = nil
    status = L10n.text("连接已释放，点击连接按钮可重新连接手机")
  }
  var selectedEntries: [RemoteEntry] {
    filtering ? [] : visibleEntries.filter { selection.contains($0.id) }
  }
  var previewableSelection: RemoteEntry? {
    guard !previewActionsBlocked, selection.count == 1, let id = selection.first else { return nil }
    return visibleEntries.first(where: { $0.id == id && !$0.isDirectory })
  }

  func isEntryVisible(_ entry: RemoteEntry) -> Bool {
    !filtering && entry.storageID == storageID && visibleEntryIDs.contains(entry.id)
  }

  func previewSelection() {
    guard !previewActionsBlocked, let entry = previewableSelection else { return }
    media.openPreview(entry)
  }

  func setViewMode(_ mode: BrowserViewMode) {
    guard !busy else { return }
    media.suspend()
    viewMode = mode
    preferences.set(mode.rawValue, forKey: Self.viewModeKey)
    resumeMedia()
  }

  private func resumeMedia() {
    guard selectedPage == .browser, !filtering, !busy, !downloadQueue.hasPendingTasks else {
      return
    }
    media.resume(
      deviceKey: deviceKey, demo: demo, showHiddenFiles: showHiddenFiles, usbTarget: activeUSBTarget
    )
  }

  private func cancelFiltering() {
    filterGeneration += 1
    filterTask?.cancel()
    filterTask = nil
    filtering = false
  }

  private func applyFilterResult(_ result: DirectoryFilterResult) {
    // Stable options keep the native popup's menu from being rebuilt on every
    // year change. Only the actual input counts/type/visibility can change them.
    if yearOptions != result.yearOptions { yearOptions = result.yearOptions }
    cachedYearOptions = result.yearOptions
    if monthOptions != result.monthOptions { monthOptions = result.monthOptions }
    cachedMonthOptions[yearFilter] = result.monthOptions
    let key = fileFilterKey
    filterResults[key] = result
    filterResultOrder.removeAll { $0 == key }
    filterResultOrder.append(key)
    if filterResultOrder.count > 8 { filterResults[filterResultOrder.removeFirst()] = nil }
    hiddenEntryCount = result.hiddenCount
    visibleEntryIDs = result.visibleIDs
    selection.formIntersection(result.visibleIDs)
    if appliedFilterKey != key { visibleEntries = result.entries }
    appliedFilterKey = key
  }

  private func refreshVisibleEntries(deferred: Bool = false) {
    let wasFiltering = filtering
    cancelFiltering()
    let input = DirectoryFilterInput(
      entries: entries, yearIndex: yearIndex, yearFilter: yearFilter,
      mediaFilter: mediaFilter, showHiddenFiles: showHiddenFiles, query: query,
      cachedYearOptions: cachedYearOptions, monthFilter: monthFilter,
      cachedMonthOptions: cachedMonthOptions[yearFilter])
    let cached = filterResults[fileFilterKey]
    if !deferred && entries.count <= 1000 {
      applyFilterResult(cached ?? input.evaluate(checkCancellation: {}))
      if wasFiltering && !busy && !isShuttingDown { resumeMedia() }
      return
    }
    filtering = true
    media.suspend()
    let token = filterGeneration
    filterTask = Task { [weak self] in
      do {
        if deferred {
          // Do not impose a fixed delay on a menu click. A default-mode run-loop
          // block resumes after native menu event tracking has ended.
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
          }
        } else {
          try await Task.sleep(nanoseconds: 60_000_000)
        }
        try Task.checkCancellation()
        let result: DirectoryFilterResult
        if let cached {
          result = cached
        } else {
          let work = Task.detached(priority: .userInitiated) {
            try input.evaluate(checkCancellation: { try Task.checkCancellation() })
          }
          result = try await withTaskCancellationHandler(
            operation: { try await work.value }, onCancel: { work.cancel() })
        }
        guard let self, !Task.isCancelled, !self.isShuttingDown,
          token == self.filterGeneration
        else { return }
        self.applyFilterResult(result)
        self.filtering = false
        self.filterTask = nil
        if !self.busy { self.resumeMedia() }
      } catch {
        guard let self, token == self.filterGeneration else { return }
        self.filtering = false
        self.filterTask = nil
      }
    }
  }

  func setYearFilter(_ filter: DirectoryYearFilter) {
    guard !busy, filter != yearFilter, yearOptions.contains(where: { $0.filter == filter }) else {
      return
    }
    media.suspend()
    yearFilter = filter
    gridSelectionAnchor = nil
    refreshVisibleEntries(deferred: true)
    resumeMedia()
  }

  func setMonthFilter(_ filter: DirectoryMonthFilter) {
    guard !busy, filter != monthFilter, monthOptions.contains(where: { $0.filter == filter }) else {
      return
    }
    media.suspend()
    monthFilter = filter
    gridSelectionAnchor = nil
    refreshVisibleEntries(deferred: true)
    resumeMedia()
  }

  func setMediaFilter(_ filter: DirectoryMediaFilter) {
    guard !busy, filter != mediaFilter else { return }
    media.suspend()
    mediaFilter = filter
    cachedYearOptions = nil
    cachedMonthOptions.removeAll()
    gridSelectionAnchor = nil
    refreshVisibleEntries(deferred: true)
    resumeMedia()
  }

  func clearFileFilters() {
    guard !busy else { return }
    media.suspend()
    yearFilter = .all
    monthFilter = .all
    mediaFilter = .all
    cachedYearOptions = nil
    cachedMonthOptions.removeAll()
    gridSelectionAnchor = nil
    query = ""
    refreshVisibleEntries(deferred: true)
    resumeMedia()
  }

  private func cancelSorting() {
    sortGeneration += 1
    sortTask?.cancel()
    sortTask = nil
    sorting = false
  }

  private func resortDirectory() {
    cancelSorting()
    guard !busy, !isShuttingDown, !entries.isEmpty else { return }
    if hasUnloadedSizes && needsSizeOrder {
      loadDirectorySizes()
      return
    }
    sorting = true
    let source = entries
    let requestedOrder = sortOrder
    let token = sortGeneration
    sortTask = Task { [weak self] in
      do {
        // Coalesce rapid header clicks before starting a large-directory sort.
        try await Task.sleep(nanoseconds: 100_000_000)
        let work = Task.detached(priority: .userInitiated) {
          try DirectoryOrdering.sortedCancellable(source, using: requestedOrder)
        }
        let sorted = try await withTaskCancellationHandler(
          operation: { try await work.value }, onCancel: { work.cancel() })
        guard let self, !Task.isCancelled, token == self.sortGeneration else { return }
        self.appliedSortOrder = requestedOrder
        self.entries = sorted
        let parentID = self.folders.last?.id ?? 0
        if self.directoryCache[parentID] != nil {
          self.cacheDirectory(
            parentID,
            snapshot: DirectorySnapshot(
              entries: sorted, sortOrder: requestedOrder, yearIndex: self.yearIndex,
              hasUnloadedSizes: self.hasUnloadedSizes))
        }
        self.sorting = false
        self.sortTask = nil
      } catch {
        guard let self, token == self.sortGeneration else { return }
        self.sorting = false
        self.sortTask = nil
      }
    }
  }

  func setShowHiddenFiles(_ enabled: Bool) {
    guard !busy else { return }
    media.suspend()
    showHiddenFiles = enabled
    cachedYearOptions = nil
    cachedMonthOptions.removeAll()
    preferences.set(enabled, forKey: Self.showHiddenFilesKey)
    refreshFrequentDirectories()
    refreshVisibleEntries()
    resumeMedia()
  }

  func setSelected(_ id: UInt32, selected: Bool) {
    guard !fileActionsBlocked, visibleEntryIDs.contains(id) else { return }
    if selected { selection.insert(id) } else { selection.remove(id) }
  }

  func selectAllVisible() {
    guard !fileActionsBlocked else { return }
    selection = visibleEntryIDs
  }

  func clearSelection() {
    guard !fileActionsBlocked else { return }
    selection = []
  }

  func selectGridEntry(_ entry: RemoteEntry, extending: Bool, toggling: Bool) {
    guard !fileActionsBlocked, let end = visibleEntries.firstIndex(where: { $0.id == entry.id })
    else { return }
    if extending, let anchor = gridSelectionAnchor,
      let start = visibleEntries.firstIndex(where: { $0.id == anchor })
    {
      let range = Set(visibleEntries[min(start, end)...max(start, end)].map(\.id))
      selection = toggling ? selection.union(range) : range
    } else if toggling {
      setSelected(entry.id, selected: !selection.contains(entry.id))
      gridSelectionAnchor = entry.id
    } else {
      selection = [entry.id]
      gridSelectionAnchor = entry.id
    }
  }

  var path: String {
    ([storages.first(where: { $0.id == storageID })?.name ?? L10n.text("手机")] + folders.map(\.name))
      .joined(
        separator: " / ")
  }

  func activate() {
    NSApp?.appearance = appearance.nativeAppearance
    guard !lifecycleStarted else { return }
    lifecycleStarted = true
    if demo { connect() } else { startUSBMonitoring() }
  }

  func shutdown() {
    isShuttingDown = true
    photoDateRepair.shutdown()
    duplicatePhotos.shutdown()
    mediaArchive.shutdown()
    mediaRename.shutdown()
    downloadQueue.shutdown()
    cancelFiltering()
    cancelSorting()
    autoConnectTask?.cancel()
    autoConnectTask = nil
    usbMonitor.stop()
    runner.shutdown()
    media.shutdown()
  }

  private func startUSBMonitoring() {
    usbMonitor.onChange = { [weak self] devices in self?.usbDevicesChanged(devices) }
    do { try usbMonitor.start() } catch {
      status = L10n.text("自动检测暂不可用")
      self.error = error.localizedDescription
    }
  }

  private func clearDevice() {
    frequentDeviceID = nil
    persistFrequentVisits = false
    frequentDirectories = []
    sessionFrequentHistory = FrequentDirectoryHistory()
    frequentSessionPaths.removeAll()
    enqueueFeedback = nil
    downloadQueue.invalidateConnection(L10n.text("手机连接已变化，等待任务需连接原手机后手动继续。"))
    runner.disconnect()
    cancelFiltering()
    cancelSorting()
    media.reset()
    directoryCache.removeAll()
    directoryRecency.removeAll()
    storages = []
    storageID = 0
    yearFilter = .all
    monthFilter = .all
    mediaFilter = .all
    yearIndex = DirectoryYearIndex()
    hasUnloadedSizes = false
    entries = []
    selection = []
    folders = []
    deviceKey = ""
    deviceRecoveryIdentity = ""
    activeUSBTarget = nil
    deviceName = L10n.text("尚未连接手机")
    query = ""
  }

  private func usbDevicesChanged(_ devices: Set<UInt64>) {
    guard !demo else { return }
    usbDevices = usbMonitor.choices
    if selectedUSBDeviceID == nil || !devices.contains(selectedUSBDeviceID!) {
      selectedUSBDeviceID = devices.count == 1 ? devices.first : nil
    }
    autoConnectTask?.cancel()
    autoConnectTask = nil
    autoConnectPolicy.update(devices: devices)
    if !connectionInterfaces.isEmpty && connectionInterfaces.isDisjoint(with: devices) {
      usbGeneration += 1
      connectionInterfaces = []
      clearDevice()
      // Removing the selected phone must not silently capture another one.
      if !devices.isEmpty { autoConnectPolicy.suppressCurrentAttachment() }
      error = nil
      if busy {
        cancelling = true
        runner.cancel()
      }
      status = L10n.text("手机已断开，等待重新连接…")
    }
    guard !busy, storages.isEmpty else { return }
    if devices.isEmpty {
      status = L10n.text("等待手机接入，请在手机上选择 USB 文件传输")
    } else if devices.count > 1 {
      status = L10n.text("检测到多台手机，请选择要连接的手机")
    } else {
      scheduleAutoConnect()
    }
  }

  private func scheduleAutoConnect(delay: UInt64 = 800_000_000) {
    guard !isShuttingDown, selectedPage != .tools, !downloadQueue.hasPendingTasks else { return }
    guard
      let candidate = autoConnectPolicy.candidate(
        isBusy: busy, hasConnection: !storages.isEmpty, isDemo: demo)
    else { return }
    autoConnectTask?.cancel()
    status =
      autoConnectPolicy.attemptCount(for: candidate) == 0
      ? L10n.text("发现手机，正在准备自动连接…") : L10n.text("手机尚未就绪，稍后自动重试…")
    autoConnectTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard let self, !Task.isCancelled,
        self.autoConnectPolicy.candidate(
          isBusy: self.busy,
          hasConnection: !self.storages.isEmpty, isDemo: self.demo) == candidate,
        self.autoConnectPolicy.claim(candidate)
      else { return }
      self.connect(automaticCandidate: candidate)
    }
  }

  func changeMode(_ enabled: Bool) {
    guard !connectionActionsBlocked else { return }
    autoConnectTask?.cancel()
    autoConnectTask = nil
    usbMonitor.stop()
    autoConnectPolicy = AutoConnectPolicy()
    usbMonitoringPaused = false
    connectionInterfaces = []
    usbDevices = []
    selectedUSBDeviceID = nil
    usbGeneration += 1
    demo = enabled
    clearDevice()
    error = nil
    status = enabled ? L10n.text("演示模式使用合成文件，不访问手机") : L10n.text("正在检测已连接的手机…")
    if !enabled { startUSBMonitoring() }
  }

  func connect() { connect(automaticCandidate: nil) }

  func selectUSBDevice(_ id: UInt64?) {
    guard !connectionActionsBlocked, id == nil || usbDevices.contains(where: { $0.id == id }) else {
      return
    }
    autoConnectTask?.cancel()
    autoConnectTask = nil
    selectedUSBDeviceID = id
  }

  private func connect(automaticCandidate: UInt64?) {
    guard !connectionActionsBlocked else { return }
    if automaticCandidate == nil, usbMonitoringPaused && !demo {
      usbMonitoringPaused = false
      startUSBMonitoring()
    }
    autoConnectTask?.cancel()
    autoConnectTask = nil
    let candidate =
      automaticCandidate ?? selectedUSBDeviceID
      ?? (autoConnectPolicy.devices.count == 1 ? autoConnectPolicy.devices.first : nil)
    let choice = usbDevices.first { $0.id == candidate }
    if !demo && autoConnectPolicy.devices.count > 1 && choice?.target == nil {
      error = nil
      status = L10n.text("请先选择要连接的手机；无法识别的设备请重新插拔后重试")
      return
    }
    if automaticCandidate == nil { autoConnectPolicy.suppressCurrentAttachment() }
    clearDevice()
    activeUSBTarget = demo ? nil : choice?.target
    connectionInterfaces = demo ? [] : candidate.map { [$0] } ?? autoConnectPolicy.devices
    error = nil
    start(EngineRequest(operation: "connect"), automaticCandidate: automaticCandidate) {
      [weak self] in
      guard let self, !self.storages.isEmpty else { return }
      self.storageID = self.storages[0].id
      self.loadDirectory()
    }
  }

  func selectStorage(_ id: UInt32) {
    guard !busy else { return }
    selectPage(.browser)
    if storageID != id {
      directoryCache.removeAll()
      directoryRecency.removeAll()
      media.reset()
    }
    storageID = id
    folders = []
    loadDirectory(useCache: true)
  }
  func open(_ entry: RemoteEntry) {
    guard entry.isDirectory, !busy else { return }
    folders.append(FolderLocation(id: entry.id, name: entry.name))
    loadDirectory(useCache: true)
  }
  func up() {
    guard !folders.isEmpty else { return }
    navigateToFolder(atDepth: folders.count - 1)
  }

  func navigateToFolder(atDepth depth: Int) {
    guard !busy, storageID != 0, depth >= 0, depth < folders.count else { return }
    folders = Array(folders.prefix(depth))
    loadDirectory(useCache: true)
  }
  func loadDirectory() {
    guard !busy else { return }
    media.reset()
    loadDirectory(useCache: false)
  }

  private func loadDirectory(useCache: Bool) {
    guard storageID != 0, !busy else { return }
    cancelFiltering()
    cancelSorting()
    cachedYearOptions = nil
    cachedMonthOptions.removeAll()
    media.suspend()
    let parentID = folders.last?.id ?? 0
    let pathIDs = Set([UInt32(0)] + folders.map(\.id))
    if !useCache {
      // Explicit refresh invalidates recent folders outside the current path,
      // so refreshing a parent cannot restore an obsolete child snapshot.
      directoryCache = directoryCache.filter { pathIDs.contains($0.key) && $0.key != parentID }
    }
    pruneDirectoryCache()
    selection = []
    gridSelectionAnchor = nil
    if useCache {
      yearFilter = .all
      monthFilter = .all
      mediaFilter = .all
    }
    query = ""
    if useCache, let cached = directoryCache[parentID] {
      touchDirectory(parentID)
      appliedSortOrder = cached.sortOrder
      yearIndex = cached.yearIndex
      hasUnloadedSizes = cached.hasUnloadedSizes
      entries = cached.entries
      error = nil
      status = L10n.text("已从缓存恢复 \(entries.count) 项，刷新可获取最新内容")
      if appliedSortOrder != sortOrder { resortDirectory() }
      recordFrequentVisit()
      resumeMedia()
      return
    }
    directoryCache[parentID] = nil
    yearIndex = DirectoryYearIndex()
    hasUnloadedSizes = false
    entries = []
    start(
      EngineRequest(
        operation: "list", deviceKey: deviceKey, storageID: storageID,
        parentID: parentID, includeSizes: needsSizeOrder),
      after: useCache ? { [weak self] in self?.recordFrequentVisit() } : nil)
  }

  private func touchDirectory(_ id: UInt32) {
    directoryRecency.removeAll { $0 == id }
    directoryRecency.append(id)
  }

  private func configureFrequentDevice() {
    if demo {
      frequentDeviceID = "demo:\(deviceKey)"
      persistFrequentVisits = true
    } else if let target = activeUSBTarget, !target.serialNumber.isEmpty {
      let identity =
        "\(deviceKey)\u{0}\(target.vendorID)\u{0}\(target.productID)\u{0}\(target.serialNumber)"
      frequentDeviceID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
        .joined()
      persistFrequentVisits = true
    } else {
      // Without a verified USB serial, identical models cannot be reliably
      // distinguished. Keep history within this connection rather than guessing.
      frequentDeviceID = "session:\(UUID().uuidString)"
      persistFrequentVisits = false
    }
    refreshFrequentDirectories()
  }

  private func refreshFrequentDirectories() {
    guard let frequentDeviceID else {
      frequentDirectories = []
      return
    }
    let history = persistFrequentVisits ? frequentHistory : sessionFrequentHistory
    frequentDirectories = history.entries(for: frequentDeviceID, includeHidden: showHiddenFiles)
    let valid = Set(
      history.entries(for: frequentDeviceID, includeHidden: true, limit: 200).map(\.id))
    frequentSessionPaths = frequentSessionPaths.filter { valid.contains($0.key) }
  }

  private func recordFrequentVisit() {
    guard let frequentDeviceID, !folders.isEmpty,
      let storage = storages.first(where: { $0.id == storageID })
    else { return }
    let components = folders.map(\.name)
    if persistFrequentVisits {
      frequentHistory.record(
        deviceID: frequentDeviceID, storageID: storageID,
        storageName: storage.name, components: components)
      if let data = frequentHistory.encoded() {
        preferences.set(data, forKey: Self.frequentDirectoriesKey)
      }
    } else {
      sessionFrequentHistory.record(
        deviceID: frequentDeviceID, storageID: storageID,
        storageName: storage.name, components: components)
    }
    let history = persistFrequentVisits ? frequentHistory : sessionFrequentHistory
    if let entry = history.entries(for: frequentDeviceID, includeHidden: true, limit: 200)
      .first(where: { $0.storageID == storageID && sameFrequentPath($0.components, components) })
    {
      frequentSessionPaths[entry.id] = folders
    }
    refreshFrequentDirectories()
  }

  func removeFrequentDirectory(_ id: UUID) {
    if persistFrequentVisits {
      frequentHistory.remove(id: id)
      if let data = frequentHistory.encoded() {
        preferences.set(data, forKey: Self.frequentDirectoriesKey)
      }
    } else {
      sessionFrequentHistory.remove(id: id)
    }
    frequentSessionPaths[id] = nil
    refreshFrequentDirectories()
  }

  func isCurrentFrequentDirectory(_ entry: FrequentDirectory) -> Bool {
    entry.deviceID == frequentDeviceID && entry.storageID == storageID
      && sameFrequentPath(entry.components, folders.map(\.name))
  }

  private func sameFrequentPath(_ left: [String], _ right: [String]) -> Bool {
    left.count == right.count && zip(left, right).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
  }

  func isFrequentStorageAvailable(_ entry: FrequentDirectory) -> Bool {
    entry.deviceID == frequentDeviceID && storages.contains { $0.id == entry.storageID }
  }

  func openFrequentDirectory(_ entry: FrequentDirectory) {
    guard !busy, !isShuttingDown, entry.deviceID == frequentDeviceID,
      showHiddenFiles || !entry.components.contains(where: { $0.hasPrefix(".") })
    else { return }
    guard isFrequentStorageAvailable(entry) else {
      error = L10n.text("该目录所在存储当前不可用，请检查手机存储后重试。")
      return
    }
    selectPage(.browser)
    guard !isCurrentFrequentDirectory(entry) else { return }
    if storageID == entry.storageID, let path = frequentSessionPaths[entry.id],
      let finalID = path.last?.id, directoryCache[finalID] != nil
    {
      folders = path
      loadDirectory(useCache: true)
    } else {
      resolveFrequentDirectory(entry)
    }
  }

  /// Cold shortcuts resolve names in this connection. Intermediate directories
  /// stay local until the entire jump succeeds; cancelled/failed jumps publish
  /// neither a new browser location nor a new visit.
  private func resolveFrequentDirectory(_ entry: FrequentDirectory) {
    let reservation = downloadQueue.reserveForeground()
    cancelFiltering()
    cancelSorting()
    media.suspend()
    busy = true
    cancelling = false
    foregroundRequestStarted = false
    error = nil
    status = L10n.text("正在定位目录“\(entry.name)”…")
    let generation = usbGeneration
    let key = deviceKey
    let target = activeUSBTarget
    let currentMode = demo
    let wantedOrder = sortOrder
    let includeTargetSizes = needsSizeOrder
    let cached = storageID == entry.storageID ? directoryCache : [:]
    task = Task {
      await downloadQueue.waitUntilIdle()
      await media.waitUntilIdle()
      var helperUsable = true
      var succeeded = false
      do {
        @MainActor func checkCurrent() throws {
          guard !isShuttingDown, generation == usbGeneration, !cancelling else {
            throw FrequentNavigationFailure.cancelled
          }
        }
        var snapshots: [UInt32: DirectorySnapshot] = [:]
        @MainActor func read(_ parent: UInt32, final: Bool) async throws -> DirectorySnapshot {
          try checkCurrent()
          if let snapshot = snapshots[parent] ?? cached[parent] { return snapshot }
          foregroundRequestStarted = true
          let request = EngineRequest(
            operation: "list", deviceKey: key, storageID: entry.storageID,
            parentID: parent, includeSizes: final && includeTargetSizes, usbTarget: target)
          var received: [RemoteEntry]?
          var failure: String?
          for try await event in runner.events(for: request, demo: currentMode) {
            if event.type == "listed" { received = event.entries ?? [] }
            if event.type == "error" {
              if event.state == "authorization_denied" {
                autoConnectPolicy.suppressCurrentAttachment()
              }
              failure = event.message ?? L10n.text("目录读取失败，请重试。")
            }
            if event.type == "status", !cancelling, generation == usbGeneration {
              status = event.message ?? status
            }
          }
          if let failure { throw EngineFailure(failure) }
          try checkCurrent()
          guard let received else { throw EngineFailure(L10n.text("目录读取响应不完整，请重试。")) }
          let order = !final && includeTargetSizes ? DirectoryOrdering.defaultOrder : wantedOrder
          let snapshot = await Task.detached(priority: .userInitiated) {
            DirectorySnapshot(
              entries: DirectoryOrdering.sorted(received, using: order),
              sortOrder: order, yearIndex: DirectoryYearIndex(received),
              hasUnloadedSizes: received.contains { !$0.hasKnownSize })
          }.value
          try checkCurrent()
          snapshots[parent] = snapshot
          return snapshot
        }
        try checkCurrent()
        var path: [FolderLocation] = []
        var parent: UInt32 = 0
        for component in entry.components {
          let snapshot = try await read(parent, final: false)
          let matches = await Task.detached(priority: .userInitiated) {
            snapshot.entries.filter { $0.isDirectory && $0.name.utf8.elementsEqual(component.utf8) }
          }.value
          try checkCurrent()
          guard matches.count == 1, let match = matches.first,
            !path.contains(where: { $0.id == match.id })
          else { throw FrequentNavigationFailure.notFound }
          path.append(FolderLocation(id: match.id, name: match.name))
          parent = match.id
        }
        let snapshot = try await read(parent, final: true)
        try checkCurrent()
        if storageID != entry.storageID {
          directoryCache.removeAll()
          directoryRecency.removeAll()
        }
        storageID = entry.storageID
        folders = path
        yearFilter = .all
        monthFilter = .all
        mediaFilter = .all
        query = ""
        selection = []
        gridSelectionAnchor = nil
        appliedSortOrder = snapshot.sortOrder
        yearIndex = snapshot.yearIndex
        hasUnloadedSizes = snapshot.hasUnloadedSizes
        entries = snapshot.entries
        for (id, value) in snapshots { cacheDirectory(id, snapshot: value) }
        cacheDirectory(parent, snapshot: snapshot)
        recordFrequentVisit()
        status = L10n.text("已打开常用目录“\(entry.name)”")
        succeeded = true
      } catch FrequentNavigationFailure.cancelled {
        // A local stop discards already-drained reads, preserving a staged job.
      } catch FrequentNavigationFailure.notFound {
        error = L10n.text("目录已移动、重命名或删除，请从手机文件中重新打开。")
        status = L10n.text("目录未能打开")
      } catch {
        helperUsable = false
        runner.disconnect()
        self.error = error.localizedDescription
        status = L10n.text("目录未能打开")
      }
      let stopped = cancelling || isShuttingDown
      busy = false
      cancelling = false
      foregroundRequestStarted = false
      if generation != usbGeneration {
        clearDevice()
        error = nil
        status = L10n.text("手机已断开，等待重新连接…")
        scheduleAutoConnect()
      } else if stopped {
        status = L10n.text("操作已停止")
      }
      downloadQueue.releaseForeground(
        reservation,
        connectionUsable: helperUsable && generation == usbGeneration)
      if !isShuttingDown {
        if succeeded && appliedSortOrder != sortOrder { resortDirectory() }
        resumeMedia()
      }
    }
  }

  private func cacheDirectory(_ id: UInt32, snapshot: DirectorySnapshot) {
    directoryCache[id] = snapshot
    touchDirectory(id)
    pruneDirectoryCache()
  }

  private func pruneDirectoryCache() {
    let pinned = Set([UInt32(0)] + folders.map(\.id))
    var retainedFolders = 0
    var retainedEntries = 0
    // This walks cached directory IDs/counts only, never the large file lists.
    for id in directoryRecency.reversed() where !pinned.contains(id) {
      guard let snapshot = directoryCache[id] else { continue }
      if retainedFolders < recentDirectoryLimit,
        snapshot.entries.count <= recentEntryLimit - retainedEntries
      {
        retainedFolders += 1
        retainedEntries += snapshot.entries.count
      } else {
        directoryCache[id] = nil
      }
    }
    directoryRecency.removeAll { directoryCache[$0] == nil }
  }

  func loadDirectorySizes() {
    guard !busy, hasUnloadedSizes, storageID != 0 else { return }
    start(
      EngineRequest(
        operation: "sizes", deviceKey: deviceKey, storageID: storageID,
        parentID: folders.last?.id ?? 0))
  }

  func chooseDestination() {
    guard !busy else { return }
    let panel = NSOpenPanel()
    panel.title = L10n.text("选择下载位置")
    panel.prompt = L10n.text("选择此文件夹")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = destination
    if panel.runModal() == .OK, let url = panel.url { setDestination(url) }
  }

  func setDestination(_ url: URL) {
    guard url.isFileURL, DownloadDestination.isValidPath(url.path) else { return }
    destination = url
    preferences.set(url.path, forKey: DownloadDestination.preferenceKey)
    error = nil
  }

  func setCreateDownloadFolder(_ enabled: Bool) {
    createDownloadFolder = enabled
    preferences.set(enabled, forKey: Self.createDownloadFolderKey)
  }

  func setUsePhotoCreationDate(_ enabled: Bool) {
    usePhotoCreationDate = enabled
    preferences.set(enabled, forKey: Self.usePhotoCreationDateKey)
  }

  func setArchivePhotosByMonth(_ enabled: Bool) {
    archivePhotosByMonth = enabled
    preferences.set(enabled, forKey: Self.archivePhotosByMonthKey)
  }

  func setArchiveVideosByMonth(_ enabled: Bool) {
    archiveVideosByMonth = enabled
    preferences.set(enabled, forKey: Self.archiveVideosByMonthKey)
  }

  func download() {
    guard !fileActionsBlocked, !selectedEntries.isEmpty else { return }
    guard destinationIsAvailable(destination) else {
      enqueueFeedback = nil
      error = L10n.text("保存位置不可用或无法写入，请连接对应硬盘或重新选择文件夹：\(destination.path)")
      return
    }
    error = nil
    let chosen = selectedEntries
    let title = chosen.count == 1 ? chosen[0].name : L10n.text("\(chosen.count) 个项目 · \(path)")
    var request = EngineRequest(
      operation: "download", deviceKey: deviceKey, storageID: storageID,
      parentID: folders.last?.id ?? 0,
      objectIDs: chosen.map(\.id), destination: destination.path,
      showHiddenFiles: showHiddenFiles, usbTarget: activeUSBTarget,
      downloadLayout: createDownloadFolder ? "folder" : "direct",
      reportDirectory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!
      .appendingPathComponent("Ferry/Transfers", isDirectory: true).path,
      usePhotoCreationDate: usePhotoCreationDate, archivePhotosByMonth: archivePhotosByMonth,
      archiveVideosByMonth: archiveVideosByMonth,
      promptConflicts: true)
    request.durableRecovery = true
    request.recoveryIdentity = deviceRecoveryIdentity
    request.sourceDirectory = folders.map(\.name)
    request.sourceSelection = chosen
    request.sourceStorage = storages.first { $0.id == storageID }
    guard
      downloadQueue.enqueue(
        title: title, request: request, demo: demo, filterSummary: downloadFilterSummary)
    else {
      enqueueFeedback = nil
      error = downloadQueue.recoveryError ?? L10n.text("请先取消其他手机的等待任务，再添加当前手机的下载。")
      return
    }
    enqueueRevision += 1
    enqueueFeedback = EnqueueFeedback(id: enqueueRevision, itemCount: chosen.count)
  }

  private var downloadFilterSummary: String {
    var conditions = [mediaFilter.title]
    switch yearFilter {
    case .all: conditions.append(L10n.text("全部年份"))
    case .year(let year): conditions.append(L10n.text("修改年份：\(year)"))
    case .unknown: conditions.append(L10n.text("日期未知"))
    }
    switch monthFilter {
    case .all: conditions.append(L10n.text("全部月份"))
    case .month(let month): conditions.append(L10n.text("修改月份：\(month)"))
    }
    if !query.isEmpty { conditions.append(L10n.text("搜索“\(query)”")) }
    conditions.append(L10n.text(showHiddenFiles ? "包含隐藏文件" : "不含隐藏文件"))
    return L10n.text("筛选：\(conditions.joined(separator: " · "))")
  }

  func dismissEnqueueFeedback(id: Int) {
    guard enqueueFeedback?.id == id else { return }
    enqueueFeedback = nil
  }

  private func synchronizeDownloads() {
    let next = DownloadQueueSummary(
      pendingTaskCount: downloadQueue.pendingTaskCount,
      hasTasks: !downloadQueue.tasks.isEmpty,
      isTransferring: downloadQueue.isTransferring,
      hasScheduledWork: downloadQueue.hasScheduledWork)
    guard next != downloadSummary else { return }
    let finishedPendingWork = downloadSummary.hasPendingTasks && !next.hasPendingTasks
    downloadSummary = next
    if finishedPendingWork && !busy && !isShuttingDown { resumeMedia() }
  }

  func cancel() {
    if !busy {
      if let id = downloadQueue.activeTaskID { downloadQueue.cancel(id) }
      return
    }
    guard !cancelling else { return }
    autoConnectPolicy.suppressCurrentAttachment()
    autoConnectTask?.cancel()
    autoConnectTask = nil
    cancelling = true
    status = L10n.text("正在停止，等待当前设备请求返回…")
    // While a download owns a staged job, stopping browsing only discards its
    // result. It must not terminate the helper or the file being downloaded.
    if foregroundRequestStarted && downloadQueue.activeTaskID == nil { runner.cancel() }
  }

  func revealOutput() {
    guard let output else { return }
    NSWorkspace.shared.open(output)
  }

  private func start(
    _ request: EngineRequest, automaticCandidate: UInt64? = nil, after: (() -> Void)? = nil
  ) {
    guard !isShuttingDown else { return }
    var request = request
    request.usbTarget = activeUSBTarget
    let reservation = downloadQueue.reserveForeground()
    cancelSorting()
    media.suspend()
    busy = true
    cancelling = false
    foregroundRequestStarted = false
    error = nil
    status =
      request.operation == "sizes"
      ? L10n.text("正在读取文件大小…")
      : downloadQueue.isTransferring
        ? L10n.text("等待当前文件传输完成后读取目录…")
        : L10n.text("正在连接手机…")
    let currentMode = demo
    let generation = usbGeneration
    task = Task {
      await downloadQueue.waitUntilIdle()
      await media.waitUntilIdle()
      var receivedListing = false
      var authorizationDenied = false
      var startedRequest = false
      var helperSucceeded = true
      var succeeded = !isShuttingDown && generation == usbGeneration && !cancelling
      if succeeded {
        startedRequest = true
        foregroundRequestStarted = true
        do {
          for try await event in runner.events(for: request, demo: currentMode) {
            if event.type == "error" {
              succeeded = false
              helperSucceeded = false
              if event.state == "authorization_denied" { authorizationDenied = true }
            }
            guard generation == usbGeneration else { continue }
            if cancelling && ["connected", "listed", "sized"].contains(event.type) { continue }
            try await handle(event, generation: generation)
            if event.type == "listed" && !cancelling { receivedListing = true }
          }
        } catch {
          succeeded = false
          helperSucceeded = false
          // Swift-side validation may fail while the helper still owns a job.
          // The foreground reservation guarantees we are between files.
          runner.disconnect()
          self.error = error.localizedDescription
          status = L10n.text("操作未完成")
        }
      }
      let wasCancelled = cancelling
      if request.operation == "sizes" && (!succeeded || wasCancelled) {
        sortOrder = appliedSortOrder
      }
      busy = false
      cancelling = false
      foregroundRequestStarted = false
      if generation != usbGeneration {
        clearDevice()
        error = nil
        status = L10n.text("手机已断开，等待重新连接…")
        scheduleAutoConnect()
      } else if wasCancelled {
        status = L10n.text("操作已停止")
      } else if succeeded {
        if (request.operation == "list" && receivedListing
          || request.operation == "sizes" && directoryCache[request.parentID] != nil)
          && !isShuttingDown
        {
          cacheDirectory(
            request.parentID,
            snapshot: DirectorySnapshot(
              entries: entries, sortOrder: appliedSortOrder, yearIndex: yearIndex,
              hasUnloadedSizes: hasUnloadedSizes))
        }
        after?()
      } else if authorizationDenied {
        autoConnectPolicy.suppressCurrentAttachment()
      } else if let candidate = automaticCandidate {
        if autoConnectPolicy.attemptCount(for: candidate) < autoConnectPolicy.maximumAttempts {
          scheduleAutoConnect(
            delay: autoConnectPolicy.attemptCount(for: candidate) == 1
              ? 2_000_000_000 : 5_000_000_000)
        } else {
          status = L10n.text("自动连接未成功，请解锁手机并允许文件访问后手动重试")
        }
      } else {
        scheduleAutoConnect()
      }
      downloadQueue.releaseForeground(
        reservation,
        connectionUsable: generation == usbGeneration && (!startedRequest || helperSucceeded))
      if !busy && !isShuttingDown {
        if succeeded && appliedSortOrder != sortOrder { resortDirectory() }
        resumeMedia()
      }
    }
  }

  private func handle(_ event: EngineEvent, generation: Int) async throws {
    if let location = event.output { foregroundOutput = URL(fileURLWithPath: location) }
    switch event.type {
    case "status": if !cancelling { status = event.message ?? status }
    case "connected":
      if !demo && connectionInterfaces.isEmpty { connectionInterfaces = autoConnectPolicy.devices }
      deviceKey = event.deviceKey ?? ""
      deviceRecoveryIdentity = event.recoveryIdentity ?? ""
      deviceName = event.deviceName ?? L10n.text("Android 手机")
      storages = event.storages ?? []
      configureFrequentDevice()
      status = L10n.text("手机已连接")
    case "listed":
      let received = event.entries ?? []
      let requestedOrder = sortOrder
      if !cancelling { status = L10n.text("已读取 \(received.count) 项，正在整理目录…") }
      let result = await Task.detached(priority: .userInitiated) {
        (
          DirectoryOrdering.sorted(received, using: requestedOrder), DirectoryYearIndex(received),
          received.contains { !$0.hasKnownSize }
        )
      }.value
      guard generation == usbGeneration, !isShuttingDown else { return }
      if cancelling {
        status = L10n.text("目录读取已停止")
      } else {
        appliedSortOrder = requestedOrder
        yearIndex = result.1
        hasUnloadedSizes = result.2
        entries = result.0
        status = L10n.text("共 \(entries.count) 项")
      }
    case "sized":
      let source = entries
      let requestedOrder = sortOrder
      let needsSort = requestedOrder != appliedSortOrder
      let result = try await Task.detached(priority: .userInitiated) {
        let merged = try DirectorySizes.applying(
          event.sizes ?? [], to: source,
          checkCancellation: { try Task.checkCancellation() })
        return needsSort
          ? try DirectoryOrdering.sortedCancellable(merged, using: requestedOrder) : merged
      }.value
      guard generation == usbGeneration, !isShuttingDown, !cancelling else { return }
      appliedSortOrder = requestedOrder
      hasUnloadedSizes = false
      entries = result
      status = L10n.text("文件大小已读取，共 \(entries.count) 项")
    case "error":
      status = event.state == "cancelled" ? L10n.text("操作已停止，已完成文件保留") : L10n.text("操作未完成")
      error = event.message
    default: break
    }
  }
}
