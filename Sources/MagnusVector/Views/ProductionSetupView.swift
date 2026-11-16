import SwiftUI

struct ProductionSetupView: View {
    @ObservedObject var session: EditorSession
    let project: VectorProject
    @State private var spec: ProductionSpec
    @State private var iccProfile: Data?
    @State private var importingICC = false
    @State private var inches = false
    @State private var profiles = ProductionProfiles.load()
    @State private var message: String?
    @State private var messageIsError = false
    @StateObject private var workflow = ProductionWorkflowStore()
    @Environment(\.dismiss) private var dismiss

    init(session: EditorSession, project: VectorProject) {
        self.session = session; self.project = project
        _spec = State(initialValue: project.production ?? ProductionSpec())
        _iccProfile = State(initialValue: project.productionICCProfile)
    }
    private var valid: Bool { (try? spec.validated()) != nil }
    private var controlsBusy: Bool { workflow.busy || workflow.choosingDestination || importingICC }
    private var validPDF: Bool {
        guard valid, let settings = spec.pdf, (try? settings.validated(requireProfile: true)) != nil,
              let iccProfile else { return false }
        return !iccProfile.isEmpty && iccProfile.count <= ProductionICCProfile.maximumBytes
    }
    private var unit: String { inches ? "in" : "mm" }
    private func length(_ key: WritableKeyPath<ProductionSpec, Double>) -> Binding<Double> {
        Binding(get: { spec[keyPath: key] / (inches ? 25.4 : 1) }, set: { spec[keyPath: key] = $0 * (inches ? 25.4 : 1) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Production Setup", systemImage: "ruler").font(.title2.bold())
                Spacer()
                Text("\(project.shapes.count.formatted()) editable objects").foregroundStyle(.secondary)
            }
            Text("Enter your printer’s actual requirements. Keep your editable artwork and create a separate, physically sized delivery copy.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        jobFields
                        dimensionFields
                        requirementFields
                        profileFields
                        ProductionPDFSettingsView(settings: $spec.pdf, profileData: $iccProfile, importing: $importingICC)
                            .disabled(controlsBusy)
                        ProductionAssistantView(spec: $spec).disabled(controlsBusy)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        ProductionPreviewView(project: project, spec: spec)
                        Text(spec.placement == .fitTrim ? "Fit within trim: preserves the whole artboard and may leave unprinted margins. Bleed is not invented." : "Fill through bleed: uniformly scales and centers the artboard; parts outside the bleed rectangle are cropped in this delivery copy.")
                            .font(.caption).foregroundStyle(.secondary)
                        Label("Editable SVG · separate production PDF", systemImage: "info.circle").font(.caption)
                        Text("Production SVG stays RGB. Production PDF uses the imported printer profile and supported finalizer checks. Roles alone do not create spot-ink plates; supplier proof approval remains separate.")
                            .font(.caption).foregroundStyle(.secondary)
                        if workflow.busy {
                            ProgressView()
                            Text(workflow.stage).font(.callout)
                            Text("\(workflow.completed.formatted()) / \(workflow.total.formatted()) objects prepared").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = workflow.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        if let url = workflow.savedURL {
                            Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle").foregroundStyle(.green)
                            Button("Show in Finder") { workflow.reveal(url) }.help("Reveal the production artwork you exported")
                        }
                        if let result = workflow.result { ProductionReportSummary(result: result, open: workflow.openReport) }
                        if let result = workflow.pdfResult { ProductionPDFReportSummary(result: result, open: workflow.openPDFReport) }
                        if let directory = workflow.pdfArtifacts {
                            Button("Show PDF Artifacts") { workflow.reveal(directory) }.help("Reveal the retained RGB draft, ICC copy, job, object manifest and validation output")
                        }
                    }.frame(width: 300)
                }.padding(.trailing, 8)
            }
            if let message { Text(message).font(.caption).foregroundStyle(messageIsError ? .red : .secondary).textSelection(.enabled) }
            if !valid { Text((try? spec.validated()) == nil ? validationMessage : "").font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(controlsBusy)
                Spacer()
                if workflow.busy { Button("Cancel") { workflow.cancel() }.help("Cancel this copy's export or local check") }
                else {
                    Button("Save Setup") { saveSetup() }.disabled(!valid || controlsBusy).help("Store these requirements and the active ICC profile in the editable project, with undo support")
                    Menu("Export") {
                        Button("Production SVG…") { workflow.export(project: project, spec: spec) }.disabled(!valid)
                        Button("Production PDF…") { if let iccProfile { workflow.exportPDF(project: project, spec: spec, icc: iccProfile) } }.disabled(!validPDF)
                    }.disabled(controlsBusy).help("Export a physically sized editable SVG or a finalized production PDF")
                    Button("Check Locally") { workflow.check(project: project, spec: spec) }.buttonStyle(.borderedProminent).disabled(!valid || controlsBusy)
                        .help("Check a snapshot with bundled PressCheck. No artwork or provider key is uploaded.")
                }
            }
        }.padding(24).frame(width: 900, height: 790)
            .background(PaperTexture.surface).preferredColorScheme(.light).tint(PaperTexture.accent)
            .interactiveDismissDisabled(controlsBusy)
            .onChange(of: spec) { old, next in
                workflow.clearReceipts()
                message = nil
                var priorRequirements = old; priorRequirements.supplierConfirmed = next.supplierConfirmed
                if old.supplierConfirmed, priorRequirements != next { spec.supplierConfirmed = false }
            }
            .onDisappear { workflow.cancel() }
    }
    private var validationMessage: String {
        do { _ = try spec.validated(); return "" } catch { return error.localizedDescription }
    }
    private var jobFields: some View {
        GroupBox("Job") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Job name", text: $spec.name).textFieldStyle(.roundedBorder).help("Name this production job")
                Picker("Workflow", selection: $spec.workflow) {
                    Text("Trading card").tag(ProductionSpec.Workflow.tradingCard)
                    Text("Packaging").tag(ProductionSpec.Workflow.packaging)
                }.help("Choose the rule context; structural packaging still requires an approved dieline")
                Text("Defaults are an unconfirmed example, not supplier specifications.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.disabled(controlsBusy)
    }
    private var dimensionFields: some View {
        GroupBox("Physical size and placement") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Display units", selection: $inches) { Text("Millimeters").tag(false); Text("Inches").tag(true) }.pickerStyle(.segmented)
                    .help("Display dimensions in inches or millimeters; the project stores millimeters")
                HStack { dimension("Trim W", key: \.trimWidthMM); dimension("Trim H", key: \.trimHeightMM) }
                HStack { dimension("Bleed", key: \.bleedMM); dimension("Safe inset", key: \.safeMM) }
                Picker("Artwork placement", selection: $spec.placement) {
                    Text("Fit within trim").tag(ProductionSpec.Placement.fitTrim)
                    Text("Fill through bleed · crop").tag(ProductionSpec.Placement.fillBleed)
                }.help("Both choices preserve the aspect ratio. The original paths and artboard stay unchanged.")
                Picker("Edge intent", selection: $spec.bleedIntent) {
                    Text("Full bleed").tag(ProductionSpec.BleedIntent.fullBleed)
                    Text("Intentional white border").tag(ProductionSpec.BleedIntent.whiteBorder)
                }.help("Tell preflight whether backgrounds must reach the bleed edge")
            }.padding(8)
        }.disabled(controlsBusy)
    }
    private func dimension(_ label: String, key: WritableKeyPath<ProductionSpec, Double>) -> some View {
        ProductionDimensionField(label: label, unit: unit, precision: inches ? 4 : 3, value: length(key))
    }
    private var requirementFields: some View {
        GroupBox("Printer requirements") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Color requirement", selection: $spec.colorPolicy) {
                    Text("Review RGB / not confirmed").tag(ProductionSpec.ColorPolicy.reviewRGB)
                    Text("RGB accepted").tag(ProductionSpec.ColorPolicy.rgb)
                    Text("CMYK required").tag(ProductionSpec.ColorPolicy.cmyk)
                }.help("This records a requirement; it does not perform color conversion")
                ProductionOptionalNumber(label: "Minimum text (pt)", value: $spec.minTextPT)
                ProductionOptionalNumber(label: "Minimum stroke (mm)", value: $spec.minStrokeMM)
                ProductionOptionalNumber(label: "Minimum raster PPI", value: $spec.minRasterPPI)
                Text("Leave unspecified limits blank. Vector paths do not have a raster PPI.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Required production roles") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                        ForEach(ProductionRole.allCases) { role in
                            Toggle(role.title, isOn: Binding(get: { spec.expectedRoles?.contains(role) ?? false }, set: { enabled in
                                var roles = spec.expectedRoles ?? []; roles.removeAll { $0 == role }; if enabled { roles.append(role) }; spec.expectedRoles = roles
                            })).toggleStyle(.checkbox).help("Require a named \(role.title.lowercased()) role in this job")
                        }
                    }.font(.caption)
                }
                Toggle("Requirements confirmed by supplier", isOn: $spec.supplierConfirmed).toggleStyle(.checkbox)
                    .help("Check only after your supplier confirms these requirements. AI proposals cannot confirm them.")
            }.padding(8)
        }.disabled(controlsBusy)
    }
    private var profileFields: some View {
        GroupBox("Custom printer profile") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Profile name", text: optional(\.profileName)).textFieldStyle(.roundedBorder)
                    .help("Name your reusable local printer profile")
                TextField("Specification source / reference", text: optional(\.specSource)).textFieldStyle(.roundedBorder)
                    .help("Record the supplier document, URL or revision used for these settings")
                TextField("Printer notes", text: optional(\.printerNotes), axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                    .help("Record stock, process, revisions and unconfirmed printer requirements")
                HStack {
                    Menu("Load Profile") {
                        ForEach(profiles) { profile in
                            Button(profile.spec.profileName ?? profile.spec.name) { loadProfile(profile) }
                        }
                    }.disabled(profiles.isEmpty).help("Load a saved profile; confirm it with the supplier for this job")
                    Button("Save Profile") { saveProfile() }.disabled(!valid || (spec.profileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Save this named printer profile locally for reuse")
                }
            }.padding(8)
        }.disabled(controlsBusy)
    }
    private func optional(_ key: WritableKeyPath<ProductionSpec, String?>) -> Binding<String> {
        Binding(get: { spec[keyPath: key] ?? "" }, set: { spec[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
    private func saveSetup() {
        do { try session.applyProductionSpec(spec, iccProfile: iccProfile); message = "Production setup saved in this editable project. Save the project to keep it on disk."; messageIsError = false }
        catch { message = error.localizedDescription; messageIsError = true }
    }
    private func saveProfile() {
        do {
            var saved = spec; saved.supplierConfirmed = false
            if let descriptor = saved.pdf?.iccProfile {
                guard let iccProfile else { throw ProductionPDFError.missingProfile }
                try ProductionICCLibrary().save(iccProfile, descriptor: descriptor)
            }
            var updated = profiles
            if let index = updated.firstIndex(where: { $0.spec.profileName == spec.profileName }) { updated[index].spec = saved }
            else { updated.append(ProductionProfile(spec: saved)) }
            try ProductionProfiles.save(updated); profiles = updated
            message = "Custom printer profile saved on this Mac."; messageIsError = false
        } catch { message = error.localizedDescription; messageIsError = true }
    }
    private func loadProfile(_ profile: ProductionProfile) {
        var next = profile.spec; next.supplierConfirmed = false
        if let descriptor = next.pdf?.iccProfile {
            do { iccProfile = try ProductionICCLibrary().load(descriptor) }
            catch { iccProfile = nil }
        } else { iccProfile = nil }
        spec = next
    }
}

private struct ProductionPDFReportSummary: View {
    let result: ProductionPDFResult
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(result.passed ? "PDF · supported checks passed" : "PDF · validation failed").font(.headline)
            Text("This is a report for the generated PDF, not manufacturing approval or independent full ISO certification.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(result.report.findings.prefix(50).enumerated()), id: \.offset) { _, finding in
                Text("\(finding.status.uppercased()) · \(finding.message)").font(.caption).textSelection(.enabled)
            }
            ForEach(result.report.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if result.reportURL != nil { Button("Open PDF Report") { open() } }
        }
    }
}

/// Production actions must see the last typed value even before focus leaves the field.
/// Other editor numeric fields keep their established Return-to-commit behavior.
private struct ProductionDimensionField: View {
    let label: String
    let unit: String
    let precision: Int
    @Binding var value: Double
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text("\(label) (\(unit))").foregroundStyle(.secondary).font(.system(size: 11))
            TextField(label, text: $draft).multilineTextAlignment(.trailing).textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced)).focused($focused)
                .help("Enter \(label.lowercased()) in \(unit). Changes are used immediately; invalid input disables production actions.")
                .onChange(of: draft) { _, next in
                    guard focused else { return }
                    let parsed = Double(next)
                    value = parsed?.isFinite == true ? parsed! : -1
                }
                .onSubmit { focused = false }
        }.padding(.horizontal, 9).padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .onAppear { sync() }
            .onChange(of: value) { _, _ in if !focused { sync() } }
            .onChange(of: focused) { _, active in if !active, Double(draft)?.isFinite == true { sync() } }
    }
    private func sync() { draft = String(format: "%.*f", precision, value) }
}

