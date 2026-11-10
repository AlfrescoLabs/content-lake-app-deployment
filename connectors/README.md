# Connector plugins

Drop a connector jar in this directory and restart an ingester to use it. Every ingester mounts this
directory read-only at `/opt/content-lake/connectors` and scans it at startup, so a connector needs no
change to `compose.content-lake.yaml`, no Maven module and no edit to any Dockerfile.

```bash
cp ~/dev/my-cmis-connector/target/my-cmis-connector-1.0.0.jar .
docker compose --profile alfresco up -d --force-recreate batch-ingester
curl http://localhost:9090/api/connectors -u admin:admin
```

The listing reports every connector the ingester has, where each came from, and anything that failed to
load. A jar that cannot be read, or whose configuration does not satisfy the schema it publishes, is
reported there and in the container log.

Whether that also stops the ingester depends on which one it is. The five that never ingest from a jar
default `CONNECTOR_VALIDATION` to `warn`, so an unconfigured connector is reported and they start anyway:
they were not going to use it, and stopping an unrelated ingestion over it would be a failure the operator
cannot act on. `plugin-batch-ingester` defaults to `fail`, since a connector it cannot load leaves it
with no source at all. Set `CONNECTOR_VALIDATION_INGESTERS=fail` to make the other five strict too.

## Ingesting with it

Every ingester *loads* a connector; only one *ingests* with it. The Alfresco, Nuxeo and filesystem
ingesters each drive a client they were compiled against, so for them the listing above is all a mounted
jar does. `plugin-batch-ingester`, on the `connector` profile, takes its client,
scope rules and optionally its extractor from the jar:

```bash
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
  docker compose --profile alfresco --profile connector up -d --build plugin-batch-ingester

curl -u admin:admin http://localhost:9096/api/connectors           # what loaded, and from which jar
curl -u admin:admin http://localhost:9096/api/connectors/schema    # what it wants configured
curl -u admin:admin -X POST http://localhost:9096/api/sync/configured
curl -u admin:admin http://localhost:9096/api/status
```

That service has no source of its own. It does not mount this directory directly: the one-shot
`connector-init` copies the jars from here into a volume before it starts, or, when this directory holds no
jar, the shipped connector of `CONNECTOR_SOURCE_TYPE` (`filesystem`, `cmis` or `sharepoint`), built by the
`connectors` stage of `dockerfiles/Dockerfile`. With neither it fails and says why, rather than running a
sync API that ingests nothing. With several jars here, set `CONNECTOR_SOURCE_TYPE` to say which one to
ingest with.

Where the walk starts: a connector that implements `ContentSourceClient.getRootNodeId()` says so itself and
needs nothing configured. Otherwise set `CONNECTOR_ROOTS` to one or more node ids, comma separated.

`../content-lake-app/plugins/examples/sample-directory-connector` is a working connector to try
this with, and `test/test-connector.sh` builds it, mounts it and asserts the documents come back out of
semantic search.

Point the mount somewhere else with `CONNECTOR_PLUGIN_PATH`:

```bash
CONNECTOR_PLUGIN_PATH=/opt/my-connectors docker compose --profile alfresco up -d
```

Two things worth knowing. The jar has to be readable by the container's user, so build it with ordinary
permissions rather than `600`. And a connector's own settings are read from the ingester's environment, so
whatever the jar's schema declares (`cmis.url` and so on) has to be passed to the service like any other
setting. Hyphens and dots both become underscores and the name is upper-cased, so `cmis.page-size` is
`CMIS_PAGE_SIZE`.

An empty directory is the normal state: with nothing here, an ingester logs that the directory holds no
jars and behaves exactly as it did before.

## Keeping state between runs

`plugin-batch-ingester` mounts one writable directory and publishes its path as
`CONNECTOR_STATE_DIRECTORY`, default `/var/lib/content-lake/connector`. Everything else that service
mounts is read-only, including this directory of jars.

