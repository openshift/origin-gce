#!/bin/bash

set -euo pipefail

# Create SSH key for GCE
if [ ! -f "{{ gce_ssh_private_key }}" ]; then
    ssh-keygen -t rsa -f "{{ gce_ssh_private_key }}" -C gce-provision-cloud-user -N ''
    ssh-add "{{ gce_ssh_private_key }}" || true
fi

# Check if the ~/.ssh/google_compute_engine.pub key is in the project metadata, and if not, add it there
pub_key=$(cut -d ' ' -f 2 < "{{ gce_ssh_private_key }}.pub")
key_tmp_file='/tmp/ocp-gce-keys'
if ! gcloud --project "{{ gce_project_id }}" compute project-info describe | grep -q "$pub_key"; then
    if gcloud --project "{{ gce_project_id }}" compute project-info describe | grep -q ssh-rsa; then
        gcloud --project "{{ gce_project_id }}" compute project-info describe | grep ssh-rsa | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/value: //' > "$key_tmp_file"
    fi
    echo -n 'cloud-user:' >> "$key_tmp_file"
    cat "{{ gce_ssh_private_key }}.pub" >> "$key_tmp_file"
    gcloud --project "{{ gce_project_id }}" compute project-info add-metadata --metadata-from-file "sshKeys=${key_tmp_file}"
    rm -f "$key_tmp_file"
fi

metadata=""
if [[ -n "{{ provision_gce_startup_script_file }}" ]]; then
    if [[ ! -f "{{ provision_gce_startup_script_file }}" ]]; then
        echo "Startup script file missing at {{ provision_gce_startup_script_file }}"
        exit 1
    fi
    metadata+="--metadata-from-file=startup-script={{ provision_gce_startup_script_file }}"
fi
if [[ -n "{{ provision_gce_user_data_file }}" ]]; then
    if [[ ! -f "{{ provision_gce_user_data_file }}" ]]; then
        echo "User data file missing at {{ provision_gce_user_data_file }}"
        exit 1
    fi
    if [[ -n "${metadata}" ]]; then
        metadata+=","
    else
        metadata="--metadata-from-file="
    fi
    metadata+="user-data={{ provision_gce_user_data_file }}"
fi


if ! gcloud --project "{{ gce_project_id }}" compute images describe "{{ provision_gce_registered_image }}" &>/dev/null; then
    "${DIR}/gcloud-image.sh"
fi

### PROVISION THE INFRASTRUCTURE ###

# Check the DNS managed zone in Google Cloud DNS, create it if it doesn't exist and exit after printing NS servers
if ! gcloud --project "{{ gce_project_id }}" dns managed-zones describe "{{ provision_prefix }}managed-zone" &>/dev/null; then
    echo "DNS zone '{{ provision_prefix }}managed-zone' doesn't exist. It will be created and installation will stop. Please configure the following NS servers for your domain in your domain provider before proceeding with the installation:"
    gcloud --project "{{ gce_project_id }}" dns managed-zones create "{{ provision_prefix }}managed-zone" --dns-name "{{ public_hosted_zone }}" --description "{{ public_hosted_zone }} domain"
    gcloud --project "{{ gce_project_id }}" dns managed-zones describe "{{ provision_prefix }}managed-zone" --format='value(nameServers)' | tr ';' '\n'
    exit 2
fi

# Create network
if ! gcloud --project "{{ gce_project_id }}" compute networks describe "{{ provision_prefix }}ocp-network" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute networks create "{{ provision_prefix }}ocp-network" --mode "auto"
else
    echo "Network '{{ provision_prefix }}ocp-network' already exists"
fi

# Firewall rules in a form:
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
BASTION_SSH_FW_RULE="{{ provision_prefix }}bastion-ssh-to-external-ip"

# Create firewall rules
for rule in "${!FW_RULES[@]}"; do
    ( if ! gcloud --project "{{ gce_project_id }}" compute firewall-rules describe "$rule" &>/dev/null; then
        gcloud --project "{{ gce_project_id }}" compute firewall-rules create "$rule" --network "{{ provision_prefix }}ocp-network" ${FW_RULES[$rule]}
    else
        echo "Firewall rule '${rule}' already exists"
    fi ) &
done

