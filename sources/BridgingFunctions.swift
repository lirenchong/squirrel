//
//  BridgingFunctions.swift
//  Squirrel
//
//  Created by Leo Liu on 5/11/24.
//

import Foundation

protocol DataSizeable {
  // swiftlint:disable:next identifier_name
  var data_size: Int32 { get set }
}

extension RimeContext_stdbool: DataSizeable {}
extension RimeTraits: DataSizeable {}
extension RimeCommit: DataSizeable {}
extension RimeStatus_stdbool: DataSizeable {}
extension RimeModule: DataSizeable {}

// RimeApi is a versioned function table. Do not dereference a newer slot just
// because the build-time headers declare it; check the loaded table and pointer.
func rimeAPIHasFunction<T>(_ member: KeyPath<RimeApi_stdbool, T>) -> Bool {
  guard let api = rime_get_api_stdbool(),
        let offset = MemoryLayout<RimeApi_stdbool>.offset(of: member),
        Int(api.pointee.data_size) + MemoryLayout<Int32>.size >= offset + MemoryLayout<T>.size else { return false }
  return UnsafeRawPointer(api).load(fromByteOffset: offset, as: UnsafeRawPointer?.self) != nil
}

// get_property may return true for a full, unterminated prefix. Never scan
// beyond the supplied buffer or decode an incomplete UTF-8 sequence.
func rimePropertyBytes(_ api: RimeApi_stdbool, session: RimeSessionId, name: String, capacity: Int) -> [UInt8]? {
  guard capacity > 0, rimeAPIHasFunction(\.get_property) else { return nil }
  guard let memory = malloc(capacity) else { return nil }
  defer { free(memory) }
  memset(memory, 255, capacity)
  let pointer = memory.assumingMemoryBound(to: CChar.self)
  let buffer = UnsafeBufferPointer(start: pointer, count: capacity)
  guard api.get_property(session, name, pointer, capacity), let end = buffer.firstIndex(of: 0) else { return nil }
  return buffer[..<end].map { UInt8(bitPattern: $0) }
}

extension DataSizeable {
  static func rimeStructInit() -> Self {
    let valuePointer = UnsafeMutablePointer<Self>.allocate(capacity: 1)
    // Initialize the memory to zero
    memset(valuePointer, 0, MemoryLayout<Self>.size)
    // Convert the pointer to a managed Swift variable
    var value = valuePointer.move()
    valuePointer.deallocate()
    // Initialize data_size property
    let offset = MemoryLayout.size(ofValue: \Self.data_size)
    value.data_size = Int32(MemoryLayout<Self>.size - offset)
    return value
  }

  mutating func setCString(_ swiftString: String, to keypath: WritableKeyPath<Self, UnsafePointer<CChar>?>) {
    swiftString.withCString { cStr in
      // Duplicate the string to create a persisting C string
      let mutableCStr = strdup(cStr)
      // Free the existing string if there is one
      if let existing = self[keyPath: keypath] {
        free(UnsafeMutableRawPointer(mutating: existing))
      }
      self[keyPath: keypath] = UnsafePointer(mutableCStr)
    }
  }
}

infix operator ?= : AssignmentPrecedence
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T, right: T?) {
  if let right = right {
    left = right
  }
}
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T?, right: T?) {
  if let right = right {
    left = right
  }
}

extension NSRange {
  static let empty = NSRange(location: NSNotFound, length: 0)
}

extension NSPoint {
  static func += (lhs: inout Self, rhs: Self) {
    lhs.x += rhs.x
    lhs.y += rhs.y
  }
  static func - (lhs: Self, rhs: Self) -> Self {
    Self.init(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }
  static func -= (lhs: inout Self, rhs: Self) {
    lhs.x -= rhs.x
    lhs.y -= rhs.y
  }
  static func * (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x * rhs, y: lhs.y * rhs)
  }
  static func / (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x / rhs, y: lhs.y / rhs)
  }
  var length: CGFloat {
    sqrt(pow(self.x, 2) + pow(self.y, 2))
  }
}
