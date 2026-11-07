# kics-scan disable=b03a748a-542d-44f4-bb86-9199ab4fd2d5,f45ea400-6bbe-4501-9fc7-1c3d75c32067,965a08d7-ef86-4f14-8792-4a3b2098937e,fd54f200-402c-4333-a5a4-36ef6709af2f,0008c003-79aa-42d8-95b8-1c2fe37dbfe6
# cspell:ignore earendil
FROM mirror.gcr.io/library/node:24-trixie-slim
ENV container=docker
ENV LANG='en_US.UTF-8'
ENV LC_TIME='en_GB.UTF-8'
ENV LANGUAGE='en_US.UTF-8'
COPY _shared /files/shared
# One layer: coder.sh removes the SSH host keys and machine ID created by install.sh
RUN SKIP_CLEANUP=1 /files/shared/install/systemd-docker/install.sh && \
  CODER_SYSTEMD=1 /files/shared/install/coder.sh
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT []
CMD ["/sbin/init"]
VOLUME ["/srv/data/podman/coder", "/home/coder", "/var/lib/host-identity"]
