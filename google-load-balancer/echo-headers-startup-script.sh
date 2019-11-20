#!/bin/bash -xe

INSTALL_BUCKET=$(curl --silent --fail -HMetadata-Flavor:Google metadata.google.internal/computeMetadata/v1/instance/attributes/install-bucket)

mkdir -p /opt/echo-headers
gsutil -m rsync -r "gs://$INSTALL_BUCKET/" /opt/echo-headers/

install /opt/echo-headers/echo-headers.service /etc/systemd/system/

systemctl daemon-reload
systemctl enable echo-headers
systemctl restart echo-headers
