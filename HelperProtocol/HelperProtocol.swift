//
//  HelperProtocol.swift
//  VibeRemote
//
//  The XPC contract between the menu-bar app and the privileged helper daemon.
//  Shared by both targets so the interface cannot drift.
//

import Foundation

/// Identifiers shared by the app (client) and the helper (daemon).
public enum HelperConstants {
    /// Mach service the daemon listens on. Must match MachServices in the daemon plist.
    public static let machServiceName = "com.viberemote.helper"

    /// Daemon plist name inside the app bundle's Contents/Library/LaunchDaemons.
    public static let daemonPlistName = "com.viberemote.helper.plist"

    /// Bumped whenever the helper's capabilities change so the app can prompt for a
    /// re-registration instead of talking to a stale daemon.
    public static let version = 2

    /// The helper version that introduced `startPacketLoggerCapture`. An approved daemon
    /// keeps running the binary it launched with, so the app checks this before calling and
    /// falls back to an administrator prompt when the daemon predates the capability.
    public static let packetLoggerCaptureMinimumVersion = 2

    /// Team identifier the helper requires of any connecting client.
    public static let expectedTeamIdentifier = "SM96W8VVK9"

    /// Bundle identifier the helper requires of any connecting client.
    public static let expectedClientBundleID = "com.viberemote.app"
}

/// Operations the app may ask the privileged helper to perform. Everything here needs root,
/// which is the entire reason the helper exists: the user authorizes it once, and the app
/// never has to raise an administrator prompt again.
@objc public protocol HelperProtocol {
    /// Liveness and compatibility probe. Returns `HelperConstants.version` of the installed
    /// helper, which may be older than the app's if the daemon was not re-registered.
    func helperVersion(reply: @escaping (Int) -> Void)

    /// Installs the VibeRemote virtual audio driver from the given source path into the
    /// system HAL plug-in directory and restarts coreaudiod.
    func installAudioDriver(fromPath sourcePath: String, reply: @escaping (Bool, String?) -> Void)

    /// Starts the root PacketLogger capture supervisor for the microphone bridge and replies
    /// with its pid (or 0 and a message on failure). The caller's uid/pid are taken from the
    /// XPC connection, never from parameters, and every path is re-validated root-side inside
    /// the supervisor script, so a client cannot point root at code we did not verify.
    ///
    /// The supervisor outlives this call; the app stops it by writing the stop-signal file
    /// into the runtime directory, exactly as it does for the administrator-prompt path.
    func startPacketLoggerCapture(
        packetLoggerExecutablePath: String,
        runtimeDirectoryPath: String,
        voiceHelperPath: String,
        supervisorToken: String,
        reply: @escaping (Int32, String?) -> Void
    )
}

/// Shared definitions for the PacketLogger capture bridge. The privileged helper daemon and
/// the app's administrator-prompt fallback both assemble the root supervisor from these, so
/// the two launch paths run byte-identical scripts and cannot drift apart.
public enum PacketLoggerBridge {
    /// Where the supervisor installs Apple's PacketLoggerHelper if it is missing.
    public static let systemHelperInstallPath = "/Library/PrivilegedHelperTools/com.apple.bluetooth.PacketLoggerHelper"
    public static let systemHelperPlistPath = "/Library/LaunchDaemons/com.apple.bluetooth.PacketLoggerHelper.plist"
    public static let bluetoothDebugPreferencesPath = "/Library/Preferences/com.apple.MobileBluetooth.debug.plist"

    /// File names inside the app's private MicrophoneBridge runtime directory. The supervisor
    /// script and the app-side manager must agree on these exactly.
    public enum RuntimeFile {
        public static let voiceFIFO = "voice-helper.nhdr"
        public static let packetLoggerFIFO = "packetlogger-output.nhdr"
        public static let packetLoggerLog = "packetlogger.log"
        public static let packetCapture = "packets.log"
        public static let packetLoggerSession = "packetlogger.session"
        public static let stopSignal = "stop"
        public static let voiceHelperPID = "voice-helper.pid"
    }

