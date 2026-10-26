#!/usr/bin/env bash
# create-sharepoint-demo-files.sh - Generate the fixture tree for a real SharePoint site or OneDrive
#
# File names and sentinel phrases are the ones the mock Graph fixtures use, so the assertions in
# test-sharepoint.sh match the same phrases against a real site. The PDF is the mock's own PDF.
#
# Usage:
#   ./fixtures/create-sharepoint-demo-files.sh [output-directory]
#
# RUN_TAG (default: a timestamp) is written into every file, so one upload cannot be mistaken for
# another. BULK_COUNT (default 120) sets how many files go in Bulk/, which must exceed Graph's
# default page size of 100 so paging is exercised.

set -euo pipefail

OUTPUT_DIR="${1:-.sharepoint-demo-files}"
RUN_TAG="${RUN_TAG:-real-$(date +%Y%m%d%H%M)}"
BULK_COUNT="${BULK_COUNT:-120}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_PDF="$SCRIPT_DIR/../../content-lake-app/plugins/sharepoint-connector/src/test/resources/fixtures/content/i-report"

if [[ ! -f "$MOCK_PDF" ]]; then
    echo "Mock PDF not found at $MOCK_PDF (content-lake-app must be a sibling checkout)" >&2
    exit 1
fi

echo "Creating SharePoint fixture files in $OUTPUT_DIR (run tag $RUN_TAG)"
mkdir -p "$OUTPUT_DIR"/{Public,UserScoped,GroupScoped,OrgLink,Nested/LevelTwo,Bulk}

# fixture <path> <text>: writes the text plus the run tag
fixture() {
    printf '%s\n\nRun tag: %s\n' "$2" "$RUN_TAG" > "$OUTPUT_DIR/$1"
}

fixture Public/quarterly-review.txt \
    "Quarterly review for the demo site. Sentinel phrase: pangolin-ledger-quarterly."
fixture Public/incident-log.md \
    "# Incident log

Markdown, so it takes the extraction short-circuit. Sentinel phrase: pangolin-ledger-incident."
cp "$MOCK_PDF" "$OUTPUT_DIR/Public/quarterly-report.pdf"
fixture UserScoped/named-grant.txt \
    "Granted to one named colleague only. Sentinel phrase: pangolin-ledger-named."
fixture GroupScoped/group-grant.txt \
    "Granted to a security group only. Sentinel phrase: pangolin-ledger-group."
fixture OrgLink/org-wide.txt \
    "Shared with an organisation link. Sentinel phrase: pangolin-ledger-orgwide."
fixture Nested/LevelTwo/deep-document.txt \
    "Two levels down, to prove traversal descends. Sentinel phrase: pangolin-ledger-deep."
for i in $(seq -w 1 "$BULK_COUNT"); do
    fixture "Bulk/bulk-$i.txt" "Bulk fixture $i, to exceed one page of children. Sentinel phrase: pangolin-ledger-bulk-$i."
done

cat > "$OUTPUT_DIR/README.md" << EOF
# SharePoint fixture files (run tag $RUN_TAG)

Upload this whole folder to the site's document library, keeping the structure:

    Public/              inherits from the library. Nothing to do
    UserScoped/          inheritance broken, shared with ONE named colleague
    GroupScoped/         inheritance broken, shared with ONE Entra ID or Microsoft 365 group
    OrgLink/             an organisation sharing link ("People in <your organisation>")
    Nested/LevelTwo/     inherits. Proves traversal descends
    Bulk/                inherits. $BULK_COUNT files, more than one page of children

Sharing, in the SharePoint web UI (select the folder, then Manage access):

1. UserScoped: Stop sharing (clears inherited access), then Share with one colleague, Can view.
2. GroupScoped: Stop sharing, then Share with one Entra ID or Microsoft 365 group, Can view.
3. OrgLink: Share, change the link type to "People in <your organisation>", Copy link.

Never share a fixture with the site's own Owners, Members or Visitors groups. They have no directory
object id, so no resolver can expand them, and the document becomes retrievable by nobody.
Skip anonymous links: they grant nothing to an authenticated principal.

Sentinel phrases, one per document:
pangolin-ledger-quarterly, -incident, -pdf-report, -named, -group, -orgwide, -deep, and
pangolin-ledger-bulk-001 to -$BULK_COUNT.
EOF

echo "Done: $(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ') files. Upload steps: $OUTPUT_DIR/README.md"
