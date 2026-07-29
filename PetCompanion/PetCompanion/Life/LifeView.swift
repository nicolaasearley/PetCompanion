import PhotosUI
import SwiftUI
import UIKit

/// LF-01 — Life timeline of milestones. Calm memories, not a social feed.
/// Photos attach after text saves (Scenario H); failed uploads never discard the memory.
struct LifeView: View {
    @Environment(AppModel.self) private var model
    @State private var store: LifeStore?
    @State private var editor: MilestoneEditorDestination?
    @State private var pendingRemove: Milestone?
    @State private var pendingRemovePhoto: MilestoneMedia?
    @State private var promptTitle: String?
    @State private var viewerMedia: MilestoneMedia?

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    timeline(store: store)
                } else {
                    EmptyStateView(
                        systemImage: "photo.on.rectangle.angled",
                        message: "Add a puppy first — then \(model.activePet?.name ?? "their") story can collect milestones and everyday memories here."
                    )
                }
            }
            .background(Color.pc.bg.ignoresSafeArea())
            .navigationTitle("Life")
            .profileEntry()
            .toolbar {
                if store != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Add") {
                            promptTitle = nil
                            editor = .create
                        }
                        .disabled(store?.isSaving == true)
                        .accessibilityLabel("Add a milestone")
                    }
                }
            }
            .task(id: model.activePet?.id) {
                store = model.makeLifeStore()
                await store?.load()
            }
            .sheet(item: $editor) { destination in
                if let store {
                    MilestoneEditorView(
                        store: store,
                        destination: destination,
                        initialTitle: promptTitle
                    )
                }
            }
            .sheet(item: $viewerMedia) { media in
                if let store {
                    MilestonePhotoViewer(store: store, media: media)
                }
            }
            .confirmationDialog(
                "Remove this milestone?",
                isPresented: Binding(
                    get: { pendingRemove != nil },
                    set: { if !$0 { pendingRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let pendingRemove, let store {
                        Task { _ = await store.remove(pendingRemove) }
                    }
                    pendingRemove = nil
                }
                Button("Cancel", role: .cancel) { pendingRemove = nil }
            } message: {
                Text("It leaves the timeline. Household history keeps an audit entry.")
            }
            .confirmationDialog(
                "Remove this photo?",
                isPresented: Binding(
                    get: { pendingRemovePhoto != nil },
                    set: { if !$0 { pendingRemovePhoto = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove photo", role: .destructive) {
                    if let pendingRemovePhoto, let store {
                        Task { _ = await store.removePhoto(pendingRemovePhoto) }
                    }
                    pendingRemovePhoto = nil
                }
                Button("Cancel", role: .cancel) { pendingRemovePhoto = nil }
            } message: {
                Text("The photo leaves this memory. The copy on your device is unchanged.")
            }
        }
    }

    @ViewBuilder
    private func timeline(store: LifeStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                if let message = store.confirmationMessage {
                    LifeOutcomeBanner(message: message, tone: .success) {
                        store.confirmationMessage = nil
                    }
                } else if let message = store.queuedMessage {
                    LifeOutcomeBanner(message: message, tone: .queued) {
                        store.queuedMessage = nil
                    }
                } else if let message = store.errorMessage, editor == nil {
                    LifeOutcomeBanner(message: message, tone: .error) {
                        store.errorMessage = nil
                    }
                }

                if store.isLoading && store.milestones.isEmpty {
                    ProgressView("Loading \(store.petName)'s story…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.xxxl)
                        .accessibilityLabel("Loading milestones")
                } else if store.milestones.isEmpty {
                    EmptyStateView(
                        systemImage: "heart.text.square",
                        message: "\(store.petName)'s story starts with the moments that matter — first day home, a first walk, everyday joys.",
                        primaryActionTitle: "Add a milestone",
                        primaryAction: {
                            promptTitle = nil
                            editor = .create
                        }
                    )
                    promptsSection(store: store)
                } else {
                    ForEach(store.timelineSections) { section in
                        VStack(alignment: .leading, spacing: PCSpacing.md) {
                            SectionHeader(title: section.title)
                            ForEach(section.milestones) { milestone in
                                MilestoneCard(
                                    milestone: milestone,
                                    store: store,
                                    onEdit: { editor = .edit(milestone) },
                                    onRemove: { pendingRemove = milestone },
                                    onViewPhoto: { viewerMedia = $0 },
                                    onRemovePhoto: { pendingRemovePhoto = $0 }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .refreshable { await store.load() }
    }

    private func promptsSection(store: LifeStore) -> some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            SectionHeader(title: "First-year moments")
            Text("Suggestions only — nothing is recorded until you save.")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(LifeMomentPrompt.firstYear) { prompt in
                Button {
                    promptTitle = prompt.title
                    editor = .create
                } label: {
                    HStack(spacing: PCSpacing.md) {
                        Image(systemName: prompt.icon)
                            .foregroundStyle(Color.pc.accent)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text(prompt.title)
                            .font(Font.pc.body)
                            .foregroundStyle(Color.pc.ink)
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.pc.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(PCSpacing.cardPadding)
                    .background(
                        RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                            .fill(Color.pc.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                            .strokeBorder(Color.pc.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add milestone: \(prompt.title)")
                .disabled(store.isSaving)
            }
        }
    }
}

private struct MilestoneCard: View {
    let milestone: Milestone
    let store: LifeStore
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onViewPhoto: (MilestoneMedia) -> Void
    let onRemovePhoto: (MilestoneMedia) -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            if let photo = milestone.media.first(where: { $0.status != .removed }) {
                MilestonePhotoThumb(store: store, media: photo) {
                    if photo.status == .available {
                        onViewPhoto(photo)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(milestone.title)
                    .font(Font.pc.body.weight(.semibold))
                    .foregroundStyle(Color.pc.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: PCSpacing.sm)
                Text(Self.dateFormatter.string(from: milestone.effectiveDate))
                    .font(Font.pc.caption)
                    .foregroundStyle(Color.pc.inkTertiary)
            }
            if let note = milestone.note, !note.isEmpty {
                Text(note)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failed = milestone.media.first(where: { $0.status == .uploadFailed || $0.status == .pendingUpload }) {
                Text(
                    failed.status == .uploadFailed
                        ? "Photo didn’t finish uploading. Edit to retry."
                        : "Photo is still uploading…"
                )
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.attention)
            }
            HStack(spacing: PCSpacing.md) {
                Button("Edit", action: onEdit)
                    .font(Font.pc.secondary)
                Button("Remove", role: .destructive, action: onRemove)
                    .font(Font.pc.secondary)
                if let photo = milestone.media.first(where: { $0.status == .available }) {
                    Button("Remove photo", role: .destructive) { onRemovePhoto(photo) }
                        .font(Font.pc.secondary)
                }
                Spacer()
            }
            .padding(.top, PCSpacing.xs)
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

private struct MilestonePhotoThumb: View {
    let store: LifeStore
    let media: MilestoneMedia
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                    .fill(Color.pc.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous))
                } else if media.status == .available {
                    ProgressView()
                        .accessibilityLabel("Loading photo")
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(Color.pc.inkTertiary)
                        .accessibilityLabel("Photo placeholder")
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(media.status != .available)
        .accessibilityLabel(media.status == .available ? "View milestone photo" : "Milestone photo unavailable")
        .task(id: media.id) {
            guard media.status == .available else { return }
            if let data = await store.loadPhotoData(media) {
                image = UIImage(data: data)
            }
        }
    }
}

private struct MilestonePhotoViewer: View {
    let store: LifeStore
    let media: MilestoneMedia
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.pc.bg.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(PCSpacing.screenMargin)
                        .accessibilityLabel("Milestone photo")
                } else {
                    ProgressView("Loading photo…")
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let data = await store.loadPhotoData(media) {
                    image = UIImage(data: data)
                }
            }
        }
    }
}

enum MilestoneEditorDestination: Identifiable {
    case create
    case edit(Milestone)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let milestone): milestone.id.uuidString
        }
    }
}

struct MilestoneEditorView: View {
    @Bindable var store: LifeStore
    let destination: MilestoneEditorDestination
    var initialTitle: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var validationMessage: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var preparedPhoto: LifePhotoEncoder.PreparedPhoto?
    @State private var photoMessage: String?

    private var editing: Milestone? {
        if case .edit(let milestone) = destination { return milestone }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    PCLabeledField(label: "Title") {
                        TextField("What happened?", text: $title)
                    }
                    .accessibilityLabel("Milestone title")

                    PCLabeledField(label: "Date") {
                        DatePicker(
                            "Date",
                            selection: $effectiveDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    }

                    PCLabeledField(label: "Note (optional)") {
                        TextField("A few words to remember", text: $note, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    photoSection

                    if let message = validationMessage ?? store.errorMessage ?? photoMessage {
                        PCInlineError(message: message)
                    }
                }
                .padding(PCSpacing.screenMargin)
            }
            .background(Color.pc.bg)
            .navigationTitle(editing == nil ? "Add milestone" : "Edit milestone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(store.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Save" : "Update") {
                        Task { await save() }
                    }
                    .disabled(store.isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let editing {
                    title = editing.title
                    effectiveDate = editing.effectiveDate
                    note = editing.note ?? ""
                } else if let initialTitle, title.isEmpty {
                    title = initialTitle
                }
            }
            .interactiveDismissDisabled(store.isSaving)
            .onChange(of: pickerItem) { _, item in
                Task { await loadPickerItem(item) }
            }
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: PCSpacing.sm) {
            Text("Photo (optional)")
                .font(Font.pc.secondary.weight(.medium))
                .foregroundStyle(Color.pc.inkSecondary)

            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous))
                    .accessibilityLabel("Selected photo preview")
            } else if let existing = editing?.media.first(where: { $0.status == .available }) {
                MilestonePhotoThumb(store: store, media: existing, onTap: {})
            }

            HStack(spacing: PCSpacing.md) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Text(preparedPhoto == nil ? "Add photo" : "Change photo")
                        .font(Font.pc.secondary)
                }
                .disabled(store.isSaving)
                .accessibilityLabel("Add a photo to this milestone")

                if preparedPhoto != nil {
                    Button("Clear") {
                        preparedPhoto = nil
                        previewImage = nil
                        pickerItem = nil
                        photoMessage = nil
                    }
                    .font(Font.pc.secondary)
                    .disabled(store.isSaving)
                }
            }

            Text("The memory saves even if the photo upload fails — you can retry later.")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadPickerItem(_ item: PhotosPickerItem?) async {
        photoMessage = nil
        guard let item else { return }
        do {
            guard let imported = try await item.loadTransferable(type: LifePhotoEncoder.ImportedImage.self) else {
                photoMessage = "That photo couldn’t be read. Try another."
                return
            }
            let data = imported.data
            guard let prepared = LifePhotoEncoder.prepare(from: data) else {
                photoMessage = "Photos need to be under 10 MB. Try another."
                return
            }
            preparedPhoto = prepared
            previewImage = UIImage(data: prepared.jpegData)
        } catch {
            // Permission denial / picker cancel keeps the text flow intact.
            photoMessage = "Photo wasn’t added. You can still save the memory as text."
            preparedPhoto = nil
            previewImage = nil
        }
    }

    private func save() async {
        validationMessage = nil
        store.errorMessage = nil
        photoMessage = nil
        var draft = MilestoneDraft(title: title, effectiveDate: effectiveDate, note: note)
        draft.photoJPEGData = preparedPhoto?.jpegData
        draft.photoCaptureTime = preparedPhoto?.captureTime
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "Add a short title."
            return
        }
        let ok: Bool
        if let editing {
            ok = await store.edit(editing, draft: draft)
        } else {
            ok = await store.create(draft)
        }
        if ok { dismiss() }
    }
}

private struct LifeOutcomeBanner: View {
    enum Tone { case success, queued, error }

    let message: String
    let tone: Tone
    let dismiss: () -> Void

    private var color: Color {
        switch tone {
        case .success: Color.pc.success
        case .queued: Color.pc.attention
        case .error: Color.pc.danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: PCSpacing.sm) {
            Text(message)
                .font(Font.pc.secondary)
                .foregroundStyle(Color.pc.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PCSpacing.sm)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pc.inkTertiary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(PCSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PCRadius.card, style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview("Life timeline") {
    LifeView()
        .environment(AppModel.preview())
}
