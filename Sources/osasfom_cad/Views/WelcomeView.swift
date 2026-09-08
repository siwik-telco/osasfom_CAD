import AppKit
import SwiftUI
import osasfom_cadCore

/// The launch window: the logo, the two ways to get started, and the projects
/// you were last working on.
struct WelcomeView: View {
    @ObservedObject var recentProjects: RecentProjects
    let newProject: () -> Void
    let openProject: () -> Void
    let openRecent: (URL) -> Void

    var body: some View {
        HStack(spacing: 0) {
            brandPanel
            Divider()
            recentPanel
        }
        .frame(width: 760, height: 440)
    }

    // MARK: - Left: logo and actions

    private var brandPanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .accessibilityLabel("osasfom_cad")
            } else {
                // The bundle should always carry the logo; if it somehow
                // doesn't, the window still has to be usable.
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 68, weight: .light))
                    .foregroundStyle(.secondary)
            }

            Text("osasfom_cad")
                .font(.system(size: 24, weight: .semibold))
                .padding(.top, 14)

            Text("Parametric FDTD antenna modelling")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                actionButton(
                    title: "New Project",
                    subtitle: "Start from an empty model",
                    systemImage: "plus.square",
                    isProminent: true,
                    action: newProject
                )
                actionButton(
                    title: "Open Project…",
                    subtitle: "Browse for an .osasfomcad file",
                    systemImage: "folder",
                    isProminent: false,
                    action: openProject
                )
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 26)
        }
        .frame(width: 320)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func actionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isProminent ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isProminent ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Right: recent projects

    private var recentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Projects")
                    .font(.headline)
                Spacer()
                if !recentProjects.entries.isEmpty {
                    Menu {
                        Button("Remove Missing Files") { recentProjects.removeMissing() }
                        Button("Clear Menu", role: .destructive) { recentProjects.clear() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if recentProjects.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(recentProjects.entries) { entry in
                            RecentProjectRow(entry: entry) {
                                openRecent(entry.url)
                            } remove: {
                                recentProjects.remove(entry.url)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "clock")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No recent projects")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Projects you open or save will be listed here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    /// The bundled launch logo. `Bundle.module` is the app target's own
    /// resource bundle, which is why the file is copied into
    /// `Sources/osasfom_cad/Resources` rather than read from `Images/`.
    static let logo: NSImage? = {
        guard let url = Bundle.module.url(forResource: "osasfom_ico", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

private struct RecentProjectRow: View {
    let entry: RecentProjects.Entry
    let open: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    private var exists: Bool { entry.stillExists }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: exists ? "doc.text" : "questionmark.folder")
                    .foregroundStyle(exists ? Color.accentColor : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .lineLimit(1)
                        .foregroundStyle(exists ? .primary : .secondary)
                    Text(exists ? entry.location : "Missing — \(entry.location)")
                        .font(.caption)
                        .foregroundStyle(exists ? .secondary : Color.orange)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 4)

                Text(Self.dateText(entry.lastOpened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A missing file can still be clicked; the open attempt reports what
        // went wrong, which is more useful than an inert row.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .help(entry.url.path)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            .disabled(!exists)
            Divider()
            Button("Remove from List", role: .destructive, action: remove)
        }
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
