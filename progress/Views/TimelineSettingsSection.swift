import CoreData
import SwiftUI

struct TimelineSettingsSection: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @State private var timelines = TimelineSelectionStore.shared
    @State private var storage = PhotoStorageCoordinator.shared
    @State private var haptics = TimelineSwitchHaptics()
    @Binding var editor: TimelineEditorSheet.Mode?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 20) {
                currentTimeline

                timelineChoices

                if storage.mode.isMigrating {
                    Text("Let the photo storage switch finish before changing timelines.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = timelines.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("timelineSettingsError")
                }
            }
            .padding(.vertical, 6)
            .task {
                haptics.prepare()
                await timelines.refresh(in: context)
            }
            .onChange(of: timelines.selectedID) { _, _ in haptics.play() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { haptics.prepare() }
                else { haptics.cancel() }
            }
            .onDisappear { haptics.cancel() }
        } header: {
            Text("Timelines")
        } footer: {
            if timelines.timelines.count > 1 {
                Text("Each timeline has its own photos and reminders.")
            }
        }
    }

    private var currentTimeline: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.stack.person.crop.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Current timeline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(timelines.selectedName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("currentTimelineName")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if timelines.canRenameTimelines {
                Button("Edit Timeline", systemImage: "pencil") {
                    if let timeline = timelines.timelines.first(where: { $0.id == timelines.selectedID }) {
                        editor = .edit(timeline)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(storage.mode.isMigrating || timelines.isDeleting)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Manage the name and reminders for \(timelines.selectedName)")
                .accessibilityIdentifier("editTimelineButton")
            } else if !timelines.isLoaded {
                ProgressView()
                    .accessibilityLabel("Loading timelines")
            }
        }
    }

    private var timelineChoices: some View {
        TimelineFlowLayout(layoutDirection: layoutDirection) {
                ForEach(timelines.timelines) { timeline in
                    let isSelected = timeline.id == timelines.selectedID
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                            _ = timelines.select(timeline.id)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .accessibilityHidden(true)
                            }
                            Text(timeline.name)
                                .lineLimit(1)
                        }
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(isSelected ? Color.accentColor.opacity(0.2) : .clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(timelines.isDeleting)
                    .accessibilityLabel(timeline.name)
                    .accessibilityValue(isSelected ? "Selected" : "")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityHint(isSelected ? "Current timeline" : "Switch to this timeline")
                    .accessibilityIdentifier("timelineOption-\(timeline.id.uuidString)")
                }

                Button {
                    editor = .create
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!timelines.isLoaded || storage.mode.isMigrating || timelines.isDeleting)
                .accessibilityLabel("New Timeline")
                .accessibilityIdentifier("newTimelineButton")
        }
    }
}
