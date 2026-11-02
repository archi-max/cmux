import Foundation

/// Makes the login shell of a cmux-tui SSH terminal report its directory.
///
/// The Files panel and relative file links follow a cmux-tui terminal through
/// the daemon's graph `cwd`, which the daemon takes from OSC 7. The daemon
/// injects its own shell integration (and so OSC 7) only into the default
/// shell it starts itself; an SSH terminal runs the app's launch command
/// (``SSHTuiConnection/shellCommand``), so without this the graph keeps the
/// spawn directory after every `cd`.
///
/// The launch command installs two small files beside the host `cmux` and
/// starts the login shell through them, the way terminals inject shell
/// integration:
/// - bash: `--posix -l` with `ENV` pointing at ``bashEnvironmentFile``. An
///   interactive POSIX-mode bash reads only `ENV`; the file leaves POSIX mode,
///   runs the login startup files bash would have run, and appends a prompt
///   hook that reports `$PWD`.
/// - zsh: `ZDOTDIR` pointing at the directory of ``zshEnvironmentFile``, which
///   restores the user's `ZDOTDIR`, runs their `.zshenv` and adds a `precmd`
///   hook. zsh reads every later startup file from the restored `ZDOTDIR`.
///
/// Any other shell, Apple's `/bin/bash` 3.2 (it ignores `ENV` in POSIX mode),
/// and a failed install start `exec "$SHELL" -l` exactly as before. The report
/// is the same `kitty-shell-cwd://host/path` OSC 7 the daemon's own
/// integration emits; the daemon accepts it only for its own host name.
public enum SSHTuiShellIntegration {
    /// Relative to the install directory.
    public static let bashEnvironmentPath = "shell/bash-env"
    /// Relative to the install directory; zsh finds it as `$ZDOTDIR/.zshenv`.
    public static let zshEnvironmentPath = "shell/zsh/.zshenv"

