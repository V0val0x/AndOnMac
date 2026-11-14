cask "andonmac" do
  version "2.0.15"
  sha256 :no_check # Replace with `shasum -a 256 dist/AndOnMac.dmg` for a pinned release

  url "https://github.com/V0val0x/AndOnMac/releases/download/v#{version}/AndOnMac.dmg"
  name "AndOnMac"
  desc "Native macOS app for mirroring and controlling Android smartphones"
  homepage "https://github.com/V0val0x/AndOnMac"

  depends_on macos: ">= :sonoma"

  app "AndOnMac.app"

  zap trash: [
    "~/Library/Caches/com.andonmac.cache",
    "~/Library/Preferences/com.andonmac.app.plist",
  ]
end
