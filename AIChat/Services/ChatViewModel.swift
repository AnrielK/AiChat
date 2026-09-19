import Foundation
import os
import Observation
import PhotosUI
import SwiftData
import SwiftUI

/// Stav hlavní obrazovky: aktuální konverzace, rozepsaná zpráva a běžící generování.
@MainActor
@Observable
final class ChatViewModel {
    var conversation: Conversation?
    var draft = ""
    var errorMessage: String?
    private(set) var errorTitle = "Odpověď se nepodařila"
    /// Přílohy připravené k odeslání s další zprávou.
    private(set) var attachments: [Attachment] = []
    /// Kolik souborů se právě načítá (kopírování, PDF, OCR).
    private(set) var loadingAttachments = 0
    /// Obsazení kontextu otevřené konverzace (po poslední odpovědi, během generování živě).
    private(set) var usage: TokenUsage?
    /// Režim, ve kterém běžela poslední odpověď (pro zobrazení v detailu kontextu).
    private(set) var lastProfile: TaskProfile?
    private(set) var isGenerating = false
    private(set) var streamingMessageID: UUID?

    @ObservationIgnored private var generationTask: Task<Void, Never>?
    /// Hledání v historii chatů. Vytvoří se při první zprávě a pak se drží –
    /// `@ModelActor` si zakládá vlastní `ModelContext`, nemá smysl ho dělat pokaždé znovu.
    @ObservationIgnored private var conversationSearch: ConversationSearch?

    func startNewChat() {
        stop()
        conversation = nil
        usage = nil
        lastProfile = nil
        draft = ""
        discardAttachments()
    }

    /// Rozepsaná zpráva a přílohy – kolik tokenů zhruba přidají.
    var pendingTokens: Int {
        (draft.count + attachments.reduce(0) { $0 + $1.characterCount }) / 3
    }

    /// Režim, ve kterém by teď odpověď běžela – podle nastavení, nebo odhadnutý
    /// z rozepsané zprávy a z kontextu chatu (soubory a režim předchozí odpovědi).
    func profile(settings: SettingsStore) -> TaskProfile {
        if let fixed = settings.local.profileMode.fixedProfile { return fixed }
        return TaskProfile.detect(
            text: draft,
            hasAttachments: !attachments.isEmpty,
            conversationHasDocuments: conversationHasDocuments,
            previous: lastProfile
        )
    }

