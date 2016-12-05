#!/bin/bash

set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "/tmp/inventory.sh" ]]; then
  echo "WARNING: /tmp/inventory.sh does not exist, run the provision playbook to create it" 1>&2
  echo "{}"
  exit 0
fi

source "/tmp/inventory.sh"
exec ${src}/inventory/gce/hosts/gce.py
