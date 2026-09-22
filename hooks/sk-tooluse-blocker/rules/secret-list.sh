#!/usr/bin/env bash
#
# rules/secret-list.sh — the secret-file list and its allowlists: the ONLY
# place a name is written. rules/secret.sh builds every matcher from these
# arrays, and deny-rules.sh prints the permissions.deny rules from them, so
# both read this file and nothing else. Sourced by hook.sh before
# rules/secret.sh; defines constants and three allowlist functions only.

# ---------------------------------------------------------------------------
# The allowlist — checked first, so it wins over every rule below.
#
# These are the standard names a certificate toolchain gives the PUBLIC half of
# a TLS pair (Let's Encrypt and friends). They are not secrets, and .pem covers
# both halves, so without this list all TLS work would be unreachable.
# privkey.pem and every other *.pem stay blocked.
# ---------------------------------------------------------------------------
is_public_cert() {
  case "$1" in
    cert.pem|fullchain.pem|chain.pem|ca.pem|cacert.pem|ca-bundle.pem) return 0 ;;
  esac
  return 1
}

# "env" is also an extension (prod.env, staging.env). In a command string the
# same shape names a JavaScript object, not a file: process.env,
# import.meta.env. Those are filtered out of the matches, like the public
# certificate names above. "process.env.FOO" never matches at all — the regex
# wants a boundary after the extension, and "." is not one.
is_env_object() {
  case "$1" in
    process.env|import.meta.env|meta.env|Deno.env|Bun.env) return 0 ;;
  esac
  return 1
}

# Template files. Exempt for WRITE tools only — see the dispatch below.
is_example_name() {
  case "$1" in
    *.example|*.sample|*.template) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# The secret-file list — one list, shared by every rule below.
#
# The bar for an entry: the filename on its own is near-certain to mean a
# secret. Deliberately out of scope for that reason: .envrc, .environment,
# terraform.tfvars, secrets.* — each is ordinary config often enough that
# adding it would buy coverage with daily friction.
#
# id_rsa.pub is not matched: the entries are exact, so the public half is free.
#
# Matching is case-insensitive throughout. macOS APFS is case-insensitive by
# default, so ".ENV" and ".SSH/ID_RSA" open the real files. secret_check in
# rules/secret.sh sets nocasematch once around the dispatch; no matcher here
# or there toggles it itself.
# ---------------------------------------------------------------------------
# The list itself — the ONLY place a name is written. Everything else (the
# basename matcher, the glob tokens, the two command-string regexes) is built
# from these three arrays when the file loads.
#
#   SECRET_NAMES     exact basenames
#   SECRET_FAMILIES  exact basenames that also cover "<name>.<anything>"
#   SECRET_EXTS      extensions: "<stem>.<ext>"
SECRET_NAMES=(
  credentials .git-credentials
  .netrc _netrc .npmrc .pypirc .htpasswd
  id_rsa id_ed25519 id_ecdsa id_dsa
)
SECRET_FAMILIES=(.env .dev.vars)
SECRET_EXTS=(pem key p12 pfx jks keystore env)

# Extensions that is_public_cert carves an allowlist into. The hook can block
# the family and still let the public names through; a permissions.deny rule
# cannot — it has no exception — so deny-rules.sh leaves these extensions out.
SECRET_EXTS_ALLOWLISTED=(pem)

# A bare name that is ordinary prose in a command string ("grep -rn credentials
# src/" must keep working). In a command it only counts under this directory.
SECRET_PROSE_NAME=credentials
SECRET_PROSE_ANCHOR=.aws/
