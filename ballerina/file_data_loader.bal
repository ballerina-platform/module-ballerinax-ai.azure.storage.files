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

import ballerina/ai;
import ballerina/log;
import ballerinax/azure_storage_service.files;

# A data loader that retrieves documents from Azure Files shares as text.
@display {
    label: "Azure Files Text Data Loader"
}
public isolated class TextDataLoader {
    *ai:DataLoader;

    private final files:FileClient fileClient;
    // Only constructed when a source uses `share: "*"` (share enumeration); `()` otherwise.
    private final files:ManagementClient? managementClient;
    private final readonly & Source[] sources;

    # Initializes the Azure Files data loader.
    #
    # + connection - The authentication and service configuration shared by all sources, or
    #                existing connector clients (`Clients`) to reuse. Clients supplied this
    #                way are **not** owned by the loader: the caller remains responsible for
    #                their lifecycle. A `Clients` value must carry a `managementClient` when
    #                any source uses `share: "*"`, since enumerating shares requires one and
    #                the loader has no configuration to build it from.
    # + sources - One or more Azure Files shares to load documents from
    # + return - An `ai:Error` if the loader could not be initialized
    public isolated function init(
            @display {label: "Connection"} files:ConnectionConfig|Clients connection,
            @display {label: "Data Sources"} Source[] sources) returns ai:Error? {
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the Azure Files data loader");
        }
        self.sources = sources.cloneReadOnly();
        // The management client is only needed to enumerate shares for a `"*"` source.
        boolean needsManagement = false;
        foreach Source src in sources {
            if src.share == "*" {
                needsManagement = true;
                break;
            }
        }
        if connection is Clients {
            // Caller-supplied clients are used as-is and are not owned by the loader.
            files:ManagementClient? managementClient = connection?.managementClient;
            if needsManagement && managementClient is () {
                return error ai:Error("A 'managementClient' must be supplied alongside the 'fileClient' when a " +
                    "source uses share '*', as enumerating the account's shares requires it");
            }
            self.fileClient = connection.fileClient;
            self.managementClient = managementClient;
        } else {
            // `files:ConnectionConfig` includes the open `client.config:ConnectionConfig`, so it
            // carries an implicit rest field. The compiler cannot then prove it disjoint from
            // `Clients` and does not narrow this branch, hence the cast — which is safe, as the
            // union has only these two members and `Clients` was ruled out above.
            files:ConnectionConfig config = <files:ConnectionConfig>connection;
            self.fileClient = check newFileClient(config);
            self.managementClient = needsManagement ? check newManagementClient(config) : ();
        }
    }

    # Loads the configured Azure Files documents.
    #
    # + return - The loaded document when a single file is resolved, an array of documents
    #            otherwise, or an `ai:Error` on failure
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        foreach Source src in self.sources {
            string[] shares = check self.resolveShares(src.share);
            // A `"*"` share applies the paths to every share, where a path need not exist in
            // all of them, so a missing path is tolerated (skipped) rather than an error.
            boolean tolerateMissing = src.share == "*";
            foreach string share in shares {
                foreach string rawPath in src.paths {
                    ai:Document[] loaded = check self.loadPath(share, rawPath, src.recursive,
                            src.includeExtensions, tolerateMissing);
                    documents.push(...loaded);
                }
            }
        }
        if documents.length() == 1 {
            return documents[0];
        }
        return documents;
    }

    // Resolves the shares to read from: the single named share, or every share in the
    // account when `"*"`. Azure Files' `listShares` returns all shares in one response
    // (the connector does not surface a continuation marker), so no pagination loop is
    // possible here; an account with no shares yields an empty list rather than an error.
    private isolated function resolveShares(string share) returns string[]|ai:Error {
        if share != "*" {
            return [share];
        }
        files:ManagementClient? managementClient = self.managementClient;
        if managementClient is () {
            // Unreachable: for a `"*"` source `init` either builds the management client from
            // the config or requires the caller to have supplied one, failing otherwise.
            return error ai:Error("The management client required for a '*' share was not initialized");
        }
        files:SharesList|files:Error result = managementClient->listShares();
        if result is files:SharesList {
            return dedupeStrings(shareNames(result));
        }
        if isEmptyListing(result) {
            return [];
        }
        return error ai:Error(string `Failed to list shares in the storage account: ${result.message()}`, result);
    }

    // Loads a single configured path within a share. The share root (`"/"`/`""`) or a
    // trailing-`/` path is a directory listing. Otherwise the path is first probed as an
    // explicitly named file; if no such file exists it is treated as a directory, unless it
    // looks like a file (has an extension), in which case a missing file is an error (typo
    // detection) — except under `tolerateMissing` (the `"*"` case), where it is skipped.
    private isolated function loadPath(string share, string rawPath, boolean recursive,
            string[]? includeExtensions, boolean tolerateMissing) returns ai:Document[]|ai:Error {
        string normalized = normalizePath(rawPath);
        if normalized == "" || normalized.endsWith("/") {
            return self.listDirectory(share, trimTrailingSlash(normalized), recursive, includeExtensions,
                    tolerateMissing);
        }

        // Ambiguous file-or-directory path: probe for an exact file first.
        [string, string] [directoryPath, fileName] = splitPath(normalized);
        byte[]|files:Error content = self.fileClient->getFileAsByteArray(share, fileName,
                directoryPath == "" ? () : directoryPath);
        if content is byte[] {
            // An explicitly named file is always loaded, regardless of the extension filter.
            // A deliberately named non-text file is an error, unlike directory contents.
            ai:TextDocument? document = check buildDocument(content, fileName, (),
                    <decimal>content.length(), (), ());
            if document is () {
                return error ai:Error(string `Unsupported (non-text) file type for path '${rawPath}'`);
            }
            return [document];
        }
        if !isNotFoundError(content) {
            return error ai:Error(
                string `Failed to load path '${rawPath}' from share '${share}': ${content.message()}`, content);
        }
        // No exact file. If the path looks like a file, a missing file is an error (unless
        // tolerated); otherwise treat it as a directory and list it.
        if getExtension(normalized) != "" {
            if tolerateMissing {
                return [];
            }
            return error ai:Error(
                string `Failed to load path '${rawPath}' from share '${share}': file not found`);
        }
        return self.listDirectory(share, normalized, recursive, includeExtensions, tolerateMissing);
    }

    // Lists a directory: converts its files into documents and, when `recursive`, descends
    // into each sub-directory. Files and sub-directories come from separate connector calls
    // (`getFileList` / `getDirectoryList`), so — unlike the flat-namespace Blob loader — no
    // direct-child filtering is needed; a non-recursive load is simply this directory's files.
    // An empty directory is not an error; a missing directory is tolerated only under `"*"`.
    private isolated function listDirectory(string share, string directoryPath, boolean recursive,
            string[]? includeExtensions, boolean tolerateMissing) returns ai:Document[]|ai:Error {
        FileEntry[] entries = check self.listFiles(share, directoryPath, tolerateMissing);

        ai:Document[] documents = [];
        foreach FileEntry entry in entries {
            if !matchesExtensionFilter(entry.name, includeExtensions) {
                continue;
            }
            ai:TextDocument?|ai:Error document = self.toDocument(share, entry);
            if document is ai:Error {
                // A text-less PDF (scanned/image-only or blank) has no text to extract;
                // inside a listing it is skipped like other non-text content rather than
                // aborting the whole walk. (An explicitly named one still surfaces the
                // descriptive error to the caller.)
                if isTextlessPdfError(document) {
                    log:printWarn("Skipping a PDF with no extractable text content",
                            fileName = entry.name, directory = directoryPath, share = share);
                    continue;
                }
                return document;
            }
            if document is ai:TextDocument {
                documents.push(document);
            } else {
                log:printWarn("Skipping a non-text Azure Files file",
                        fileName = entry.name, directory = directoryPath, share = share);
            }
        }

        if recursive {
            foreach string subDirectory in check self.listSubDirectories(share, directoryPath, tolerateMissing) {
                string childPath = directoryPath == "" ? subDirectory : (directoryPath + "/" + subDirectory);
                ai:Document[] childDocuments = check self.listDirectory(share, childPath, true,
                        includeExtensions, tolerateMissing);
                documents.push(...childDocuments);
            }
        }
        return documents;
    }

    // Lists a directory's files as normalized `FileEntry` values. An empty directory (the
    // connector's "No files found" sentinel) yields no entries; a missing directory (404) is
    // tolerated only under a `"*"` source, otherwise it is an error (typo detection).
    private isolated function listFiles(string share, string directoryPath, boolean tolerateMissing)
            returns FileEntry[]|ai:Error {
        string? directoryArg = directoryPath == "" ? () : directoryPath;
        files:FileList|files:Error fileList = self.fileClient->getFileList(share, directoryArg);
        if fileList is files:FileList {
            return toFileEntries(fileList, directoryPath);
        }
        if isEmptyListing(fileList) {
            // The directory exists but contains no files (it may still hold sub-directories).
            return [];
        }
        if isNotFoundError(fileList) {
            if tolerateMissing {
                return [];
            }
            return error ai:Error(
                string `Path '${directoryPath}' was not found in share '${share}'`, fileList);
        }
        return error ai:Error(string `Failed to list files in '${directoryPath}' of share ` +
            string `'${share}': ${fileList.message()}`, fileList);
    }

    // Returns the names of a directory's immediate sub-directories. An empty or missing
    // directory yields no sub-directories rather than an error (the parent's files were
    // already listed; a genuine failure still surfaces).
    private isolated function listSubDirectories(string share, string directoryPath, boolean tolerateMissing)
            returns string[]|ai:Error {
        string? directoryArg = directoryPath == "" ? () : directoryPath;
        files:DirectoryList|files:Error directoryList = self.fileClient->getDirectoryList(share, directoryArg);
        if directoryList is files:DirectoryList {
            return directoryNames(directoryList);
        }
        if isEmptyListing(directoryList) || isNotFoundError(directoryList) {
            return [];
        }
        return error ai:Error(string `Failed to list sub-directories in '${directoryPath}' of share ` +
            string `'${share}': ${directoryList.message()}`, directoryList);
    }

    // Downloads a file's content and converts it into an `ai:TextDocument`, returning `()`
    // when the file cannot be represented as text (the caller skips it). Azure Files
    // listings report no content type, so classification falls back to the extension.
    private isolated function toDocument(string share, FileEntry entry) returns ai:TextDocument?|ai:Error {
        byte[]|files:Error content = self.fileClient->getFileAsByteArray(share, entry.name,
                entry.directoryPath == "" ? () : entry.directoryPath);
        if content is files:Error {
            return error ai:Error(string `Failed to download file '${entry.name}' from directory ` +
                string `'${entry.directoryPath}' of share '${share}': ${content.message()}`, content);
        }
        decimal? contentLength = entry.contentLength ?: <decimal>content.length();
        return buildDocument(content, entry.name, (), contentLength, (), entry.lastModified);
    }
}

