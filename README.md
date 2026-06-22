# setup-atestum

A GitHub Action that bootstraps a per-run **Atestum credential** for a CI
workflow.

`setup-atestum` runs inside your workflow, generates an ephemeral Ed25519
keypair on the runner, claims a per-run **Biscuit** derived from a
`WorkflowDelegationCredential` you signed in Atestum, and exports the credential
to the rest of your job. From that point the workflow holds a first-class
Atestum credential — with a Biscuit chain, DPoP-bound per-request signing,
StatusList2021 revocation, and Cedar policy — the same shape any Atestum agent
holds.

No `id-token: write` and no long-lived secrets are needed. The action uses the
run's automatic `GITHUB_TOKEN` purely as proof of *"I am this run"*; Atestum
validates it against GitHub's Workflow Run API and never trusts it for
authorization.

## Usage

```yaml
name: deploy
on:
  push:
    branches: [main]

permissions:
  contents: read
  actions: read        # lets Atestum verify this run via the GitHub API

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: Atestum/setup-atestum@v1
        with:
          tenant: acme-corp
          gateway: https://gateway.example.com
        # exports $ATESTUM_BISCUIT and $ATESTUM_PROOF_KEY for later steps

      - name: Call a protected MCP server
        run: |
          # The SDK appends a fresh DPoP block to the Biscuit per request —
          # no separate proof header is sent on the wire.
          BISCUIT=$(atestum-cli attach-dpop \
            --in "$ATESTUM_BISCUIT" \
            --key "$ATESTUM_PROOF_KEY" \
            --htm POST --htu /mcp/tools/call)
          curl -sS -X POST "$ATESTUM_GATEWAY/mcp/tools/call" \
            -H "Authorization: Biscuit $BISCUIT" \
            -H "Content-Type: application/json" \
            -d '{"tool":"deploy_to_staging","args":{"env":"staging"}}'
```

### Using the step outputs

The credential is also available as step outputs if you prefer them to env vars:

```yaml
      - uses: Atestum/setup-atestum@v1
        id: atestum
        with:
          tenant: acme-corp
      - run: echo "Acquired credential for ${{ steps.atestum.outputs.did }}"
```

## Inputs

| Input             | Required | Default                 | Description |
| ----------------- | -------- | ----------------------- | ----------- |
| `tenant`          | yes      | —                       | Atestum tenant id (or slug) the workflow belongs to. |
| `api-url`         | no       | `https://api.atestum.com` | Base URL of the Atestum control plane that serves `/v1/ci/claim`. |
| `gateway`         | no       | `""`                    | Atestum gateway base URL the credential targets. Exported as `$ATESTUM_GATEWAY`. |
| `github-token`    | no       | `${{ github.token }}`   | The run's `GITHUB_TOKEN`, used **only** as proof of run identity. Requires `actions: read`. |
| `installation-id` | no       | `""`                    | Numeric id of the Atestum GitHub App installation. Set with `job-id` for the low-latency pre-mint path; leave empty for the on-demand path. |
| `job-id`          | no       | `""`                    | Numeric `workflow_job` id (the webhook payload id, **not** the `GITHUB_JOB` config key). Optional; empty uses the on-demand path. |
| `on-demand`       | no       | `false`                 | Force the synchronous on-demand mint path. Used automatically when `installation-id` or `job-id` is empty. |
| `retries`         | no       | `3`                     | Claim attempts on the pre-mint path before falling back to on-demand (covers the webhook-delivery race). |

## Outputs

| Output         | Description |
| -------------- | ----------- |
| `biscuit`      | The per-run Atestum Biscuit credential (also `$ATESTUM_BISCUIT`, masked). |
| `proof-key`    | Path to the ephemeral Ed25519 private key file (also `$ATESTUM_PROOF_KEY`). |
| `did`          | The workflow run's Atestum DID. |
| `parent-vc-id` | Id/URL of the `WorkflowDelegationCredential` the Biscuit was derived from. |
| `expires-at`   | RFC 3339 expiry of the per-run Biscuit. |
| `audience`     | The audience the credential is bound to (gateway / MCP). |

## Exported environment variables

For later `run:` steps in the same job:

| Variable            | Description |
| ------------------- | ----------- |
| `ATESTUM_BISCUIT`   | The per-run Biscuit credential (masked in logs). |
| `ATESTUM_PROOF_KEY` | Path to the ephemeral private key file used to sign per-request DPoP blocks. |
| `ATESTUM_GATEWAY`   | The `gateway` input, if provided. |
| `ATESTUM_AUDIENCE`  | The audience the credential is bound to. |

## How it works

1. **Ephemeral keypair.** The action generates an Ed25519 keypair in tmpfs
   (`/dev/shm`, falling back to `RUNNER_TEMP`). The private key is created
   `0600` and never leaves the runner — only its *path* is exported.
2. **Claim.** It POSTs the run identity (`tenant`, `repository`, `run_id`,
   `run_attempt`, `head_sha`, the public key, and the `github_token`) to
   `POST <api-url>/v1/ci/claim`.
3. **Verification.** Atestum validates the `GITHUB_TOKEN` against
   `GET /repos/{repo}/actions/runs/{run_id}`, cross-checks `run_id` /
   `head_sha` / `repository`, then returns a per-run Biscuit derived from your
   signed `WorkflowDelegationCredential`.
4. **Export.** The Biscuit and the key path are masked and written to
   `$GITHUB_ENV` and to the step outputs.

### Pre-mint vs. on-demand

When a workflow job is queued, GitHub fires a `workflow_job` webhook to Atestum,
which pre-mints a claim ticket keyed on `(installation_id, run_id, run_attempt,
job_id)`. If you supply `installation-id` **and** `job-id`, the action redeems
that pre-minted ticket (lowest latency), retrying with exponential backoff to
absorb the webhook-delivery race. Otherwise — or if the pre-mint is not found
after `retries` attempts — it falls back to the **on-demand** path
(`on_demand=true`), which looks up the parent credential synchronously. The
on-demand path is the simplest to wire (it needs neither `installation-id` nor
`job-id`) and is the default when those are omitted.

## Security model

- **No `id-token: write`.** The action does not request a GitHub OIDC token. It
  uses the automatic `GITHUB_TOKEN` only as proof of run identity, which keeps
  the workflow's required permissions minimal (`actions: read`).
- **`GITHUB_TOKEN` is never trusted for authorization** — only for *identity
  attestation*. Authorization comes from the `WorkflowDelegationCredential` you
  signed in Atestum.
- **The private key never leaves the runner.** It is generated in tmpfs, kept
  `0600`, and only its path is exported.
- **Credentials are masked.** The Biscuit and key path are passed through
  `::add-mask::` so they are redacted from the workflow log. The action prints
  only a truncated SHA-256 fingerprint of the Biscuit, never the Biscuit itself.

## Requirements

- Linux GitHub-hosted or self-hosted runner with `openssl`, `curl`, `jq`, and
  `base64` on `PATH` (all present on the standard GitHub-hosted images).
- An Atestum GitHub App installed on your org and a
  `WorkflowDelegationCredential` scoped to the workflow's `(repository, ref,
  actor, event)`.
- `permissions: { actions: read }` in the workflow (or job) so Atestum can
  verify the run.

## License

Apache-2.0. See [LICENSE](./LICENSE).
