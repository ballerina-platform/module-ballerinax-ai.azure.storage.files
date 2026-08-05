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

# A rule selecting what to load from one Azure Files share. Several may be configured
# per loader. A share is the unit of addressing (analogous to a SharePoint library):
# there is no site/library chain, so a share maps directly to a `Source`. Unlike Azure
# Blob's flat namespace, an Azure Files share is a real `Directory → File` tree, so paths
# address genuine directories and files rather than blob-name prefixes.
public type Source record {|
    # The share name to read from.
    string share;
    # Directory or file paths (e.g. `/reports`, `/design.md`) to read.
    # Defaults to `["/"]`, the whole share; `[]` reads nothing.
    string[] paths = ["/"];
    # Whether sub-directories under a directory are traversed. Defaults to `false`.
    boolean recursive = false;
    # Case-insensitive extension allowlist for directory listings.
    # When not specified, all types are loaded.
    string[] includeExtensions?;
|};

// A normalized listing entry, decoupled from the connector's `File` record (whose
// `Properties` are an optional `PropertiesFileItem|EMPTY_STRING`). The loader reads the
// connector's file metadata into this shape before building an `ai:TextDocument`.
//
// Azure Files' file listing (`getFileList`) surfaces the name and `Content-Length` only —
// no content type and no per-file timestamp — so classification falls back to the file
// extension, and `mimeType`/`createdAt`/`modifiedAt` are left unset on the document. Both
// are obtainable from `Get File Properties`, but the connector discards response headers;
// see the limitations section of the module README.

# A single file discovered while listing a share directory.
type FileEntry record {|
    # The file name (leaf, without its directory), e.g. `q1.pdf`.
    string name;
    # The directory path the file lives in, relative to the share root (e.g. `reports`
    # or `reports/2026`); `""` for the share root.
    string directoryPath;
    # The file's size in bytes, if reported (`Content-Length`).
    int? contentLength = ();
|};
