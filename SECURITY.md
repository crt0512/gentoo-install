# Security

## Trust model

`install`, `configure`, and the selected configuration file execute as Bash code. The installer then performs privileged disk, network, chroot, package-management, kernel, and boot operations. Treat a configuration file with the same caution as a root shell script.

Before running the installer:

- review the exact commit and local diff;
- review the selected configuration file and every sourced file;
- test the same configuration in a disposable VM;
- verify the target devices by stable `/dev/disk/by-id/` paths;
- keep recoverable backups outside the target disks.

Do not run configurations or repository copies obtained from an untrusted source.

## Reporting a vulnerability

Open a GitHub security advisory for `firesand/gentoo-easy-install` when possible. Do not include passwords, private keys, recovery keys, LUKS headers, or other secrets in a public issue.

For non-sensitive security hardening proposals, use the public issue tracker.
