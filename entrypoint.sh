#!/bin/bash

#
# Used as the entrypoint for the installer image. Must be kept in sync
# with the directories in that file.
#
export PATH=$HOME/google-cloud-sdk/bin:$PATH

# When running with an invalid user, correct it by adding cloud-user (also
# part of the image definition). Ansible requires getpwnam() to start.
# Also set the default to localhost to become: no to avoid the need to
# sudo.
if ! whoami &>/dev/null; then
  echo "cloud-user$(id -u):x:$(id -u):0:cloud-user:$HOME:/sbin/nologin" >> /etc/passwd
  mkdir -p "${WORK}/inventory/host_vars/localhost"
  echo "ansible_become: no" > "${WORK}/inventory/host_vars/localhost/00_skip_root.yaml"

  # SSH requires the file to be owned by the current user, but Docker copies
  # files in as root. Remove the file and recreate it.
  keyfile="${HOME}/.ssh/google_compute_engine"
  if key=$( cat "${keyfile}" ); then
    rm -f "${keyfile}"
    echo "${key}" > "${keyfile}"
    chmod 0600 "${keyfile}"
  fi
fi

find "${WORK}/playbooks/files" | xargs -L1 -I {} ln -fs {} "${WORK}/inventory/"
find "${WORK}/playbooks/files" -name *.yaml -or -name vars | xargs -L1 -I {} ln -fs {} "${WORK}/inventory/group_vars/all"

if [[ -n "${OPENSHIFT_ANSIBLE_COMMIT-}" ]]; then
  pushd /usr/share/ansible/openshift-ansible &>/dev/null
  git checkout "${OPENSHIFT_ANSIBLE_COMMIT}" || ( git fetch origin && git checkout "${OPENSHIFT_ANSIBLE_COMMIT}" )
  popd &>/dev/null
fi

gcloud auth activate-service-account --key-file="${WORK}/playbooks/files/gce.json"

exec "$@"
