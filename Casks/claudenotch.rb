cask "claudenotch" do
  version "0.2.32"
  sha256 "71eeb60db00b0f69af3312b1c4db48f473212e7784f85c1d17ddb40f698ca148"

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
