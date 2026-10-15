# kics-scan disable=b03a748a-542d-44f4-bb86-9199ab4fd2d5,f45ea400-6bbe-4501-9fc7-1c3d75c32067,965a08d7-ef86-4f14-8792-4a3b2098937e,fd54f200-402c-4333-a5a4-36ef6709af2f
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS runtime
ARG PYENV_ROOT
ENV PATH="/ansbl:$PATH"
ENV PYENV_ROOT=${PYENV_ROOT}
COPY _shared /files
RUN /files/runtime.sh
ARG PYENV_VERSION_PYTHON
ENV PYENV_VERSION_PYTHON=${PYENV_VERSION_PYTHON}

FROM runtime AS builder
RUN /files/pyenv.sh

FROM builder AS pip
ARG TAG
ENV TAG=${TAG}
COPY requirements.txt /files/requirements.txt
RUN /files/pip-install.sh

FROM runtime AS ansible
COPY --from=pip ${PYENV_ROOT}/versions/ ${PYENV_ROOT}/versions/
RUN /files/configure.sh
WORKDIR /ansible

FROM ansible AS docker
COPY _shared /files
RUN /files/docker.sh
VOLUME ["/sys/fs/cgroup", "/tmp", "/run"]
CMD ["/lib/systemd/systemd"]
