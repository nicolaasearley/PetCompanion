import SwiftUI

/// CA-09 — Providers. Contact cards only; no medication linkage here.
struct ProvidersView: View {
    @Bindable var store: ProvidersStore
    @State private var editor: ProviderEditorDestination?
    @State private var pendingRemove: CareProvider?

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

                if store.isLoading && store.providers.isEmpty {
                    ProgressView("Loading providers…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PCSpacing.xxxl)
                        .accessibilityLabel("Loading providers")
                } else if store.providers.isEmpty {
                    EmptyStateView(
                        systemImage: "cross.case",
                        message: "No providers yet — add your veterinarian or other care contacts when you’re ready.",
                        primaryActionTitle: "Add a provider",
                        primaryAction: { editor = .create }
                    )
                } else {
                    ForEach(store.providers) { provider in
                        ProviderCard(
                            provider: provider,
                            onEdit: { editor = .edit(provider) },
                            onRemove: { pendingRemove = provider }
                        )
                    }
                }
            }
            .padding(PCSpacing.screenMargin)
            .padding(.bottom, PCSpacing.huge)
        }
        .background(Color.pc.bg)
        .navigationTitle("Providers")
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
            ProviderEditorView(store: store, destination: destination)
        }
        .confirmationDialog(
            "Remove this provider?",
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
            Text("Past records that mention this provider keep their history. The contact won’t appear in the list.")
        }
    }
}

private struct ProviderCard: View {
    let provider: CareProvider
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PCSpacing.md) {
            HStack(alignment: .top, spacing: PCSpacing.md) {
                Image(systemName: provider.kind.systemImage)
                    .foregroundStyle(Color.pc.primary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PCSpacing.xs) {
                    Text(provider.name)
                        .font(Font.pc.body.weight(.semibold))
                        .foregroundStyle(Color.pc.ink)
                    Text(provider.kind.displayName)
                        .font(Font.pc.secondary)
                        .foregroundStyle(Color.pc.inkSecondary)
                }
                Spacer()
            }

            if let phone = provider.phone, !phone.isEmpty {
                if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                    Link(phone, destination: url)
                        .font(Font.pc.body)
                        .foregroundStyle(Color.pc.primary)
                        .frame(minHeight: PCMetrics.minTouchTarget, alignment: .leading)
                        .accessibilityLabel("Call \(provider.name)")
                } else {
                    Text(phone)
                        .font(Font.pc.body)
                        .foregroundStyle(Color.pc.ink)
                }
            }

            if let address = provider.address, !address.isEmpty {
                Text(address)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notes = provider.notes, !notes.isEmpty {
                Text(notes)
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Not referenced by other care records yet.")
                .font(Font.pc.caption)
                .foregroundStyle(Color.pc.inkTertiary)

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

enum ProviderEditorDestination: Identifiable {
    case create
    case edit(CareProvider)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let provider): provider.id.uuidString
        }
    }
}

struct ProviderEditorView: View {
    @Bindable var store: ProvidersStore
    let destination: ProviderEditorDestination
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: ProviderKind = .veterinarian
    @State private var phone = ""
    @State private var address = ""
    @State private var notes = ""
    @State private var validationMessage: String?

    private var editing: CareProvider? {
        if case .edit(let provider) = destination { return provider }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PCSpacing.betweenSections) {
                    PCLabeledField(label: "Name") {
                        TextField("Clinic or contact name", text: $name)
                    }

                    VStack(alignment: .leading, spacing: PCSpacing.sm) {
                        Text("Kind")
                            .font(Font.pc.secondary)
                            .foregroundStyle(Color.pc.inkSecondary)
                        ForEach(ProviderKind.allCases) { option in
                            PCRadioRow(
                                title: option.displayName,
                                isSelected: kind == option
                            ) { kind = option }
                        }
                    }

                    PCLabeledField(label: "Phone (optional)") {
                        TextField("Phone number", text: $phone)
                            .keyboardType(.phonePad)
                    }

                    PCLabeledField(label: "Address (optional)") {
                        TextField("Address", text: $address, axis: .vertical)
                            .lineLimit(2...4)
                    }

                    PCLabeledField(label: "Notes (optional)") {
                        TextField("Notes for your household", text: $notes, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    if let message = validationMessage ?? store.errorMessage {
                        PCInlineError(message: message)
                    }

                    PrimaryButton(title: "Save", action: save)
                        .disabled(store.isSaving)

                    Text("Providers are household contacts — not a referral or medical recommendation.")
                        .font(Font.pc.caption)
                        .foregroundStyle(Color.pc.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PCSpacing.screenMargin)
                .padding(.bottom, PCSpacing.huge)
            }
            .background(Color.pc.bg)
            .navigationTitle(editing == nil ? "Add provider" : "Edit provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.errorMessage = nil
                        dismiss()
                    }
                }
            }
            .onAppear {
                store.errorMessage = nil
                if let editing {
                    name = editing.name
                    kind = editing.kind
                    phone = editing.phone ?? ""
                    address = editing.address ?? ""
                    notes = editing.notes ?? ""
                }
            }
        }
    }

    private func save() {
        validationMessage = nil
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Enter a name."
            return
        }
        let draft = ProviderDraft(
            name: name,
            kind: kind,
            phone: phone,
            address: address,
            notes: notes
        )
        Task {
            let ok: Bool
            if let editing {
                ok = await store.edit(editing, draft: draft)
            } else {
                ok = await store.create(draft)
            }
            if ok { dismiss() }
        }
    }
}
