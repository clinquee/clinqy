import Accelerate
import Foundation

/// A real retrieval model on the Mac: BAAI/bge-small-en-v1.5 (a 33M-parameter BERT trained for search), run here
/// with Accelerate, no Core ML conversion and no new dependency. On the user's memory it finds the fact a request means
/// far more often than the system's sentence vectors do, which only match wording. One sentence costs a few ms.
///
/// The model (~130 MB) is downloaded once from Hugging Face into Application Support (no user data is sent); until
/// it's there, `Embedder` keeps using the system vectors.
final class TextEncoder: @unchecked Sendable {
    static let modelName = "bge-small-en-v1.5"
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clinqy/models/\(modelName)", isDirectory: true)
    private static let files = ["vocab.txt", "model.safetensors"]

    let dimension = 384
    private let layers = 12, heads = 12, inner = 1536, maxTokens = 512
    private let vocab: [String: Int32]
    /// The weights, read in place from the memory-mapped file (the system can page them out when memory is tight).
    private let file: NSData
    private let weights: [String: UnsafePointer<Float>]
    private let lock = NSLock()

    /// The encoder if its files are on disk (nil otherwise; see `fetch`).
    static func load(from dir: URL = dir) -> TextEncoder? {
        // CLINQY_EMBEDDINGS=system keeps the system vectors (and skips the download).
        guard Config.value("CLINQY_EMBEDDINGS")?.lowercased() != "system" else { return nil }
        guard let vocabText = try? String(contentsOf: dir.appendingPathComponent("vocab.txt"), encoding: .utf8),
              let file = try? NSData(contentsOf: dir.appendingPathComponent("model.safetensors"), options: .alwaysMapped),
              let tensors = safetensors(file) else { return nil }
        var vocab: [String: Int32] = [:]
        for (i, line) in vocabText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            // A repeated token would make ids ambiguous; a vocabulary beyond Int32 can't be indexed.
            guard i <= Int(Int32.max), vocab.updateValue(Int32(i), forKey: String(line)) == nil else { return nil }
        }
        guard validate(tensors: tensors, vocab: vocab) else { return nil }
        return TextEncoder(vocab: vocab, file: file, weights: tensors.mapValues(\.pointer))
    }

    /// Everything `embed` reads must exist with exactly the shape of bge-small (a truncated, renamed or different model
    /// would otherwise crash on a missing tensor or read outside it), and every token id must have an embedding row.
    static func validate(tensors: [String: Tensor], vocab: [String: Int32], hidden d: Int = 384, layers: Int = 12, inner: Int = 1536) -> Bool {
        func has(_ name: String, _ shape: [Int]) -> Bool { tensors[name]?.shape == shape }
        func hasAtLeast(_ name: String, rows minimum: Int, columns: Int) -> Bool {
            guard let shape = tensors[name]?.shape, shape.count == 2 else { return false }
            return shape[0] >= minimum && shape[1] == columns
        }
        guard ["[CLS]", "[SEP]", "[UNK]"].allSatisfy({ vocab[$0] != nil }), let top = vocab.values.max() else { return false }
        guard hasAtLeast("embeddings.word_embeddings.weight", rows: Int(top) + 1, columns: d),
              hasAtLeast("embeddings.position_embeddings.weight", rows: 512, columns: d),
              hasAtLeast("embeddings.token_type_embeddings.weight", rows: 1, columns: d),
              has("embeddings.LayerNorm.weight", [d]), has("embeddings.LayerNorm.bias", [d]) else { return false }
        for l in 0..<layers {
            let p = "encoder.layer.\(l)."
            for part in ["attention.self.query", "attention.self.key", "attention.self.value", "attention.output.dense"] {
                guard has(p + part + ".weight", [d, d]), has(p + part + ".bias", [d]) else { return false }
            }
            guard has(p + "intermediate.dense.weight", [inner, d]), has(p + "intermediate.dense.bias", [inner]),
                  has(p + "output.dense.weight", [d, inner]), has(p + "output.dense.bias", [d]) else { return false }
            for norm in ["attention.output.LayerNorm", "output.LayerNorm"] {
                guard has(p + norm + ".weight", [d]), has(p + norm + ".bias", [d]) else { return false }
            }
        }
        return true
    }

    private init(vocab: [String: Int32], file: NSData, weights: [String: UnsafePointer<Float>]) {
        self.vocab = vocab
        self.file = file
        self.weights = weights
    }

    static var downloaded: Bool { files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) } }

    /// Downloads the model files (once; each lands under its final name only when complete).
    static func fetch() async -> Bool {
        guard Config.value("CLINQY_EMBEDDINGS")?.lowercased() != "system" else { return false }
        if downloaded { return true }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            guard let url = URL(string: "https://huggingface.co/BAAI/\(modelName)/resolve/main/\(name)"),
                  let (tmp, response) = try? await URLSession.shared.download(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            try? FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent(name))
        }
        return downloaded && load() != nil
    }

    // MARK: Safetensors

    struct Tensor {
        let pointer: UnsafePointer<Float>
        let shape: [Int]
    }

    /// Tensor name → its floats and shape inside the file (F32 only; the file stays mapped for the encoder's lifetime).
    /// Nil when the header is malformed or any tensor's byte range doesn't match its shape or lies outside the file.
    static func safetensors(_ data: NSData) -> [String: Tensor]? {
        guard data.length > 8 else { return nil }
        let base = data.bytes
        let raw = UInt64(littleEndian: base.loadUnaligned(as: UInt64.self))
        guard raw > 0, raw <= UInt64(data.length - 8), let n = Int(exactly: raw),
              let header = try? JSONSerialization.jsonObject(with: Data(bytes: base + 8, count: n)) as? [String: Any] else { return nil }
        var out: [String: Tensor] = [:]
        for (name, value) in header where name != "__metadata__" {
            // Other dtypes (bge ships an int64 position_ids) aren't read by the encoder: skipped, and any tensor it does
            // need is checked for by name and shape in `validate`.
            guard let info = value as? [String: Any] else { return nil }
            guard info["dtype"] as? String == "F32" else { continue }
            guard let range = info["data_offsets"] as? [Int], range.count == 2,
                  let shape = info["shape"] as? [Int], shape.allSatisfy({ $0 >= 0 }) else { return nil }
            let (dataStart, o1) = (8 + n).addingReportingOverflow(range[0])
            let (dataEnd, o2) = (8 + n).addingReportingOverflow(range[1])
            guard !o1, !o2, range[0] >= 0, range[0] <= range[1], dataEnd <= data.length, dataStart % MemoryLayout<Float>.alignment == 0 else { return nil }
            var elements = 1
            for dim in shape {
                let (product, overflow) = elements.multipliedReportingOverflow(by: dim)
                guard !overflow else { return nil }
                elements = product
            }
            guard elements.multipliedReportingOverflow(by: MemoryLayout<Float>.size) == (range[1] - range[0], false) else { return nil }
            out[name] = Tensor(pointer: (base + dataStart).assumingMemoryBound(to: Float.self), shape: shape)
        }
        return out
    }

    // MARK: Tokenizing (BERT uncased WordPiece)

    func tokens(_ text: String) -> [Int32] {
        let cls = vocab["[CLS]"] ?? 101, sep = vocab["[SEP]"] ?? 102, unk = vocab["[UNK]"] ?? 100
        var ids: [Int32] = [cls]
        // Lowercase, strip accents, split on spaces and around punctuation.
        let folded = text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .nonspacingMark }
        var words: [String] = [], word = ""
        for scalar in folded {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                if !word.isEmpty { words.append(word); word = "" }
            } else if Self.isPunctuation(scalar) {
                if !word.isEmpty { words.append(word); word = "" }
                words.append(String(scalar))
            } else {
                word.unicodeScalars.append(scalar)
            }
        }
        if !word.isEmpty { words.append(word) }
        for w in words {
            guard ids.count < maxTokens - 1 else { break }
            let chars = Array(w)
            guard chars.count <= 100 else { ids.append(unk); continue }
            var pieces: [Int32] = [], start = 0
            while start < chars.count {
                var end = chars.count, found: Int32?
                while start < end {
                    let piece = (start > 0 ? "##" : "") + String(chars[start..<end])
                    if let id = vocab[piece] { found = id; break }
                    end -= 1
                }
                guard let id = found else { pieces = [unk]; break }
                pieces.append(id)
                start = end
            }
            ids += pieces
        }
        return Array(ids.prefix(maxTokens - 1)) + [sep]
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .otherSymbol, .mathSymbol, .currencySymbol: return true
        default: return false
        }
    }

    // MARK: The model

    /// The sentence's vector (CLS, unit length).
    func embed(_ text: String) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let ids = tokens(text)
        let t = ids.count, d = dimension
        let words = weights["embeddings.word_embeddings.weight"]!, positions = weights["embeddings.position_embeddings.weight"]!
        let types = weights["embeddings.token_type_embeddings.weight"]!
        var x = [Float](repeating: 0, count: t * d)
        for (i, id) in ids.enumerated() {
            for j in 0..<d { x[i * d + j] = words[Int(id) * d + j] + positions[i * d + j] + types[j] }
        }
        layerNorm(&x, rows: t, "embeddings.LayerNorm")
        for l in 0..<layers {
            let p = "encoder.layer.\(l)."
            let q = linear(x, rows: t, p + "attention.self.query", out: d, in: d)
            let k = linear(x, rows: t, p + "attention.self.key", out: d, in: d)
            let v = linear(x, rows: t, p + "attention.self.value", out: d, in: d)
            let context = attention(q, k, v, rows: t)
            var h = linear(context, rows: t, p + "attention.output.dense", out: d, in: d)
            vDSP_vadd(h, 1, x, 1, &h, 1, vDSP_Length(t * d))
            layerNorm(&h, rows: t, p + "attention.output.LayerNorm")
            var mid = linear(h, rows: t, p + "intermediate.dense", out: inner, in: d)
            gelu(&mid)
            var o = linear(mid, rows: t, p + "output.dense", out: d, in: inner)
            vDSP_vadd(o, 1, h, 1, &o, 1, vDSP_Length(t * d))
            layerNorm(&o, rows: t, p + "output.LayerNorm")
            x = o
        }
        var cls = Array(x[0..<d])
        var norm: Float = 0
        vDSP_svesq(cls, 1, &norm, vDSP_Length(d))
        var scale = 1 / max(norm.squareRoot(), 1e-9)
        vDSP_vsmul(cls, 1, &scale, &cls, 1, vDSP_Length(d))
        return cls
    }

    /// y = x·Wᵀ + b, with W stored [out, in].
    private func linear(_ x: [Float], rows: Int, _ name: String, out: Int, in n: Int) -> [Float] {
        let w = weights[name + ".weight"]!, b = weights[name + ".bias"]!
        var y = [Float](repeating: 0, count: rows * out)
        for r in 0..<rows { for j in 0..<out { y[r * out + j] = b[j] } }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(out), Int32(n), 1, x, Int32(n), w, Int32(n), 1, &y, Int32(out))
        return y
    }

    private func attention(_ q: [Float], _ k: [Float], _ v: [Float], rows t: Int) -> [Float] {
        let d = dimension, hd = dimension / heads
        let scale = 1 / Float(hd).squareRoot()
        var out = [Float](repeating: 0, count: t * d)
        var scores = [Float](repeating: 0, count: t * t)
        q.withUnsafeBufferPointer { qp in k.withUnsafeBufferPointer { kp in v.withUnsafeBufferPointer { vp in out.withUnsafeMutableBufferPointer { op in
            for h in 0..<heads {
                let off = h * hd
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(t), Int32(t), Int32(hd), scale,
                            qp.baseAddress! + off, Int32(d), kp.baseAddress! + off, Int32(d), 0, &scores, Int32(t))
                for r in 0..<t {
                    scores.withUnsafeMutableBufferPointer { sp in
                        let row = sp.baseAddress! + r * t
                        var m: Float = 0
                        vDSP_maxv(row, 1, &m, vDSP_Length(t))
                        var neg = -m
                        vDSP_vsadd(row, 1, &neg, row, 1, vDSP_Length(t))
                        var n = Int32(t)
                        vvexpf(row, row, &n)
                        var sum: Float = 0
                        vDSP_sve(row, 1, &sum, vDSP_Length(t))
                        var inv = 1 / sum
                        vDSP_vsmul(row, 1, &inv, row, 1, vDSP_Length(t))
                    }
                }
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(t), Int32(hd), Int32(t), 1,
                            scores, Int32(t), vp.baseAddress! + off, Int32(d), 0, op.baseAddress! + off, Int32(d))
            }
        } } } }
        return out
    }

    private func layerNorm(_ x: inout [Float], rows: Int, _ name: String) {
        let g = weights[name + ".weight"]!, b = weights[name + ".bias"]!
        let d = dimension
        for r in 0..<rows {
            var mean: Float = 0, sd: Float = 0
            x.withUnsafeMutableBufferPointer { p in
                let row = p.baseAddress! + r * d
                vDSP_normalize(row, 1, row, 1, &mean, &sd, vDSP_Length(d))
            }
            // vDSP_normalize divides by the population sd without an epsilon; BERT's eps (1e-12) is negligible.
            for j in 0..<d { x[r * d + j] = x[r * d + j] * g[j] + b[j] }
        }
    }

    private func gelu(_ x: inout [Float]) {
        for i in x.indices { x[i] = 0.5 * x[i] * (1 + erf(x[i] / 1.41421356)) }
    }
}