    /// Pracuje se v tomhle chatu s dokumentem – přílohou nebo dlouhým vloženým textem?
    /// (Navazující dotazy pak zůstávají v režimu dokumentu.)
    private var conversationHasDocuments: Bool {
        conversation?.messages.contains { message in
            message.attachmentsData != nil
                || (message.role == .user && message.text.count >= TaskProfile.longInputCharacters)
        } ?? false
    }

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && loadingAttachments == 0
    }

    // MARK: - Přílohy

    /// `removeAfterLoading`: soubor je dočasná kopie od výběru souborů – po načtení ji smazat.
    func addFiles(_ urls: [URL], removeAfterLoading: Bool = false) {
        for url in urls {
            loadingAttachments += 1
            Task {
                defer {
                    loadingAttachments -= 1
                    if removeAfterLoading { try? FileManager.default.removeItem(at: url) }
                }
                do {
                    let attachment = try await AttachmentLoader.load(fileAt: url)
                    withAnimation(.smooth) { attachments.append(attachment) }
                } catch {
                    showError(error.localizedDescription, title: "Soubor \(url.lastPathComponent) nejde přiložit")
                }
            }
        }
    }

    func addPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            loadingAttachments += 1
            let name = "Fotka \(attachments.count + loadingAttachments).jpg"
            Task {
                defer { loadingAttachments -= 1 }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw AttachmentLoader.LoadError.unreadable("Fotku se nepodařilo načíst z knihovny.")
                    }
                    let attachment = try await AttachmentLoader.load(imageData: data, name: name)
                    withAnimation(.smooth) { attachments.append(attachment) }
                } catch {
                    showError(error.localizedDescription, title: "Fotku nejde přiložit")
                }
            }
        }
    }

    func removeAttachment(_ attachment: Attachment) {
        withAnimation(.smooth) { attachments.removeAll { $0.id == attachment.id } }
        AttachmentStore.remove([attachment])
    }

    /// Neodeslané přílohy smaže i z disku.
    private func discardAttachments() {
        AttachmentStore.remove(attachments)
        attachments = []
    }

    func showError(_ message: String, title: String = "Odpověď se nepodařila") {
        errorTitle = title
        errorMessage = message
    }

    func open(_ conversation: Conversation) {
        stop()
        self.conversation = conversation
        usage = Self.lastUsage(in: conversation)
        // Režim poslední odpovědi – aby navazující dotaz po otevření z historie
        // pokračoval ve stejném režimu, v jakém chat běžel.
        lastProfile = conversation.sortedMessages.last { $0.role == .assistant && $0.profileRaw != nil }?.profile
    }

    /// Poslední uložené obsazení; starší konverzace bez něj dostanou odhad ze znaků.
    private static func lastUsage(in conversation: Conversation) -> TokenUsage? {
        let messages = conversation.sortedMessages
        if let stored = messages.last(where: { $0.role == .assistant && $0.usageData != nil })?.usage {
            return stored
        }
        guard !messages.isEmpty else { return nil }
        let characters = messages.reduce(0) { total, message in
            total + message.text.count + message.attachments.reduce(0) { $0 + $1.characterCount }
        }
        return TokenUsage(promptTokens: characters / 3, outputTokens: 0, isEstimate: true)
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
    }

    /// Nahradí odeslanou zprávu upraveným zněním: původní zpráva i všechno, co po ní
    /// následovalo, se z konverzace smaže a odešle se znovu. Přílohy zůstávají.
    func resend(
        _ message: ChatMessage,
        text: String,
        context: ModelContext,
        settings: SettingsStore,
        models: ModelManager
    ) {
        guard let conversation, !isGenerating else { return }
        let ordered = conversation.sortedMessages
        guard let index = ordered.firstIndex(where: { $0.id == message.id }) else { return }

        let files = message.attachments
        for old in ordered[index...] {
            conversation.messages.removeAll { $0.id == old.id }
            context.delete(old)
        }
        draft = text
        attachments = files
        send(context: context, settings: settings, models: models)
    }

    func send(context: ModelContext, settings: SettingsStore, models: ModelManager) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard canSend, !isGenerating else { return }

        // Režim se určí z odesílané zprávy (přílohy + klíčová slova), než se draft vyprázdní.
        let profile = self.profile(settings: settings)
        lastProfile = profile
        // Podle čeho se rozhodlo o režimu (a tedy i o přemýšlení) – v Konzoli
        // `subsystem:cz.aichat category:chat`, vedle řádku z enginu.
        Logger(subsystem: "cz.aichat", category: "chat")
            .info("režim \(profile.rawValue) · příloh \(files.count)")

        let provider: any ChatProvider
        do {
            let base = try settings.makeProvider(models: models, profile: profile)

            // Hledání v historii běží nad vlastním kontextem stejného kontejneru,
            // takže nesahá na ten, se kterým pracuje UI.
            let search = conversationSearch ?? ConversationSearch(modelContainer: context.container)
            conversationSearch = search
            let excluded = conversation?.id
            let lookup: HistoryLookup = { query in
                await search.excerpts(for: query, excluding: excluded)
            }

            // Dlouhá příloha ke shrnutí se na lokálním modelu zpracuje po částech,
            // dotaz do dlouhé přílohy se místo ořezání vyhledá.
            // Pořadí: shrnutí celé přílohy, pak agentní smyčka (když je zapnutá),
            // pak pevná pipeline. Agent se ptá sám, takže pevné hledání nepotřebuje.
            provider = SummaryPipeline.wrapping(
                base, settings: settings, models: models, attachments: files, profile: profile
            ) ?? AgentPipeline.wrapping(
                base, settings: settings, profile: profile
            ) ?? RetrievalPipeline.wrapping(
                base, settings: settings, profile: profile, historySearch: lookup
            ) ?? base
        } catch {
            showError(error.localizedDescription)
            return
        }

        let conversation: Conversation
        if let existing = self.conversation {
            conversation = existing
        } else {
            conversation = Conversation(provider: settings.provider, modelName: settings.activeModelLabel)
            context.insert(conversation)
            self.conversation = conversation
        }
        if conversation.messages.isEmpty {
            conversation.title = Self.title(from: text.isEmpty ? files.map(\.name).joined(separator: ", ") : text)
        }
        conversation.providerRaw = settings.provider.rawValue
        conversation.modelName = settings.activeModelLabel
        conversation.updatedAt = .now

        let userMessage = ChatMessage(role: .user, text: text)
        userMessage.attachments = files
        context.insert(userMessage)
        conversation.messages.append(userMessage)

        let history = ChatTurn.normalized(conversation.sortedMessages.map(\.turn))

        let reply = ChatMessage(role: .assistant, text: "")
        reply.profile = profile
        context.insert(reply)
        conversation.messages.append(reply)

        draft = ""
        attachments = []
        isGenerating = true
        streamingMessageID = reply.id

        // Uložit hned: když iOS appku během odpovědi ukončí (paměť, odchod na pozadí),
        // konverzace i otázka zůstanou. Dřív se ukládalo až po dokončení odpovědi.
        try? context.save()

        generationTask = Task { [weak self] in
            var lastSave = Date.now
            do {
                for try await event in provider.stream(history) {
                    // Rozepsanou odpověď průběžně ukládat (nejvýš jednou za 3 s).
                    if Date.now.timeIntervalSince(lastSave) > 3 {
                        try? context.save()
                        lastSave = .now
                    }
                    switch event {
                    case .text(let text):
                        reply.text += text
                    case .reasoning(let text):
                        reply.reasoning += text
                    case .status(let text):
                        reply.status += text
                    case .promoteTextToReasoning:
                        reply.reasoning += reply.text
                        reply.text = ""
                    case .usage(let value):
                        reply.usage = value
                        self?.usage = value
                    case .sources(let value):
                        reply.sources = value
                    }
                }
            } catch is CancellationError {
                // Uživatel zastavil generování – rozepsaný text necháme.
            } catch {
                self?.showError(error.localizedDescription)
            }

            if reply.text.isEmpty && reply.reasoning.isEmpty {
                context.delete(reply)
            } else {
                // Stejný začátek, jaký během generování odpočítává `RunningTimeLabel`,
                // takže se zobrazený čas po dokončení neposkočí.
                reply.generationSeconds = Date.now.timeIntervalSince(reply.createdAt)
            }
            conversation.updatedAt = .now
            try? context.save()
            self?.isGenerating = false
            self?.streamingMessageID = nil
        }
    }

    private static func title(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 48 ? String(firstLine.prefix(47)) + "…" : firstLine
    }
}