# Master IP
( if ! gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}master-ssl-lb-ip" --global &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute addresses create "{{ provision_prefix }}master-ssl-lb-ip" --global
else
    echo "IP '{{ provision_prefix }}master-ssl-lb-ip' already exists"
fi ) &


# Internal master IP
( if ! gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}master-network-lb-ip" --region "{{ gce_region_name }}" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute addresses create "{{ provision_prefix }}master-network-lb-ip" --region "{{ gce_region_name }}"
else
    echo "IP '{{ provision_prefix }}master-network-lb-ip' already exists"
fi ) &

# Router IP
( if ! gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}router-network-lb-ip" --region "{{ gce_region_name }}" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute addresses create "{{ provision_prefix }}router-network-lb-ip" --region "{{ gce_region_name }}"
else
    echo "IP '{{ provision_prefix }}router-network-lb-ip' already exists"
fi ) &

for i in `jobs -p`; do wait $i; done

# Create instance templates
(
if ! gcloud --project "{{ gce_project_id }}" compute instance-templates describe "{{ provision_prefix }}instance-template-master" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute instance-templates create "{{ provision_prefix }}instance-template-master" --machine-type "{{ provision_gce_machine_type_master }}" --network "{{ provision_prefix }}ocp-network" --tags "ocp,ocp-master" --image "{{ provision_gce_registered_image }}" --boot-disk-size "35" --boot-disk-type "pd-ssd" --scopes logging-write,monitoring-write,useraccounts-ro,service-control,service-management,storage-ro,compute-rw ${metadata}
else
    echo "Instance template '{{ provision_prefix }}instance-template-master' already exists"
fi

# Create Master instance group
if ! gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed describe "{{ provision_prefix }}instance-group-master" --zone "{{ gce_zone_name }}" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed create "{{ provision_prefix }}instance-group-master" --zone "{{ gce_zone_name }}" --template "{{ provision_prefix }}instance-template-master" --size "{{ provision_prefix }}instance-group-size-master"
    gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed set-named-ports "{{ provision_prefix }}instance-group-master" --zone "{{ gce_zone_name }}" --named-ports "{{ provision-prefix }}-port-name-master:{{ internal_console_port }}"
else
    echo "Instance group '{{ provision_prefix }}instance-group-master' already exists"
fi
) &

(
if ! gcloud --project "{{ gce_project_id }}" compute instance-templates describe "{{ provision_prefix }}instance-template-node" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute instance-templates create "{{ provision_prefix }}instance-template-node" --machine-type "{{ provision_gce_machine_type_node }}" --network "{{ provision_prefix }}ocp-network" --tags "ocp,ocp-node" --image "{{ provision_gce_registered_image }}" --boot-disk-size "25" --boot-disk-type "pd-ssd" --scopes logging-write,monitoring-write,useraccounts-ro,service-control,service-management,storage-ro,compute-rw ${metadata}
else
    echo "Instance template '{{ provision_prefix }}instance-template-node' already exists"
fi

# Create Node instance group
if ! gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed describe "{{ provision_prefix }}instance-group-node" --zone "{{ gce_zone_name }}" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed create "{{ provision_prefix }}instance-group-node" --zone "{{ gce_zone_name }}" --template "{{ provision_prefix }}instance-template-node" --size "{{ provision_prefix }}instance-group-size-node"
else
    echo "Instance group '{{ provision_prefix }}instance-group-node' already exists"
fi
) &

(
if ! gcloud --project "{{ gce_project_id }}" compute instance-templates describe "{{ provision_prefix }}instance-template-node-infra" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute instance-templates create "{{ provision_prefix }}instance-template-node-infra" --machine-type "{{ provision_gce_machine_type_node_infra }}" --network "{{ provision_prefix }}ocp-network" --tags "ocp,ocp-infra-node" --image "{{ provision_gce_registered_image }}" --boot-disk-size "25" --boot-disk-type "pd-ssd" --scopes logging-write,monitoring-write,useraccounts-ro,service-control,service-management,storage-rw,compute-rw ${metadata}
else
    echo "Instance template '{{ provision_prefix }}instance-template-node-infra' already exists"
fi

# Create Infra node instance group
if ! gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed describe "{{ provision_prefix }}instance-group-node-infra" --zone "{{ gce_zone_name }}" &>/dev/null; then
        gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed create "{{ provision_prefix }}instance-group-node-infra" --zone "{{ gce_zone_name }}" --template "{{ provision_prefix }}instance-template-node-infra" --size "{{ provision_prefix }}instance-group-size-node-infra"
else
    echo "Instance group '{{ provision_prefix }}instance-group-node-infra' already exists"
fi
) &

