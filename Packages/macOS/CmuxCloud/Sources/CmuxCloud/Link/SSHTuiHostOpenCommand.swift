import CryptoKit
import Foundation

/// `cmux open <path>[:line]` in a cmux-tui SSH terminal.
///
/// Those terminals have no cmuxd-remote relay (`routesThroughSSHTui`), so no
/// `CMUX_SOCKET_PATH` and no `cmux` on PATH. Their one trusted channel to the
/// Mac is the session's own cmux-tui daemon socket (`CMUX_TUI_SOCKET`, a
/// user-owned Unix socket on the host): a row the host CLI posts with
/// `notification create --terminal <its terminal>` reaches this Mac on the
/// state feed it already follows.
///
/// The terminal's launch command (``shellPrelude``) installs ``script`` as
/// `cmux` under a tagged, content-addressed directory and puts it first on
/// PATH. The script resolves the path on the host and posts a row whose body
/// is ``bodyPrefix`` + base64(path). The Mac (``SSHTuiHostOpenRequest``)
/// accepts only a fresh, terminal-scoped row with a canonical absolute path,
/// opens it in the native preview of the pane showing that terminal, and
/// acknowledges the row; nothing else in the row is used.
public struct SSHTuiHostOpenCommand: Sendable {
    /// Marks a row as a `cmux open` request. The body is this plus base64 of the path.
    public static let bodyPrefix = "cmux-open-v1:"
    /// Shown by any client that displays the row anyway (a phone).
    public static let notificationTitle = "cmux open"
    /// The Mac keeps 1,024 bytes of a body; base64 of 756 bytes plus the prefix fits.
    public static let maximumPathBytes = 756
    /// A row older (or, by clock skew, newer) than this is never opened, so a
    /// reconnect or relaunch does not replay old requests.
    public static let maximumRequestAge: TimeInterval = 60

    /// The cmux-tui daemon session (`cmux`, or `cmux-<tag>` for a tagged build).
    public let session: String
    /// The host's cmux-tui binary for this build, `~/`-relative.
    public let remoteBinary: String

    public init(session: String, remoteBinary: String) {
        self.session = session
        self.remoteBinary = remoteBinary
    }

    /// The host binary as a shell word inside double quotes.
    private var remoteBinaryShellWord: String {
        remoteBinary.hasPrefix("~/") ? "$HOME/" + remoteBinary.dropFirst(2) : remoteBinary
    }

    /// The host `cmux`. POSIX sh; only `open` is available.
    public var script: String {
        #"""
        #!/bin/sh
        # cmux in a cmux SSH terminal, installed by the cmux app. Only
        # `cmux open <path>[:line]` is available: the path is resolved on this
        # host and handed to the Mac through this session's cmux-tui daemon,
        # which previews it over the workspace's own SSH connection.
        CMUX_TUI_BIN="${CMUX_TUI_BIN:-\#(remoteBinaryShellWord)}"
        usage() { printf '%s\n' 'Usage: cmux open <path>[:line]' >&2; exit 2; }
        die() { printf 'cmux open: %s\n' "$1" >&2; exit 1; }
        isnum() { case $1 in ''|*[!0-9]*) return 1 ;; esac; return 0; }
        case "${1:-}" in
          open) shift ;;
          -h|--help|help) printf '%s\n' 'Usage: cmux open <path>[:line]' 'Opens a file of this host in cmux, beside this terminal.'; exit 0 ;;
          '') usage ;;
          *) printf 'cmux: %s is not available in a cmux SSH terminal; only cmux open is\n' "$1" >&2; exit 2 ;;
        esac
        [ "$#" -eq 1 ] || usage
        raw=$1
        case $raw in
          -*) usage ;;
          *://*) die "$raw is not a file path" ;;
        esac
        [ -n "${CMUX_TUI_SOCKET:-}" ] && [ -n "${CMUX_TUI_TERMINAL_ID:-}" ] ||
          die 'run it in a cmux SSH terminal (CMUX_TUI_SOCKET and CMUX_TUI_TERMINAL_ID are not set)'
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
        nl=$(printf '\nx'); nl=${nl%x}
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
        out=$("$CMUX_TUI_BIN" --json notification create --title '\#(Self.notificationTitle)' \
          --subtitle "$(basename -- "$abs")" --body "\#(Self.bodyPrefix)$encoded" \
          --terminal "$CMUX_TUI_TERMINAL_ID" 2>&1) || die "the cmux-tui daemon refused it: $out"
        id=$(printf '%s\n' "$out" | sed -n 's/.*"id":"\(notification_[0-9a-f]*\)".*/\1/p' | head -n 1)
        [ -n "$id" ] || exit 0
        # The Mac acknowledges the row once it has taken the request.
        tries=0
        while [ "$tries" -lt 20 ]; do
          list=$("$CMUX_TUI_BIN" --json notification list --limit 256 2>/dev/null) || break
          row=$(printf '%s\n' "$list" | tr '}' '\n' | grep -F "\"id\":\"$id\"")
          case $row in
            '') exit 0 ;;
            *'"read_by":[]'*) ;;
            *'"read_by":['*) exit 0 ;;
          esac
          sleep 0.3 2>/dev/null || sleep 1
          tries=$((tries + 1))
        done
        die 'no cmux window took the request; is this terminal open in the cmux app?'

        """#
    }

    /// Where the launch command installs ``script``, as a `$HOME`-relative
    /// shell word. Tagged by session so a DEV build and the release on one
    /// host never share it, and keyed by content so an update installs beside
    /// the old copy instead of rewriting a file another shell may be running.
    public var installDirectory: String {
        let digest = SHA256.hash(data: Data(script.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "$HOME/.local/share/cmux/ssh-cli/\(session)/\(digest)"
    }

    /// Shell code run before the login shell: installs ``script`` once and
    /// prepends its directory to PATH. Any failure leaves PATH unchanged and
    /// the shell still starts.
    public var shellPrelude: String {
        let delimiter = "CMUX_SSH_CLI_EOF"
        return """
        cmux_cli_dir="\(installDirectory)"
        if [ ! -x "$cmux_cli_dir/cmux" ]; then
          mkdir -p "$cmux_cli_dir" 2>/dev/null &&
          cat > "$cmux_cli_dir/.cmux.$$" 2>/dev/null <<'\(delimiter)' &&
        \(script)\(delimiter)
          chmod 755 "$cmux_cli_dir/.cmux.$$" && mv -f "$cmux_cli_dir/.cmux.$$" "$cmux_cli_dir/cmux"
          rm -f "$cmux_cli_dir/.cmux.$$" 2>/dev/null
        fi
        if [ -x "$cmux_cli_dir/cmux" ]; then PATH="$cmux_cli_dir:$PATH"; export PATH; fi
        unset cmux_cli_dir

        """
    }
}

/// What a marked body asks for (placeholder, implemented next).
public enum SSHTuiHostOpenRequest: Equatable, Sendable {
    case notARequest
    case refused(SSHTuiHostOpenAnswer)
    case open(path: String, terminalID: String)

    public init(body: String, pathIsAcceptable: (String) -> Bool) {
        self = .notARequest
    }
}

extension SSHTuiHostOpenCommand {
    public static func requestBody(path: String, terminalID: String) -> String { "" }
}

extension SSHTuiConnection {
    /// The host side of `cmux open` for this connection's daemon session.
    public var hostOpenCommand: SSHTuiHostOpenCommand {
        SSHTuiHostOpenCommand(session: session, remoteBinary: remoteBinary)
    }
}
