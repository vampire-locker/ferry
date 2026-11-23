import AppKit
import FerryCore
import ImageIO
import SwiftUI

enum BrowserViewMode: String, CaseIterable {
  case list, preview
}

/// Shares the main runner. Foreground operations suspend and await this worker
/// before opening USB, so thumbnail reads can never overlap navigation/downloads.
@MainActor
final class MediaController: ObservableObject {
  @Published var previewEntry: RemoteEntry?
  @Published private(set) var previewURL: URL?
  @Published private(set) var previewError: String?
  @Published private(set) var previewBytes: Int64 = 0
  @Published private(set) var previewTotal: Int64 = 0
  @Published private(set) var thumbnailRevision = 0
  @Published private(set) var requestVersion = 0
  @Published private(set) var thumbnailError: String?
  private let runner: any EngineRunning
  private let images = NSCache<NSString, NSImage>()
  // Visible images must survive NSCache eviction. Release these references as
  // soon as their cells leave the viewport; the offscreen cache stays bounded.
  private var visibleImages: [String: NSImage] = [:]
  private var demanded: [String: RemoteEntry] = [:]
  private var thumbnailIssues: [String: String] = [:]
  private var worker: Task<Void, Never>?
  private var reading = false
  private var suspended = true
  private var generation = 0
  private var deviceKey = ""
  private var usbTarget: USBDeviceTarget?
  private var demo = false
  private var showHiddenFiles = false
  private var temporaryDirectories = Set<URL>()

  init(runner: any EngineRunning) {
    self.runner = runner
    images.countLimit = 128
    images.totalCostLimit = 48 * 1024 * 1024
  }

  private func key(_ entry: RemoteEntry) -> String {
    "\(entry.storageID)-\(entry.id)-\(entry.size)-\(entry.modified)-\(entry.name)"
  }

  func thumbnail(for entry: RemoteEntry) -> NSImage? {
    visibleImages[key(entry)] ?? images.object(forKey: key(entry) as NSString)
  }

  func thumbnailIssue(for entry: RemoteEntry) -> String? { thumbnailIssues[key(entry)] }

  func isLoadingThumbnail(_ entry: RemoteEntry) -> Bool {
    entry.isThumbnailEligible && demanded[key(entry)] != nil && thumbnail(for: entry) == nil
      && thumbnailIssue(for: entry) == nil && thumbnailError == nil && !suspended
  }

