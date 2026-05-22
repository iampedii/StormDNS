# WhiteDNS and God-Mode Tutorial

This guide explains how to deploy StormDNS with `stormdns_god_mode.sh` and how to manage the running deployment with the `WhiteDNS` menu script.

`stormdns_god_mode.sh` is the installer/rebuilder. It creates the Docker backend cluster, proxy service, watchdog service, config files, and encryption key.

`WhiteDNS` is the management tool. Use it after god mode has already created a working deployment.

## When to Use Each Script

Use `stormdns_god_mode.sh` for:

- First deployment on a server.
- Rebuilding the whole god-mode deployment.
- Changing the total backend container count from scratch.
- Replacing old Docker containers, images, Compose files, services, and key material.

Use `WhiteDNS` for:

- Restarting the current containers.
- Stopping the current containers and services.
- Updating the encryption key and applying it to the running Docker deployment.
- Adding more tunnel domains and applying them to the running Docker deployment.
- Showing the current config, client values, service state, and container state.

## Prerequisites

Run these scripts on the Linux server that will receive DNS traffic.

You need:

- Root access.
- A public server IP.
- A delegated DNS subdomain, such as `v.example.com`.
- UDP port `53` open on the server firewall and hosting provider firewall.
- The StormDNS server package or repository files present on the server.

Example DNS records:

```text
ns.example.com  A   1.2.3.4
v.example.com   NS  ns.example.com
```

If you use Cloudflare, the `A` record for `ns.example.com` must be `DNS only`, not proxied.

## First Deployment With God Mode

Go to the StormDNS directory:

```bash
cd /root/StormDNS
```

Run god mode:

```bash
sudo ./stormdns_god_mode.sh
```

The script shows the WhiteDNS banner, then checks Docker, Docker Compose, Python, Go, systemd, and required runtime tools.

On the first run, it asks for:

- The tunnel domain, for example `v.example.com`.
- The number of backend containers to run.

For a small server, start with `2` to `5` containers. For a stronger server, choose a higher number based on CPU and memory.

When the script finishes, it prints client values similar to:

```text
StormDNS client values:
  DOMAIN = ["v.example.com"]
  DATA_ENCRYPTION_METHOD = 1 (XOR)
  ENCRYPTION_KEY = 1234567890abcdef1234567890abcdef
  ENCRYPTION_SECRET = 1234567890abcdef1234567890abcdef
```

Save these values. The client must use the same domain, encryption method, and encryption key.

## What God Mode Creates

After a successful run, god mode creates or updates:

```text
/root/StormDNS/server_config.toml
/root/StormDNS/encrypt_key.txt
/root/StormDNS/stormdns-docker/
/root/StormDNS/stormdns-proxy
/root/StormDNS/stormdns_watchdog.py
/root/StormDNS/stormdns-warp-egress.sh
/etc/systemd/system/stormdns-proxy.service
/etc/systemd/system/stormdns-watchdog.service
/etc/systemd/system/stormdns-warp-egress.service
```

The Docker containers are named:

```text
stormdns-1
stormdns-2
stormdns-3
...
```

The Docker images may be named:

```text
stormdns-docker-stormdns-1
stormdns-docker-stormdns-2
stormdns-docker-stormdns-3
...
```

## Running God Mode Again

Running god mode again is destructive by design. It treats the run as a clean rebuild.

On rerun, it warns that it will:

- Stop StormDNS watchdog/proxy services.
- Remove old StormDNS Docker containers and networks.
- Remove old god-mode Docker images.
- Replace the Docker project files.
- Generate and apply a new encryption key.
- Recreate all selected backend containers.

Run:

```bash
sudo ./stormdns_god_mode.sh
```

Confirm the warning only if you want to replace the deployment.

The script asks for the domain again. The existing domain list is shown as the default. Press Enter to keep it, or type a new comma-separated list:

```text
Enter tunnel domain(s), comma-separated [v.example.com]:
```

It also asks how many containers should run:

```text
How many total StormDNS containers should run? [5]: 2
```

If you enter `2`, the rebuilt deployment should create only `stormdns-1` and `stormdns-2`.

For non-interactive rebuilds, pass the container count and `--yes`:

```bash
sudo ./stormdns_god_mode.sh --instances 2 --yes
```

Important: because rerun generates a new key, all clients must be updated with the new `ENCRYPTION_KEY`.

## Using the WhiteDNS Management Menu

Run WhiteDNS after god mode has completed at least once:

```bash
cd /root/StormDNS
sudo ./WhiteDNS
```

WhiteDNS shows an ASCII banner and this menu:

```text
0 -> Restart Containers
2 -> Stop containers
3 -> Update encryption Key
4 -> Add new domain
5 -> Show config
6 -> Exit
```

WhiteDNS requires the god-mode deployment files to exist:

```text
server_config.toml
stormdns-docker/docker-compose.yml
stormdns-docker/config/
```

If those files do not exist, run god mode first.

## Menu Option 0: Restart Containers

Use this when you want to reload the current config into Docker and restart all backend containers, proxy, watchdog, and WARP egress helper.

