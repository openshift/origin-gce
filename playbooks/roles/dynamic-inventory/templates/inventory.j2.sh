#!/bin/sh

export GCE_PROJECT="{{ gce_project_id }}"
export GCE_ZONE="{{ gce_zone_name }}"
export GCE_EMAIL="{{ (lookup('file', playbook_dir + '/files/' + gce_service_account_keyfile ) | from_json ).client_email }}"
export GCE_PEM_FILE_PATH="/tmp/gce.pem"
export INVENTORY_IP_TYPE="{{ inventory_ip_type }}"
export GCE_TAGGED_INSTANCES="{{ provision_prefix }}ocp"