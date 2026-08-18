import SwiftUI
import PDFKit

struct AIAssistantPanelView: View {
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var appSettings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @StateObject private var vm = AIAssistantViewModel()

    let fileName: String
    let fileContent: String
    let compileLog: String
    let pdfDocument: PDFDocument?
    var onApply: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                if let logo = AppBranding.logo {
                    logo
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220)
                        .opacity(0.05)
                        .allowsHitTesting(false)
                }
                if !aiSettings.isConfigured(aiSettings.activeProvider) {
                    unconfiguredState
                } else {
                    VStack(spacing: 0) {
                        messageList
                        Divider()
                        composer
                    }
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("AI Assistant").font(.headline)
            Spacer()
            Menu(aiSettings.activeProvider.displayName) {
                ForEach(AIProviderKind.allCases) { provider in
                    Button(provider.displayName) { aiSettings.activeProvider = provider }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                vm.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clear conversation")
        }
        .padding(10)
    }

    private var unconfiguredState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "key.slash").font(.system(size: 24)).foregroundStyle(.secondary)
            Text("No API key set for \(aiSettings.activeProvider.displayName).")
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Open AI Settings") { openSettings() }
                .buttonStyle(.borderedProminent)
                .tint(appSettings.color(for: .buttonColor))
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if vm.messages.isEmpty {
                        emptyState
                    }
                    ForEach(vm.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    if vm.isSending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking...").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    }
                    if let error = vm.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about \(fileName), or get help with a compile error.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !aiSettings.promptTasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved tasks — type # to use one:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(aiSettings.promptTasks) { task in
                                Button("#\(task.label)") { vm.inputText = "#\(task.label) " }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            if !compileLog.isEmpty {
                Button("Explain the latest compile error") {
                    Task {
                        await vm.askAboutError(
                            settings: aiSettings, currentFileName: fileName, currentFileContent: fileContent, errorLog: compileLog
                        )
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageBubble(_ message: AIAssistantViewModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : aiSettings.activeProvider.displayName)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(message.content)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
            if let proposed = message.proposedFileContent {
                Button {
                    onApply(proposed)
                } label: {
                    Label("Apply to Editor", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(appSettings.color(for: .buttonColor))
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(message.role == .user ? Color.gray.opacity(0.15) : Color.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a question or request a fix...", text: $vm.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appSettings.color(for: .buttonColor))
            .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSending)
        }
        .padding(10)
    }

    private func sendMessage() {
        Task {
            await vm.send(
                settings: aiSettings, currentFileName: fileName, currentFileContent: fileContent,
                compileLog: compileLog, pdfDocument: pdfDocument
            )
        }
    }
}
