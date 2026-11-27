cask "edge-reminders" do
  version "0.5.0"
  sha256 "82d7bae3cd40e4eede87cc6cc74f7840613d2eee99d0aaee7ebb8d62efb8632d"

  url "https://github.com/giracle/EdgeReminders/releases/download/v#{version}/EdgeReminders-#{version}-macOS-universal.dmg"
  name "浮光提醒"
  name "EdgeReminders"
  desc "Native macOS menu-bar reminders app that docks to screen edges"
  homepage "https://github.com/giracle/EdgeReminders"

  depends_on macos: ">= :sequoia"

  app "EdgeReminders.app"

  zap trash: [
    "~/Library/Application Support/local.fuguang.EdgeReminders",
    "~/Library/Preferences/local.fuguang.EdgeReminders.plist",
  ]
end
