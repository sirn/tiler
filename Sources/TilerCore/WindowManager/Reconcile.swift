import AppKit
import CoreGraphics
import Foundation

/// True when every edge of `a` and `b` is within `tolerance`.
public func framesMatch(_ a: NSRect, _ b: NSRect, tolerance: CGFloat) -> Bool {
  abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
    && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

public enum EchoDecision: Equatable {
  case echo
  case genuineMove
}

/// Pure echo decision. `applied` is the frame we last told the window to take
/// (nil when we have no record). No record → genuine move.
public func classifyGeometryChange(observed: NSRect, applied: NSRect?, tolerance: CGFloat)
  -> EchoDecision
{
  guard let applied else { return .genuineMove }
  return framesMatch(observed, applied, tolerance: tolerance) ? .echo : .genuineMove
}

public struct ReconcilePlan: Equatable {
  public let toAdd: Set<CGWindowID>
  public let toReap: Set<CGWindowID>
  public let updatedMissingCounts: [CGWindowID: Int]
  public let hasPendingMiss: Bool
  public let updatedResolveCounts: [CGWindowID: Int]
  public let hasPendingResolve: Bool
  public let hasPendingNoElementResolve: Bool
}

/// Pure membership diff. Inputs are plain facts gathered by the caller.
/// missThreshold is the consecutive-miss count required before reaping.
/// unresolvedIDs are CGWindowList candidates that could not be tiled this pass
/// (no AX element yet, or not tileable). resolveThreshold bounds the retry budget.
public func reconcilePlan(
  managedIDs: Set<CGWindowID>,
  stillAliveIDs: Set<CGWindowID>,
  tileableIDs: Set<CGWindowID>,
  missingCounts: [CGWindowID: Int],
  missThreshold: Int,
  unresolvedIDs: Set<CGWindowID> = [],
  noElementIDs: Set<CGWindowID> = [],
  resolveCounts: [CGWindowID: Int] = [:],
  resolveThreshold: Int = 8,
  reapingAllowed: Bool = true
) -> ReconcilePlan {
  var counts = missingCounts
  var toReap: Set<CGWindowID> = []
  for id in managedIDs {
    if stillAliveIDs.contains(id) {
      counts[id] = 0
    } else {
      if reapingAllowed {
        counts[id, default: 0] += 1
        if counts[id]! >= missThreshold { toReap.insert(id) }
      }
    }
  }
  counts = counts.filter { managedIDs.contains($0.key) }
  let hasPendingMiss = reapingAllowed && counts.values.contains { $0 == 1 }
  let toAdd = tileableIDs.subtracting(managedIDs)

  var resolve = resolveCounts
  var hasPendingResolve = false
  for id in unresolvedIDs {
    let n = (resolve[id] ?? 0) + 1
    resolve[id] = n
    if n < resolveThreshold { hasPendingResolve = true }
  }
  // Keep counts only for ids still unresolved this pass (resolved/gone ids drop out)
  resolve = resolve.filter { unresolvedIDs.contains($0.key) }

  // No-element windows always trigger a retry regardless of count
  // (they'll succeed once the AX element becomes available)
  let hasPendingNoElementResolve = !noElementIDs.isEmpty

  return ReconcilePlan(
    toAdd: toAdd, toReap: toReap, updatedMissingCounts: counts, hasPendingMiss: hasPendingMiss,
    updatedResolveCounts: resolve, hasPendingResolve: hasPendingResolve,
    hasPendingNoElementResolve: hasPendingNoElementResolve)
}

/// Whether a reconcile pass should suppress reaping because the managed windows
/// vanished en masse from a system transition rather than genuine closure.
///
/// Both cases require that no managed window is alive this pass:
/// - Display-wake lag: CGWindowList returned nothing on screen while managed
///   windows exist. The scan hasn't caught up to reality yet.
/// - Screen saver / display sleep: the AX server is suspended, so every managed
///   window loses its AX element at once, yet CGWindowList still reports them
///   (onScreenIDs contains the managed ids). Reaping here would discard every
///   column assignment and width, since the next pass re-adds the windows as
///   fresh columns on the active workspace — exactly the screen-saver regression.
///
/// Genuine closure removes windows from CGWindowList, so managedIDs and
/// onScreenIDs stop overlapping and this returns false; reaping proceeds.
public func massDisappearanceActive(
  managedIDs: Set<CGWindowID>,
  stillAliveIDs: Set<CGWindowID>,
  onScreenIDs: Set<CGWindowID>
) -> Bool {
  guard !managedIDs.isEmpty, stillAliveIDs.isEmpty else { return false }
  if onScreenIDs.isEmpty { return true }
  return !managedIDs.intersection(onScreenIDs).isEmpty
}
