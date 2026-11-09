# kics-scan disable=b84a0b47-2e99-4c9f-8933-98bcabe2b94d,f45ea400-6bbe-4501-9fc7-1c3d75c32067,965a08d7-ef86-4f14-8792-4a3b2098937e,fd54f200-402c-4333-a5a4-36ef6709af2f,b03a748a-542d-44f4-bb86-9199ab4fd2d5
# cspell:ignore procps
FROM mirror.gcr.io/node:24-trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
  ca-certificates git python3 procps && apt-get clean && rm -rf /var/lib/apt/lists/*
