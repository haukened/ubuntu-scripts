#! /usr/bin/env bash
set -euo pipefail

# Configuration (allow overrides via env vars)
readonly PRO_TOKEN="${PRO_TOKEN:-token_not_set}"
readonly JOIN_TOKEN="${JOIN_TOKEN:-}"
readonly LANDSCAPE_HOST="${LANDSCAPE_HOST:-}"
readonly TAGS="${TAGS:-}"
readonly SCRIPT_USERS="${SCRIPT_USERS:-}"
readonly ACCOUNT_NAME="${ACCOUNT_NAME:-standalone}"

# must run as root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: please run as root (sudo)." >&2
    exit 1
fi

# Validate token is provided
if [ "$PRO_TOKEN" = "token_not_set" ] || [ -z "$PRO_TOKEN" ]; then
    echo "Error: PRO_TOKEN is not set. Export PRO_TOKEN in the environment and re-run." >&2
    exit 1
fi

# Basic command checks
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: required command '$1' not found." >&2; exit 1; }; }

# Ensure apt exists (Ubuntu/Debian)
require_cmd apt

echo "installing required dependencies..."
DEBIAN_FRONTEND=noninteractive apt -yq update
DEBIAN_FRONTEND=noninteractive apt -yq install ubuntu-advantage-tools jq bc

# Ensure tools we rely on are now present
require_cmd pro
require_cmd jq
require_cmd bc
require_cmd lsb_release
require_cmd hostname

# determine the ubuntu version
UBUNTU_VERSION=$(lsb_release -rs)
echo "Detected Ubuntu version: $UBUNTU_VERSION"

# die if we aren't at least 18.04
if [ "$(echo "$UBUNTU_VERSION < 18.04" | bc)" -eq 1 ]; then
    echo "Error: Ubuntu version 18.04 or newer is required." >&2
    echo "You should upgrade your Ubuntu installation." >&2
    exit 1
fi

# determine installation method
# landscape pro install method for 24.04 and newer
if [ "$(echo "$UBUNTU_VERSION >= 24.04" | bc)" -eq 1 ]; then
    METHOD="PRO"
else
    METHOD="APT"
fi
echo "Using installation method: $METHOD"

# pro install method for 24.04
install_with_pro() {
  ## now check if landscape service is enabled
  LANDSCAPE_ENABLED=$(pro status --format=json | jq -r 'try (.services[] | select(.name=="landscape") | .status) // empty')

  if [ "$LANDSCAPE_ENABLED" = "enabled" ]; then
      echo "Ubuntu Pro Landscape service is already enabled."
  else
      echo "Enabling Ubuntu Pro Landscape service..."
      DEBIAN_FRONTEND=noninteractive pro enable landscape --assume-yes
      echo "Landscape service enabled."
  fi

  # Ensure landscape client is available after enabling service
  if ! command -v landscape-config >/dev/null 2>&1; then
      # On some systems the client is provided by landscape-client
      DEBIAN_FRONTEND=noninteractive apt-get -yq install landscape-client || true
  fi
}

# apt install method for 22.04 and earlier
install_with_apt() {
  ## now check if landscape service is enabled
  LANDSCAPE_ENABLED=$(apt-cache policy landscape-client | grep -m 1 'Installed: (none)' || true)

  if [ -z "$LANDSCAPE_ENABLED" ]; then
      echo "Ubuntu Pro Landscape client is already installed."
  else
      echo "Installing Ubuntu Landscape client..."
      DEBIAN_FRONTEND=noninteractive apt-get -yq install landscape-client
      echo "Landscape client installed."
  fi
}

## check if pro is already enabled
PRO_ENABLED=$(pro status --format=json | jq -r 'try .attached // empty')
if [ "$PRO_ENABLED" = "true" ]; then
    echo "Ubuntu Pro is already attached."
else
    echo "Attaching Ubuntu Pro..."
    # Note: passing tokens via CLI can appear in process lists on the system while running.
    pro attach "$PRO_TOKEN"
    echo "Ubuntu Pro has been attached."
fi

# install the landscape-client
if [ "$METHOD" = "PRO" ]; then
    install_with_pro
else
    install_with_apt
fi

# ensure landscape client was installed
require_cmd landscape-config

# configure the landscape client
echo "Configuring Landscape client..."
join_args=()
if [ -n "$JOIN_TOKEN" ]; then
    join_args=( -p "$JOIN_TOKEN" )
fi

tags_args=()
if [ -n "$TAGS" ]; then
    tags_args=( --tags "$TAGS" )
fi

script_users_args=()
if [ -n "$SCRIPT_USERS" ]; then
    script_users_args=( --script-users "$SCRIPT_USERS" )
fi

# Optional Landscape host; omit flags if not provided
url_args=()
if [ -n "$LANDSCAPE_HOST" ]; then
    url_args=( \
        --url "https://$LANDSCAPE_HOST/message-system" \
        --ping-url "https://$LANDSCAPE_HOST/ping" \
    )
fi

landscape-config \
    --computer-title "$(hostname)" \
    --account-name "$ACCOUNT_NAME" \
    "${url_args[@]}" \
    "${script_users_args[@]}" \
    "${join_args[@]}" \
    "${tags_args[@]}" \
    --silent

# Restart client to pick up new config
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart landscape-client || true
else
    service landscape-client restart || true
fi

echo "Done. Landscape client configured and restarted."