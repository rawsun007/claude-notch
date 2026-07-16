cask "claudenotch" do
  version "0.5.3"
  sha256 "32c0848ed2c150890dacc2dfeda98833963d57efd51ffafd841e37a046747c4c"

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
