# Deploy SFApp to Azure Container Apps (GitHub Actions only)

Deploys the Streamlit app as an **Azure Container App** via the
[`deploy-azure.yml`](../.github/workflows/deploy-azure.yml) workflow. Same
pattern as the `data-infrastructure` deploy: **GitHub OIDC** for Azure auth (no
stored passwords), **Docker build + push on the runner**, and the Container App
pulls from ACR using a **user-assigned managed identity**.

> The old [`DEPLOY.md`](./DEPLOY.md) / `azuredeploy.json` describe a **VM**
> deployment and are kept for reference. This file supersedes them.

---

## What the workflow does

1. `azure/login@v3` with OIDC (federated managed identity — nothing to rotate).
2. `az acr login` + `docker build` + `docker push` of `sfapp:<sha>` and `:latest`.
3. Creates the Container App on first run (or updates the image on later runs),
   configured to pull from ACR via the managed identity in `ACR_PULL_IDENTITY_ID`.
4. Prints the public app URL in the run summary.

It runs on push to `main` and on manual dispatch (Actions → *Deploy to Azure
Container Apps* → *Run workflow*).

---

## One-time setup

### 1. Repository **variables** (Settings → Secrets and variables → Actions → *Variables*)

These mirror the names used in your other repos.

| Variable | Example / meaning |
|----------|-------------------|
| `ACR_NAME` | registry name only, e.g. `iitasfhub` |
| `ACR_LOGIN_SERVER` | `iitasfhub.azurecr.io` |
| `AZURE_RESOURCE_GROUP` | resource group holding ACR / the app |
| `CONTAINERAPP_NAME` | e.g. `sfapp` |
| `CONTAINERAPP_ENV` | managed environment name (created if missing) |
| `ACR_PULL_IDENTITY_ID` | **resource id** of the user-assigned managed identity with `AcrPull` on the registry |
| `AZURE_LOCATION` | region, e.g. `westeurope` — only needed if the environment must be created |
| `SERVICE_ACCOUNT` | *(optional)* Earth Engine service-account email; defaults to the current `sampling-frames@…` account |
| `MIN_REPLICAS` | *(optional)* `1` = no cold starts (default); `0` = scale-to-zero |
| `MAX_REPLICAS`, `ACA_CPU`, `ACA_MEMORY` | *(optional)* defaults `3`, `1.0`, `2.0Gi` |

### 2. Repository **secrets** (→ *Secrets*)

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | client id of the deployer managed identity / app |
| `AZURE_TENANT_ID` | tenant id |
| `AZURE_SUBSCRIPTION_ID` | subscription id |
| `GOOGLE_CREDENTIALS_JSON` | the **entire contents** of the Earth Engine service-account JSON key |

### 3. Add the federated credential for this repo (admin, once)

Your deployer managed identity already exists (you use it for the other apps).
Add a federated credential that trusts **this** repo's `main` branch so OIDC
login works here too:

```bash
RG=<resource-group-of-the-identity>
MI_NAME=<existing-deployer-identity-name>
az identity federated-credential create -g "$RG" --identity-name "$MI_NAME" \
  --name sfapp-main --issuer https://token.actions.githubusercontent.com \
  --subject "repo:IITA-Fertilizer-Soil-Health-Hub-WAS/SFApp:ref:refs/heads/main" \
  --audiences api://AzureADTokenExchange
```

The identity needs, scoped to the resource group (or the ACR):
`AcrPush` (to push the image) and `Contributor` on the Container App /
environment (to create/update it). The **pull** identity
(`ACR_PULL_IDENTITY_ID`) needs `AcrPull`; it can be the same identity or a
separate one, as in your other deployments.

---

## Earth Engine credentials at runtime

The app initializes Earth Engine at startup from a service-account key *file*.
Container Apps don't mount files, so the key is delivered as a Container App
*secret* (`google-credentials`, from `GOOGLE_CREDENTIALS_JSON`) and exposed to
the container as an env var; [`docker-entrypoint.sh`](../docker-entrypoint.sh)
writes it to `GOOGLE_APPLICATION_CREDENTIALS` (`/var/secrets/google/key.json`)
before launching Streamlit. `AUTH_MECHANISM=service_account` is set
automatically, so no interactive login is attempted. The GCP project is read
from the key file.

---

## Custom domain — `samplingframes.akilimo.org`

Bind the hostname on the Container App so it serves the app over a free managed
certificate. Note: the default `*.azurecontainerapps.io` FQDN keeps serving too
— Azure Container Apps has no native switch to disable it. (An earlier nginx
host-gate that 404'd the default FQDN was removed; if locking it down becomes a
requirement, Azure Front Door with origin restriction is the clean route.)

One-time bind:

```bash
RG=data-infrastructure-rg
APP=sfapp
HOST=samplingframes.akilimo.org

# 1) Verification id for the DNS TXT record
az containerapp show -g "$RG" -n "$APP" --query properties.customDomainVerificationId -o tsv
```

`akilimo.org` is served by **Cloudflare**, so add these in the **Cloudflare**
dashboard (NOT an Azure DNS zone — that zone is not authoritative and Azure's
validator won't see it):
- `CNAME  samplingframes  →  sfapp.delightfulwater-14d0d55a.eastus.azurecontainerapps.io`, **Proxy status: DNS only (grey cloud)**
- `TXT    asuid.samplingframes  →  <customDomainVerificationId from above>`

Then issue a free managed certificate and bind the hostname:

```bash
ENV=<container-apps-environment-name>
az containerapp hostname add  -g "$RG" -n "$APP" --hostname "$HOST"
az containerapp hostname bind -g "$RG" -n "$APP" --hostname "$HOST" \
  --environment "$ENV" --validation-method CNAME
```

After this, `https://samplingframes.akilimo.org` serves the app. Keep the
Cloudflare record **grey-cloud** (Container Apps terminates TLS with its own
managed cert; a Cloudflare proxy in front would clash).

---

## Cold-start notes

The image was slimmed from a Miniconda + mamba + Google Cloud SDK base (several
GB) to a `python:3.11-slim` base with only the locked Python wheels — a much
smaller image that pulls and starts far faster. For **zero** cold starts keep
`MIN_REPLICAS` at `1`; for lowest cost set it to `0` and accept a short (now
much faster) cold start on the first request after idle.
