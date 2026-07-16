import Foundation

/// Swift view onto the C constants in FingerprintParams.h — the single iOS
/// source of truth (imported via the bridging header). Those values are
/// asserted against fingerprint/fpcore/constants.py (Python) via the checked-in
/// tests/fixtures/params.json and FingerprintConstantsParityTests, so any
/// Python↔iOS drift fails CI instead of silently breaking parity.
enum FingerprintConstants {
    static let fpVersion = Int(kFPVersion)
    static let canonW = Int(kFPCanonW)
    static let canonH = Int(kFPCanonH)
    static let codebookK = Int(kFPCodebookK)
    static let globalVecDim = Int(kFPCodebookK)

    /// sha256 of the shipped fpcore/codebook.bin; the FingerprintUpdater codebookHash
    /// gate and the bundled-codebook integrity test both compare against this.
    static let codebookSHA256 = "29f6036053e9ace2129430c317a22291b488266c8de32ff811394c42f31ce131"

    struct ORBParams {
        let nfeatures = Int(kFPOrbNfeatures)
        let scaleFactor = Double(kFPOrbScaleFactor)
        let nlevels = Int(kFPOrbNlevels)
        let edgeThreshold = Int(kFPOrbEdgeThreshold)
        let firstLevel = Int(kFPOrbFirstLevel)
        let wtaK = Int(kFPOrbWtaK)
        let patchSize = Int(kFPOrbPatchSize)
        let fastThreshold = Int(kFPOrbFastThreshold)
    }
    static let orb = ORBParams()
}
