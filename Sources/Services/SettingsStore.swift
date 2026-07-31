import Foundation

final class SettingsStore {
    private let fileManager: FileManager
    private let stateURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = applicationSupport.appendingPathComponent("DevManagement", isDirectory: true)
        stateURL = directory.appendingPathComponent("state.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> PersistedState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(PersistedState.self, from: data)
        else {
            return .empty
        }
        return state
    }

    func save(_ state: PersistedState) {
        do {
            try fileManager.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("DevManagement could not save state: %@", error.localizedDescription)
        }
    }
}