    /// The `ENV` file of an injected bash.
    public static let bashEnvironmentFile = #"""
    # cmux: makes this cmux SSH terminal's bash report its directory (OSC 7).
    # Installed by the cmux app; started as `bash --posix -l` with ENV=<this file>.
    if [[ -n "${CMUX_SSH_BASH_INJECT-}" ]]; then
      builtin unset ENV CMUX_SSH_BASH_INJECT
      if [[ -n "${CMUX_SSH_BASH_ENV+x}" ]]; then
        builtin export ENV="$CMUX_SSH_BASH_ENV"
        builtin unset CMUX_SSH_BASH_ENV
      fi
      builtin set +o posix
      builtin shopt -u inherit_errexit 2>/dev/null
      if [[ -n "${CMUX_SSH_BASH_UNEXPORT_HISTFILE-}" ]]; then
        builtin export -n HISTFILE
        builtin unset CMUX_SSH_BASH_UNEXPORT_HISTFILE
      fi
      # POSIX mode read no startup file; run those of an interactive login
      # shell (INVOCATION in bash(1)).
      if builtin shopt -q login_shell; then
        [[ -r /etc/profile ]] && builtin source /etc/profile
        for __cmux_ssh_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
          [[ -r "$__cmux_ssh_rc" ]] && { builtin source "$__cmux_ssh_rc"; break; }
        done
        builtin unset __cmux_ssh_rc
      fi
    fi
    __cmux_ssh_report_cwd() {
      builtin local ret=$?
      if [[ "${__cmux_ssh_reported_cwd-}" != "$PWD" ]]; then
        __cmux_ssh_reported_cwd=$PWD
        builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "$HOSTNAME" "$PWD"
      fi
      builtin return "$ret"
    }
    # After the startup files, so their PROMPT_COMMAND keeps running. A nested
    # shell can inherit PROMPT_COMMAND without the function, hence 2>/dev/null.
    if [[ -n "${bash_preexec_imported-}${__bp_imported-}" ]]; then
      precmd_functions+=(__cmux_ssh_report_cwd)
    elif [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
      PROMPT_COMMAND+=("__cmux_ssh_report_cwd 2>/dev/null")
    elif [[ -z "${PROMPT_COMMAND-}" ]]; then
      PROMPT_COMMAND="__cmux_ssh_report_cwd 2>/dev/null"
    else
      [[ "$PROMPT_COMMAND" =~ (\;[[:space:]]*|$'\n')$ ]] || PROMPT_COMMAND+=";"
      PROMPT_COMMAND+="__cmux_ssh_report_cwd 2>/dev/null"
    fi

    """#

    /// The `.zshenv` of an injected zsh.
    public static let zshEnvironmentFile = #"""
    # cmux: makes this cmux SSH terminal's zsh report its directory (OSC 7).
    # Installed by the cmux app; started as `zsh -l` with ZDOTDIR=<this directory>.
    if [[ -n ${CMUX_SSH_ZDOTDIR+x} ]]; then
      builtin export ZDOTDIR=$CMUX_SSH_ZDOTDIR
      builtin unset CMUX_SSH_ZDOTDIR
    else
      builtin unset ZDOTDIR
    fi
    # zsh reads each later startup file from the restored ZDOTDIR.
    [[ -r ${ZDOTDIR:-$HOME}/.zshenv ]] && builtin source ${ZDOTDIR:-$HOME}/.zshenv
    if [[ -o interactive ]]; then
      __cmux_ssh_report_cwd() {
        if [[ ${__cmux_ssh_reported_cwd-} != "$PWD" ]]; then
          __cmux_ssh_reported_cwd=$PWD
          builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "$HOST" "$PWD"
        fi
      }
      builtin autoload -Uz add-zsh-hook && add-zsh-hook precmd __cmux_ssh_report_cwd
    fi

    """#

    /// Shell code that installs both files under the directory in the
    /// shell variable `directoryVariable`. Any failure only skips the file.
    static func installCode(directoryVariable: String) -> String {
        [(bashEnvironmentPath, bashEnvironmentFile, "CMUX_SSH_BASH_EOF"),
         (zshEnvironmentPath, zshEnvironmentFile, "CMUX_SSH_ZSH_EOF")].map { path, contents, delimiter in
            let parent = (path as NSString).deletingLastPathComponent
            return """
            if [ ! -r "$\(directoryVariable)/\(path)" ]; then
              mkdir -p "$\(directoryVariable)/\(parent)" 2>/dev/null &&
              cat > "$\(directoryVariable)/\(path).$$" 2>/dev/null <<'\(delimiter)' &&
            \(contents)\(delimiter)
              mv -f "$\(directoryVariable)/\(path).$$" "$\(directoryVariable)/\(path)" 2>/dev/null
              rm -f "$\(directoryVariable)/\(path).$$" 2>/dev/null
            fi

            """
        }.joined()
    }

    /// Shell code that starts the login shell through the installed files,
    /// found under `installDirectory`, or falls through when it cannot.
    static func launchCode(installDirectory: String) -> String {
        """
        cmux_ssh_dir="\(installDirectory)"
        cmux_ssh_shell=${SHELL:-/bin/sh}
        case ${cmux_ssh_shell##*/} in
          bash)
            if [ -r "$cmux_ssh_dir/\(bashEnvironmentPath)" ] &&
              { [ "$cmux_ssh_shell" != /bin/bash ] || [ "$(uname -s 2>/dev/null)" != Darwin ]; }; then
              if [ -n "${ENV+x}" ]; then CMUX_SSH_BASH_ENV=$ENV; export CMUX_SSH_BASH_ENV; fi
              if [ -z "${HISTFILE+x}" ]; then
                HISTFILE=$HOME/.bash_history; CMUX_SSH_BASH_UNEXPORT_HISTFILE=1
                export HISTFILE CMUX_SSH_BASH_UNEXPORT_HISTFILE
              fi
              ENV=$cmux_ssh_dir/\(bashEnvironmentPath); CMUX_SSH_BASH_INJECT=1; export ENV CMUX_SSH_BASH_INJECT
              exec "$cmux_ssh_shell" --posix -l
            fi ;;
          zsh)
            if [ -r "$cmux_ssh_dir/\(zshEnvironmentPath)" ]; then
              if [ -n "${ZDOTDIR+x}" ]; then CMUX_SSH_ZDOTDIR=$ZDOTDIR; export CMUX_SSH_ZDOTDIR; fi
              ZDOTDIR=$cmux_ssh_dir/\((zshEnvironmentPath as NSString).deletingLastPathComponent); export ZDOTDIR
              exec "$cmux_ssh_shell" -l
            fi ;;
        esac
        unset cmux_ssh_dir cmux_ssh_shell

        """
    }
}
