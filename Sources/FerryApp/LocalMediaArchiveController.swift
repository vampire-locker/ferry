import Combine
import FerryCore
import Foundation

@MainActor
private final class ArchiveProgressDelivery {
  weak var owner: LocalMediaArchiveController?
  let revision: Int
  init(_ owner: LocalMediaArchiveController, revision: Int) {
    self.owner = owner
    self.revision = revision
  }
  nonisolated func ask(_ value: MediaArchiveConflict, resolver: ArchiveConflictResolver) {
    Task { @MainActor [weak self] in
      guard let self, let owner, owner.accept(value, revision: revision) else {
        resolver.cancel()
        return
      }
    }
  }
  nonisolated func send(_ value: MediaArchiveProgress) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      owner?.receive(value, revision: revision)
    }
  }
}

@MainActor
final class LocalMediaArchiveController: ObservableObject {
  enum Phase { case idle, scanning, ready, applying, stopping, scanCancelled, finished }
  let operation: LocalMediaOperation
  var isRenaming: Bool { operation == .renameMedia }
  init(operation: LocalMediaOperation = .archive) { self.operation = operation }
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var folder: URL?
  @Published private(set) var recursive = true
  @Published private(set) var images = true
  @Published private(set) var videos = true
  @Published private(set) var plan: MediaArchivePlan?
  @Published private(set) var choices: [String: String] = [:]
  @Published private(set) var progress = MediaArchiveProgress()
  @Published private(set) var result: MediaArchiveResult?
  @Published private(set) var error: String?
  @Published private(set) var conflict: MediaArchiveConflict?
  @Published private(set) var movingCount = 0
  @Published private(set) var alreadyCount = 0
  @Published private(set) var unresolvedCount = 0
  @Published private(set) var previewPage = 0
  @Published private(set) var selectedIDs: Set<String> = []
  private var selectableIDs: Set<String> = []
  private var directoryItemIDs: [String: Set<String>] = [:]
  static let previewPageSize = 20
  private var cancellation: PhotoRepairCancellation?
  private var conflictResolver: ArchiveConflictResolver?
  private var worker: Task<Void, Never>?
  private var revision = 0
  private var scanningOperation = false

  var folderYear: Int? { isRenaming ? nil : folder.flatMap(LocalMediaArchive.yearFolder) }
  var isBusy: Bool { phase == .scanning || phase == .applying || phase == .stopping }
  var isScanning: Bool { phase == .scanning || phase == .stopping && scanningOperation }
  var canApply: Bool { phase == .ready && selectedCount > 0 && unresolvedCount == 0 }
  var selectedCount: Int { selectedIDs.count }
  var isAllSelected: Bool { selectedIDs.count == selectableIDs.count }

  var previewPageCount: Int {
    ((plan?.items.count ?? 0) + Self.previewPageSize - 1) / Self.previewPageSize
  }
  var previewRange: Range<Int> {
    let count = plan?.items.count ?? 0
    let start = min(previewPage * Self.previewPageSize, count)
    return start..<min(start + Self.previewPageSize, count)
  }
  var previewItems: ArraySlice<MediaArchiveItem> {
    guard let plan else { return [] }
    return plan.items[previewRange]
  }
  func showPreviewPage(_ page: Int) {
    guard phase == .ready, page >= 0, page < previewPageCount else { return }
    previewPage = page
  }

  func canSelect(_ id: String) -> Bool { selectableIDs.contains(id) }
  func selectItem(_ id: String, selected: Bool) {
    guard phase == .ready, canSelect(id) else { return }
    if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    updateUnresolvedCount()
  }
  func selectAll(_ selected: Bool) {
    guard phase == .ready else { return }
    selectedIDs = selected ? selectableIDs : []
    updateUnresolvedCount()
  }
  var pageSelectableIDs: Set<String> {
    Set(previewItems.map(\.id)).intersection(selectableIDs)
  }
  var isPageSelected: Bool {
    !pageSelectableIDs.isEmpty && pageSelectableIDs.isSubset(of: selectedIDs)
  }
  func selectPage(_ selected: Bool) {
    guard phase == .ready else { return }
    if selected {
      selectedIDs.formUnion(pageSelectableIDs)
    } else {
      selectedIDs.subtract(pageSelectableIDs)
    }
    updateUnresolvedCount()
  }
  func hasSelectedFiles(in directory: MediaArchiveDirectory) -> Bool {
    directoryItemIDs[directory.id].map { !$0.isDisjoint(with: selectedIDs) } ?? false
  }
  private func updateUnresolvedCount() {
    unresolvedCount =
      plan?.directories.filter {
        $0.defaultPath == nil && choices[$0.id] == nil && hasSelectedFiles(in: $0)
      }.count ?? 0
  }

