import Foundation

extension EdgeAgentService {
    static let nodeVersion = "24.20.0"
    static let nodeExecutable = "/opt/throttle-agent/runtime/node-v\(nodeVersion)"

    /// Install only the agent's runtime. Existing system Node and other projects
    /// keep their own interpreter. The exact official archive is checked before
    /// extraction and the running executable is replaced by an atomic rename.
    static var nodeInstallationScript: String {
        """
        set -euo pipefail
        case "$(uname -m)" in
          x86_64)
            node_arch=x64
            node_sha=2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2
            ;;
          aarch64|arm64)
            node_arch=arm64
            node_sha=5f4ddab610c1ab2016b3c227cebdbf6d9495161487e4739c7b90090595f465f7
            ;;
          *) echo 'Unsupported Edge runtime architecture' >&2; exit 1 ;;
        esac
        install -d -m 755 /opt/throttle-agent/runtime
        node_stage=$(mktemp -d /opt/throttle-agent/runtime/.node.XXXXXXXX)
        trap 'rm -rf "$node_stage"' EXIT
        node_archive=node-v\(nodeVersion)-linux-$node_arch.tar.xz
        curl --fail --location --max-time 120 "https://nodejs.org/dist/v\(nodeVersion)/$node_archive" \\
          -o "$node_stage/$node_archive"
        printf '%s  %s\\n' "$node_sha" "$node_stage/$node_archive" | sha256sum -c -
        tar -xJf "$node_stage/$node_archive" -C "$node_stage"
        node_binary="$node_stage/node-v\(nodeVersion)-linux-$node_arch/bin/node"
        test "$(env -i PATH=/usr/bin:/bin "$node_binary" --version)" = v\(nodeVersion)
        chmod 755 "$node_binary"
        mv -f "$node_binary" \(nodeExecutable)
        """
    }

    static func nodeBootstrapCommand(overSSH ssh: String) -> String {
        """
        \(ssh) 'bash -s' <<'INSTALL_NODE'
        \(nodeInstallationScript)
        INSTALL_NODE
        \(ssh) 'command -v tmux >/dev/null || apt-get install -y tmux'

        """
    }

}
