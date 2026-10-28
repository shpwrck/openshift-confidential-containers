# shellcheck shell=bash
# Sets up a terminal for the guides. From the checkout root, in every new terminal:
#
#   source scripts/env.sh
#
# The first run also builds the controller: a Python environment, the pinned
# OpenShift CLIs (oc-mirror runs only on the helper, so the controller goes
# without it), and the Cherry Servers API key, asked for once and kept in
# COCO_STATE_DIR. The build runs again when the requirements or the release
# manifest change. Later runs only set the variables, so they take a second.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "ERROR: source scripts/env.sh from bash" >&2
  return 2
fi
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "ERROR: source this file instead of running it: source scripts/env.sh" >&2
  exit 2
fi

coco_env() {
  local repo state stamp key key_file status
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || return 1
  umask 077
  if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
    echo "ERROR: the controller needs Python 3.12 or later as python3" >&2
    return 2
  fi
  export COCO_STATE_DIR="${COCO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openshift-confidential-containers}"
  # Generated state holds credentials, so it must stay outside the checkout.
  state="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$COCO_STATE_DIR")" || return 1
  if [[ "$state" == "$repo" || "$state" == "$repo"/* ]]; then
    echo "ERROR: COCO_STATE_DIR ($COCO_STATE_DIR) is inside the checkout; choose a directory outside it" >&2
    return 2
  fi
  mkdir -p "$COCO_STATE_DIR" || return 1
  local missing=() tool
  for tool in curl jq make ssh ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} )); then
    echo "ERROR: install these first: ${missing[*]}" >&2
    return 2
  fi

  stamp="$(python3 - "$repo/requirements-dev.txt" "$repo/install/release-manifest.json" <<'PY'
import hashlib, sys
digest = hashlib.sha256()
for path in sys.argv[1:]:
    digest.update(open(path, 'rb').read())
print(digest.hexdigest())
PY
)" || return 1
  if [[ ! -x "$COCO_STATE_DIR/controller-venv/bin/python3" ]]; then
    python3 -m venv "$COCO_STATE_DIR/controller-venv" || return 1
  fi
  # shellcheck source=/dev/null
  source "$COCO_STATE_DIR/controller-venv/bin/activate" || return 1
  if [[ "$(cat "$COCO_STATE_DIR/.controller-ready" 2>/dev/null)" != "$stamp" ]]; then
    echo "== Setting up the controller in $COCO_STATE_DIR =="
    echo "This runs on the first use and after the requirements or the release change."
    echo
    python3 -m pip install --quiet --disable-pip-version-check -r "$repo/requirements-dev.txt" || return 1
    make -C "$repo" --no-print-directory preflight || return 1
    INSTALL_OC_MIRROR=0 make -C "$repo" --no-print-directory fetch-cli-tools || return 1
    printf '%s\n' "$stamp" > "$COCO_STATE_DIR/.controller-ready"
    echo
  fi
  case ":$PATH:" in
    *":$COCO_STATE_DIR/bin:"*) ;;
    *) export PATH="$COCO_STATE_DIR/bin:$PATH" ;;
  esac

  key_file="$COCO_STATE_DIR/cherry-api-key"
  if [[ ! -s "$key_file" && -t 0 ]]; then
    echo "Cherry Servers API key (create one at https://portal.cherryservers.com/settings/api-keys)."
    echo "It is saved in $key_file, readable only by you. Press Enter to skip."
    echo
    read -rsp "API key: " key
    echo
    if [[ -n "$key" ]]; then
      # The key goes to curl on stdin, so it never appears in the process list.
      status="$(printf 'header = "Authorization: Bearer %s"\n' "$key" |
        curl -sS -K - -o /dev/null -w '%{http_code}' --max-time 30 https://api.cherryservers.com/v1/teams)" || status=000
      case "$status" in
        200) printf '%s\n' "$key" > "$key_file" && echo "Key checked and saved." ;;
        401|403) echo "Cherry Servers refused the key (HTTP $status); nothing was saved. Source this file again to retry." >&2 ;;
        *) echo "Could not check the key (HTTP $status); nothing was saved. Source this file again to retry." >&2 ;;
      esac
    fi
    key=""
  fi
  if [[ -s "$key_file" ]]; then
    CHERRY_SERVERS_API_KEY="$(<"$key_file")"
    # The Cherry Terraform provider reads CHERRY_API_KEY.
    export CHERRY_SERVERS_API_KEY CHERRY_API_KEY="$CHERRY_SERVERS_API_KEY"
  fi
  export TF_DATA_DIR="$COCO_STATE_DIR/terraform"

  # make connect writes lab.env (KUBECONFIG, contexts and lab settings); make
  # trustee-lab writes trustee-lab.env (the capability tests' settings).
  local file
  for file in lab.env trustee-lab.env; do
    if [[ -r "$COCO_STATE_DIR/$file" ]]; then
      # shellcheck source=/dev/null
      source "$COCO_STATE_DIR/$file" || return 1
    fi
  done

  echo "Ready: state in $COCO_STATE_DIR"
  [[ -n "${CHERRY_SERVERS_API_KEY:-}" ]] && echo "  Cherry Servers API key loaded"
  [[ -r "$COCO_STATE_DIR/lab.env" ]] && echo "  Cluster settings loaded from lab.env"
  [[ -r "$COCO_STATE_DIR/trustee-lab.env" ]] && echo "  Capability test settings loaded from trustee-lab.env"
  return 0
}

if coco_env; then
  unset -f coco_env
else
  unset -f coco_env
  false
fi
