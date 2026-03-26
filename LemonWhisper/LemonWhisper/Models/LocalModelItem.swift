enum ModelEngine: String {
    case whisper = "Whisper"
    case voxtral = "Voxtral"
}

struct LocalModelItem: Identifiable, Hashable {
    let engine: ModelEngine
    let baseID: String
    let title: String
    let downloadSizeLabel: String
    let expectedPeakMemoryLabel: String
    let description: String

    var id: String { "\(engine.rawValue):\(baseID)" }

    var subtitle: String {
        "\(engine.rawValue) • Download \(downloadSizeLabel) • Peak \(expectedPeakMemoryLabel)"
    }
}
