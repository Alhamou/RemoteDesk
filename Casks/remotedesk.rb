cask "remotedesk" do
  version "1.0.0"
  sha256 "e052bf12fa6c2fad47916f51184adf22eccedf07856ad233b18777bb6428915a"

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
