# qmail

Customized qmail stack for [Kan-Linux](https://github.com/kan-linux). Easy to install on common Linux distros.

Build your own email server from full source with minimal setup — on a laptop, a home server, or in the cloud.


## Quick Start

```sh
git clone https://github.com/kan-linux/qmail.git
cd qmail
sudo ./build-qmail-stack.sh

# start services
sudo /etc/init.d/smtp
sudo /etc/init.d/pop3

# start TLS services (SMTP 465, POP3 995)
sudo /etc/init.d/smtps
sudo /etc/init.d/pop3s

# smoke test
sudo ./test-qmail-stack.sh
```

## Usage

```sh
sudo ./build-qmail-stack.sh            # full build + install (with DKIM)
sudo ./build-qmail-stack.sh clean      # clean source trees
sudo ./build-qmail-stack.sh uninstall  # remove install (not reversible)
sudo ./build-qmail-stack.sh smoke-test # quick local test
./build-qmail-stack.sh help            # show help
```

### Useful env vars

| Var | Default | Meaning |
|---|---|---|
| `QMAIL_HOSTNAME` | `$(hostname -f)` | mail hostname |
| `QMAIL_DOMAIN` | from hostname | virtual domain |


## What this stack adds
- Customized and verified patches
- One-shot install script, plus a test script for local smoke checks
- Init scripts in the classic qmail style: `/etc/init.d/smtp`, `/etc/init.d/pop3`
- TLS (implicit) for SMTP and POP3 via a small `sslwrap` around `tcpserver`:
  - SMTP over TLS: port 465 (`/etc/init.d/smtps`)
  - POP3 over TLS: port 995 (`/etc/init.d/pop3s`)
  - Cert: `/var/qmail/control/servercert.pem` (self-signed by default; replace with a real cert)

### Mail client settings (TLS)

| Protocol | Host | Port | Security |
|---|---|---|---|
| SMTP | your mail hostname | 465 | SSL/TLS |
| POP3 | your mail hostname | 995 | SSL/TLS |

Plain ports 25 and 110 stay available for local tests. Prefer the TLS ports for real use.

After install, add the printed DNS records (A, MX, DKIM TXT) before sending real mail.

## Contributing
- Contributors can open PRs
- Collaborators will be invited based on contributions
- Maintainers can push branches and merge PRs into `master`
- Any help with managing issues, PRs and projects is very appreciated!
- Read the [CONTRIBUTING.md](https://github.com/kan-linux/kan/blob/master/CONTRIBUTING.md) for more information

## Language Policy and AI Policy

- To facilitate clear and effective communication, all discussions, comments, documentation, and PRs in this project should be conducted in English, this ensures that all contributors can participate and collaborate effectively.
- English and Chinese are both fine for issues and discussions.
- Discussions, issues and PRs should include **human-written content**. **AI-assisted polish is accepted and welcomed**(many of us are non-native English speakers). What matters is not who typed the content but whether a human understands it.
- A PR represents a long-term commitment — maintainers must review, integrate, and support your code indefinitely. What matters is not who wrote the code but whether a human understands it: either fully, or at the 80–90% level, and is able to explain every change to reviewers, even with AI assistance.
- Fully AI-generated content and fully automated PRs are not permitted. We value human connection and communication over fully AI-driven interaction.

## Acknowledgements

- [D. J. Bernstein](https://cr.yp.to/djb.html) — qmail and ucspi-tcp
- [OpenDKIM](http://www.opendkim.org/) project
- The AI assistant, for technical discussion, design notes, and writing polish during this project

## License

MIT — see [LICENSE](LICENSE).

Upstream components keep their own licenses (qmail, OpenDKIM, vpopmail, ucspi-tcp).
