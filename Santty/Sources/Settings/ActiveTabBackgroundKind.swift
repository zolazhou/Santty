enum ActiveTabBackgroundKind: String, CaseIterable, Identifiable {
    case solid
    case gradient

    var id: Self { self }

    var label: String {
        switch self {
        case .solid:
            "Solid"
        case .gradient:
            "Gradient"
        }
    }
}
