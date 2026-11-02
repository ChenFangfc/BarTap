import Foundation

/// "Stay awake with the lid closed" is `pmset -a disablesleep 1`, which needs an administrator.
/// BarTap asks for the password once, when it is turned on, and leaves a small watcher running
/// with those rights. The watcher puts sleep back (`disablesleep 0`) and exits as soon as BarTap
/// turns it off (a file appears), BarTap quits or crashes, or the battery runs low; so turning it
/// off never asks again, and nothing can leave it on by accident.
public enum LidAwakeScript {
    /// `SleepDisabled` from `pmset -g`, or nil if the line is missing.
    public static func sleepDisabled(fromPMSet output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return nil
    }

    /// The shell command to run as an administrator: disables sleep, starts the watcher in the
    /// background and prints the watcher's process ID. Nil if `stopFile` has characters that
    /// can't sit safely inside the quoted script.
    /// - Parameters:
    ///   - pid: BarTap's process; once it's gone, sleep comes back.
    ///   - stopFile: BarTap creates it to turn the feature off.
    ///   - batteryMin: on battery at or below this percentage, sleep comes back.
    public static func command(watching pid: Int32, stopFile: String, batteryMin: Int, pmset: String = "/usr/bin/pmset") -> String? {
        let unsafe = CharacterSet(charactersIn: "\"'`$\\\n")
        guard pid > 0, batteryMin >= 0, !stopFile.isEmpty, stopFile.rangeOfCharacter(from: unsafe) == nil,
              pmset.rangeOfCharacter(from: unsafe) == nil else { return nil }
        let pm = "\"\(pmset)\""
        // Every 2 s: is BarTap still running, has it asked to stop? Every 30 s: the battery.
        let watcher = [
            "n=0",
            "while sleep 2; do",
            "kill -0 \(pid) 2>/dev/null || break",
            "[ -e \"\(stopFile)\" ] && break",
            "n=$((n+1))",
            "if [ $((n % 15)) -eq 0 ]; then",
            "b=$(\(pm) -g batt)",
            "case \"$b\" in *\"Battery Power\"*)",
            "p=$(echo \"$b\" | /usr/bin/grep -Eo \"[0-9]+%\" | /usr/bin/head -1 | /usr/bin/tr -d %)",
            "[ -n \"$p\" ] && [ \"$p\" -le \(batteryMin) ] && break;;",
            "esac",
            "fi",
            "done",
            "\(pm) -a disablesleep 0",
        ].joined(separator: "\n")
        return "\(pm) -a disablesleep 1 || exit 1\n"
            + "/usr/bin/nohup /bin/sh -c '\(watcher)' >/dev/null 2>&1 &\n"
            + "echo $!"
    }

    /// Turns sleep back on directly (no watcher left to ask).
    public static func restoreCommand(pmset: String = "/usr/bin/pmset") -> String { "\(pmset) -a disablesleep 0" }

    /// AppleScript that runs `shell` as an administrator: macOS shows its own password dialog with
    /// `prompt`.
    public static func appleScript(running shell: String, prompt: String) -> String {
        "do shell script \(quoted(shell)) with prompt \(quoted(prompt)) with administrator privileges"
    }

    /// An AppleScript string literal (line breaks written as \n, which AppleScript turns back).
    public static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
