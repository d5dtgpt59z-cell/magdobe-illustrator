import XCTest
@testable import MagnusVector

final class ProductionProposalContextTests: XCTestCase {
    private func baseline() -> ProductionProposalContext {
        var spec = ProductionSpec(), pdf = ProductionPDFSettings()
        pdf.iccProfile = ProductionICCDescriptor(sha256: String(repeating: "a", count: 64), name: "Selected printer")
        spec.pdf = pdf
        return ProductionProposalContext(spec: spec, instructions: "Use PDF/X-4.", provider: .codex, model: "")
    }
    func testCurrentProposalCanChangeRequestedSettingsWhileKeepingTheImportedProfile() {
        let context = baseline()
        var next = context.spec; next.pdf?.target = .pdfx4; next.supplierConfirmed = false
        XCTAssertTrue(context.accepts(next, current: context))
    }
    func testChangingPrinterProfileOrDimensionsWhileAwaitingAProposalInvalidatesIt() {
        let context = baseline()
        var changed = context
        changed.spec.pdf?.iccProfile = ProductionICCDescriptor(sha256: String(repeating: "b", count: 64), name: "New printer")
        XCTAssertFalse(context.accepts(context.spec, current: changed))
        changed = context; changed.spec.trimWidthMM = 70
        XCTAssertFalse(context.accepts(context.spec, current: changed))
    }
    func testAProposalCannotReplaceOrRemoveAnImportedProfile() {
        let context = baseline()
        var next = context.spec; next.pdf?.iccProfile?.sha256 = String(repeating: "b", count: 64)
        XCTAssertFalse(context.accepts(next, current: context))
        next = context.spec; next.pdf = nil
        XCTAssertFalse(context.accepts(next, current: context))
    }
    func testChangingTheBriefProviderOrModelInvalidatesTheReviewedSnapshot() {
        let context = baseline()
        var changed = context; changed.instructions = "Use a standard CMYK PDF."
        XCTAssertFalse(context.accepts(context.spec, current: changed))
        changed = context; changed.provider = .openai
        XCTAssertFalse(context.accepts(context.spec, current: changed))
        changed = context; changed.model = "another-text-model"
        XCTAssertFalse(context.accepts(context.spec, current: changed))
    }
}
