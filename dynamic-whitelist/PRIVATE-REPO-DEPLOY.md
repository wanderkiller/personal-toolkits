# Private Repo Deployment

The repository is private, so a VPS cannot clone it unless you give that VPS
GitHub credentials. Use one of these two methods.

## Option A: Tarball Upload

This is the simplest and avoids putting GitHub credentials on VPS machines.

On your local machine:

```bash
cd D:/GitHubRepo/personal-toolkits/dynamic-whitelist
bash scripts/package-release.sh dynamic-whitelist
```

Upload the archive to each VPS:

```bash
scp dist/dynamic-whitelist.tar.gz root@HK_PUBLIC_IP:/opt/
scp dist/dynamic-whitelist.tar.gz root@GZ_PUBLIC_IP:/opt/
```

On each VPS:

```bash
sudo mkdir -p /opt/dynamic-whitelist
sudo tar -xzf /opt/dynamic-whitelist.tar.gz -C /opt/dynamic-whitelist
cd /opt/dynamic-whitelist
```

Then run the matching Docker script:

HK VPS:

```bash
sudo bash scripts/docker-up-hk.sh
```

Guangzhou VPS:

```bash
sudo bash scripts/docker-up-gz.sh
```

On the first run, each script creates an env file and exits. Edit the env file,
then run the same command again.

## Option B: GitHub Deploy Key

Use this if you want the VPS to pull updates directly from the private repo.

On each VPS:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/github-personal-toolkits -C "personal-toolkits-vps"
cat ~/.ssh/github-personal-toolkits.pub
```

In GitHub:

```text
Repo -> Settings -> Deploy keys -> Add deploy key
```

Add the public key. Read-only is enough for deployment.

On the VPS:

```bash
cat >> ~/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github-personal-toolkits
  IdentitiesOnly yes
EOF

chmod 600 ~/.ssh/config ~/.ssh/github-personal-toolkits
ssh -T git@github.com
git clone git@github.com:wanderkiller/personal-toolkits.git
cd personal-toolkits/dynamic-whitelist
```

Then run:

```bash
sudo bash scripts/docker-up-hk.sh
```

or:

```bash
sudo bash scripts/docker-up-gz.sh
```

