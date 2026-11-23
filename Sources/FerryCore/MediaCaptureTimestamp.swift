import AVFoundation
import Foundation

struct MediaCaptureTimestamp: Sendable {
  let date: Date
  let filenamePart: String
  let year: Int
  let month: Int

  static func parse(
    _ string: String, offset: String? = nil, subsecond: String? = nil,
    timeZone: TimeZone = .current, minimumYear: Int = 1
  ) -> Self? {
    let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 19 else { return nil }
    let base = String(text.prefix(19))
    var rest = String(text.dropFirst(19))
    var fraction = subsecond
    var zone = offset
    if rest.hasPrefix(".") {
      rest.removeFirst()
      let digits = rest.prefix { $0.isASCII && $0.isNumber }
      guard !digits.isEmpty else { return nil }
      fraction = String(digits)
      rest = String(rest.dropFirst(digits.count))
    }
    if rest == "Z" {
      zone = "+00:00"
    } else if !rest.isEmpty {
      if rest.count == 5 { rest.insert(":", at: rest.index(rest.startIndex, offsetBy: 3)) }
      zone = rest
    }
    guard
      let date = PhotoDateRepair.parseDate(
        base, offset: zone, subsecond: fraction, timeZone: timeZone)
    else { return nil }
    let fields = base.components(separatedBy: CharacterSet(charactersIn: ":- T")).compactMap(
      Int.init)
    guard fields.count == 6, (minimumYear...9999).contains(fields[0]) else { return nil }
    return .init(
      date: date,
      filenamePart: String(
        format: "%04d%02d%02d_%02d%02d%02d", fields[0], fields[1], fields[2], fields[3], fields[4],
        fields[5]),
      year: fields[0], month: fields[1])
  }
  static func from(_ date: Date, timeZone: TimeZone, minimumYear: Int = 1) -> Self? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let values = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    guard let y = values.year, let m = values.month, let d = values.day,
      let h = values.hour, let minute = values.minute, let second = values.second,
      (minimumYear...9999).contains(y)
    else { return nil }
    return .init(
      date: date,
      filenamePart: String(format: "%04d%02d%02d_%02d%02d%02d", y, m, d, h, minute, second),
      year: y, month: m)
  }
  func filename(original: String, video: Bool) -> String {
    let stem = (video ? "VID_" : "IMG_") + filenamePart
    let ext = (original as NSString).pathExtension
    let oldStem = (original as NSString).deletingPathExtension
    // Keep our numbered collision names stable on subsequent scans.
    if oldStem == stem { return original }
    if oldStem.hasPrefix(stem + " ("), oldStem.hasSuffix(")") {
      let number = oldStem.dropFirst(stem.count + 2).dropLast()
      if number.first != "0", !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) {
        return original
      }
    }
    return stem + "." + ext
  }
  static func video(
    _ url: URL, timeZone: TimeZone, cancellation: PhotoRepairCancellation
  ) async -> MediaCaptureTimestamp? {
    guard !cancellation.isCancelled else { return nil }
    let asset = AVURLAsset(url: url)
    var entries = (try? await asset.load(.metadata)) ?? []
    let creation = try? await asset.load(.creationDate)
    if let creation { entries.append(creation) }
    for item in entries {
      guard !cancellation.isCancelled else {
        asset.cancelLoading()
        return nil
      }
      let key = item.identifier?.rawValue.lowercased() ?? ""
      guard
        item.commonKey == .commonKeyCreationDate || key.contains("creationdate")
          || key.contains("creation_date") || key.contains("©day")
          || creation.map({ $0 === item }) == true
      else { continue }
      if let string = try? await item.load(.stringValue),
        let time = MediaCaptureTimestamp.parse(string, timeZone: timeZone, minimumYear: 1970)
      {
        return time
      }
      if let date = try? await item.load(.dateValue) {
        if let captured = MediaCaptureTimestamp.from(date, timeZone: timeZone, minimumYear: 1970) {
          return captured
        }
      }
    }
    return nil
  }
}
