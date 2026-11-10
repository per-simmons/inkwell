import Foundation
import Observation
import SwiftData

/// Who is signed in on this iPad, and which notes are open because of it.
///
/// - Signed out: notes live in the `.device` store and never leave the iPad.
/// - First sign-in: those notes move into the account's own store (nothing is re-downloaded),
///   and a pre-accounts backup made from this iPad is claimed for the account.
/// - Signed in: the account's store opens at launch with no network needed; backup,
///   restore, speaker detection and handoff talk to the server as that account.
/// - Session expired (e.g. offline for weeks): notes stay open and editable; backup pauses
///   until you sign in again.
@MainActor @Observable final class AccountManager {
    static let shared = AccountManager()

    private(set) var user: AuthClient.User?
    private(set) var session: AppSession?
    /// Shown while the store is swapped (a second or two).
    private(set) var switchingMessage: String?
    /// Signed in on this iPad, but the server session is gone; sign in again to resume backup.
    private(set) var needsReauth = false
    /// One-line result of the last sign-in, e.g. "12 notes moved into your account".
    private(set) var lastSignInSummary: String?
    /// An error to show at the app root (the sign-in sheet may be gone by then).
    var alert: String?

    var isSignedIn: Bool { user != nil && !needsReauth }

    private init() {}

    /// Opens the right store at launch. Never touches the network.
    func start() {
        sweepPendingRemovals()
        user = AuthClient.storedUser
        needsReauth = user != nil && !AuthClient.hasSession
        finishInterruptedAdoption()
        if user == nil { recoverOrphanedAccounts() }
        open(user.map { .account($0.id) } ?? .device)
        // Signed in but nothing here (the app was reinstalled — the Keychain outlives it, the
        // store doesn't): bring the account's notes back down in the background.
        if isSignedIn, let ctx = session?.model.context,
           (try? ctx.fetchCount(FetchDescriptor<Note>())) == 0 {
            Task {
                try? await Task.sleep(for: .seconds(1))
                await BackupEngine.shared.restore()
            }
        }
    }

    private func open(_ scope: StorageScope) {
        StorageScope.current = scope
        BackupEngine.shared.reload(for: scope)
        do {
            session = try AppSession(scope: scope)
        } catch {
            fatalError("Could not open the Inkwell store: \(error)")
        }
        BackupEngine.shared.resume()
    }

    /// Old sessions are kept alive for the rest of the process: SwiftUI may still render a
    /// dismissing view that reads a model object, and releasing the container resets its
    /// context, which makes any such read a fatal error. (Small: one per account switch.)
    private var retired: [AppSession] = []

    /// Takes the current store out of use before another is touched.
    private func close() async {
        if let model = session?.model {
            if let editor = model.editor {
                editor.flush()
                editor.playback.pause()
            }
            // Dismiss everything showing this account's notes first.
            model.showSettings = false
            model.closeEditor()
        }
        await BackupEngine.shared.suspend()
        SpeakerDetection.shared.detach()
        BackupEngine.shared.detach()
        try? await Task.sleep(for: .milliseconds(450))   // sheet dismissal animations
        if let session {
            // Frozen: nothing may write through the old context once another store is open.
            try? session.model.context.save()
            session.model.context.autosaveEnabled = false
            retired.append(session)
        }
        session = nil
        try? await Task.sleep(for: .milliseconds(300))
    }

    var canSwitch: Bool { !AudioRecorder.shared.isRecording }

    // MARK: Sign in

    enum SignInError: LocalizedError {
        case recording
        case claim(String)
        case migrate(String)
        var errorDescription: String? {
            switch self {
            case .recording: "Stop the recording before signing in."
            case .claim(let m): "Couldn’t connect this iPad’s existing backup to your account: \(m) Try again."
            case .migrate(let m): "Couldn’t move this iPad’s notes into your account: \(m)"
            }
        }
    }

