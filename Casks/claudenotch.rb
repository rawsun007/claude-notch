cask "claudenotch" do
  version "0.2.22"
  sha256 "bdbde458e4981c58587fc75e9040f0f2010af34f46ce09420119ad45c41b11b4"

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
