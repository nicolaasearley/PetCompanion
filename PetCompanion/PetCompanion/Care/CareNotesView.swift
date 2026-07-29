import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// Care notes — CA-01 / US-077.
///
/// General observations and document references with optional household-private
/// image or PDF attachments. Text always saves when upload fails (Scenario H).
/// Never diagnoses or recommends treatment from note text.
struct CareNotesView: View {
    @Bindable var store: CareNoteStore
    @State private var editor: CareNoteEditorDestination?
    @State private var pendingRemove: CareNote?
    @State private var pendingRemoveMedia: CareNoteMedia?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                if let message = store.confirmationMessage {
                    CareOutcomeBanner(message: message, tone: .success) {
                        store.confirmationMessage = nil
                    }
                } else if let message = store.queuedMessage {
                    CareOutcomeBanner(message: message, tone: .queued) {
                        store.queuedMessage = nil
                    }
                } else if let message = store.errorMessage, editor == nil {
                    CareOutcomeBanner(message: message, tone: .error) {
                        store.errorMessage = nil
                    }
                }

                if store.isLoading && store.notes.isEmpty {
                    ProgressView("Loading notes…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.xxxl)
                        .accessibilityLabel("Loading notes")
                } else if store.notes.isEmpty {
                    EmptyStateView(
                        systemImage: "doc.text",
                        message: "No notes yet — add a short observation when something is worth remembering.",
                        primaryActionTitle: "Add a note",
                        primaryAction: { editor = .create }
                    )
                } else {
                    ForEach(store.notes) { note in
                        CareNoteCard(
                            note: note,
                            store: store,
                            calendar: store.calendar,
                            onEdit: { editor = .edit(note) },
                            onRemove: { pendingRemove = note },
                            onRemoveMedia: { pendingRemoveMedia = $0 }
                        )
                    }
                }

                Text("Notes are private household records, not medical advice. They never diagnose or recommend treatment.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add") { editor = .create }
                    .disabled(store.isSaving)
            }
        }
        .refreshable { await store.load() }
        .task { await store.load() }
        .sheet(item: $editor) { destination in
            CareNoteEditorView(store: store, destination: destination)
        }
        .confirmationDialog(
            "Remove this note?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingRemove {
                    Task { _ = await store.remove(pendingRemove) }
                }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("The household history keeps this removal in the audit trail.")
        }
        .confirmationDialog(
            "Remove this attachment?",
            isPresented: Binding(
                get: { pendingRemoveMedia != nil },
                set: { if !$0 { pendingRemoveMedia = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove attachment", role: .destructive) {
                if let pendingRemoveMedia {
                    Task { _ = await store.removeAttachment(pendingRemoveMedia) }
                }
                pendingRemoveMedia = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoveMedia = nil }
        } message: {
            Text("The note stays. The copy on your device is unchanged.")
        }
    }
}

private struct CareNoteCard: View {
    let note: CareNote
    let store: CareNoteStore
    let calendar: Calendar
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onRemoveMedia: (CareNoteMedia) -> Void

    private var cardTitle: String {
        if let title = note.title, !title.isEmpty { return title }
        return note.kind == .document ? "Document" : "Note"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(cardTitle)
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                Spacer()
                if note.kind == .document {
                    PCChip(text: "Doc", style: .neutral)
                }
                PCChip(text: note.provenance.shortBadge, style: .neutral)
            }

