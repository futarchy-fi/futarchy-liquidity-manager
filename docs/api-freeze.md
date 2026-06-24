# API Freeze

The public/external selectors for audited contracts are snapshotted in `audit/api-freeze`.

`tools/check-api-freeze.sh` regenerates method identifiers with `forge inspect` and compares them
to the committed snapshots. CI runs this check on every push and pull request.

If a selector changes, the change is not automatically forbidden, but it must be intentional:

1. review why the API changed;
2. update docs and integration runbooks if needed;
3. regenerate the relevant snapshot;
4. include the reason in the commit or pull request.

This protects the audit boundary from accidental renames, parameter changes, or new custody paths.
