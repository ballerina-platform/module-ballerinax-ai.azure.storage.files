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
    test:assertEquals(entries[0].contentLength, 12);
    test:assertEquals(entries[1].name, "b.pdf");
    test:assertEquals(entries[1].contentLength, 2048);
}

@test:Config {}
isolated function testToFileEntriesSingleFileNormalizedToArray() {
    // The connector returns a bare `File` (not an array) when a directory holds exactly one file.
    files:FileList fileList = {File: {Name: "only.md", Properties: {'Content\-Length: "5"}}};
    FileEntry[] entries = toFileEntries(fileList, "");
    test:assertEquals(entries.length(), 1);
    test:assertEquals(entries[0].name, "only.md");
    test:assertEquals(entries[0].directoryPath, "", "a share-root listing has an empty directory path");
    test:assertEquals(entries[0].contentLength, 5);
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
isolated function testInitRejectsNonPositiveMaxFileSize() {
    // A zero or negative bound would silently skip every file, so it is rejected at init.
    // Both sides of the boundary are asserted: a check weakened from `<= 0` to `< 0` would
    // still let zero through, and zero is the value a mis-typed configuration actually
    // produces.
    files:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "token", authorizationMethod: files:SAS};
    TextDataLoader|error zero = new (config, [{share: "documents"}], 0);
    test:assertTrue(zero is error, "'maxFileSizeInBytes' of 0 must be rejected");
    TextDataLoader|error negative = new (config, [{share: "documents"}], -1);
    test:assertTrue(negative is error, "a negative 'maxFileSizeInBytes' must be rejected");
    if negative is ai:Error {
        test:assertTrue(negative.message().includes("positive"), negative.message());
    }
}

@test:Config {}
isolated function testInitAcceptsCustomMaxFileSize() returns error? {
    // Construction only. What the stored limit *does* — the range the download asks for and
    // the skip/error split once it comes back — is covered by the bounded-download tests
    // below and, end to end, by the live sample: the connector derives its endpoint from the
    // account name (`https://<account>.file.core.windows.net`), so no local stub can stand in
    // for Azure here.
    files:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "sv=2022-11-02&ss=f&srt=co&sp=rl&sig=abc",
        authorizationMethod: files:SAS
    };
    TextDataLoader _ = check new (config, [{share: "documents"}], 1024);
}

@test:Config {}
isolated function testInitReportsEmptySourcesAsAiError() {
    // The source check runs before any client is constructed, so it is reported as a typed
    // `ai:Error` with an actionable message rather than a connector failure.
    files:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "token", authorizationMethod: files:SAS};
    TextDataLoader|ai:Error loader = new (config, []);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("At least one source"), loader.message());
    } else {
        test:assertFail("Expected an error when no sources are provided");
    }
}

// ---- SAS redaction in surfaced errors ----------------------------------------

@test:Config {}
isolated function testRedactSecretsStripsSasSignature() {
    // The connector concatenates the full request path — SAS included — into some of its
    // error messages, and those messages are interpolated into `ai:Error`s that callers log.
    string raw = "No files found in received azure response. Path= /share/dir?restype=directory" +
        "&comp=list&sv=2022-11-02&ss=f&srt=co&sp=rl&sig=abc123DEF456%2Bxyz%3D";
    string redacted = redactSecrets(raw);
    test:assertFalse(redacted.includes("abc123DEF456"), "The SAS signature must not survive: " + redacted);
    test:assertTrue(redacted.includes("sig=<redacted>"), redacted);
    // The rest of the URL stays intact so the message is still diagnosable.
    test:assertTrue(redacted.includes("/share/dir"), redacted);
    test:assertTrue(redacted.includes("sv=2022-11-02"), redacted);
}

@test:Config {}
isolated function testRedactSecretsHandlesSignatureFollowedByAnotherParameter() {
    string redacted = redactSecrets("path?sig=SECRETVALUE&comp=list");
    test:assertEquals(redacted, "path?sig=<redacted>&comp=list",
            "Only the signature value is removed, not what follows it");
}

@test:Config {}
isolated function testRedactSecretsLeavesCleanMessagesUnchanged() {
    string clean = "Path 'reports' was not found in share 'documents'";
    test:assertEquals(redactSecrets(clean), clean);
}

// ---- listing truncation detection --------------------------------------------

@test:Config {}
isolated function testCheckListingCompleteAcceptsPartialPage() {
    // Anything short of a full page means Azure had nothing more to give.
    test:assertTrue(checkListingComplete(0, "files", "reports", "documents") is ());
    test:assertTrue(checkListingComplete(4999, "files", "reports", "documents") is ());
}

