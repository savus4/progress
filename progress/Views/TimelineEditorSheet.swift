import CoreData
import SwiftUI

struct TimelineEditorSheet: View {
    enum Mode: Identifiable {
        case create
        case edit(TimelineSnapshot)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let timeline): timeline.id.uuidString
            }
        }

        var isCreating: Bool {
            if case .create = self { return true }
            return false
        }

        var initialName: String {
            if case .edit(let timeline) = self { return timeline.name }
            return ""
        }
    }

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timelines = TimelineSelectionStore.shared
    @State private var storage = PhotoStorageCoordinator.shared
    @State private var name: String
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showsDeleteConfirmation = false
    @State private var photoCount: Int?
    @StateObject private var importer = PhotoImportCoordinator.shared
    @State private var errorMessage: String?
    @State private var hasAppeared = false
    @FocusState private var isNameFocused: Bool

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        _name = State(initialValue: mode.initialName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if mode.isCreating {
                        introduction
                    } else {
                        timelinePreview
                    }
                    nameCard

                    if case .edit(let timeline) = mode {
                        remindersAction(for: timeline.id)
                        deletionAction
                    } else {
                        timelinePreview
                    }

                    if let errorMessage, errorMessage != validationError?.localizedDescription {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("timelineEditorError")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.secondary.opacity(0.045))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if mode.isCreating { createAction }
            }
            .navigationTitle(mode.isCreating ? "New Timeline" : "Edit Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mode.isCreating {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                            .disabled(isBusy)
                            .accessibilityIdentifier("closeTimelineEditorButton")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: save) {
                            if isSaving {
                                ProgressView()
                            } else {
                                Image(systemName: "xmark")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .disabled(isBusy)
                        .accessibilityLabel("Close")
                        .accessibilityHint("Saves name changes and closes timeline settings.")
                        .accessibilityIdentifier("closeTimelineEditorButton")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isBusy || (!mode.isCreating && hasNameChanges))
        .alert("Delete \(editingName)?", isPresented: $showsDeleteConfirmation) {
            Button("Delete Timeline", role: .destructive, action: deleteTimeline)
                .disabled(!canDelete || isBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
        .onChange(of: timelines.deletedIDs) { _, deletedIDs in
            if case .edit(let timeline) = mode, deletedIDs.contains(timeline.id), !isDeleting { dismiss() }
        }
        .onChange(of: name) { _, _ in errorMessage = nil }
        .task {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0.1)) {
                hasAppeared = true
            }
            isNameFocused = mode.isCreating
            if case .edit(let timeline) = mode {
                let photoContext = context
                photoCount = try? await photoContext.perform {
                    let request = DailyPhoto.fetchRequest()
                    request.predicate = TimelineIdentity.photoPredicate(for: timeline.id)
                    return try photoContext.count(for: request)
                }
            }
        }
    }

    private var introduction: some View {
        VStack(spacing: 18) {
            illustration
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared || reduceMotion ? 0 : 10)

            VStack(spacing: 10) {
                Text("Every story has its own timeline.")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A space for someone’s daily photos, with reminders of their own.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var illustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 90, height: 90)
                .rotationEffect(.degrees(-12))
                .offset(x: -10, y: 1)
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 90, height: 90)
                .rotationEffect(.degrees(7))
                .offset(x: 9, y: 0)
            Image(systemName: "person.crop.square")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
                .frame(width: 86, height: 86)
                .background(.background, in: RoundedRectangle(cornerRadius: 23))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                        .background(.background, in: Circle())
                        .offset(x: 9, y: 8)
                }
        }
        .frame(height: 112)
        .accessibilityHidden(true)
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Timeline name")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if name.count > TimelineStore.maxNameLength - 20 {
                    Text("\(name.count)/\(TimelineStore.maxNameLength)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isNameTooLong ? .red : .secondary)
                        .accessibilityLabel("\(name.count) of \(TimelineStore.maxNameLength) characters")
                }
            }

            TextField("e.g. Alex", text: $name)
                .font(.title3)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isNameFocused)
                .disabled(isBusy)
                .onSubmit(save)
                .accessibilityLabel("Timeline name")
                .accessibilityIdentifier("timelineNameField")

            if let validationError, isDuplicateName || errorMessage == validationError.localizedDescription {
                Text(validationError.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(isDuplicateName ? "duplicateTimelineNameError" : "timelineNameValidationError")
            }

            if !mode.isCreating {
                Text("Name changes are saved when you close.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var timelinePreview: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.person.crop.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(previewName)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(mode.isCreating ? "Daily photos. Their own reminders." : "Manage this timeline’s name and reminders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.isCreating ? "Preview" : "Timeline"): \(previewName)")
    }

    private func remindersAction(for timelineID: UUID) -> some View {
        NavigationLink {
            DailyReminderSettingsView(timelineID: timelineID)
                .id(timelineID)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bell.badge")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Reminders")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Choose times and when to skip them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || timelines.isDeleting)
        .accessibilityIdentifier("timelineRemindersLink")
    }

    private var createAction: some View {
        VStack(spacing: 10) {
            Button(action: save) {
                HStack(spacing: 10) {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isSaving ? "Creating…" : "Create Timeline")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canSave || isBusy || storage.mode.isMigrating || timelines.isDeleting)
            .accessibilityIdentifier("saveTimelineButton")

            Text(storage.mode.isMigrating
                 ? "Let the photo storage switch finish before changing timelines."
                 : "You can change this name later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var previewName: String { trimmedName.isEmpty ? (mode.isCreating ? "Your new timeline" : editingName) : trimmedName }
    private var hasNameChanges: Bool { trimmedName != mode.initialName }
    private var isBusy: Bool { isSaving || isDeleting }
    private var editingName: String {
        if case .edit(let timeline) = mode {
            return timelines.timelines.first { $0.id == timeline.id }?.name ?? timeline.name
        }
        return "Timeline"
    }
    private var canDelete: Bool {
        guard case .edit(let timeline) = mode else { return false }
        return timelines.canDeleteTimeline(timeline.id) && !storage.mode.isMigrating && !importer.isImporting
    }
    private var isNameTooLong: Bool { trimmedName.count > TimelineStore.maxNameLength }
    private var isDuplicateName: Bool {
        let editingID: UUID? = if case .edit(let timeline) = mode { timeline.id } else { nil }
        return !trimmedName.isEmpty && TimelineStore.isNameInUse(trimmedName, among: timelines.timelines, excluding: editingID)
    }
    private var validationError: TimelineNameError? {
        if trimmedName.isEmpty { return .empty }
        if isNameTooLong { return .tooLong }
        if isDuplicateName { return .duplicate }
        return nil
    }
    private var canSave: Bool { validationError == nil }

    private func save() {
        guard !isBusy else { return }
        if !mode.isCreating, !hasNameChanges { dismiss(); return }
        if let validationError {
            errorMessage = validationError.localizedDescription
            isNameFocused = true
            return
        }
        guard !storage.mode.isMigrating, !timelines.isDeleting else {
            errorMessage = "Let the current storage or timeline change finish before saving this name."
            return
        }
        isNameFocused = false
        isSaving = true
        errorMessage = nil
        Task {
            do {
                switch mode {
                case .create:
                    _ = try await timelines.create(name: trimmedName, in: context)
                case .edit(let timeline):
                    try await timelines.rename(id: timeline.id, to: trimmedName, in: context)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private var deletionMessage: String {
        let photos = photoCount.map { "all \($0) of its photos" } ?? "all its photos"
        if storage.isLocalOnly {
            return "This deletes this timeline, \(photos), and its reminders from this device. Other timelines are kept. Any kept iCloud copies are unchanged and return when you enable iCloud Sync again. Deleted reminders do not return. This device deletion cannot be undone."
        }
        return "This permanently deletes this timeline and \(photos) from this device and iCloud, including other synced devices. Its reminders are deleted on this device. Other timelines are kept. If iCloud is unavailable, deletion syncs when it becomes available. This cannot be undone."
    }

    private var deletionAction: some View {
        VStack(spacing: 10) {
            Divider()
                .padding(.bottom, 8)
            Button(role: .destructive) {
                isNameFocused = false
                showsDeleteConfirmation = true
            } label: {
                if isDeleting {
                    ProgressView("Deleting…")
                } else {
                    Label("Delete Timeline", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete || isBusy || timelines.isDeleting)
            .accessibilityIdentifier("deleteTimelineButton")

            Text(timelines.timelines.count <= 1
                 ? "Keep at least one timeline. Create another before deleting this one."
                 : (importer.isImporting ? "Wait for the photo import to finish before deleting a timeline."
                    : "Removes this timeline’s photos and reminders. Your other timelines stay as they are."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deleteTimeline() {
        guard case .edit(let timeline) = mode, canDelete, !isBusy else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await timelines.delete(id: timeline.id, in: context)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isDeleting = false
            }
        }
    }
}
