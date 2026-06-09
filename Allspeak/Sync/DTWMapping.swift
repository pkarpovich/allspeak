import Foundation

struct DTWMapping: Sendable, Equatable {
    struct Pair: Sendable, Equatable, Codable {
        let enT: Double
        let ruT: Double

        init(enT: Double, ruT: Double) {
            self.enT = enT
            self.ruT = ruT
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            enT = try container.decode(Double.self)
            ruT = try container.decode(Double.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(enT)
            try container.encode(ruT)
        }
    }

    struct Payload: Decodable {
        let film: String
        let version: Int
        let ru_fps: Double
        let en_fps: Double
        let precision_s: Double
        let pairs: [Pair]
    }

    enum LoadError: Error, Equatable {
        case unsupportedVersion(Int)
        case empty
        case notSorted
    }

    let film: String
    let version: Int
    let ruFPS: Double
    let enFPS: Double
    let precisionS: Double
    let pairs: [Pair]

    init(jsonURL: URL) throws {
        try self.init(jsonData: Data(contentsOf: jsonURL))
    }

    init(jsonData: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: jsonData)
        guard payload.version == 1 else { throw LoadError.unsupportedVersion(payload.version) }
        guard !payload.pairs.isEmpty else { throw LoadError.empty }
        var previous = -Double.infinity
        for pair in payload.pairs {
            guard pair.enT >= previous else { throw LoadError.notSorted }
            previous = pair.enT
        }
        film = payload.film
        version = payload.version
        ruFPS = payload.ru_fps
        enFPS = payload.en_fps
        precisionS = payload.precision_s
        pairs = payload.pairs
    }

    func ruTime(forEnTime en: Double) -> Double {
        guard let first = pairs.first, let last = pairs.last else { return en }
        if en <= first.enT { return first.ruT }
        if en >= last.enT { return last.ruT }
        var lo = 0
        var hi = pairs.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if pairs[mid].enT <= en {
                lo = mid
            } else {
                hi = mid
            }
        }
        let leftEn = pairs[lo].enT
        let rightEn = pairs[hi].enT
        let leftRu = pairs[lo].ruT
        let rightRu = pairs[hi].ruT
        let span = rightEn - leftEn
        guard span > 0 else { return leftRu }
        let fraction = (en - leftEn) / span
        return leftRu + fraction * (rightRu - leftRu)
    }
}
