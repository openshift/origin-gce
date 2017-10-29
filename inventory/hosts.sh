#!/bin/sh

set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! out="$( ansible-playbook -e "inventory_dir=${src}" --inventory-file "${src}/none" ${src}/../playbooks/inventory.yaml 2>&1 )"; then
  echo "error: Inventory configuration failed" 1>&2
  echo "$out" 1>&2
  echo "{}"
  exit 1
fi
source "/tmp/inventory.sh"
exec ${src}/gce/hosts/gce.py
