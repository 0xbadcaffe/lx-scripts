# lx-scripts

Linux scripts for workstation setup and development.

Source the environment from Bash (works from any directory; repeated sourcing
adds the scripts directory to `PATH` only once):

```bash
source /path/to/lx-scripts/settings.sh
```

Preview Yocto repositories and initialize a checkout:

```bash
lx-clone-yocto-world.sh --list
lx-clone-yocto-world.sh --only poky --root "$HOME/src/yocto-distros"
lx-clone-yocto-world.sh --only poky --root "$HOME/src/yocto-distros" --apply
lx-init-yocto-world.sh --id poky
lx-init-yocto-world.sh --id poky --apply
```

Both Yocto commands use `scripts/data/yocto-repositories.txt`. Each row contains
`id|clone type|description|repository URL|initialization type`. Manifest
workspaces need `--sync` to download their sources; vendor SDKs are installed
separately. Clone updates skip dirty repositories and stop on Git failures.
`--apply` on the initializer opens a child shell; exit it to return.

Developer setup scripts expose `--help` with their supported distributions,
package selections, and preview options. Defaults differ: `lx-kernel-dev.sh`,
`lx-ffmpeg-dev.sh`, and `lx-yocto.sh` install unless given `--dry-run`.
Use `lx-rsync-backup.sh --help` for snapshot backups.

Run the offline regression suite with Bash, Git, and Python 3:

```bash
python3 -m unittest discover -s tests -v
shellcheck --severity=error settings.sh scripts/*.sh
```

Tests cover shell syntax, help, environment setup, Yocto selection/initialization,
and a real local Git clone/update, including dirty checkouts and update failures.
The repo manifest tool is stubbed; tests do not install packages, reboot, send
mail, or build firmware. No SDK is needed for these tests. Keep downloaded SDKs
and source/build trees outside this repository.
