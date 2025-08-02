# MANGOS

**MA**stercard **N**ext **G**eneration **O**perating **S**ystem

If you look around, you can see that this is very much in its infancy, and not something you'd find running at Mastercard, so the name is more aspirational than anything.

## What is it?

With MANGOS, we want to build a highly secure operating system beyond what you can achieve with garden variety Linux distros.

### Disk layout

First, MANGOS gets installed as an image. The filesystem is [erofs](https://docs.kernel.org/filesystems/erofs.html), so the filesystem driver doesn't even implement any write operations. The image also contains a [Verity](https://docs.kernel.org/admin-guide/device-mapper/verity.html) hash partition. The kernel uses this to verify that the erofs filesystem hasn't been tampered with. A third partition contains a signature for the hash partition. The kernel will check this signature against a certificate that is embedded in the kernel at build time. Also, the kernel itself is signed, and systems are configured with Secure Boot to only allow kernels (or boot managers/loaders) signed by this key. Finally, the system will refuse to start if Secure Boot is disabled.

System updates are also provided as images. As they are made available, they are downloaded and written to a second set of 3 partitions as (data + hash + signature). On reboot, the bootloader will attempt to boot into the newest version and fall back to the older one if it fails.

The filesystem in the image is the root filesystem, so even `/etc` is read-only.  Configuration is done using [configuration extensions](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html). These are also signed and verified against the certificate in the kernel.

On first boot, `systemd-repart` creates 3 partitions: swap, `/var`, and `/var/tmp`. They are encrypted using a key rooted in the TPM, so can't be decrypted anywhere else.

If you've ever used CoreOS, a lot of these concepts will seem familiar. If you're an Android user, you're using a lot of this already!

### Runtime environment and compatibility

If you were to log into a MANGOS system and look around, it would be almost indistinguishable from a pared down Ubuntu system... because that's kinda what it is. 

Ubuntu is extraordinarily pervasive. For a piece of software, there's almost always going to be instructions for how to make it work on Ubuntu. Yes, it needs to be installed during the image build process, but everything is where you expect it to be. This makes the learning curve much more reasonable than omething like Alpine or a completely custom distro. 

### How am I supposed to use it?

Since everything has to be signed and will be validated against an embedded cert, how is anyone else supposed to sign their configuration and use this?  

Well spotted. They can't.

Organizations will have their own keys. They will build their own kernels, images, and configuration on whatever infrastructure they trust. They can use MANGOS as is or modify it according to their needs. E.g. I imagine most will enable the Docker profile that installs Docker in the image, too. Very handy.

In fact, anything we build on Github is built using either ephemeral keys or keys that are simply stored as secrets in Github Actions. I wouldn't trust it, and you shouldn't either. If you want to use MANGOS, you build it yourself.

One of our goals is to build everything from source, taking control of a big chunk of the supply chain, providing an audit trail for everything installed on our systems back to a specific commit in the upstream source code repo. For anything that can be built reproducibly (i.e. everyone should get the bit-for-bit same output), there should be a mechanism for MANGOS users to compare their results, thus cross-validating their supply chain.


## Status?

Some of the above is fully implemented. Some is just ideas. Most is somewhere in between. Stay tuned.
