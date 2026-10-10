# kics-scan disable=b03a748a-542d-44f4-bb86-9199ab4fd2d5,f45ea400-6bbe-4501-9fc7-1c3d75c32067,965a08d7-ef86-4f14-8792-4a3b2098937e,fd54f200-402c-4333-a5a4-36ef6709af2f
FROM mirror.gcr.io/debian:trixie-slim
ENV container=docker
COPY _shared /files/shared
RUN SKIP_CLEANUP=1 /files/shared/install/systemd-docker/install.sh
COPY files /files
RUN /files/install.sh
ENV DISPLAY=:99
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
VOLUME ["/vault", "/config"]
EXPOSE 6080
