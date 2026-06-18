class Pinner < Formula
  desc "CLI for pinning content to IPFS via the Pinner.xyz service"
  homepage "https://pinner.xyz"
  version "0.1.0"
  license "MIT"

  on_arm do
    url "https://github.com/LumeWeb/pinner-cli/releases/download/v0.1.0/pinner-cli_0.1.0_darwin_arm64.tar.gz"
    sha256 "688403a3bbefdf202526123215bad1f23696e2a2f32da6ee5e9cebb5ea69ec78"
  end

  on_intel do
    url "https://github.com/LumeWeb/pinner-cli/releases/download/v0.1.0/pinner-cli_0.1.0_darwin_amd64.tar.gz"
    sha256 "7790bf49ca0456adf9afb417bf828c7201006f6a558c3dbc51483abccc2f7c56"
  end

  def install
    bin.install "pinner"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/pinner --version 2>&1", 1)
  end
end
