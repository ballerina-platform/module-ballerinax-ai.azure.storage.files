// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerinax/azure_storage_service.files;

# A rule selecting what to load from one Azure Files share. Several may be configured
# per loader. A share is the unit of addressing (analogous to a SharePoint library):
# there is no site/library chain, so a share maps directly to a `Source`. Unlike Azure
# Blob's flat namespace, an Azure Files share is a real `Directory → File` tree, so paths
# address genuine directories and files rather than blob-name prefixes.
public type Source record {|
    # The share name to read from, or `"*"` for every share in the account.
    # For `"*"`, a missing path is tolerated (skipped) rather than an error.
    string share;
    # Directory or file paths (e.g. `/reports`, `/design.md`) to read.
    # Defaults to `["/"]`, the whole share; `[]` reads nothing.
    string[] paths = ["/"];
    # Whether sub-directories under a directory are traversed. Defaults to `false`.
    boolean recursive = false;
    # Case-insensitive extension allowlist for directory listings.
    # Defaults to `()`, all types.
    string[]? includeExtensions = ();
|};

# Existing Azure Files connector clients, supplied in place of a `files:ConnectionConfig`
# so the loader reuses the caller's connections rather than opening its own. Clients
# supplied this way are **not** owned by the loader: the caller remains responsible for
# their lifecycle.
#
# Two clients are needed because the connector splits the API: `FileClient` lists
# directories and downloads files, while `ManagementClient` is used only to enumerate the
# account's shares for a `share: "*"` source.
public type Clients record {|
    # The client used to list directories and download files.
    files:FileClient fileClient;
    # The client used only to enumerate shares for a `share: "*"` source. It may be omitted
    # when no source uses `"*"`, mirroring the loader's own lazy construction of it.
    files:ManagementClient managementClient?;
|};

// A normalized listing entry, decoupled from the connector's `File` record (whose
// `Properties` are an optional `PropertiesFileItem|EMPTY_STRING`). The loader 
// reads the connector's file metadata into this shape before building an `ai:TextDocument`.
// Azure Files' file listing (`getFileList`) surfaces the name and `Content-Length` only —
// no content type and no per-file timestamp — so `contentType` is dropped (classification
// falls back to the extension) and `lastModified` is present but generally unpopulated. The `directoryPath` is the path to the file's parent directory, relative to the share root

# A single file discovered while listing a share directory.
type FileEntry record {|
    # The file name (leaf, without its directory), e.g. `q1.pdf`.
    string name;
    # The directory path the file lives in, relative to the share root (e.g. `reports`
    # or `reports/2026`); `""` for the share root.
    string directoryPath;
    # The file's size in bytes, if reported (`Content-Length`).
    decimal? contentLength = ();
    # The file's last-modified timestamp (ISO 8601), if reported. Azure Files' file
    # listing does not currently surface this, so it is typically `()`.
    string? lastModified = ();
|};
