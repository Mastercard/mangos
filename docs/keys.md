# Encryption and signing key types and sizes

Different parts of the system need different key types and sizes, and the tooling doesn't alwways prevent you from making the wrong choices.

## Kernel signing key

| Type | Size      | Extra info                    | Working? |
|------|-----------|-------------------------------|----------|
| RSA  | 4096 bits | Extensions as below           | Yes      |
| RSA  | 2048 bits | As produced by `mkosi genkey` | No       |

The kernel's build system creates a signing key using [this config](https://github.com/torvalds/linux/blob/8f5ae30d69d7543eee0d70083daf4de8fe15d585/certs/default_x509.genkey) (shown here with irrelevant parts removed):

```
[ req ]
default_bits = 4096
x509_extensions = myexts

[ myexts ]
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
```

I'm not sure if the extensions must be set up exactly like this.

## Verity signing key

| Type | Size      | Extra info                    | Working? |
|------|-----------|-------------------------------|----------|
| RSA  | 4096 bits | Extensions as for kernel      | Yes      |
| RSA  | 2048 bits | As produced by `mkosi genkey` | Yes      |


## Expected PCR signatures

| Type | Size      | Working? |
|------|-----------|----------|
| RSA  | 4096 bits | No       |
| RSA  | 2048 bits | Yes      |

When creating the encrypted, local storage, a key is loaded into the TPM along with the conditions required to get access to the key.
Validating those conditions involves loading a public key into the TPM to verify a signature.
It may depend on your specific TPM, but with 4096 bit keys, I'd get errors.
With a 2048 bit key, everything was fine.

mkosi uses `SignExpectedPCRKey` to sign the expected PCR values that are embedded in the UKI.
If one is not provided, it will use `mkosi.key` if it exists.

## Secure boot key

(Add info)

## Repository signing key (sysupdate)

`SHA256SUMS` needs to be signed by a GPG key.
Not sure if there are any special requirements for the key.
