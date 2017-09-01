#
# This is GCE installer image for OpenShift.
#
# It expects to have the following files mounted:
#  - required:
#    /usr/local/install/data/ansible-config.yml - an ansible config yaml containing all context info
#    /usr/local/install/data/gce.json - the service account data for GCE in JSON format
#    /usr/local/install/data/gce.pem - the service account data for GCE in PEM format
#  - optional:
#    /usr/local/install/data/ssh-publickey - the public key for SSH to GCE nodes, will be generated
#    /usr/local/install/data/ssh-privatekey - the private key for SSH to GCE nodes, will be generated
#    /usr/local/install/data/ssl.pem - master serving certificate, signed for MASTER_DNS_NAME
#    /usr/local/install/data/ssl.key - the private key for the master serving certificate
#
# It must have the following env vars:
#  - optional:
#    GCE_PEM_FILE_PATH: path to a GCE PEM service account key, mounted in
#    INVENTORY_IP_TYPE: *external*|internal
#    CONFIG_SCRIPT: path to script for configuration
#    STARTUP_INSTANCE_DATA_PATH: path to a directory containing instance data to upload
#
# The standard name for this image is openshift/origin-gce
#
FROM openshift/origin-base

LABEL io.k8s.display-name="OpenShift GCE Install Environment" \
      io.k8s.description="This image helps install OpenShift onto GCE."

ENV WORK=/usr/share/ansible/openshift-ansible-gce \
    HOME=/home/cloud-user \
    GOOGLE_CLOUD_SDK_VERSION=147.0.0 \
    OPENSHIFT_ANSIBLE_TAG=master \
    ANSIBLE_JUNIT_DIR=/tmp/openshift/ansible_junit

# meta refresh_inventory has a bug in 2.2.0 where it uses relative path
# remove when fixed
ENV ANSIBLE_INVENTORY=$WORK/inventory/hosts

# package atomic-openshift-utils missing
RUN mkdir -p /usr/share/ansible $HOME/.ssh $WORK/playbooks/files && \
    ln -s $WORK/playbooks/files/ssh-privatekey $HOME/.ssh/google_compute_engine && \
    ln -s $WORK/playbooks/files/ssh-publickey $HOME/.ssh/google_compute_engine.pub && \
    INSTALL_PKGS="python-dns python2-libcloud python2-pip pyOpenSSL openssl gettext sudo epel-release" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    pip install junit_xml && \
    yum install -y ansible && \
    yum clean all && \
    cd /usr/share/ansible && \
    git clone https://github.com/openshift/openshift-ansible.git && \
    cd openshift-ansible && \
    git checkout ${OPENSHIFT_ANSIBLE_TAG} && \
    cd $HOME && \
    curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${GOOGLE_CLOUD_SDK_VERSION}-linux-x86_64.tar.gz | tar -xzf - && \
    ./google-cloud-sdk/bin/gcloud -q components update && \
    ./google-cloud-sdk/bin/gcloud -q components install beta && \
    ./google-cloud-sdk/install.sh -q --usage-reporting false && \
    echo 'ALL ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers && \
    mkdir -p /usr/share/ansible/plugins/callback && \
    curl -sS https://raw.githubusercontent.com/openshift/origin-ci-tool/master/oct/ansible/oct/callback_plugins/default_with_output_lists.py > /usr/share/ansible/plugins/callback/default_with_output_lists.py && \
    sed -r -i 's/^#?stdout_callback.*/stdout_callback = default_with_output_lists/' /etc/ansible/ansible.cfg && \
    curl -sS https://raw.githubusercontent.com/openshift/origin-ci-tool/master/oct/ansible/oct/callback_plugins/generate_junit.py > /usr/share/ansible/plugins/callback/generate_junit.py && \
    sed -r -i 's/^#?callback_whitelist.*/callback_whitelist = generate_junit/' /etc/ansible/ansible.cfg && \
    chmod -R g+w /usr/share/ansible $HOME /etc/passwd && \
    cd /usr/lib/python2.7/site-packages/libcloud && \
    curl -sS https://patch-diff.githubusercontent.com/raw/apache/libcloud/pull/1010.patch > /tmp/patch && \
    sudo patch -p2 < /tmp/patch && \
    rm /tmp/patch

WORKDIR $WORK
ENTRYPOINT ["/usr/share/ansible/openshift-ansible-gce/entrypoint.sh"]
CMD ["ansible-playbook", "playbooks/launch.yaml"]

COPY . $WORK
RUN chmod -R g+w $WORK
USER 1000
