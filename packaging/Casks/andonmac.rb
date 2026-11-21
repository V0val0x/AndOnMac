cask "andonmac" do
  version "2.5.0"
  sha256 "91a569144ab020002c7b0b4b0d97f51d98a06fe574231806b45d3124e02c95c7"

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
