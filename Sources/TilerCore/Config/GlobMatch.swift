import Foundation

/// Returns true if `pattern` matches `target` using simple wildcard rules.
/// `*` matches any sequence of characters (including empty).
/// Matching is case-insensitive. Only `*` is special.
func globMatch(pattern: String, target: String) -> Bool {
  let p = Array(pattern.lowercased())
  let t = Array(target.lowercased())
  var pi = 0, ti = 0
  var backtrackP = -1, backtrackT = -1

  while ti < t.count {
    if pi < p.count && p[pi] == "*" {
      backtrackP = pi
      backtrackT = ti
      pi += 1
    } else if pi < p.count && (p[pi] == t[ti]) {
      pi += 1
      ti += 1
    } else if backtrackP != -1 {
      pi = backtrackP + 1
      backtrackT += 1
      ti = backtrackT
    } else {
      return false
    }
  }

  // Skip remaining * in pattern
  while pi < p.count && p[pi] == "*" {
    pi += 1
  }

  return pi == p.count
}
