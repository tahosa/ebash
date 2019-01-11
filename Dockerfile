#
# Copyright 2011-2018, Marshall McMullen <marshall.mcmullen@gmail.com>
# Copyright 2011-2018, SolidFire, Inc. All rights reserved.
#
# This program is free software: you can redistribute it and/or modify it under the terms of the Apache License
# as published by the Apache Software Foundation, either version 2 of the License, or (at your option) any later
# version.

FROM ubuntu:16.04
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes \
          bsdmainutils \
          bzip2 \
          coreutils \
          cpio \
          curl \
          dialog \
          debootstrap \
          findutils \
          gawk \
          genisoimage \
          gnupg \
          grep \
          gzip \
          iproute2 \
          iputils-ping \
          jq \
          less \
          locales \
          lsb-release \
          openssl \
          ncurses-bin \
          pbzip2 \
          pigz \
          sed \
          squashfs-tools \
          tar \
          tzdata \
          util-linux \
          uuid-runtime \
          vim \
          wget \
          xz-utils \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.utf8 \
    && apt-get autoremove --assume-yes \
    && apt-get clean --assume-yes \
    && rm --force --recursive /var/lib/apt/lists/* /tmp/* /var/tmp/*
ENV LANG en_US.utf8
COPY . /ebash
WORKDIR /ebash
