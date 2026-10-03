enum TargetStatusLevel: Equatable {
    case neutral
    case positive
    case warning
    case critical

    var symbolName: String {
        switch self {
        case .neutral: "circle.fill"
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

}
