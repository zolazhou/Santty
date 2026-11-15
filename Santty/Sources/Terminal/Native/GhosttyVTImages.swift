import Foundation
import GhosttyVt

/// Owned VT output, not a second image protocol/parser or placement resolver.
final class NativeTerminalImage: Sendable {
    let id: UInt32
    let generation: UInt64
    let width: Int
    let height: Int
    let rgba: [UInt8] // top-row-first, straight alpha

    init(id: UInt32, generation: UInt64, width: Int, height: Int, rgba: [UInt8]) {
        self.id = id; self.generation = generation
        self.width = width; self.height = height; self.rgba = rgba
    }
}

struct NativeImagePlacement: Equatable, Sendable {
    enum Kind: Sendable { case fixed, virtual, relative }
    enum Layer: Int, Sendable { case belowBackground, belowText, aboveText }
    let imageID: UInt32
    let imageGeneration: UInt64
    let placementID: UInt32
    let kind: Kind
    let layer: Layer
    let z: Int32
    let column: Int
    let row: Int // absolute grid row; may precede the captured rows
    let columns: Int
    let rows: Int
    let offsetX: Int // protocol pixels, not AppKit points
    let offsetY: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceX: Int
    let sourceY: Int
    let sourceWidth: Int
    let sourceHeight: Int
}

struct NativeImageSnapshot: Sendable {
    let revision: UInt64
    let storageGeneration: UInt64
    let placementGeneration: UInt64
    let images: [UInt32: NativeTerminalImage]
    let placements: [NativeImagePlacement]
    /// Limits/unknown formats are observable, not silently declared rendered.
    let limited: Bool
    static let empty = Self(revision: 0, storageGeneration: 0, placementGeneration: 0,
        images: [:], placements: [], limited: false)
}

struct NativeImageAnimationWake: Equatable, Sendable {
    let deadlineMilliseconds: UInt64
    let delayMilliseconds: UInt64
}

struct NativeImageSnapshotLimits: Sendable {
    var bytes = 16 * 1024 * 1024
    var placements = 1024
}

/// Called only under GhosttyVTDriver's lock. Iterators, storage handles and
/// pixel pointers never escape a capture. Only currently captured images are
/// cached; scrolling history does not create another image/history store.
final class GhosttyVTImages {
    static let storageBytes: UInt64 = 10_000_000 // the pinned VT default
    private var iterator: GhosttyRenderStateImageIterator?
    private let limits: NativeImageSnapshotLimits
    private var cache: [UInt32: NativeTerminalImage] = [:]
    private var previous: [NativeImagePlacement] = []
    private var previousLimited = false
    private var revision: UInt64 = 0