  func setThumbnailDemand(_ entries: [RemoteEntry]) {
    let requested = Dictionary(
      entries.filter(\.isThumbnailEligible).map { (key($0), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    guard Set(requested.keys) != Set(demanded.keys) else { return }
    demanded = requested
    visibleImages = visibleImages.filter { requested[$0.key] != nil }
    for entry in requested.values {
      if let image = images.object(forKey: key(entry) as NSString) {
        visibleImages[key(entry)] = image
      }
    }
    thumbnailRevision += 1
    scheduleThumbnails()
  }

  func requestThumbnail(_ entry: RemoteEntry) {
    guard entry.isThumbnailEligible else { return }
    demanded[key(entry)] = entry
    if let image = images.object(forKey: key(entry) as NSString) {
      visibleImages[key(entry)] = image
    }
    scheduleThumbnails()
  }

  func releaseThumbnail(_ entry: RemoteEntry) {
    demanded[key(entry)] = nil
    visibleImages[key(entry)] = nil
  }

  func retryThumbnails(_ entry: RemoteEntry? = nil) {
    if let entry {
      thumbnailIssues[key(entry)] = nil
      images.removeObject(forKey: key(entry) as NSString)
      visibleImages[key(entry)] = nil
    } else {
      for entry in demanded.values { thumbnailIssues[key(entry)] = nil }
    }
    thumbnailError = nil
    thumbnailRevision += 1
    scheduleThumbnails()
  }

  private func cancelWorker() {
    generation += 1
    requestVersion += 1
    // Cancelling the Swift task terminates AsyncThrowingStream iteration before
    // the helper has actually exited. While reading, drain the stream instead.
    if reading { runner.cancel() } else { worker?.cancel() }
  }

  func suspend() {
    suspended = true
    demanded.removeAll()
    visibleImages.removeAll()
    cancelWorker()
    previewEntry = nil
    previewURL = nil
    discardTemporaryFiles(after: worker)
  }

  func waitUntilIdle() async {
    let token = generation
    await worker?.value
    if token == generation { worker = nil }
  }

  func resume(
    deviceKey: String, demo: Bool, showHiddenFiles: Bool, usbTarget: USBDeviceTarget? = nil
  ) {
    self.deviceKey = deviceKey
    self.usbTarget = usbTarget
    self.demo = demo
    self.showHiddenFiles = showHiddenFiles
    suspended = false
    requestVersion += 1
    thumbnailError = nil
    if let previous = worker {
      let token = generation
      worker = Task { [weak self] in
        await previous.value
        guard let self, token == generation else { return }
        worker = nil
        scheduleThumbnails()
      }
    } else {
      scheduleThumbnails()
    }
  }

  func reset() {
    suspend()
    images.removeAllObjects()
    thumbnailIssues.removeAll()
    thumbnailError = nil
    thumbnailRevision += 1
  }

  func shutdown() {
    suspended = true
    cancelWorker()
    previewEntry = nil
    previewURL = nil
    visibleImages.removeAll()
    images.removeAllObjects()
    // The caller has already shut down the helper. Only our private directories
    // are removed; user downloads never enter this set.
    for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
    temporaryDirectories.removeAll()
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Ferry-media-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    temporaryDirectories.insert(directory)
    return directory
  }

  private func remove(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
    temporaryDirectories.remove(directory)
  }

  private func discardTemporaryFiles(after previous: Task<Void, Never>?) {
    let directories = temporaryDirectories
    Task {
      await previous?.value
      for directory in directories { remove(directory) }
    }
  }

  private func scheduleThumbnails() {
    guard !suspended, thumbnailError == nil, previewEntry == nil, !demanded.isEmpty else { return }
    // One worker drains the visible-cell demand in small batches. Scrolling only
    // updates demand; it never starts a second helper alongside this worker.
    guard worker == nil else { return }
    let token = generation
    worker = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: 120_000_000)
      var retryCount = 0
      while !Task.isCancelled && token == generation && !suspended && previewEntry == nil {
        let batch = Array(
          demanded.values.filter {
            self.thumbnail(for: $0) == nil && self.thumbnailIssue(for: $0) == nil
          }.sorted { $0.id < $1.id }.prefix(24))
        if batch.isEmpty { break }
        do {
          let directory = try makeTemporaryDirectory()
          defer { remove(directory) }
          let request = EngineRequest(
            operation: "thumbnails", deviceKey: deviceKey, storageID: batch[0].storageID,
            objectIDs: batch.map(\.id), destination: directory.path,
            showHiddenFiles: showHiddenFiles, usbTarget: usbTarget)
          reading = true
          defer { reading = false }
          var received = Set<UInt32>()
          var finished = false
          var failure: String?
          for try await event in runner.events(for: request, demo: demo) {
            guard !Task.isCancelled, token == generation else { continue }
            // Drain even an error event until the helper exits before retrying.
            if event.type == "error" { failure = event.message ?? L10n.text("缩略图读取失败") }
            if event.type == "completed" { finished = true }
            if event.type == "thumbnail", let id = event.objectID,
              let entry = batch.first(where: { $0.id == id })
            {
              received.insert(id)
              if let path = event.output {
                let url: URL
                do { url = try validatedOutput(path, inside: directory) } catch {
                  thumbnailIssues[key(entry)] = error.localizedDescription
                  thumbnailRevision += 1
                  continue
                }
                let cgImage = await Task.detached(priority: .utility) {
                  Self.decodeThumbnail(url)
                }.value
                guard token == generation, !Task.isCancelled else { continue }
                if let cgImage {
                  let image = NSImage(cgImage: cgImage, size: .zero)
                  if demanded[key(entry)] != nil { visibleImages[key(entry)] = image }
                  images.setObject(
                    image, forKey: key(entry) as NSString,
                    cost: cgImage.bytesPerRow * cgImage.height)
                  thumbnailIssues[key(entry)] = nil
                } else {
                  thumbnailIssues[key(entry)] = L10n.text("缩略图无法解码，可重试或按空格预览原图")
                }
              } else {
                thumbnailIssues[key(entry)] = event.message ?? L10n.text("设备暂未提供可用缩略图，可重试或按空格预览")
              }
              thumbnailRevision += 1
            }
          }
          if token == generation, !Task.isCancelled {
            if let failure { throw EngineFailure(failure) }
            guard finished, received.count == batch.count else {
              throw EngineFailure(L10n.text("缩略图未完整读取，请重试"))
            }
          }
        } catch {
          guard token == generation, !Task.isCancelled else { break }
          if retryCount == 0 {
            retryCount += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            continue
          }
          thumbnailError = error.localizedDescription
          break
        }
      }
      if token == generation { worker = nil }
    }
  }

  func openPreview(_ entry: RemoteEntry) {
    guard !suspended, !entry.isDirectory else { return }
    cancelWorker()
    let previous = worker
    discardTemporaryFiles(after: previous)
    previewEntry = entry
    previewURL = nil
    previewError = entry.isPreviewable ? nil : L10n.text("此格式暂不支持预览，可下载后打开")
    previewBytes = 0
    previewTotal = entry.size
    let token = generation
    worker = Task { [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled, token == generation else { return }
      guard entry.isPreviewable else {
        previewError = L10n.text("此格式暂不支持预览，可下载后打开")
        worker = nil
        return
      }
      var directory: URL?
      do {
        let created = try makeTemporaryDirectory()
        directory = created
        let request = EngineRequest(
          operation: "preview", deviceKey: deviceKey, storageID: entry.storageID,
          objectIDs: [entry.id], destination: created.path, showHiddenFiles: showHiddenFiles,
          usbTarget: usbTarget)
        var result: URL?
        var failure: String?
        reading = true
        defer { reading = false }
        for try await event in runner.events(for: request, demo: demo) {
          guard !Task.isCancelled, token == generation else { continue }
          switch event.type {
          case "progress":
            previewBytes = event.bytes ?? 0
            previewTotal = event.totalBytes ?? entry.size
          case "completed":
            if let path = event.output {
              do { result = try validatedOutput(path, inside: created) } catch {
                failure = error.localizedDescription
              }
            }
          case "error": failure = event.message ?? L10n.text("预览读取失败")
          default: break
          }
        }
        if token == generation, !Task.isCancelled {
          if let failure { throw EngineFailure(failure) }
          guard let result else { throw EngineFailure(L10n.text("预览文件未完整读取，请重试")) }
          previewURL = result
          previewBytes = entry.size
        } else {
          remove(created)
        }
      } catch {
        if let directory { remove(directory) }
        if token == generation, !Task.isCancelled { previewError = error.localizedDescription }
      }
      if token == generation { worker = nil }
    }
  }

  func closePreview() {
    cancelWorker()
    let previous = worker
    previewEntry = nil
    previewURL = nil
    discardTemporaryFiles(after: previous)
    // Preserve the chain until the cancelled helper exits before resuming cells.
    let token = generation
    worker = Task { [weak self] in
      await previous?.value
      guard let self, token == generation else { return }
      worker = nil
      scheduleThumbnails()
    }
  }

  private func validatedOutput(_ path: String, inside directory: URL) throws -> URL {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let root = directory.resolvingSymlinksInPath().path + "/"
    guard url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path) else {
      throw EngineFailure(L10n.text("预览缓存路径无效"))
    }
    return url
  }

  nonisolated static func decodeThumbnail(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 384,
      ] as CFDictionary)
  }
}
