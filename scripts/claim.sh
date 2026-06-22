#!/usr/bin/env bash
#
# setup-atestum — claim a per-run Atestum Biscuit credential for a CI workflow.
#
# Run by `action.yml` inside a GitHub Actions runner. It:
#   1. Generates an ephemeral Ed25519 keypair in tmpfs (RUNNER_TEMP / /dev/shm).
#   2. POSTs the workflow run identity + the public key to the Atestum claim
#      endpoint, presenting the run's GITHUB_TOKEN as proof of "I am this run".
#   3. Receives a per-run Biscuit derived from the customer's signed
#      WorkflowDelegationCredential.
#   4. Exports $ATESTUM_BISCUIT (the Biscuit) and $ATESTUM_PROOF_KEY (the path
#      to the private key file) for subsequent workflow steps, masked.
#
# The Biscuit and the private key are masked in the workflow log; the script
# never prints either to stdout.
#
# Required environment (set by action.yml from the action inputs / runner ctx):
#   INPUT_API_URL          Base URL of the Atestum control plane (e.g. https://api.atestum.com)
#   INPUT_TENANT           Atestum tenant id / slug the workflow belongs to
#   INPUT_GATEWAY          Atestum gateway base URL the credential targets (exported for later steps)
#   INPUT_GITHUB_TOKEN     The run's GITHUB_TOKEN (proof of run identity)
#   INPUT_INSTALLATION_ID  Atestum GitHub App installation id (optional; "" => on-demand path)
#   INPUT_JOB_ID           Numeric workflow_job id (optional; "" => on-demand path)
#   INPUT_ON_DEMAND        "true" to force the synchronous on-demand mint path
#   INPUT_RETRIES          Claim retry attempts before falling back to on-demand
#   GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_SHA  (runner defaults)
#   GITHUB_ENV GITHUB_OUTPUT RUNNER_TEMP                            (runner defaults)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Preconditions — fail fast with a clear message if a tool or input is missing.
# ---------------------------------------------------------------------------
for tool in openssl curl jq base64 sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::setup-atestum requires '$tool' on the runner PATH (present on all GitHub-hosted runners)." >&2
    exit 1
  fi
done

: "${INPUT_API_URL:?api-url input is required}"
: "${INPUT_TENANT:?tenant input is required}"
: "${INPUT_GITHUB_TOKEN:?github-token input is required (default: \${{ github.token }})}"

# Trim a trailing slash off the API base so we never produce a // in the path.
API_URL="${INPUT_API_URL%/}"
CLAIM_URL="${API_URL}/v1/ci/claim"

# ---------------------------------------------------------------------------
# 1. Generate an ephemeral Ed25519 keypair in tmpfs.
#
# /dev/shm is a tmpfs (RAM-backed, never hits disk) on GitHub-hosted Linux
# runners; RUNNER_TEMP is the portable fallback. The private key is created
# 0600 and never leaves the runner. We export only its PATH to later steps;
# the bytes stay on the runner filesystem.
# ---------------------------------------------------------------------------
if [ -d /dev/shm ] && [ -w /dev/shm ]; then
  KEY_DIR="/dev/shm"
else
  KEY_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
fi

KEY_FILE="$(mktemp "${KEY_DIR}/atestum-proof-key-XXXXXXXX")"
chmod 600 "$KEY_FILE"
# Mask the key path defensively (it is not secret, but keeps logs clean).
echo "::add-mask::$KEY_FILE"

openssl genpkey -algorithm Ed25519 -out "$KEY_FILE" 2>/dev/null
chmod 600 "$KEY_FILE"

# Public key as base64 of the DER SubjectPublicKeyInfo (44 bytes for Ed25519:
# 12-byte SPKI prefix + 32-byte raw key). The Atestum claim handler accepts
# either the 44-byte SPKI form or the bare 32-byte key and strips the prefix.
PUBKEY_B64="$(openssl pkey -in "$KEY_FILE" -pubout -outform DER | base64 | tr -d '\n')"

# ---------------------------------------------------------------------------
# 2. Build the claim request body.
#
# The Atestum claim endpoint takes a flat JSON body (the GITHUB_TOKEN rides in
# the body, NOT an Authorization header). installation_id and job_id are
# numbers; when the caller cannot supply them they default to 0 and we drive
# the request down the on-demand path (which looks up the parent VC directly
# rather than a pre-minted (installation, run, attempt, job) cache tuple).
# ---------------------------------------------------------------------------
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
INSTALLATION_ID="${INPUT_INSTALLATION_ID:-0}"
JOB_ID="${INPUT_JOB_ID:-0}"
ON_DEMAND="${INPUT_ON_DEMAND:-false}"
RETRIES="${INPUT_RETRIES:-3}"

# Default to numeric 0 when an id input was left blank.
[ -z "$INSTALLATION_ID" ] && INSTALLATION_ID=0
[ -z "$JOB_ID" ] && JOB_ID=0

build_body() {
  # $1 = on_demand (true|false). jq builds the body so all strings are escaped
  # correctly and the numeric fields stay numeric.
  jq -cn \
    --arg tenant "$INPUT_TENANT" \
    --argjson installation_id "$INSTALLATION_ID" \
    --arg repository "$GITHUB_REPOSITORY" \
    --argjson run_id "$GITHUB_RUN_ID" \
    --argjson run_attempt "$RUN_ATTEMPT" \
    --argjson job_id "$JOB_ID" \
    --arg head_sha "$GITHUB_SHA" \
    --arg workflow_pubkey "$PUBKEY_B64" \
    --arg github_token "$INPUT_GITHUB_TOKEN" \
    --argjson on_demand "$1" \
    '{
      tenant: $tenant,
      installation_id: $installation_id,
      repository: $repository,
      run_id: $run_id,
      run_attempt: $run_attempt,
      job_id: $job_id,
      head_sha: $head_sha,
      workflow_pubkey: $workflow_pubkey,
      github_token: $github_token,
      on_demand: $on_demand
    }'
}