    init(terminal: GhosttyTerminal, limits: NativeImageSnapshotLimits) throws {
        self.limits = .init(bytes: max(0, limits.bytes), placements: max(0, limits.placements))
        var iterator: GhosttyRenderStateImageIterator?
        do {
            try imageCheck(ghostty_render_state_image_iterator_new(nil, &iterator), "image_iterator_new")
            var storage = Self.storageBytes
            try imageCheck(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &storage), "image_limit")
            // A remote terminal must never read/unlink local paths or access
            // shared memory. Keep all non-direct transports explicitly off.
            for option in [GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
                           GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
                           GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM] {
                try imageCheck(ghostty_terminal_set(terminal, option, nil), "image_medium_off")
            }
            var fileEnabled = false, sharedEnabled = false
            var temporaryDirectory = GhosttyString()
            try imageCheck(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_FILE, &fileEnabled), "image_file_policy")
            try imageCheck(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_SHARED_MEM, &sharedEnabled), "image_shared_policy")
            try imageCheck(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_TEMP_FILE, &temporaryDirectory), "image_temporary_policy")
            guard !fileEnabled, !sharedEnabled, temporaryDirectory.len == 0 else {
                throw NativeTerminalError.api("image_external_media_policy", GHOSTTY_INVALID_VALUE.rawValue)
            }
            var apc = UInt(16 * 1024 * 1024)
            try imageCheck(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES, &apc), "apc_limit")
            try imageCheck(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY, &apc), "image_apc_limit")
        } catch { ghostty_render_state_image_iterator_free(iterator); throw error }
        self.iterator = iterator
    }

    func dispose() {
        ghostty_render_state_image_iterator_free(iterator)
        iterator = nil; cache = [:]
    }

    func reset() { cache = [:] }

    /// Call once per actual presentation, before render-state update/capture.
    /// VT owns frame choice, loops/composition and late-call behavior. No image
    /// handle or pixel pointer from before this mutation may be reused.
    func advanceAnimations(terminal: GhosttyTerminal, now: UInt64) throws -> UInt64? {
        var graphics: GhosttyKittyGraphics?
        try imageCheck(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics), "animation_storage")
        var next: UInt64 = 0
        let result = ghostty_kitty_graphics_animation_tick(graphics, now, &next)
        if result == GHOSTTY_NO_VALUE { return nil }
        try imageCheck(result, "animation_tick")
        guard next > now else {
            // Do not turn an unsupported/nonfuture deadline into a busy loop
            // or hide it with a production delay/frame-rate workaround.
            throw NativeTerminalError.api("animation_nonfuture_deadline", GHOSTTY_INVALID_VALUE.rawValue)
        }
        return next
    }

    func capture(terminal: GhosttyTerminal, state: GhosttyRenderState, topRow: Int) throws -> NativeImageSnapshot {
        var graphics: GhosttyKittyGraphics?
        try imageCheck(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics), "image_storage")
        var storageGeneration: UInt64 = 0, placementGeneration: UInt64 = 0
        try imageCheck(ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &storageGeneration), "image_storage_generation")
        try imageCheck(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION, &placementGeneration), "image_placement_generation")
        var target = iterator
        try imageCheck(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &target), "image_iterator_fill")
        var images: [UInt32: NativeTerminalImage] = [:], placements: [NativeImagePlacement] = []
        var used = 0, visited = 0, limited = false
        while ghostty_render_state_image_iterator_next(iterator) {
            guard visited < limits.placements else { limited = true; break }
            visited += 1
            var proto = GHOSTTY_IMAGE_PROTOCOL_KITTY
            try imageCheck(ghostty_render_state_image_get(iterator, GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL, &proto), "image_protocol")
            guard proto == GHOSTTY_IMAGE_PROTOCOL_KITTY else { limited = true; continue }
            let id: UInt32 = try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID)
            let generation: UInt64 = try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION)
            if images[id] == nil {
                let image: NativeTerminalImage?
                if let cached = cache[id], cached.generation == generation { image = cached }
                else { image = try readImage(graphics: graphics, id: id, generation: generation, budget: limits.bytes - used) }
                guard let image, image.rgba.count <= limits.bytes - used else { limited = true; continue }
                images[id] = image; used += image.rgba.count
            }
            var rawKind = GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_FIXED
            var rawLayer = GHOSTTY_IMAGE_LAYER_ABOVE_TEXT
            try imageCheck(ghostty_render_state_image_get(iterator, GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_KIND, &rawKind), "image_kind")
            try imageCheck(ghostty_render_state_image_get(iterator, GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER, &rawLayer), "image_layer")
            let kind: NativeImagePlacement.Kind
            switch rawKind {
            case GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_FIXED: kind = .fixed
            case GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_VIRTUAL: kind = .virtual
            case GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_RELATIVE: kind = .relative
            default: limited = true; continue
            }
            guard let layer = NativeImagePlacement.Layer(rawValue: Int(rawLayer.rawValue)), let image = images[id] else { limited = true; continue }
            let x: UInt32 = try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X)
            let y: UInt32 = try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y)
            let w: UInt32 = try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH)
            let h: UInt32 = try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT)
            guard w > 0, h > 0, UInt64(x) + UInt64(w) <= image.width,
                  UInt64(y) + UInt64(h) <= image.height else { limited = true; continue }
            let row: Int32 = try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW)
            let col: Int32 = try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL)
            placements.append(.init(imageID: id, imageGeneration: generation,
                placementID: try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_PLACEMENT_ID), kind: kind, layer: layer,
                z: try field(GHOSTTY_RENDER_STATE_IMAGE_DATA_Z), column: Int(col), row: topRow + Int(row),
                columns: try uintField(GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_COLS), rows: try uintField(GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_ROWS),
                offsetX: try uintField(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X), offsetY: try uintField(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y),
                pixelWidth: try uintField(GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH), pixelHeight: try uintField(GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT),
                sourceX: Int(x), sourceY: Int(y), sourceWidth: Int(w), sourceHeight: Int(h)))
        }
        // Preserve VT iterator order for equal z; the public ABI has no stable
        // token/insertion-order field for anonymous placements.
        placements = placements.enumerated().sorted {
            if $0.element.layer != $1.element.layer { return $0.element.layer.rawValue < $1.element.layer.rawValue }
            if $0.element.z != $1.element.z { return $0.element.z < $1.element.z }
            return $0.offset < $1.offset
        }.map(\.element)
        if previous != placements || previousLimited != limited { revision &+= 1 }
        previous = placements; previousLimited = limited; cache = images
        return .init(revision: revision, storageGeneration: storageGeneration, placementGeneration: placementGeneration,
            images: images, placements: placements, limited: limited)
    }

    private func uintField(_ key: GhosttyRenderStateImageData) throws -> Int { let value: UInt32 = try field(key); return Int(value) }
    private func field<T: FixedWidthInteger>(_ key: GhosttyRenderStateImageData) throws -> T {
        var value: T = 0
        try withUnsafeMutablePointer(to: &value) { try imageCheck(ghostty_render_state_image_get(iterator, key, $0), "image_field") }
        return value
    }

    private func readImage(graphics: GhosttyKittyGraphics?, id: UInt32, generation: UInt64, budget: Int) throws -> NativeTerminalImage? {
        guard let handle = ghostty_kitty_graphics_image(graphics, id) else { return nil }
        var width: UInt32 = 0, height: UInt32 = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var pixels = GhosttyString()
        try imageCheck(ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH, &width), "image_width")
        try imageCheck(ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT, &height), "image_height")
        try imageCheck(ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT, &format), "image_format")
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              UInt64(width) * UInt64(height) * 4 <= budget else { return nil }
        let result = ghostty_kitty_graphics_image_get(handle, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &pixels)
        if result == GHOSTTY_NO_VALUE { return nil } // don't negative-cache incomplete pixels
        try imageCheck(result, "image_pixels")
        let components: Int
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB: components = 3
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA: components = 4
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA: components = 2
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY: components = 1
        default: return nil
        }
        let count = Int(width) * Int(height)
        guard pixels.len == count * components, let ptr = pixels.ptr else { return nil }
        let bytes = UnsafeBufferPointer(start: ptr, count: pixels.len)
        if components == 4 {
            return .init(id: id, generation: generation, width: Int(width), height: Int(height), rgba: Array(bytes))
        }
        var rgba = [UInt8](repeating: 255, count: count * 4)
        for pixel in 0..<count {
            let from = pixel * components, to = pixel * 4
            rgba[to] = bytes[from]
            rgba[to + 1] = components == 3 ? bytes[from + 1] : bytes[from]
            rgba[to + 2] = components == 3 ? bytes[from + 2] : bytes[from]
            if components == 2 { rgba[to + 3] = bytes[from + 1] }
        }
        return .init(id: id, generation: generation, width: Int(width), height: Int(height), rgba: rgba)
    }
}

private func imageCheck(_ result: GhosttyResult, _ operation: String) throws {
    if result != GHOSTTY_SUCCESS { throw NativeTerminalError.api(operation, result.rawValue) }
}
