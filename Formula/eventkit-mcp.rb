# Homebrew formula: this repository doubles as a tap.
#   brew tap tomludd/eventkit https://github.com/tomludd/EventKit.HttpMCP
#   brew install tomludd/eventkit/eventkit-mcp      (--HEAD builds the latest main)
class EventkitMcp < Formula
  desc "Menu bar app that exposes your macOS calendars as a local MCP server over HTTP"
  homepage "https://github.com/tomludd/EventKit.HttpMCP"
  head "https://github.com/tomludd/EventKit.HttpMCP.git", branch: "main"

  # SwiftUI macros need the full Xcode toolchain, not just the Command Line Tools.
  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    ENV["DEVELOPER_DIR"] = MacOS::Xcode.prefix.to_s
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "EventKitMCP"

    app = prefix/"EventKit MCP.app"
    (app/"Contents/MacOS").install ".build/release/EventKitMCP"
    (app/"Contents").install "Resources/Info.plist"
    system "codesign", "--force", "--sign", "-", "--identifier", "local.eventkit.httpmcp", app
  end

  def caveats
    <<~EOS
      Link the app into ~/Applications and start it:
        mkdir -p ~/Applications
        ln -sfn "#{opt_prefix}/EventKit MCP.app" ~/Applications/
        open ~/Applications/"EventKit MCP.app"

      macOS asks for calendar access on first launch, and again after each upgrade
      because the app is ad-hoc signed. Update with:
        brew upgrade eventkit-mcp
      (add --fetch-HEAD if you installed with --HEAD)
    EOS
  end

  test do
    assert_path_exists prefix/"EventKit MCP.app/Contents/MacOS/EventKitMCP"
    system "codesign", "--verify", prefix/"EventKit MCP.app"
  end
end
