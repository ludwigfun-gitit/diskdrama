# DiskDrama

Minimal macOS menubar app that shows free disk space on Macintosh HD, polling every 10 minutes.

## Features

- **Menubar label**: `💾 42.3 GB` free at a glance
- **Warning indicators**: `⚠️` below 5 GB, `⛔️` below 1 GB
- **Dropdown**: free / used / total / usage %, last-checked time
- **Refresh Now**: manual poll (⌘R)
- **Open Storage Settings…**: jumps straight to System Settings → Storage
- No Dock icon, no sandbox, no external dependencies

## Requirements

- macOS 13 Ventura or later (arm64 or x86_64 — change `-target` in build.sh)
- Xcode Command Line Tools: `xcode-select --install`

## Build & Run

```bash
chmod +x build.sh
./build.sh run        # compile + launch immediately
./build.sh install    # compile + copy to /Applications/DiskDrama.app
./build.sh            # compile only → .build/DiskDrama
```

## Launch at Login (recommended)

After installing to /Applications, add it in:
**System Settings → General → Login Items → Open at Login → +**

## Customise

| Thing | Where |
|---|---|
| Poll interval | `AppDelegate.pollInterval` (seconds) |
| Low space threshold | `DiskInfo.isLow` (default 5 GB) |
| Critical threshold | `DiskInfo.isCritical` (default 1 GB) |
| Target volume | `statvfs("/", …)` — change `"/"` to any mount point |
