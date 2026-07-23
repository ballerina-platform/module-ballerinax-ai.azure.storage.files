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
import ballerina/test;
import ballerinax/azure_storage_service.files;

// The loader's connector-backed `load()` orchestration (listing/download/tree-walk) needs a
// live Azure Files account and is exercised by the Phase 5 `live-test/` sample. These tests
// cover the pure tree-walk helpers and the offline-constructible `init` path.

// ---- normalizePath -----------------------------------------------------------

@test:Config {}
isolated function testNormalizePathRootForms() {
    test:assertEquals(normalizePath(""), "", "empty path is the share root");
    test:assertEquals(normalizePath("/"), "", "'/' is the share root");
    test:assertEquals(normalizePath("  /  "), "", "surrounding whitespace is trimmed");
}

@test:Config {}
isolated function testNormalizePathStripsLeadingSlashKeepsTrailing() {
    test:assertEquals(normalizePath("/reports"), "reports", "a leading slash is dropped");
    test:assertEquals(normalizePath("reports/"), "reports/", "a trailing slash is preserved (explicit directory)");
    test:assertEquals(normalizePath("/reports/2026/"), "reports/2026/");
    test:assertEquals(normalizePath("design.md"), "design.md");
}

// ---- trimTrailingSlash -------------------------------------------------------

@test:Config {}
isolated function testTrimTrailingSlash() {
    test:assertEquals(trimTrailingSlash("reports/"), "reports");
    test:assertEquals(trimTrailingSlash("reports"), "reports", "no trailing slash is a no-op");
    test:assertEquals(trimTrailingSlash(""), "", "the share root stays empty");
}

// ---- splitPath ---------------------------------------------------------------

@test:Config {}
isolated function testSplitPathNested() {
    [string, string] [directoryPath, fileName] = splitPath("reports/2026/q1.pdf");
    test:assertEquals(directoryPath, "reports/2026");
    test:assertEquals(fileName, "q1.pdf");
}

@test:Config {}
isolated function testSplitPathAtRoot() {
    [string, string] [directoryPath, fileName] = splitPath("design.md");
    test:assertEquals(directoryPath, "", "a file at the share root has an empty directory path");
    test:assertEquals(fileName, "design.md");
}

// ---- toFileEntries (single-or-array + Content-Length) ------------------------