for i in `jobs -p`; do wait $i; done

# Attach additional disks to instances for docker storage
instances=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter='tags.items:ocp' --format='value(name)')
for i in $instances; do
    ( docker_disk="${i}-docker"
    instance_zone=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter="name:${i}" --format='value(zone)')
    if ! gcloud --project "{{ gce_project_id }}" compute disks describe "$docker_disk" --zone "$instance_zone" &>/dev/null; then
        gcloud --project "{{ gce_project_id }}" compute disks create "$docker_disk" --zone "$instance_zone" --size "{{ provision_gce_disk_size_node_docker }}" --type "pd-ssd"
        gcloud --project "{{ gce_project_id }}" compute instances attach-disk "${i}" --disk "$docker_disk" --zone "$instance_zone"
    else
        echo "Disk '${docker_disk}' already exists"
    fi ) &
done

# Attach additional disks to node instances for openshift storage
instances=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter='tags.items:ocp-node OR tags.items:ocp-infra-node' --format='value(name)')
for i in $instances; do
    ( openshift_disk="${i}-openshift"
    instance_zone=$(gcloud --project "{{ gce_project_id }}" compute instances list --filter="name:${i}" --format='value(zone)')
    if ! gcloud --project "{{ gce_project_id }}" compute disks describe "$openshift_disk" --zone "$instance_zone" &>/dev/null; then
        gcloud --project "{{ gce_project_id }}" compute disks create "$openshift_disk" --zone "$instance_zone" --size "{{ provision_gce_disk_size_node_openshift }}" --type "pd-ssd"
        gcloud --project "{{ gce_project_id }}" compute instances attach-disk "${i}" --disk "$openshift_disk" --zone "$instance_zone"
    else
        echo "Disk '${openshift_disk}' already exists"
    fi ) &
done

for i in `jobs -p`; do wait $i; done

# Master health check
(
if ! gcloud --project "{{ gce_project_id }}" compute health-checks describe "{{ provision_prefix }}master-ssl-lb-health-check" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute health-checks create https "{{ provision_prefix }}master-ssl-lb-health-check" --port "{{ internal_console_port }}" --request-path "/healthz"
else
    echo "Health check '{{ provision_prefix }}master-ssl-lb-health-check' already exists"
fi

# Master backend service
if ! gcloud --project "{{ gce_project_id }}" beta compute backend-services describe "{{ provision_prefix }}master-ssl-lb-backend" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" beta compute backend-services create "{{ provision_prefix }}master-ssl-lb-backend" --health-checks "{{ provision_prefix }}master-ssl-lb-health-check" --port-name "{{ provision-prefix }}-port-name-master" --protocol "SSL" --global
    gcloud --project "{{ gce_project_id }}" beta compute backend-services add-backend "{{ provision_prefix }}master-ssl-lb-backend" --instance-group "{{ provision_prefix }}instance-group-master" --global --instance-group-zone "{{ gce_zone_name }}"
else
    echo "Backend service '{{ provision_prefix }}master-ssl-lb-backend' already exists"
fi
) &

# Master Certificate
( if ! gcloud --project "{{ gce_project_id }}" compute ssl-certificates describe "{{ provision_prefix }}master-ssl-lb-cert" &>/dev/null; then
    if [ -z "{{ provision_master_https_key_file }}" ] || [ -z "{{ provision_master_https_cert_file }}" ]; then
        KEY='/tmp/ocp-ssl.key'
        CERT='/tmp/ocp-ssl.crt'
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -subj "/C=US/L=Raleigh/O={{ public_hosted_zone }}/CN={{ openshift_master_cluster_public_hostname }}" -keyout "$KEY" -out "$CERT"
    else
        KEY="{{ provision_master_https_key_file }}"
        CERT="{{ provision_master_https_cert_file }}"
    fi
    gcloud --project "{{ gce_project_id }}" compute ssl-certificates create "{{ provision_prefix }}master-ssl-lb-cert" --private-key "$KEY" --certificate "$CERT"
    if [ -z "{{ provision_master_https_key_file }}" ] || [ -z "{{ provision_master_https_cert_file }}" ]; then
        rm -fv "$KEY" "$CERT"
    fi
else
    echo "Certificate '{{ provision_prefix }}master-ssl-lb-cert' already exists"
fi ) &

