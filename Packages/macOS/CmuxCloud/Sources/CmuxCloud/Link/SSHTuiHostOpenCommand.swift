import CryptoKit
import Foundation

/// `cmux open <path>` in a cmux-tui SSH terminal.
///
/// Those terminals have no cmuxd-remote relay (`routesThroughSSHTui`), so no
/// `CMUX_SOCKET_PATH` and no `cmux` on PATH. Their one trusted channel to the
/// Mac is the session's own cmux-tui daemon socket (`CMUX_TUI_SOCKET`, a
/// user-owned Unix socket on the host): a notification row posted there
/// reaches this Mac on the state feed it already follows.
///
/// The terminal's launch command (``shellPrelude``) installs ``script`` as
/// `cmux` under a tagged, content-addressed directory and puts it first on
/// PATH. The script resolves the path on the host and posts one
/// session-wide row (no `--terminal`, so it never replaces a terminal's
/// pending marker) whose body is ``requestBody(path:terminalID:)``. The Mac
/// (``SSHTuiHostOpenIngress``) never shows the row; it answers it with an
/// ack under a reserved client id (``SSHTuiHostOpenAnswer``), which the script
/// waits for. The row itself stays in the daemon's 256-row ledger until it
/// ages out: the daemon can delete rows only per terminal or per session.
///
/// Not covered: terminals started through a tmux profile run tmux, not this
/// launch command, so they get no `cmux`; under tmux the script needs
/// `update-environment` to name the attaching terminal, and screen is refused.
public struct SSHTuiHostOpenCommand: Sendable {
    /// Marks a row as a `cmux open` request: `cmux-open-v2:<term id>:<base64 path>`.
    public static let bodyPrefix = "cmux-open-v2:"
    /// Shown by any client that displays the row anyway (a phone).
    public static let notificationTitle = "cmux open"
    /// The Mac keeps 1,024 bytes of a body: the prefix, a 37-byte terminal id,
    /// a colon and base64 of 729 bytes (972) fit.
    public static let maximumPathBytes = 729
    /// How long the host CLI waits for the Mac's answer before withdrawing the request.
    public static let answerWaitSeconds = 10

    /// The cmux-tui daemon session (`cmux`, or `cmux-<tag>` for a tagged build).
    public let session: String
    /// The host's cmux-tui binary for this build, `~/`-relative.
    public let remoteBinary: String

    public init(session: String, remoteBinary: String) {
        self.session = session
        self.remoteBinary = remoteBinary
    }

    /// The body the host CLI posts.
    public static func requestBody(path: String, terminalID: String) -> String {
        bodyPrefix + terminalID + ":" + Data(path.utf8).base64EncodedString()
    }

    /// The host binary as a shell word inside double quotes.
    private var remoteBinaryShellWord: String {
        remoteBinary.hasPrefix("~/") ? "$HOME/" + remoteBinary.dropFirst(2) : remoteBinary
    }

