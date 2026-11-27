cask "edge-reminders" do
  version "0.5.0"
  sha256 "ea3fb8bd4285c9c776fa56229b6dbc9dfd8fbd21a3ad621533d91585c6b6fa62"

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
