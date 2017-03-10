#!/bin/bash

set -euo pipefail

# Bucket for registry
if gsutil ls -p "{{ gce_project_id }}" "gs://{{ provision_gce_registry_gcs_bucket }}" &>/dev/null; then
    gsutil -m rm -r "gs://{{ provision_gce_registry_gcs_bucket }}"
fi

function teardown() {
    a=( $@ )
    local name=$1
    a=( "${a[@]:1}" )
    local flag=0
    local found=
    for i in ${a[@]}; do
        if [[ "$i" == "--"* ]]; then
            found=true
            break
        fi
        flag=$((flag+1))
    done
    if [[ -z "${found}" ]]; then
      flag=$((flag+1))
    fi
    if gcloud --project "{{ gce_project_id }}" ${a[@]::$flag} describe "${name}" ${a[@]:$flag} &>/dev/null; then
        gcloud --project "{{ gce_project_id }}" ${a[@]::$flag} delete -q "${name}" ${a[@]:$flag}
    fi
}

# DNS
dns_zone="{{ dns_managed_zone | default(provision_prefix + 'managed-zone') }}"
if gcloud --project "{{ gce_project_id }}" dns managed-zones describe "${dns_zone}" &>/dev/null; then
    # Retry DNS changes until they succeed since this may be a shared resource
    while true; do
        dns="${TMPDIR:-/tmp}/dns.yaml"
        rm -f "${dns}"

        # export all dns records that match into a zone format, and turn each line into a set of args for
        # record-sets transaction.
        gcloud dns record-sets export --project "{{ gce_project_id }}" -z "${dns_zone}" --zone-file-format "${dns}"
        if grep -F -e '{{ openshift_master_cluster_hostname }}' -e '{{ openshift_master_cluster_public_hostname }}' -e '{{ wildcard_zone }}' "${dns}" | \
                awk '{ print "--name", $1, "--ttl", $2, "--type", $4, $5; }' > "${dns}.input"
        then
            rm -f "${dns}"
            gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns start -z "${dns_zone}"
            cat "${dns}.input" | xargs -L1 gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file="${dns}" remove -z "${dns_zone}"

            # Commit all DNS changes, retrying if preconditions are not met
            if ! out="$( gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns execute -z "${dns_zone}" 2>&1 )"; then
                rc=$?
                if [[ "${out}" == *"HTTPError 412: Precondition not met"* ]]; then
                    continue
                fi
                exit $rc
            fi
        fi
        rm "${dns}.input"
        break
    done
fi

# Preemptively spin down the instances
(
if gcloud --project "{{ gce_project_id }}" compute instance-groups managed describe "{{ provision_prefix }}ig-m" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute instance-groups managed resize "{{ provision_prefix }}ig-m" --size=0 --zone "{{ gce_zone_name }}"
fi
) &
(
if gcloud --project "{{ gce_project_id }}" compute instance-groups managed describe "{{ provision_prefix }}ig-i" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute instance-groups managed resize "{{ provision_prefix }}ig-i" --size=0 --zone "{{ gce_zone_name }}"
fi
) &
(
if gcloud --project "{{ gce_project_id }}" compute instance-groups managed describe "{{ provision_prefix }}ig-n" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute instance-groups managed resize "{{ provision_prefix }}ig-n" --size=0 --zone "{{ gce_zone_name }}"
fi
) &

(
# Router network rules
teardown "{{ provision_prefix }}router-network-lb-rule" compute forwarding-rules --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}router-network-lb-pool" compute target-pools --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}router-network-lb-health-check" compute http-health-checks
teardown "{{ provision_prefix }}router-network-lb-ip" compute addresses --region "{{ gce_region_name }}"

# Internal master network rules
teardown "{{ provision_prefix }}master-network-lb-rule" compute forwarding-rules --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}master-network-lb-pool" compute target-pools --region "{{ gce_region_name }}"
teardown "{{ provision_prefix }}master-network-lb-health-check" compute http-health-checks
teardown "{{ provision_prefix }}master-network-lb-ip" compute addresses --region "{{ gce_region_name }}"
) &

