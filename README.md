# wslctl-main

WSLCTL main registry (Distribution to use with wslctl)


### Integrate to an existing wslctl instance

```PS1
wslctl registry add main https://github.com/mbl-35/wslctl-main
wslctl registry update
```

## Dev Notes

### Official Ubuntu Versions

- Download from ubuntu repo :
    `https://cloud-images.ubuntu.com/releases/{version}/release/ubuntu-{version}-server-cloudimg-amd64-wsl.rootfs.tar.gz`


### Microsoft Official Ubuntu Version Distribution
- Download tha app file at aka.ms: `https://aka.ms/wsl-ubuntu-{version}`
- extract install.tar.gz from app dowloaded file
- rename it to `ms-ubuntu-{version}-server-cloudimg-amd64-wsl.rootfs.tar.gz`