    /// Called after the emailed code is verified.
    func didSignIn(_ newUser: AuthClient.User) async throws {
        let target = StorageScope.account(newUser.id)
        if session?.scope == target {
            // Same account signing back in after its session expired.
            try await AuthClient.shared.remember(newUser)
            user = newUser
            needsReauth = false
            lastSignInSummary = nil
            BackupEngine.shared.resume()
            Task { await BackupEngine.shared.backUpNow() }
            return
        }
        guard canSwitch else { await AuthClient.shared.forget(); throw SignInError.recording }
        let from = session?.scope ?? .device

        // 1. A backup made before accounts existed (shared token in this iPad's Keychain)
        //    becomes this account's, so the notes already on the server aren't duplicated.
        var claimed = false
        if from == .device, let legacy = Keychain.read(BackupEngine.legacyTokenKey), !legacy.isEmpty {
            switchingMessage = "Connecting your existing backup…"
            do {
                claimed = try await claimLegacyBackup(token: legacy)
                Keychain.write(BackupEngine.legacyTokenKey, "")
            } catch {
                switchingMessage = nil
                await AuthClient.shared.forget()
                throw SignInError.claim(error.localizedDescription)
            }
        }

        // 2. Notes made on this iPad while signed out move into the account.
        switchingMessage = "Moving your notes into your account…"
        await close()
        var moved = StoreMerger.Result(notes: 0, subjects: 0)
        if from == .device {
            // If the app dies mid-move, the next launch finishes it (see finishInterruptedAdoption).
            UserDefaults.standard.set(["uid": newUser.id, "keepManifest": claimed ? "1" : "0"], forKey: Self.adoptionKey)
            do {
                moved = try StoreMerger.adopt(from: .device, into: target, keepManifest: claimed)
            } catch {
                UserDefaults.standard.removeObject(forKey: Self.adoptionKey)
                // Nothing was deleted from the device store; reopen it and report.
                open(.device)
                switchingMessage = nil
                await AuthClient.shared.forget()
                alert = SignInError.migrate(error.localizedDescription).errorDescription
                throw SignInError.migrate(error.localizedDescription)
            }
        }
        try await AuthClient.shared.remember(newUser)
        UserDefaults.standard.removeObject(forKey: Self.adoptionKey)   // only once the account is remembered
        unscheduleRemoval(newUser.id)
        // Reopen the note that was open, now in the account.
        if from == .device, let last = UserDefaults.standard.string(forKey: "lastOpenNote.\(StorageScope.device.id)") {
            UserDefaults.standard.set(last, forKey: "lastOpenNote.\(target.id)")
        }
        user = newUser
        needsReauth = false
        open(target)
        switchingMessage = nil
        lastSignInSummary = moved.notes > 0
            ? "\(moved.notes) note\(moved.notes == 1 ? "" : "s") on this iPad moved into your account."
            : nil

        // 3. Bring down notes this account has elsewhere, then back up what's here.
        Task {
            await BackupEngine.shared.restore()
            await BackupEngine.shared.backUpNow()
        }
    }

    private static let adoptionKey = "accounts.pendingAdoption"

    /// A move of signed-out notes into an account that didn't finish (the app was killed).
    /// Runs before any store opens, so nothing is left stranded in the signed-out store.
    private func finishInterruptedAdoption() {
        guard let pending = UserDefaults.standard.dictionary(forKey: Self.adoptionKey) as? [String: String],
              let uid = pending["uid"] else { return }
        guard let user else { return }   // not remembered yet: the next sign-in finishes the move
        guard uid == user.id else {
            UserDefaults.standard.removeObject(forKey: Self.adoptionKey)
            return
        }
        if (try? StoreMerger.adopt(from: .device, into: .account(uid), keepManifest: pending["keepManifest"] == "1")) != nil {
            UserDefaults.standard.removeObject(forKey: Self.adoptionKey)
        }
    }

    /// Signed out, but a signed-out account's notes are still on this iPad (plain "Sign Out"
    /// keeps them, hidden, under Accounts/<uid>/). That account can't always come back: the
    /// Neon project behind it was deleted on 2026-10-02, and a new project gives the same
    /// email a new user id, so the folder would never be opened again. Move those notes, with
    /// their recordings, drawings, images and PDFs, into the signed-out notebook. Runs before
    /// any store opens. Never touches the network.
    private func recoverOrphanedAccounts() {
        let fm = FileManager.default
        let pending = Set(UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? [])
        guard let uids = try? fm.contentsOfDirectory(atPath: StorageScope.accountsRoot.path) else { return }
        var notes = 0
        for uid in uids where !pending.contains(uid) {
            let scope = StorageScope.account(uid)
            guard fm.fileExists(atPath: scope.storeURL.path) else { continue }
            if let r = try? StoreMerger.adopt(from: scope, into: .device, keepManifest: false) { notes += r.notes }
        }
        if notes > 0 {
            alert = "Recovered \(notes) note\(notes == 1 ? "" : "s") from your earlier account onto this iPad."
        }
    }

