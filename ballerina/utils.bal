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
import ballerina/jballerina.java;
import ballerina/lang.regexp;
import ballerina/log;
import ballerina/time;

// How a file's content is turned into text, derived from its MIME type / extension.
enum DocumentKind {
    // Inherently textual; decoded directly from its bytes.
    PLAIN_TEXT,
    // A PDF or Microsoft Office document whose text is extracted via Apache Tika
    // (PDFBox for PDF, Apache POI for Office).
    EXTRACTABLE,
    // Cannot be represented as text (images, audio, unknown binary); skipped.
    UNSUPPORTED
}

// Builds an `ai:TextDocument` from downloaded file content, extracting the text of
// PDF documents via Apache Tika. Returns `()` for content that cannot be represented
// as text (images, audio, Office documents, unknown binary), signalling the caller to skip.
isolated function buildDocument(byte[] content, string fileName, string? mimeType, decimal? fileSize,
        string? createdDateTime, string? modifiedDateTime) returns ai:TextDocument?|ai:Error {
    ai:Metadata metadata = {fileName};
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    if fileSize is decimal {
        metadata.fileSize = fileSize;
    }
    time:Utc? createdAt = toUtc(createdDateTime);
    if createdAt is time:Utc {
        metadata.createdAt = createdAt;
    }
    time:Utc? modifiedAt = toUtc(modifiedDateTime);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }

    match classify(fileName, mimeType) {
        PLAIN_TEXT => {
            // Not `string:fromBytes`: that accepts strict UTF-8 only, while an SMB share
            // routinely holds UTF-16LE and UTF-8-with-BOM text written by Windows tooling.
            string|error text = decodeText(content);
            if text is error {
                return error ai:Error(
                    string `Failed to decode text content of '${fileName}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        EXTRACTABLE => {
            [string, boolean]|error extracted = extractText(content, fileName, mimeType);
            if extracted is error {
                return error ai:Error(
                    string `Failed to extract text from '${fileName}': ${extracted.message()}`, extracted);
            }
            [string, boolean] [text, truncated] = extracted;
            if truncated {
                // The document held more text than the extractor's per-document cap. The
                // capped text is still returned — a partially indexed document is more useful
                // than a failed load — but the dropped tail must not go unreported, since
                // nothing downstream can tell a truncated document from a complete one.
                log:printWarn("Truncated the extracted text of an Azure Files document at the " +
                        "extractor's per-document character limit; the tail was not indexed",
                        fileName = fileName, extractedCharacters = text.length());
            }
            return {content: text, metadata};
        }
    }
    return ();
}

// Extracts plain text from a PDF or Microsoft Office document using Apache Tika, reading
// directly from the in-memory bytes (no temporary file). The parser is selected from
// `mimeType` when it names a format the extractor knows, and from the extension otherwise —
// the same precedence `classify` applies, so the two cannot disagree. `fileName` is also
// passed to Tika as a resource-name hint.
//
// Returns the extracted text together with whether it was truncated at the extractor's
// per-document character limit, or an `error` if the content cannot be parsed, is
// password-protected, or yields no text at all.
isolated function extractText(byte[] content, string fileName, string? mimeType)
        returns [string, boolean]|error = @java:Method {
    'class: "io.ballerina.lib.ai.azure.storage.files.TextExtractor",
    name: "extractText"
} external;

// Decodes an inherently textual file into a string, honouring a UTF-8/UTF-16 byte-order
// mark and recognising BOM-less UTF-16, both of which are common on an SMB share. Returns
// an `error` when the bytes are not text in any of those encodings.
isolated function decodeText(byte[] content) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.azure.storage.files.TextExtractor",
    name: "decodeText"
} external;

// The sentinel phrase the native extractor embeds in every "parsed fine, but there is no
// text" message — a scanned/image-only PDF, a blank PDF, or an empty Office document.
// Mirrors `TextExtractor.NO_EXTRACTABLE_TEXT_SENTINEL`; keep the two in sync.
const string NO_EXTRACTABLE_TEXT_SENTINEL = "no extractable text";

// Reports whether an error denotes a document that parsed successfully but holds no text.
// The loader uses this to skip such files in directory listings (with a warning) — like
// other non-text content — while an explicitly named one surfaces the descriptive,
// case-specific error to the caller.
isolated function isNoExtractableTextError(error err) returns boolean =>
    err.message().includes(NO_EXTRACTABLE_TEXT_SENTINEL);

// Classifies a file by how its text is obtained: a recognised MIME type decides on its own,
// and the extension is consulted only when there is no MIME type or it is not one this module
// knows. The MIME type is the authoritative statement of what the bytes are, so letting an
// extension override it would classify `report.txt` served as `application/pdf` as plain text
// and hand a PDF's bytes to the text decoder.
isolated function classify(string fileName, string? mimeType) returns DocumentKind {
    string mime = (mimeType ?: "").toLowerAscii();
    if mime != "" {
        if mime.startsWith("text/") || TEXT_MIME_TYPES.indexOf(mime) !is () {
            return PLAIN_TEXT;
        }
        // PDF and Microsoft Office documents are extracted via Apache Tika (PDFBox / POI).
        if EXTRACTABLE_MIME_TYPES.indexOf(mime) !is () {
            return EXTRACTABLE;
        }
    }
    string extension = getExtension(fileName);
    if TEXT_EXTENSIONS.indexOf(extension) !is () {
        return PLAIN_TEXT;
    }
    if EXTRACTABLE_EXTENSIONS.indexOf(extension) !is () {
        return EXTRACTABLE;
    }
    return UNSUPPORTED;
}

// Returns the lower-cased file extension (without the dot), or `""` if none.
isolated function getExtension(string fileName) returns string {
    int? lastDotIndex = fileName.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return fileName.substring(lastDotIndex + 1).toLowerAscii();
}

// Reports whether a file passes the extension allowlist (`()`/empty matches all).
isolated function matchesExtensionFilter(string fileName, string[]? includeExtensions) returns boolean {
    if includeExtensions is () || includeExtensions.length() == 0 {
        return true;
    }
    string extension = getExtension(fileName);
    foreach string allowed in includeExtensions {
        string normalized = allowed.toLowerAscii();
        if normalized.startsWith(".") {
            normalized = normalized.substring(1);
        }
        if normalized == extension {
            return true;
        }
    }
    return false;
}

// The page size requested for every directory, file and share listing.
//
// Azure caps a single `List Directories and Files` page at 5,000 entries and will not return
// more however large a `maxresults` is asked for. Requesting it explicitly is what makes
// truncation *detectable*: a page that comes back exactly full is the signal that Azure had
// more to give. Continuing past it is not possible here, because the connector projects only
// `/<Entries>/<File>` out of the response and discards Azure's `NextMarker`, so
// `files:FileList.Marker` is never populated.
const int LISTING_PAGE_SIZE = 5000;

// The file name used to probe whether a directory exists (see `probeDirectory`). It must be a
// name no real file would carry, since the probe reads "not found" as the good outcome.
const string EMPTINESS_PROBE_FILE = ".__ballerina_azure_files_existence_probe__";

// Fails when a listing came back exactly one page long, which means Azure had more entries to
// give and this loader cannot ask for them.
//
// Returning the truncated page would silently drop documents from a knowledge base, and a
// knowledge base that is quietly missing a thousand files is worse than one that refuses to
// build, so this is an error rather than a warning. A directory holding exactly
// `LISTING_PAGE_SIZE` entries trips it too; that false positive is the acceptable side of the
// trade. Narrow the load with `paths` or `includeExtensions` to get under the cap.
isolated function checkListingComplete(int entryCount, string kind, string directoryPath, string share)
        returns ai:Error? {
    if entryCount < LISTING_PAGE_SIZE {
        return ();
    }
    return error ai:Error(string `Listing the ${kind} of '${directoryPath}' in share '${share}' ` +
        string `returned a full page of ${LISTING_PAGE_SIZE} entries, so Azure has more that ` +
        string `cannot be retrieved: the underlying connector does not surface the continuation ` +
        string `marker. Loading the truncated page would silently drop documents. Narrow the ` +
        string `load with 'paths' or 'includeExtensions' so each directory stays under the cap`);
}

// Matches the `sig` query parameter of an Azure SAS token, the HMAC signature that makes the
// token usable. The name is spelled as a character class rather than with an inline `(?i)`
// flag so that case-insensitivity does not collide with the `\s` escape in the value part.
final regexp:RegExp SAS_SIGNATURE = re `[sS][iI][gG]=[^&\s]*`;

// Strips the SAS signature out of a message before it is interpolated into an `ai:Error`.
//
// A SAS token travels in the query string, and the `files` connector concatenates the whole
// request path — token included — into several of its error messages (`getFileList` and
// `getDirectoryList` both do, for instance). Those messages end up inside `ai:Error`s that
// applications routinely log, so a live storage credential could be written to a log file.
// Redacting the signature leaves the rest of the URL intact for diagnosis while making what
// remains useless to replay.
isolated function redactSecrets(string message) returns string =>
    SAS_SIGNATURE.replaceAll(message, "sig=<redacted>");

// Parses an ISO 8601 timestamp into `time:Utc`, or `()` if absent/unparseable.
// Azure Files' directory/file listings report timestamps in RFC 1123 form, which
// `time:utcFromString` does not accept, so those are dropped gracefully (see the README).
isolated function toUtc(string? dateTime) returns time:Utc? {
    if dateTime is () {
        return ();
    }
    time:Utc|error utc = time:utcFromString(dateTime);
    return utc is time:Utc ? utc : ();
}

// Removes duplicate strings, preserving first-appearance order. Applied to share names as
// a safety net only: `listShares` returns a single, un-paginated page and Azure share names
// are unique within an account, so this is not expected to remove anything today. It guards
// the day the connector grows a continuation marker and the loader starts concatenating
// pages (see `resolveShares`).
isolated function dedupeStrings(string[] values) returns string[] {
    string[] result = [];
    map<boolean> seen = {};
    foreach string value in values {
        if !seen.hasKey(value) {
            seen[value] = true;
            result.push(value);
        }
    }
    return result;
}

// MIME types (outside the `text/` family) treated as text.
final readonly & string[] TEXT_MIME_TYPES = [
    "application/json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/x-yaml",
    "application/yaml",
    "application/csv"
];

// File extensions treated as text.
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js", "ts"
];

// MIME types whose text is extracted via Apache Tika: PDF (PDFBox) and Microsoft
// Office documents (POI, via the `tika-parser-microsoft-module`).
final readonly & string[] EXTRACTABLE_MIME_TYPES = [
    "application/pdf",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
];

// File extensions whose text is extracted via Apache Tika: PDF and Microsoft Office.
final readonly & string[] EXTRACTABLE_EXTENSIONS = [
    "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx"
];