private struct ProductionOptionalNumber: View {
    let label: String
    @Binding var value: Double?
    @State private var draft = ""
    var body: some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField("Unspecified", text: $draft).frame(width: 105).textFieldStyle(.roundedBorder)
                .onChange(of: draft) { _, next in value = next.isEmpty ? nil : Double(next) ?? -1 }
                .onAppear { sync() }.onChange(of: value) { _, next in if Double(draft) != next { sync() } }
                .help("Leave blank if the supplier has not specified this limit")
        }
    }
    private func sync() { draft = value.map { SVGExporter.number($0) } ?? "" }
}

private struct ProductionReportSummary: View {
    let result: ProductionCheckResult
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Local check · \(result.report.status.replacingOccurrences(of: "_", with: " "))").font(.headline)
            ForEach(Array(result.report.findings.prefix(50).enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(finding.status.uppercased()) · \(finding.ruleID)").font(.caption.bold())
                    Text(finding.message).font(.caption).textSelection(.enabled)
                }
            }
            if result.report.findings.count > 50 {
                Text("Showing the first 50 of \(result.report.findings.count.formatted()) findings. Open the full report for all results.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.report.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if result.reportURL != nil { Button("Open Full Report") { open() }.help("Open the bundled local report in your browser") }
        }
    }
}
