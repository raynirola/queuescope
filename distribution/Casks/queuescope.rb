cask "queuescope" do
  version "0.6.0"
  sha256 "6fa6b8929ad89b23f99a708e9aa1564eba8d14b57cea51c2f90ad25ca7cd7d51"

  url "https://github.com/raynirola/queuescope/releases/download/v#{version}/QueueScope-#{version}-macOS.zip"
  name "QueueScope"
  desc "Dashboard for BullMQ queues"
  homepage "https://github.com/raynirola/queuescope"

  auto_updates true
  depends_on macos: :sonoma

  app "QueueScope.app"
end
