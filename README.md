# homelab

Scripts from my home NAS.

**Hardware:** Ryzen 5 5600, GTX 1080 Ti, Ubuntu 26.04
**Runs (all in Docker):** Jellyfin with NVENC transcoding, Sonarr/Radarr behind a gluetun VPN container, Samba shares, and a [Quartz](https://quartz.jzhao.xyz/) site for my notes at **[notes.honknas.win](https://notes.honknas.win)**

## Overnight maintenance

Runs at 1am from cron. Reports go to `~/overnight-reports/<date>/`.

| Script | What it does |
| --- | --- |
| [`overnight-maintenance-controlled`](scripts/overnight-maintenance-controlled) | Cron entrypoint. Runs the job as a transient systemd unit capped at 1 core and 2 GB RAM, at idle IO priority, so Jellyfin stays responsive. |
| [`overnight-maintenance.sh`](scripts/overnight-maintenance.sh) | Prunes dangling Docker images, builds a SHA-256 manifest of the library, full-decodes every video with ffmpeg to find corrupt files, and flags stuck Sonarr/Radarr downloads. |
| [`verify-manifests.py`](scripts/verify-manifests.py) | Compares tonight's manifest with the last complete one and reports changed/missing files (bitrot, accidental deletes). |

```cron
0 1 * * * nice -n 19 ionice -c3 flock -n /tmp/overnight-maintenance.lock ~/scripts/overnight-maintenance-controlled
```

A few things worth noting:

- **The decode scan is resumable.** It has a 3-hour budget per night and keeps a list of files that passed, so a big library gets through over several nights and after that a run only checks new files.
- **Per-file timeouts are based on pixels, not file size.** A low-bitrate 4K HEVC file is small on disk but slow to decode, so a size-based timeout kept killing it every night. The timeout is now width × height × fps × duration against measured decode throughput on this box.
- **`-xerror` matters.** Without it ffmpeg exits 0 on frame-level corruption, so the scan wouldn't catch anything `ffprobe` couldn't.
