#!/bin/bash

set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "/tmp/inventory.sh" ]]; then
  if ! ansible-playbook ${INVENTORY_ARGS-} --inventory-file "${src}/inventory/empty.json" ${src}/playbooks/inventory.yaml 1>&2; then
    echo "{}"
    exit 1
  fi
fi
source "/tmp/inventory.sh"
exec ${src}/inventory/gce/hosts/gce.py
