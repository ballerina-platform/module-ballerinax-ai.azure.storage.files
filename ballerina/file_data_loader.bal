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
    # + azureConnection - The authentication and service configuration shared by all sources
    # + sources - One or more Azure Files shares to load documents from
    # + return - An `ai:Error` if the loader could not be initialized
    public isolated function init(
            @display {label: "Azure Connection"} files:ConnectionConfig azureConnection,
            @display {label: "Data Sources"} Source[] sources) returns ai:Error? {
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the Azure Files data loader");
        }
        self.sources = sources.cloneReadOnly();
        // The management client is only needed to enumerate shares for a `"*"` source, so it
        // is built lazily: a load that names its shares never opens a connection it will not use.
        boolean needsManagement = false;
        foreach Source src in sources {
            if src.share == "*" {
                needsManagement = true;
                break;
            }
        }
        self.fileClient = check newFileClient(azureConnection);
        self.managementClient = needsManagement ? check newManagementClient(azureConnection) : ();
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
                    ai:Document[] loaded = check self.loadPath(share, rawPath, src, tolerateMissing);
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
            // Unreachable: `init` builds the management client from the configuration whenever
            // any source uses `"*"`, and a source's share cannot change after construction.
            return error ai:Error("The management client required for a '*' share was not initialized");
        }
        files:SharesList|files:Error result = managementClient->listShares(
                {maxresults: LISTING_PAGE_SIZE.toString()});
        if result is files:SharesList {
            string[] names = dedupeStrings(shareNames(result));
            check checkListingComplete(names.length(), "shares", "/", share);
            return names;
        }
        if isEmptyListing(result) {
            return [];
        }
        return error ai:Error(
            string `Failed to list shares in the storage account: ${redactSecrets(result.message())}`, result);
    }

    // Loads a single configured path within a share. The share root (`"/"`/`""`) or a
    // trailing-`/` path is a directory listing. Otherwise the path is first probed as an
    // explicitly named file; if no such file exists it is treated as a directory, unless it
    // looks like a file (has an extension), in which case a missing file is an error (typo
    // detection) — except under `tolerateMissing` (the `"*"` case), where it is skipped.
    private isolated function loadPath(string share, string rawPath, Source src, boolean tolerateMissing)
            returns ai:Document[]|ai:Error {
        string normalized = normalizePath(rawPath);
        if normalized == "" || normalized.endsWith("/") {
            return self.listDirectory(share, trimTrailingSlash(normalized), src, tolerateMissing);
        }

        // Ambiguous file-or-directory path: probe for an exact file first.
        [string, string] [directoryPath, fileName] = splitPath(normalized);
        byte[]|files:Error content = self.fileClient->getFileAsByteArray(share, fileName,
                directoryPath == "" ? () : directoryPath);
        if content is byte[] {
            // The size of a path named directly is not known until it has been fetched: the
            // connector exposes no properties/HEAD call, so unlike a listed file this one can
            // only be rejected after the download. The limit still bounds extraction.
            if <decimal>content.length() > src.maxFileSizeInBytes {
                return error ai:Error(string `File '${rawPath}' in share '${share}' is ` +
                    string `${content.length()} bytes, which exceeds the configured ` +
                    string `'maxFileSizeInBytes' of ${src.maxFileSizeInBytes}`);
            }
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
            return error ai:Error(string `Failed to load path '${rawPath}' from share ` +
                string `'${share}': ${redactSecrets(content.message())}`, content);
        }
        // No file of that name. A path that looks like a file may still be a directory —
        // Azure Files permits dots in directory names (`/docs/v1.0`, `/2026.Q1`) — so the
        // extension heuristic alone must not decide. Try listing it before giving up.
        if getExtension(normalized) != "" {
            ai:Document[] documents = check self.listDirectory(share, normalized, src, true);
            if documents.length() > 0 {
                return documents;
            }
            if tolerateMissing {
                return [];
            }
            return error ai:Error(string `Failed to load path '${rawPath}' from share '${share}': ` +
                string `no file of that name exists, and no directory of that name holds loadable files`);
        }
        return self.listDirectory(share, normalized, src, tolerateMissing);
    }

    // Lists a directory: converts its files into documents and, when `recursive`, descends
    // into each sub-directory. Files and sub-directories come from separate connector calls
    // (`getFileList` / `getDirectoryList`), so — unlike the flat-namespace Blob loader — no
    // direct-child filtering is needed; a non-recursive load is simply this directory's files.
    // An empty directory is not an error; a missing directory is tolerated only under `"*"`.
    private isolated function listDirectory(string share, string directoryPath, Source src,
            boolean tolerateMissing) returns ai:Document[]|ai:Error {
        FileEntry[] entries = check self.listFiles(share, directoryPath, tolerateMissing);

        ai:Document[] documents = [];
        foreach FileEntry entry in entries {
            if !matchesExtensionFilter(entry.name, src.includeExtensions) {
                continue;
            }
            // The listing reports each file's size, so an oversized file is rejected before
            // it is fetched — the whole body is otherwise held in memory at once.
            decimal? contentLength = entry.contentLength;
            if contentLength is decimal && contentLength > src.maxFileSizeInBytes {
                log:printWarn("Skipping an Azure Files file larger than 'maxFileSizeInBytes'",
                        fileName = entry.name, directory = directoryPath, share = share,
                        fileSize = contentLength, maxFileSizeInBytes = src.maxFileSizeInBytes);
                continue;
            }

            byte[]|ai:Error content = self.downloadFile(share, entry);
            if content is ai:Error {
                // A download failure is an infrastructure problem (auth, throttling, a
                // vanished file), not a property of the content, so it aborts the walk
                // rather than quietly shrinking the result set.
                return content;
            }
            ai:TextDocument?|ai:Error document = buildDocument(content, entry.name, (),
                    entry.contentLength ?: <decimal>content.length(), (), ());
            if document is ai:Error {
                // The file was fetched but its bytes could not be turned into text: a
                // scanned PDF, a password-protected or corrupt Office file, a mislabeled
                // binary. One such file must not abort a bulk ingestion run, so it is
                // skipped like other non-text content. (A path named explicitly in `paths`
                // still surfaces the descriptive error to the caller.)
                log:printWarn("Skipping an Azure Files file whose text could not be extracted",
                        fileName = entry.name, directory = directoryPath, share = share,
                        reason = document.message());
                continue;
            }
            if document is ai:TextDocument {
                documents.push(document);
            } else {
                log:printWarn("Skipping a non-text Azure Files file",
                        fileName = entry.name, directory = directoryPath, share = share);
            }
        }

        if src.recursive {
            foreach string subDirectory in check self.listSubDirectories(share, directoryPath, tolerateMissing) {
                string childPath = directoryPath == "" ? subDirectory : (directoryPath + "/" + subDirectory);
                ai:Document[] childDocuments = check self.listDirectory(share, childPath, src, tolerateMissing);
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
        files:FileList|files:Error fileList = self.fileClient->getFileList(share, directoryArg,
                {maxresults: LISTING_PAGE_SIZE.toString()});
        if fileList is files:FileList {
            FileEntry[] entries = toFileEntries(fileList, directoryPath);
            check checkListingComplete(entries.length(), "files", directoryPath, share);
            return entries;
        }
        if isEmptyListing(fileList) {
            // "No files found" is not proof of an empty directory: the connector returns the
            // same sentinel for any response whose XML holds no <File> entries, which
            // includes every Azure *error* body. Confirm before believing it.
            check self.probeDirectory(share, directoryPath, tolerateMissing);
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
            string `'${share}': ${redactSecrets(fileList.message())}`, fileList);
    }

    // Establishes whether a listing that reported "nothing here" really was empty.
    //
    // The connector's listing calls never inspect the HTTP status, so a 403 from an expired
    // SAS, a 503 while the account is throttled, and a share that does not exist all arrive
    // looking exactly like an empty directory. Left alone that fails open: a load quietly
    // returns no documents and reports success, and a knowledge base silently empties.
    //
    // `getFileAsByteArray` does check the status, so asking it for a file that will not exist
    // turns the ambiguity into a typed answer. Azure distinguishes "the file is missing"
    // (`ResourceNotFound`) from "its parent is missing" (`ParentNotFound`/`ShareNotFound`),
    // and answers 403/5xx before either. Returns `()` when the directory genuinely is empty.
    private isolated function probeDirectory(string share, string directoryPath, boolean tolerateMissing)
            returns ai:Error? {
        string? directoryArg = directoryPath == "" ? () : directoryPath;
        byte[]|files:Error probe = self.fileClient->getFileAsByteArray(share, EMPTINESS_PROBE_FILE, directoryArg);
        if probe is byte[] {
            // A file with the probe name actually exists, so the directory certainly does.
            return ();
        }
        if probe is files:ForbiddenError {
            return error ai:Error(string `Not authorized to read '${directoryPath}' in share ` +
                string `'${share}' (Azure returned ${probe.detail().errorCode}). The listing came ` +
                string `back empty because the request was rejected, not because there are no ` +
                string `files — check that the SAS or account key is valid, unexpired, and ` +
                string `granted list and read permission on the file service`, probe);
        }
        if probe is files:NotFoundError {
            string errorCode = probe.detail().errorCode;
            if errorCode == PARENT_NOT_FOUND_CODE || errorCode == SHARE_NOT_FOUND_CODE {
                if tolerateMissing {
                    return ();
                }
                return error ai:Error(string `Path '${directoryPath}' does not exist in share ` +
                    string `'${share}' (Azure returned ${errorCode})`, probe);
            }
            // `ResourceNotFound`, or a 404 whose code could not be read: the parent resolved,
            // so the directory is there and the empty listing was truthful.
            return ();
        }
        if probe is files:ServerError {
            return error ai:Error(string `Could not confirm whether '${directoryPath}' in share ` +
                string `'${share}' is empty or unreadable: Azure returned HTTP ` +
                string `${probe.detail().httpStatus} (${probe.detail().errorCode}). Treating an ` +
                string `unverified empty listing as success would hide the failure`, probe);
        }
        return error ai:Error(string `Could not confirm whether '${directoryPath}' in share ` +
            string `'${share}' is empty or unreadable: ${redactSecrets(probe.message())}`, probe);
    }

    // Returns the names of a directory's immediate sub-directories. An empty or missing
    // directory yields no sub-directories rather than an error (the parent's files were
    // already listed; a genuine failure still surfaces).
    private isolated function listSubDirectories(string share, string directoryPath, boolean tolerateMissing)
            returns string[]|ai:Error {
        string? directoryArg = directoryPath == "" ? () : directoryPath;
        files:DirectoryList|files:Error directoryList = self.fileClient->getDirectoryList(share, directoryArg,
                {maxresults: LISTING_PAGE_SIZE.toString()});
        if directoryList is files:DirectoryList {
            string[] names = directoryNames(directoryList);
            check checkListingComplete(names.length(), "sub-directories", directoryPath, share);
            return names;
        }
        if isEmptyListing(directoryList) || isNotFoundError(directoryList) {
            // No probe here: the parent's own file listing has already been verified by
            // `listFiles`, so a directory that is missing or unreadable has been reported.
            return [];
        }
        return error ai:Error(string `Failed to list sub-directories in '${directoryPath}' of share ` +
            string `'${share}': ${redactSecrets(directoryList.message())}`, directoryList);
    }

    // Downloads a listed file's content. Kept separate from converting it to a document so
    // the caller can tell a transport failure (which must abort the walk) from content that
    // simply cannot be turned into text (which is skipped).
    private isolated function downloadFile(string share, FileEntry entry) returns byte[]|ai:Error {
        byte[]|files:Error content = self.fileClient->getFileAsByteArray(share, entry.name,
                entry.directoryPath == "" ? () : entry.directoryPath);
        if content is files:Error {
            return error ai:Error(string `Failed to download file '${entry.name}' from directory ` +
                string `'${entry.directoryPath}' of share '${share}': ` +
                string `${redactSecrets(content.message())}`, content);
        }
        return content;
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