It is for the state a connector cannot recompute: a change cursor, a delta token, a continuation marker.
The sources with the cheapest and most complete change feeds are exactly the ones that hand you an opaque
token and expect you to hold it, and discarding it on restart means re-enumerating the whole corpus.

The host only provides the directory and names it. **Nothing reads `CONNECTOR_STATE_DIRECTORY` on its
own:** a connector that needs state declares its own setting in its `ConnectorSchema`, reads it through
`ConnectorContext`, and the operator points that setting at this path. So for a connector declaring
`my-source.state-directory`:

```bash
MY_SOURCE_STATE_DIRECTORY=/var/lib/content-lake/connector \
  docker compose --profile alfresco --profile connector up -d plugin-batch-ingester
```

Not every connector needs it. The shipped SharePoint connector keeps its delta cursor through the host's own
`CONNECTOR_CURSOR_STORE`, which defaults to a state document in hxpr and so needs no writable mount at all.

Two things to know.

**Namespace your files.** Several jars can be mounted at once and they all see the same directory, so a
connector that writes `cursor.json` will collide with the next one that does. Use something derived from
the source type, `sharepoint-cursor.json` or a subdirectory of your own making.

**It is a named volume, so `make clean` wipes it and `make down` does not.** That is deliberate: the
project's standing rule is that every test run starts from an empty index, and state that outlived a
`make clean` would reintroduce the staleness that rule exists to prevent. Treat a missing cursor as
normal and fall back to a full enumeration; it is the state you will be in after every wipe.

Only `plugin-batch-ingester` gets the mount. A jar is loaded by all six ingesters, but this is the only
one that ingests from the registry, so it is the only one with state to keep.

## The shipped connectors

Three jars are built from `../content-lake-app/plugins/` rather than written for one deployment. Their settings
arrive as environment variables like any other, using the names their schemas declare.

| Connector | Jar | Settings |
|---|---|---|
| CMIS 1.1 | `cmis-connector-1.0.0.jar` | `CMIS_URL`, `CMIS_USERNAME`, `CMIS_PASSWORD`, `CMIS_ROOT_PATH`, ... |
| Filesystem | `filesystem-connector-1.0.0.jar` | `FILESYSTEM_ROOT_PATH`, `FILESYSTEM_EXCLUDE_PATTERNS`, ... |
| SharePoint Online | `sharepoint-connector-1.0.0.jar` | `SHAREPOINT_DRIVE_IDS`, `SHAREPOINT_CLIENT_ID`, `SHAREPOINT_TENANT_ID`, `SHAREPOINT_CLIENT_SECRET`, `SHAREPOINT_PERMISSIONS_MODE`, ... |

Both are declared with defaults in the `plugin-batch-ingester` block of `compose.content-lake.yaml`, where
each setting carries a comment about what it does. The full tables are in
`../content-lake-app/docs/configuration.md`.

### Running the platform with every connector mounted

The deployment is meant to run with all connector jars present or none, and an unconfigured connector is
designed to decline rather than break anything. What that looks like:

- Each mounted jar's schema is validated against the environment, and one missing a required setting is
  **refused**: an error line naming the settings, that jar skipped, the application and the other jars
  unaffected. So an all-connectors deployment logs one error per unconfigured connector by design.
- With more than one connector configured, `CONNECTOR_SOURCE_TYPE` has to name the one to ingest with.
- No connector does network I/O while being constructed, so mounting a jar cannot slow or break a deployment
  that is using a different one.

### SharePoint without a Microsoft 365 tenant

`SHAREPOINT_GRAPH_BASE_URL` and `SHAREPOINT_AUTH_MODE` are the only two things that differ between a tenant
and the mock Graph service in the `sharepoint-mock` profile, which is what lets the connector be run and
demonstrated with no account anywhere:

```bash
CONNECTOR_SOURCE_TYPE=sharepoint \
SHAREPOINT_DRIVE_IDS='b!mock-drive-id' SHAREPOINT_CLIENT_ID=mock \
SHAREPOINT_AUTH_MODE=static-token SHAREPOINT_ACCESS_TOKEN=mock-token \
SHAREPOINT_GRAPH_BASE_URL=http://mock-graph:8099/v1.0 \
SHAREPOINT_RESOURCE_UNITS_PER_MINUTE=0 \
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
  docker compose --profile alfresco --profile connector --profile sharepoint-mock up -d
```

