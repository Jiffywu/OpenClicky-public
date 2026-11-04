# Feature-stack integration record

The private development archive combined PRs #46 through #54 and #57 in its integration PR #58 on 2 November 2026. It resolved shared wiring conflicts and included follow-up fixes for runtime cancellation, screenshot ownership, quiet delivery, usage-ledger writes, result retries, Developer brain controls and speech-provider refusal handling.

This public repository starts from cleaned archive commit `9590c5d57b2efa1f996c52be73e3c9fd3b0f4982` with a new root commit. Private branches, commit objects, PR records and raw evidence were not imported. The original archive remains private. Historical PR links elsewhere refer to that archive and require access to it.

The [source-head catalog](integration-source-heads.json) retains the original feature attribution. Its commit IDs describe the private archive; they are not ancestors in this public repository. [Contributor credit](../AUTHORS.md) records the archive's authors without publishing contact addresses.

The [public source manifest](public-source.json) records the cleaned source tree, its file hashes and the changes needed for this public copy. From a full public clone, run:

```sh
python3 scripts/check-stack-provenance.py
```

This checks the public import against the recorded source file hashes. It does not fetch private history. Later feature changes do not alter that initial import record.

The source snapshot passed 2,338 library tests, 37 app tests, eight Node tests, browser E2E, isolated app packaging and signature checks before import. Public repository adaptations are verified separately. These results do not establish microphone, Bluetooth, live Focus, OAuth or real provider/account behavior. See [the current status](parity-status.md) and [testing instructions](testing.md).

Generated logs, captures, recordings, diagnostic bundles and saved threads stay local. They are ignored under `docs/evidence/` and other output paths. Reviewed regression inputs are retained in [Tests/Fixtures](../Tests/Fixtures/README.md).
