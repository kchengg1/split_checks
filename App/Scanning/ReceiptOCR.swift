import UIKit
import Vision
import SplitChecksCore

/// On-device text recognition. Wraps Vision's `VNRecognizeTextRequest` and
/// maps its observations into the parser's platform-neutral `TextObservation`.
enum ReceiptOCR {

    enum OCRError: Error {
        case notAnImage
    }

    /// Recognizes text in one receipt photo. Synchronous and CPU-bound —
    /// call it off the main actor (see `recognize(pages:)`).
    static func recognize(in image: UIImage) throws -> [TextObservation] {
        guard let cgImage = image.cgImage else { throw OCRError.notAnImage }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction "fixes" prices and dish names into English
        // words; receipts are better served raw.
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation)
        )
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextObservation(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                x: box.origin.x,
                y: box.origin.y,
                width: box.width,
                height: box.height
            )
        }
    }

    /// OCRs every page and merges the parses: items accumulate, totals take
    /// the last value seen (multi-page receipts print totals on the last page).
    static func recognizeAndParse(pages: [UIImage]) async throws -> ParsedReceipt {
        try await Task.detached(priority: .userInitiated) {
            var merged = ParsedReceipt(merchantName: nil, items: [], subtotalCents: nil,
                                       taxCents: nil, tipCents: nil, totalCents: nil)
            for page in pages {
                let parsed = ReceiptParser.parse(try recognize(in: page))
                merged.items.append(contentsOf: parsed.items)
                merged.merchantName = merged.merchantName ?? parsed.merchantName
                merged.subtotalCents = parsed.subtotalCents ?? merged.subtotalCents
                merged.taxCents = parsed.taxCents ?? merged.taxCents
                merged.tipCents = parsed.tipCents ?? merged.tipCents
                merged.totalCents = parsed.totalCents ?? merged.totalCents
            }
            return merged
        }.value
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
