cask "andonmac" do
  version "2.5.1"
  sha256 "1e01dfed168f4a27ce047d76448bf3cfdc5de6e63c05a1250da9585cf415f133"

  url "https://github.com/V0val0x/AndOnMac/releases/download/v#{version}/AndOnMac.dmg"
  name "AndOnMac"
  desc "Native macOS app for mirroring and controlling Android smartphones"
  homepage "https://github.com/V0val0x/AndOnMac"

  depends_on macos: ">= :sonoma"

  app "AndOnMac.app"

  postflight do
    # Strip macOS Gatekeeper quarantine attribute because AndOnMac is distributed
    # free and open-source without a $99/yr Apple Developer ID notarization.
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/AndOnMac.app"],
                   sudo: false
  end

  caveats <<~EOS
    AndOnMac is free and open-source and is not notarized with a $99/year Apple Developer ID.
    Homebrew automatically cleared the quarantine attribute during installation so you can launch it immediately.
    Make sure USB Debugging (or Wireless Debugging) is enabled on your Android device.
  EOS

  zap trash: [
    "~/Library/Caches/com.andonmac.cache",
    "~/Library/Preferences/com.andonmac.app.plist",
  ]
end
