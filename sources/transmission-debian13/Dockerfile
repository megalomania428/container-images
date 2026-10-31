# kics-scan disable=b84a0b47-2e99-4c9f-8933-98bcabe2b94d,f45ea400-6bbe-4501-9fc7-1c3d75c32067,965a08d7-ef86-4f14-8792-4a3b2098937e,fd54f200-402c-4333-a5a4-36ef6709af2f,b03a748a-542d-44f4-bb86-9199ab4fd2d5
# cspell:ignore msmtpq
FROM mirror.gcr.io/debian:trixie-slim AS builder
COPY _shared/upstream /build
COPY files/build.sh /files/build.sh
RUN /files/build.sh

FROM mirror.gcr.io/debian:trixie-slim
ENV MSMTPQ_Q=/var/spool/msmtpq MSMTPQ_LOG=/dev/stdout EMAIL_CONN_TEST=x MSMTPQ_PERIOD=555
COPY --from=builder /build/debs /tmp/debs
COPY files /files
RUN /files/install.sh
CMD ["/usr/local/bin/transmission-entrypoint.sh"]
