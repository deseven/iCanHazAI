// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// The sheet that blocks the app until it has a provider, a default model and
/// a utility model. Each requirement has a button opening the matching dialog
/// (provider wizard / model picker); closing the dialog returns here. Once
/// everything is set up the sheet fades out and the UI comes back — see
/// `AppViewModel.onboardingActive`.
struct OnboardingView: View {
    @EnvironmentObject var store: AppViewModel
    @State private var window: NSWindow?

    private static let fadeDuration: TimeInterval = 0.5
    /// How long the all-set state stays visible before the fade starts.
    private static let settleDelay: Duration = .milliseconds(800)

    var body: some View {
        let status = store.onboardingStatus
        let firstUnmet = firstUnmetRequirement(status)

        VStack(spacing: 0) {
            header(status)
                .padding(.top, 28)
                .padding(.horizontal, 28)

            VStack(spacing: 10) {
                RequirementRow(
                    icon: "key.horizontal",
                    title: "Provider",
                    detail: providerDetail(status),
                    isMet: status.hasProvider,
                    isEnabled: store.providers.count < Provider.allCases.count,
                    buttonTitle: status.hasProvider ? "Add Another…" : "Add Provider…",
                    isProminent: firstUnmet == .provider,
                    action: { store.presentSheet(.providerWizard) })

                RequirementRow(
                    icon: "text.bubble",
                    title: "Default model",
                    detail: modelDetail(
                        .defaultModel, met: status.hasDefaultModel, canPick: status.canPickModels,
                        hint: "Preselected for every new chat."),
                    isMet: status.hasDefaultModel,
                    isEnabled: status.canPickModels,
                    buttonTitle: status.hasDefaultModel ? "Change…" : "Choose…",
                    isProminent: firstUnmet == .defaultModel,
                    action: { store.pickSettingsModel(.defaultModel) })

                RequirementRow(
                    icon: "bolt",
                    title: "Utility model",
                    detail: modelDetail(
                        .utilityModel, met: status.hasUtilityModel, canPick: status.canPickModels,
                        hint: "Used for background tasks such as naming chats. A fast, cheap model is best."),
                    isMet: status.hasUtilityModel,
                    isEnabled: status.canPickModels,
                    buttonTitle: status.hasUtilityModel ? "Change…" : "Choose…",
                    isProminent: firstUnmet == .utilityModel,
                    action: { store.pickSettingsModel(.utilityModel) })
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 540)
        .animation(.easeInOut(duration: 0.25), value: status)
        .background(
            WindowReader { newWindow in
                newWindow.alphaValue = 1
                window = newWindow
            }
        )
        .interactiveDismissDisabled()
        .task(id: status.isComplete) { await finishWhenComplete() }
    }

    // MARK: - Content

    private enum Requirement { case provider, defaultModel, utilityModel }

    private func firstUnmetRequirement(_ status: OnboardingStatus) -> Requirement? {
        if !status.hasProvider { return .provider }
        if !status.hasDefaultModel { return .defaultModel }
        if !status.hasUtilityModel { return .utilityModel }
        return nil
    }

    private func header(_ status: OnboardingStatus) -> some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.isComplete ? "You're all set" : "Welcome to iCanHazAI")
                    .font(.title2.weight(.semibold))
                Text(
                    status.isComplete
                        ? "Everything is configured."
                        : "Three things are needed before you can start using the app."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func providerDetail(_ status: OnboardingStatus) -> String {
        guard status.hasProvider else { return "Connect to an AI provider with your API key." }
        return store.providers.map(\.provider.displayName).joined(separator: ", ")
    }

    private func modelDetail(_ setting: ModelSetting, met: Bool, canPick: Bool, hint: String) -> String {
        if met { return store.modelLabel(for: store.preferencesModel(for: setting)) }
        return canPick ? hint : "Add a provider first."
    }

    // MARK: - Completion

    private func finishWhenComplete() async {
        guard store.onboardingStatus.isComplete else { return }
        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled, store.onboardingStatus.isComplete else { return }
        await fadeOut()
        if Task.isCancelled || !store.onboardingStatus.isComplete {
            window?.alphaValue = 1
        } else {
            store.finishOnboarding()
        }
    }

    /// SwiftUI can't animate a sheet's removal, so the sheet's own window is
    /// faded; the sheet is dismissed only once it is fully transparent.
    private func fadeOut() async {
        guard let window else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = Self.fadeDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 0
                },
                completionHandler: { continuation.resume() })
        }
    }
}

// MARK: - Requirement row

private struct RequirementRow: View {
    let icon: String
    let title: String
    let detail: String
    let isMet: Bool
    let isEnabled: Bool
    let buttonTitle: String
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isMet ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(isMet ? Color.green : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isProminent {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEnabled)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .disabled(!isEnabled)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isMet ? Color.green.opacity(0.35) : Color.secondary.opacity(0.15))
        )
        .opacity(isEnabled || isMet ? 1 : 0.6)
    }
}

// MARK: - Window access

/// Reports the `NSWindow` hosting the view (the sheet's window), including
/// when it is attached later than the view is created.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
