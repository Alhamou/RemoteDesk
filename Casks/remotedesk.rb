cask "remotedesk" do
  version "1.1.0"
  sha256 "91d3fb5c704d53bb42138c437cc9799374251b68e5e93bf1c704f8179dde0dc8"

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
