import Combine
import FerryCore
import Foundation

@MainActor
private final class DuplicateProgressDelivery {
  weak var owner: DuplicatePhotosController?
  let revision: Int
  init(_ owner: DuplicatePhotosController, revision: Int) {
    self.owner = owner
    self.revision = revision
  }
  nonisolated func send(_ value: DuplicatePhotoProgress) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      owner?.receive(value, revision: revision)
    }
  }
}

@MainActor
final class DuplicatePhotosController: ObservableObject {
  enum Phase { case idle, scanning, ready, trashing, stopping, scanCancelled, finished }
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var folder: URL?
  @Published private(set) var recursive = true
  @Published private(set) var plan: DuplicatePhotoPlan?
  @Published private(set) var progress = DuplicatePhotoProgress()
  @Published private(set) var result: DuplicateCleanupResult?
  @Published private(set) var error: String?
  @Published private(set) var selectedGroups: Set<String> = []
  @Published private(set) var keepers: [String: String] = [:]
  @Published private(set) var selectedCopies = 0
  @Published private(set) var selectedBytes: Int64 = 0
  @Published private(set) var preferredFolder: URL?
  private var byID: [String: DuplicatePhotoGroup] = [:]
  private var cancellation: PhotoRepairCancellation?
  private var worker: Task<Void, Never>?
  private var revision = 0
  private let trash: (@Sendable (URL) throws -> Void)?

  init(trash: (@Sendable (URL) throws -> Void)? = nil) { self.trash = trash }
  var isBusy: Bool { phase == .scanning || phase == .trashing || phase == .stopping }
  var canClean: Bool { phase == .ready && selectedCopies > 0 }

  func selectFolder(_ folder: URL) {
    guard !isBusy, folder.isFileURL else { return }
    self.folder = folder
    scan()
  }
  func setRecursive(_ value: Bool) {
    guard !isBusy else { return }
    recursive = value
    plan = nil
    result = nil
    error = nil
    phase = .idle
    resetSelection()
  }
  private func resetSelection() {
    selectedGroups = []
    keepers = [:]
    selectedCopies = 0
    selectedBytes = 0
    preferredFolder = nil
    byID = [:]
  }

  func scan() {
    guard !isBusy, let folder else { return }
    let token = PhotoRepairCancellation()
    cancellation = token
    revision += 1
    let revision = revision
    let recursive = recursive
    let delivery = DuplicateProgressDelivery(self, revision: revision)
    plan = nil
    result = nil
    error = nil
    progress = .init()
    resetSelection()
    phase = .scanning
    let work = Task.detached(priority: .utility) {
      try DuplicatePhotos.scan(folder: folder, recursive: recursive, cancellation: token) {
        delivery.send($0)
      }
    }
    worker = Task { [weak self] in
      do {
        let plan = try await work.value
        guard let self, self.revision == revision else { return }
        self.plan = plan
        self.byID = Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.id, $0) })
        self.keepers = Dictionary(
          uniqueKeysWithValues: plan.groups.map { ($0.id, $0.photos[0].id) })
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

  func selectGroup(_ id: String, selected: Bool) {
    guard phase == .ready, byID[id] != nil else { return }
    if selected { selectedGroups.insert(id) } else { selectedGroups.remove(id) }
    updateCounts()
  }
  func selectAll(_ selected: Bool) {
    guard phase == .ready else { return }
    selectedGroups = selected ? Set(byID.keys) : []
    updateCounts()
  }
  func keep(_ photoID: String, in groupID: String) {
    guard phase == .ready, byID[groupID]?.photos.contains(where: { $0.id == photoID }) == true
    else { return }
    keepers[groupID] = photoID
  }
  func preferFolder(_ folder: URL) {
    guard phase == .ready, let plan else { return }
    let root = plan.folder.resolvingSymlinksInPath().pathComponents
    let preferred = folder.resolvingSymlinksInPath().pathComponents
    guard folder.isFileURL, preferred.starts(with: root) else {
      error = L10n.text("请选择扫描文件夹内的保留目录。")
      return
    }
    let parts = Array(preferred.dropFirst(root.count))
    for group in plan.groups {
      if let photo = group.photos.first(where: {
        $0.relativePath.split(separator: "/").map(String.init).dropLast().starts(with: parts)
      }) {
        keepers[group.id] = photo.id
      }
    }
    preferredFolder = folder
    error = nil
  }
  private func updateCounts() {
    selectedCopies = selectedGroups.reduce(0) { $0 + (byID[$1]?.photos.count ?? 1) - 1 }
    selectedBytes = selectedGroups.reduce(0) { $0 + (byID[$1]?.duplicateBytes ?? 0) }
  }

  func clean() {
    guard canClean, let plan else { return }
    let choices = selectedGroups.sorted().compactMap { id in
      keepers[id].map { DuplicateKeepChoice(groupID: id, keepID: $0) }
    }
    guard choices.count == selectedGroups.count else { return }
    let token = PhotoRepairCancellation()
    cancellation = token
    revision += 1
    let revision = revision
    let trash = trash
    let delivery = DuplicateProgressDelivery(self, revision: revision)
    error = nil
    result = nil
    progress = .init()
    progress.stage = .trashing
    progress.total = selectedCopies
    phase = .trashing
    let work = Task.detached(priority: .utility) {
      try DuplicatePhotos.moveToTrash(plan, choices: choices, cancellation: token, trash: trash) {
        delivery.send($0)
      }
    }
    worker = Task { [weak self] in
      do {
        let result = try await work.value
        guard let self, self.revision == revision else { return }
        self.result = result
        self.phase = .finished
        self.worker = nil
      } catch {
        guard let self, self.revision == revision else { return }
        self.error = error.localizedDescription
        self.phase = .finished
        self.worker = nil
      }
    }
  }

  fileprivate func receive(_ value: DuplicatePhotoProgress, revision: Int) {
    guard self.revision == revision, isBusy else { return }
    progress = value
  }
  func cancel() {
    guard isBusy else { return }
    cancellation?.cancel()
    phase = .stopping
  }
  func shutdown() {
    cancellation?.cancel()
    revision += 1
  }
  deinit { cancellation?.cancel() }
}
