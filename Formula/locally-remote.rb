class LocallyRemote < Formula
  desc "Headless Tailscale bridge for Xcode, CoreDevice, and SweetPad wireless builds"
  homepage "https://github.com/Nailington/Locally-Remote"
  url "https://github.com/Nailington/Locally-Remote/releases/download/v0.2.0/locally-remote-0.2.0-macos-universal.tar.gz"
  version "0.2.0"
  sha256 "a3a0249d692103f66be78769ed6c88d9cac4558e03a219cefdac1686c1391bd8"
  license "MIT"

  depends_on :macos

  def install
    bin.install "locally-remote"
    zsh_completion.install "completions/_locally-remote"
    bash_completion.install "completions/locally-remote.bash" => "locally-remote"
    fish_completion.install "completions/locally-remote.fish"
    doc.install "README.md", "docs", "skills"
  end

  service do
    run [opt_bin/"locally-remote", "daemon", "--bind", "lo0"]
    keep_alive true
    log_path var/"log/locally-remote.log"
    error_log_path var/"log/locally-remote.log"
  end

  def caveats
    <<~EOS
      Capture your paired iPhone once while on shared local Wi-Fi:
        locally-remote capture

      Start the background daemon either via LaunchAgent:
        locally-remote install-agent
      or via Homebrew services:
        brew services start locally-remote
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/locally-remote --version")
    assert_match "locally-remote", shell_output("#{bin}/locally-remote help")
  end
end
