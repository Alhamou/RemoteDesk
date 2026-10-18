cask "remotedesk" do
  version "1.0.0"
  sha256 "d8b6d71f3da72c1a5c10e7cace8e820dabc7cd62f342372235df264afa7642bc"

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