  func selectFolder(_ url: URL) {
    guard !isBusy, url.isFileURL else { return }
    folder = url
    scan()
  }
  func setOptions(recursive: Bool? = nil, images: Bool? = nil, videos: Bool? = nil) {
    guard !isBusy else { return }
    if let recursive { self.recursive = recursive }
    if let images { self.images = images }
    if let videos { self.videos = videos }
    reset()
    phase = .idle
  }
  private func reset() {
    previewPage = 0
    selectedIDs = []
    selectableIDs = []
    directoryItemIDs = [:]
    conflict = nil
    conflictResolver = nil
    plan = nil
    result = nil
    error = nil
    choices = [:]
    movingCount = 0
    alreadyCount = 0
    unresolvedCount = 0
  }
  func choose(_ path: String, for month: String) {
    guard phase == .ready,
      plan?.directories.first(where: { $0.id == month })?.candidates.contains(path) == true
    else { return }
    choices[month] = path
    updateCounts()
  }
  private func updateCounts(defaultSelection: Bool = false) {
    guard let plan else { return }
    let previouslySelectable = selectableIDs
    selectableIDs = []
    directoryItemIDs = [:]
    let ambiguous = Set(plan.directories.filter { $0.candidates.count > 1 }.map(\.id))
    alreadyCount = 0
    movingCount = 0
    for item in plan.items {
      let target = plan.destination(item, choices: choices)
      if !plan.needsProcessing(item, choices: choices) {
        alreadyCount += 1
      } else {
        selectableIDs.insert(item.id)
        if target != nil { movingCount += 1 }
      }
      if ambiguous.contains(item.month.id) {
        directoryItemIDs[item.month.id, default: []].insert(item.id)
      }
    }
    if defaultSelection {
      selectedIDs = selectableIDs
    } else {
      selectedIDs.formIntersection(selectableIDs)
      selectedIDs.formUnion(selectableIDs.subtracting(previouslySelectable))
    }
    updateUnresolvedCount()
  }
  func scan() {
    guard !isBusy, let folder else { return }
    let token = PhotoRepairCancellation()
    cancellation = token
    revision += 1
    let revision = revision
    let recursive = recursive
    let images = images
    let videos = videos
    let operation = operation
    scanningOperation = true
    let delivery = ArchiveProgressDelivery(self, revision: revision)
    reset()
    progress = .init()
    phase = .scanning
    let work = Task.detached(priority: .utility) {
      try await LocalMediaArchive.scan(
        folder: folder, recursive: recursive, images: images, videos: videos,
        operation: operation, cancellation: token
      ) { delivery.send($0) }
    }
    worker = Task { [weak self] in
      do {
        let plan = try await work.value
        guard let self, self.revision == revision else { return }
        self.plan = plan
        self.updateCounts(defaultSelection: true)
        self.phase = .ready
        self.worker = nil
      } catch {
        guard let self, self.revision == revision else { return }
        self.error = error is CancellationError ? nil : error.localizedDescription
        self.phase = error is CancellationError ? .scanCancelled : .idle
        self.worker = nil
      }
    }
  }
  func apply() {
    guard canApply, let plan else { return }
    let token = PhotoRepairCancellation()
    cancellation = token
    revision += 1
    let revision = revision
    let choices = choices
    let selectedIDs = selectedIDs
    scanningOperation = false
    let delivery = ArchiveProgressDelivery(self, revision: revision)
    error = nil
    result = nil
    progress = .init()
    progress.total = selectedIDs.count
    phase = .applying
    let resolver = ArchiveConflictResolver()
    conflictResolver = resolver
    conflict = nil
    let work = Task.detached(priority: .utility) {
      try LocalMediaArchive.apply(
        plan, choices: choices, selectedIDs: selectedIDs, cancellation: token,
        resolveConflict: { question in
          try resolver.request(question, cancellation: token) {
            delivery.ask($0, resolver: resolver)
          }
        }, progress: { delivery.send($0) })
    }
    worker = Task { [weak self] in
      do {
        let result = try await work.value
        guard let self, self.revision == revision else { return }
        self.result = result
        self.conflict = nil
        self.conflictResolver = nil
        self.phase = .finished
        self.worker = nil
      } catch {
        guard let self, self.revision == revision else { return }
        self.error = error.localizedDescription
        self.conflict = nil
        self.conflictResolver = nil
        self.phase = .finished
        self.worker = nil
      }
    }
  }
  fileprivate func accept(_ value: MediaArchiveConflict, revision: Int) -> Bool {
    guard self.revision == revision, phase == .applying else { return false }
    conflict = value
    progress.currentPath = value.sourcePath
    return true
  }
  func resolve(_ decision: DownloadConflictDecision) {
    guard phase == .applying, let conflict, conflict.id == decision.id,
      ["keepBoth", "skip", "replace"].contains(decision.choice),
      decision.choice != "replace" || conflict.file.canReplace
    else { return }
    if conflictResolver?.resolve(decision) == true { self.conflict = nil }
  }
  fileprivate func receive(_ value: MediaArchiveProgress, revision: Int) {
    guard self.revision == revision, isBusy else { return }
    progress = value
  }
  func cancel() {
    guard isBusy else { return }
    cancellation?.cancel()
    conflictResolver?.cancel()
    conflict = nil
    phase = .stopping
  }
  func shutdown() {
    cancellation?.cancel()
    conflictResolver?.cancel()
    conflict = nil
    revision += 1
  }
  deinit {
    cancellation?.cancel()
    conflictResolver?.cancel()
  }
}
