#!/bin/bash

# MIT License
#
# Copyright (c) 2016 Peter Schiffer <pschiffe@redhat.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

#
# Script to install a cluster.
#

set -euo pipefail

CONTEXT_DIR="${CONTEXT_DIR:-/usr/local/install/data}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${src}"

# Support the revert option
if [ "${1:-}" = '--revert' ]; then
    shift
    ansible-playbook -e "install_var=${CONTEXT_DIR}/ansible-config.yml" "$@" "playbooks/deprovision.yaml"
    exit 0
fi

ansible-playbook -e "install_var=${CONTEXT_DIR}/ansible-config.yml" "$@" "playbooks/provision.yaml"
ansible-playbook -e "install_var=${CONTEXT_DIR}/ansible-config.yml" "$@" "playbooks/install.yaml"
