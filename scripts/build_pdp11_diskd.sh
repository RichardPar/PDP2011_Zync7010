#!/bin/bash
# build_pdp11_diskd.sh - cross-compile pdp11-diskd in the Dockerized PetaLinux
# container (only the pdp11-diskd recipe - fast, sstate is warm) and copy the
# resulting ARM binary to deploy/pdp11-diskd.
#
# Prereqs: docker image petalinux-2023.2:ubuntu22 exists, PetaLinux installed
# at /home/richard/petalinux-docker/2023.2, the petalinux project exists at
# /home/richard/petalinux-docker/work/pdp2011_zynq_petalinux.
#
# Output: deploy/pdp11-diskd (ARM ELF for the board).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO="$(cd "$HERE/.." && pwd)"

# Single source of truth: the vendored PetaLinux recipe (recipe + Makefile +
# source + init script). We sync the WHOLE recipe into the live project so a
# fast single-recipe build matches a full `plnx.sh build`.
RECIPE_SRC="$REPO/petalinux/meta-user/recipes-apps/pdp11-diskd"
DEPLOY="$REPO/deploy"
IMG=petalinux-2023.2:ubuntu22
PLNX_INSTALL=/home/richard/petalinux-docker/2023.2
WORK=/home/richard/petalinux-docker/work
PROJ_HOST="$WORK/pdp2011_zynq_petalinux"
PROJ="/home/plnx/work/pdp2011_zynq_petalinux"   # path inside the container
RECIPE_DST="$PROJ_HOST/project-spec/meta-user/recipes-apps/pdp11-diskd"

[ -f "$RECIPE_SRC/pdp11-diskd.bb" ] || { echo "ERROR: missing recipe $RECIPE_SRC"; exit 1; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "ERROR: docker image $IMG missing (run docker/plnx.sh image+install)"; exit 1; }

echo "== syncing vendored recipe into project =="
mkdir -p "$RECIPE_DST"
cp -rf "$RECIPE_SRC/." "$RECIPE_DST/"
echo "   $RECIPE_SRC -> $RECIPE_DST"

echo "== building pdp11-diskd recipe in container =="
# Stop at do_install so do_rm_work does not delete the work dir; then copy the
# freshly built binary out of the recipe's image dir.
docker run --rm \
  -v "$PLNX_INSTALL":/opt/petalinux/2023.2 \
  -v "$WORK":/home/plnx/work \
  -v "$DEPLOY":/deploy \
  "$IMG" bash -lc "
    set -e
    source /opt/petalinux/2023.2/settings.sh
    cd $PROJ
    petalinux-build -c pdp11-diskd -x do_install
    BIN=\$(find build/tmp/work -path '*pdp11-diskd*/image/usr/bin/pdp11-diskd' | head -1)
    [ -n \"\$BIN\" ] || { echo 'ERROR: built binary not found'; exit 1; }
    cp -f \$BIN /deploy/pdp11-diskd
    echo \"BUILD_OK -> /deploy/pdp11-diskd\"
  "

echo "== verifying =="
file "$DEPLOY/pdp11-diskd"
ls -la "$DEPLOY/pdp11-diskd"
