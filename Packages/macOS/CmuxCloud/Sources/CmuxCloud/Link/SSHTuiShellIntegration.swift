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
/// The launch command installs two small files in a private directory chain
/// below HOME (``SSHTuiHostOpenCommand/shellIntegrationDirectory``) and
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
      # A name with control characters would end the report early and inject
      # its own escape sequences.
      if [[ "${__cmux_ssh_reported_cwd-}" != "$PWD" && "$PWD" != *[[:cntrl:]]* ]]; then
        __cmux_ssh_reported_cwd=$PWD
        builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "$HOSTNAME" "$PWD"
      fi
      builtin return "$ret"
    }
    # The prompt runs the hook through this unexported name: a child shell that
    # inherits an exported PROMPT_COMMAND expands it to nothing instead of
    # looking up a command that isn't there.
    __cmux_ssh_cwd_hook=__cmux_ssh_report_cwd
    # After the startup files, so their PROMPT_COMMAND keeps running. A
    # newline, unlike `;`, also follows a trailing `&` or comment.
    if [[ -n "${bash_preexec_imported-}${__bp_imported-}" ]]; then
      precmd_functions+=(__cmux_ssh_report_cwd)
    elif [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
      PROMPT_COMMAND+=('${__cmux_ssh_cwd_hook-} 2>/dev/null')
    elif [[ -z "${PROMPT_COMMAND-}" ]]; then
      PROMPT_COMMAND='${__cmux_ssh_cwd_hook-} 2>/dev/null'
    else
      PROMPT_COMMAND+=$'\n''${__cmux_ssh_cwd_hook-} 2>/dev/null'
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
      # Only from precmd: chpwd also runs in subshells and $(...), where a
      # report would land in captured output.
      __cmux_ssh_report_cwd() {
        # A name with control characters would end the report early.
        if [[ ${__cmux_ssh_reported_cwd-} != "$PWD" && $PWD != *[[:cntrl:]]* ]]; then
          __cmux_ssh_reported_cwd=$PWD
          builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "$HOST" "$PWD"
        fi
      }
      # A .zshrc may reassign precmd_functions; the next cd puts the hook back
      # silently.
      __cmux_ssh_rehook() {
        (( ${precmd_functions[(Ie)__cmux_ssh_report_cwd]} )) || precmd_functions+=(__cmux_ssh_report_cwd)
      }
      # The arrays directly: add-zsh-hook needs fpath, which a .zshenv may replace.
      precmd_functions+=(__cmux_ssh_report_cwd)
      chpwd_functions+=(__cmux_ssh_rehook)
    fi

    """#

    /// Shell code that installs both files under the directory in the
    /// shell variable `directoryVariable`. Any failure only skips the file.
    /// The caller runs it under `umask 077`, so directories are private; the
    /// files are 644.
    static func installCode(directoryVariable: String) -> String {
        [(bashEnvironmentPath, bashEnvironmentFile, "CMUX_SSH_BASH_EOF"),
         (zshEnvironmentPath, zshEnvironmentFile, "CMUX_SSH_ZSH_EOF")].map { path, contents, delimiter in
            let parent = (path as NSString).deletingLastPathComponent
            return """
            if [ ! -r "$\(directoryVariable)/\(path)" ]; then
              mkdir -p "$\(directoryVariable)/\(parent)" 2>/dev/null &&
              cat > "$\(directoryVariable)/\(path).$$" 2>/dev/null <<'\(delimiter)' &&
            \(contents)\(delimiter)
              chmod 644 "$\(directoryVariable)/\(path).$$" 2>/dev/null &&
              mv -f "$\(directoryVariable)/\(path).$$" "$\(directoryVariable)/\(path)" 2>/dev/null
              rm -f "$\(directoryVariable)/\(path).$$" 2>/dev/null
            fi

            """
        }.joined()
    }

    /// Shell code that starts the login shell through the installed files,
    /// found under `installDirectory`, or falls through when it cannot.
    static func launchCode(installDirectory: String) -> String {
        #"""
        cmux_ssh_dir="\#(installDirectory)"
        cmux_ssh_shell=${SHELL:-/bin/sh}
        # The shell sources the file, so nobody else may be able to rewrite or
        # swap it: the file and each parent up to HOME is the user's, not a
        # symlink, with no group or other write. Group write is never trusted:
        # on Linux the group bits are the ACL mask, so they would let named ACL
        # entries write. Only that chain is looked at: another terminal
        # installing at the same moment renames temporary files beside it, and
        # a walk that lists one before it is renamed fails.
        cmux_ssh_unsafe() {
          find "$1" -prune \( -type l -o -perm -020 -o -perm -002 -o ! -user "$cmux_ssh_uid" \) -print 2>/dev/null || echo error
        }
        cmux_ssh_private() {
          [ -r "$1" ] && cmux_ssh_uid=$(id -u) || return 1
          [ -z "$(cmux_ssh_unsafe "$1")" ] || return 1
          cmux_ssh_parent=$1
          while [ "$cmux_ssh_parent" != "$HOME" ]; do
            case $cmux_ssh_parent in "$HOME"/?*) ;; *) return 1 ;; esac
            cmux_ssh_parent=${cmux_ssh_parent%/*}
            # HOME itself may be a symlink; check what it points to.
            if [ "$cmux_ssh_parent" = "$HOME" ]; then set -- "$HOME/."; else set -- "$cmux_ssh_parent"; fi
            [ -z "$(cmux_ssh_unsafe "$1")" ] || return 1
          done
        }
        case ${cmux_ssh_shell##*/} in
          bash)
            # bash expands ENV before reading it, so a path it would change
            # keeps the plain launch, as does Apple's bash 3.2 (it ignores ENV
            # in POSIX mode).
            case $cmux_ssh_dir in
              *[\$\`\\]*) ;;
              *)
                if cmux_ssh_private "$cmux_ssh_dir/\#(bashEnvironmentPath)" &&
                  { [ "$cmux_ssh_shell" != /bin/bash ] || [ "$(uname -s 2>/dev/null)" != Darwin ]; }; then
                  if [ -n "${ENV+x}" ]; then CMUX_SSH_BASH_ENV=$ENV; export CMUX_SSH_BASH_ENV; fi
                  if [ -z "${HISTFILE+x}" ]; then
                    HISTFILE=$HOME/.bash_history; CMUX_SSH_BASH_UNEXPORT_HISTFILE=1
                    export HISTFILE CMUX_SSH_BASH_UNEXPORT_HISTFILE
                  fi
                  ENV=$cmux_ssh_dir/\#(bashEnvironmentPath); CMUX_SSH_BASH_INJECT=1; export ENV CMUX_SSH_BASH_INJECT
                  exec "$cmux_ssh_shell" --posix -l
                fi ;;
            esac ;;
          zsh)
            # zsh reads .zshenv.zwc instead when it is there and newer.
            if cmux_ssh_private "$cmux_ssh_dir/\#(zshEnvironmentPath)" && {
                { [ ! -e "$cmux_ssh_dir/\#(zshEnvironmentPath).zwc" ] && [ ! -h "$cmux_ssh_dir/\#(zshEnvironmentPath).zwc" ]; } ||
                [ -z "$(cmux_ssh_unsafe "$cmux_ssh_dir/\#(zshEnvironmentPath).zwc")" ]; }; then
              if [ -n "${ZDOTDIR+x}" ]; then CMUX_SSH_ZDOTDIR=$ZDOTDIR; export CMUX_SSH_ZDOTDIR; fi
              ZDOTDIR=$cmux_ssh_dir/\#((zshEnvironmentPath as NSString).deletingLastPathComponent); export ZDOTDIR
              exec "$cmux_ssh_shell" -l
            fi ;;
        esac
        unset cmux_ssh_dir cmux_ssh_shell cmux_ssh_uid cmux_ssh_parent
        unset -f cmux_ssh_private cmux_ssh_unsafe

        """#
    }
}