(
# Master SSL network rules
teardown "{{ provision_prefix }}master-ssl-lb-rule" compute forwarding-rules --global
teardown "{{ provision_prefix }}master-ssl-lb-target" compute target-ssl-proxies
teardown "{{ provision_prefix }}master-ssl-lb-cert" compute ssl-certificates
teardown "{{ provision_prefix }}master-ssl-lb-ip" compute addresses --global
teardown "{{ provision_prefix }}master-ssl-lb-backend" compute backend-services --global
teardown "{{ provision_prefix }}master-ssl-lb-health-check" compute health-checks
) &

# Additional disks for instances for docker storage
instances=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter='tags.items:{{ provision_prefix }}ocp AND tags.items:ocp' --format='value(name)')
for i in $instances; do
    (
    instance_zone=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter="name:${i}" --format='value(zone)')
    docker_disk="${i}-docker"
    if gcloud --project "{{ gce_project_id }}" compute disks describe "$docker_disk" --zone "$instance_zone" &>/dev/null; then
        if ! gcloud --project "{{ gce_project_id }}" compute instances detach-disk "${i}" --disk "$docker_disk" --zone "$instance_zone"; then
            echo "warning: Unable to detach docker disk or already detached" 1>&2
        fi
    fi
    openshift_disk="${i}-openshift"
    if gcloud --project "{{ gce_project_id }}" compute disks describe "$openshift_disk" --zone "$instance_zone" &>/dev/null; then
        if ! gcloud --project "{{ gce_project_id }}" compute instances detach-disk "${i}" --disk "$openshift_disk" --zone "$instance_zone"; then
            echo "warning: Unable to detach openshift disk or already detached" 1>&2
        fi
    fi
    ) &
done

for i in `jobs -p`; do wait $i; done

# Wait for any remaining disks to be detached
done=
for i in `seq 1 60`; do
    if [[ -z "$( gcloud --project "{{ gce_project_id }}" compute operations list --zones "{{ gce_zone_name }}" --filter 'operationType=detachDisk AND NOT status=DONE AND targetLink : "{{ provision_prefix }}ig-"' --page-size=10 --format 'value(targetLink)' --limit 1 )" ]]; then
        done=1
        break
    fi
    sleep 2
done
if [[ -z "${done}" ]]; then
    echo "Failed to detach disks"
    exit 1
fi

# Delete the disks in parallel with instance operations. Ignore failures to avoid preventing other expensive resources from
# being removed.
instances=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter='tags.items:{{ provision_prefix }}ocp AND tags.items:ocp' --format='value(name)')
for i in $instances; do
    instance_zone=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter="name:${i}" --format='value(zone)')
    ( gcloud -q --project "{{ gce_project_id }}" compute disks delete "${i}-docker" --zone "$instance_zone" || true ) &
    ( gcloud -q --project "{{ gce_project_id }}" compute disks delete "${i}-openshift" --zone "$instance_zone" || true ) &
done

# Instance groups
( teardown "{{ provision_prefix }}ig-m" compute instance-groups managed --zone "{{ gce_zone_name }}" ) &
( teardown "{{ provision_prefix }}ig-n" compute instance-groups managed --zone "{{ gce_zone_name }}" ) &
( teardown "{{ provision_prefix }}ig-i" compute instance-groups managed --zone "{{ gce_zone_name }}" ) &

for i in `jobs -p`; do wait $i; done

# Instance templates
( teardown "{{ provision_prefix }}instance-template-master" compute instance-templates ) &
( teardown "{{ provision_prefix }}instance-template-node" compute instance-templates ) &
( teardown "{{ provision_prefix }}instance-template-node-infra" compute instance-templates ) &

# Firewall rules
# ['name']='parameters for "gcloud compute firewall-rules create"'
# For all possible parameters see: gcloud compute firewall-rules create --help
declare -A FW_RULES=(
  ['icmp']=""
  ['ssh-external']=""
  ['ssh-internal']=""
  ['master-internal']=""
  ['master-external']=""
  ['node-internal']=""
  ['infra-node-internal']=""
  ['infra-node-external']=""
)
for rule in "${!FW_RULES[@]}"; do
    ( if gcloud --project "{{ gce_project_id }}" compute firewall-rules describe "{{ provision_prefix }}$rule" &>/dev/null; then
        gcloud -q --project "{{ gce_project_id }}" compute firewall-rules delete "{{ provision_prefix }}$rule"
    fi ) &
done

for i in `jobs -p`; do wait $i; done

# Network
teardown "{{ gce_network_name }}" compute networks
