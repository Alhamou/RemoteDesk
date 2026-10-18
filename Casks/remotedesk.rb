cask "remotedesk" do
  version "1.0.0"
  sha256 "9a13f4d575b9505ab0f08cf8850ee302ce7f7035fad9961d41b581f6a16df6f7"

  url "https://github.com/Alhamou/RemoteDesk/releases/download/v#{version}/RemoteDesk-#{version}.dmg"
  name "RemoteDesk"
  desc "High-performance Mac-to-Mac remote desktop over local network"
  homepage "https://github.com/Alhamou/RemoteDesk"

  depends_on macos: ">= :sonoma"

  app "RemoteDesk.app"

  zap trash: [
    "~/Library/Caches/local.remotedesk",
    "~/Library/Preferences/local.remotedesk.plist",
    "~/Library/Saved Application State/local.remotedesk.savedState",
  ]
end
