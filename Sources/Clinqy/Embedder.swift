import CryptoKit
import Foundation
import NaturalLanguage

/// On-device sentence vectors, cached by text: from the retrieval model (TextEncoder, bge-small) once it's downloaded,
/// else the system's (NaturalLanguage). One embedding costs ~7–9 ms, so memory facts and saved runs are embedded
/// once, in the background, and kept in Caches across launches; a request then costs a single embedding (its own)
/// instead of one per fact.
final class Embedder: @unchecked Sendable {
    static let shared = Embedder()

    private let model = NLEmbedding.sentenceEmbedding(for: .english)
    /// The retrieval model, once loaded (guarded by `lock`). Its vectors are cached under their own keys.
    private var encoder: TextEncoder?
    private let words = NLEmbedding.wordEmbedding(for: .english)
    /// Guards `cache`, `touched`, `neighbors` and `dirty`.
    private let lock = NSLock()
    /// Serialises use of the NaturalLanguage models.
    private let modelLock = NSLock()
    private var cache: [String: [Float]] = [:]
    /// Keys used this launch: the cache is trimmed to these when it grows too big.
    private var touched: Set<String> = []
    private var neighbors: [String: [String]] = [:]
    private var dirty = false
    private let queue = DispatchQueue(label: "clinqy.embedder", qos: .utility)

    private let url: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vectors.plist")
    }()

    private init() {
        guard let data = try? Data(contentsOf: url),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data] else { return }
        for (key, blob) in saved where blob.count > 0 && blob.count % MemoryLayout<Float>.size == 0 {
            let vector = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            // A damaged cache entry (wrong width for its model, NaN/inf) would poison similarity scores: recompute it instead.
            guard Self.usable(vector, bge: key.hasPrefix("bge:")) else { continue }
            cache[key] = vector
        }
    }

    /// Whether a vector is plausible output of its model: the right width for the retrieval model, every value finite.
    static func usable(_ v: [Float], bge: Bool) -> Bool {
        !v.isEmpty && (!bge || v.count == 384) && v.allSatisfy(\.isFinite) && v.contains { $0 != 0 }
    }

    var available: Bool { model != nil || usesModel }

    /// Vectors come from the retrieval model (similarities run higher than the system vectors': thresholds differ).
    var usesModel: Bool {
        lock.lock(); defer { lock.unlock() }
        return encoder != nil
    }

    /// Loads the retrieval model if its files are there (off the caller's thread when `wait` is false), then embeds
    /// `texts` with it.
    func activate(warming texts: [String] = [], wait: Bool = false) {
        let work = { [self] in
            guard !usesModel, let enc = TextEncoder.load() else { return }
            // Smoke test before trusting the weights: a unit-length, finite, 384-wide vector for a sentence, and different
            // sentences must not collapse to the same vector (garbage or zeroed weights do).
            let a = enc.embed("memory test sentence"), b = enc.embed("an unrelated question about travel")
            guard Self.usable(a, bge: true), Self.usable(b, bge: true), abs(Self.cosine(a, a) - 1) < 1e-2, Self.cosine(a, b) < 0.9999 else { return }
            lock.lock()
            encoder = enc
            lock.unlock()
            for text in texts { _ = vector(text) }
            save()
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// The cache key for a text in the current vector space.
    private func cacheKey(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return (encoder != nil ? "bge:" : "") + Self.key(text)
    }

    static func key(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(normalize(text).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The vector if it's already cached; never computes (safe to call in a loop over many texts).
    func cached(_ text: String) -> [Float]? {
        let k = cacheKey(text)
        lock.lock(); defer { lock.unlock() }
        if let v = cache[k] { touched.insert(k); return v }
        return nil
    }

    /// The vector, computed now if needed (for the one text a request is about).
    func vector(_ text: String) -> [Float]? {
        if let v = cached(text) { return v }
        let k = cacheKey(text)
        lock.lock()
        let enc = encoder
        lock.unlock()
        let v: [Float]
        if let enc {
            v = enc.embed(Self.normalize(text))
            guard Self.usable(v, bge: true) else { return nil }   // never cache or return a broken vector
        } else {
            guard let model else { return nil }
            modelLock.lock()
            let raw = model.vector(for: Self.normalize(text))
            modelLock.unlock()
            guard let raw else { return nil }
            v = raw.map(Float.init)
            guard Self.usable(v, bge: false) else { return nil }
        }
        lock.lock()
        cache[k] = v
        touched.insert(k)
        dirty = true
        lock.unlock()
        return v
    }

    /// Embeds these texts in the background (skipping cached ones), then saves the cache.
    func warm(_ texts: [String]) {
        guard available else { return }
        let missing = texts.filter { cached($0) == nil }
        guard !missing.isEmpty else { return }
        queue.async { [self] in
            for text in missing { _ = vector(text) }
            save()
        }
    }

    /// Embeds these texts now, on the caller's thread (tests, and code already off the main thread).
    func warmNow(_ texts: [String]) {
        for text in texts where cached(text) == nil { _ = vector(text) }
        queue.sync { save() }
    }

    /// Close words for a query word ("eat" → meal, snack, hungry), from the on-device word vectors.
    /// Replaces a hand-written synonym list, so it works for anyone's vocabulary.
    func related(_ word: String, max: Int = 5, within distance: Double = 0.95) -> [String] {
        lock.lock()
        if let hit = neighbors[word] { lock.unlock(); return hit }
        lock.unlock()
        guard let words else { return [] }
        modelLock.lock()
        let found = words.neighbors(for: word, maximumCount: max).filter { $0.1 < distance }.map(\.0)
        modelLock.unlock()
        lock.lock()
        neighbors[word] = found
        lock.unlock()
        return found
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, x: Float = 0, y: Float = 0
        for i in a.indices { dot += a[i] * b[i]; x += a[i] * a[i]; y += b[i] * b[i] }
        return dot / ((x * y).squareRoot() + 1e-9)
    }

    private func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        // Don't grow without bound: past 4000 vectors, keep only the ones used this launch. Once the retrieval model is
        // in use, the system vectors are dead weight.
        if encoder != nil, cache.keys.contains(where: { !$0.hasPrefix("bge:") }) { cache = cache.filter { $0.key.hasPrefix("bge:") } }
        if cache.count > 4000 { cache = cache.filter { touched.contains($0.key) } }
        let snapshot = cache
        lock.unlock()
        let blobs = snapshot.mapValues { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
        // A cache: if it can't be written the vectors are simply recomputed next launch, so keep them marked unsaved.
        if let data = try? PropertyListSerialization.data(fromPropertyList: blobs, format: .binary, options: 0),
           StoreFile.write(data, to: url) == nil { return }
        lock.lock(); dirty = true; lock.unlock()
    }
}
