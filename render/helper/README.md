# EOTIR Render Helper - updates

This repository only distributes **signed updates** of the EOTIR Music Project render-helper script, so
that helpers can update themselves without needing access to any private repository.

* `latest.json` lists the current version and the SHA-256 of each file in `files/`.
* `latest.json.sig` is an OpenSSH signature (`ssh-keygen -Y sign`, namespace `eotir-render-helper`) over
  `latest.json`. A helper installs an update **only** if that signature verifies against the project's release
  key, which it already has. Anything else - including a modified file in this repository - is ignored.
* Nothing in here is a credential; the helper's access keys are never stored in this repository.

Do not edit the files by hand: they are produced by the project's `publish_update.py`.
