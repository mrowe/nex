import Darwin
import Foundation
import os
import Security
import UserNotifications

/// Keeps the globally installed `nex` CLI and bundled `nex-agentic` skill in
/// sync with the currently running app bundle. Runs once per process off the
/// main thread and is always best-effort: failures are logged but never
/// surface as errors that block startup.
///
/// See issue #39: users who installed via an older `install-hooks.sh` (which
/// used `cp` instead of `ln -sf`) end up with a stale copy at
/// `/usr/local/bin/nex` after every Sparkle auto-update. This service detects
/// and repairs that drift while avoiding any binary it can't confidently
/// attribute to Nex.
enum CLIInstallService {
    private static let globalCLIPath = "/usr/local/bin/nex"
    private static let skillDestDir = ("~/.claude/skills/nex-agentic" as NSString).expandingTildeInPath
    private static let notifiedVersionKey = "cliInstallHealNotifiedVersion"

    /// Team ID of the original benfriebe/nex Developer ID builds. Used to
    /// verify that an existing `/usr/local/bin/nex` is Nex-managed before we
    /// touch it. mrowe/nex builds are ad-hoc signed (no Team ID), so they are
    /// only recognised via the symlink fast path and the broken-symlink suffix.
    private static let expectedTeamID = "4ASXCG2599"

    /// Single-shot guard: `.onAppear` can fire more than once during a
    /// process lifetime (window recreation, etc.). Filesystem mutation must
    /// not race with itself.
    private static let runLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Entry point. Safe to call from any queue; second and subsequent calls
    /// within the same process are no-ops.
    static func healIfNeeded() {
        let shouldRun = runLock.withLock { hasRun in
            guard !hasRun else { return false }
            hasRun = true
            return true
        }
        guard shouldRun else { return }

        healCLISymlink()
        healSkill()
    }

    // MARK: - Paths inside the current app bundle

    private static var bundledCLIPath: String {
        Bundle.main.bundlePath + "/Contents/Helpers/nex"
    }

    private static var bundledSkillPath: String {
        Bundle.main.bundlePath + "/Contents/Resources/skills/nex-agentic/SKILL.md"
    }

    private static var installScriptPath: String {
        Bundle.main.bundlePath + "/Contents/Resources/scripts/install-hooks.sh"
    }

    // MARK: - CLI symlink heal

    private static func healCLISymlink() {
        let fm = FileManager.default

        // Respect opt-out: if the user never installed the global CLI, do not
        // create it now. `attributesOfItem` uses lstat, so broken symlinks are
        // still reported as existing.
        guard let attrs = try? fm.attributesOfItem(atPath: globalCLIPath) else {
            return
        }

        let target = bundledCLIPath

        // Fast path: already a symlink pointing at our bundled binary.
        if attrs[.type] as? FileAttributeType == .typeSymbolicLink,
           let resolved = try? fm.destinationOfSymbolicLink(atPath: globalCLIPath),
           resolved == target {
            return
        }

        // Only touch an existing entry we can attribute to Nex. Anything else
        // (a homebrew binary named `nex`, a user-pinned older install outside
        // the app bundle, etc.) is left alone with no notification, since we
        // can't prove the user wanted our CLI there in the first place.
        guard isNexManagedInstall(at: globalCLIPath, attrs: attrs) else {
            return
        }

        let parentDir = (globalCLIPath as NSString).deletingLastPathComponent
        if access(parentDir, W_OK) != 0 {
            notifyUserToReinstall()
            return
        }

        do {
            try fm.removeItem(atPath: globalCLIPath)
            try fm.createSymbolicLink(atPath: globalCLIPath, withDestinationPath: target)
        } catch {
            print("CLIInstallService: symlink heal failed — \(error)")
            notifyUserToReinstall()
        }
    }

    /// Provenance check: decide whether an existing entry at `path` looks
    /// like something Nex's installer produced. We accept:
    /// - a symlink whose destination resolves to a code-signed binary with
    ///   our Team ID (covers "symlink into another /Applications/Nex.app");
    /// - a broken symlink whose stored destination ends with the Nex CLI
    ///   bundle path (the typical orphan after a Nex.app was moved);
    /// - a regular file whose code signature is ours (covers the old `cp`
    ///   install from pre-April install-hooks.sh).
    private static func isNexManagedInstall(at path: String, attrs: [FileAttributeKey: Any]) -> Bool {
        let type = attrs[.type] as? FileAttributeType

        if type == .typeSymbolicLink {
            let fm = FileManager.default
            guard let storedDest = try? fm.destinationOfSymbolicLink(atPath: path) else {
                return false
            }
            // Resolve relative to the symlink's directory so we can stat it.
            let resolvedAbs: String
            if (storedDest as NSString).isAbsolutePath {
                resolvedAbs = storedDest
            } else {
                let linkDir = (path as NSString).deletingLastPathComponent
                resolvedAbs = (linkDir as NSString).appendingPathComponent(storedDest)
            }
            if fm.fileExists(atPath: resolvedAbs) {
                return codeSignTeamID(at: resolvedAbs) == expectedTeamID
            }
            // Broken symlink: look for the standard Nex install suffix. This
            // is still a narrow match (`.app/Contents/Helpers/nex`) so we
            // don't accidentally inherit random dangling symlinks.
            return storedDest.hasSuffix(".app/Contents/Helpers/nex")
        }

        if type == .typeRegular {
            return codeSignTeamID(at: path) == expectedTeamID
        }

        return false
    }

    private static func codeSignTeamID(at path: String) -> String? {
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return nil
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return nil
        }

        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Skill heal

    private static func healSkill() {
        let fm = FileManager.default
        let destFile = skillDestDir + "/SKILL.md"
        let srcFile = bundledSkillPath

        // Only act if the user previously installed the skill (dest dir
        // exists) and a bundled copy is present. Don't silently create a new
        // skill install on their behalf.
        guard fm.fileExists(atPath: skillDestDir),
              fm.fileExists(atPath: srcFile) else {
            return
        }

        let srcURL = URL(fileURLWithPath: srcFile)
        let destURL = URL(fileURLWithPath: destFile)

        guard let srcData = try? Data(contentsOf: srcURL) else { return }
        let destData = try? Data(contentsOf: destURL)

        if srcData == destData {
            return
        }

        do {
            try srcData.write(to: destURL, options: .atomic)
        } catch {
            print("CLIInstallService: skill heal failed — \(error)")
        }
    }

    // MARK: - Fallback notification

    private static func notifyUserToReinstall() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if !currentVersion.isEmpty,
           UserDefaults.standard.string(forKey: notifiedVersionKey) == currentVersion {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Nex CLI is out of date"
        content.body = "Re-run the install script to update the global nex CLI: \(installScriptPath)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "nex-cli-install-heal",
            content: content,
            trigger: nil
        )
        let versionToRecord = currentVersion
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                // Leave the dedupe key unset so a later launch can try again
                // once notification authorization is granted.
                print("CLIInstallService: notification failed — \(error)")
                return
            }
            if !versionToRecord.isEmpty {
                UserDefaults.standard.set(versionToRecord, forKey: notifiedVersionKey)
            }
        }
    }
}
