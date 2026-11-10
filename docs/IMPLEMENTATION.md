# Implementation ledger

Baseline: sing-box 1.14.4; upstream command reference 6082f1bf70ed4550a5fbd5c9fe147ba5228189d5.

The implementation is original Bash 5 + jq. The upstream installer is never executed.

Implemented checkpoints:

1. Independent node records, URI codecs, renderer, transactional application.
2. Certbot DNS-01, versioned certificate deployment, optional Nginx.
3. Installation, import/export, recovery, Docker verification and recorded results.

External acceptance: real Cloudflare staging requires a dedicated domain and a token supplied interactively. Neither is copied from DMIT.

Known validation boundaries are maintained in VERIFICATION.md. The project does not advertise an unverified distro/architecture as passing.
