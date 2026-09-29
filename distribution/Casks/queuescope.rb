cask "queuescope" do
  version "0.5.0"
  sha256 "5db49b74f347e94e1183ebdf457cbffd116992a1f9f7c2488c938320938d3b52"

  url "https://github.com/raynirola/queuescope/releases/download/v#{version}/QueueScope-#{version}-macOS.zip"
  name "QueueScope"
  desc "Dashboard for BullMQ queues"
  homepage "https://github.com/raynirola/queuescope"

  auto_updates true
  depends_on macos: :sonoma

  app "QueueScope.app"
end
