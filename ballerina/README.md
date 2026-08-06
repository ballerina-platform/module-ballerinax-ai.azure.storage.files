# Ballerina Azure Files Data Loader

The `ballerinax/ai.azure.storage.files` module provides a `TextDataLoader` that retrieves documents from Azure Files shares and returns them as `ai:TextDocument` values, ready to be chunked, embedded, and indexed by the [Ballerina AI](https://central.ballerina.io/ballerina/ai) module. Inherently textual files are decoded directly, while PDF and Microsoft Office documents have their text extracted with Apache Tika (PDFBox for PDF, Apache POI for Office).

It implements the `ai:DataLoader` abstraction, so it can be used anywhere an `ai:DataLoader` is expected (for example, in a Retrieval-Augmented Generation ingestion pipeline).

The acquisition layer — authentication, directory/file listing, and download — is delegated to the [`ballerinax/azure_storage_service.files`](https://central.ballerina.io/ballerinax/azure_storage_service.files) connector.

## Overview

- Reads files from one or more Azure Files **shares** in a storage account.
- Loads individual files as well as entire **directories**, optionally recursively.
- Reads from multiple shares with a single loader instance.
- Walks the real `Share → Directory → File` tree: files and sub-directories are listed separately, so recursion is a genuine tree-walk (no blob-name-prefix simulation).
- Returns every file as an `ai:TextDocument`, based on its extension:
  - Inherently textual files (e.g. `txt`, `md`, `html`, `json`, `csv`, `xml`) are decoded directly.
  - `pdf` files have their text extracted with Apache Tika (PDFBox).
  - Microsoft Office documents (`.doc`, `.docx`, `.ppt`, `.pptx`, `.xls`, `.xlsx`) have their text
    extracted with Apache Tika (Apache POI).
  - **PDFs with no extractable text** (scanned/image-only documents, or genuinely blank ones)
    are detected: skipped with a logged warning in directory listings, and reported with a
    descriptive error when named explicitly. OCR is not supported.
  - Other files that cannot be represented as text (e.g. images, audio, archives) are skipped with a
    logged warning; explicitly naming such a file as a path is an error.

## Authentication

Azure Files is accessed through the `ballerinax/azure_storage_service.files` connector, and the loader is initialized directly with the connector's `files:ConnectionConfig`. The connector supports two authorization mechanisms, configured through `accessKeyOrSAS` together with `authorizationMethod`:

| Mechanism | `authorizationMethod` | `accessKeyOrSAS` holds | Best for |
| --- | --- | --- | --- |
| Shared Access Signature (SAS) | `files:SAS` | A SAS token (the query string, e.g. `sv=...&sig=...`) | Scoped, time-limited, pre-signed access without sharing an account key |
| Shared Key (account access key) | `files:ACCESS_KEY` | One of the storage account's access keys | Full-account, server-to-server access; the connector signs each request with HMAC-SHA256 |

> **Note:** Azure AD / Microsoft Entra ID (OAuth2) is **not** supported in this version, as the underlying connector authorizes with Shared Key and SAS only.

The service endpoint is derived from the account name as `https://{accountName}.file.core.windows.net`.

### Configuring credentials

An account access key grants full control of the storage account, and a SAS token grants
whatever it was signed for — both are secrets and neither belongs in source control. Declare
them as `configurable` values and supply them at run time through `Config.toml`, which this
repository already git-ignores:

```ballerina
configurable string accountName = ?;
configurable string accessKeyOrSAS = ?;
```

```toml
# Config.toml — never commit this file
accountName = "contosostorage"
accessKeyOrSAS = "sv=2022-11-02&ss=f&srt=co&sp=rl&sig=<signature>"
```

Ballerina also reads `configurable` values from environment variables and CLI arguments, which
is usually how they are injected in a container or CI environment.

Prefer a SAS over the account key, and sign it as narrowly as the job allows: this loader only
ever reads and lists, so `sp=rl` on the file service is sufficient. Give it a short expiry and
rotate it.

> **Note:** a SAS travels in the URL query string, so it can appear in the connector's error
> messages. The loader strips the `sig` value from any connector message it interpolates into
> an `ai:Error`, but treat storage-related error text as sensitive regardless of where you
> forward it.

## Usage

### Initialization

Both this package and the underlying connector end in `files`, so the loader import needs an
alias to avoid a duplicate prefix:

```ballerina
import ballerinax/ai.azure.storage.files as azureFiles;
import ballerinax/azure_storage_service.files;

// Credentials are secrets: keep them out of the source and supply them through Config.toml
// or the environment. See "Configuring credentials" below.
configurable string accountName = ?;
configurable string accessKeyOrSAS = ?;

final azureFiles:TextDataLoader loader = check new (
    {
        accountName,
        accessKeyOrSAS,
        authorizationMethod: files:SAS
    },
    [
        {
            // Load one explicit file plus everything under /onboarding (recursively),
            // restricted to PDFs.
            share: "documents",
            paths: ["/policies/leave-policy.pdf", "/onboarding"],
            recursive: true,
            includeExtensions: ["pdf"]
        },
        {
            // A bare share name loads the whole share (non-recursive).
            share: "specs",
            paths: ["/api-design.md"]
        }
    ]
);
```

A third, optional parameter — `maxFileSizeInBytes` — bounds how large a file may be before the
loader will convert it. It applies to every source and defaults to 100 MiB:

```ballerina
final files:ConnectionConfig connectionConfig = {
    accountName,
    accessKeyOrSAS,
    authorizationMethod: files:SAS
};

final azureFiles:TextDataLoader smallFilesOnly = check new (
    connectionConfig,
    [{share: "documents", recursive: true}],
    10 * 1024 * 1024
);
```

An oversized file is reported differently depending on how the loader reached it:

- **Found by listing a directory** — skipped with a `WARN`, so one huge file cannot fail a bulk
  ingestion run. When the listing reports a size over the limit the file is never requested at
  all; when the listing reports no size (the property is optional) or understates it, the read
  itself is cut short and the file is skipped then.
- **Named explicitly in `paths`** — an **error**, since it was asked for by name. Such a path
  has no listing to consult, so it is read before being rejected.

Either way the loader reads at most one byte past the limit: the download is issued as a byte
range, so an oversized file is identified without ever being held in memory whole.

### The share / directory model

Unlike Azure Blob Storage's flat namespace, an Azure Files share is a real directory tree: a share holds directories, directories hold files and further sub-directories (e.g. `reports/2026/q1.pdf`). This loader maps a configured **path** onto a directory or a file:

- **A path with a trailing `/`, or the share root (`/`)** is treated as a directory and listed.
- **A path without a trailing `/`** is first tried as an explicitly named file. If an exact file exists it is loaded directly (and always loaded, regardless of the extension filter). If no such file exists, the path is treated as a directory — unless it looks like a file (has an extension), in which case a missing file is reported as an error to help catch typos.
- **A deliberately named non-text file** (an image, an archive, etc.) is an **error**, whereas the same file discovered while listing a directory is skipped with a warning.

`paths` defaults to `["/"]`, so a `Source` with only a `share` loads the whole share; set `paths` to `[]` to load nothing.

### Recursion

By default a directory loads only the files **directly** inside it. Set `recursive: true` to include files in every sub-directory beneath it:

```ballerina
{share: "documents", paths: ["/reports"], recursive: true}
```

### Filtering by file type

Each `Source` has its own `includeExtensions` to restrict which files are loaded from directories:

- `includeExtensions: ["pdf"]` — only PDF files.
- `includeExtensions: ["pdf", ".md", "TXT"]` — case-insensitive; a leading dot is optional.
- omitted (the default) — load all types.

The filter applies to files discovered while listing a directory. A file listed **explicitly** in `paths` is always loaded, even if its extension isn't in the list.

### Loading documents

```ballerina
public function main() returns error? {
    ai:Document[]|ai:Document documents = check loader.load();
    // Pass the documents to a chunker / embedding provider / vector store ...
}
```

`load()` returns a single `ai:Document` when exactly one file is resolved, and an `ai:Document[]` otherwise (mirroring `ai:TextDataLoader`).

Each returned `ai:TextDocument` carries metadata including the file name (`fileName`) and — when reported by Azure — the `fileSize`.

> **Note:** `mimeType`, `createdAt` and `modifiedAt` are **never** set on the returned metadata. Azure Files' *listings* report neither, and although `Get File Properties` does return `Content-Type`, `Last-Modified` and `x-ms-creation-time`, the connector discards response headers, so the loader has no way to read them. Classification therefore relies entirely on the file extension. The `fileSize` reported by a listing may also be stale, since an SMB or NFS client can modify a file locally without the listing being updated.

## Limitations

- **Single-page listings.** The underlying connector (`azure_storage_service` 4.3.4) does not surface the Azure continuation marker (`NextMarker`) for directory or file listings, so each listing returns a single page of up to 5000 entries. A directory with more than that **fails the load with an error** rather than returning a truncated result — narrow it with `paths` or `includeExtensions`. A directory holding exactly 5000 entries trips the same check. Recursion into sub-directories is unaffected.
- **An empty listing costs one extra request to verify.** The connector does not check the
  HTTP status of its listing calls, so an Azure error (a `403` from an expired SAS, a `503`
  while throttled, a share that does not exist) arrives looking exactly like an empty
  directory. Rather than trust it, the loader confirms an empty listing with a single
  `Get File` probe — which *does* report status — and turns a rejected request into an error
  instead of an empty result. The cost is one additional request per empty directory.
- **No content type from listings.** As noted above, classification is extension-based.
- **A file larger than `maxFileSizeInBytes` is not converted.** Files are buffered whole in
  memory before extraction, so the default 100 MiB bound protects the process. Raise it
  deliberately. A file discovered in a directory listing is skipped with a `WARN`; one named
  explicitly in `paths` is reported as an error.
- **Text extraction failures are skipped, not fatal.** A password-protected, corrupt, or
  mislabeled file inside a directory listing is logged at `WARN` and skipped so that one bad
  file cannot abort a bulk ingestion run. A path named explicitly in `paths` still errors.
- **Extraction stops after 10 million characters.** A single PDF or Office document yields at
  most that much text (~20 MB), so no one document can exhaust the heap. A document that hits
  the cap is still loaded — its text simply ends there — and the truncation is logged at
  `WARN` with the file name.
- **Plain-text encodings.** UTF-8, UTF-8 with BOM, and UTF-16 (with a BOM, or BOM-less where
  the NUL pattern makes it unambiguous) are decoded. Other legacy code pages are not detected
  and are reported as an error for that file.
- **Directory names containing dots.** A path such as `/docs/v1.0` is probed as a file first;
  if no such file exists it is then listed as a directory. A dotted directory that is *empty*
  cannot be distinguished from a typo and is reported as an error — append a `/` to force the
  directory interpretation.
- **Credentials are static.** Only Shared Key and SAS are supported. Entra ID / managed
  identity needs `x-ms-file-request-intent`, which requires a newer service version than the
  connector's pinned `2019-12-12`.
- **Text, PDF, and Office only.** Text is extracted from inherently textual files, PDFs (PDFBox),
  and Microsoft Office documents (POI). Other binary formats (images, audio, archives) are skipped.
- **No OCR.** A PDF that yields no text (a scanned/image-only document, or a genuinely blank
  one) is skipped with a warning in directory listings and produces a descriptive error
  ("the PDF contains no extractable text content ...") when named explicitly. Reading scanned
  documents would require OCR (e.g. Tesseract via Tika's OCR module, or Azure AI Document
  Intelligence), which this loader does not ship.

## Configuration reference

### `files:ConnectionConfig`

The connection configuration is the [`ballerinax/azure_storage_service.files`](https://central.ballerina.io/ballerinax/azure_storage_service.files) connector's own `ConnectionConfig`:

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `accountName` | `string` | — | The Azure Storage account name; used to build the file service endpoint |
| `accessKeyOrSAS` | `string` | — | An account access key or a SAS token, interpreted per `authorizationMethod` |
| `authorizationMethod` | `files:AuthorizationMethod` | — | `files:ACCESS_KEY` (Shared Key) or `files:SAS` |
| `httpVersion` | `http:HttpVersion` | `http:HTTP_1_1` | HTTP version understood by the client |
| `http2Settings` | `http:ClientHttp2Settings` | — | HTTP/2 protocol settings |
| `timeout` | `decimal` | `30` | Response timeout, in seconds |
| `forwarded` | `string` | `"disable"` | Handling of the `forwarded`/`x-forwarded` header |
| `poolConfig` | `http:PoolConfiguration` | — | Request pooling configuration |
| `cache` | `http:CacheConfig` | — | HTTP caching configuration |
| `compression` | `http:Compression` | `http:COMPRESSION_AUTO` | `accept-encoding` handling |
| `circuitBreaker` | `http:CircuitBreakerConfig` | — | Circuit breaker configuration |
| `retryConfig` | `http:RetryConfig` | — | Retry configuration |
| `responseLimits` | `http:ResponseLimitConfigs` | — | Inbound response size limits |
| `secureSocket` | `http:ClientSecureSocket` | — | SSL/TLS options |
| `proxy` | `http:ProxyConfig` | — | Proxy server options |
| `validation` | `boolean` | `true` | Inbound payload validation |


### `Source`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `share` | `string` | — | The share name to read from |
| `paths` | `string[]` | `["/"]` | Directory paths and/or explicit file names. The default `["/"]` loads the whole share; `[]` loads nothing |
| `recursive` | `boolean` | `false` | Whether directories are traversed into sub-directories |
| `includeExtensions` | `string[]?` | absent | Extension allowlist applied to directory contents (e.g. `["pdf"]`). Case-insensitive; when absent, all types are loaded. Explicit file paths bypass it |

### `TextDataLoader` initialization parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `azureConnection` | `files:ConnectionConfig` | — | The authentication and service configuration shared by all sources |
| `sources` | `Source[]` | — | One or more Azure Files shares to load documents from; at least one is required |
| `maxFileSizeInBytes` | `int` | `104857600` (100 MiB) | Largest file that will be converted, applied across every source. A file found in a directory listing is skipped with a warning — before it is fetched when the listing reports an oversized `Content-Length`, and after a bounded read when that size is absent or understated. A file named explicitly in `paths` is read (up to one byte past the limit) and then reported as an error. Must be positive |
