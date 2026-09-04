# PetaLinux 2023.2 build environment - Ubuntu 22.04 (glibc 2.35).
#
# Why: the host (Linux Mint 22 / Ubuntu 24.04 base, glibc 2.39) cannot run
# PetaLinux's bitbake - it dies with "Failed to spawn fakeroot worker ...
# Broken pipe" because PetaLinux 2023.2's pseudo/buildtools expect glibc 2.35.
# Docker shares the host kernel but gives us the 22.04 userspace glibc that
# pseudo needs, which is what fixes it.
#
# PetaLinux itself is NOT installed into this image - it is installed once into
# a bind-mounted host dir (see plnx.sh 'install'), so the image stays small and
# the ~40 GB install persists across container runs.

FROM ubuntu:22.04
ARG UID=1000
ARG GID=1000
ENV DEBIAN_FRONTEND=noninteractive

# Prevent package postinst scripts from trying to start services (no init in a
# build container) - otherwise e.g. tftpd's postinst fails dpkg with
# "invoke-rc.d: could not determine current runlevel".
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# PetaLinux 2023.2 host package requirements (UG1144), all available on 22.04.
# (tftpd dropped - only needed for network-boot testing, not for building.)
RUN apt-get update && apt-get install -y --no-install-recommends \
      gawk gcc g++ git make net-tools libncurses5-dev zlib1g-dev \
      libssl-dev flex bison libselinux1 gnupg wget diffstat chrpath socat \
      xterm autoconf libtool tar unzip texinfo gcc-multilib build-essential \
      libsdl1.2-dev libglib2.0-dev screen pax gzip cpio python3 python3-pip \
      python3-jinja2 python3-git xz-utils debianutils iputils-ping \
      libegl1-mesa pylint bc rsync file locales sudo vim ca-certificates \
      expect less lsb-release zip libtinfo5 && \
    rm -rf /var/lib/apt/lists/*

# PetaLinux requires /bin/sh -> bash, and a UTF-8 locale
RUN ln -sf bash /bin/sh && locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Non-root user (PetaLinux refuses to run as root), matched to the host uid/gid
# so bind-mounted files stay owned by the host user.
RUN groupadd -g ${GID} plnx 2>/dev/null || true && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash plnx && \
    echo "plnx ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/plnx && chmod 440 /etc/sudoers.d/plnx

USER plnx
WORKDIR /home/plnx
CMD ["/bin/bash"]
