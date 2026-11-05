# Problems and Solutions

Real issues encountered during the project, with root cause and fix.

## Workstation (Stage 1A)

### Docker CLI returned HTTP 500 from the engine API
- **Symptom:** `docker version` -> `500 Internal Server Error ... dockerDesktopLinuxEngine`.
- **Root cause:** The Docker Desktop backend had been waiting 363 hours for its engine VM (`docker-desktop` WSL distro, state *Stopped*) to answer its control API (`still waiting for init control API to respond`). The original boot failure was no longer in the rotated logs. A graceful `docker desktop restart` timed out because the backend itself was hung.
- **Fix:** Force-stop the Docker Desktop processes, `wsl --shutdown`, start Docker Desktop. No settings change or factory reset.

### New WSL user created as UID 1001, WSL fell back to root
- **Symptom:** `wsl -d Ubuntu-24.04` logged in as root; WSL error `getpwuid(1000) failed`.
- **Root cause:** Docker's WSL integration was enabled *before* the first-launch user setup. Docker injected a `docker` group with GID 1000, so `adduser` created the user as 1001:1001, while WSL registered `DefaultUid=1000`, a UID that belongs to nobody.
- **Fix:** `/etc/wsl.conf` `[user] default=amirweiser` (read at distro boot) and `usermod -aG docker amirweiser`. Lesson: create the distro user before enabling Docker integration.

### `docker` fell back to the Windows binary inside WSL
- **Symptom:** `type docker` resolved to `/mnt/c/Program Files/Docker/.../docker` while the Linux symlink was broken.
- **Root cause:** WSL appends the Windows `PATH` by default, so any missing Linux tool silently resolves to a Windows `.exe` (same risk for terraform, kubectl, helm, aws, python).
- **Fix:** `/etc/wsl.conf` `[interop] appendWindowsPath=false`; only VS Code's path is added back in `~/.profile`.

### `kubectl` resolved to Docker Desktop's bundled v1.34 instead of the pinned v1.37
- **Symptom:** `command -v kubectl` -> `/usr/local/bin/kubectl` (v1.34.1), not apt's `/usr/bin/kubectl` (v1.37.2).
- **Root cause:** Docker Desktop's WSL integration creates `/usr/local/bin/kubectl` (a symlink into its own cli-tools) every time it attaches, and `/usr/local/bin` precedes `/usr/bin` in `PATH`. v1.34 vs. a v1.37 API server is outside kubectl's supported +/-1 minor skew.
- **Fix:** `ln -sfn /usr/bin/kubectl ~/.local/bin/kubectl`; `~/.local/bin` is first in `PATH`. Deleting Docker's symlink would not last, since Docker recreates it.

### Docker integration lost after restarting the Ubuntu distro
- **Symptom:** After `wsl --terminate Ubuntu-24.04`, `docker: command not found`; the Docker Desktop log shows `distro agent Ubuntu-24.04 exited unexpectedly`.
- **Root cause:** Terminating the distro kills Docker Desktop's in-distro proxy. Docker Desktop then reports an error and waits for the user ("Restart the WSL integration") instead of retrying.
- **Fix / rule:** Do not terminate the distro while Docker Desktop runs. Recover with `docker desktop restart` (or the dialog button). A clean sequence (`wsl --shutdown`, start Docker Desktop, open Ubuntu) works, which matches a normal reboot.
