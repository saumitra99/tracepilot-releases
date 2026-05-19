# tracepilot-releases

Public mirror that hosts the **install one-liner** and pre-built binary
releases for [Tracepilot](https://tracepilot.in). The source code lives
in a separate private repository — this repo only contains:

- `install.sh` — POSIX bash installer for macOS and Linux.
- GitHub releases tagged `v*` carrying tarballs for each supported target.

## Install (one-liner)

```sh
curl -fsSL https://raw.githubusercontent.com/saumitra99/tracepilot-releases/main/install.sh | bash
```

Supported targets:

| Target            | Tarball                                              |
|-------------------|------------------------------------------------------|
| macOS arm64       | `tracepilot-<tag>-aarch64-darwin.tar.gz`             |
| macOS x86_64      | `tracepilot-<tag>-x86_64-darwin.tar.gz`              |
| Linux x86_64      | `tracepilot-<tag>-x86_64-linux.tar.gz`               |

Each tarball contains `tracepilot` (CLI) and `tracepilotd` (daemon). After
install the daemon runs in file-watcher mode against your local AI tool
stores; open <http://localhost:4321> for the dashboard.

## Team / hosted backend

After installing, redeem your seat invite to forward usage rollups to your
workspace:

```sh
tracepilot login <invite-token> --email you@company.com
```

The team console lives at <https://app.tracepilot.in>.

## License

Binaries are distributed under the terms in the upstream private repo.