# do_claim <on_demand> -> prints HTTP status on its own line, writes the body
# to $RESP_BODY. Never echoes the request body (it carries the token).
RESP_BODY="$(mktemp "${KEY_DIR:-/tmp}/atestum-claim-resp-XXXXXXXX")"
do_claim() {
  local on_demand="$1"
  build_body "$on_demand" | curl -sS \
    -o "$RESP_BODY" \
    -w '%{http_code}' \
    -X POST "$CLAIM_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "User-Agent: setup-atestum-action" \
    --data-binary @-
}

# ---------------------------------------------------------------------------
# 3. Claim with retry + on-demand fallback.
#
# The canonical (webhook-driven) path may race the GitHub webhook delivery, so
# a 404 (CLAIM-003: pre-minted ticket not found) is retried with exponential
# backoff. If retries are exhausted — or the caller forced it, or no
# installation/job id was supplied — we fall back to the synchronous
# on-demand mint (on_demand=true), which skips the pre-mint cache lookup.
# ---------------------------------------------------------------------------
HTTP_CODE=""
attempt=0
backoff=0.25

if [ "$ON_DEMAND" = "true" ] || [ "$INSTALLATION_ID" = "0" ] || [ "$JOB_ID" = "0" ]; then
  # No way to hit the pre-minted cache tuple — go straight to on-demand.
  echo "Atestum: claiming credential (on-demand mint path)..."
  HTTP_CODE="$(do_claim true)"
else
  echo "Atestum: claiming credential (webhook pre-mint path, up to ${RETRIES} attempts)..."
  while [ "$attempt" -lt "$RETRIES" ]; do
    HTTP_CODE="$(do_claim false)"
    if [ "$HTTP_CODE" = "404" ]; then
      attempt=$((attempt + 1))
      if [ "$attempt" -lt "$RETRIES" ]; then
        echo "Atestum: pre-minted ticket not found yet (CLAIM-003); retry ${attempt}/${RETRIES} in ${backoff}s..."
        sleep "$backoff"
        backoff="$(awk "BEGIN{print $backoff * 4}")"
        continue
      fi
    fi
    break
  done
  if [ "$HTTP_CODE" = "404" ]; then
    echo "Atestum: pre-mint not found after ${RETRIES} attempts; falling back to on-demand mint..."
    HTTP_CODE="$(do_claim true)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Handle the response.
# ---------------------------------------------------------------------------
if [ "$HTTP_CODE" != "200" ]; then
  # Surface the structured Atestum error code/message without leaking the body
  # wholesale (it does not echo the token, but stay conservative).
  ERR_CODE="$(jq -r '.error.code // empty' "$RESP_BODY" 2>/dev/null || true)"
  ERR_MSG="$(jq -r '.error.message // empty' "$RESP_BODY" 2>/dev/null || true)"
  rm -f "$RESP_BODY"
  echo "::error::Atestum claim failed (HTTP ${HTTP_CODE}${ERR_CODE:+, ${ERR_CODE}})${ERR_MSG:+: ${ERR_MSG}}" >&2
  exit 1
fi

BISCUIT="$(jq -r '.biscuit_token // empty' "$RESP_BODY")"
EXPIRES_AT="$(jq -r '.expires_at // empty' "$RESP_BODY")"
DID="$(jq -r '.did // empty' "$RESP_BODY")"
PARENT_VC_ID="$(jq -r '.parent_vc_id // empty' "$RESP_BODY")"
AUDIENCE="$(jq -r '.att_proof_audience // empty' "$RESP_BODY")"
rm -f "$RESP_BODY"

if [ -z "$BISCUIT" ]; then
  echo "::error::Atestum claim returned 200 but no biscuit_token in the response." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Mask the credential and export it for later steps.
#
# ::add-mask:: redacts the value from all subsequent log lines. We write the
# Biscuit + key path to $GITHUB_ENV (env vars for `run:` steps) and to
# $GITHUB_OUTPUT (step outputs for ${{ steps.<id>.outputs.* }}).
# ---------------------------------------------------------------------------
echo "::add-mask::$BISCUIT"

GATEWAY="${INPUT_GATEWAY:-}"

{
  echo "ATESTUM_BISCUIT=$BISCUIT"
  echo "ATESTUM_PROOF_KEY=$KEY_FILE"
  [ -n "$GATEWAY" ] && echo "ATESTUM_GATEWAY=$GATEWAY"
  [ -n "$AUDIENCE" ] && echo "ATESTUM_AUDIENCE=$AUDIENCE"
} >> "$GITHUB_ENV"

{
  echo "biscuit=$BISCUIT"
  echo "proof-key=$KEY_FILE"
  echo "did=$DID"
  echo "parent-vc-id=$PARENT_VC_ID"
  echo "expires-at=$EXPIRES_AT"
  echo "audience=$AUDIENCE"
} >> "$GITHUB_OUTPUT"

# Fingerprint only — never the Biscuit itself.
FINGERPRINT="$(printf '%s' "$BISCUIT" | sha256sum | cut -c1-16)"
echo "Atestum credential acquired (fingerprint ${FINGERPRINT}…)"
echo "  did:        ${DID:-<none>}"
echo "  parent vc:  ${PARENT_VC_ID:-<none>}"
echo "  expires at: ${EXPIRES_AT:-<none>}"
