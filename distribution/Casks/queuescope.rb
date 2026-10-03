cask "queuescope" do
  version "0.5.1"
  sha256 "18077e60e164ab4ad9c68f0b5487a28959b6c72b0bf43ec5ca2879b3f82ef620"

  url "https://github.com/raynirola/queuescope/releases/download/v#{version}/QueueScope-#{version}-macOS.zip"
  name "QueueScope"
  desc "Dashboard for BullMQ queues"
  homepage "https://github.com/raynirola/queuescope"

  auto_updates true
  depends_on macos: :sonoma

  app "QueueScope.app"
end