// Normalizes a configured path into a share-relative path: trims it, drops a leading `/`
// (Azure Files directory paths have no leading slash), and maps the share root (`""`/`"/"`)
// to `""`. A trailing `/` is preserved, since it distinguishes an explicit directory
// (`reports/`) from an ambiguous file-or-directory path (`reports`).
isolated function normalizePath(string path) returns string {
    string trimmed = path.trim();
    if trimmed == "" || trimmed == "/" {
        return "";
    }
    return trimmed.startsWith("/") ? trimmed.substring(1) : trimmed;
}

// Removes a single trailing `/`, converting an explicit directory path into the bare
// directory path the connector expects (`reports/` -> `reports`, `""` -> `""`).
isolated function trimTrailingSlash(string path) returns string =>
    path.endsWith("/") ? path.substring(0, path.length() - 1) : path;

// Splits a normalized (leading-/trailing-slash-free) path into its parent directory and
// leaf file name, e.g. `reports/2026/q1.pdf` -> (`reports/2026`, `q1.pdf`) and
// `design.md` -> (`""`, `design.md`).
isolated function splitPath(string path) returns [string, string] {
    int? lastSlash = path.lastIndexOf("/");
    if lastSlash is () {
        return ["", path];
    }
    return [path.substring(0, lastSlash), path.substring(lastSlash + 1)];
}

