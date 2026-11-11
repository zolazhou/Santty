import Foundation

/// Keep unrecognized document fields, including integer revisions/metadata, when editing a known field.
indirect enum HerdrJSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), string(String), integer(Int64), unsigned(UInt64), number(Double)
    case array([HerdrJSONValue]), object([String: HerdrJSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? value.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? value.decode([HerdrJSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: HerdrJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(v): try value.encode(v)
        case let .string(v): try value.encode(v)
        case let .integer(v): try value.encode(v)
        case let .unsigned(v): try value.encode(v)
        case let .number(v): try value.encode(v)
        case let .array(v): try value.encode(v)
        case let .object(v): try value.encode(v)
        }
    }

    subscript(_ key: String) -> HerdrJSONValue? { object?[key] }
    var object: [String: HerdrJSONValue]? { if case let .object(v) = self { return v }; return nil }
    var array: [HerdrJSONValue]? { if case let .array(v) = self { return v }; return nil }
    var string: String? { if case let .string(v) = self { return v }; return nil }
    var double: Double? {
        switch self {
        case let .integer(v): Double(v)
        case let .unsigned(v): Double(v)
        case let .number(v): v
        default: nil
        }
    }
}

/// The machine-owned `herdr-app` document, not Santty's device-local SavedWorkspace.
/// Wire format: herdr-app v0.1.14, src/mirror.rs + src/layout.rs (see the investigation doc).
struct HerdrWorkspaceDocument: Sendable, Equatable {
    static let name = "herdr-app"
    static let maximumBytes = 1024 * 1024
    let value: HerdrJSONValue

    struct Space: Sendable, Equatable {
        let id: String
        let name: String
        let folder: String
        let tabs: [Tab]
    }
    struct Tab: Sendable, Equatable {
        let id: String
        let name: String
        let root: HerdrJSONValue
    }
    enum Edit: Sendable {
        case insertSpace(HerdrJSONValue)
        case renameSpace(id: String, expectedName: String, name: String)
        case renameTab(spaceID: String, id: String, expectedName: String, name: String)
        /// Replace a space's name/folder/tabs. Unknown space-level keys are kept.
        case setSpace(HerdrJSONValue, expectedName: String)
        /// Remove a space from the shared document. It never ends a program.
        case removeSpace(id: String, expectedName: String)
    }

    init(value: HerdrJSONValue = .object(["spaces": .array([])])) throws {
        self.value = value
        _ = try spaces()
        guard try JSONEncoder().encode(value).count <= Self.maximumBytes else {
            throw Self.invalid("Shared workspace exceeds the core document limit")
        }
    }

    func spaces() throws -> [Space] {        guard value.object != nil else { throw Self.invalid("Shared workspace is not an object") }
        guard let raw = (value["spaces"] ?? .array([])).array else { throw Self.invalid("Invalid shared spaces") }
        var spaceIDs = Set<String>(), tabIDs = Set<String>()
        return try raw.map { space in
            let id = try Self.id(space["id"])
            guard spaceIDs.insert(id).inserted else { throw Self.invalid("Duplicate shared space ID") }
            guard let tabs = (space["tabs"] ?? .array([])).array else { throw Self.invalid("Invalid shared tabs") }
            return Space(id: id, name: try Self.text(space["name"]), folder: try Self.text(space["folder"]), tabs: try tabs.map { tab in
                let tabID = try Self.id(tab["id"])
                guard tabIDs.insert(tabID).inserted else { throw Self.invalid("Duplicate shared tab ID") }
                let root = tab["root"] ?? .object(["id": .string(""), "type": .string("row"), "children": .array([])])
                guard root.object != nil else { throw Self.invalid("Invalid shared tab root") }
                return Tab(id: tabID, name: try Self.text(tab["name"]), root: root)
            })
        }
    }

    func space(id: String) throws -> Space? {
        try spaces().first { $0.id == id }
    }

    /// Deliberately no delete/kill or whole-document replacement operation here.
    /// Renames change only the selected name; all other fields/subtrees are preserved.
    func applying(_ edit: Edit) throws -> Self {
        var object = value.object!
        var spaces = (value["spaces"] ?? .array([])).array!
        switch edit {
        case let .insertSpace(space): spaces.append(space)
        case let .renameSpace(id, expectedName, name):
            guard let index = spaces.firstIndex(where: { $0["id"]?.string == id }) else { throw Self.conflict() }
            spaces[index] = try Self.rename(spaces[index], expectedName: expectedName, name: name)
        case let .renameTab(spaceID, id, expectedName, name):
            guard let index = spaces.firstIndex(where: { $0["id"]?.string == spaceID }),
                  var space = spaces[index].object, var tabs = space["tabs"]?.array,
                  let tab = tabs.firstIndex(where: { $0["id"]?.string == id }) else { throw Self.conflict() }
            tabs[tab] = try Self.rename(tabs[tab], expectedName: expectedName, name: name)
            space["tabs"] = .array(tabs)
            spaces[index] = .object(space)
        case let .setSpace(value, expectedName):
            guard let incoming = value.object, let id = incoming["id"]?.string,
                  let index = spaces.firstIndex(where: { $0["id"]?.string == id }),
                  var space = spaces[index].object, try Self.text(space["name"]) == expectedName,
                  incoming["name"]?.string != nil, incoming["folder"]?.string != nil,
                  incoming["tabs"]?.array != nil else { throw Self.conflict() }
            for key in ["name", "folder", "tabs"] { space[key] = incoming[key] }
            spaces[index] = .object(space)
        case let .removeSpace(id, expectedName):
            guard let index = spaces.firstIndex(where: { $0["id"]?.string == id }),
                  try Self.text(spaces[index]["name"]) == expectedName else { throw Self.conflict() }
            spaces.remove(at: index)
        }
        object["spaces"] = .array(spaces)
        return try Self(value: .object(object))
    }

    private static func rename(_ value: HerdrJSONValue, expectedName: String, name: String) throws -> HerdrJSONValue {
        guard var object = value.object, try text(object["name"]) == expectedName else { throw conflict() }
        guard name.utf8.count <= 1024 else { throw invalid("Shared name is too long") }
        object["name"] = .string(name)
        return .object(object)
    }

    private static func id(_ value: HerdrJSONValue?) throws -> String {
        guard let id = value?.string, !id.isEmpty, id.utf8.count <= 128,
              !id.contains("/"), id.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw invalid("Invalid machine-local shared ID")
        }
        return id
    }
    private static func text(_ value: HerdrJSONValue?) throws -> String {
        guard let value else { return "" }
        guard let text = value.string else { throw invalid("Invalid shared text") }
        return text
    }
    static func invalid(_ message: String) -> HerdrCoreError { HerdrCoreError(message, kind: "invalid_workspace") }
    static func conflict() -> HerdrCoreError { HerdrCoreError("The shared workspace changed. Refresh before editing.", kind: "conflict") }
}
