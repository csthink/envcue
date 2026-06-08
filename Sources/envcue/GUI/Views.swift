// GUI views (T5, Liquid Glass shell, design §8).
//
// Material rule (design §8): use system Liquid Glass — `.glassEffect` / GlassEffectContainer
// and `.glass` / `.glassProminent` button styles — and NEVER paint a custom translucent
// background. No hardcoded colors except the semantic diff signs (+/-/~), which are
// foreground accents, not material. The system handles light/dark, refraction, and the
// "reduce transparency" fallback.
//
// The diff preview is shown INLINE inside the menu window (maintainer's call), so the whole
// surface stays a single pane of glass refracting the desktop — no opaque modal sheet.

import SwiftUI
import EnvCueCore

// MARK: - Menu content (hosted by MenuBarExtra .window)

/// The dropdown shown from the menu bar: the scene list, or — when a switch is pending — the
/// inline diff preview (T5.1/T5.2/T5.3). One glass container throughout.
struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().opacity(0.5)
                if let pending = model.pending {
                    DiffPreviewView(model: model, pending: pending)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    sceneList
                        .transition(.opacity)
                }
            }
            .padding(16)
            .frame(width: 340)
            .animation(.easeInOut(duration: 0.18), value: model.pending?.id)
        }
        .onAppear { model.refresh() } // pick up external switches when the menu opens
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Active scene").font(.caption).foregroundStyle(.secondary)
                Text(model.labelText).font(.headline)
            }
            Spacer()
        }
    }

    private var sceneList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.options) { option in
                SceneRow(
                    option: option,
                    isActive: model.isActive(option),
                    action: { model.beginSwitch(to: option) }
                )
            }
        }
    }
}

/// One scene row: a glass button with a leading state glyph and trailing checkmark.
private struct SceneRow: View {
    let option: SceneOption
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: option.name == nil ? "circle.slash" : "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(option.title)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark").font(.callout.weight(.semibold))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .disabled(isActive)
    }
}

// MARK: - Diff preview (pre-switch confirmation, FR-3 / T5.3) — shown inline

/// The change preview shown before a switch is applied. Secrets display their account
/// reference only — never plaintext (invariant #2). Cancel writes nothing to disk.
struct DiffPreviewView: View {
    @Bindable var model: AppModel
    let pending: AppModel.PendingSwitch

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            title
            changeList
            actions
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Switch to \(pending.target.title)").font(.headline)
            Text("\(pending.changes.count) change\(pending.changes.count == 1 ? "" : "s") to this terminal’s environment")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var changeList: some View {
        if pending.changes.isEmpty {
            Text("No environment changes — generation unchanged.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(pending.changes, id: \.name) { change in
                    ChangeRow(change: change)
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.cancel() }
                .buttonStyle(.glass)
            Button("Apply") { model.confirm() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pending.changes.isEmpty)
        }
    }
}

/// A single change line: sign glyph, variable name, masked old→new values, source layer.
private struct ChangeRow: View {
    let change: Change

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: glyph)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.name).font(.callout.weight(.medium).monospaced())
                Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(change.source.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var glyph: String {
        switch change.kind {
        case .added: return "plus"
        case .removed: return "minus"
        case .changed: return "arrow.right"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .added: return .green
        case .removed: return .red
        case .changed: return .orange
        }
    }

    private var detail: String {
        switch change.kind {
        case .added: return change.newDisplay ?? ""
        case .removed: return "was \(change.oldDisplay ?? "")"
        case .changed: return "\(change.oldDisplay ?? "") → \(change.newDisplay ?? "")"
        }
    }
}
