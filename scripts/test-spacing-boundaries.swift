// From the fork root: swiftc -import-objc-header sources/Squirrel-Bridging-Header.h -I librime/src -I librime/include sources/BridgingFunctions.swift sources/SpacingBoundaries.swift scripts/test-spacing-boundaries.swift -o build/synthetic-imk-probe/spacing-boundaries-test && build/synthetic-imk-probe/spacing-boundaries-test
// Literal expectations are independent of the boundary classifier.
import Foundation

@main
struct SpacingBoundariesTest {
  static func main() {
    func check(_ name: String, inserted: String, left: Character?, right: Character?,
               before: Bool, after: Bool) {
      let decision = spacesAroundInsertion(inserted, left: left, right: right)
      guard decision.before == before && decision.after == after else {
        fputs("FAIL \(name): expected (\(before), \(after)), got \(decision)\n", stderr)
        exit(1)
      }
      print("PASS \(name)")
    }

    // The insertion block remains untouched; only its two outer boundaries qualify.
    check("甲ab乙 -> 甲 ab 乙", inserted: "ab", left: "甲", right: "乙", before: true, after: true)
    check("甲42乙 -> 甲 42 乙", inserted: "42", left: "甲", right: "乙", before: true, after: true)
    check("left space, right Han", inserted: "ab", left: " ", right: "乙",
          before: false, after: true)
    check("left Han, right space", inserted: "42", left: "甲", right: " ",
          before: true, after: false)
    check("line start", inserted: "ab", left: nil, right: "乙", before: false, after: true)
    check("line end", inserted: "42", left: "甲", right: nil, before: true, after: false)
    check("line middle with right-side text", inserted: "甲", left: "x", right: "7",
          before: true, after: true)
    check("ASCII token stays whole", inserted: "v1.2.3", left: nil, right: "版",
          before: false, after: true)
    check("version ends at digit before Han", inserted: "版本", left: "3", right: nil,
          before: true, after: false)
    check("ASCII token internal adjacency", inserted: "1.2.3", left: "v", right: "4",
          before: false, after: false)
    check("emoji breaks left boundary", inserted: "ab", left: "😀", right: "乙",
          before: false, after: true)
    check("emoji breaks right boundary", inserted: "😀", left: "甲", right: "a",
          before: false, after: false)
    check("punctuation breaks boundary", inserted: "ab", left: "，", right: "。",
          before: false, after: false)
    check("newline breaks boundary", inserted: "ab", left: "\n", right: "乙",
          before: false, after: true)
    check("inserted newline has no cross-line spacing", inserted: "ab\n", left: "甲", right: "乙",
          before: true, after: false)
    check("empty insertion", inserted: "", left: "甲", right: "a", before: false, after: false)
    check("already formatted, second pass adds nothing", inserted: "ab", left: " ", right: " ",
          before: false, after: false)
    check("supplementary Han", inserted: "A", left: "𠀀", right: nil, before: true, after: false)
    check("non-ASCII digit excluded", inserted: "４", left: "甲", right: "乙",
          before: false, after: false)
    print("Synthetic boundary decisions only; no host reads, writes, undo, or target-app proof.")
  }
}
