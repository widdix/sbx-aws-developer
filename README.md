# sbx-aws-developer

AWS for agents in [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/): the tools, and temporary credentials from your IAM Identity Center session on the host, with the AWS profiles chosen per sandbox.

- `aws-developer/` is a kit, published as `widdix/sbx-kit-aws-developer`: an image layered on top of an agent workload such as `claude`. It brings the tools and the AWS setup.
- `broker/` is the broker, published as `widdix/sbx-aws-developer`: a container on the host's Docker that hands temporary credentials for selected AWS profiles to one sandbox.

Requires `sbx` 0.45 or later and Docker. Tested with `sbx` 0.54. Both images come from Docker Hub, so nothing is installed or checked out on the host; the AWS CLI is only needed for `aws sso login`.

## AWS profiles

A sandbox gets the AWS profiles you assign to it, and no other. They are profiles of your `~/.aws/config` on the host, the names you pass to `aws --profile`. The examples below use `aws-profile-1` and `aws-profile-2`; replace them with yours. A profile qualifies when:

- it gets temporary credentials, typically from IAM Identity Center. Profiles with long-term access keys are refused, so these never reach a sandbox.
- its name consists of letters, digits, `.`, `_` and `-`.
- it sets a `region`, if the sandbox should have one. Otherwise set `AWS_REGION` in the sandbox or pass `--region`.

For example, `aws configure sso` creates profiles like these:

```ini
[sso-session my-sso]
sso_start_url = https://my-organization.awsapps.com/start
sso_region = eu-central-1
sso_registration_scopes = sso:account:access

[profile aws-profile-1]
sso_session = my-sso
sso_account_id = 111122223333
sso_role_name = DeveloperAccess
region = eu-central-1

[profile aws-profile-2]
sso_session = my-sso
sso_account_id = 444455556666
sso_role_name = ReadOnlyAccess
region = eu-central-1
```

Use profiles with an `sso_session`: their session is refreshed on its own until it ends. Profiles with `sso_start_url` directly in the profile stop working when their access token expires and need `aws sso login` again.

Sign in on the host before you start a sandbox:

```sh
aws sso login --sso-session my-sso
```

## Set up a project with `sbx env`

Put a `sbxenv.yaml` in the project. Only the two arguments at the top are yours to fill in:

```yaml
schemaVersion: "1"
agent: claude
workspace: .
args:
  profiles:
    default: aws-profile-1,aws-profile-2
    description: AWS profiles of the host that the sandbox may use, separated by commas
    pattern: "[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*"
  credentials:
    default: /Users/<you>/.sbx-aws-developer/my-project
    description: Directory on the host for the AWS credentials of this sandbox
kits:
  - widdix/sbx-kit-aws-developer:1.0.0
additionalWorkspaces:
  - path: ${{ env.args.credentials }}
    target: /mnt/aws-credentials
    readOnly: true
lifecycle:
  initialize:
    - name: Start the AWS credentials broker
      command: >-
        mkdir -p "${{ env.args.credentials }}";
        docker rm -f "sbx-aws-developer-$SBX_SANDBOX_NAME" >/dev/null 2>&1;
        docker run -d --name "sbx-aws-developer-$SBX_SANDBOX_NAME"
        --restart unless-stopped --init --user "$(id -u):$(id -g)"
        -v "$HOME/.aws:/home/sbx-aws-developer/.aws"
        -v "${{ env.args.credentials }}:/data"
        widdix/sbx-aws-developer:1.0.0 ${{ env.args.profiles }}
  preRemove:
    - name: Remove the AWS credentials broker
      command: >-
        docker stop "sbx-aws-developer-$SBX_SANDBOX_NAME";
        docker rm "sbx-aws-developer-$SBX_SANDBOX_NAME"
```

Then run `sbx env run` in the project directory.

