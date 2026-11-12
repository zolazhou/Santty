import GhosttyVt

/// One viewport's owned reference, accessed only under GhosttyVTDriver's lock.
/// Unlike a row ID or a borrowed GridRef, VT tracks this cell through page
/// pruning and resize/reflow. No buffer text is copied to find it again.
final class GhosttyVTHistoryAnchor {
    private let terminal: GhosttyTerminal
    private var reference: GhosttyTrackedGridRef?
    private var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
    private var resetEpoch: UInt64 = 0
    private(set) var needsLiveReset = true

    init(terminal: GhosttyTerminal) { self.terminal = terminal }
    deinit { ghostty_tracked_grid_ref_free(reference) }

    func invalidate() {
        ghostty_tracked_grid_ref_free(reference)
        reference = nil
        needsLiveReset = true
    }

    func synchronize(resetEpoch: UInt64) throws {
        var current = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        try check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &current))
        if current != screen || resetEpoch != self.resetEpoch { invalidate() }
        screen = current
        self.resetEpoch = resetEpoch
    }

    func position() throws -> GhosttyPointCoordinate? {
        guard let reference else { return nil }
        var point = GhosttyPointCoordinate()
        let result = ghostty_tracked_grid_ref_point(reference, GHOSTTY_POINT_TAG_SCREEN, &point)
        if result == GHOSTTY_NO_VALUE { return nil }
        try check(result)
        return point
    }

    /// Called immediately after capture(), whose integer viewport is now known.
    /// The viewport lookup avoids scanning history to create a reference.
    func track(viewportRow: Int) throws {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = .init(x: 0, y: UInt32(clamping: viewportRow))
        if let reference {
            try check(ghostty_tracked_grid_ref_set(reference, terminal, point))
        } else {
            try check(ghostty_terminal_grid_ref_track(terminal, point, &reference))
        }
        needsLiveReset = false
    }

    private func check(_ result: GhosttyResult) throws {
        guard result == GHOSTTY_SUCCESS else {
            throw NativeTerminalError.api("history_anchor", result.rawValue)
        }
    }
}
