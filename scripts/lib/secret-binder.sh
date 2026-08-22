#!/usr/bin/env bash
# Secret-binder (ADR-035): wires a tenant's Cloudflare Secrets Store secrets
# into a Worker's wrangler config as [[secrets_store_secrets]] bindings.
# Bind-only — the provisioner never reads plaintext; bindings reference the
# store id + secret NAME, so the emitted block is committed and reviewable.
# Sourced by deploy scripts (same pattern as tier-installer.sh): functions
# only, callers own set -uo pipefail, errors on stderr, fail HARD — a deploy
# missing its secret bindings must not continue.

# Hardcoded on purpose: the bearer token is sent to this host, so it must
# not be redirectable via env. Tests mock cf_api_get itself, not the base.
CF_API_BASE="https://api.cloudflare.com/client/v4"

# The ONLY function that talks to the CF API (plan §6.3: isolate the beta-era
# API surface to one place; tests override this function to serve fixtures).
# Token comes from $CF_API_TOKEN via a --config stdin file — never on argv.
# xtrace is suppressed around the token-bearing lines so a caller's set -x
# cannot echo plaintext to logs (same rationale as openai-review.sh).
cf_api_get() {
  local path="$1"
  local had_xtrace=0
  [[ $- == *x* ]] && had_xtrace=1
  { set +x; } 2>/dev/null
  printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" \
    | curl -sS --config - "${CF_API_BASE}${path}"
  local rc=$?
  [[ "$had_xtrace" == 1 ]] && set -x
  return $rc
}

