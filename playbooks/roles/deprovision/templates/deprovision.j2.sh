#!/bin/bash

set -euo pipefail

# Bucket for registry
if gsutil ls -p "{{ gce_project_id }}" "gs://${REGISTRY_BUCKET}" &>/dev/null; then
    gsutil -m rm -r "gs://${REGISTRY_BUCKET}"
fi

function teardown() {
    local name=$1
    shift $@
    if gcloud --project "{{ gce_project_id }}" $@ describe "${name}" &>/dev/null; then
        gcloud --project "{{ gce_project_id }}" $@ delete "${name}"
    fi
}

# DNS
if gcloud --project "{{ gce_project_id }}" dns managed-zones describe "{{ provision_prefix }}managed-zone" &>/dev/null; then
    # Easy way how to delete all records from a zone is to import empty file and specify '--delete-all-existing'
    EMPTY_FILE=$TMPDIR/ocp-dns-records-empty.yml
    touch "$EMPTY_FILE"
    gcloud --project "{{ gce_project_id }}" dns record-sets import "$EMPTY_FILE" -z "{{ provision_prefix }}managed-zone" --delete-all-existing &>/dev/null
    rm -f "$EMPTY_FILE"
fi

(
# Router network rules
teardown "{{ provision_prefix }}router-network-lb-rule" compute forwarding-rules --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}router-network-lb-ip" compute addresses --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}router-network-lb-pool" compute target-pools --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}router-network-lb-pool" compute http-health-checks
) &

(
# Internal master network rules
teardown "{{ provision_prefix }}master-network-lb-rule" compute forwarding-rules --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}master-network-lb-ip" compute addresses --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}master-network-lb-pool" compute target-pools --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}master-network-lb-pool" compute http-health-checks
) &

(
# Master SSL network rules
teardown "{{ provision_prefix }}master-ssl-lb-rule" compute forwarding-rules --global
teardown "{{ provision_prefix }}master-ssl-lb-target" compute target-ssl-proxies
teardown "{{ provision_prefix }}master-ssl-lb-cert" compute ssl-certificates
teardown "{{ provision_prefix }}master-ssl-lb-ip" compute addresses --global
teardown "{{ provision_prefix }}master-ssl-lb-backend" beta compute backend-services --global
teardown "{{ provision_prefix }}master-ssl-lb-health-check" compute health-checks
) &

# Additional disks for instances for docker storage
instances=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter='tags.items:ocp' --format='value(name)')
for i in $instances; do
    ( docker_disk="${i}-docker"
    instance_zone=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter="name:${i}" --format='value(zone)')
    if gcloud --project "{{ gce_project_id }}" compute disks describe "$docker_disk" --zone "$instance_zone" &>/dev/null; then
        if ! gcloud --project "{{ gce_project_id }}" compute instances detach-disk "${i}" --disk "$docker_disk" --zone "$instance_zone"; then
            echo "warning: Unable to detach disk or already detached" 1>&2
        fi
        gcloud -q --project "{{ gce_project_id }}" compute disks delete "$docker_disk" --zone "$instance_zone"
    fi
    ) &
done

# Additional disks for node instances for openshift storage
instances=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter='tags.items:ocp-node OR tags.items:ocp-infra-node' --format='value(name)')
for i in $instances; do
    ( openshift_disk="${i}-openshift"
    instance_zone=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter="name:${i}" --format='value(zone)')
    if gcloud --project "{{ gce_project_id }}" compute disks describe "$openshift_disk" --zone "$instance_zone" &>/dev/null; then
        if ! gcloud --project "{{ gce_project_id }}" compute instances detach-disk "${i}" --disk "$openshift_disk" --zone "$instance_zone"; then
            echo "warning: Unable to detach disk or already detached" 1>&2
        fi
        gcloud -q --project "{{ gce_project_id }}" compute disks delete "$openshift_disk" --zone "$instance_zone"
    fi ) &
done

for i in `jobs -p`; do wait $i; done

# Instance groups
teardown "{{ provision_prefix }}instance-group-master" beta compute instance-groups managed --zone "{{ gce_zone_name }}"
teardown "{{ provision_prefix }}instance-group-node" beta compute instance-groups managed --zone "{{ gce_zone_name }}"
teardown "{{ provision_prefix }}instance-group-node-infra" beta compute instance-groups managed --zone "{{ gce_zone_name }}"

for i in `jobs -p`; do wait $i; done

# Instance templates
( teardown "{{ provision_prefix }}instance-template-master" compute instance-templates ) &
( teardown "{{ provision_prefix }}instance-template-node" compute instance-templates ) &
( teardown "{{ provision_prefix }}instance-template-node-infra" compute instance-templates ) &

# Firewall rules
# ['name']='parameters for "gcloud compute firewall-rules create"'
# For all possible parameters see: gcloud compute firewall-rules create --help
declare -A FW_RULES=(
  ['icmp']='--allow icmp'
  ['ssh-external']='--allow tcp:22'
  ['ssh-internal']='--allow tcp:22 --source-tags bastion'
  ['master-internal']="--allow tcp:2224,tcp:2379,tcp:2380,tcp:4001,udp:4789,udp:5404,udp:5405,tcp:8053,udp:8053,tcp:8444,tcp:10250,tcp:10255,udp:10255,tcp:24224,udp:24224 --source-tags ocp --target-tags ocp-master"
  ['master-external']="--allow tcp:80,tcp:443,tcp:1936,tcp:8080,tcp:8443 --target-tags ocp-master"
  ['node-internal']="--allow udp:4789,tcp:10250,tcp:10255,udp:10255 --source-tags ocp --target-tags ocp-node,ocp-infra-node"
  ['infra-node-internal']="--allow tcp:5000 --source-tags ocp --target-tags ocp-infra-node"
  ['infra-node-external']="--allow tcp:80,tcp:443,tcp:1936 --target-tags ocp-infra-node"
)
for rule in "${!FW_RULES[@]}"; do
    ( if gcloud --project "{{ gce_project_id }}" compute firewall-rules describe "$rule" &>/dev/null; then
        gcloud -q --project "{{ gce_project_id }}" compute firewall-rules delete "$rule"
    fi ) &
done

for i in `jobs -p`; do wait $i; done

# Network
teardown "{{ provision_prefix }}ocp-network" compute networks
