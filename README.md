# linux-backup-ops

Operational scripts for running filesystem-level backups against RHEL and SUSE
hosts. This exists because most backup failures on Linux aren't caused by the
backup product — they're caused by things the backup product can't see ahead
of time: a filesystem that's 97% full, a database holding a file open with
its unlinked inode still consuming space, a host onboarded without checking
whether the backup agent's ports are actually reachable, or a snapshot-based
backup left half-torn-down after a job aborts. These scripts are the checks
and helpers an engineer runs by hand (or wires into a pre-job hook) to catch
that class of problem before it turns into a missed backup, a failed
restore, or a 2am page.

## Scripts

| Script | Purpose |
|---|---|
| `linux-preflight-audit` | Checks agent presence, required ports, filesystem free space, and open-file exposure before a host is onboarded for backup. |
| `linux-fs-growth-report` | Tracks per-filesystem growth from periodic samples and forecasts time-to-full. |
| `linux-lvm-snapshot-backup` | Takes an LVM snapshot, backs it up, and tears the snapshot down safely, including on failure. |
| `linux-service-hardening-check` | Audits a RHEL/SUSE host against a subset of CIS-style baseline controls. |
| `linux-open-file-detector` | Identifies open or deleted-but-held files that a filesystem-level backup would silently skip or capture inconsistently. |

## Status

`linux-preflight-audit`, `linux-fs-growth-report`, and
`linux-open-file-detector` are read-only diagnostics and have been run and
verified against live RHEL and SUSE hosts.

`linux-lvm-snapshot-backup` and `linux-service-hardening-check` are reference
implementations. They are not tested against live RHEL/SUSE environments —
LVM snapshot handling and hardening baselines are too environment- and
policy-specific to ship as verified. Read them before running them, and
expect to adapt volume group names, snapshot sizing, and control sets to
your own hosts.

Do not run any script here against production without reading it first and
testing in a non-production environment.

## Requirements

- RHEL 8/9 or SUSE Linux Enterprise Server (openSUSE should mostly work but
  is untested)
- bash, coreutils, `lvm2` (for `linux-lvm-snapshot-backup`)
- `lsof` (for `linux-open-file-detector`)
- root or equivalent sudo access for filesystem, LVM, and process inspection

## Usage

Each script is standalone and takes `-h` / `--help` for its own options.
Typical invocation:

```
./linux-preflight-audit -h
./linux-fs-growth-report --filesystem /data --history /var/lib/fsgrowth
./linux-lvm-snapshot-backup --lv /dev/vgdata/lvdata --dest /backup/staging
./linux-service-hardening-check --profile rhel9
./linux-open-file-detector --path /data
```

Review the script source before pointing anything at a filesystem you can't
afford to lose, particularly `linux-lvm-snapshot-backup`, which creates and
removes LVM snapshots.

## Provenance

These scripts are generalised from roughly 20 years of enterprise
data-protection work. They contain no customer data, hostnames, credentials,
or site-specific configuration — everything here has been rewritten to be
generic and safe to publish.
