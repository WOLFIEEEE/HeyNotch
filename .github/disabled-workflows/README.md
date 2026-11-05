# Archived workflows

These inherited workflows are outside `.github/workflows` and cannot run as GitHub Actions workflows. They are retained for reference while HeyNotch establishes its own release process. Their associated regression checks preserve useful versioning and publication logic for that future work.

Do not restore them directly. In particular, the archived release workflow still contains the original team's Homebrew destination. Any replacement must target only `WOLFIEEEE/HeyNotch`, use this fork's signing credentials and update feed, and pass a destination audit before it is enabled.

The active Build and test workflow supports push, pull request, and manual runs without signing credentials. CodeQL remains enabled for the personal fork. Scheduled publication, Pages deployment, Crowdin sync, and upstream branch-policy comments are disabled.
