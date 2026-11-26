import Foundation

public enum ShellType: String, CaseIterable, Codable, Sendable {
    case zsh
    case bash
    case fish
}

public struct CompletionInstallResult: Codable, Sendable {
    public let shell: ShellType
    public let path: String
    public let usesDefaultFpath: Bool
    public let nextSteps: String
}

public enum ShellCompletionsError: Error, LocalizedError {
    case unsupportedShell(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedShell(let name):
            return "Unsupported shell '\(name)'. Expected one of: zsh, bash, fish."
        }
    }
}

public enum ShellCompletions {
    public static func detectCurrentShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ShellType {
        let raw = (environment["SHELL"] ?? "").lowercased()
        if raw.hasSuffix("/fish") || raw == "fish" { return .fish }
        if raw.hasSuffix("/bash") || raw == "bash" { return .bash }
        return .zsh
    }

    public static func generate(for shell: ShellType) -> String {
        switch shell {
        case .zsh:
            return zshScript()
        case .bash:
            return bashScript()
        case .fish:
            return fishScript()
        }
    }

    public static func install(
        shell: ShellType? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemSearchPaths: [URL]? = nil
    ) throws -> CompletionInstallResult {
        let resolvedShell = shell ?? detectCurrentShell()
        let content = generate(for: resolvedShell)
        let fm = FileManager.default

        let targetURL: URL
        let usesDefaultFpath: Bool

        switch resolvedShell {
        case .zsh:
            let candidates = systemSearchPaths ?? [
                URL(fileURLWithPath: "/opt/homebrew/share/zsh/site-functions", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/share/zsh/site-functions", isDirectory: true)
            ]
            if let dir = candidates.first(where: { isWritableDirectory($0) }) {
                targetURL = dir.appendingPathComponent("_locally-remote")
                usesDefaultFpath = true
            } else {
                let userDir = homeDirectory.appendingPathComponent(".zsh/completions", isDirectory: true)
                try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
                targetURL = userDir.appendingPathComponent("_locally-remote")
                usesDefaultFpath = false
            }

        case .bash:
            let candidates = systemSearchPaths ?? [
                URL(fileURLWithPath: "/opt/homebrew/etc/bash_completion.d", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/etc/bash_completion.d", isDirectory: true)
            ]
            if let dir = candidates.first(where: { isWritableDirectory($0) }) {
                targetURL = dir.appendingPathComponent("locally-remote")
                usesDefaultFpath = true
            } else {
                let userDir = homeDirectory.appendingPathComponent(".local/share/bash-completion/completions", isDirectory: true)
                try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
                targetURL = userDir.appendingPathComponent("locally-remote")
                usesDefaultFpath = true
            }

        case .fish:
            let userDir = homeDirectory.appendingPathComponent(".config/fish/completions", isDirectory: true)
            try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
            targetURL = userDir.appendingPathComponent("locally-remote.fish")
            usesDefaultFpath = true
        }

        try content.write(to: targetURL, atomically: true, encoding: .utf8)

        let nextSteps: String
        switch resolvedShell {
        case .zsh:
            if usesDefaultFpath {
                nextSteps = "Reload zsh completions with: autoload -Uz compinit && compinit (or open a new shell)."
            } else {
                nextSteps = "Ensure ~/.zshrc contains `fpath=(~/.zsh/completions $fpath)` before `autoload -Uz compinit && compinit`, then open a new shell."
            }
        case .bash:
            nextSteps = "Open a new bash session or run: source \"\(targetURL.path)\""
        case .fish:
            nextSteps = "Fish loads completions from ~/.config/fish/completions automatically."
        }

        return CompletionInstallResult(
            shell: resolvedShell,
            path: targetURL.path,
            usesDefaultFpath: usesDefaultFpath,
            nextSteps: nextSteps
        )
    }

    private static func isWritableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    // MARK: - Shell Scripts

    private static func zshScript() -> String {
        """
        #compdef locally-remote

        _locally_remote_saved_devices() {
          local config_file="${HOME}/.config/locally-remote/config.json"
          [[ -r "$config_file" ]] || return 0
          local -a udids
          udids=(${(f)"$(sed -n 's/.*"udid"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$config_file")"})
          if (( ${#udids[@]} > 0 )); then
            _describe -t devices 'saved device UDID' udids
          fi
        }

        _locally_remote() {
          local -a commands
          commands=(
            'capture:Capture a paired iPhone Bonjour record on local Wi-Fi'
            'daemon:Run the background Tailscale bridge daemon'
            'status:Show daemon, LaunchAgent, and bridge status'
            'devices:List saved, CoreDevice, and Tailscale iOS devices'
            'wake:Probe Tailscale and wake the CoreDevice tunnel via devicectl'
            'doctor:Run environment and reachability checks'
            'install-agent:Install and start the user LaunchAgent'
            'uninstall-agent:Stop and remove the user LaunchAgent'
            'remove:Remove a saved device from config'
            'completions:Print or install shell tab completions'
            'version:Print the locally-remote version'
            'help:Show usage help'
          )

          local -a bind_modes shells
          bind_modes=('lo0' 'lan' 'loopback4')
          shells=('zsh' 'bash' 'fish')

          if (( CURRENT == 2 )); then
            _describe -t commands 'locally-remote command' commands
            return
          fi

          local cmd="${words[2]}"
          shift words
          (( CURRENT-- ))

          case "$cmd" in
            capture)
              _arguments \\
                '--device[UDID, CoreDevice ID, or name filter]:device:_locally_remote_saved_devices' \\
                '--tailscale-peer[Tailscale hostname, DNS name, or IP]:peer:' \\
                '--timeout[Bonjour browse timeout in seconds]:seconds:' \\
                '--json[Output JSON]'
              ;;
            daemon)
              _arguments \\
                '--force-bridge[Keep Tailscale proxy active even on local Wi-Fi]' \\
                '--bind[Local bind strategy]:mode:(lo0 lan loopback4)' \\
                '--port-range[Local relay port range (start:end)]:range:' \\
                '--poll-interval[Reconcile interval in seconds]:seconds:' \\
                '--verbose[Log proxied control and tunnel connections]'
              ;;
            status|devices|doctor)
              _arguments '--json[Output JSON]'
              ;;
            wake)
              _arguments \\
                '--device[Target device UDID]:device:_locally_remote_saved_devices' \\
                '--timeout[devicectl timeout in seconds]:seconds:' \\
                '--json[Output JSON]'
              ;;
            install-agent)
              _arguments \\
                '--bind[Bind strategy for LaunchAgent]:mode:(lo0 lan loopback4)' \\
                '--force-bridge[Pass --force-bridge to the LaunchAgent daemon]' \\
                '--bin[Override binary path]:binary:_files'
              ;;
            remove)
              _arguments '1:saved device:_locally_remote_saved_devices'
              ;;
            completions)
              if (( CURRENT == 2 )); then
                local -a subcmds
                subcmds=(
                  'zsh:Print zsh completion script'
                  'bash:Print bash completion script'
                  'fish:Print fish completion script'
                  'install:Install completions for the current or chosen shell'
                )
                _describe -t completions 'completions target' subcmds
              elif [[ "${words[2]}" == "install" ]]; then
                shift words
                (( CURRENT-- ))
                _arguments \\
                  '--shell[Target shell]:shell:(zsh bash fish)' \\
                  '--json[Output JSON]'
              fi
              ;;
          esac
        }

        if [ "$funcstack[1]" = "_locally_remote" ]; then
          _locally_remote "$@"
        else
          compdef _locally_remote locally-remote
        fi
        """
    }

    private static func bashScript() -> String {
        """
        _locally_remote_saved_udids() {
          local config_file="${HOME}/.config/locally-remote/config.json"
          if [[ -r "$config_file" ]]; then
            sed -n 's/.*"udid"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$config_file"
          fi
        }

        _locally_remote() {
          local cur prev cmd
          cur="${COMP_WORDS[COMP_CWORD]}"
          prev="${COMP_WORDS[COMP_CWORD-1]}"

          local commands="capture daemon status devices wake doctor install-agent uninstall-agent remove completions version help"
          if [[ ${COMP_CWORD} -eq 1 ]]; then
            COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
            return 0
          fi

          cmd="${COMP_WORDS[1]}"

          case "${prev}" in
            --bind)
              COMPREPLY=( $(compgen -W "lo0 lan loopback4" -- "${cur}") )
              return 0
              ;;
            --shell)
              COMPREPLY=( $(compgen -W "zsh bash fish" -- "${cur}") )
              return 0
              ;;
            --device)
              COMPREPLY=( $(compgen -W "$(_locally_remote_saved_udids)" -- "${cur}") )
              return 0
              ;;
            --bin)
              COMPREPLY=( $(compgen -f -- "${cur}") )
              return 0
              ;;
          esac

          case "${cmd}" in
            capture)
              COMPREPLY=( $(compgen -W "--device --tailscale-peer --timeout --json" -- "${cur}") )
              ;;
            daemon)
              COMPREPLY=( $(compgen -W "--force-bridge --bind --port-range --poll-interval --verbose" -- "${cur}") )
              ;;
            status|devices|doctor)
              COMPREPLY=( $(compgen -W "--json" -- "${cur}") )
              ;;
            wake)
              COMPREPLY=( $(compgen -W "--device --timeout --json" -- "${cur}") )
              ;;
            install-agent)
              COMPREPLY=( $(compgen -W "--bind --force-bridge --bin" -- "${cur}") )
              ;;
            remove)
              COMPREPLY=( $(compgen -W "$(_locally_remote_saved_udids)" -- "${cur}") )
              ;;
            completions)
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "zsh bash fish install" -- "${cur}") )
              elif [[ "${COMP_WORDS[2]}" == "install" ]]; then
                COMPREPLY=( $(compgen -W "--shell --json" -- "${cur}") )
              fi
              ;;
          esac
          return 0
        }

        complete -F _locally_remote locally-remote
        """
    }

    private static func fishScript() -> String {
        """
        function __locally_remote_saved_udids
          set -l cfg "$HOME/.config/locally-remote/config.json"
          if test -r "$cfg"
            sed -n 's/.*"udid"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$cfg"
          end
        end

        complete -c locally-remote -f

        # Subcommands
        complete -c locally-remote -n "__fish_use_subcommand" -a capture -d "Capture a paired iPhone Bonjour record on local Wi-Fi"
        complete -c locally-remote -n "__fish_use_subcommand" -a daemon -d "Run the background Tailscale bridge daemon"
        complete -c locally-remote -n "__fish_use_subcommand" -a status -d "Show daemon, LaunchAgent, and bridge status"
        complete -c locally-remote -n "__fish_use_subcommand" -a devices -d "List saved, CoreDevice, and Tailscale iOS devices"
        complete -c locally-remote -n "__fish_use_subcommand" -a wake -d "Probe Tailscale and wake the CoreDevice tunnel"
        complete -c locally-remote -n "__fish_use_subcommand" -a doctor -d "Run environment and reachability checks"
        complete -c locally-remote -n "__fish_use_subcommand" -a install-agent -d "Install and start the user LaunchAgent"
        complete -c locally-remote -n "__fish_use_subcommand" -a uninstall-agent -d "Stop and remove the user LaunchAgent"
        complete -c locally-remote -n "__fish_use_subcommand" -a remove -d "Remove a saved device from config"
        complete -c locally-remote -n "__fish_use_subcommand" -a completions -d "Print or install shell tab completions"
        complete -c locally-remote -n "__fish_use_subcommand" -a version -d "Print the locally-remote version"
        complete -c locally-remote -n "__fish_use_subcommand" -a help -d "Show usage help"

        # capture
        complete -c locally-remote -n "__fish_seen_subcommand_from capture" -l device -r -a "(__locally_remote_saved_udids)" -d "Device UDID or name"
        complete -c locally-remote -n "__fish_seen_subcommand_from capture" -l tailscale-peer -r -d "Tailscale hostname, DNS name, or IP"
        complete -c locally-remote -n "__fish_seen_subcommand_from capture" -l timeout -r -d "Bonjour browse timeout in seconds"
        complete -c locally-remote -n "__fish_seen_subcommand_from capture" -l json -d "Output JSON"

        # daemon
        complete -c locally-remote -n "__fish_seen_subcommand_from daemon" -l force-bridge -d "Keep Tailscale proxy active even on local Wi-Fi"
        complete -c locally-remote -n "__fish_seen_subcommand_from daemon" -l bind -r -a "lo0 lan loopback4" -d "Local bind strategy"
        complete -c locally-remote -n "__fish_seen_subcommand_from daemon" -l port-range -r -d "Local relay port range (start:end)"
        complete -c locally-remote -n "__fish_seen_subcommand_from daemon" -l poll-interval -r -d "Reconcile interval in seconds"
        complete -c locally-remote -n "__fish_seen_subcommand_from daemon" -l verbose -d "Log proxied connections"

        # status / devices / doctor
        complete -c locally-remote -n "__fish_seen_subcommand_from status devices doctor" -l json -d "Output JSON"

        # wake
        complete -c locally-remote -n "__fish_seen_subcommand_from wake" -l device -r -a "(__locally_remote_saved_udids)" -d "Target device UDID"
        complete -c locally-remote -n "__fish_seen_subcommand_from wake" -l timeout -r -d "devicectl timeout in seconds"
        complete -c locally-remote -n "__fish_seen_subcommand_from wake" -l json -d "Output JSON"

        # install-agent
        complete -c locally-remote -n "__fish_seen_subcommand_from install-agent" -l bind -r -a "lo0 lan loopback4" -d "Bind strategy for LaunchAgent"
        complete -c locally-remote -n "__fish_seen_subcommand_from install-agent" -l force-bridge -d "Pass --force-bridge to LaunchAgent"
        complete -c locally-remote -n "__fish_seen_subcommand_from install-agent" -l bin -r -F -d "Override binary path"

        # remove
        complete -c locally-remote -n "__fish_seen_subcommand_from remove" -a "(__locally_remote_saved_udids)" -d "Saved device UDID"

        # completions
        complete -c locally-remote -n "__fish_seen_subcommand_from completions; and not __fish_seen_subcommand_from zsh bash fish install" -a "zsh bash fish install"
        complete -c locally-remote -n "__fish_seen_subcommand_from completions; and __fish_seen_subcommand_from install" -l shell -r -a "zsh bash fish" -d "Target shell"
        complete -c locally-remote -n "__fish_seen_subcommand_from completions; and __fish_seen_subcommand_from install" -l json -d "Output JSON"
        """
    }
}
