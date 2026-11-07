// Offline ShazamKit catalog verification (macOS).
// Build:  swiftc -O verify_catalog.swift -o verify_catalog -framework ShazamKit
// Query signatures: shazam signature -i FILM.mp4 --start <sec> --duration 12 -o q.shazamsignature
// Expect MATCH at every probed position; ABS must equal the query --start.
// NO MATCH beyond ~2060s into any single signature = the ~34-min cap, catalog needs chunking
// (build_catalog.py does this by default).

import Foundation
import ShazamKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: verify_catalog <catalog.shazamcatalog> <query.shazamsignature> [more queries...]")
    exit(1)
}

let catalog = SHCustomCatalog()
try catalog.add(from: URL(fileURLWithPath: args[1]))

final class Matcher: NSObject, SHSessionDelegate {
    let sem = DispatchSemaphore(value: 0)
    var outcome = "?"

    func session(_ session: SHSession, didFind match: SHMatch) {
        var parts: [String] = []
        for item in match.mediaItems {
            let off = item.matchOffset
            let sub = item.subtitle ?? ""
            var absStart = 0.0
            if sub.hasPrefix("abs_start="), let v = Double(sub.dropFirst("abs_start=".count)) {
                absStart = v
            }
            parts.append(String(format: "off=%.1f sub=%@ ABS=%.1fs(%.1fmin)", off, sub, absStart + off, (absStart + off) / 60))
        }
        outcome = "MATCH  " + parts.joined(separator: " | ")
        sem.signal()
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
        outcome = error.map { "NO MATCH error=\($0.localizedDescription)" } ?? "NO MATCH"
        sem.signal()
    }
}

for queryPath in args.dropFirst(2) {
    let data = try Data(contentsOf: URL(fileURLWithPath: queryPath))
    let sig = try SHSignature(dataRepresentation: data)
    let matcher = Matcher()
    let session = SHSession(catalog: catalog)
    session.delegate = matcher
    session.match(sig)
    let name = (queryPath as NSString).lastPathComponent
    if matcher.sem.wait(timeout: .now() + 30) == .timedOut {
        print("\(name): TIMEOUT")
    } else {
        print("\(name): \(matcher.outcome)")
    }
}
