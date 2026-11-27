cask "edge-reminders" do
  version "0.5.0"
  sha256 "2f4cf67b1073027533512342f27d5b87b988876a09970e6137cd3e67d939ed46"

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
