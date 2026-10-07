# eotir-public

Public files for the **EOTIR Music Project**. Everything in this repository is world-readable and is meant to
be: **it contains no credentials, no private keys and no private hostnames.**

| Path | What it is |
|---|---|
| [`render/helper/`](render/helper/) | The signed update feed for the render helpers (Windows and Linux) that friends run to lend their computers to the project. |

## How the update feed stays safe

The render helpers check [`render/helper/latest.json`](render/helper/latest.json) for newer versions of
themselves. Because this repository is public, **nothing in it is trusted on its own**: a helper installs an update
only if `latest.json` carries a valid [`ssh-keygen -Y`](https://man.openbsd.org/ssh-keygen#Y) signature
(`latest.json.sig`, namespace `eotir-render-helper`) from the project's release key, whose *public* half each helper
already has. Each file is then checked against the SHA-256 recorded in that signed manifest, and a build number that is
not newer is ignored. Changing a file here - or pushing a forged manifest - cannot make a helper run anything.

## Rules for this repository

- **Never commit** private keys, `helper_key`, `known_hosts`, helper packages (`*.zip`, `*.tar.gz`), `.env` files,
  tokens or passwords. `.gitignore` blocks the usual names, but look at `git status` before every commit.
- Files under `render/helper/` are **generated and signed** by the project's `publish_update.py`. Do not edit them by
  hand; a hand-edited file simply fails verification and is ignored by helpers.
- `.gitattributes` disables all line-ending conversion on purpose: the signature covers exact bytes.