WhiteDNS will:

- Copy `server_config.toml` into `stormdns-docker/config/server_config.toml`.
- Copy the encryption key into `stormdns-docker/config/encrypt_key.txt`.
- Rebuild/recreate the Docker containers from the current Docker project.
- Restart `stormdns-proxy.service`.
- Restart `stormdns-watchdog.service`.
- Restart `stormdns-warp-egress.service` if it exists.

Choose:

```text
0
```

## Menu Option 2: Stop Containers

Use this to stop the current god-mode runtime.

WhiteDNS asks for confirmation, then stops:

- `stormdns-watchdog.service`
- `stormdns-proxy.service`
- `stormdns-warp-egress.service`
- Docker containers from the Compose project

Choose:

```text
2
```

This stops the service. It does not delete the config files.

## Menu Option 3: Update Encryption Key

Use this to rotate the encryption key without running a full god-mode rebuild.

Choose:

```text
3
```

WhiteDNS shows the current encryption method and required key length. You can:

- Press Enter to auto-generate a new valid key.
- Type your own key with the exact required length.

After the key is updated, WhiteDNS:

- Writes the new key to `encrypt_key.txt`.
- Copies it into the Docker config directory.
- Rebuilds/recreates the containers.
- Restarts the proxy and watchdog services.
- Prints the new client values.

Important: every client must be updated with the new `ENCRYPTION_KEY`. Old clients will stop connecting until they use the new key.

## Menu Option 4: Add New Domain

Use this to add another tunnel domain to the server config.

Choose:

```text
4
```

Enter one or more domains separated by commas:

```text
test.example.com, v2.example.com
```

WhiteDNS:

- Adds new domains to `DOMAIN` in `server_config.toml`.
- Avoids duplicates.
- Copies the updated config into Docker.
- Rebuilds/recreates the containers.
- Restarts the proxy and watchdog services.
- Prints the updated client values.

The client must use one of the domains in its `DOMAINS` value.

## Menu Option 5: Show Config

Use this to display:

- StormDNS root directory.
- Docker project directory.
- Host config path.
- Docker config path.
- Key file path.
- Client values.
- systemd service states.
- Docker Compose container state.

Choose:

```text
5
```

This is the safest way to copy the current client values after changes.

## Menu Option 6: Exit

Choose:

```text
6
```

This exits the menu without changing anything.

## Checking the Deployment Manually

Show containers:

```bash
docker ps
```

Show the Compose project:

```bash
cd /root/StormDNS/stormdns-docker
sudo docker compose ps
```

Show proxy status:

```bash
sudo systemctl status stormdns-proxy.service --no-pager
```

Show watchdog status:

```bash
sudo systemctl status stormdns-watchdog.service --no-pager
```

Show logs:

```bash
sudo journalctl -u stormdns-proxy.service -n 100 --no-pager
sudo journalctl -u stormdns-watchdog.service -n 100 --no-pager
```

Check UDP port `53`:

```bash
sudo ss -lunp | grep ':53'
```

## Backups

Both scripts create backups before replacing important files.

Backups are written under:

```text
/root/StormDNS/stormdns-backups/
```

God-mode backups end with:

```text
-god-mode
```

WhiteDNS backups end with:

```text
-whitedns
```

## Common Problems

### I selected 2 containers, but more containers or images still appear

Run:

```bash
docker ps -a | grep stormdns
docker images | grep stormdns
```

Current god mode removes old containers named `stormdns-N` and old images named like `stormdns-docker-stormdns-N` during redo.

If you still see stale objects from an older manual deployment, remove them manually after confirming they belong to StormDNS:

```bash
sudo docker rm -f stormdns-3 stormdns-4 stormdns-5
sudo docker rmi -f stormdns-docker-stormdns-3 stormdns-docker-stormdns-4 stormdns-docker-stormdns-5
```

Then rerun god mode:

```bash
sudo ./stormdns_god_mode.sh
```

### Port 53 is already in use

Find the owner:

```bash
sudo ss -lunp | grep ':53'
```

God mode can stop common DNS services after confirmation. If the conflict remains, disable the service that owns port `53`, then rerun god mode.

### Clients stopped working after a god-mode rerun

God-mode redo generates a new encryption key. Update every client with the new values printed at the end:

```text
DOMAIN
DATA_ENCRYPTION_METHOD
ENCRYPTION_KEY
```

If you only want to add a domain or rotate a key without a full destructive rebuild, use `WhiteDNS`.

### WhiteDNS says god mode must run first

WhiteDNS depends on the Docker project created by god mode. Run:

```bash
sudo ./stormdns_god_mode.sh
```

After the first successful deployment, run:

```bash
sudo ./WhiteDNS
```

## Recommended Workflow

For a new server:

```bash
cd /root/StormDNS
sudo ./stormdns_god_mode.sh
sudo ./WhiteDNS
```

For normal management after setup:

```bash
sudo ./WhiteDNS
```

For a full clean rebuild:

```bash
sudo ./stormdns_god_mode.sh
```

For automation:

```bash
sudo ./stormdns_god_mode.sh --instances 2 --yes
```

