#!/bin/bash

set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! out="$( ansible-playbook --inventory-file "${src}/inventory/empty.json" ${src}/playbooks/inventory.yaml 2>&1 )"; then
  echo "error: Inventory configuration failed" 1>&2
  echo "$out" 1>&2
  echo "{}"
  exit 1
fi
source "/tmp/inventory.sh"
exec ${src}/inventory/gce/hosts/gce.py
