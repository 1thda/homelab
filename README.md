homelab-scripts
A few standalone scripts from my self-hosted media server, cleaned up for public sharing. No IPs, hostnames, credentials, or personal paths — just the automation logic.

Scripts
overnight-maintenance.sh
Nightly cron job that keeps a Docker-based media server healthy:

Prunes dangling Docker images and build cache.
Builds a SHA-256 checksum manifest of the media library and diffs it against the previous complete scan, to catch bitrot or silent corruption.
Runs a full ffmpeg decode integrity check across the library. Time-boxed and resumable — a large library takes several nights to fully scan, and each night picks up where the last one left off. Per-file timeout is derived from resolution × framerate × duration (decode cost tracks pixels, not file size — a small, low-bitrate 4K HEVC file is deceptively expensive to decode) rather than a flat or size-based timeout.
Checks Sonarr/Radarr download queues for flagged items that would otherwise go unnoticed until someone happens to look.
recovery-check.sh
A cron-friendly health check: verifies expected mountpoints are mounted, expected Docker containers are running and healthy, a couple of key service endpoints respond, and the most recent configuration backup exists and looks big enough to be real (not a truncated/empty file). Exit code is the failure count, so it drops straight into monitoring (e.g. Uptime Kuma's push monitor) or alerting.

rip-dvd.sh
Rips a DVD (via makemkvcon), auto-picks the longest title (or a specified one), transcodes to H.265 (via HandBrakeCLI), and drops the result into a Jellyfin-style Movies/ or TV/ library layout — then optionally triggers a Jellyfin library scan. Handles both movie and TV (--tv) modes, fails fast on missing disk space or an existing output file (won't clobber), and keeps the raw rip around for a retry if the transcode step fails.

Requirements
Each script lists its own dependencies at the top (makemkvcon, HandBrakeCLI, ffmpeg, jq, docker, curl). All configuration is via environment variables with sensible defaults — see each script's header.

Notes
These are pulled from a larger personal server setup and trimmed to the generically useful parts. They assume a fairly standard /mnt/media-style library layout (Movies/<Title> (<Year>)/, TV/<Show>/Season NN/) but every path is overridable.