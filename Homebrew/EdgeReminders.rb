cask "edge-reminders" do
  version "0.5.0"
  sha256 "17a64d69ba479064cf6da20fc1612c1dd1dd12a6083bfef8dbf6f81b5ba45be7"

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