for i in `jobs -p`; do wait $i; done

(
# Master ssl proxy target
if ! gcloud --project "{{ gce_project_id }}" compute target-ssl-proxies describe "{{ provision_prefix }}master-ssl-lb-target" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute target-ssl-proxies create "{{ provision_prefix }}master-ssl-lb-target" --backend-service "{{ provision_prefix }}master-ssl-lb-backend" --ssl-certificate "{{ provision_prefix }}master-ssl-lb-cert"
else
    echo "Proxy target '{{ provision_prefix }}master-ssl-lb-target' already exists"
fi

# Master forwarding rule
if ! gcloud --project "{{ gce_project_id }}" compute forwarding-rules describe "{{ provision_prefix }}master-ssl-lb-rule" --global &>/dev/null; then
    IP=$(gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}master-ssl-lb-ip" --global --format='value(address)')
    gcloud --project "{{ gce_project_id }}" compute forwarding-rules create "{{ provision_prefix }}master-ssl-lb-rule" --address "$IP" --global --ports "80:65335" --target-ssl-proxy "{{ provision_prefix }}master-ssl-lb-target"
else
    echo "Forwarding rule '{{ provision_prefix }}master-ssl-lb-rule' already exists"
fi
) &

(
# Internal master health check
if ! gcloud --project "{{ gce_project_id }}" compute http-health-checks describe "{{ provision_prefix }}master-network-lb-health-check" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute http-health-checks create "{{ provision_prefix }}master-network-lb-health-check" --port "8080" --request-path "/healthz"
else
    echo "Health check '{{ provision_prefix }}master-network-lb-health-check' already exists"
fi

# Internal master target pool
if ! gcloud --project "{{ gce_project_id }}" compute target-pools describe "{{ provision_prefix }}master-network-lb-pool" --region "{{ gce_region_name }}" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute target-pools create "{{ provision_prefix }}master-network-lb-pool" --http-health-check "{{ provision_prefix }}master-network-lb-health-check" --region "{{ gce_region_name }}"
    gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed set-target-pools "{{ provision_prefix }}instance-group-master" --target-pools "{{ provision_prefix }}master-network-lb-pool" --zone "{{ gce_zone_name }}"
else
    echo "Target pool '{{ provision_prefix }}master-network-lb-pool' already exists"
fi

# Internal master forwarding rule
if ! gcloud --project "{{ gce_project_id }}" compute forwarding-rules describe "{{ provision_prefix }}master-network-lb-rule" --region "{{ gce_region_name }}" &>/dev/null; then
    IP=$(gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}master-network-lb-ip" --region "{{ gce_region_name }}" --format='value(address)')
    gcloud --project "{{ gce_project_id }}" compute forwarding-rules create "{{ provision_prefix }}master-network-lb-rule" --address "$IP" --region "{{ gce_region_name }}" --target-pool "{{ provision_prefix }}master-network-lb-pool"
else
    echo "Forwarding rule '{{ provision_prefix }}master-network-lb-rule' already exists"
fi
) &

(
# Router health check
if ! gcloud --project "{{ gce_project_id }}" compute http-health-checks describe "{{ provision_prefix }}router-network-lb-health-check" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute http-health-checks create "{{ provision_prefix }}router-network-lb-health-check" --port "1936" --request-path "/healthz"
else
    echo "Health check '{{ provision_prefix }}router-network-lb-health-check' already exists"
fi

# Router target pool
if ! gcloud --project "{{ gce_project_id }}" compute target-pools describe "{{ provision_prefix }}router-network-lb-pool" --region "{{ gce_region_name }}" &>/dev/null; then
    gcloud --project "{{ gce_project_id }}" compute target-pools create "{{ provision_prefix }}router-network-lb-pool" --http-health-check "{{ provision_prefix }}router-network-lb-health-check" --region "{{ gce_region_name }}"
    gcloud --project "{{ gce_project_id }}" beta compute instance-groups managed set-target-pools "{{ provision_prefix }}instance-group-{{ provision_gce_router_network_instance_group }}" --target-pools "{{ provision_prefix }}router-network-lb-pool" --zone "{{ gce_zone_name }}"
else
    echo "Target pool '{{ provision_prefix }}router-network-lb-pool' already exists"
fi

# Router forwarding rule
if ! gcloud --project "{{ gce_project_id }}" compute forwarding-rules describe "{{ provision_prefix }}router-network-lb-rule" --region "{{ gce_region_name }}" &>/dev/null; then
    IP=$(gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}router-network-lb-ip" --region "{{ gce_region_name }}" --format='value(address)')
    gcloud --project "{{ gce_project_id }}" compute forwarding-rules create "{{ provision_prefix }}router-network-lb-rule" --address "$IP" --region "{{ gce_region_name }}" --target-pool "{{ provision_prefix }}router-network-lb-pool"
else
    echo "Forwarding rule '{{ provision_prefix }}router-network-lb-rule' already exists"
fi
) &

