# CI Evidence (Stage 1C)

## Publish on push to main

[Run 42035340209](https://github.com/AmirWeiser/Speedata-DevOps-Engineer-Home-Assignment---Amir-Weiser/actions/runs/42035340209), commit `80d7ed150d6dfa053c3798a8b36680854a9b1fd5`: all four jobs green.

| Image | Digest (build log = registry = anonymous pull) |
|---|---|
| `ghcr.io/amirweiser/skywatch-backend:80d7ed150d6dfa053c3798a8b36680854a9b1fd5` | `sha256:5a434c0402939d83ca14eaa210c62ecc66d642cc83cee61a9e3f607ece8c3a13` |
| `ghcr.io/amirweiser/skywatch-frontend:80d7ed150d6dfa053c3798a8b36680854a9b1fd5` | `sha256:c0864852d59333ef4b17beaff7df494a86ab684829f58258769f0b35eb3b726f` |

- Anonymous `docker pull` works (packages inherit the public repo's visibility); pulled images run as UID 10001 and return `/healthz` 200.
- **Re-run (attempt 2):** publish step logged `already exists (sha256:...); not overwriting`, so the digests above are unchanged. 11 Docker layers came from the GHA cache and the pip cache was restored; image jobs 64 s -> 51 s and 56 s -> 45 s.

## Gate: a failing test blocks publishing

[PR #1](https://github.com/AmirWeiser/Speedata-DevOps-Engineer-Home-Assignment---Amir-Weiser/pull/1) ([run 42039525997](https://github.com/AmirWeiser/Speedata-DevOps-Engineer-Home-Assignment---Amir-Weiser/actions/runs/42039525997)) changed one expectation to a wrong value:

- `test (backend)`: failure, `assert 404 == 500` (1 failed, 24 passed); `test (frontend)`: success.
- `image` jobs: skipped (`needs: test`); no image exists for the demo commit `e97b56c`.
- PR closed without merging; branch deleted; `main` unchanged.

Note: a skipped matrix job is displayed as `image (${{ matrix.service }})` because GitHub never expands the matrix of a job that does not run.

## Docs-only push is skipped

The commit adding this file touches only `docs/**`, which `paths-ignore` excludes on push; no workflow run is created for it.