            Text(CareCoding.displayDate(note.effectiveDate, calendar: calendar))
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)

            Text(note.body)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let media = note.media.first(where: { $0.status == .available }) {
                CareNoteAttachmentPreview(store: store, media: media)
                Button("Remove attachment", role: .destructive) {
                    onRemoveMedia(media)
                }
                .font(Font.pc.caption)
                .frame(minHeight: PCMetrics.minTouchTarget)
            } else if let failed = note.media.first(where: {
                $0.status == .uploadFailed || $0.status == .pendingUpload
            }) {
                Text("Attachment didn’t upload — edit this note to try again.")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
                    .accessibilityLabel("Attachment upload pending or failed for this note")
                Button("Remove attachment", role: .destructive) {
                    onRemoveMedia(failed)
                }
                .font(Font.pc.caption)
                .frame(minHeight: PCMetrics.minTouchTarget)
            }

            if let recordedBy = note.recordedByName, !recordedBy.isEmpty {
                Text("Recorded by \(recordedBy)")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }

            HStack(spacing: PCSpacing.md) {
                Button("Edit", action: onEdit)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.primary)
                    .frame(minHeight: PCMetrics.minTouchTarget)
                Button("Remove", role: .destructive, action: onRemove)
                    .font(Font.pc.secondary)
                    .frame(minHeight: PCMetrics.minTouchTarget)
                Spacer()
            }
        }
        .padding(PCSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(Color.pc.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct CareNoteAttachmentPreview: View {
    let store: CareNoteStore
    let media: CareNoteMedia
    @State private var image: UIImage?
    @State private var previewItem: CarePDFPreviewItem?
    @State private var loadFailed = false

    private var isPDF: Bool { media.mimeType == "application/pdf" }

    var body: some View {
        Group {
            if isPDF {
                pdfRow
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous))
                    .accessibilityLabel("Attached document photo")
            } else if loadFailed {
                Text("Couldn’t load this attachment.")
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            } else {
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .fill(Color.pc.surfaceSubtle)
                    .frame(height: 140)
                    .overlay(ProgressView().accessibilityLabel("Loading attachment"))
            }
        }
        .task(id: media.id) {
            guard !isPDF else { return }
            guard let data = await store.loadAttachmentData(media) else {
                loadFailed = true
                return
            }
            image = UIImage(data: data)
            if image == nil { loadFailed = true }
        }
        .sheet(item: $previewItem) { item in
            CarePDFQuickLook(url: item.url)
                .ignoresSafeArea()
        }
    }

    private var pdfRow: some View {
        HStack(spacing: PCSpacing.md) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(Color.pc.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("PDF attachment")
                    .font(Font.pc.secondary.weight(.medium))
                    .foregroundStyle(Color.pc.ink)
                Text(byteSizeLabel(media.byteSize))
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }
            Spacer()
            Button("Open") {
                Task {
                    guard let data = await store.loadAttachmentData(media),
                          let url = writeTempPDF(data: data, id: media.id)
                    else {
                        loadFailed = true
                        return
                    }
                    previewItem = CarePDFPreviewItem(url: url)
                }
            }
            .font(Font.pc.secondary)
            .disabled(loadFailed)
            .frame(minHeight: PCMetrics.minTouchTarget)
        }
        .padding(PCSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(Color.pc.surfaceSubtle)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PDF attachment, \(byteSizeLabel(media.byteSize))")
    }
}

/// Kept for editor image thumbs that already reference this name.
private struct CareNotePhotoThumb: View {
    let store: CareNoteStore
    let media: CareNoteMedia

    var body: some View {
        CareNoteAttachmentPreview(store: store, media: media)
    }
}

enum CareNoteEditorDestination: Identifiable {
    case create
    case edit(CareNote)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let note): note.id.uuidString
        }
    }
}

struct CareNoteEditorView: View {
    @Bindable var store: CareNoteStore
    let destination: CareNoteEditorDestination
    @Environment(\.dismiss) private var dismiss

    @State private var draft = CareNoteDraft.blank()
    @State private var validationMessage: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var pendingAttachment: CareNotePendingAttachment?
    @State private var attachmentMessage: String?
    @State private var showPDFImporter = false
    @State private var pdfPreviewItem: CarePDFPreviewItem?

