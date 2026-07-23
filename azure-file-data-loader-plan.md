# Azure Files Data Loader — New Repo Plan

Build `ballerinax/ai.azure.storage.files`, a `TextDataLoader` that loads documents from
**Azure Files** shares, mirroring the existing Azure **Blob** loader
(`ballerinax/ai.azure.storage.blob`). It reuses the text-conversion layer (Apache Tika +
native extractor) verbatim and rewrites only the acquisition layer against the
`ballerinax/azure_storage_service.files` connector.

## Why this is mostly a port, not a new build

The Blob module is split into two layers; only one is Blob-specific:

| Layer | Source | Action |
| --- | --- | --- |
| Text/conversion | `utils.bal`, `native/…/TextExtractor.java`, Tika/PDFBox deps | **Copy verbatim** (rename package/class only) |
| Acquisition | `blob_data_loader.bal`, `client.bal`, `types.bal` | **Rewrite** against the `files` connector |

## The core model difference (drives the whole rewrite)

- **Blob** = a *flat* namespace; "folders" are simulated by `/` in blob names. Hence the
  Blob loader's `normalizeBlobPath`, `isDirectChild`, trailing-slash prefix probing.
- **Azure Files** = a *real* tree: `Share → Directory → File`. The connector exposes it
  directly, so the prefix gymnastics disappear and recursion becomes a genuine tree-walk.

Connector API (`azure_storage_service.files` 4.3.4):

| Purpose | Method | Client |
| --- | --- | --- |
| List sub-directories of a directory | `getDirectoryList(share, azureDirectoryPath?, params)` → `DirectoryList` | `FileClient` |
| List files in a directory | `getFileList(share, azureDirectoryPath?, params)` → `FileList` | `FileClient` |
| Download a file | `getFileAsByteArray(share, fileName, azureDirectoryPath?, ContentRange?)` → `byte[]` | `FileClient` |
| List shares (for `"*"`) | `listShares(params)` → `SharesList` | `ManagementClient` |

Both `getDirectoryList` / `getFileList` support `marker` / `maxresults` / `prefix` and
return an optional `Marker` for the next page. Listings report `Content-Length` but
generally **not** a content-type — fine, because `classify()` already falls back to the
file extension.

---

## Naming map (apply everywhere)

| Blob repo | New Files repo |
| --- | --- |
| repo `module-ballerinax-ai.loader.azureblob` | `module-ballerinax-ai.azure.storage.files` |
| package `ballerinax/ai.azure.storage.blob` | `ballerinax/ai.azure.storage.files` |
| gradle project `ai.azure.storage.blob-native` / `-ballerina` | `ai.azure.storage.files-native` / `-ballerina` |
| native artifactId `ai.azure.storage.blob-native` | `ai.azure.storage.files-native` |
| Java package `io.ballerina.lib.ai.azure.storage.blob` | `io.ballerina.lib.ai.azure.storage.files` |
| connector `azure_storage_service.blobs` | `azure_storage_service.files` |
| `blob_data_loader.bal` | `file_data_loader.bal` |
| `BlobEntry` | `FileEntry` |
| `Source.container` | `Source.share` |

---

## Phase 0 — Scaffold

Copy the whole repo tree to `module-ballerinax-ai.azure.storage.files`, then rename per the
map above in these files:

- `settings.gradle` — `rootProject.name`, the two `include`/`projectDir` lines.
- `gradle.properties` — unchanged (same Tika/PDFBox/lang versions).
- `build.gradle`, `native/build.gradle` — `description` strings.
- `native/…/native-image.properties` — path segment `…/storage/blob` → `…/storage/file`.
- Move `native/src/main/java/io/ballerina/lib/ai/azure/storage/blob/` →
  `…/storage/file/`.
- `ballerina/Ballerina.toml` — `name`, `repository`, the native-jar `artifactId` + `path`,
  keywords (`blob`→`file`). Keep the Tika/PDFBox platform deps identical.

**Gate:** `./gradlew build` compiles the empty-logic package (or `bal build` in `ballerina/`).

## Phase 1 — Text layer (copy, ~zero logic)

Copy verbatim, changing only names:

- `native/…/TextExtractor.java` — `package … .storage.file;` (logic untouched).
- `ballerina/utils.bal` — the `@java:Method { 'class: "io.ballerina.lib.ai.azure.storage.files.TextExtractor" }`
  path; everything else (classify, MIME/extension tables, `matchesExtensionFilter`,
  `getExtension`, `toUtc`, `dedupeStrings`, `buildDocument`) is **unchanged**.
  - `normalizeBlobPath` / `isDirectChild` are Blob-only — **drop them** (or replace with the
    Files path helpers in Phase 4).
