import Combine
import FerryCore
import Foundation

@MainActor
private final class PhotoRepairProgressDelivery {
  weak var owner: PhotoDateRepairController?
  let revision: Int
  init(_ owner: PhotoDateRepairController, revision: Int) {
    self.owner = owner
    self.revision = revision
  }
  nonisolated func send(_ value: PhotoRepairProgress) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      owner?.receive(value, revision: revision)
    }
  }
}

@MainActor
final class PhotoDateRepairController: ObservableObject {
  enum Phase { case idle, scanning, ready, applying, stopping, scanCancelled, finished }
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var folder: URL?
  @Published private(set) var plan: PhotoRepairPlan?
  @Published private(set) var result: PhotoRepairResult?
  @Published private(set) var progress = PhotoRepairProgress()
  @Published private(set) var error: String?
  @Published private(set) var recursive = true
  @Published private(set) var images = true
  @Published private(set) var videos = true
  @Published private(set) var allowFilename = true
  @Published private(set) var allowDateOnly = true
  @Published private(set) var repairModificationDate = false
  private var cancellation: PhotoRepairCancellation?
  private var worker: Task<Void, Never>?
  private var revision = 0
  private var scanningOperation = false

  var isBusy: Bool { phase == .scanning || phase == .applying || phase == .stopping }
  var canApply: Bool { phase == .ready && plan?.items.isEmpty == false }
  var isScanning: Bool { phase == .scanning || phase == .stopping && scanningOperation }

  func selectFolder(_ url: URL) {
    guard !isBusy, url.isFileURL else { return }
    folder = url
    scan()
  }

  func setOptions(
    recursive: Bool? = nil, allowFilename: Bool? = nil, allowDateOnly: Bool? = nil,
    repairModificationDate: Bool? = nil, images: Bool? = nil, videos: Bool? = nil
  ) {
    guard !isBusy else { return }
    if let recursive { self.recursive = recursive }
    if let images { self.images = images }
    if let videos { self.videos = videos }
    if let allowFilename { self.allowFilename = allowFilename }
    if let allowDateOnly { self.allowDateOnly = allowDateOnly }
    if let repairModificationDate { self.repairModificationDate = repairModificationDate }
    plan = nil
    result = nil
    error = nil
    phase = .idle
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
    let filename = allowFilename
    let dateOnly = allowDateOnly
    let repairModificationDate = repairModificationDate
    scanningOperation = true
    let delivery = PhotoRepairProgressDelivery(self, revision: revision)
    plan = nil
    result = nil
    error = nil
    progress = .init()
    phase = .scanning
    let work = Task.detached(priority: .utility) {
      try await PhotoDateRepair.scan(
        folder: folder, recursive: recursive, allowFilename: filename, allowDateOnly: dateOnly,
        repairModificationDate: repairModificationDate, images: images, videos: videos,
        cancellation: token
      ) { value in
        delivery.send(value)
      }
    }
    worker = Task { [weak self] in
      do {
        let plan = try await work.value
        guard let self, self.revision == revision else { return }
        self.plan = plan
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
    scanningOperation = false
    let delivery = PhotoRepairProgressDelivery(self, revision: revision)
    error = nil
    result = nil
    progress = .init()
    progress.total = plan.items.count
    phase = .applying
    let work = Task.detached(priority: .utility) {
      try PhotoDateRepair.apply(plan, cancellation: token) { value in
        delivery.send(value)
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

  fileprivate func receive(_ value: PhotoRepairProgress, revision: Int) {
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
