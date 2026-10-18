cask "remotedesk" do
  version "1.0.0"
  sha256 "b23aa11e75f1d6c86dbdabfaa7b235df698416f9b2228b72dce3b03a269dd0f9"

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