for i in `jobs -p`; do wait $i; done

# DNS record for master lb
dns="$TMPDIR/dns.yaml"
rm -f $dns

if ! gcloud --project "{{ gce_project_id }}" dns record-sets list -z "{{ provision_prefix }}managed-zone" --name "{{ openshift_master_cluster_public_hostname }}" 2>/dev/null | grep -q "{{ openshift_master_cluster_public_hostname }}"; then
    IP=$(gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}master-ssl-lb-ip" --global --format='value(address)')
    if [[ ! -f $dns ]]; then
        gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns start -z "{{ provision_prefix }}managed-zone"
    fi
    gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns add -z "{{ provision_prefix }}managed-zone" --ttl 3600 --name "{{ openshift_master_cluster_public_hostname }}." --type A "$IP"
else
    echo "DNS record for '{{ openshift_master_cluster_public_hostname }}' already exists"
fi

# DNS record for internal master lb
if ! gcloud --project "{{ gce_project_id }}" dns record-sets list -z "{{ provision_prefix }}managed-zone" --name "{{ openshift_master_cluster_hostname }}" 2>/dev/null | grep -q "{{ openshift_master_cluster_hostname }}"; then
    IP=$(gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}master-network-lb-ip" --region "{{ gce_region_name }}" --format='value(address)')
    if [[ ! -f $dns ]]; then
        gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns start -z "{{ provision_prefix }}managed-zone"
    fi
    gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns add -z "{{ provision_prefix }}managed-zone" --ttl 3600 --name "{{ openshift_master_cluster_hostname }}." --type A "$IP"
else
    echo "DNS record for '{{ openshift_master_cluster_hostname }}' already exists"
fi

# DNS record for router lb
if ! gcloud --project "{{ gce_project_id }}" dns record-sets list -z "{{ provision_prefix }}managed-zone" --name "{{ wildcard_zone }}" 2>/dev/null | grep -q "{{ wildcard_zone }}"; then
    IP=$(gcloud --project "{{ gce_project_id }}" compute addresses describe "{{ provision_prefix }}router-network-lb-ip" --region "{{ gce_region_name }}" --format='value(address)')
    if [[ ! -f $dns ]]; then
        gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns start -z "{{ provision_prefix }}managed-zone"
    fi
    gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns add -z "{{ provision_prefix }}managed-zone" --ttl 3600 --name "{{ wildcard_zone }}." --type A "$IP"
    gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns add -z "{{ provision_prefix }}managed-zone" --ttl 3600 --name "*.{{ wildcard_zone }}." --type CNAME "{{ wildcard_zone }}."
else
    echo "DNS record for '{{ wildcard_zone }}' already exists"
fi

# Commit all DNS changes
if [[ -f $dns ]]; then
    gcloud --project "{{ gce_project_id }}" dns record-sets transaction --transaction-file=$dns execute -z "{{ provision_prefix }}managed-zone"
fi

# Create bucket for registry
( if ! gsutil ls -p "{{ gce_project_id }}" "gs://{{ provision_gce_registry_gcs_bucket }}" &>/dev/null; then
    gsutil mb -p "{{ gce_project_id }}" -l "{{ gce_region_name }}" "gs://{{ provision_gce_registry_gcs_bucket }}"
else
    echo "Bucket '{{ provision_gce_registry_gcs_bucket }}' already exists"
fi ) &

for i in `jobs -p`; do wait $i; done
