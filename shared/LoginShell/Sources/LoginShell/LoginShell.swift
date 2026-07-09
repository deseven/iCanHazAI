// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Helpers for launching commands via the user's configured login shell.
///
/// When a GUI app is launched from Finder it inherits only a minimal system
/// `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so commands installed via
/// homebrew, nvm, volta, etc. are not found. To work around this, stdio
/// commands are launched through the user's login shell with `-l`, which
/// sources the login profile and makes the full environment available. The
/// command is then `exec`'d so the shell replaces itself and stdin/stdout
/// remain directly connected to the target process.
public enum LoginShell {

    /// Returns the user's configured login shell (the one set via `chsh`),
    /// queried from the local Open Directory database via
    /// `getpwuid(getuid())`. Falls back to `/bin/bash` if the lookup fails
    /// or the shell isn't a POSIX-compatible shell we can drive with `-l`
    /// (sh/bash/zsh).
    public static func path() -> String {
        if let pw = getpwuid(getuid()) {
            let shell = String(cString: pw.pointee.pw_shell)
            let name = (shell as NSString).lastPathComponent
            if ["sh", "bash", "zsh"].contains(name) {
                return shell
            }
        }
        return "/bin/bash"
    }

    /// Builds the `exec <command>\n` line to send to a login shell's stdin.
    /// The shell (run with `-l`) sources its login profile, then `exec`
    /// replaces the shell process with the target command so stdin/stdout
    /// are connected directly. The command string is passed through to the
    /// shell as-is, so shell syntax (quoting, variable expansion, etc.) is
    /// available.
    public static func execLine(command: String) -> String {
        return "exec \(command)\n"
    }
}
