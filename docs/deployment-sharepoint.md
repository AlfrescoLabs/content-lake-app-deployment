# SharePoint Connector - Deployment and Demo Site Setup

This document describes how to set up and test the SharePoint Online connector, by three routes: against
the mock Graph service, against a real Microsoft 365 tenant with an Entra ID app registration, and against
a real OneDrive for Business drive with no app registration at all.

## Table of Contents

- [Mock Graph Service](#mock-graph-service)
- [Demo Site Structure](#demo-site-structure)
- [Setting Up a Real SharePoint Site](#setting-up-a-real-sharepoint-site)
- [Demo Against a Real OneDrive With No App Registration](#demo-against-a-real-onedrive-with-no-app-registration)
- [Connector Configuration](#connector-configuration)
- [Running Tests](#running-tests)

---

## Mock Graph Service

The SharePoint connector ships with a mock Microsoft Graph service that runs without requiring a
Microsoft 365 tenant. The mock (`mock-graph`) serves Graph API responses from fixture files and
is used by the end-to-end test suite.

### Why the Mock Exists

Registering an Entra ID application is disabled in this tenant, and SharePoint sites where a developer
is only a member return truncated ACLs that cannot validate permission mapping. The mock allows:

- Building and demonstrating the connector without tenant access
- Testing ACL mapping with known permission fixtures
- Verifying paging, delta feeds, and throttling behavior
- Running the full E2E suite against a known, reproducible structure

### What the Mock Faithfully Reproduces

The mock is designed to catch connector bugs that would only surface against the real Graph API:

1. **Opaque @odata.nextLink paging** - $skip is ignored, just like Graph
2. **302 redirect for /content** - Downloads go through pre-authenticated URLs
3. **410 Gone for expired delta tokens** - Delta sync can expire and require full re-sync
4. **Preference-Applied headers** - Only honoured preferences are listed

### Running the Mock

```bash
# Start with demo stack
cd content-lake-app-deployment
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
CONNECTOR_SOURCE_TYPE=sharepoint SHAREPOINT_AUTH_MODE=static-token \
SHAREPOINT_ACCESS_TOKEN=mock-token SHAREPOINT_CLIENT_ID=mock \
SHAREPOINT_DRIVE_IDS='b!mock-drive-id' \
SHAREPOINT_GRAPH_BASE_URL=http://mock-graph:8099/v1.0 \
SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0 \
  docker compose --profile alfresco --profile connector --profile sharepoint-mock up -d

# The mock is accessible at localhost:8099
curl -s http://localhost:8099/mock-diagnostics/requests | jq .
```

---

## Demo Site Structure

The mock's fixture tree (`content-lake-app/plugins/sharepoint-connector/src/test/resources/fixtures/`)
holds **10 documents** in **6 folders**, designed to test permissions, scoping, MIME filtering, delta sync
and ACL mapping.

### Folder Structure

```
drive root (b!mock-drive-id:root)
  public/           f-public      inherits "Everyone except external users"
    quarterly-review.txt          pangolin-ledger-quarterly
    incident-log.md               pangolin-ledger-incident   (markdown)
    quarterly-report.pdf          pangolin-ledger-pdf-report (PDF)
    obsolete-note.txt             pangolin-ledger-obsolete   (deleted in delta change 1)
    widely-shared.txt             permissions over two pages
    unreadable-acl.txt            its permissions read fails
  restricted-user/  f-user
    named-grant.txt               pangolin-ledger-named      (one named user)
  restricted-group/ f-group
    group-grant.txt               pangolin-ledger-group      (one group only)
  org-link/         f-orglink
    org-wide.txt                  pangolin-ledger-orgwide    (organisation link, plus an anonymous one)
  nested/           f-nested
    level-two/      f-level-two
      deep-document.txt           pangolin-ledger-deep       (users-scoped sharing link)
```

### Document Details

| File Name | Item ID | MIME Type | Sentinel Phrase | Permission Scope |
|-----------|---------|-----------|-----------------|------------------|
| quarterly-review.txt | i-quarterly | text/plain | pangolin-ledger-quarterly | Inherited |
| incident-log.md | i-incident | text/markdown | pangolin-ledger-incident | Inherited |
| quarterly-report.pdf | i-report | application/pdf | pangolin-ledger-pdf-report | Inherited |
| obsolete-note.txt | i-removed | text/plain | pangolin-ledger-obsolete | Inherited (deleted) |
| widely-shared.txt | i-paged | text/plain | - | Paged permissions |
| unreadable-acl.txt | i-noacl | text/plain | - | ACL read fails |
| named-grant.txt | i-named | text/plain | pangolin-ledger-named | Named user |
| group-grant.txt | i-group | text/plain | pangolin-ledger-group | Group only |
| org-wide.txt | i-orgwide | text/plain | pangolin-ledger-orgwide | Organisation link |
| deep-document.txt | i-deep | text/plain | pangolin-ledger-deep | Users-scoped link |

### Sentinel Phrases

Each document contains a unique "pangolin-ledger-*" phrase used by tests to verify:
- The document was indexed
- Text extraction worked correctly
- Search returns the expected results
- ACL filtering is applied correctly

### Permission Scenarios Tested

1. **Inherited** (public/*) - everyone in the tenant
2. **Named user** (restricted-user/named-grant.txt) - one user only
3. **Group only** (restricted-group/group-grant.txt) - group members only
4. **Organisation link** (org-link/org-wide.txt) - everyone in the tenant; the anonymous link grants nothing
5. **No ACL readable** (i-noacl) - the ACL read fails, so under the default `sharepoint.acl-fallback=fail-closed` the document is not ingested

### Test Scenarios Enabled

- **Full batch sync** - Every document indexed from the root walk
- **Delta sync** - Change feed reports incremental updates
- **Deletion** - obsolete-note.txt removed in delta change #1
- **MIME filtering** - quarterly-report.pdf excluded when `EXCLUDE_MIME_TYPES=application/pdf`
- **Path scoping** - Selecting f-orglink only indexes org-wide.txt
- **Nested folders** - Deep nesting (nested/level-two/deep-document.txt)
- **ACL mapping** - Each permission type (public, user, group, org link)
- **Browse API** - Tree navigation with inScope/traversable annotations

---

## Setting Up a Real SharePoint Site

To test the connector against a real Microsoft 365 tenant, create a SharePoint document library
that mirrors the mock fixture structure.

### Prerequisites

- Microsoft 365 tenant with SharePoint Online
- Admin access to create a site and document library
- Entra ID app registration (see below)
- PowerShell with SharePoint PnP module OR Graph API access

### Site Structure

Use the site's default document library ("Documents", path `Shared Documents`). Generate the files with:

```bash
./fixtures/create-sharepoint-demo-files.sh /tmp/content-lake-demo
```

It writes this tree, with the same file names and sentinel phrases as the mock fixtures, so the
assertions in `test/test-sharepoint.sh` match the same phrases against the real site:

```
Public/              quarterly-review.txt, incident-log.md, quarterly-report.pdf   (inherits)
UserScoped/          named-grant.txt      pangolin-ledger-named
GroupScoped/         group-grant.txt      pangolin-ledger-group
OrgLink/             org-wide.txt         pangolin-ledger-orgwide
Nested/LevelTwo/     deep-document.txt    pangolin-ledger-deep
Bulk/                bulk-001.txt to bulk-120.txt, more than one page of children  (inherits)
```

The `Public/` sentinels are `pangolin-ledger-quarterly`, `pangolin-ledger-incident` (markdown, so it takes
the extraction short-circuit) and `pangolin-ledger-pdf-report` (the mock's own PDF, so it takes the
extractor path). Every file also carries a run tag (`RUN_TAG`, a timestamp by default), so one upload cannot
be mistaken for another. Upload the generated folders by dragging them into the library in the browser.

### Permission Setup

**IMPORTANT: Never share fixtures with site-local groups** (site Owners, Members, or Visitors). These are
site-scoped principals with no Entra object ID, so the query-time group resolver cannot expand them. A
document shared only with such a group will be indexed with a correct ACL but retrievable by nobody, which
presents as a connector bug. Share with Entra ID / Microsoft 365 groups instead, which have directory object
IDs and are resolvable.

This is a limit of the product, not only of the fixtures. Content Lake honours grants to named users,
Entra ID groups, Microsoft 365 groups and organisation links. It does not expand site groups: Microsoft
Graph does not list their members, and SharePoint REST, which does, refuses app-only tokens obtained with a
client secret. So a site Member or Visitor who has no other grant cannot retrieve documents that inherit the
site's permissions. Only users named in a grant, the site owner for example, can. To make a library
searchable by its members, also share it directly with an Entra ID or Microsoft 365 group that holds them.

The inherited folders below are therefore readable only by users named in their grants. The suite queries
them as the user Graph names on `Public/quarterly-review.txt`.

Configure sharing permissions to match the test scenarios:

1. **Public, Nested and Bulk folders** - Do nothing. They inherit from the library
2. **UserScoped folder** - Stop sharing, then share with one named colleague, Can view
3. **GroupScoped folder** - Stop sharing, then share with one Entra ID or Microsoft 365 group, Can view
4. **OrgLink folder** - Share with an organisation link ("People in <your organisation>")

### PowerShell Setup Script

```powershell
# Connect to SharePoint
Connect-PnPOnline -Url "https://yourtenant.sharepoint.com/sites/content-lake-demo" -Interactive

# Create folders
Add-PnPFolder -Name "Public" -Folder "Shared Documents"
Add-PnPFolder -Name "UserScoped" -Folder "Shared Documents"
Add-PnPFolder -Name "GroupScoped" -Folder "Shared Documents"
Add-PnPFolder -Name "OrgLink" -Folder "Shared Documents"
Add-PnPFolder -Name "Nested" -Folder "Shared Documents"
Add-PnPFolder -Name "LevelTwo" -Folder "Shared Documents/Nested"

# Upload sample files
Add-PnPFile -Path "Public/quarterly-review.txt" -Folder "Shared Documents/Public"
Add-PnPFile -Path "Public/incident-log.md" -Folder "Shared Documents/Public"
Add-PnPFile -Path "Public/quarterly-report.pdf" -Folder "Shared Documents/Public"
Add-PnPFile -Path "UserScoped/named-grant.txt" -Folder "Shared Documents/UserScoped"
Add-PnPFile -Path "GroupScoped/group-grant.txt" -Folder "Shared Documents/GroupScoped"
Add-PnPFile -Path "OrgLink/org-wide.txt" -Folder "Shared Documents/OrgLink"
Add-PnPFile -Path "Nested/LevelTwo/deep-document.txt" -Folder "Shared Documents/Nested/LevelTwo"

# Set permissions (examples - adjust for your tenant)
Set-PnPFolderPermission -List "Shared Documents" -Identity "UserScoped" -User "testuser@yourtenant.com" -AddRole "Read" -ClearExisting
Set-PnPFolderPermission -List "Shared Documents" -Identity "GroupScoped" -Group "Project Team" -AddRole "Read" -ClearExisting
```

### Running the suite against the real site

`test/test-sharepoint-real.sh` runs the connector app-only (`client-credentials`) against the site and
checks the ACLs end to end. It is opt-in, like `test-sharepoint.sh`, and it writes nothing to the tenant.

```bash
make clean && make up-alfresco
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
GROUP_ID=<object id of the group GroupScoped/ is shared with> \
./test/test-sharepoint-real.sh
```

It reads every tenant value, the secret included, from a connection file outside any repository (default
`~/Downloads/credentials/sharepoint-connection.env`, mode 600), and never from `.env.local`: `run-tests.sh` and
`test-sharepoint.sh` load that file, and real-tenant values there would break both.

Before ingesting, it reads the fixtures' own permissions from Graph. A fixture that is not shared as the
README says stops the run with a setup message, not a connector failure. It then:

- records whether `Sites.Selected` allows the change feed and the permission reads;
- crawls and counts the documents (the 120 in `Bulk/` need a second page of children);
- creates an Alfresco caller named exactly as Graph names the shared user, case included, because the ACL
  stores the address verbatim, and checks the named file is retrievable by that caller only;
- checks that a valid Microsoft Graph token is refused by rag-service (the audience check), using the Azure
  CLI's own Graph token, so no sign-in is needed.

The suite runs rag-service with `membership-lookup=user` by default. Under it, rag-service reads a caller's
groups from the directory by address, which needs the application permission `User.ReadBasic.All`. That lets
the suite prove the group grant with an Alfresco caller named as a group member (`GROUP_MEMBER`, by default
the user named on the inherited fixture). The suite checks that membership in the directory first.
`MEMBERSHIP_LOOKUP=group` skips that check, because under `group` only an object-id caller has groups.

Two checks need a caller's own Entra token, which only an interactive sign-in can produce. Set
`ENTRA_BEARER_TOKEN` to an `access_as_user` token to run them; they are reported as skipped otherwise.

---

## Demo Against a Real OneDrive With No App Registration

Everything above needs either the mock or an Entra ID app registration. This section is the third route:
the shipped connector, unchanged, reading real content from a real OneDrive for Business drive, on the
local stack, with **no app registration at all**. It exists because a tenant that has closed self-service
application registration blocks both `client-credentials` and `device-code`, and a demo still has to be
possible.

It is a runbook for a human, not an unattended mode. Read "What this route cannot show" before promising
anything from it.

**How far this has been verified.** Steps 1 to 4 are confirmed against a real tenant: one Graph Explorer
token covers both halves, the connector authenticates and browses a real OneDrive drive, the group resolver
attaches to the `sharepoint` source against real Graph, and the proxy and Sources screen wiring are correct.
Steps 5 to 9, from the first sync onwards, are written from the connector's behaviour against the mock and
have **not** yet been run against a real drive. Treat the expected results there as predictions, and correct
this document when you run them.

### Why a personal drive, and not a shared site

Graph returns an item's permissions **relative to the caller**: the owner of an item gets every sharing
permission on it, a non-owner gets only the ones that apply to themselves. A delegated crawl of a site you
are merely a member of therefore produces an index whose ACLs are complete only for your own content and
silently missing everything else, which cannot demonstrate per-user filtering for anybody but you.

In your own OneDrive you own every item, so `/permissions` returns the complete set. It is the same
`driveItem` API a document library exposes, so `delta`, `/permissions`, `/content` and the sharing model
all behave identically.

A personal drive has no site groups, so the `siteUser` and `siteGroup` principal shapes are the one part
of the ACL mapper this route cannot exercise.

### Before you start

Ingesting OneDrive content into a local index and embedding it is data egress from the Microsoft 365
compliance boundary. **Every fixture is a file you author for this purpose.** Do not point this at real
business content, and delete the folder afterwards.

You also need:

- Docker, `curl`, `jq`, and the Azure CLI (`brew install azure-cli`)
- the AI inference backend on port 12434, since ingestion embeds
- the connector jar. `plugins/` is not in the reactor, so it builds separately:
  ```bash
  cd ../content-lake-app
  mvn -pl common/content-lake-spi -am install -DskipTests
  mvn -f plugins/sharepoint-connector/pom.xml package
  ```

### Step 1: Author the fixture content

One deletable top-level folder in your own OneDrive, shaped like the mock's fixture tree so the two are
comparable:

```
content-lake-demo/
  Public/              inherits from the parent, nothing shared     (a .md and a .pdf)
  UserScoped/          inheritance broken, shared with ONE colleague
  GroupScoped/         inheritance broken, shared with an Entra ID or M365 group only
  OrgLink/             an organisation-scoped sharing link
  Nested/LevelTwo/     depth, to prove traversal descends
```

Every file carries a unique sentinel phrase, because that is what the retrieval checks match on.
`fixtures/create-sharepoint-demo-files.sh` generates exactly that tree, with the sentinel phrases already
in place, ready to drag into OneDrive:

```bash
./fixtures/create-sharepoint-demo-files.sh /tmp/content-lake-demo
```

The file names and sentinel phrases are the mock fixtures' own, and `test-sharepoint.sh` matches on the
sentinel phrases, so a result from this route is directly comparable with a mock run. The folder names
differ from the mock's (`public`, `restricted-user`, ...), which no assertion depends on.

How to produce each ACL shape in the OneDrive web UI:

| Shape | How |
|---|---|
| Inherited | Do nothing. The files under `Public/` inherit from the drive root |
| Named user | Manage access, Stop sharing to clear inherited links, then Share with one colleague, Can view |
| Group only | The same, but share with a security group or Microsoft 365 group instead of a person |
| Organisation link | Share, then change the link type to People in `<your organisation>` |

Two traps:

- **Never share a fixture with the site's own Owners, Members or Visitors groups.** Those are site-local
  principals with no directory object id, so no resolver can expand them. The document is ingested with a
  correct ACL and is retrievable by nobody, which looks exactly like a connector bug.
- **Skip anonymous links.** Most tenants disable them, and the mapping rule is that they grant nothing to
  any authenticated principal, so there is nothing to assert.

Record the colleague's user principal name. Step 4 needs it.

### Step 2: Mint one token

Two halves need a credential, and the architecture keeps them deliberately apart: the connector reads
files, and the RAG service resolves the searching user's group membership. **One Graph Explorer token
measured sufficient for both**, which is the shortest path and the one to take.

Its consented scope set includes `Sites.Read.All` for the drive and `Directory.Read.All` plus
`User.Read.All` for `transitiveMemberOf`. Verify that before relying on it, because the scope set belongs to
Microsoft's application and can change:

```bash
T=$(cat /tmp/graph-token)
curl -s -H "Authorization: Bearer $T" 'https://graph.microsoft.com/v1.0/me/drive?$select=id,driveType' | jq -c .
curl -s -H "Authorization: Bearer $T" \
  'https://graph.microsoft.com/v1.0/users/<your-upn>/transitiveMemberOf/microsoft.graph.group?$select=id' \
  | jq 'if .error then .error.code else "groups: \(.value|length)" end'
```

A `driveType` of `business` and a group count are the two green lights. If the second call fails, fall back
to a second token for the resolver only, as described under "If the directory half is refused" below.

**Getting it.** Open Graph Explorer
(`https://developer.microsoft.com/graph/graph-explorer`), sign in, and copy the token from the Access
token tab. Graph Explorer is a Microsoft-published client that is pre-registered in every tenant, which is
what makes this work with nothing registered by you. While you are there, run `GET /me/drive?$select=id`
and keep the `id`: that is the drive id the connector needs, and there is no other supported way to find
it, since the connector takes a drive id directly and never calls `/me/drive`.

Do not try to consent an additional scope here. In a tenant that has centrally blocked user consent the
Consent button answers with a service-request demand, and it is not needed: a personal OneDrive is a
SharePoint site, so a `Sites.Read.All` token reads it.

**Reading the token's own claims** is the quickest way to see what you have, including which account it is
for and when it dies. A JWT payload is unpadded base64url, so `base64 -d | jq` truncates it and fails with
`Unfinished JSON term at EOF`; pad it first:

```bash
cut -d. -f2 /tmp/graph-token | python3 -c '
import sys,base64,json,datetime
d=sys.stdin.read().strip()
c=json.loads(base64.urlsafe_b64decode(d+"="*(-len(d)%4)))
print("upn ", c.get("upn"))
print("app ", c.get("app_displayname"))
print("exp ", datetime.datetime.fromtimestamp(c["exp"],datetime.timezone.utc).isoformat())
print("scp ", " ".join(sorted(c.get("scp","").split())))'
```

Take the UPN from that output rather than typing it: step 4 has to match it exactly.

**Lifetime is about 80 to 90 minutes**, and there is no refresh. When it expires, ingestion fails, and
because group resolution is fail-closed, SharePoint results disappear for **every** caller rather than
degrading to "group grants do not resolve". The symptom is an empty result set, not an error. Re-paste and
recreate the affected services to continue.

**If the directory half is refused.** Should the `transitiveMemberOf` check fail, the Azure CLI's own Graph
token covers the resolver on its own, and needs no registration either:

```bash
az login --allow-no-subscriptions     # the flag matters: the tenant may have no Azure subscription
az account get-access-token --resource-type ms-graph --query accessToken -o tsv > /tmp/dir-token
```

That token was measured to carry `Group.ReadWrite.All`, `User.Read.All` and `Directory.AccessAsUser.All`,
and **no files or sites scope at all**, so it can only ever be the resolver's half: `GET /me/drive` with it
answers 404. Feed it to `RAG_SECURITY_ENTRA_ACCESS_TOKEN` and keep the Graph Explorer token for
`SHAREPOINT_ACCESS_TOKEN`. Note that 404 rather than 403 is what an unscoped files request returns, so it is
not evidence that the drive is missing.

### Step 3: Bring the stack up

Start from an empty index. `make down` preserves volumes and a leftover index pollutes results.

```bash
make clean
docker compose -f ../nuxeo-deployment/compose.yaml up -d   # the demo profile includes Nuxeo
cp ../content-lake-app/plugins/sharepoint-connector/target/sharepoint-connector-1.0.0.jar connectors/
```

The jar has to be in `connectors/` first: `plugin-batch-ingester` is driven entirely by a mounted jar and
refuses to start with that directory empty.

Bring the base stack and the connector up in **one** invocation rather than `make up-demo` followed by
additions. The proxy's configuration is rendered from `CONNECTOR_SOURCE_TYPE` when its container is
created, so a proxy created without it routes `/api/sync` to the Alfresco ingester instead.

```bash
CONTENT_LAKE_GIT_CONTEXT=../content-lake-app \
CONTENT_LAKE_APP_UI_CONTEXT=../content-lake-app-ui \
CONTENT_LAKE_UI_GIT_CONTEXT=../alfresco-content-lake-ui \
NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
NGINX_ROOT_DIRECTIVE="proxy_pass http://content-lake-app-ui:80;" \
CONNECTOR_SOURCE_TYPE=sharepoint \
CONNECTORS_URL=/api/connectors \
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
SHAREPOINT_AUTH_MODE=static-token \
SHAREPOINT_ACCESS_TOKEN="$(cat /tmp/graph-token)" \
SHAREPOINT_CLIENT_ID=graph-explorer \
SHAREPOINT_DRIVE_IDS="${DRIVE_ID}" \
SHAREPOINT_FOLDER_PATHS=content-lake-demo \
SHAREPOINT_SOURCE_ID=onedrive-demo \
SHAREPOINT_PERMISSIONS_MODE=per-item \
RAG_SECURITY_ENTRA_ENABLED=true \
RAG_SECURITY_ENTRA_AUTH_MODE=static-token \
RAG_SECURITY_ENTRA_ACCESS_TOKEN="$(cat /tmp/graph-token)" \
  docker compose --profile demo --profile connector up --build -d
```

What each group is doing, since most of it is not obvious:

- `CONNECTORS_URL=/api/connectors` is what reveals the demo UI's Sources screen and its nav entry. It is
  empty by default, which hides the screen, because a deployment with no connector host would show one
  answering 502.
- `CONNECTOR_SYNC_USERNAME` and `CONNECTOR_SYNC_PASSWORD` have no compose defaults. The container refuses
  to start without them.
- `SHAREPOINT_CLIENT_ID` is the only unconditionally required setting in the connector's schema, so it
  needs a value even though `static-token` never uses it.
- `SHAREPOINT_SOURCE_ID` is set explicitly. It otherwise defaults to the first drive id, and deriving a
  source id from a resolved drive means a change in resolution silently renames the source, orphaning its
  cursor and its indexed documents.
- `SHAREPOINT_FOLDER_PATHS` keeps the crawl inside the fixture folder. Without it the pass walks the whole
  drive.
- Resource-unit metering keeps its defaults. **Do not copy `SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0` from
  the mock recipe**: that disables the throttle budget, which is safe against a mock and is not against a
  tenant.
- `SHAREPOINT_GRAPH_BASE_URL` is deliberately absent, so it stays at the real Graph endpoint. So is
  `RAG_SECURITY_ENTRA_GRAPH_BASE_URL`.
- The group cache keeps its 300-second default and **cannot be turned off from the deployment**:
  `RAG_SECURITY_GROUP_CACHE_TTL_SECONDS` is a real application property but it is not declared on the
  `rag-service` service in `compose.content-lake.yaml`, so setting it in the shell has no effect and the
  container never sees it. The consequence for a live demo is that a group membership or sharing change can
  take up to five minutes to show. The cache is in memory, so
  `docker compose ... up -d --no-deps --force-recreate rag-service` clears it immediately, which is the
  quicker move during a demo.

On startup, confirm the resolver attached itself to the right source type. Two registry lines are logged and
only the second is the live bean; the first, with `resolvers=[]` and `cacheTtlSeconds=0`, is a static
no-resolver fallback and is not your configuration:

```bash
docker compose logs rag-service | grep -E "Entra group resolver|Group resolution:"
# Entra group resolver is using a static bearer token. Development only: ...
# Entra group resolver active for source type 'sharepoint' against https://graph.microsoft.com/v1.0
# Group resolution: resolvers=[sharepoint, alfresco, nuxeo], failurePolicy=FAIL_CLOSED, cacheTtlSeconds=300
```

### Step 4: Create the demo callers

The RAG service authenticates a caller against a source that can authenticate one; on this stack that is
Alfresco. Create users whose **login names are exactly the principal strings the connector wrote**.

**Two are enough**, and this is the part worth getting right before doing more work than necessary: your own
user principal name, and one outsider that matches nothing. The group-scoped fixture alone proves per-user
filtering, because you are a member of the group and the outsider is not, so **no colleague has to be
involved at all**. Add a colleague's UPN only if you also want the named-grant shape.

The match is an exact term match on the stored ACL entry, so **casing matters**. Take the UPN from Graph
rather than typing it: `GET /users/{upn}?$select=userPrincipalName,mail` reports both, and they are not
guaranteed to agree with each other or with what you would have guessed.

```bash
for u in '<your-upn>' 'outsider@example.invalid'; do
  curl -sk -u admin:admin -X POST \
    "https://localhost/alfresco/api/-default-/public/alfresco/versions/1/people" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"${u}\",\"firstName\":\"${u}\",\"email\":\"${u}\",\"password\":\"demo-pw\"}"
done
```

A repeat answers 409, which is fine. Alfresco's REST API answers 405 to `DELETE /people/{id}`, so these
users cannot be removed afterwards.

This is not a trick. A credential that proves a single login produces one *untyped* caller identity, and
an untyped identity answers for every source type, so the string you logged in with is matched verbatim
against SharePoint principals. `SharePointAclMapper` emits the Entra object id, the `userPrincipalName`
and the `email` for each named-user grant, so a UPN-shaped login matches the ACL entry the connector
wrote. The same property is why the security model states that a source with no authenticator of its own
is not unreachable, it is reached under someone else's identity.

Be aware that this puts real colleagues' user principal names in a local user database as login names.
It belongs on a throwaway stack only.

### Step 5: Sync

Confirm the jar loaded, then read the auth state. The two live on different endpoints: `/api/connectors`
lists what loaded and anything that failed to, and the auth block is on the host's `/api/status`. Note that
the proxy exposes that same status as `/api/connector-status`, because `/api/status` on the base stack's
port belongs to `rag-service`.

```bash
curl -s -u admin:admin http://localhost:9096/api/connectors | jq .
curl -s -u admin:admin http://localhost:9096/api/status | jq .auth
```

The auth block reports the mode, the identity, whether the credential is currently usable, a remedy when it
is not, and `supportedInProduction: false` for `static-token`. It never contains the token:

```json
{ "mode": "static-token", "supportedInProduction": false, "identity": null,
  "lastRefreshedAt": null, "usable": true, "remedy": null }
```

Then sync, and poll the same status endpoint for the counts:

```bash
curl -s -u admin:admin -X POST 'http://localhost:9096/api/sync/configured' | jq .
curl -s -u admin:admin http://localhost:9096/api/status | jq '{state, nodesDiscovered, nodesIndexed, nodesSkipped, nodesFailed}'
```

Two lines in the ingester log are the point of the pass rather than decoration:

```bash
docker compose logs plugin-batch-ingester | grep -E 'documentsGroupOnly|resource units'
```

`documentsGroupOnly` is how many documents are granted only to a group, which is exactly how many would be
retrievable by nobody if the group resolver were off. The resource-unit figure is the measured Graph cost
per document, to compare against the mock's model and against `hierarchical` mode in step 8.

### Step 6: Per-user ACL filtering

Query as each caller. Use https and `-k`: plain http answers 301, and a 301 makes every assertion look
like an empty result.

```bash
# search <login> <question> <sentinel phrase>
# Filters on the sentinel phrase and on this pass's source id, so a hit can only be the document meant.
search() {
  curl -sk -u "$1:demo-pw" -X POST 'https://localhost/api/rag/search/semantic' \
    -H 'Content-Type: application/json' \
    -d "{\"query\":\"$2\",\"topK\":30,\"minScore\":0.2}" \
  | jq --arg phrase "$3" \
      '[.results[]? | select((.sourceDocument.sourceId // "") == "sharepoint:onedrive-demo")
                    | select((.chunkText // "") | test($phrase; "i"))] | length'
}
```

A non-zero count is a hit. Filtering on the source id matters as soon as a second pass exists under a
second source id, and on the phrase because a semantic query returns the nearest chunks whether or not they
are the document you asked about.

Expected, for a fixture set built as in step 1:

| Fixture | You (the owner) | The outsider | A colleague, if you added one |
|---|---|---|---|
| `OrgLink/*`, organisation link | yes | **yes** | yes |
| `Public/*`, inherited from the drive root | yes | no | no |
| `GroupScoped/*`, shared with a group only | yes, via the group | no | only if also a member |
| `UserScoped/*`, shared with one colleague | yes, as owner | no | yes |
| `Nested/LevelTwo/*`, inherited | yes | no | no |

**`OrgLink` is the only row every caller retrieves, and the table is ordered to make that the first thing you
check.** An organisation-scoped link maps to `GROUP_EVERYONE`, which core rewrites to the un-namespaced
`__Everyone__`, so any authenticated caller matches it. It is the presence assertion all the absence ones
depend on: without it, "not found" could just as easily mean the ingest never happened.

**Do not expect `Public/` to be public.** The folder name comes from the mock's fixture tree, where it is
granted to Everyone. In a personal OneDrive the drive root is shared with nobody, so a file that merely
inherits is visible to **you alone**. That is the single most likely way to misread this demo: the
`Public/` files not coming back for the outsider is the correct result, not a broken ACL.

An outsider whose UPN Entra does not know at all is a legitimate negative case rather than a cheat. Graph
answers 404, the resolver reads that as "no such identity" rather than a failure, and the caller keeps the
source with default authorities, so they see the public documents and nothing granted to a group.

The group row is the one that proves the resolver, and it is the row that matters: sharing with a group is
how SharePoint is normally administered. Recreate `rag-service` with
`RAG_SECURITY_ENTRA_ENABLED=false` and the same document becomes retrievable by nobody, which is the
fail-closed behaviour the connector counts and reports at ingest.

Then repeat the same searches in the browser at `https://localhost/`, signing in as each user on the
connections screen, which is what a demo audience actually sees.

### Step 7: The Sources screen

The Sources entry appears in the nav only because `CONNECTORS_URL` was set in step 3. It prompts for the
sync-admin credentials from step 3.

It shows the loaded connector, its origin and its published settings schema. The schema endpoint returns
descriptors only and never values, so nothing on this screen can leak a credential. Four settings are
reported as secret, which is worth confirming once:

```bash
curl -s -u admin:admin http://localhost:9096/api/connectors/schema \
  | jq -r '.fields[] | select(.secret) | .name'
# sharepoint.client-secret, sharepoint.certificate-password,
# sharepoint.access-token, sharepoint.token-cache-path
```

The folder tree expands lazily over the real drive, one request per expansion. Select a subfolder, save,
and re-sync: the pass now walks only that subtree. Confirm it against the backend rather than the UI's own
state, and note that a selection lives in the index, so a container restart keeps it and `make clean`
wipes it:

```bash
curl -s -u admin:admin http://localhost:9096/api/selection | jq .
```

### Step 8: Change feed, deletion, and cost

Recreate the ingester with the change feed on and run a second pass. The job log shows the change feed
being read instead of a walk:

```bash
CONNECTOR_CHANGE_FEED_ENABLED=true docker compose --profile demo --profile connector \
  up -d --no-deps --force-recreate plugin-batch-ingester
```

Delete one fixture in OneDrive, sync again, and confirm it leaves the index: a deletion in the change feed
is reconciled rather than left behind.

For cost, run a third pass in hierarchical permissions mode **under a second source id**, so the two
measurements are attributable and neither overwrites the other:

```bash
SHAREPOINT_PERMISSIONS_MODE=hierarchical SHAREPOINT_SOURCE_ID=onedrive-demo-hier \
  docker compose --profile demo --profile connector \
  up -d --no-deps --force-recreate plugin-batch-ingester
```

Hierarchical mode depends on Graph honouring `Prefer: hierarchicalsharing`, which Microsoft documents as
requiring `Sites.FullControl.All`. The connector refuses to run in that mode rather than silently paying
the per-item price when the preference is not honoured, so a refusal here is a result and not a failure.

### Step 9: Clean up

```bash
rm -f /tmp/graph-token /tmp/dir-token
make clean
```

Delete the `content-lake-demo` folder from OneDrive and empty the recycle bin, so no ingested content is
left in either place. If you leave the stack running, recreate `rag-service` without the
`RAG_SECURITY_ENTRA_*` variables, or it holds a group resolver pointed at an expired token.

### Diagnosing it

Two things measured while writing this section, both of which cost time if you do not know them.

**A configuration error on `/api/browse/roots` answers 500 with a bare `Internal Server Error`, and the
useful message is only in the log.** The connector's own diagnostics are good, so read the log rather than
the response:

```bash
docker compose logs plugin-batch-ingester | grep GraphException
# None of the configured sharepoint.folder-paths resolved in any drive: [<drive-id>:content-lake-demo].
# A path is relative to the drive root, for example /Finance.
```

A wrong drive id and a folder path that does not exist look identical from the outside. Check the drive id
against Graph Explorer first.

**The plugin host has no `POST /api/sync`.** The proxy routes `/api/sync` by `?sourceType`, but the endpoint
on the host is `/api/sync/configured`, so a request to `/api/sync?sourceType=sharepoint` is routed
correctly and then answered 404 by the host. Both of these work:

```bash
curl -sk -u admin:admin -X POST 'https://localhost/api/sync/configured?sourceType=sharepoint'
curl -s  -u admin:admin -X POST 'http://localhost:9096/api/sync/configured'
```

To confirm the routing itself is right, the rendered map is worth one look. The `sharepoint` key comes from
`CONNECTOR_SOURCE_TYPE`; if it is missing, the key renders empty and sync silently reaches the Alfresco
ingester instead:

```bash
docker exec content-lake-app-proxy-1 grep -A5 'map $arg_sourceType' /tmp/nginx.conf.substituted
```

Note the path: the proxy renders its real configuration to `/tmp/nginx.conf.substituted` with `envsubst` and
runs `nginx -c` against it, so `/etc/nginx/nginx.conf` and `nginx -T` show the stock default and tell you
nothing.

### What this route cannot show

Everything below needs an app registration, and no fallback substitutes for it:

- **App-only ingestion.** A crawl under an application identity is the only way to build an index whose
  ACLs are complete for *every* user, because permissions are returned relative to the caller. This route
  is correct for the owner's own drive and would not be correct for a shared site.
- **Unattended operation.** Every step above puts a human in a browser. A static token cannot be
  refreshed, so a container restart after expiry does not recover.
- **Microsoft sign-in as the caller.** Callers here authenticate against Alfresco and are matched to
  SharePoint principals by name. Validating a real Entra-issued bearer token needs a sign-in application
  with a published API scope.
- **Site and library enumeration**, and the `siteUser` / `siteGroup` principal shapes. A personal drive
  has no site groups, and delegated file access cannot enumerate sites.
- **Genuine tenant throttling.** A fixture-sized crawl never reaches a 429.

## Connector Configuration

### Entra ID App Registration

The connector requires an Entra ID app registration with appropriate permissions.

#### Application (Client) Permissions (App-Only Auth)

For unattended crawling across the tenant:

- **Sites.Read.All** - Read all site collections
- **Sites.FullControl.All** - Required for hierarchical permissions mode (optional)
- **GroupMember.Read.All** - Resolve Entra ID group membership (optional)

#### Delegated Permissions (Device Code Auth)

For testing under a specific user account:

- **Sites.Read.All** - Read sites the user can access
- **offline_access** - Get refresh tokens for background sync

### Configuration Examples

#### Against Mock (Static Token)

```bash
SHAREPOINT_AUTH_MODE=static-token
SHAREPOINT_ACCESS_TOKEN=mock-token-any-value
SHAREPOINT_CLIENT_ID=mock
SHAREPOINT_GRAPH_BASE_URL=http://mock-graph:8099/v1.0
SHAREPOINT_DRIVE_IDS=b!mock-drive-id
SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0
```

#### Against Real Tenant (App-Only)

```bash
SHAREPOINT_AUTH_MODE=client-credentials
SHAREPOINT_TENANT_ID=your-tenant-id-guid
SHAREPOINT_CLIENT_ID=your-app-registration-guid
SHAREPOINT_CLIENT_SECRET=your-client-secret
SHAREPOINT_SITE_URL=https://yourtenant.sharepoint.com/sites/content-lake-demo
SHAREPOINT_PERMISSIONS_MODE=per-item
```

#### Against Real Tenant (Device Code)

```bash
SHAREPOINT_AUTH_MODE=device-code
SHAREPOINT_TENANT_ID=your-tenant-id-guid
SHAREPOINT_CLIENT_ID=your-app-registration-guid
SHAREPOINT_TOKEN_CACHE_PATH=/var/lib/content-lake/token-cache.json
SHAREPOINT_SCOPES=Sites.Read.All,offline_access
SHAREPOINT_SITE_URL=https://yourtenant.sharepoint.com/sites/content-lake-demo
```

Sign in once **on the host**, not in the container: `slf4j-api` is `provided` for the plugin, so the jar
cannot be run on its own, and the container mount is read-only. The script assembles the classpath and
locks down the cache file it writes.

```bash
export SHAREPOINT_CLIENT_ID=<application-client-id>
export SHAREPOINT_TENANT_ID=<directory-tenant-id>
./scripts/sharepoint-device-login.sh
```

It prints a code and a URL, waits for a browser, and writes `./sharepoint-auth/msal-cache.json`, which is
bind-mounted into the ingester read-only. That file holds a refresh token and is a credential. The mount
being read-only means refreshed tokens are held in memory only, so the sign-in has to be repeated when the
stored refresh token finally expires, or after a password reset or a Conditional Access change.

### Environment Variables

Two sources of truth, both authoritative:

- `GET /api/connectors/schema` on the plugin host publishes every setting the loaded connector declares,
  with its type, whether it is required, and whether it is secret. Values are never returned.
- The `plugin-batch-ingester` service in `compose.content-lake.yaml` enumerates every `SHAREPOINT_*`
  variable with its default and a comment explaining it.

A setting name becomes an environment variable by upper-casing it and replacing dots and hyphens with
underscores, so `sharepoint.drive-ids` is `SHAREPOINT_DRIVE_IDS`.

---

## Running Tests

### End-to-End Suite Against Mock

```bash
cd content-lake-app-deployment

# Ensure connector jar is built
cd ../content-lake-app
mvn -f plugins/sharepoint-connector/pom.xml package -DskipTests
cd ../content-lake-app-deployment

# Copy jar to connectors directory
mkdir -p connectors
cp ../content-lake-app/plugins/sharepoint-connector/target/sharepoint-connector-*.jar connectors/

# Run test suite
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
RAG_AUTH=admin:admin ./test/test-sharepoint.sh
```

Expected output: **39 tests passing, 0 failing**

### Manual Verification Against Real Tenant

```bash
# Start plugin-batch-ingester with real tenant config
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
CONNECTOR_SOURCE_TYPE=sharepoint \
SHAREPOINT_AUTH_MODE=client-credentials \
SHAREPOINT_TENANT_ID=your-tenant-id \
SHAREPOINT_CLIENT_ID=your-app-id \
SHAREPOINT_CLIENT_SECRET=your-secret \
SHAREPOINT_SITE_URL=https://yourtenant.sharepoint.com/sites/content-lake-demo \
  docker compose --profile alfresco --profile connector up -d

# Trigger sync
curl -u admin:admin -X POST http://localhost:9096/api/sync/configured

# Monitor job status
curl -u admin:admin http://localhost:9096/api/status | jq '.state, .nodesIndexed'

# Search for indexed documents
curl -u admin:admin -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "pangolin-ledger-quarterly", "topK": 5}' | jq '.results[].sourceDocument.name'
```

---

## Troubleshooting

### Mock Graph Not Responding

```bash
# Check if mock-graph container is running
docker compose ps mock-graph

# Check mock logs
docker compose logs mock-graph --tail 50

# Verify mock is accessible
curl http://localhost:8099/mock-diagnostics/requests
```

### Connector Authentication Failures

```bash
# Check connector logs for auth errors
docker compose logs plugin-batch-ingester --tail 100

# Verify auth state
curl -u admin:admin http://localhost:9096/api/status | jq '.auth'

# For device-code: check token cache exists and is readable
docker exec plugin-batch-ingester ls -la /var/lib/content-lake/token-cache.json
```

### Documents Not Indexed

```bash
# Check sync job status
curl -u admin:admin http://localhost:9096/api/status | jq '.'

# Check for errors in ingester logs
docker compose logs plugin-batch-ingester | grep -i error

# Verify documents are discoverable
curl -u admin:admin "http://localhost:9096/api/browse/children?nodeId=b!mock-drive-id:root" | jq '.nodes[].name'
```

### Permission Mapping Issues

```bash
# Check ACL mapping in logs
docker compose logs plugin-batch-ingester | grep -i "permission\|acl"

# Verify group resolver is enabled if using groups
docker compose logs rag-service | grep -i "entra\|group"

# Test search with different users
curl -u testuser@yourtenant.com:password -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "pangolin-ledger-named"}' | jq '.resultCount'
```

---

## References

- [SharePoint Connector Plugin README](../../content-lake-app/plugins/sharepoint-connector/README.md)
- [Mock Graph Server Source](../../content-lake-app/plugins/sharepoint-connector/src/test/java/org/hyland/contentlake/connector/sharepoint/mock/MockGraphServer.java)
- [Test Fixtures](../../content-lake-app/plugins/sharepoint-connector/src/test/resources/fixtures/)
- [E2E Test Suite](../test/test-sharepoint.sh)
- [Microsoft Graph API Documentation](https://learn.microsoft.com/en-us/graph/api/resources/driveitem)
