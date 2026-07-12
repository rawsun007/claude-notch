cask "claudenotch" do
  version "0.3.4"
  sha256 "b200c9aff92aaa61ff9a9423338c80b704e13a02fdb123d5e71ad9227a5b1f88"

  url "https://github.com/rawsun007/claude-notch/releases/download/v#{version}/ClaudeNotch.dmg",
      verified: "github.com/rawsun007/claude-notch/"
  name "ClaudeNotch"
  desc "Shows Claude Code permission prompts in your Mac's notch"
  homepage "https://github.com/rawsun007/claude-notch"

  app "ClaudeNotch.app"

  caveats <<~EOS
    ClaudeNotch is ad-hoc signed (not yet notarized). On first launch:
      right-click ClaudeNotch in /Applications and choose Open.

    Then open the Setup window from the menu-bar bell to wire up the
    Claude Code hooks.
  EOS
end
