# vercel-deploy (vendored)

This folder is a copy of the `vercel-deploy` skill from the public repository
<https://github.com/openai/skills>, path `skills/.curated/vercel-deploy`, at commit
`49f948faa9258a0c61caceaf225e179651397431` (2026-06-24). It is distributed under the MIT licence in
`LICENSE.txt` (copyright 2026 Vercel). OpenClicky changed one file (see Local changes); this file is the only
addition.

Each unchanged file's git blob hash, checked against the upstream tree when it was vendored:

| File | Blob |
|---|---|
| SKILL.md | a7e6faf3b999d31e8224e232d39fbf58952b7a5b |
| LICENSE.txt | 94df5bf89dbb6210a707fb4edbf3aade96bc4318 |
| agents/openai.yaml | f11e4eeb297dac79d03c35b227830b611f6e6ad2 |
| assets/vercel-small.svg | 96df051b9b6ac2905a86f43b95fb9ff68d2d8b04 |
| assets/vercel.png | c41ae1e890a2f85c50ae6e976ed00e8374b0e87e |

## Local changes

`scripts/deploy.sh` leaves credential and secret files out of the upload: upstream excluded only `node_modules`,
`.git`, `.env` and `.env.*`, so files such as `.envrc`, `.npmrc`, `.aws/credentials` or `*.pem` in the project
folder were sent to the anonymous deployment. The staging `tar` now also excludes `.env*`, `.npmrc`, `.yarnrc*`,
`.netrc`, `.pypirc`, `.aws`, `.ssh`, `.gnupg`, `.docker`, `.vercel`, `*.pem`, `*.key`, `*.p12`, `*.pfx` and
`id_rsa*`, `id_dsa*`, `id_ecdsa*`, `id_ed25519*`. Nothing else in the script changed.

| File | Upstream blob | Local blob |
|---|---|---|
| scripts/deploy.sh | 4494ee11b60454f07fde1ed84b94935030530772 | db8eb5a8639d48777af3a27a9c0bba3421e2cf9a |

To update it, copy the folder from a newer commit of openai/skills, then update the commit and the hashes here
(`git hash-object <file>`), and reapply the local change above. `vendoredVercelDeployMatchesItsPinnedUpstreamCommit`
checks that the hashes still match.

`scripts/deploy.sh` sends the project to Vercel's claimable-deployment endpoint named in the script when the
Vercel CLI isn't signed in. The skill deploys previews unless the user asks for production.
