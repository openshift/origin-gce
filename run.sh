#!/bin/bash

#
# Run the playbook using the default directory and contents.
#
set -euo pipefail

# meta refresh_inventory has a bug in 2.2.0 where it uses relative path
# remove when fixed
export ANSIBLE_INVENTORY=$(pwd)/inventory.sh

CONTEXT_DIR="${CONTEXT_DIR:-/usr/local/install/data}"
ansible-playbook -e "install_var=${CONTEXT_DIR}/ansible-config.yml" "$@"
