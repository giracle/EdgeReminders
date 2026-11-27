cask "edge-reminders" do
  version "0.5.0"
  sha256 "b64e922f3753c92afdbc565c4ed87aded9981576bac01cb408c56af7a1ce7ca8"

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
