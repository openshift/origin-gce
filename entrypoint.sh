#!/bin/bash

#
# Used as the entrypoint for the installer image. Must be kept in sync
# with the directories in that file.
#
export PATH=/usr/local/install/google-cloud-sdk/bin:$PATH
export CONTEXT_DIR=/usr/local/install/data

if [[ -n "${OPENSHIFT_ANSIBLE_COMMIT-}" ]]; then
  pushd /usr/share/ansible/openshift-ansible &>/dev/null
  git checkout "${OPENSHIFT_ANSIBLE_COMMIT}" || git fetch origin && git checkout "${OPENSHIFT_ANSIBLE_COMMIT}"
  popd &>/dev/null
fi

gcloud auth activate-service-account --key-file=/usr/local/install/data/gce.json
exec "$@"