    /// POST /api/account/claim-legacy. `false` when there was nothing to claim or it
    /// belongs to another account (the notes then back up fresh).
    private func claimLegacyBackup(token: String) async throws -> Bool {
        guard let url = AppConfig.apiURL else { return false }
        let api = BackupAPI(baseURL: url, token: { refresh in try await AuthClient.shared.accessToken(forceRefresh: refresh) })
        do {
            let resp = try await api.call("POST", "api/account/claim-legacy", body: Data("{}".utf8),
                                          headers: ["X-Inkwell-Legacy-Token": token])
            let counts = resp["claimed"] as? [String: Any] ?? [:]
            return (counts["notes"] as? Int ?? 0) > 0 || (counts["subjects"] as? Int ?? 0) > 0
        } catch let e as BackupAPI.APIError where e.status == 403 || e.status == 409 {
            return false   // not this iPad's to claim / already someone's: back up fresh
        }
    }

    /// The server said the session is gone. Keep the account's notes open; pause backup.
    func sessionExpired() {
        guard user != nil else { return }
        needsReauth = true
    }

    // MARK: Sign out / delete

    /// Notes not yet fully backed up (for the sign-out warning).
    func unbackedNoteCount() -> Int {
        guard let ctx = session?.model.context,
              let notes = try? ctx.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil })) else { return 0 }
        return notes.filter { n in n.lastBackedUpAt.map { !BackupEngine.sameInstant($0, n.modifiedAt) } ?? true }.count
    }

    /// Signs out. The account's notes stay on this iPad (hidden) unless `removeFromDevice`.
    func signOut(removeFromDevice: Bool) async {
        guard canSwitch, let current = session?.scope else { return }
        switchingMessage = "Signing out…"
        await BackupUploader.shared.cancelAll()
        await AuthClient.shared.signOut()
        await close()
        if removeFromDevice, current.accountID != nil { scheduleRemoval(current) }
        user = nil
        needsReauth = false
        lastSignInSummary = nil
        open(.device)
        switchingMessage = nil
        sweepPendingRemovals()
    }

    /// DELETE /api/account, then everything of that account on this iPad.
    func deleteAccount() async throws {
        guard let url = AppConfig.apiURL else { return }
        let api = BackupAPI(baseURL: url, token: { refresh in try await AuthClient.shared.accessToken(forceRefresh: refresh) })
        _ = try await api.call("DELETE", "api/account", body: try BackupAPI.json(["confirm": "delete my account"]))
        guard let current = session?.scope else { return }
        switchingMessage = "Deleting your account…"
        await BackupUploader.shared.cancelAll()
        await AuthClient.shared.forget()
        await close()
        if current.accountID != nil { scheduleRemoval(current) }
        user = nil
        needsReauth = false
        open(.device)
        switchingMessage = nil
        sweepPendingRemovals()
    }

    // An account's folder is deleted only when its store isn't open (now, or next launch).
    private static let pendingKey = "accounts.pendingRemoval"

    private func scheduleRemoval(_ scope: StorageScope) {
        guard let uid = scope.accountID else { return }
        var list = UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
        if !list.contains(uid) { list.append(uid) }
        UserDefaults.standard.set(list, forKey: Self.pendingKey)
        UserDefaults.standard.removeObject(forKey: "backup.lastAt.\(scope.id)")
    }

    private func unscheduleRemoval(_ uid: String) {
        let list = (UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []).filter { $0 != uid }
        UserDefaults.standard.set(list, forKey: Self.pendingKey)
    }

    private func sweepPendingRemovals() {
        let list = UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
        guard !list.isEmpty else { return }
        // Never the account this iPad is signed in to (it may be about to open).
        let keep: Set<String> = [StorageScope.current.accountID, AuthClient.storedUser?.id].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
        let remaining = list.filter { uid in
            guard !keep.contains(uid) else { return true }
            let dir = StorageScope.account(uid).directory
            return FileManager.default.fileExists(atPath: dir.path) && (try? FileManager.default.removeItem(at: dir)) == nil
        }
        UserDefaults.standard.set(remaining, forKey: Self.pendingKey)
    }
}
