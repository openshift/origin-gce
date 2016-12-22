#!/bin/bash

#
# Run the playbook using the default directory and contents.
#
set -euo pipefail

CONTEXT_DIR="${CONTEXT_DIR:-/usr/local/install/data}"
ansible-playbook -e "install_var=${CONTEXT_DIR}/ansible-config.yml" "$@"
