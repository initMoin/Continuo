import SwiftUI

struct HistorySettingsView: View {
    let viewModel: ContinuoViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var syncEnabled: Bool
    @State private var isSwitching = false
    @State private var errorMessage: String?
    @State private var showingDisableConfirmation = false
    @State private var confirmingDisable = false

    init(viewModel: ContinuoViewModel) {
        self.viewModel = viewModel
        _syncEnabled = State(initialValue: viewModel.isHistorySyncEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync history across devices", isOn: $syncEnabled)
                    .disabled(isSwitching)
                    .tint(ContinuoDesign.primaryAction)
                    .onChange(of: syncEnabled) { _, enabled in
                        guard enabled != viewModel.isHistorySyncEnabled else { return }
                        if !enabled, !confirmingDisable {
                            syncEnabled = true
                            showingDisableConfirmation = true
                            return
                        }
                        confirmingDisable = false
                        isSwitching = true
                        errorMessage = nil
                        Task { @MainActor in
                            let destination: HistoryStorageLocation = enabled ? .iCloudDrive : .onThisDevice
                            let failure = await viewModel.switchHistoryStorageLocation(to: destination)
                            await MainActor.run {
                                isSwitching = false
                                if let failure {
                                    syncEnabled = viewModel.isHistorySyncEnabled
                                    errorMessage = failure
                                }
                            }
                        }
                    }
                } footer: {
                    Text("When enabled, stitch history is stored in iCloud Drive and available on your other devices signed in to the same Apple Account. Enable it on each device you want to sync.")
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.historySyncState.systemImage)
                            .foregroundStyle(syncTint)
                        Text(viewModel.historySyncState.title)
                        Spacer()
                        if isSwitching || viewModel.historySyncState == .syncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let lastSyncedAt = viewModel.historyLastSyncedAt,
                       viewModel.historySyncState == .upToDate {
                        Text("Last synced \(lastSyncedAt, style: .relative)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let syncError = viewModel.historySyncError,
                       viewModel.historySyncState == .failed || viewModel.historySyncState == .unavailable {
                        Text(syncError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let progress = viewModel.historyTransferProgress, isSwitching {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                ProgressView(value: progress.fraction)
                                    .progressViewStyle(.linear)
                                Text("\(Int((progress.fraction * 100).rounded()))%")
                                    .font(ContinuoDesign.Typography.metadata())
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.secondary)
                            }
                            Text(progress.message)
                                .font(.subheadline)
                                .contentTransition(.opacity)
                            if let currentFile = progress.currentFile {
                                Text(currentFile)
                                    .font(ContinuoDesign.Typography.metadata())
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if let result = viewModel.historyTransferResult, !isSwitching {
                    Section {
                        Label(result.message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let transferError = viewModel.historyTransferError, !isSwitching {
                    Section {
                        Label(transferError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
#if os(macOS)
            .formStyle(.grouped)
#endif
            .fontDesign(.rounded)
            .navigationTitle("History & Sync")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(isSwitching)
                }
            }
            .alert(
                "Couldn’t change history sync",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Continuo could not move stitch history.")
            }
            .confirmationDialog(
                "Turn off iCloud sync?",
                isPresented: $showingDisableConfirmation,
                titleVisibility: .visible
            ) {
                Button("Turn Off and Move History Locally", role: .destructive) {
                    confirmingDisable = true
                    syncEnabled = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This moves history back to this device and removes the shared iCloud copy from your other devices.")
            }
        }
#if os(macOS)
        .frame(width: 640, height: 560, alignment: .topLeading)
#endif
    }

    private var syncTint: Color {
        switch viewModel.historySyncState {
        case .localOnly:
            .secondary
        case .syncing:
            ContinuoDesign.primaryAction
        case .upToDate:
            ContinuoDesign.logoGreen
        case .unavailable, .failed:
            ContinuoDesign.destructive
        }
    }
}
