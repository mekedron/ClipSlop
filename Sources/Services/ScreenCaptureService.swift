import AppKit
import Vision

enum ScreenCaptureService {
    enum CaptureError: LocalizedError {
        case processLaunchFailed(String)
        case userCancelled
        case noImageData
        case ocrFailed(String)

        var errorDescription: String? {
            switch self {
            case .processLaunchFailed(let msg): "Screenshot failed: \(msg)"
            case .userCancelled: "Screenshot cancelled"
            case .noImageData: "Could not read screenshot image"
            case .ocrFailed(let msg): "Text recognition failed: \(msg)"
            }
        }
    }

    /// Takes a screenshot of a user-selected region and performs OCR
    @MainActor
    static func captureAndRecognize() async throws -> String {
        let image = try await captureScreenRegion()
        let text = try await recognizeText(in: image)
        return text
    }

    // MARK: - Screen Capture

    private static func captureScreenRegion() async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("png")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", tempURL.path] // -i interactive, -x no sound

            process.terminationHandler = { proc in
                defer { try? FileManager.default.removeItem(at: tempURL) }

                guard proc.terminationStatus == 0 else {
                    if !FileManager.default.fileExists(atPath: tempURL.path) {
                        continuation.resume(throwing: CaptureError.userCancelled)
                    } else {
                        continuation.resume(throwing: CaptureError.processLaunchFailed("Exit code \(proc.terminationStatus)"))
                    }
                    return
                }

                guard FileManager.default.fileExists(atPath: tempURL.path) else {
                    continuation.resume(throwing: CaptureError.userCancelled)
                    return
                }

                // Check file has content (user didn't just press escape)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
                      let size = attrs[.size] as? Int, size > 0
                else {
                    continuation.resume(throwing: CaptureError.userCancelled)
                    return
                }

                guard let dataProvider = CGDataProvider(url: tempURL as CFURL),
                      let image = CGImage(
                          pngDataProviderSource: dataProvider,
                          decode: nil,
                          shouldInterpolate: true,
                          intent: .defaultIntent
                      )
                else {
                    continuation.resume(throwing: CaptureError.noImageData)
                    return
                }
                continuation.resume(returning: image)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CaptureError.processLaunchFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - OCR

    private static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: CaptureError.ocrFailed(error.localizedDescription))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(throwing: CaptureError.ocrFailed("No results"))
                    return
                }

                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                if text.isEmpty {
                    continuation.resume(throwing: CaptureError.ocrFailed("No text found in the captured area"))
                } else {
                    continuation.resume(returning: text)
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: CaptureError.ocrFailed(error.localizedDescription))
            }
        }
    }
}