    /// The host `cmux`. POSIX sh. `open` is handled here; any other verb runs
    /// the next `cmux` on PATH, so a host's own cmux is not shadowed.
    public var script: String {
        let prefix = SSHTuiHostOpenAnswer.clientIDPrefix
        return #"""
        #!/bin/sh
        # cmux in a cmux SSH terminal, installed by the cmux app. It handles
        # `cmux open <path>`: the path is resolved on this host and handed to
        # the Mac through this session's cmux-tui daemon, which previews it over
        # the workspace's own SSH connection. Other verbs go to the next cmux
        # on PATH.
        CMUX_TUI_BIN="${CMUX_TUI_BIN:-\#(remoteBinaryShellWord)}"
        usage_text() {
          printf '%s\n' 'Usage: cmux open <path>' \
            'Opens a file of this host in cmux, beside this terminal. A trailing' \
            ':line or :line:column is accepted and ignored.' \
            'It returns once the cmux app has queued the preview; if the preview' \
            'then cannot open, a notice on the terminal says why.' \
            'Under tmux, add CMUX_TUI_TERMINAL_ID to update-environment so cmux knows' \
            'which cmux terminal shows the pane: the one attached last; screen is' \
            'not supported.'
        }
        usage() { usage_text >&2; exit 2; }
        die() { printf 'cmux open: %s\n' "$1" >&2; exit 1; }
        isnum() { case $1 in ''|*[!0-9]*) return 1 ;; esac; return 0; }
        # Never another copy of this script (any install directory, or one
        # that execs back here): two of them would exec each other forever.
        passthrough() {
          if [ -z "${CMUX_SSH_CLI_PASSTHROUGH:-}" ]; then
            self_dir=$(cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
            installs=$(cd -P -- "$HOME/.local/share/cmux/ssh-cli" 2>/dev/null && pwd -P) ||
              installs=$HOME/.local/share/cmux/ssh-cli
            old_ifs=$IFS; IFS=:; set -f
            for d in $PATH; do
              [ -n "$d" ] && [ -f "$d/cmux" ] && [ -x "$d/cmux" ] || continue
              real=$(cd -P -- "$d" 2>/dev/null && pwd -P) || continue
              [ "$real" = "$self_dir" ] && continue
              case $real/ in "$installs"/*) continue ;; esac
              IFS=$old_ifs; set +f
              CMUX_SSH_CLI_PASSTHROUGH=1 exec "$d/cmux" "$@"
            done
            IFS=$old_ifs; set +f
          fi
          printf 'cmux: %s is not available in a cmux SSH terminal; only cmux open is\n' "$1" >&2
          exit 2
        }
        case "${1:-}" in
          open) shift ;;
          -h|--help|help) usage_text; exit 0 ;;
          '') usage ;;
          *) passthrough "$@" ;;
        esac
        [ "$#" -eq 1 ] || usage
        raw=$1
        nl=$(printf '\nx'); nl=${nl%x}
        case $raw in
          -*) usage ;;
          *://*) die "$raw is not a file path" ;;
          *"$nl"*) die 'the path contains a line break' ;;
        esac
        [ -n "${CMUX_TUI_SOCKET:-}" ] && [ -n "${CMUX_TUI_TERMINAL_ID:-}" ] ||
          die 'run it in a cmux SSH terminal (CMUX_TUI_SOCKET and CMUX_TUI_TERMINAL_ID are not set)'
        terminal=$CMUX_TUI_TERMINAL_ID
        [ -z "${STY:-}" ] || die 'not available under screen: it cannot tell which cmux terminal shows this window'
        if [ -n "${TMUX:-}" ]; then
          # The pane inherited the id of whichever terminal started the tmux
          # server; tmux knows the attaching client's only via update-environment.
          line=$(tmux show-environment CMUX_TUI_TERMINAL_ID 2>/dev/null) || line=
          case $line in
            CMUX_TUI_TERMINAL_ID=term_*) terminal=${line#CMUX_TUI_TERMINAL_ID=} ;;
            *) die 'under tmux, add "set -ga update-environment CMUX_TUI_TERMINAL_ID" to tmux.conf and reattach, so cmux knows which terminal shows this pane' ;;
          esac
        fi
        case $terminal in
          term_*) ;;
          *) die "CMUX_TUI_TERMINAL_ID is not a terminal id: $terminal" ;;
        esac
        # A name may itself end in :12, so try it as written before dropping
        # an editor's :line or :line:column.
        path=$raw
        if [ ! -e "$path" ]; then
          case $raw in
            *:*)
              stripped=${raw%:*}
              if isnum "${raw##*:}" && [ -n "$stripped" ]; then
                case $stripped in
                  *:*) if isnum "${stripped##*:}" && [ -n "${stripped%:*}" ]; then stripped=${stripped%:*}; fi ;;
                esac
                path=$stripped
              fi ;;
          esac
        fi
        [ -e "$path" ] || die "no such file: $raw"
        [ -d "$path" ] && die "$path is a directory"
        [ -f "$path" ] || die "$path is not a regular file"
        [ -r "$path" ] || die "$path is not readable"
        abs=$(realpath -- "$path" 2>/dev/null) || abs=
        if [ -z "$abs" ]; then
          dir=$(cd -P -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || die "cannot resolve $path"
          abs=${dir%/}/$(basename -- "$path")
        fi
        case $abs in /*) ;; *) die "cannot resolve $path" ;; esac
        case $abs in *"$nl"*) die 'the path contains a line break' ;; esac
        # The Mac reads FSDB in place on this host; anything else is downloaded, capped.
        case $abs in
          *.[Ff][Ss][Dd][Bb]) ;;
          *) size=$(wc -c < "$abs" 2>/dev/null | tr -d ' ')
             { [ -n "$size" ] && [ "$size" -le 33554432 ]; } ||
               die "$abs is larger than 32 MB; open it from the Files panel instead" ;;
        esac
        length=$(printf %s "$abs" | wc -c | tr -d ' ')
        [ "$length" -le \#(Self.maximumPathBytes) ] || die "the path is too long for cmux open ($length bytes; at most \#(Self.maximumPathBytes))"
        command -v base64 >/dev/null 2>&1 || die 'needs base64 on this host'
        encoded=$(printf %s "$abs" | base64 | tr -d '\n')
        # Session-wide on purpose: a --terminal row would replace that
        # terminal's pending marker (an agent waiting for input, say).
        # The subtitle is display only; without JSON punctuation a name cannot
        # reshape the row this script reads back.
        subtitle=$(basename -- "$abs" | tr -d '{}[]"\\')
        out=$("$CMUX_TUI_BIN" --json notification create --title '\#(Self.notificationTitle)' \
          --subtitle "$subtitle" --body "\#(Self.bodyPrefix)$terminal:$encoded" 2>&1) ||
          die "the cmux-tui daemon refused it: $out"
        id=$(printf '%s\n' "$out" | sed -n 's/.*"id":"\(notification_[0-9a-f]\{32\}\)".*/\1/p' | head -n 1)
        [ -n "$id" ] || die "could not read the request id from the cmux-tui daemon: $out"
        cancel() {
          "$CMUX_TUI_BIN" --quiet notification ack "$id" --client '\#(SSHTuiHostOpenAnswer.cancelledClientID)' >/dev/null 2>&1
        }
        trap 'cancel; exit 130' INT TERM HUP
        # The Mac answers with an ack under a reserved client id. Only the
        # row's read_by array counts: keys are sorted, so it precedes the
        # subtitle, and the row is flat.
        answer() {
          list=$("$CMUX_TUI_BIN" --json notification list --limit 256 2>/dev/null) || { echo none; return; }
          row=$(printf '%s\n' "$list" | tr '}' '\n' | grep -F "\"id\":\"$id\"")
          [ -n "$row" ] || { echo gone; return; }
          case $row in *'"read_by":['*) ;; *) echo none; return ;; esac
          readers=${row#*'"read_by":['}; readers=${readers%%]*}
          ok=; hard=; soft=
          IFS=,; set -f
          for r in $readers; do
            case $r in
              '"\#(SSHTuiHostOpenAnswer.ok.clientID)"') ok=1 ;;
              '"\#(SSHTuiHostOpenAnswer.notOpenHere.clientID)"') soft=1 ;;
              '"\#(prefix)refused:'*'"') [ -n "$hard" ] || { hard=${r#'"\#(prefix)refused:'}; hard=${hard%'"'}; } ;;
            esac
          done
          if [ -n "$ok" ]; then echo ok
          elif [ -n "$hard" ]; then echo "refused:$hard"
          elif [ -n "$soft" ]; then echo soft
          else echo none
          fi
        }
        nap() { sleep 0.3 2>/dev/null || sleep 1; }
        # not-open-here is one Mac's view; another Mac may still show the
        # terminal, so it only changes the message at the deadline.
        soft=
        start=$(date +%s)
        while :; do
          result=$(answer)
          case $result in
            ok) exit 0 ;;
            soft) soft=1 ;;
            gone) die 'the request disappeared from the cmux-tui daemon before the Mac answered' ;;
            refused:stale) die 'the cmux app found the request too old; check this host'"'"'s clock' ;;
            refused:malformed) die 'the cmux app could not read the request' ;;
            refused:path) die 'the cmux app refused this path' ;;
            refused:previews-off) die 'cmux cannot preview from this terminal: it is not an SSH terminal there, or file previews are off' ;;
            refused:type) die 'this file type opens from the Files panel, not cmux open' ;;
            refused:*) die "the cmux app refused it (${result#refused:})" ;;
          esac
          [ $(($(date +%s) - start)) -lt \#(Self.answerWaitSeconds) ] || break
          nap
        done
        # Withdraw it so the Mac cannot open it later; an ok that raced the
        # withdrawal still counts.
        cancel
        for attempt in 1 2; do
          [ "$(answer)" = ok ] && exit 0
          nap
        done
        [ -z "$soft" ] || die 'this terminal is not open in a cmux window'
        die 'no cmux window took the request; is this terminal open in the cmux app?'

        """#
    }

    /// Where the launch command installs ``script``, as a `$HOME`-relative
    /// shell word. Tagged by session so a DEV build and the release on one
    /// host never share it, and keyed by content so an update installs beside
    /// the old copy instead of rewriting a file another shell may be running.
    public var installDirectory: String {
        let contents = script + "\u{0}" + SSHTuiShellIntegration.bashEnvironmentFile + "\u{0}" + SSHTuiShellIntegration.zshEnvironmentFile
        let digest = SHA256.hash(data: Data(contents.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "$HOME/.local/share/cmux/ssh-cli/\(session)/\(digest)"
    }

    /// Shell code run before the login shell: installs ``script`` and the
    /// ``SSHTuiShellIntegration`` files once and prepends their directory to
    /// PATH. Any failure leaves PATH unchanged and the shell still starts.
    public var shellPrelude: String {
        let delimiter = "CMUX_SSH_CLI_EOF"
        return """
        cmux_cli_dir="\(installDirectory)"
        if [ ! -x "$cmux_cli_dir/cmux" ]; then
          mkdir -p "$cmux_cli_dir" 2>/dev/null &&
          cat > "$cmux_cli_dir/.cmux.$$" 2>/dev/null <<'\(delimiter)' &&
        \(script)\(delimiter)
          chmod 755 "$cmux_cli_dir/.cmux.$$" && mv -f "$cmux_cli_dir/.cmux.$$" "$cmux_cli_dir/cmux" 2>/dev/null
          rm -f "$cmux_cli_dir/.cmux.$$" 2>/dev/null
        fi
        if [ -f "$cmux_cli_dir/cmux" ] && [ -x "$cmux_cli_dir/cmux" ]; then PATH="$cmux_cli_dir:$PATH"; export PATH; fi
        \(SSHTuiShellIntegration.installCode(directoryVariable: "cmux_cli_dir"))unset cmux_cli_dir

        """
    }

    /// Shell code that starts the interactive login shell so it reports its
    /// directory (``SSHTuiShellIntegration``); it falls through when it cannot.
    public var loginShellLaunch: String {
        SSHTuiShellIntegration.launchCode(installDirectory: installDirectory)
    }
}

/// What a marked row body asks for.
public enum SSHTuiHostOpenRequest: Equatable, Sendable {
    /// An ordinary notification.
    case notARequest
    /// Marked as a request but not honored; the answer says why.
    case refused(SSHTuiHostOpenAnswer)
    /// Open `path` (a canonical host path) from the pane showing `terminalID`.
    case open(path: String, terminalID: String)

    /// - Parameter pathIsAcceptable: The app passes
    ///   `RemoteRelayCommandPolicy.isAcceptableRemoteFileOpenPath`, the check
    ///   `file.open_remote` applies to every caller.
    public init(body: String, pathIsAcceptable: (String) -> Bool) {
        guard body.hasPrefix(SSHTuiHostOpenCommand.bodyPrefix) else {
            self = .notARequest
            return
        }
        let rest = body.dropFirst(SSHTuiHostOpenCommand.bodyPrefix.count)
        guard let colon = rest.firstIndex(of: ":"),
              case let terminalID = String(rest[..<colon]),
              CloudMachineNotificationEvent.isPublicID(terminalID, prefix: "term"),
              let data = Data(base64Encoded: String(rest[rest.index(after: colon)...])),
              data.count <= SSHTuiHostOpenCommand.maximumPathBytes,
              let path = String(data: data, encoding: .utf8),
              Data(path.utf8) == data else {
            self = .refused(.malformed)
            return
        }
        guard pathIsAcceptable(path) else {
            self = .refused(.path)
            return
        }
        self = .open(path: path, terminalID: terminalID)
    }
}

extension SSHTuiConnection {
    /// The host side of `cmux open` for this connection's daemon session.
    public var hostOpenCommand: SSHTuiHostOpenCommand {
        SSHTuiHostOpenCommand(session: session, remoteBinary: remoteBinary)
    }
}
