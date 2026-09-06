import IslandCore
import SwiftUI

/// The review is read-only until the user clicks the explicit authorization
/// button. Dismissal and loading never change vendor trust.
struct CodexHookAuthorizationSheet: View {
    let onAuthorized: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.devIslandLanguage) private var language
    @State private var review: CodexHookAuthorizationReview?
    @State private var isWorking = true
    @State private var errorMessage: String?
    @State private var copiedLauncher = false
    private let authorization = CodexHookAuthorization()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Authorize Dev Island hooks", language: language))
                .font(.system(size: 18, weight: .semibold))
            Text(L10n.string(
                "Allow Codex to run these Dev Island commands for task updates and approval requests on this Mac. Each tool request still follows your Codex approval settings.",
                language: language
            ))
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let review {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(review.entries, id: \.eventName) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: entry.eventName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(verbatim: entry.command)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(maxHeight: 280)
                .background(Palette.tourPanel, in: RoundedRectangle(cornerRadius: 8))
            } else if isWorking {
                ProgressView(L10n.string("Reading Dev Island hooks…", language: language))
                    .controlSize(.small)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.stateWaiting)
                Text(CodexTrustGuidance.manualInstructions(language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Button {
                    copiedLauncher = CodexTrustGuidance.copyCLILaunchCommand()
                } label: {
                    Text(L10n.string(
                        copiedLauncher ? "Launch command copied" : "Copy Codex CLI launch command",
                        language: language
                    ))
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel", language: language)) { dismiss() }
                    .disabled(isWorking && review != nil)
                Button(L10n.string(
                    review?.isAlreadyAuthorized == true ? "Done" : "Authorize Dev Island hooks",
                    language: language
                )) {
                    authorizeReviewedHooks()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || review == nil || errorMessage != nil)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Palette.tourCanvas)
        .foregroundStyle(Palette.warmWhite)
        .task {
            let authorization = authorization
            let result = await Task.detached(priority: .userInitiated) {
                Result { try authorization.review() }
            }.value
            switch result {
            case .success(let value): review = value
            case .failure(let error): errorMessage = CodexTrustGuidance.errorMessage(error, language: language)
            }
            isWorking = false
        }
    }

    private func authorizeReviewedHooks() {
        guard let review, !isWorking else { return }
        if review.isAlreadyAuthorized {
            onAuthorized()
            dismiss()
            return
        }
        isWorking = true
        let authorization = authorization
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try authorization.authorize(review) }
            }.value
            isWorking = false
            switch result {
            case .success:
                onAuthorized()
                dismiss()
            case .failure(let error):
                errorMessage = CodexTrustGuidance.errorMessage(error, language: language)
            }
        }
    }
}
