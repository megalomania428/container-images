# Container images collection

[![containers](https://github.com/megalomania428/container-images/actions/workflows/containers.yaml/badge.svg)](https://github.com/megalomania428/container-images/actions/workflows/containers.yaml)
[![AppImages](https://github.com/megalomania428/container-images/actions/workflows/appimages.yaml/badge.svg)](https://github.com/megalomania428/container-images/actions/workflows/appimages.yaml)


## Before manual `./push.sh`

```shell
podman login --username json_key --password-stdin ghcr.io
```

## Build steps

- clone me:

  ```bash
  git clone --recursive git@github.com:megalomania428/container-images && cd container-images
  ```

- build some container image(s):

  ```bash
  MANUAL_IMAGES_DIRS='opencode-ubuntu-22_04/ utils-ubuntu-22_04/' _shared/_all/build.sh
  ```

- push some container image(s):

  ```bash
  MANUAL_IMAGES_DIRS='opencode-ubuntu-22_04/ utils-ubuntu-22_04/' _shared/_all/push.sh
  ```

- build appimage:

  ```bash
  TAG='ansible-11' _shared/_all/appimage.sh
  ```

- send appimage release:

  ```bash
  git checkout master && git pull
  git tag -fm $(git branch --sho) 009 && git push origin --force $(git describe)
  ```
