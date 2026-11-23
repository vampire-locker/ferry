import Darwin
import Foundation

// ImageIO omits some PNG tEXt creation-time fields. Read only that bounded metadata;
// skip pixel payloads by validated chunk lengths and validate the selected chunk CRC.
enum PNGCreationTime {
  static func read(_ fd: Int32, cancellation: PhotoRepairCancellation, timeZone: TimeZone)
    -> MediaCaptureTimestamp?
  {
    guard let info = try? LocalImageFiles.checkedStat(fd), info.st_size >= 20 else { return nil }
    func bytes(_ offset: Int64, _ count: Int) -> [UInt8]? {
      guard !cancellation.isCancelled, offset >= 0, count >= 0,
        offset <= info.st_size, Int64(count) <= info.st_size - offset
      else { return nil }
      var output = [UInt8](repeating: 0, count: count)
      let read = output.withUnsafeMutableBytes { buffer -> Int in
        var value: Int
        repeat {
          value = pread(fd, buffer.baseAddress, count, off_t(offset))
        } while value < 0 && errno == EINTR
        return value
      }
      return read == count ? output : nil
    }
    func number(_ data: ArraySlice<UInt8>) -> UInt32 { data.reduce(0) { ($0 << 8) | UInt32($1) } }
    guard bytes(0, 8) == [137, 80, 78, 71, 13, 10, 26, 10] else { return nil }
    var position: Int64 = 8
    for _ in 0..<4096 {
      guard let header = bytes(position, 8) else { return nil }
      let length = Int64(number(header[0..<4]))
      guard length <= info.st_size - position - 12 else { return nil }
      let kind = Array(header[4..<8])
      if kind == Array("tEXt".utf8), length <= 4096,
        let data = bytes(position + 8, Int(length) + 4),
        let separator = data.prefix(Int(length)).firstIndex(of: 0)
      {
        let key = String(decoding: data[..<separator], as: UTF8.self).lowercased()
        if key == "creation time" || key == "creationtime" {
          var checksum = UInt32.max
          for byte in kind + data.prefix(Int(length)) {
            checksum ^= UInt32(byte)
            for _ in 0..<8 { checksum = (checksum >> 1) ^ ((checksum & 1) == 0 ? 0 : 0xedb8_8320) }
          }
          guard (checksum ^ UInt32.max) == number(data[Int(length)..<Int(length) + 4]) else {
            return nil
          }
          let text = String(decoding: data[(separator + 1)..<Int(length)], as: UTF8.self)
          if let time = MediaCaptureTimestamp.parse(text, timeZone: timeZone) { return time }
          // PNG's registered creation-time keyword commonly uses RFC 1123.
          let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
          let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
          ]
          guard fields.count == 6, let day = Int(fields[1]),
            let month = months.firstIndex(of: fields[2]),
            let year = Int(fields[3]), (1...9999).contains(year), (1...31).contains(day)
          else { return nil }
          let zone = ["GMT", "UTC", "Z"].contains(fields[5]) ? "Z" : fields[5]
          return MediaCaptureTimestamp.parse(
            String(format: "%04d-%02d-%02d ", year, month + 1, day) + fields[4] + zone,
            timeZone: timeZone)
        }
      }
      if kind == Array("IEND".utf8) { return nil }
      position += length + 12
    }
    return nil
  }
}
