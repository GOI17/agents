class AgentSwitcher < Formula
  desc "Switch and sync machine-local agent profiles"
  homepage "https://github.com/TODO/agent-switcher"
  url "https://github.com/TODO/agent-switcher/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "TODO"
  # TODO: Add a license stanza after the project license is selected.

  def install
    bin.install "bin/agent-switcher"
    pkgshare.install "setup.sh"
    (bin/"agent-switcher").write <<~SH
      #!/bin/bash
      exec "#{pkgshare}/bin/agent-switcher" "$@"
    SH
    pkgshare.install "bin"
  end

  test do
    assert_match "agent-switcher doctor", shell_output("#{bin}/agent-switcher --help")
  end
end