@test:Config {}
isolated function testToFileEntriesArrayWithContentLength() {
    files:FileList fileList = {
        File: [
            {Name: "a.txt", Properties: {'Content\-Length: "12"}},
            {Name: "b.pdf", Properties: {'Content\-Length: "2048"}}
        ]
    };
    FileEntry[] entries = toFileEntries(fileList, "reports");
    test:assertEquals(entries.length(), 2);
    test:assertEquals(entries[0].name, "a.txt");
    test:assertEquals(entries[0].directoryPath, "reports", "the listing directory is recorded on each entry");
    test:assertEquals(entries[0].contentLength, <decimal>12);
    test:assertEquals(entries[1].name, "b.pdf");
    test:assertEquals(entries[1].contentLength, <decimal>2048);
}

@test:Config {}
isolated function testToFileEntriesSingleFileNormalizedToArray() {
    // The connector returns a bare `File` (not an array) when a directory holds exactly one file.
    files:FileList fileList = {File: {Name: "only.md", Properties: {'Content\-Length: "5"}}};
    FileEntry[] entries = toFileEntries(fileList, "");
    test:assertEquals(entries.length(), 1);
    test:assertEquals(entries[0].name, "only.md");
    test:assertEquals(entries[0].directoryPath, "", "a share-root listing has an empty directory path");
    test:assertEquals(entries[0].contentLength, <decimal>5);
}

@test:Config {}
isolated function testToFileEntriesMissingContentLength() {
    // Properties may be absent or the connector's empty-string sentinel; size is then ().
    files:FileList fileList = {File: [{Name: "a.txt"}, {Name: "b.txt", Properties: ""}]};
    FileEntry[] entries = toFileEntries(fileList, "docs");
    test:assertTrue(entries[0].contentLength is (), "absent Properties yields () size");
    test:assertTrue(entries[1].contentLength is (), "empty-string Properties yields () size");
}

// ---- directoryNames (single-or-array) ----------------------------------------

@test:Config {}
isolated function testDirectoryNamesArray() {
    files:DirectoryList directoryList = {Directory: [{Name: "2025"}, {Name: "2026"}]};
    test:assertEquals(directoryNames(directoryList), ["2025", "2026"]);
}

@test:Config {}
isolated function testDirectoryNamesSingle() {
    files:DirectoryList directoryList = {Directory: {Name: "archive"}};
    test:assertEquals(directoryNames(directoryList), ["archive"]);
}

// ---- shareNames (single-or-array) --------------------------------------------

@test:Config {}
isolated function testShareNamesArray() {
    files:SharesList sharesList = {
        Shares: {
            Share: [
                {Name: "documents", Properties: {'Last\-Modified: "d", Quota: "5120"}},
                {Name: "reports", Properties: {'Last\-Modified: "d", Quota: "5120"}}
            ]
        }
    };
    test:assertEquals(shareNames(sharesList), ["documents", "reports"]);
}

@test:Config {}
isolated function testShareNamesSingle() {
    files:SharesList sharesList = {
        Shares: {Share: {Name: "documents", Properties: {'Last\-Modified: "d", Quota: "5120"}}}
    };
    test:assertEquals(shareNames(sharesList), ["documents"]);
}

// ---- isEmptyListing (connector "No ... found" sentinels) ---------------------

@test:Config {}
isolated function testIsEmptyListingSentinels() {
    files:ProcessingError noFiles = error("No files found in received azure response. Path= /s/d");
    files:ProcessingError noDirs = error("No directories found in received azure response Path= /s/d");
    files:ProcessingError noShares = error("No any shares found in storage accountAccount = acct");
    test:assertTrue(isEmptyListing(noFiles), "empty file listing is recognised");
    test:assertTrue(isEmptyListing(noDirs), "empty directory listing is recognised");
    test:assertTrue(isEmptyListing(noShares), "empty share listing is recognised");
}

@test:Config {}
isolated function testIsEmptyListingRejectsOtherErrors() {
    files:ProcessingError conversion = error("Error while converting response to a FileList.");
    test:assertFalse(isEmptyListing(conversion), "a genuine processing failure is not an empty listing");
    test:assertFalse(isEmptyListing(error("some transport failure")), "a non-connector error is not an empty listing");
    files:NotFoundError notFound = error("Resource not found.",
        httpStatus = 404, errorCode = "ResourceNotFound", message = "not found");
    test:assertFalse(isEmptyListing(notFound), "a 404 is a missing resource, not an empty listing");
}

// ---- init --------------------------------------------------------------------

@test:Config {}
isolated function testInitRejectsEmptySources() {
    files:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "token", authorizationMethod: files:SAS};
    TextDataLoader|error loader = new (config, []);
    test:assertTrue(loader is error, "at least one source is required");
}

@test:Config {}
isolated function testInitConstructsForNamedShare() returns error? {
    files:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "sv=2022-11-02&ss=f&srt=co&sp=rl&sig=abc",
        authorizationMethod: files:SAS
    };
    TextDataLoader _ = check new (config, [{share: "documents", paths: ["/reports"], recursive: true}]);
}

@test:Config {}
isolated function testInitConstructsForWildcardShare() returns error? {
    // A `"*"` source also builds the management client (share enumeration); still offline at init.
    files:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "dGhpcy1pcy1hLWZha2Uta2V5LWZvci10ZXN0aW5n",
        authorizationMethod: files:ACCESS_KEY
    };
    TextDataLoader _ = check new (config, [{share: "*"}]);
}

@test:Config {}
isolated function testInitWithExistingClientSucceeds() returns error? {
    // An already-constructed client is used as-is, so a caller sharing one client across
    // several loaders does not open a second connection pool per loader.
    files:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "token", authorizationMethod: files:SAS};
    files:FileClient fileClient = check new (config);
    TextDataLoader _ = check new ({fileClient}, [{share: "documents", paths: ["/reports"]}]);
}

@test:Config {}
isolated function testInitWithExistingClientStillValidatesSources() returns error? {
    // The source check runs before the connection is resolved, so it applies to both forms.
    files:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "token", authorizationMethod: files:SAS};
    files:FileClient fileClient = check new (config);
    TextDataLoader|ai:Error loader = new ({fileClient}, []);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("At least one source"), loader.message());
    } else {
        test:assertFail("Expected an error when no sources are provided");
    }
}

@test:Config {}
isolated function testInitWithExistingClientsSupportsWildcardShare() returns error? {
    // A `"*"` source needs the management client too; supplying both keeps share
    // enumeration available to callers that pass their own clients.
    files:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "token", authorizationMethod: files:SAS};
    files:FileClient fileClient = check new (config);
    files:ManagementClient managementClient = check new (config);
    TextDataLoader _ = check new ({fileClient, managementClient}, [{share: "*"}]);
}

@test:Config {}
isolated function testInitWithExistingClientRejectsWildcardWithoutManagementClient() returns error? {
    // Without a management client there is no configuration to build one from, so a `"*"`
    // source fails fast at init rather than at load time.
    files:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "token", authorizationMethod: files:SAS};
    files:FileClient fileClient = check new (config);
    TextDataLoader|ai:Error loader = new ({fileClient}, [{share: "*"}]);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("managementClient"), loader.message());
    } else {
        test:assertFail("Expected an error when a '*' source is given without a management client");
    }
}
