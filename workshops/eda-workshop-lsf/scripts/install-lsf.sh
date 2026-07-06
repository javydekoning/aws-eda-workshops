#!/bin/bash

# Exit on unset variables and pipe failures. Errors are handled explicitly below.
set -uo pipefail

# ------------------------------------------------------------------
# Logging helpers
# Output is echoed to stdout/stderr, which is captured by the
# instance user-data / cloud-init logs.
# ------------------------------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2
}

# Fail fast with a message. Used when a critical step cannot continue.
die() {
    log_error "$*"
    log_error "LSF installation aborted."
    exit 1
}

# Copy a file from S3, halting the install if the copy fails.
s3_cp() {
    local src="$1"
    local dest="$2"
    log "Downloading $src -> $dest"
    if ! aws --quiet s3 cp "$src" "$dest"; then
        die "Failed to download $src from S3."
    fi
    log "Successfully downloaded $src"
}

log "Starting LSF installation."
log "LSF_INSTALL_DIR=${LSF_INSTALL_DIR}"

mkdir -p "$LSF_INSTALL_DIR"
mkdir -p /var/log/lsf && chmod 777 /var/log/lsf

# Add LSF admin account
log "Ensuring LSF admin account '$LSF_ADMIN' exists."
id -u "$LSF_ADMIN" &>/dev/null || adduser -m -u 1500 "$LSF_ADMIN"

# Add to bashrc if not yet exists
log "Configuring LSF profile in /etc/bashrc."
grep -qxF "source $LSF_INSTALL_DIR/conf/profile.lsf" /etc/bashrc || \
echo "source $LSF_INSTALL_DIR/conf/profile.lsf" >> /etc/bashrc

# Download customer-provided LSF binaries and entitlement file
log "Downloading LSF binaries and entitlement file from S3."
s3_cp "$CFN_LSF_INSTALL_URI" /tmp
s3_cp "$CFN_LSF_BIN_URI" /tmp
s3_cp "$CFN_LSF_ENTITLEMENT_URI" /tmp
s3_cp "$CFN_LSF_FIXPACK_URI" /tmp

log "Extracting LSF installer package $LSF_INSTALL_PKG."
cd /tmp
tar xf "$LSF_INSTALL_PKG" || die "Failed to extract $LSF_INSTALL_PKG."
cp "$LSF_BIN_PKG" lsf10.1_lsfinstall || die "Failed to copy $LSF_BIN_PKG into installer directory."
cd lsf10.1_lsfinstall

# Create LSF installer config file
log "Creating LSF installer config file."
cat <<EOF > install.config
LSF_TOP="$LSF_INSTALL_DIR"
LSF_ADMINS="$LSF_ADMIN"
LSF_CLUSTER_NAME=$LSF_CLUSTER_NAME
LSF_MASTER_LIST="${HOSTNAME%%.*}"
SILENT_INSTALL="Y"
LSF_SILENT_INSTALL_TARLIST="ALL"
ACCEPT_LICENSE="Y"
LSF_ENTITLEMENT_FILE="/tmp/$LSF_ENTITLEMENT"
EOF

log "Running LSF installer."
./lsfinstall -f install.config || die "LSF installer (lsfinstall) failed."

# Setup LSF environment
log "Sourcing LSF environment profile."
source "$LSF_INSTALL_DIR/conf/profile.lsf"

# Install fix pack
log "Installing LSF fix pack $LSF_FP_PKG."
cd "$LSF_INSTALL_DIR/10.1/install"
cp "/tmp/$LSF_FP_PKG" . || die "Failed to copy fix pack $LSF_FP_PKG."
echo "schmod_demand.so" >> patchlib/daemonlists.tbl
./patchinstall --silent "$LSF_FP_PKG" || die "Fix pack installation (patchinstall) failed."

## Create Resource Connector config dir
log "Creating Resource Connector config directory."
mkdir -p "$LSF_ENVDIR/resource_connector/aws/conf"
chown -R lsfadmin:root "$LSF_ENVDIR/resource_connector/aws"

log "LSF installation completed successfully."