- **`profiles`** are the [AWS profiles](#aws-profiles) the sandbox may use, separated by commas without spaces; `sbx` checks the list against the `pattern`. To change them, edit the default; the next `sbx env run` applies it, also when it attaches to an existing sandbox. For a single run, override it: `sbx env run --env-arg profiles=aws-profile-1`.
- **`credentials`** is the directory on the host where the broker writes the credentials and the sandbox reads them. Use a different directory for each project. It has to be an absolute path: `~` is not expanded here.
- The broker container is named after the sandbox, `sbx-aws-developer-$SBX_SANDBOX_NAME`, for example `sbx-aws-developer-claude-my-project`. `sbx` sets `SBX_SANDBOX_NAME` for the commands.
- `initialize` runs before every `create` and `run`. It replaces the broker each time, so changes to the profiles or a newer image take effect, and the credentials directory exists before the sandbox mounts it.
- Keep `workspace:`, even when `~/.sbxenv.yaml` sets one: without it, `sbx` rejects `additionalWorkspaces`.
- Kits and mounts apply only when a sandbox is created. Remove an existing sandbox of the project first, with `sbx env rm` or `sbx rm`.
- `sbx` asks you to approve the host commands. Read them: the file lies in the workspace, so the agent can change it. A changed profile list or command shows up in that approval before it takes effect.
- The paths are personal, so keep the file out of version control, for example with `sbxenv.yaml` in `.gitignore`.
- The commands are written for the shell on macOS and Linux. `--user` makes the files the broker writes yours; Docker Desktop does that on its own, but on Linux it is required.

`sbx env` is experimental; see the [environment file documentation](https://docs.docker.com/ai/sandboxes/configuration/environment-files/).

## Without `sbx env`

Start the broker, then create the sandbox with the kit and the credentials directory:

```sh
mkdir -p ~/.sbx-aws-developer/my-project
docker run -d --name sbx-aws-developer-my-project --restart unless-stopped --init \
  --user "$(id -u):$(id -g)" \
  -v ~/.aws:/home/sbx-aws-developer/.aws \
  -v ~/.sbx-aws-developer/my-project:/data \
  widdix/sbx-aws-developer:1 aws-profile-1,aws-profile-2

cd my-project
sbx run claude --kit widdix/sbx-kit-aws-developer:1.0.0 . ~/.sbx-aws-developer/my-project:/mnt/aws-credentials:ro
```

To change the profiles, remove the broker with `docker rm -f sbx-aws-developer-my-project` and start it again with the new list. A running sandbox picks up the change within a minute.

## Operate a broker

A broker is a plain container, named `sbx-aws-developer-<sandbox>` with `sbx env`:

| Task | Command |
|---|---|
| List the brokers | `docker ps --filter name=sbx-aws-developer-` |
| Show the exported profiles with account, expiration and errors | `docker exec <broker> sbx-aws-developer-broker --status` |
| Show the log | `docker logs <broker>` |
| Stop it; this deletes the exported credentials | `docker stop <broker> && docker rm <broker>` |
| Update the image | `docker pull widdix/sbx-aws-developer:1`, then `sbx env run`, which replaces the broker |

A broker runs until it is stopped, also across restarts of Docker, and uses about 5 MB of memory.
When your SSO session expires, the exported credentials run out and the error in the sandbox asks for `aws sso login` on the host. The broker picks up the new session within a minute.

## Tools

| Tool | Default version | Where it comes from |
|---|---|---|
| AWS CLI | 2.41.1 | Official installer, in `/usr/local/aws-cli` |
| Node.js with npm and npx | 24.22.3 | Official release tarball, in `/opt/node` |
| jq | Version of the agent image | Debian package shipped by the agent workload |
| mandoc | 1.14.6 | Static build, renders `aws help` |

Each tool version is a kit argument with a default in `aws-developer/aws-developer.yaml`.
Override one for a single sandbox:

```sh
sbx run claude --kit widdix/sbx-kit-aws-developer:1.0.0 --kit-arg nodeVersion=22.23.5
```

To change it for everyone, edit the default and release a new kit version. The build fails if the installed version does not match.

The kit also sets `AWS_PAGER` to empty, and allows egress to `**.amazonaws.com`, `**.api.aws`, `**.amazonaws.eu` and `registry.npmjs.org`.

## How it works

An agent gets access to the AWS profiles you assign to its sandbox, without signing in itself:

1. On the host, one broker container per sandbox runs `aws configure export-credentials` for each of its profiles every minute. The AWS CLI in the broker reads your IAM Identity Center session from the mounted `~/.aws`, fetches temporary role credentials, and refreshes the session when needed. The broker replaces the credentials before they expire.
2. It writes them to the credentials directory, which the sandbox mounts read-only at `/mnt/aws-credentials`.
3. In the sandbox, `AWS_CONFIG_FILE` points to the config file in that directory. The AWS CLI and the SDKs pick a profile with `AWS_PROFILE`, read its credentials through `credential_process` and fetch new ones on their own.

The credentials directory holds two files:

| File | Content |
|---|---|
| `aws-config` | The AWS config file for the sandbox: exactly the assigned profiles |
| `credentials.json` | Per profile `AccessKeyId`, `SecretAccessKey`, `SessionToken`, `Expiration` and `AccountId`, and why a profile has no credentials |

`aws-config` also maps accounts to profiles. Each profile states its account and region, which the broker takes from `sso_account_id` and `region` in your `~/.aws/config`. Set `AWS_REGION` in the sandbox to use another region:

```ini
[profile aws-profile-1]
aws_account_id = 111122223333
region = eu-central-1
credential_process = aws-credential-process aws-profile-1
```

The broker runs as your user and mounts `~/.aws` read-write, because the AWS CLI writes the SSO token cache when it refreshes the session.

### Security

- Only temporary credentials reach a sandbox. The broker refuses profiles with long-term access keys and reports them as an error.
- A sandbox can read the credentials of every profile assigned to it, whichever one `AWS_PROFILE` selects, and nothing else: it mounts only its own credentials directory. Assign only profiles that the agent may use, and prefer roles with least privilege.
- With `sbx env`, the profiles are part of `sbxenv.yaml` in the workspace, which the agent can edit. A change takes effect only through a host command you approve.
- Credentials are temporary and are no longer refreshed once the broker stops or your SSO session expires, but credentials already handed out stay valid until their expiration (the session duration of the permission set: one hour by default, up to twelve). Copies an agent made are not revoked by stopping the broker.
- The SSO session and its refresh token stay on the host. The sandbox never sees `~/.aws`; the brokers run on the host's Docker, not on the sandbox's own Docker daemon. A broker has no access to Docker itself.
- The kit allows egress to all AWS endpoints, so credentials can be used against any account and region they are valid for.

Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Publish

GitHub Actions builds both images for `linux/amd64` and `linux/arm64` and publishes them to Docker Hub: the broker with `.github/workflows/broker-image.yml`, which tests it first, and the kit with `.github/workflows/kit-image.yml`.

| Event | `widdix/sbx-aws-developer` (broker) | `widdix/sbx-kit-aws-developer` (kit) |
|---|---|---|
| Tag `v1.2.3` pushed | `1.2.3`, `1.2`, `1`, `latest` | `1.2.3`, `1.2`, `1` |
| Push to `main` | `main`, `sha-<commit>` | `main` |
| Pull request | Built and tested, not published | Built, not published |

To release, set `version` in `aws-developer/aws-developer.yaml` and push a matching tag: `git tag v1.0.0 && git push origin v1.0.0`. The kit workflow fails if the two differ. Reference the kit by its full version, as Docker recommends: `latest` can move to a kit that needs a newer `sbx`.

The workflows log in to Docker Hub with the repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`, a personal access token with read and write scope for the `widdix` namespace.

To work on the images locally, build them from the checkout:

```sh
docker build -t widdix/sbx-aws-developer:1 broker
sbx run claude --kit ./aws-developer . ~/.sbx-aws-developer/my-project:/mnt/aws-credentials:ro
```

In `sbxenv.yaml`, use the absolute path of `aws-developer` instead of the published kit.

## License

Apache License 2.0, see [LICENSE](LICENSE). The kit image bundles third-party software under its own licenses: AWS CLI (Apache-2.0), Node.js (MIT) and mandoc (ISC). The broker image is based on Debian and contains the AWS CLI and jq.
