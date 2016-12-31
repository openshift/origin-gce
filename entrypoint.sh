#!/bin/bash

#
# Used as the entrypoint for the installer image. Must be kept in sync
# with the directories in that file.
#
export PATH=$HOME/google-cloud-sdk/bin:$PATH

if [[ -n "${OPENSHIFT_ANSIBLE_COMMIT-}" ]]; then
  pushd /usr/share/ansible/openshift-ansible &>/dev/null
  git checkout "${OPENSHIFT_ANSIBLE_COMMIT}" || git fetch origin && git checkout "${OPENSHIFT_ANSIBLE_COMMIT}"
  popd &>/dev/null
fi

# Ansible requires getpwnam() to work, and various modules my default to become: yes
# when they do not need to.
if ! whoami &>/dev/null; then
  echo "cloud-user$(id -u):x:$(id -u):0:cloud-user:/:/sbin/nologin" >> /etc/passwd
  mkdir -p "${WORK}/playbooks/host_vars"
  echo "ansible_become: no" >> "${WORK}/playbooks/host_vars/localhost"
fi

gcloud auth activate-service-account --key-file="${WORK}/playbooks/files/gce.json"

if [[ ! -f "/tmp/inventory.sh" ]]; then
  echo "Initializing inventory ..."
  if ! out="$( ansible-playbook --inventory-file "${WORK}/inventory/empty.json" ${WORK}/playbooks/inventory.yaml 2>&1 )"; then
    echo "error: Inventory configuration failed"
    echo "$out" 1>&2
  fi
fi

exec "$@"