    /// Derives the PacketLogger.app bundle path from its CLI executable path, requiring the
    /// original `PacketLogger.app/Contents/Resources/packetlogger` structure. Pure path
    /// logic — signature validation happens separately (and again root-side in the script).
    public static func appBundlePath(forExecutablePath executablePath: String) -> String? {
        let executableURL = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard executableURL.lastPathComponent == "packetlogger",
              executableURL.deletingLastPathComponent().lastPathComponent == "Resources",
              executableURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else {
            return nil
        }
        let appURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard appURL.pathExtension.lowercased() == "app",
              appURL.lastPathComponent == "PacketLogger.app" else {
            return nil
        }
        return appURL.path
    }

    /// Where Apple ships PacketLoggerHelper inside PacketLogger.app.
    public static func systemHelperSourcePath(forAppBundlePath appPath: String) -> String {
        URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Library/LaunchServices/com.apple.bluetooth.PacketLoggerHelper")
            .path
    }

    public static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The root supervisor for live PacketLogger capture. It validates every path it was
    /// handed (ownership, permissions, Apple signatures) before touching the system, installs
    /// the PacketLoggerHelper daemon if needed, enables Bluetooth HCI logging, then runs
    /// `packetlogger convert -s` in a restart loop, teeing the stream into the user's voice
    /// FIFO. It stops when the stop-signal file appears or the owning app process exits, and
    /// rolls back whatever system state it installed. Prints the supervisor pid on stdout.
    ///
    /// `ownerUID` is the user whose runtime directory and FIFOs the script requires and whose
    /// helper process it may terminate; `ownerPID` is the app process whose lifetime bounds
    /// the capture. When the privileged helper daemon runs this, both come from the XPC
    /// connection's audit information rather than from client-supplied values.
    public static func supervisorCommand(
        packetLogger: String,
        packetLoggerApp: String,
        helperSource: String,
        userHelper: String,
        runtimeDirectory: String,
        ownerPID: Int32,
        ownerUID: uid_t,
        supervisorToken: String
    ) -> String {
        func runtimePath(_ name: String) -> String {
            (runtimeDirectory as NSString).appendingPathComponent(name)
        }

        return """
        set -eu
        umask 077
        viberemote_supervisor_token=\(supervisorToken)
        owner_pid=\(ownerPID)
        expected_uid=\(ownerUID)
        runtime=\(shellEscape(runtimeDirectory))
        packetlogger_app=\(shellEscape(packetLoggerApp))
        packetlogger=\(shellEscape(packetLogger))
        helper_source=\(shellEscape(helperSource))
        helper_install=\(shellEscape(systemHelperInstallPath))
        helper_plist=\(shellEscape(systemHelperPlistPath))
        debug_preferences=\(shellEscape(bluetoothDebugPreferencesPath))
        voice_fifo=\(shellEscape(runtimePath(RuntimeFile.voiceFIFO)))
        packet_fifo=\(shellEscape(runtimePath(RuntimeFile.packetLoggerFIFO)))
        packet_log=\(shellEscape(runtimePath(RuntimeFile.packetLoggerLog)))
        packet_capture=\(shellEscape(runtimePath(RuntimeFile.packetCapture)))
        packet_session=\(shellEscape(runtimePath(RuntimeFile.packetLoggerSession)))
        stop_signal=\(shellEscape(runtimePath(RuntimeFile.stopSignal)))
        user_helper=\(shellEscape(userHelper))
        helper_pid_file=\(shellEscape(runtimePath(RuntimeFile.voiceHelperPID)))

        fail() {
          echo "$1" >&2
          exit 1
        }
        validate_packetlogger() {
          [ ! -L "$packetlogger_app" ] && [ -d "$packetlogger_app" ] || return 1
          [ ! -L "$packetlogger" ] && [ -x "$packetlogger" ] || return 1
          [ "$packetlogger" = "$packetlogger_app/Contents/Resources/packetlogger" ] || return 1
          /usr/bin/codesign --verify --strict --deep -R='identifier "com.apple.PacketLogger" and anchor apple' "$packetlogger_app" >/dev/null 2>&1 || return 1
          /usr/bin/codesign --verify --strict -R='identifier "com.apple.packetlogger" and anchor apple' "$packetlogger" >/dev/null 2>&1 || return 1
        }
        validate_helper() {
          [ ! -L "$1" ] && [ -x "$1" ] || return 1
          /usr/bin/codesign --verify --strict -R='identifier "com.apple.bluetooth.PacketLoggerHelper" and anchor apple' "$1" >/dev/null 2>&1
        }

        [ ! -L "$runtime" ] && [ -d "$runtime" ] || fail "Unsafe VibeRemote runtime directory."
        [ "$(/usr/bin/stat -f '%u' "$runtime")" = "$expected_uid" ] || fail "VibeRemote runtime directory has the wrong owner."
        [ "$(/usr/bin/stat -f '%Lp' "$runtime")" = "700" ] || fail "VibeRemote runtime directory permissions must be 0700."
        [ ! -L "$voice_fifo" ] && [ -p "$voice_fifo" ] || fail "Voice FIFO is missing or unsafe."
        [ ! -L "$packet_fifo" ] && [ -p "$packet_fifo" ] || fail "PacketLogger FIFO is missing or unsafe."
        [ "$(/usr/bin/stat -f '%u' "$voice_fifo")" = "$expected_uid" ] || fail "Voice FIFO has the wrong owner."
        [ "$(/usr/bin/stat -f '%u' "$packet_fifo")" = "$expected_uid" ] || fail "PacketLogger FIFO has the wrong owner."
        validate_packetlogger || fail "PacketLogger failed root-side Apple signature validation."
        validate_helper "$helper_source" || fail "PacketLoggerHelper failed root-side Apple signature validation."

        backup_dir=$(/usr/bin/mktemp -d /var/run/viberemote-microphone.XXXXXX) || fail "Could not create a root-only rollback directory."
        /bin/chmod 700 "$backup_dir"
        trap '/bin/rm -rf "$backup_dir"' EXIT HUP INT TERM
        validate_packetlogger || { /bin/rm -rf "$backup_dir"; fail "PacketLogger changed after elevation."; }
        validate_helper "$helper_source" || { /bin/rm -rf "$backup_dir"; fail "PacketLoggerHelper changed after elevation."; }
        helper_installed_by_bridge=0
        plist_installed_by_bridge=0
        helper_was_loaded=0
        rollback_owned_by_supervisor=0

        if /bin/launchctl print system/com.apple.bluetooth.PacketLoggerHelper >/dev/null 2>&1; then
          helper_was_loaded=1
        fi

        restore_system_state() {
          if [ "$helper_was_loaded" -eq 0 ]; then
            /bin/launchctl bootout system "$helper_plist" >/dev/null 2>&1 || true
          fi
          if [ "$plist_installed_by_bridge" -eq 1 ]; then /bin/rm -f "$helper_plist"; fi
          if [ "$helper_installed_by_bridge" -eq 1 ]; then /bin/rm -f "$helper_install"; fi
        }
        setup_exit() {
          if [ "$rollback_owned_by_supervisor" -eq 0 ]; then
            restore_system_state
            /bin/rm -rf "$backup_dir"
          fi
        }
        trap setup_exit EXIT HUP INT TERM

        if [ -e "$helper_install" ]; then
          validate_helper "$helper_install" || fail "The installed PacketLoggerHelper is not valid Apple code."
        else
          /usr/bin/install -m 755 -o root -g wheel "$helper_source" "$helper_install"
          helper_installed_by_bridge=1
        fi
        validate_helper "$helper_install" || fail "The installed PacketLoggerHelper failed post-install signature validation."
        if [ -e "$helper_plist" ]; then
          [ ! -L "$helper_plist" ] && [ -f "$helper_plist" ] || fail "The PacketLoggerHelper launch daemon plist is unsafe."
          [ "$(/usr/bin/stat -f '%u' "$helper_plist")" = "0" ] || fail "The PacketLoggerHelper plist has an unsafe owner."
          [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$helper_plist" 2>/dev/null)" = "com.apple.bluetooth.PacketLoggerHelper" ] || fail "The PacketLoggerHelper plist has an unexpected label."
          [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$helper_plist" 2>/dev/null)" = "$helper_install" ] || fail "The PacketLoggerHelper plist has an unexpected executable."
          [ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.apple.bluetooth.PacketLoggerHelper' "$helper_plist" 2>/dev/null)" = "true" ] || fail "The PacketLoggerHelper plist has unexpected Mach services."
        else
          temp_plist="$backup_dir/PacketLoggerHelper.plist"
          /usr/bin/touch "$temp_plist"
          /usr/libexec/PlistBuddy -c 'Clear dict' -c 'Add :Label string com.apple.bluetooth.PacketLoggerHelper' -c 'Add :ProgramArguments array' -c 'Add :ProgramArguments:0 string /Library/PrivilegedHelperTools/com.apple.bluetooth.PacketLoggerHelper' -c 'Add :MachServices dict' -c 'Add :MachServices:com.apple.bluetooth.PacketLoggerHelper bool true' -c 'Add :RunAtLoad bool true' "$temp_plist" >/dev/null
          /usr/bin/install -m 644 -o root -g wheel "$temp_plist" "$helper_plist"
          plist_installed_by_bridge=1
        fi
        if [ "$helper_was_loaded" -eq 0 ]; then
          /bin/launchctl bootstrap system "$helper_plist" >/dev/null 2>&1 || true
          /bin/launchctl kickstart system/com.apple.bluetooth.PacketLoggerHelper >/dev/null 2>&1 || true
        fi

        bluetooth_ready=1
        /usr/bin/defaults read /Library/Preferences/com.apple.MobileBluetooth.debug HCITraces 2>/dev/null | /usr/bin/grep -q 'StackDebugEnabled = 1' || bluetooth_ready=0
        /usr/bin/defaults read /Library/Preferences/com.apple.MobileBluetooth.debug HCI 2>/dev/null | /usr/bin/grep -q 'lmpRouting = 1' || bluetooth_ready=0
        /usr/bin/defaults read /Library/Preferences/com.apple.MobileBluetooth.debug FWStreamLogging 2>/dev/null | /usr/bin/grep -q 'FWCoreDumpEnable = 1' || bluetooth_ready=0
        /usr/bin/defaults read /Library/Preferences/com.apple.MobileBluetooth.debug FWStreamLogging 2>/dev/null | /usr/bin/grep -q 'FWStreamLoggingEnable = 1' || bluetooth_ready=0
        nvram_value=
        if nvram_line=$(/usr/sbin/nvram SkipBluetoothPacketLogAuthorization 2>/dev/null); then
          nvram_value=$(printf '%s\n' "$nvram_line" | /usr/bin/cut -f2- | /usr/bin/tr -d '[:space:]')
        else
          bluetooth_ready=0
        fi
        if [ -n "$nvram_value" ]; then bluetooth_ready=0; fi
        if [ "$bluetooth_ready" -eq 0 ]; then
          /usr/bin/defaults write /Library/Preferences/com.apple.MobileBluetooth.debug FWStreamLogging -dict FWCoreDumpEnable -bool true FWStreamLoggingEnable -bool true
          /usr/bin/defaults write /Library/Preferences/com.apple.MobileBluetooth.debug HCI -dict lmpRouting -bool true
          /usr/bin/defaults write /Library/Preferences/com.apple.MobileBluetooth.debug HCITraces -dict StackDebugEnabled -bool true
          /usr/sbin/nvram SkipBluetoothPacketLogAuthorization=" "
        fi

        # PacketLogger 26 treats priority 3 as the local live-capture source.
        # Without it the CLI prints the device inventory, then immediately
        # disconnects from "OS X Device" even when its helper is healthy.
        /usr/bin/defaults write com.apple.PacketLogger 'Last UsedPacket Priority Set' -int 3 >/dev/null 2>&1 || true

        /bin/rm -f "$packet_log" "$packet_capture" "$packet_session" "$stop_signal"
        : > "$packet_log"
        : > "$packet_capture"
        : > "$packet_session"
        /usr/sbin/chown "$expected_uid" "$packet_log" "$packet_capture" "$packet_session"
        /bin/chmod 600 "$packet_log" "$packet_capture" "$packet_session"

        # PacketLogger treats stdin EOF as Ctrl-D and tears down the local live-capture
        # session immediately ("Disconnected from OS X Device"). Give it a FIFO opened
        # read-write below, which never delivers data or EOF.
        stdin_keepalive="$runtime/packetlogger-stdin.keepalive"
        /bin/rm -f "$stdin_keepalive"
        /usr/bin/mkfifo -m 600 "$stdin_keepalive" || fail "Could not create the PacketLogger stdin keepalive FIFO."

        (
          # `exec` keeps the probe in the command-substitution fork itself, so PPID is this
          # subshell. Without it, sh runs one fork deeper and reports the wrong parent,
          # making every is_direct_child check fail and tearing the bridge down instantly.
          supervisor_pid=$(exec /bin/sh -c 'echo $PPID')
          logger_pid=
          tee_pid=
          is_direct_child() {
            case "$1" in ''|*[!0-9]*) return 1 ;; esac
            [ "$1" -gt 1 ] || return 1
            child_parent=$(/bin/ps -p "$1" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')
            [ "$child_parent" = "$supervisor_pid" ]
          }
          terminate_direct_child() {
            child_pid="$1"
            is_direct_child "$child_pid" || return 0
            /bin/kill -TERM "$child_pid" 2>/dev/null || true
            /bin/sleep 0.2
            if is_direct_child "$child_pid"; then /bin/kill -KILL "$child_pid" 2>/dev/null || true; fi
          }
          packetlogger_process_matches() {
            checked_pid="$1"
            checked_uid=$(/bin/ps -p "$checked_pid" -o uid= 2>/dev/null | /usr/bin/tr -d ' ')
            checked_command=$(/bin/ps -p "$checked_pid" -o comm= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$checked_uid" = "0" ] || return 1
            [ "$checked_command" = "$packetlogger" ]
          }
          packetlogger_is_alive() {
            candidate_pids="$(/usr/bin/pgrep -f "$packetlogger" 2>/dev/null || true)"
            for checked_pid in $candidate_pids; do
              if packetlogger_process_matches "$checked_pid"; then return 0; fi
            done
            return 1
          }
          terminate_packetlogger_processes() {
            matching_pids=
            candidate_pids="$(/usr/bin/pgrep -f "$packetlogger" 2>/dev/null || true)"
            for checked_pid in $candidate_pids; do
              if packetlogger_process_matches "$checked_pid"; then
                matching_pids="$matching_pids $checked_pid"
                /bin/kill -TERM "$checked_pid" 2>/dev/null || true
              fi
            done
            [ -z "$matching_pids" ] && return 0
            /bin/sleep 0.2
            for checked_pid in $matching_pids; do
              if packetlogger_process_matches "$checked_pid"; then
                /bin/kill -KILL "$checked_pid" 2>/dev/null || true
              fi
            done
          }
          user_helper_matches() {
            checked_pid="$1"
            checked_uid=$(/bin/ps -p "$checked_pid" -o uid= 2>/dev/null | /usr/bin/tr -d ' ')
            checked_command=$(/bin/ps -p "$checked_pid" -o comm= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$checked_uid" = "$expected_uid" ] || return 1
            if [ "$checked_command" = "$user_helper" ]; then return 0; fi
            [ "$checked_command" = "/bin/bash" ] || return 1
            checked_arguments=$(/bin/ps -ww -p "$checked_pid" -o command= 2>/dev/null || true)
            case "$checked_arguments" in *"$user_helper"*"$voice_fifo"*) return 0 ;; esac
            return 1
          }
          terminate_user_helper() {
            [ ! -L "$helper_pid_file" ] && [ -f "$helper_pid_file" ] || return 0
            [ "$(/usr/bin/stat -f '%u' "$helper_pid_file" 2>/dev/null)" = "$expected_uid" ] || return 0
            [ "$(/usr/bin/stat -f '%l' "$helper_pid_file" 2>/dev/null)" = "1" ] || return 0
            helper_pid_file_size=$(/usr/bin/stat -f '%z' "$helper_pid_file" 2>/dev/null || echo 999)
            case "$helper_pid_file_size" in ''|*[!0-9]*) return 0 ;; esac
            [ "$helper_pid_file_size" -le 64 ] || return 0
            helper_pid=$(/bin/cat "$helper_pid_file" 2>/dev/null || true)
            case "$helper_pid" in ''|*[!0-9]*) return 0 ;; esac
            [ "$helper_pid" -gt 1 ] || return 0
            user_helper_matches "$helper_pid" || return 0
            /bin/kill -TERM "$helper_pid" 2>/dev/null || true
            /bin/sleep 0.2
            if user_helper_matches "$helper_pid"; then
              /bin/kill -KILL "$helper_pid" 2>/dev/null || true
            fi
            /bin/rm -f "$helper_pid_file"
          }
          supervisor_cleanup() {
            terminate_direct_child "$logger_pid"
            terminate_packetlogger_processes
            terminate_direct_child "$tee_pid"
            terminate_user_helper
            /bin/date '+%Y-%m-%d %H:%M:%S PacketLogger supervisor stopped' >> "$packet_log" 2>/dev/null || true
            restore_system_state
            /bin/rm -f "$stop_signal" "$voice_fifo" "$packet_fifo" "$stdin_keepalive"
            /bin/rm -rf "$backup_dir"
          }
          trap supervisor_cleanup EXIT
          trap 'exit 0' HUP INT TERM

          while [ ! -e "$stop_signal" ] && /bin/kill -0 "$owner_pid" 2>/dev/null; do
            if ! validate_packetlogger; then
              /bin/date '+%Y-%m-%d %H:%M:%S PacketLogger signature changed; stopping' >> "$packet_log"
              break
            fi
            /bin/date '+%Y-%m-%d %H:%M:%S PacketLogger starting' >> "$packet_log"
            # PacketLogger 26 supports live stdout through `convert -s`. Its stdin must
            # never reach EOF (Control-D disconnects the local OS X Device session), so
            # it reads the keepalive FIFO opened read-write instead of /dev/null.
            "$packetlogger" convert -s -f nhdr 0<> "$stdin_keepalive" > "$packet_fifo" 2>> "$packet_log" &
            logger_pid=$!
            /usr/bin/tee -a "$packet_capture" < "$packet_fifo" > "$voice_fifo" &
            tee_pid=$!
            while is_direct_child "$tee_pid"; do
              if [ -e "$stop_signal" ] || ! /bin/kill -0 "$owner_pid" 2>/dev/null; then break; fi
              if ! is_direct_child "$logger_pid" && ! packetlogger_is_alive; then break; fi
              /bin/sleep 1
            done
            terminate_direct_child "$logger_pid"
            terminate_packetlogger_processes
            terminate_direct_child "$tee_pid"
            logger_status=0
            /bin/wait "$logger_pid" 2>/dev/null || logger_status=$?
            /bin/wait "$tee_pid" 2>/dev/null || true
            logger_pid=
            tee_pid=
            if [ -e "$stop_signal" ] || ! /bin/kill -0 "$owner_pid" 2>/dev/null; then break; fi
            /bin/date "+%Y-%m-%d %H:%M:%S PacketLogger exited with status $logger_status; restarting in 2 seconds" >> "$packet_log"
            /bin/sleep 2
          done
        ) >/dev/null 2>/dev/null < /dev/null &
        supervisor_pid=$!
        rollback_owned_by_supervisor=1
        trap - EXIT HUP INT TERM
        echo "$supervisor_pid"
        """
    }
}