# Resolution order for the tenant API token (plan §2 — the store copy is for
# the running Worker; the provisioner holds its own separately-saved copy):
# env <TENANT>_API_TOKEN, then macOS Keychain, then fail with the exact
# command to run. Sets CF_API_TOKEN; prints nothing. xtrace suppressed —
# every branch here touches a plaintext token.
resolve_tenant_token() {
  local tenant_id="$1"
  local keychain_item="$2"
  local had_xtrace=0
  [[ $- == *x* ]] && had_xtrace=1
  { set +x; } 2>/dev/null

  # Keychain item names are operator-facing (pasted into security(1) calls)
  # and tenant-supplied — hold them to a safe charset.
  if [[ -n "$keychain_item" && ! "$keychain_item" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "    [bind-fail] api_token_keychain_item has unsafe characters: $keychain_item" >&2
    [[ "$had_xtrace" == 1 ]] && set -x
    return 1
  fi

  local env_name
  env_name="$(echo "$tenant_id" | tr 'a-z-' 'A-Z_')_API_TOKEN"
  if [[ -n "${!env_name:-}" ]]; then
    CF_API_TOKEN="${!env_name}"
    [[ "$had_xtrace" == 1 ]] && set -x
    return 0
  fi

  if [[ -n "$keychain_item" ]]; then
    local from_keychain
    from_keychain="$(security find-generic-password -s "$keychain_item" -w 2>/dev/null || echo "")"
    if [[ -n "$from_keychain" ]]; then
      CF_API_TOKEN="$from_keychain"
      [[ "$had_xtrace" == 1 ]] && set -x
      return 0
    fi
  fi

  echo "    [requirement-fail] No token for tenant '$tenant_id': env $env_name unset and Keychain item '${keychain_item:-<none configured>}' missing" >&2
  echo "    Add with: security add-generic-password -s '${keychain_item:-${tenant_id}-cf-api-token}' -a \"\$USER\" -w '<token>' -U" >&2
  [[ "$had_xtrace" == 1 ]] && set -x
  return 1
}

# Resolve the tenant's Secrets Store id from the ACCOUNT id, always live.
# NEVER accept a store id from config — ADR-035 gotcha: account id and store
# id are distinct 32-hex values, and a store id in the accounts/{id} slot
# returns a misleading 10000 auth error, not a 404.
resolve_store_id() {
  local account_id="$1"

  local resp
  resp="$(cf_api_get "/accounts/$account_id/secrets_store/stores")" || {
    echo "  [bind-fail] list-stores request failed for account $account_id" >&2
    return 1
  }

  if jq -e '.errors[]? | select(.code == 10000)' <<<"$resp" >/dev/null 2>&1; then
    echo "  [bind-fail] 10000 Authentication error from list-stores. Two known causes:" >&2
    echo "    - '$account_id' is not the ACCOUNT id (a Secrets Store id in the accounts/{id} slot returns this misleading error, not a 404 — ADR-035)" >&2
    echo "    - token lacks the explicit 'Secrets Store: Read' account permission (not in default hosting scopes)" >&2
    return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    echo "  [bind-fail] list-stores error: $(jq -c '.errors // "unparseable response"' <<<"$resp" 2>/dev/null)" >&2
    return 1
  fi

  local count
  count="$(jq '.result | length' <<<"$resp")" || return 1
  if [[ "$count" -eq 0 ]]; then
    echo "  [bind-fail] No Secrets Store found in account $account_id" >&2
    return 1
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "  [bind-fail] $count Secrets Stores in account $account_id — ambiguous, refusing to guess (plan §6.4). Stores:" >&2
    jq -r '.result[] | "    \(.id)  \(.name // "")"' <<<"$resp" >&2
    return 1
  fi

  local store_id
  store_id="$(jq -r '.result[0].id' <<<"$resp")" || return 1
  # Defense-in-depth: this id is interpolated into a follow-up API URL and
  # into the emitted wrangler TOML — validate the shape before either use,
  # even though it came from the CF API rather than tenant.json.
  if [[ ! "$store_id" =~ ^[0-9a-f]{32}$ ]]; then
    echo "  [bind-fail] Secrets Store id from the CF API is not a 32-hex id: ${store_id:0:40}" >&2
    return 1
  fi
  echo "$store_id"
}

# Preflight gate: every expected name must exist in the store. The name→id
# resolution is validation only — the wrangler binding references the NAME.
# All misses reported, not first-fail. 'pending' status is NOT a failure
# (secrets show Pending until first bound).
resolve_secret_names() {
  local account_id="$1"
  local store_id="$2"
  shift 2

  local page=1 existing="" resp total_pages
  while :; do
    resp="$(cf_api_get "/accounts/$account_id/secrets_store/stores/$store_id/secrets?page=$page&per_page=100")" || {
      echo "  [bind-fail] list-secrets request failed (page $page)" >&2
      return 1
    }
    if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
      echo "  [bind-fail] list-secrets error: $(jq -c '.errors // "unparseable response"' <<<"$resp" 2>/dev/null)" >&2
      return 1
    fi
    existing+="$(jq -r '.result[]?.name' <<<"$resp")"$'\n'
    total_pages="$(jq -r '.result_info.total_pages // 1' <<<"$resp")"
    [[ "$page" -ge "$total_pages" ]] && break
    page=$((page + 1))
  done

  local name missing=0
  for name in "$@"; do
    if ! grep -qxF "$name" <<<"$existing"; then
      echo "  [bind-fail] Secret '$name' not found in store $store_id" >&2
      missing=$((missing + 1))
    fi
  done
  [[ "$missing" -gt 0 ]] && return 1
  return 0
}

# Pure function, no API calls: the [[secrets_store_secrets]] block on stdout.
# binding = secret_name = the tenant-prefixed name (one name, one identifier,
# no aliasing — the Worker reads env.<NAME>).
emit_secret_bindings() {
  local store_id="$1"
  shift

  local name
  for name in "$@"; do
    cat <<EOF
[[secrets_store_secrets]]
binding = "$name"
store_id = "$store_id"
secret_name = "$name"

EOF
  done
}

# Device id of a path. rename(2) — the atomicity the splice depends on — is
# only defined within a single filesystem, so the splice has to know whether
# its scratch dir and the target share one. GNU stat wants -c, BSD stat
# wants -f; the GNU form is tried first and short-circuits on success.
# Overridden by tests to exercise the cross-filesystem branch.
_secret_binder_device_of() {
  stat -c '%d' -- "$1" 2>/dev/null || stat -f '%d' -- "$1" 2>/dev/null
}

# Cleanup for the splice subshell below. Covers normal return and INT/TERM/
# HUP. SIGKILL is untrappable by definition, so this is never the last line
# of defence — that is why the scratch file lives outside the tenant's
# checkout in the first place, and why the pin is dropped the moment the
# reads finish rather than being left to the trap.
_secret_binder_cleanup() {
  if [[ -n "${_sb_pin:-}" ]]; then
    rm -f -- "$_sb_pin"
  fi
  if [[ -n "${_sb_stage:-}" ]]; then
    rm -f -- "$_sb_stage"
  fi
  if [[ -n "${_sb_scratch:-}" ]]; then
    rm -rf -- "$_sb_scratch"
  fi
  return 0
}

# Idempotent marker-region splice (TOML-comment twin of append_stack_section).
# Runs its body in a subshell so the cleanup trap cannot clobber a caller's
# own traps — this lib is sourced, and callers own their signal handling.
replace_secrets_region() {
  (
    _sb_pin=""
    _sb_stage=""
    _sb_scratch=""
    trap '_secret_binder_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    _secret_binder_splice "$1" "$2"
  )
}

_secret_binder_splice() {
  local content_file="$1"
  local target="$2"

  local marker="# STACK_SECRETS_MANAGED"
  local end_marker="# /STACK_SECRETS_MANAGED"

  local target_dir
  target_dir="$(dirname -- "$target")"

  # Private scratch dir, deliberately NOT inside the tenant's checkout. The
  # scratch file holds the fully spliced wrangler.toml, so a SIGKILL
  # mid-splice used to strand a .stack_secrets.XXXXXX in the tenant's repo —
  # a secrets-shaped artifact sitting where a later `git add .` or archive
  # would sweep it up. SIGKILL cannot be trapped, so no cleanup handler can
  # fix that; only not putting the file there can. mktemp -d gives 0700.
  _sb_scratch="$(mktemp -d "${TMPDIR:-/tmp}/stack-secret-binder.XXXXXX")" || return 1

  # ...but rename(2) is atomic only within one filesystem, and the splice
  # relies on that atomicity: a half-written target must never surface with
  # an unclosed managed region. $TMPDIR is frequently a different filesystem
  # from the checkout (tmpfs /tmp is the common case), where `mv` silently
  # degrades from a rename into a copy. So the scratch dir is used directly
  # only when it shares the target's filesystem; otherwise the install below
  # stages the rename inside the target's directory instead.
  local same_fs=0
  if [[ "$(_secret_binder_device_of "$_sb_scratch")" == "$(_secret_binder_device_of "$target_dir")" ]]; then
    same_fs=1
  fi

  # Pin the target's INODE before inspecting it, and read only the pin.
  #
  # `[[ -L $target ]]` followed by a separate cat/grep/awk of "$target"
  # resolves the path twice: the guard describes whatever the path named at
  # check time, the reads consume whatever it names at read time. A
  # concurrent writer that swaps a symlink into that gap makes the guard
  # describe one object while the reads disclose another — an arbitrary
  # local file spliced into the committed TOML. No ordering of a
  # check-then-use pair closes that gap; only removing the second path
  # resolution does.
  #
  # `ln -P` links the symbolic link ITSELF rather than its referent, so the
  # pin is a second name for exactly what "$target" named at that instant,
  # in a directory entry nobody else can redirect. A symlinked target
  # therefore yields a symlinked pin, which -L catches for certain, and
  # every read below sees the same object the guard passed on.
  #
  # A hard link cannot cross filesystems, so the pin lives in the scratch dir
  # (outside the checkout, and unguessable because the dir is ours and 0700)
  # whenever that shares the target's filesystem, and only falls back into
  # the target's own directory when it does not.
  local read_src=""
  local pin_path
  if [[ "$same_fs" == 1 ]]; then
    pin_path="$_sb_scratch/pin"
  else
    pin_path="$(mktemp -u "${target_dir}/.stack_binder_pin.XXXXXX")" || return 1
  fi
  if ln -P -- "$target" "$pin_path" 2>/dev/null; then
    _sb_pin="$pin_path"
    if [[ -L "$_sb_pin" ]]; then
      echo "  [bind-fail] $target is a symlink — refusing to read/write through it" >&2
      return 1
    fi
    if [[ ! -f "$_sb_pin" ]]; then
      echo "  [bind-fail] $target exists and is not a regular file" >&2
      return 1
    fi
    read_src="$_sb_pin"
  elif [[ -e "$target" || -L "$target" ]]; then
    # Present but unpinnable: a directory, a special file, or a symlink on a
    # filesystem that refuses hard links to symlinks. Refuse — reading the
    # path instead would put the race straight back.
    echo "  [bind-fail] $target exists but could not be pinned for a race-free read — refusing (not a regular file, or a symlink that cannot be hard-linked)" >&2
    return 1
  fi
  # An empty read_src means the target does not exist yet; the create branch
  # below handles that. Still no pre-emptive touch: touching through a
  # dangling symlink would create the file at the resolved path before any
  # guard runs. The install below is a rename, which replaces a symlink
  # rather than writing through it.

  # Build into the private scratch dir. The `--` on every mv below stops
  # "$target" from being parsed as an option if it ever started with a dash.
  #
  # The install is a rename, so the target inherits the scratch file's mode.
  # Created explicitly at 0600 — the mode mktemp gave the in-directory temp
  # this replaced. A plain `>` redirect would be 0644-minus-umask, which
  # would have this hardening pass hand back a MORE permissive wrangler.toml
  # than before. The staged copy on the cross-filesystem path below comes
  # from mktemp and is already 0600.
  local tmp="$_sb_scratch/next"
  : > "$tmp" || return 1
  chmod 600 "$tmp" || return 1

  if [[ -n "$read_src" ]] && grep -qxF "$marker" "$read_src"; then
    # Exactly one well-ordered pair — duplicate, missing, or out-of-order
    # markers would make the awk state machine silently drop real config.
    local starts ends start_line end_line
    starts="$(grep -cxF "$marker" "$read_src")"
    ends="$(grep -cxF "$end_marker" "$read_src")"
    start_line="$(grep -nxF "$marker" "$read_src" | head -1 | cut -d: -f1)"
    end_line="$(grep -nxF "$end_marker" "$read_src" | head -1 | cut -d: -f1)"
    if [[ "$starts" != 1 || "$ends" != 1 || "$start_line" -ge "${end_line:-0}" ]]; then
      echo "  [bind-fail] $target has a malformed STACK_SECRETS_MANAGED region (need exactly one start/end pair, start before end)" >&2
      return 1
    fi
    awk -v source="$content_file" -v marker="$marker" -v end_marker="$end_marker" '
      BEGIN { in_section = 0 }
      $0 == end_marker { in_section = 0; print; next }
      $0 == marker { in_section = 1; print; while ((getline line < source) > 0) print line; next }
      !in_section { print }
    ' "$read_src" > "$tmp" || return 1
  else
    # Build-to-temp then atomic mv — a mid-write failure must not leave an
    # unclosed managed region in the committed config.
    {
      [[ -n "$read_src" ]] && cat -- "$read_src"
      echo ""
      echo "$marker"
      cat "$content_file"
      echo "$end_marker"
    } > "$tmp" || return 1
  fi

  # Reads are finished: drop the pin now rather than at trap time, so the
  # install below runs with nothing extra of ours in the target's directory.
  if [[ -n "$_sb_pin" ]]; then
    rm -f -- "$_sb_pin"
    _sb_pin=""
  fi

  # Install. rename(2) both gives the atomic swap and refuses to follow a
  # symlink at the destination, so it replaces a symlinked target rather
  # than writing through it.
  if [[ "$same_fs" == 1 ]]; then
    mv -- "$tmp" "$target" || return 1
    return 0
  fi

  # Cross-filesystem: `mv` straight from the scratch dir would be a copy,
  # not a rename, and would expose a partially written target. Stage a
  # same-directory copy — the one and only thing that transits the tenant's
  # checkout, and only on this path — and rename that. Registered for
  # cleanup, though a SIGKILL between mktemp and the assignment is
  # unavoidable here; atomicity wins that trade.
  _sb_stage="$(mktemp "${target_dir}/.stack_secrets.XXXXXX")" || return 1
  cat -- "$tmp" > "$_sb_stage" || return 1
  mv -- "$_sb_stage" "$target" || return 1
  _sb_stage=""
}

# Orchestrator — the only entrypoint deploy scripts call.
#   bind_tenant_secrets <tenant_json_path> <wrangler_toml_path>
bind_tenant_secrets() {
  local tenant_json="$1"
  local wrangler_toml="$2"

  if ! jq -e . "$tenant_json" >/dev/null 2>&1; then
    echo "  [bind-fail] tenant.json missing or unparseable: $tenant_json" >&2
    return 1
  fi

  local tenant_id account_id keychain_item
  tenant_id="$(jq -r '.tenant_id // empty' "$tenant_json")"
  account_id="$(jq -r '.deploy.cloudflare.account_id // empty' "$tenant_json")"
  keychain_item="$(jq -r '.deploy.cloudflare.api_token_keychain_item // empty' "$tenant_json")"

  # Defense-in-depth: re-assert the schema patterns at runtime — these values
  # feed env-var construction, URL paths, and Keychain lookups, and callers
  # may not have schema-validated the file.
  if [[ ! "$tenant_id" =~ ^[a-z][a-z0-9-]{1,62}$ ]]; then
    echo "  [bind-fail] tenant.json tenant_id missing or invalid" >&2
    return 1
  fi

  # .secrets must be an array — a malformed field must fail closed, never
  # read as "no secrets declared" (that would be a silent zero-bindings
  # deploy). Explicitly empty [] is the only legitimate no-op.
  if ! jq -e 'has("secrets") and (.secrets | type == "array")' "$tenant_json" >/dev/null 2>&1; then
    echo "  [bind-fail] tenant.json is missing .secrets or .secrets is not an array — refusing to treat as empty (declare \"secrets\": [] explicitly for a tenant with none)" >&2
    return 1
  fi

  local -a names=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && names+=("$line")
  done < <(jq -r '(.secrets // [])[]' "$tenant_json")

  if [[ "${#names[@]}" -eq 0 ]]; then
    echo "  [bind] No secrets declared for tenant '$tenant_id' — nothing to bind."
    return 0
  fi

  if [[ ! "$account_id" =~ ^[0-9a-f]{32}$ ]]; then
    echo "  [bind-fail] tenant.json declares secrets but deploy.cloudflare.account_id is missing or not a 32-hex account id" >&2
    return 1
  fi

  # Names are interpolated into TOML string literals and API URLs: enforce
  # the schema charset (^[A-Z][A-Z0-9_]*$) — blocks quote/newline breakout —
  # AND the tenant prefix (ADR-034/035 convention).
  local prefix name
  prefix="$(echo "$tenant_id" | tr 'a-z-' 'A-Z_')_"
  for name in "${names[@]}"; do
    if [[ ! "$name" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      echo "  [bind-fail] Secret name has unsafe characters (must match ^[A-Z][A-Z0-9_]*\$): ${name:0:40}" >&2
      return 1
    fi
    if [[ "$name" != "$prefix"* ]]; then
      echo "  [bind-fail] Secret '$name' does not carry the tenant prefix '$prefix'" >&2
      return 1
    fi
  done

  resolve_tenant_token "$tenant_id" "$keychain_item" || return 1

  local store_id
  store_id="$(resolve_store_id "$account_id")" || return 1

  resolve_secret_names "$account_id" "$store_id" "${names[@]}" || return 1

  local block
  block="$(mktemp)" || return 1
  emit_secret_bindings "$store_id" "${names[@]}" > "$block" || { rm -f "$block"; return 1; }
  # No pre-emptive touch here on purpose: touching through a dangling
  # symlink would create the file at the resolved target path before
  # replace_secrets_region's symlink guard ever runs. It handles a
  # not-yet-existing target itself.
  replace_secrets_region "$block" "$wrangler_toml" || { rm -f "$block"; return 1; }
  rm -f "$block"

  echo "  [bind] ${#names[@]} secret binding(s) for tenant '$tenant_id' written to $wrangler_toml"
}
