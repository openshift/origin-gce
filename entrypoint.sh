#!/bin/bash

#
# Used as the entrypoint for the installer image. Must be kept in sync
# with the directories in that file.
#
export PATH=/usr/local/install/google-cloud-sdk/bin:$PATH
export CONTEXT_DIR=/usr/local/install/data
gcloud auth activate-service-account --key-file=/usr/local/install/data/gce.json
source "${CONTEXT_DIR}/inventory.sh"
exec "$@"
