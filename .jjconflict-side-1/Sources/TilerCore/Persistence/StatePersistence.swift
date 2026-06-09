import Foundation

class StatePersistence {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("tiler")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("state.json")
    }

    func save(_ state: TilerState) {
        let persisted = PersistedState.from(state)
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            tiler_log("State save failed: \(error)")
        }
    }

    func load() -> PersistedState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let persisted = try JSONDecoder().decode(PersistedState.self, from: data)
            guard persisted.version == 1 else {
                tiler_log("Ignoring persisted state with unknown version \(persisted.version)")
                return nil
            }
            return persisted
        } catch {
            tiler_log("State load failed: \(error)")
            return nil
        }
    }
}
