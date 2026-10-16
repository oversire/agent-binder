/// Collapses concurrent calls with the same key into one execution. Each caller gets its result.
actor SingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private var calls: [Key: Task<Value, Never>] = [:]

    func run(_ key: Key, _ body: @escaping @Sendable () async -> Value) async -> Value {
        if let t = calls[key] { return await t.value }
        let t = Task { await body() }
        calls[key] = t
        let v = await t.value
        calls[key] = nil
        return v
    }
}