`static-token` is needed because msal4j refuses an authority that is not `https`, so the mock cannot stand in
for Entra ID. That makes token acquisition the one part of the connector a local run does not exercise.
`../test/test-sharepoint.sh` drives the whole thing, including an assertion that a document restricted to one
user is not returned to anyone else.

### SharePoint as a named user, with no application permissions

Where the tenant will issue a public-client app registration but not application permissions, the connector
can authenticate as a person. Sign in once on the host, then the ingester refreshes silently and survives
restarts:

```bash
export SHAREPOINT_CLIENT_ID='<application (client) id>'
export SHAREPOINT_TENANT_ID='<directory (tenant) id>'
../scripts/sharepoint-device-login.sh

CONNECTOR_SOURCE_TYPE=sharepoint SHAREPOINT_AUTH_MODE=device-code \
SHAREPOINT_CLIENT_ID="$SHAREPOINT_CLIENT_ID" SHAREPOINT_TENANT_ID="$SHAREPOINT_TENANT_ID" \
SHAREPOINT_DRIVE_IDS='<drive id>' \
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
  docker compose --profile alfresco --profile connector up -d
```

The sign-in writes `../sharepoint-auth/msal-cache.json`, which is bind-mounted read-only into the ingester.
That file holds a refresh token, so it is gitignored, kept owner-readable only, and is a credential rather
than configuration. There is a wrapper script rather than a `java -jar` because `slf4j-api` is `provided` for
the plugin, so the jar cannot run on its own.

Three consequences of choosing this over `client-credentials`, none of them obvious from the setting name:

- The index holds **one identity's view**. Content the signed-in user cannot read is absent from it, rather
  than present and unretrievable. That is a completeness limitation, not a security one.
- The mount is read-only, so refreshed tokens live in memory for the life of the process. Nothing breaks; the
  sign-in simply has to be repeated when the stored refresh token finally expires, or after a password reset
  or a Conditional Access change.
- The connector reports the mode as unsupported for production at startup, because recovery needs a human.

An empty or spent cache is reported as a configuration problem naming the sign-in command, at load rather than
mid-crawl. Nothing in the container can complete an interactive sign-in, and it deliberately does not try.

### What a SharePoint crawl costs, and the one setting that changes it

Graph meters SharePoint in resource units rather than requests, and charges **5 units for any permission
operation** while refusing to let `permissions` be `$expand`ed onto an item. So the default
`SHAREPOINT_PERMISSIONS_MODE=per-item` spends about 6 units per document, five of them on the ACL. Against a
per-application per-tenant cap of 1,250 units a minute and 1.2M a day, that bounds a first crawl near
**200,000 documents in 24 hours**.

`SHAREPOINT_PERMISSIONS_MODE=hierarchical` reads permissions only where SharePoint's sharing hierarchy says
they are set and inherits the rest, which moves the bottleneck to the content download where it belongs.
Measured by `../test/test-sharepoint.sh` over the same fixture tree: **1.10 units per document against 5.60**,
one permissions call serving nine items. The gap widens with the proportion of items that inherit and is
bounded at sixfold, since the 1-unit content download is then the whole cost.

Two things to know before turning it on:

- It needs the **`Sites.FullControl.All`** application permission, because that is what
  `Prefer: hierarchicalsharing` requires. Without it the connector **refuses to run** in this mode rather
  than falling back, so a deployment that cannot get the grant stays on `per-item` deliberately rather than
  paying five times the budget without being told.
- The saving depends on how the tenant is administered. A tenant where users share individual files heavily
  has more permission-hierarchy roots and less to inherit, so measure it rather than quoting the figure
  above. Every pass logs its own `permissions mode ...` and `Graph resource units ... per document` lines.