@test:Config {}
isolated function testCheckListingCompleteRejectsFullPage() {
    // A page that comes back exactly full means there are more entries that this loader
    // cannot reach, so the load must fail rather than silently drop them.
    ai:Error? result = checkListingComplete(5000, "files", "reports", "documents");
    if result is ai:Error {
        test:assertTrue(result.message().includes("full page"), result.message());
        test:assertTrue(result.message().includes("silently drop"), result.message());
    } else {
        test:assertFail("A full listing page must be reported, not truncated silently");
    }
}

// ---- Azure error codes on connector errors -----------------------------------

@test:Config {}
isolated function testAzureErrorCodeReadsServerErrorDetail() {
    files:NotFoundError notFound = error files:NotFoundError("Resource not found.",
            httpStatus = 404, errorCode = RESOURCE_NOT_FOUND_CODE, message = "not found");
    test:assertEquals(azureErrorCode(notFound), RESOURCE_NOT_FOUND_CODE);

    files:ForbiddenError forbidden = error files:ForbiddenError("Forbidden. ",
            httpStatus = 403, errorCode = "AuthenticationFailed", message = "denied");
    test:assertEquals(azureErrorCode(forbidden), "AuthenticationFailed");
}

@test:Config {}
isolated function testAzureErrorCodeNilForNonServerErrors() {
    // A ProcessingError carries no Azure detail record, so there is no code to read.
    test:assertTrue(azureErrorCode(error files:ProcessingError("No files found")) is ());
    test:assertTrue(azureErrorCode(error("something else")) is ());
}

// ---- the bound imposed on every download -------------------------------------

@test:Config {}
isolated function testBoundedRangeAsksForOneByteBeyondTheLimit() {
    // The single extra byte is the whole mechanism: `bytes=0-limit` yields `limit + 1` bytes
    // only when the file has more to give, so an oversized file is recognised from the length
    // of the response without reading any further into it. A range ending *at* `limit - 1`
    // would make a file of exactly `limit` bytes indistinguishable from a 4 TiB one.
    files:ContentRange range = boundedRange(1024);
    test:assertEquals(range.startByte, 0, "the range must start at the first byte");
    test:assertEquals(range.endByte, 1024, "the range must end one byte past the limit");
    test:assertEquals(range.endByte - range.startByte + 1, 1025,
            "1024 permitted bytes, plus the one byte that proves there are more");
    test:assertEquals(boundedRange(104857600).endByte, 104857600, "the default limit is bounded the same way");
}

@test:Config {}
isolated function testIsInvalidRangeErrorRecognisesTheEmptyFileRejection() {
    // A zero-length file has no byte 0, so Azure answers the bounded request with 416
    // `InvalidRange`. That is the loader's cue to re-read the file without a range rather
    // than report the load as failed.
    files:ServerError invalidRange = error files:ServerError("Undefined error occured",
            httpStatus = STATUS_RANGE_NOT_SATISFIABLE, errorCode = INVALID_RANGE_CODE,
            message = "The range specified is invalid for the current size of the resource.");
    test:assertTrue(isInvalidRangeError(invalidRange), "a 416 InvalidRange marks an empty file");

    // A 416 whose XML body the connector could not parse arrives as a generic `ServerError`
    // carrying `errorCode = "Undefined"`, so the status alone has to carry the decision.
    files:ServerError undefined = error files:ServerError("Undefined error occured",
            httpStatus = STATUS_RANGE_NOT_SATISFIABLE, errorCode = "Undefined", message = "Unknown");
    test:assertTrue(isInvalidRangeError(undefined), "an unparsed 416 is still a range rejection");
}

@test:Config {}
isolated function testIsInvalidRangeErrorRejectsOtherFailures() {
    // Every other failure keeps its own handling. Widening this predicate would retry a
    // missing file or a rejected credential as an *unbounded* download, which is precisely
    // what the range exists to prevent.
    files:NotFoundError notFound = error files:NotFoundError("Resource not found.",
            httpStatus = 404, errorCode = RESOURCE_NOT_FOUND_CODE, message = "not found");
    test:assertFalse(isInvalidRangeError(notFound), "a 404 is a missing file, not an empty one");
    files:ForbiddenError forbidden = error files:ForbiddenError("Forbidden. ",
            httpStatus = 403, errorCode = "AuthenticationFailed", message = "denied");
    test:assertFalse(isInvalidRangeError(forbidden), "a 403 must surface as an authorization failure");
    test:assertFalse(isInvalidRangeError(error files:ProcessingError("No files found")));
    test:assertFalse(isInvalidRangeError(error("some transport failure")));
}