- Copy `tests/fixtures.bal`, `tests/text_layer_test.bal`, `tests/types_test.bal`
  (adjust only type names touched in Phase 2).

**Gate:** `bal test` — the text-layer + fixture tests pass with no live calls.

## Phase 2 — Types (`types.bal`)

- `AuthorizationMethod` enum — **identical** (`ACCESS_KEY`, `SAS`).
- `ConnectionConfig` — **identical** shape (`accountName`, `accessKeyOrSAS`,
  `authorizationMethod`, HTTP fields). The `files` connector takes the same config surface.
- `Source` — rename `container` → **`share`**; keep `paths` (default `["/"]`), `recursive`
  (default `false`), `includeExtensions` (default `()`). `share: "*"` = every share.
- `FileEntry` (replaces `BlobEntry`): `name`, `directoryPath`, `contentLength`,
  optionally `lastModified`. No `contentType` from listings (extension drives `classify`).

## Phase 3 — Client (`client.bal`)

- `toConnectorAuthMethod`, `toConnectorConfig` — reuse, retargeting the `files:` types.
- Build **two** clients from one `ConnectionConfig`:
  - `files:FileClient` — listing + download (always needed).
  - `files:ManagementClient` — only for `share: "*"` (`listShares`). Construct lazily or
    always; wrap failures as `ai:Error` like `newBlobClient`.

**Gate:** a live smoke test that constructs the clients against the real account.

## Phase 4 — Loader (`file_data_loader.bal`)

`TextDataLoader` still `*ai:DataLoader`, holds `FileClient` (+ `ManagementClient`) and
`readonly & Source[]`; `load()` returns `ai:Document[]|ai:Document|ai:Error`. Per source:

1. **Resolve shares** — `[share]`, or paginate `listShares()` (marker loop, `dedupeStrings`)
   when `"*"`. `tolerateMissing = share == "*"`.
2. **Resolve each path** to a `(directoryPath, fileName?)`:
   - Root (`"/"`/`""`) or trailing `/` → directory listing.
   - Otherwise probe as an explicit file via `getFileAsByteArray`; on success build one
     document (explicit files bypass the extension filter; a named non-text/Office file is
     an error). On 404 (`isNotFoundError`), treat as a directory — unless it "looks like a
     file" (has an extension) and `!tolerateMissing`, then error (typo detection). Mirrors
     the Blob `loadPrefix` contract exactly.
3. **List a directory** = `getFileList` (files here) **+**, when `recursive`,
   `getDirectoryList` then recurse into each sub-directory. Page both via the `Marker`
   cursor. For each file: apply `matchesExtensionFilter`, download with
   `getFileAsByteArray`, convert via the shared `buildDocument`. Skip unsupported/Office
   files with a `log:printWarn` (never an error inside a listing).
   - **Simpler than Blob:** no `isDirectChild` filtering — directories and files come back
     from separate calls, so non-recursive = "just this directory's `getFileList`".
4. **`isNotFoundError`** — port the Blob version, matching the `files` connector's 404 /
   `ShareNotFound` / `ResourceNotFound` error shapes (verify the exact error type in Phase 3).

**Gate:** live tests for single file, directory (non-recursive), recursive tree, `"*"`
shares, extension filter, and Office-file rejection.

## Phase 5 — Tests, docs, sample

- Keep the mocked text-layer + types tests; add loader tests for the tree-walk / recursion
  / `"*"` paths.
- New `README.md` / `ballerina/README.md`: swap "container/blob/prefix" → "share/directory/
  file"; **remove** the Blob "no real folders" caveat (Files has real directories); keep the
  RFC-1123 timestamp caveat if it still applies to Files listings.
- Add a `live-test/` sample (copy the Blob one; `container`→`share`) for end-to-end
  verification against a real Azure Files share.

---

## Open items to confirm during Phase 3

1. Exact error type/shape for a missing share/directory/file (drives `isNotFoundError`).
2. Whether `getFileList` surfaces any content-type or timestamps (affects `FileEntry` +
   metadata richness). If not, classification stays extension-only, which is fully supported.
3. Whether `ManagementClient.listShares` pagination uses the same `Marker` convention.

## Reuse scorecard

- **Verbatim:** `TextExtractor.java`, Tika/PDFBox deps, `buildDocument`, `classify`, all
  MIME/extension tables, `matchesExtensionFilter`, `getExtension`, `toUtc`, `dedupeStrings`,
  the gradle/native build wiring.
- **Rewrite:** `types.bal` (rename `container`→`share`, `BlobEntry`→`FileEntry`), `client.bal`
  (two `files` clients), `file_data_loader.bal` (tree-walk instead of prefix listing).
- **Drop:** `normalizeBlobPath`, `isDirectChild` (Blob-flat-namespace only).
</content>
