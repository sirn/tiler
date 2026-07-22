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

/// True when reaping should be suppressed because managed windows vanished en
/// masse from a system transition rather than genuine closure: CGWindowList
/// returned nothing on screen (display-wake lag), or several managed windows
/// are still composited but have no live AX element this pass (AX suspended by
/// screen saver, display sleep, or another app's fullscreen Space). Genuine
/// closure removes windows from CGWindowList, so they drop out of the
/// composited-but-elementless set and this returns false.
public func massDisappearanceActive(
  managedIDs: Set<CGWindowID>,
  stillAliveIDs: Set<CGWindowID>,
  onScreenIDs: Set<CGWindowID>
) -> Bool {
  guard !managedIDs.isEmpty else { return false }
  if onScreenIDs.isEmpty { return true }
  let axSuspended = managedIDs.subtracting(stillAliveIDs).intersection(onScreenIDs)
  if axSuspended.count >= 2 { return true }
  return stillAliveIDs.isEmpty && !axSuspended.isEmpty
}
