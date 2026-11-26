class LocallyRemote < Formula
  desc "Headless Tailscale bridge for Xcode, CoreDevice, and SweetPad wireless builds"
  homepage "https://github.com/Nailington/Locally-Remote"
  url "https://github.com/Nailington/Locally-Remote/releases/download/v0.2.1/locally-remote-0.2.1-macos-universal.tar.gz"
  version "0.2.1"
  sha256 "dd53a4d1adb85ca357d77a801ad93682fcd95d9f630fadd9bcdb9f48e64cdb7d"
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