// Builds normalized `FileEntry` values from a connector `FileList`, recording the directory
// each file was listed in. The connector's `File` field is a single-or-array union, so it
// is normalized to an array first.
isolated function toFileEntries(files:FileList fileList, string directoryPath) returns FileEntry[] {
    files:File[]|files:File file = fileList.File;
    files:File[] fileArray = file is files:File[] ? file : [file];
    FileEntry[] entries = [];
    foreach files:File f in fileArray {
        entries.push({
            name: f.Name,
            directoryPath: directoryPath,
            contentLength: contentLengthOf(f)
        });
    }
    return entries;
}

// Reads a listed file's `Content-Length`, or `()` when absent. Azure Files reports the size
// as a string, and the connector types the property block as `PropertiesFileItem|""`.
isolated function contentLengthOf(files:File file) returns decimal? {
    files:PropertiesFileItem|string? properties = file?.Properties;
    if properties !is files:PropertiesFileItem {
        return ();
    }
    string? contentLength = properties?.'Content\-Length;
    if contentLength is () {
        return ();
    }
    decimal|error parsed = decimal:fromString(contentLength.trim());
    return parsed is decimal ? parsed : ();
}

// Extracts the sub-directory names from a connector `DirectoryList`, normalizing its
// single-or-array `Directory` field to an array.
isolated function directoryNames(files:DirectoryList directoryList) returns string[] {
    files:Directory[]|files:Directory directory = directoryList.Directory;
    files:Directory[] directoryArray = directory is files:Directory[] ? directory : [directory];
    return directoryArray.'map(isolated function(files:Directory d) returns string => d.Name);
}

// Extracts the share names from a connector `SharesList`, normalizing its single-or-array
// `Share` field to an array.
isolated function shareNames(files:SharesList sharesList) returns string[] {
    files:ShareItem[]|files:ShareItem share = sharesList.Shares.Share;
    files:ShareItem[] shareArray = share is files:ShareItem[] ? share : [share];
    return shareArray.'map(isolated function(files:ShareItem s) returns string => s.Name);
}

// Reports whether a connector error is the "empty listing" sentinel. The `files` connector
// signals an empty share/directory/account listing by returning a `ProcessingError` whose
// message is one of `NO_FILE_FOUND` / `NO_DIRECTORIES_FOUND` / `NO_SHARES_FOUND` (rather than
// an empty result), so the loader treats these as "nothing here", not a failure.
isolated function isEmptyListing(error err) returns boolean {
    if err !is files:ProcessingError {
        return false;
    }
    string message = err.message();
    return message.includes("No files found") || message.includes("No directories found")
            || message.includes("No any shares found");
}