    private var editing: CareNote? {
        if case .edit(let note) = destination { return note }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    if let validationMessage {
                        CareOutcomeBanner(message: validationMessage, tone: .error) {
                            self.validationMessage = nil
                        }
                    } else if let message = store.errorMessage {
                        CareOutcomeBanner(message: message, tone: .error) {
                            store.errorMessage = nil
                        }
                    }

                    if editing == nil {
                        PCLabeledField(label: "Type") {
                            Picker("Type", selection: $draft.kind) {
                                ForEach(CareNoteKind.allCases) { kind in
                                    Text(kind.displayName).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    PCLabeledField(label: draft.kind == .document ? "Title" : "Title (optional)") {
                        TextField(
                            draft.kind == .document ? "Document name" : "Short label",
                            text: $draft.title
                        )
                    }

                    PCLabeledField(label: "Note") {
                        TextField("What happened or what to remember", text: $draft.body, axis: .vertical)
                            .lineLimit(4...12)
                    }

                    PCLabeledField(label: "Date") {
                        DatePicker(
                            "Date",
                            selection: $draft.effectiveDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    }

                    PCLabeledField(label: "Source") {
                        Picker("Source", selection: $draft.provenance) {
                            ForEach(CareNoteProvenance.allCases) { provenance in
                                Text(provenance.displayName).tag(provenance)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    attachmentSection

                    if let attachmentMessage {
                        Text(attachmentMessage)
                            .font(Font.pc.caption)
                            .foregroundStyle(Color.pc.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(PCSpacing.screenMargin)
            }
            .background(Color.pc.bg)
            .navigationTitle(editing == nil ? "Add note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Save" : "Update") {
                        Task { await save() }
                    }
                    .disabled(store.isSaving)
                }
            }
            .onAppear {
                if let editing {
                    draft = CareNoteDraft.from(editing)
                } else {
                    draft = CareNoteDraft.blank()
                }
            }
            .interactiveDismissDisabled(store.isSaving)
            .onChange(of: pickerItem) { _, item in
                Task { await loadPickerItem(item) }
            }
            .onChange(of: draft.kind) { _, kind in
                if kind != .document, pendingAttachment?.isPDF == true {
                    clearPendingAttachment()
                    attachmentMessage = "PDFs are for document notes — switch back to Document to attach one."
                }
            }
            .fileImporter(
                isPresented: $showPDFImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                Task { await loadImportedPDF(result) }
            }
            .sheet(item: $pdfPreviewItem) { item in
                CarePDFQuickLook(url: item.url)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text(draft.kind == .document ? "Attachment (optional)" : "Photo (optional)")
                .font(Font.pc.secondary.weight(.medium))
                .foregroundStyle(Color.pc.inkSecondary)

            if let pendingAttachment {
                pendingAttachmentPreview(pendingAttachment)
            } else if let existing = editing?.media.first(where: { $0.status == .available }) {
                CareNoteAttachmentPreview(store: store, media: existing)
            }

            HStack(spacing: PCSpacing.md) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Text(pendingAttachment == nil ? "Add photo" : "Change photo")
                        .font(Font.pc.secondary)
                }
                .disabled(store.isSaving)
                .accessibilityLabel("Add a photo to this note")

                if draft.kind == .document {
                    Button(pendingAttachment?.isPDF == true ? "Change PDF" : "Add PDF") {
                        showPDFImporter = true
                    }
                    .font(Font.pc.secondary)
                    .disabled(store.isSaving)
                    .accessibilityLabel("Add a PDF document to this note")
                }

                if pendingAttachment != nil {
                    Button("Clear") {
                        clearPendingAttachment()
                    }
                    .font(Font.pc.secondary)
                    .disabled(store.isSaving)
                }
            }

            Text(
                draft.kind == .document
                    ? "Photos or PDFs up to 10 MB. The note saves even if the upload fails — you can retry later."
                    : "Photos up to 10 MB. The note saves even if the photo upload fails — you can retry later."
            )
            .font(Font.pc.caption)
            .foregroundStyle(Color.pc.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func pendingAttachmentPreview(_ attachment: CareNotePendingAttachment) -> some View {
        if attachment.isPDF {
            HStack(spacing: PCSpacing.md) {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(Color.pc.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.displayName ?? "PDF ready to attach")
                        .font(Font.pc.secondary.weight(.medium))
                        .foregroundStyle(Color.pc.ink)
                        .lineLimit(1)
                    Text(byteSizeLabel(attachment.data.count))
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                }
                Spacer()
                Button("Preview") {
                    if let url = writeTempPDF(data: attachment.data, id: UUID()) {
                        pdfPreviewItem = CarePDFPreviewItem(url: url)
                    }
                }
                .font(Font.pc.secondary)
                .frame(minHeight: PCMetrics.minTouchTarget)
            }
            .padding(PCSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .fill(Color.pc.surfaceSubtle)
            )
            .accessibilityLabel("Selected PDF, \(byteSizeLabel(attachment.data.count))")
        } else if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous))
                .accessibilityLabel("Selected photo preview")
        }
    }

    private func clearPendingAttachment() {
        pendingAttachment = nil
        previewImage = nil
        pickerItem = nil
        attachmentMessage = nil
        pdfPreviewItem = nil
    }

    private func loadPickerItem(_ item: PhotosPickerItem?) async {
        attachmentMessage = nil
        guard let item else { return }
        do {
            guard let imported = try await item.loadTransferable(type: LifePhotoEncoder.ImportedImage.self) else {
                attachmentMessage = "That photo couldn’t be read. Try another."
                return
            }
            guard let prepared = LifePhotoEncoder.prepare(from: imported.data) else {
                attachmentMessage = CareNoteAttachmentLimits.honestSizeCopy
                return
            }
            pendingAttachment = CareNotePendingAttachment(
                data: prepared.jpegData,
                mimeType: "image/jpeg",
                captureTime: prepared.captureTime,
                displayName: nil
            )
            previewImage = UIImage(data: prepared.jpegData)
        } catch {
            attachmentMessage = "Photo wasn’t added. You can still save the note as text."
            pendingAttachment = nil
            previewImage = nil
        }
    }

    private func loadImportedPDF(_ result: Result<[URL], Error>) async {
        attachmentMessage = nil
        switch result {
        case .failure:
            attachmentMessage = "PDF wasn’t added. You can still save the note as text."
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                guard data.count > 0 else {
                    attachmentMessage = "That PDF was empty. Try another file."
                    return
                }
                guard data.count <= CareNoteAttachmentLimits.maxBytes else {
                    attachmentMessage = CareNoteAttachmentLimits.honestSizeCopy
                    return
                }
                // Basic PDF magic-byte check so we don't upload arbitrary files.
                let header = data.prefix(5)
                guard header == Data("%PDF-".utf8) else {
                    attachmentMessage = "That file doesn’t look like a PDF. Try another."
                    return
                }
                pendingAttachment = CareNotePendingAttachment(
                    data: data,
                    mimeType: "application/pdf",
                    captureTime: nil,
                    displayName: url.lastPathComponent
                )
                previewImage = nil
                pickerItem = nil
            } catch {
                attachmentMessage = "PDF wasn’t added. You can still save the note as text."
            }
        }
    }

    private func save() async {
        validationMessage = nil
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            validationMessage = "Add a short note before saving."
            return
        }
        if draft.kind == .document {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                validationMessage = "Add a title for this document."
                return
            }
        }
        if let pendingAttachment, pendingAttachment.isPDF, draft.kind != .document {
            validationMessage = "Switch the type to Document to attach a PDF."
            return
        }
        draft.pendingAttachment = pendingAttachment
        let ok: Bool
        if let editing {
            ok = await store.edit(editing, draft: draft)
        } else {
            ok = await store.create(draft)
        }
        if ok { dismiss() }
    }
}

private func byteSizeLabel(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}

private func writeTempPDF(data: Data, id: UUID) -> URL? {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("care-note-\(id.uuidString).pdf")
    do {
        try data.write(to: url, options: .atomic)
        return url
    } catch {
        return nil
    }
}

private struct CarePDFPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
private struct CarePDFQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

#Preview("Care notes") {
    NavigationStack {
        CareNotesView(
            store: CareNoteStore(
                service: InMemoryCareNoteService(),
                petId: UUID(),
                petName: "Maple"
            )
        )
    }
}
